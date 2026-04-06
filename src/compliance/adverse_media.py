#!/data/banxe/compliance-env/bin/python3
"""
Adverse Media + Regulatory Feed Monitor — Phase 15
Sources:
  - Google News RSS (English, global)
  - FCA Enforcement Notices RSS (live)
  - EBA News RSS (live)
  - EUR-Lex (AML/sanctions legislative collection RSS)
  - OFAC Recent Actions HTML scrape (RSS retired 31 Jan 2025)
  - BAILII (via legal_databases.py integration — no RSS)

Scoring model:
  final_score = source_weight * 0.45 + entity_match_weight * 0.35 + topic_weight * 0.20

Regulatory sources are tagged is_regulatory=True and carry higher source_weight.
"""
from __future__ import annotations

import asyncio
import hashlib
import html
import re
import time
from typing import Optional
import xml.etree.ElementTree as ET

import httpx

# ── Feed registry ─────────────────────────────────────────────────────────────

FEED_REGISTRY = [
    # source_name, feed_url, source_family, source_weight, jurisdiction, is_regulatory
    {
        "source_name":   "Google-News",
        "feed_url":      "https://news.google.com/rss/search?q={query}&hl=en-GB&gl=GB&ceid=GB:en",
        "source_family": "news",
        "source_weight": 0.55,
        "jurisdiction":  "multi",
        "is_regulatory": False,
        "uses_query":    True,
    },
    {
        "source_name":   "FCA-Enforcement",
        "feed_url":      "https://www.fca.org.uk/news/rss.xml",
        "source_family": "regulator",
        "source_weight": 1.00,
        "jurisdiction":  "uk",
        "is_regulatory": True,
        "uses_query":    False,
    },
    {
        "source_name":   "EBA-News",
        "feed_url":      "https://www.eba.europa.eu/rss/press-releases",
        "source_family": "regulator",
        "source_weight": 0.85,
        "jurisdiction":  "eu",
        "is_regulatory": True,
        "uses_query":    False,
    },
    {
        "source_name":   "EUR-Lex-AML",
        "feed_url":      "https://eur-lex.europa.eu/RSSXSL/atom.xsl?type=recent&topic=anti-money-laundering",
        "source_family": "eu_law",
        "source_weight": 0.75,
        "jurisdiction":  "eu",
        "is_regulatory": True,
        "uses_query":    False,
    },
    # OFAC RSS retired 31 January 2025 — replaced by Recent Actions HTML scrape
    {
        "source_name":   "OFAC-RecentActions",
        "feed_url":      "https://ofac.treasury.gov/recent-actions/actions",
        "source_family": "regulator",
        "source_weight": 0.95,
        "jurisdiction":  "us",
        "is_regulatory": True,
        "uses_query":    False,
        "is_html_scrape": True,
    },
]

# Topic weights (for topic scoring; keyword → weight bucket)
TOPIC_KEYWORD_WEIGHTS = {
    # Weight 1.0 — highest risk
    "money laundering":     1.0,
    "sanction":             1.0,
    "sanctioned":           1.0,
    "sanctions":            1.0,
    "sdn":                  1.0,
    "sdn list":             1.0,
    "designation":          1.0,
    "asset freeze":         1.0,
    "designated":           1.0,
    "terrorist financing":  1.0,
    "proceeds of crime":    1.0,
    "confiscation":         1.0,
    "restraint order":      1.0,
    "winding up":           1.0,
    # Weight 0.85 — significant
    "fraud":                0.85,
    "bribery":              0.85,
    "corruption":           0.85,
    "insider dealing":      0.85,
    "market abuse":         0.85,
    "final notice":         0.85,
    "enforcement action":   0.85,
    "criminal charge":      0.85,
    "conviction":           0.85,
    # Weight 0.70 — notable
    "investigation":        0.70,
    "probe":                0.70,
    "fine":                 0.70,
    "penalty":              0.70,
    "censure":              0.70,
    "warning notice":       0.70,
    "administration":       0.70,
    "insolvency":           0.70,
    "bankruptcy":           0.70,
    # Weight 0.40 — weak signal
    "regulatory":           0.40,
    "compliance":           0.40,
    "consultation":         0.40,
}

HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; BanxeAML/1.0; +https://banxe.com)"}

# Module-level import so tests can patch adverse_media.check_legal_exposure
try:
    from legal_databases import check_legal_exposure
except ImportError:
    check_legal_exposure = None  # type: ignore


# ── RSS / Atom parser ─────────────────────────────────────────────────────────

def _parse_feed(xml_text: str) -> list[dict]:
    """Parse RSS 2.0 or Atom feed into list of {title, url, summary, published}."""
    items = []
    try:
        root = ET.fromstring(xml_text)
        ns = {
            "atom": "http://www.w3.org/2005/Atom",
            "media": "http://search.yahoo.com/mrss/",
        }

        # Detect Atom vs RSS
        tag = root.tag.lower()
        if "feed" in tag:
            # Atom
            for entry in root.findall("atom:entry", ns) or root.findall("{http://www.w3.org/2005/Atom}entry"):
                title   = entry.findtext("{http://www.w3.org/2005/Atom}title", "")
                link_el = entry.find("{http://www.w3.org/2005/Atom}link")
                url     = link_el.get("href", "") if link_el is not None else ""
                summary = entry.findtext("{http://www.w3.org/2005/Atom}summary", "")
                pub     = entry.findtext("{http://www.w3.org/2005/Atom}published", "")
                if title:
                    items.append({"title": html.unescape(title), "url": url, "summary": html.unescape(summary or "")[:300], "published": pub[:10]})
        else:
            # RSS 2.0
            channel = root.find("channel")
            entries = (channel or root).findall("item")
            for entry in entries:
                title   = entry.findtext("title", "")
                url     = entry.findtext("link", "") or entry.findtext("guid", "")
                summary = entry.findtext("description", "")
                pub     = entry.findtext("pubDate", "")
                if title:
                    items.append({"title": html.unescape(title), "url": url, "summary": html.unescape(summary or "")[:300], "published": pub[:16]})
    except Exception:
        pass
    return items


# ── OFAC Recent Actions HTML scraper ─────────────────────────────────────────

def _parse_ofac_html(html_text: str) -> list[dict]:
    """
    Extract action titles and URLs from OFAC Recent Actions page.
    Returns list of {title, url, published} dicts.
    """
    items = []
    # Pattern: table rows or list items with dates and action titles
    # OFAC page typically has <tr> rows with date + description
    row_pattern = re.findall(
        r'<tr[^>]*>.*?<td[^>]*>([^<]{6,12})</td>.*?<td[^>]*>(?:<a[^>]*href="([^"]+)"[^>]*>)?([^<]{5,200})',
        html_text, re.DOTALL | re.IGNORECASE,
    )
    for date_str, href, title in row_pattern[:20]:
        title = html.unescape(title.strip())
        if not title or len(title) < 5:
            continue
        url = href if href else "https://ofac.treasury.gov/recent-actions/actions"
        if not url.startswith("http"):
            url = f"https://ofac.treasury.gov{url}"
        items.append({"title": title, "url": url, "published": date_str.strip(), "summary": ""})

    # Fallback: grab any anchor text that looks like a sanction action
    if not items:
        link_pattern = re.findall(
            r'href="(/recent-actions/[^"]+|https://ofac[^"]+)"[^>]*>([^<]{10,150})</a>',
            html_text, re.IGNORECASE,
        )
        for href, title in link_pattern[:15]:
            title = html.unescape(title.strip())
            url   = href if href.startswith("http") else f"https://ofac.treasury.gov{href}"
            items.append({"title": title, "url": url, "published": "", "summary": ""})

    return items


# ── Entity matching ───────────────────────────────────────────────────────────

