#!/data/banxe/compliance-env/bin/python3
"""
PEP Check — Politically Exposed Persons screening.
Two-step approach:
  1. PostgreSQL pep_legislators (14,491 records) — ~5ms
  2. Wikidata fallback: wbsearchentities → QID → SPARQL P39 (positions held)

Called synchronously (use loop.run_in_executor from async context).
"""
from __future__ import annotations

import re
import time
from typing import Optional

import requests

# ── PostgreSQL (optional — graceful when not available) ───────────────────────
try:
    import psycopg2
    import psycopg2.extras
    PG_AVAILABLE = True
except ImportError:
    PG_AVAILABLE = False

PG_DSN = "host=127.0.0.1 port=5432 dbname=banxe_compliance user=banxe password=banxe_secure_2026"

# ── Wikidata ──────────────────────────────────────────────────────────────────
WIKIDATA_SEARCH = "https://www.wikidata.org/w/api.php"
WIKIDATA_SPARQL = "https://query.wikidata.org/sparql"

# Keywords in Wikidata entity description that indicate PEP status
PEP_KEYWORDS = {
    "politician", "president", "prime minister", "minister", "senator",
    "member of parliament", "mp ", "governor", "ambassador", "diplomat",
    "judge", "general", "admiral", "commissioner", "chancellor",
    "secretary of state", "head of state", "head of government",
    "mayor", "prefect", "oligarch", "executive",
}

SPARQL_BY_QID = """
SELECT ?positionLabel ?countryLabel ?start WHERE {{
  wd:{qid} p:P39 ?stmt .
  ?stmt ps:P39 ?position .
  OPTIONAL {{ ?stmt pq:P17 ?country . }}
  OPTIONAL {{ ?stmt pq:P580 ?start . }}
  SERVICE wikibase:label {{
    bd:serviceParam wikibase:language "en" .
  }}
}}
ORDER BY DESC(?start)
LIMIT 20
"""


# ── Step 1: PostgreSQL lookup ─────────────────────────────────────────────────

def _pg_lookup(full_name: str) -> Optional[dict]:
    """Search pep_legislators table. Returns hit dict or None."""
    if not PG_AVAILABLE:
        return None
    try:
        conn = psycopg2.connect(PG_DSN, connect_timeout=3)
        cur  = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        # Exact match first
        cur.execute(
            "SELECT * FROM banxe_compliance.pep_legislators "
            "WHERE lower(full_name) = lower(%s) LIMIT 1",
            (full_name,),
        )
        row = cur.fetchone()
        if not row:
            # Partial match on last name + first name fragment
            parts = full_name.split()
            if len(parts) >= 2:
                cur.execute(
                    "SELECT * FROM banxe_compliance.pep_legislators "
                    "WHERE lower(full_name) LIKE lower(%s) LIMIT 1",
                    (f"%{parts[-1]}%{parts[0][0]}%",),
                )
                row = cur.fetchone()
        conn.close()
        if row:
            return {
                "hit":         True,
                "source":      "postgresql",
                "full_name":   row.get("full_name", full_name),
                "description": row.get("description", ""),
                "positions":   [{"position": row.get("position", ""), "country": row.get("country", "")}],
                "qid":         row.get("wikidata_qid", ""),
            }
    except Exception:
        pass
    return None


# ── Step 2: Wikidata 2-step ───────────────────────────────────────────────────

def _wikidata_lookup(full_name: str) -> dict:
    """
    Step 2a: wbsearchentities → best QID + quick description PEP check.
    Step 2b: SPARQL by QID for P39 positions held (targeted, fast ~1s).
    """
    base_result: dict = {
        "hit": False, "source": "wikidata",
        "full_name": full_name, "description": "",
        "positions": [], "qid": "",
    }

    # ── 2a: Search ────────────────────────────────────────────────────────────
    try:
        resp = requests.get(
            WIKIDATA_SEARCH,
            params={
                "action":   "wbsearchentities",
                "search":   full_name,
                "language": "en",
                "type":     "item",
                "limit":    5,
                "format":   "json",
            },
            timeout=8,
            headers={"User-Agent": "BanxeAML/1.0 (compliance@banxe.com)"},
        )
        results = resp.json().get("search", [])
    except Exception:
        return base_result

    if not results:
        return base_result

    # Pick best match: prefer result whose label closely matches full_name
    best = None
    name_lower = full_name.lower()
    for item in results:
        label = item.get("label", "").lower()
        if label == name_lower or all(p in label for p in name_lower.split()):
            best = item
            break
    if best is None:
        best = results[0]

    qid         = best.get("id", "")
    description = best.get("description", "").lower()
    label       = best.get("label", full_name)

    # Quick check: description keywords
    quick_pep = any(kw in description for kw in PEP_KEYWORDS)

    if not qid:
        return base_result

    # ── 2b: SPARQL by QID ─────────────────────────────────────────────────────
    positions = []
    try:
        sparql = SPARQL_BY_QID.format(qid=qid)
        r2 = requests.get(
            WIKIDATA_SPARQL,
            params={"query": sparql, "format": "json"},
            timeout=10,
            headers={
                "User-Agent": "BanxeAML/1.0 (compliance@banxe.com)",
                "Accept":     "application/sparql-results+json",
            },
        )
        bindings = r2.json().get("results", {}).get("bindings", [])

        seen: set = set()
        for b in bindings:
            pos     = b.get("positionLabel", {}).get("value", "")
            country = b.get("countryLabel", {}).get("value", "")
            start   = b.get("start", {}).get("value", "")[:10]
            key     = (pos, country)
            if key not in seen and pos:
                seen.add(key)
                positions.append({"position": pos, "country": country, "start": start})

    except Exception:
        pass

    is_pep = bool(positions) or quick_pep

    return {
        "hit":         is_pep,
        "source":      "wikidata",
        "full_name":   label,
        "description": description[:200],
        "positions":   positions[:10],
        "qid":         qid,
    }


# ── Public entry point ────────────────────────────────────────────────────────

def check_pep(full_name: str) -> dict:
    """
    Synchronous PEP check.
    1. PostgreSQL pep_legislators first (~5ms).
    2. Wikidata 2-step fallback (~1.5s).

    Returns:
        {
            hit: bool,
            source: "postgresql" | "wikidata" | "none",
            full_name: str,
            description: str,
            positions: [{"position", "country", "start"}],
            qid: str,
            check_time_ms: int,
        }
    """
    t0 = time.time()

    # Try PostgreSQL first
    pg_result = _pg_lookup(full_name)
    if pg_result:
        pg_result["check_time_ms"] = int((time.time() - t0) * 1000)
        return pg_result

    # Wikidata fallback
    wd_result = _wikidata_lookup(full_name)
    wd_result["check_time_ms"] = int((time.time() - t0) * 1000)
    return wd_result


# ── Standalone test ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    import json
    tests = [
        ("Emmanuel Macron",    True,  "French President"),
        ("Vladimir Putin",     True,  "Russian President, sanctioned"),
        ("Emma Johnson",       False, "Generic clean name"),
    ]
    for name, expected, note in tests:
        r = check_pep(name)
        status = "✅" if r["hit"] == expected else "❌"
        print(f"{status} {name}: hit={r['hit']} ({note})")
        print(f"   source={r['source']}, time={r['check_time_ms']}ms")
        if r["positions"]:
            print(f"   positions: {r['positions'][:2]}")
