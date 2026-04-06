#!/data/banxe/compliance-env/bin/python3
"""
Legal Databases — Phase 14
EUR-Lex (EU law + sanctions regulations) + BAILII (UK case law).
Free / open-access sources, no API key required.

Covers:
  - EUR-Lex CELLAR SPARQL: EU sanctions regulations, enforcement decisions
  - EUR-Lex REST: full-text search in Official Journal
  - BAILII website search: UK court cases mentioning entity (crime/fraud/AML)

Used by: screener.py (EDD layer when composite_score >= 40)
         api.py /screen/person when requires_edd=True
"""
from __future__ import annotations

import asyncio
import re
import time
from typing import Optional
import httpx

# ── EUR-Lex ───────────────────────────────────────────────────────────────────

EURLEX_CELLAR_SPARQL = "https://publications.europa.eu/webapi/rdf/sparql"
EURLEX_REST_SEARCH   = "https://eur-lex.europa.eu/search.html"
EURLEX_REST_API      = "https://eur-lex.europa.eu/CELLAR/data"

# Sanction regulation CELEX numbers (Council Regulations restricting persons)
SANCTIONS_CELEX = [
    "32014R0269",  # Crimea/Sevastopol
    "32022R0428",  # Russia/Ukraine — primary
    "32022R0576",
    "32022R1269",
    "32023R1215",
    "32014R0833",  # Russian sectoral sanctions
    "32017R1509",  # North Korea
    "32012R0267",  # Iran
    "32012R0036",  # Syria
]

# SPARQL: find mentions of entity name in EUR-Lex enforcement notices
CELLAR_SPARQL_TEMPLATE = """
PREFIX cdm: <http://publications.europa.eu/ontology/cdm#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
SELECT DISTINCT ?work ?title ?date ?celex
WHERE {{
  ?work cdm:work_has_resource-type ?type .
  ?work cdm:work_date_document ?date .
  OPTIONAL {{ ?work cdm:work_created_by_agent ?author . }}
  ?work cdm:expression_title ?title_obj .
  ?title_obj skos:prefLabel ?title .
  OPTIONAL {{ ?work cdm:resource_legal_id_celex ?celex . }}
  FILTER (lang(?title) = 'en')
  FILTER (contains(lcase(str(?title)), lcase("{name}")))
  FILTER (?date >= "{year}-01-01"^^xsd:date)
}}
ORDER BY DESC(?date)
LIMIT 10
"""

# EUR-Lex full-text search (HTML scrape — no API key needed)
EURLEX_SEARCH_URL = "https://eur-lex.europa.eu/search.html"


async def search_eurlex(
    entity_name: str,
    timeout: int = 10,
) -> dict:
    """
    Search EUR-Lex for entity mentions in:
    1. Official Journal (sanctions listings, enforcement)
    2. SPARQL CELLAR (recent enforcement decisions)

    Returns:
        {
            "entity_name": str,
            "eu_legal_hits": int,
            "eu_sanctions_regulations": int,
            "eu_findings": [{"title": str, "date": str, "celex": str, "url": str}],
            "risk_score": int (0-60),
            "risk_level": "NONE"/"LOW"/"MEDIUM"/"HIGH",
            "source": "EUR-Lex",
        }
    """
    findings = []
    risk_score = 0

    async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:

        # ── 1. EUR-Lex REST search (Official Journal full-text) ───────────────
        try:
            params = {
                "scope":   "EURLEX",
                "type":    "quick",
                "text":    f'"{entity_name}"',
                "lang":    "en",
                "qid":     "1",
                "DTS_DOM": "ALL",
                "SUBDOM_INIT": "ALL_ALL",
                "DTS_SUBDOM": "ALL_ALL",
                "page":    "1",
                "pageSize": "10",
            }
            r = await client.get(EURLEX_SEARCH_URL, params=params)
            if r.status_code == 200:
                text = r.text
                # Extract result count from HTML
                count_match = re.search(r'(\d[\d,]*)\s+result', text, re.IGNORECASE)
                hit_count = 0
                if count_match:
                    hit_count = int(count_match.group(1).replace(",", ""))

                # Extract titles and CELEX numbers from result list
                celex_pattern = re.findall(
                    r'CELEX:(\d{5}[A-Z]\d{4})', text
                )
                title_pattern = re.findall(
                    r'class="[^"]*title[^"]*"[^>]*>([^<]{10,200})<', text
                )

                for i, celex in enumerate(celex_pattern[:5]):
                    title = title_pattern[i] if i < len(title_pattern) else f"EUR-Lex: {celex}"
                    findings.append({
                        "title":  title.strip(),
                        "celex":  celex,
                        "url":    f"https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:{celex}",
                        "source": "EUR-Lex Official Journal",
                        "date":   "",
                    })

                if hit_count > 0:
                    risk_score += min(20 * min(hit_count, 3), 40)

        except Exception:
            pass

        # ── 2. SPARQL CELLAR search ───────────────────────────────────────────
        try:
            import datetime
            current_year = datetime.datetime.now().year - 3  # last 3 years
            sparql_query = CELLAR_SPARQL_TEMPLATE.format(
                name=entity_name.replace('"', ''),
                year=str(current_year),
            )
            headers = {"Accept": "application/sparql-results+json"}
            r2 = await client.post(
                EURLEX_CELLAR_SPARQL,
                data={"query": sparql_query, "format": "application/sparql-results+json"},
                headers=headers,
            )
            if r2.status_code == 200:
                data = r2.json()
                bindings = data.get("results", {}).get("bindings", [])
                for b in bindings:
                    title = b.get("title", {}).get("value", "")
                    celex = b.get("celex", {}).get("value", "")
                    date  = b.get("date", {}).get("value", "")
                    work  = b.get("work", {}).get("value", "")
                    if title and title not in [f["title"] for f in findings]:
                        findings.append({
                            "title":  title[:120],
                            "celex":  celex,
                            "url":    work or (f"https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:{celex}" if celex else ""),
                            "source": "EUR-Lex CELLAR SPARQL",
                            "date":   date[:10] if date else "",
                        })
                        risk_score = min(risk_score + 20, 60)
        except Exception:
            pass

    # Deduplicate
    seen_celexes = set()
    unique_findings = []
    for f in findings:
        key = f.get("celex") or f.get("title", "")[:40]
        if key not in seen_celexes:
            seen_celexes.add(key)
            unique_findings.append(f)

    risk_level = (
        "HIGH"   if risk_score >= 40 else
        "MEDIUM" if risk_score >= 20 else
        "LOW"    if risk_score > 0  else
        "NONE"
    )

    return {
        "entity_name":            entity_name,
        "eu_legal_hits":          len(unique_findings),
        "eu_findings":            unique_findings[:5],
        "risk_score":             risk_score,
        "risk_level":             risk_level,
        "source":                 "EUR-Lex",
    }