def _entity_match_weight(entity_name: str, text: str, aliases: list[str] = None) -> float:
    """
    Returns entity_match_weight:
      1.00 — exact legal name (case-insensitive)
      0.80 — alias / previous name match
      0.45 — any name part appears in text
    """
    text_lower = text.lower()
    name_lower = entity_name.lower()

    if name_lower in text_lower:
        return 1.00

    for alias in (aliases or []):
        if alias.lower() in text_lower:
            return 0.80

    # Partial: all significant name parts present
    parts = [p for p in name_lower.split() if len(p) > 2]
    if parts and all(p in text_lower for p in parts):
        return 0.70

    # Any part present
    if any(p in text_lower for p in parts):
        return 0.45

    return 0.0


def _topic_weight(text: str) -> float:
    """Return max topic_weight from keywords found in text."""
    text_lower = text.lower()
    weight = 0.0
    for kw, w in TOPIC_KEYWORD_WEIGHTS.items():
        if kw in text_lower:
            weight = max(weight, w)
    return weight


def _score_article(source_weight: float, entity_match: float, topic: float) -> float:
    """final_score = source_weight * 0.45 + entity_match * 0.35 + topic * 0.20"""
    return round(source_weight * 0.45 + entity_match * 0.35 + topic * 0.20, 4)


def _stable_hash(source_name: str, item_url: str, title: str) -> str:
    payload = f"{source_name}|{item_url or title}"
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


# ── Per-feed fetcher ──────────────────────────────────────────────────────────

async def _fetch_feed(
    client: httpx.AsyncClient,
    feed: dict,
    entity_name: str,
    aliases: list[str],
) -> list[dict]:
    """Fetch one feed and return scored articles matching entity_name."""
    url = feed["feed_url"]
    if feed.get("uses_query"):
        query = entity_name.replace(" ", "+")
        url   = url.format(query=query)

    matched = []
    try:
        r = await client.get(url, headers=HEADERS, timeout=12)
        if r.status_code != 200:
            return []

        if feed.get("is_html_scrape"):
            items = _parse_ofac_html(r.text)
        else:
            items = _parse_feed(r.text)

        for item in items:
            combined_text = f"{item['title']} {item.get('summary', '')}"

            # For query-based feeds (Google News) all results are pre-filtered by name
            if feed.get("uses_query"):
                em_weight = 1.0 if entity_name.lower() in combined_text.lower() else 0.45
            else:
                em_weight = _entity_match_weight(entity_name, combined_text, aliases)
                if em_weight == 0.0:
                    continue  # no match in non-query feed

            topic = _topic_weight(combined_text)
            score = _score_article(feed["source_weight"], em_weight, topic)

            if score < 0.10:
                continue  # below noise floor

            matched.append({
                "event_stable_hash": _stable_hash(feed["source_name"], item.get("url", ""), item["title"]),
                "source_name":       feed["source_name"],
                "source_family":     feed["source_family"],
                "source_weight":     feed["source_weight"],
                "is_regulatory":     feed["is_regulatory"],
                "jurisdiction":      feed["jurisdiction"],
                "title":             item["title"][:180],
                "url":               item.get("url", ""),
                "summary":           item.get("summary", "")[:300],
                "published":         item.get("published", "")[:10],
                "entity_match_weight": em_weight,
                "topic_weight":      topic,
                "final_score":       score,
                "topic_tags":        [kw for kw, w in TOPIC_KEYWORD_WEIGHTS.items() if kw in combined_text.lower() and w >= 0.70],
            })

    except Exception:
        pass

    return matched


# ── Main entry point ──────────────────────────────────────────────────────────