# ── BAILII ────────────────────────────────────────────────────────────────────

BAILII_SEARCH_URL = "https://www.bailii.org/cgi-bin/markup.cgi"
BAILII_SEARCH_ALT = "https://www.bailii.org/cgi-bin/AdvSearch.pl"

# AML/fraud-related keywords — presence of these with entity name = high risk
BAILII_HIGH_RISK_TERMS = [
    "money laundering", "proceeds of crime", "confiscation",
    "restraint order", "fraud", "bribery", "corruption",
    "terrorism", "sanctions", "asset freezing", "receivership",
]


async def search_bailii(
    entity_name: str,
    timeout: int = 12,
) -> dict:
    """
    Search BAILII for UK court cases mentioning entity.
    Focus: crime/fraud/AML/confiscation cases.

    Returns:
        {
            "entity_name": str,
            "uk_legal_hits": int,
            "uk_findings": [{"title": str, "citation": str, "url": str, "keywords": [str]}],
            "high_risk_keywords_found": [str],
            "risk_score": int (0-60),
            "risk_level": str,
            "source": "BAILII",
        }
    """
    findings = []
    high_risk_keywords = []
    risk_score = 0

    # Parts of name for search (last name most specific)
    name_parts = entity_name.strip().split()
    search_term = name_parts[-1] if len(name_parts) > 1 else entity_name
    full_search = entity_name

    async with httpx.AsyncClient(
        timeout=timeout,
        follow_redirects=True,
        headers={"User-Agent": "Mozilla/5.0 (compatible; BanxeAML/1.0; +https://banxe.com)"},
    ) as client:

        # ── BAILII Advanced Search ────────────────────────────────────────────
        try:
            params = {
                "query":     full_search,
                "bailiidb":  "all",
                "method":    "phrase",
                "highlight": "1",
            }
            r = await client.get(BAILII_SEARCH_ALT, params=params)
            if r.status_code == 200:
                text = r.text

                # Count results
                count_match = re.search(r'(\d+)\s+(?:document|result|case)', text, re.IGNORECASE)
                hit_count = int(count_match.group(1)) if count_match else 0

                # Extract case links and titles
                case_pattern = re.findall(
                    r'href="(/(?:ew|ni|scot|ukpc|ukhl|uksc)/[^"]+\.html)"[^>]*>([^<]{5,150})<',
                    text,
                    re.IGNORECASE,
                )
                neutral_citation = re.findall(
                    r'\[(\d{4})\]\s+(?:EWCA|EWHC|UKSC|UKHL|UKPC|CSIH|NICA)\s+\w+\s+\d+',
                    text,
                )

                # Check for high-risk terms in the page
                text_lower = text.lower()
                for term in BAILII_HIGH_RISK_TERMS:
                    if term in text_lower:
                        high_risk_keywords.append(term)

                for href, title in case_pattern[:5]:
                    citation_match = re.search(
                        r'\[(\d{4})\]\s+(?:EWCA|EWHC|UKSC|UKHL)\s+\w+\s+\d+', title
                    )
                    citation = citation_match.group(0) if citation_match else ""
                    findings.append({
                        "title":    title.strip()[:120],
                        "citation": citation,
                        "url":      f"https://www.bailii.org{href}",
                        "source":   "BAILII",
                        "keywords": [t for t in BAILII_HIGH_RISK_TERMS if t in title.lower()],
                    })

                if hit_count > 0:
                    risk_score += min(15 * min(hit_count, 4), 40)
                if high_risk_keywords:
                    risk_score = min(risk_score + 10 * len(set(high_risk_keywords)), 60)

        except Exception:
            pass

        # ── BAILII simple search fallback ─────────────────────────────────────
        if not findings:
            try:
                params2 = {
                    "query":    full_search,
                    "bailiidb": "all",
                }
                r2 = await client.get(
                    "https://www.bailii.org/cgi-bin/markup.cgi",
                    params=params2,
                )
                if r2.status_code == 200:
                    text2 = r2.text
                    case_links = re.findall(
                        r'href="(/(?:ew|ni|scot|ukpc|ukhl|uksc)/[^"]+\.html)"',
                        text2, re.IGNORECASE
                    )
                    if case_links:
                        risk_score += 15
                        findings.append({
                            "title":    f"UK court records for: {entity_name}",
                            "citation": "",
                            "url":      f"https://www.bailii.org/cgi-bin/markup.cgi?query={full_search.replace(' ', '+')}&bailiidb=all",
                            "source":   "BAILII",
                            "keywords": [],
                        })
            except Exception:
                pass

    risk_level = (
        "HIGH"   if risk_score >= 40 else
        "MEDIUM" if risk_score >= 20 else
        "LOW"    if risk_score > 0  else
        "NONE"
    )

    return {
        "entity_name":              entity_name,
        "uk_legal_hits":            len(findings),
        "uk_findings":              findings,
        "high_risk_keywords_found": list(set(high_risk_keywords))[:8],
        "risk_score":               risk_score,
        "risk_level":               risk_level,
        "source":                   "BAILII",
    }


# ── Aggregated check ──────────────────────────────────────────────────────────

async def check_legal_exposure(entity_name: str) -> dict:
    """
    Run EUR-Lex + BAILII in parallel.
    Returns combined legal exposure profile.

    Called by screener.py when composite_score >= 40 (EDD required).
    """
    t0 = time.time()

    eurlex_task = asyncio.create_task(search_eurlex(entity_name))
    bailii_task = asyncio.create_task(search_bailii(entity_name))

    eurlex_result, bailii_result = await asyncio.gather(
        eurlex_task, bailii_task, return_exceptions=True
    )

    # Handle exceptions gracefully
    if isinstance(eurlex_result, Exception):
        eurlex_result = {"eu_legal_hits": 0, "eu_findings": [], "risk_score": 0, "risk_level": "NONE", "error": str(eurlex_result)}
    if isinstance(bailii_result, Exception):
        bailii_result = {"uk_legal_hits": 0, "uk_findings": [], "risk_score": 0, "risk_level": "NONE", "error": str(bailii_result)}

    combined_score = min(
        eurlex_result.get("risk_score", 0) + bailii_result.get("risk_score", 0),
        80
    )
    combined_level = (
        "HIGH"   if combined_score >= 50 else
        "MEDIUM" if combined_score >= 20 else
        "LOW"    if combined_score > 0  else
        "NONE"
    )

    return {
        "entity_name":      entity_name,
        "legal_risk_score": combined_score,
        "legal_risk_level": combined_level,
        "eu_legal": {
            "hits":     eurlex_result.get("eu_legal_hits", 0),
            "findings": eurlex_result.get("eu_findings", []),
            "score":    eurlex_result.get("risk_score", 0),
        },
        "uk_legal": {
            "hits":     bailii_result.get("uk_legal_hits", 0),
            "findings": bailii_result.get("uk_findings", []),
            "high_risk_keywords": bailii_result.get("high_risk_keywords_found", []),
            "score":    bailii_result.get("risk_score", 0),
        },
        "check_time_ms": int((time.time() - t0) * 1000),
    }


# ── Standalone test ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    import json

    async def test():
        print("=" * 60)
        print("  LEGAL DATABASES — EUR-Lex + BAILII")
        print("=" * 60)

        test_entities = [
            ("Vladimir Putin",    "expect: HIGH (sanctions regulations)"),
            ("Alisher Usmanov",   "expect: HIGH (EU/UK asset freeze)"),
            ("HSBC",              "expect: MEDIUM (BAILII AML cases)"),
            ("Emma Johnson",      "expect: NONE (clean)"),
        ]

        for name, note in test_entities:
            print(f"\n[{name}] — {note}")
            result = await check_legal_exposure(name)
            print(f"  Legal risk: {result['legal_risk_level']} (score={result['legal_risk_score']})")
            print(f"  EUR-Lex hits: {result['eu_legal']['hits']}")
            print(f"  BAILII hits:  {result['uk_legal']['hits']}")
            if result['uk_legal']['high_risk_keywords']:
                print(f"  AML keywords: {result['uk_legal']['high_risk_keywords']}")
            for f in result['eu_legal']['findings'][:2]:
                print(f"    EU: {f['title'][:70]}")
            for f in result['uk_legal']['findings'][:2]:
                print(f"    UK: {f['title'][:70]}")
            print(f"  Time: {result['check_time_ms']}ms")

    asyncio.run(test())