async def check_adverse_media(
    entity_name: str,
    aliases: list[str] = None,
    include_legal_db: bool = False,
) -> dict:
    """
    Full adverse media + regulatory check.

    Args:
        entity_name: Person or company name
        aliases: Previous names / aliases for entity matching
        include_legal_db: Also run EUR-Lex CELLAR SPARQL + BAILII (slower, EDD)

    Returns:
        {
            risk_score: int (0-100),
            risk_level: NONE/LOW/MEDIUM/HIGH/CRITICAL,
            hits: int,
            articles: [...],
            top_articles: [...],
            regulatory_hits: int,
            high_severity_topics: [...],
        }
    """
    t0      = time.time()
    aliases = aliases or []
    all_articles = []

    async with httpx.AsyncClient(timeout=12, follow_redirects=True) as client:
        tasks = [
            _fetch_feed(client, feed, entity_name, aliases)
            for feed in FEED_REGISTRY
        ]
        results = await asyncio.gather(*tasks, return_exceptions=True)

    for batch in results:
        if isinstance(batch, list):
            all_articles.extend(batch)

    # Deduplicate by stable_hash
    seen = set()
    unique = []
    for a in all_articles:
        h = a["event_stable_hash"]
        if h not in seen:
            seen.add(h)
            unique.append(a)

    # Sort by final_score desc
    unique.sort(key=lambda x: x["final_score"], reverse=True)

    # Aggregate risk score
    # Weight: regulatory articles count more; cap at 100
    raw_score = 0
    regulatory_hits = 0
    high_severity_topics = set()

    for a in unique:
        contribution = int(a["final_score"] * 100)
        if a["is_regulatory"]:
            contribution = int(contribution * 1.4)  # regulatory boost ×1.4
            regulatory_hits += 1
        raw_score += contribution
        for tag in a.get("topic_tags", []):
            high_severity_topics.add(tag)

    risk_score = min(raw_score, 100)

    risk_level = (
        "CRITICAL" if risk_score >= 80 else
        "HIGH"     if risk_score >= 60 else
        "MEDIUM"   if risk_score >= 30 else
        "LOW"      if risk_score > 0   else
        "NONE"
    )

    # Optional EDD legal layer
    legal_result = {}
    if include_legal_db:
        try:
            if check_legal_exposure is None:
                raise ImportError("legal_databases not available")
            legal_result = await check_legal_exposure(entity_name)
            # Merge legal risk into score
            legal_boost = min(legal_result.get("legal_risk_score", 0) // 2, 20)
            risk_score  = min(risk_score + legal_boost, 100)
            if risk_score >= 80:
                risk_level = "CRITICAL"
            elif risk_score >= 60:
                risk_level = "HIGH"
        except ImportError:
            pass

    return {
        "entity_name":          entity_name,
        "risk_score":           risk_score,
        "risk_level":           risk_level,
        "hits":                 len(unique),
        "regulatory_hits":      regulatory_hits,
        "high_severity_topics": sorted(high_severity_topics),
        "top_articles":         unique[:5],
        "articles":             unique,
        "legal_exposure":       legal_result,
        "check_time_ms":        int((time.time() - t0) * 1000),
    }


# ── Standalone test ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    import asyncio

    async def test():
        print("=" * 60)
        print("  ADVERSE MEDIA — Feed Registry + Scoring")
        print("=" * 60)

        tests = [
            ("Vladimir Putin",   [], "expect: HIGH/CRITICAL"),
            ("Alisher Usmanov",  [], "expect: HIGH (EU asset freeze)"),
            ("HSBC",             [], "expect: MEDIUM (historical AML)"),
            ("RandomNobodyXyz123", [], "expect: NONE"),
        ]
        for name, aliases, note in tests:
            print(f"\n[{name}] — {note}")
            r = await check_adverse_media(name, aliases)
            print(f"  risk: {r['risk_level']} (score={r['risk_score']})")
            print(f"  hits: {r['hits']} total, {r['regulatory_hits']} regulatory")
            if r['high_severity_topics']:
                print(f"  topics: {r['high_severity_topics'][:4]}")
            for a in r['top_articles'][:3]:
                flag = "[REG]" if a['is_regulatory'] else "[NEWS]"
                print(f"    {flag} [{a['source_name']}] {a['title'][:70]} (score={a['final_score']:.3f})")

    asyncio.run(test())
