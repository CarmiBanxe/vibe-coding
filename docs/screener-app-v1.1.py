#!/usr/bin/env python3
"""
Banxe Screener API v1.1
Combines: Moov Watchman (OFAC/UN/EU/UK sanctions) + Wikidata SPARQL (PEP, CC0)
Port: 8085

Fixes in v1.1:
- Watchman v2 API: ?name= parameter (not ?q=)
- Response uses entities[] array (not SDNs/EUSanctions/etc)
- Correct health check endpoint
"""
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse
import httpx
import requests

app = FastAPI(title="Banxe Screener API", version="1.1.0")
WATCHMAN = "http://localhost:8084"
WIKIDATA = "https://query.wikidata.org/sparql"
MIN_SCORE = 0.75  # min match score to flag as sanctioned

@app.get("/screen")
def screen(name: str = Query(..., description="Name, company, or country to screen")):
    result = {
        "entity": name,
        "sanctioned": False,
        "pep": False,
        "risk_level": "LOW",
        "sanctions_matches": [],
        "pep_matches": [],
        "sources": []
    }

    # ── Watchman sanctions check ──────────────────────────────
    try:
        r = httpx.get(
            f"{WATCHMAN}/v2/search",
            params={"name": name, "limit": 10},
            timeout=10.0
        )
        if r.status_code == 200:
            data = r.json()
            entities = data.get("entities") or []
            for entity in entities:
                source_list = entity.get("sourceList", "")
                entity_name = entity.get("name", "")
                score = entity.get("match", entity.get("score", 0))
                if score < MIN_SCORE:
                    continue
                sanctions_info = entity.get("sanctionsInfo") or {}
                programs = sanctions_info.get("programs", []) if sanctions_info else []
                result["sanctions_matches"].append({
                    "list": source_list,
                    "name": entity_name,
                    "score": round(score, 3),
                    "programs": programs
                })
            if result["sanctions_matches"]:
                result["sanctioned"] = True
                result["sources"].append("Watchman/OFAC+UN+EU+UK")
    except Exception as e:
        result["watchman_error"] = str(e)

    # ── Wikidata PEP check (Politically Exposed Persons) ─────
    try:
        sparql = f"""SELECT DISTINCT ?personLabel ?positionLabel ?countryLabel WHERE {{
  ?person wdt:P106 wd:Q82955;
          rdfs:label ?nameLabel.
  FILTER(LANG(?nameLabel)="en")
  FILTER(CONTAINS(LCASE(?nameLabel), LCASE("{name}")))
  OPTIONAL {{
    ?person p:P39 ?ps.
    ?ps ps:P39 ?pos.
    ?pos rdfs:label ?positionLabel.
    FILTER(LANG(?positionLabel)="en")
  }}
  OPTIONAL {{
    ?person wdt:P27 ?c.
    ?c rdfs:label ?countryLabel.
    FILTER(LANG(?countryLabel)="en")
  }}
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "en". }}
}} LIMIT 5"""
        r2 = requests.get(
            WIKIDATA,
            params={"query": sparql, "format": "json"},
            headers={"User-Agent": "BanxeAIBank/1.1 (compliance@banxe.com)"},
            timeout=15
        )
        bindings = r2.json().get("results", {}).get("bindings", [])
        for b in bindings:
            result["pep_matches"].append({
                "name": b.get("personLabel", {}).get("value", name),
                "position": b.get("positionLabel", {}).get("value", "Unknown"),
                "country": b.get("countryLabel", {}).get("value", "Unknown")
            })
        if result["pep_matches"]:
            result["pep"] = True
            result["sources"].append("Wikidata/PEP")
    except Exception as e:
        result["wikidata_error"] = str(e)

    # ── Risk level ────────────────────────────────────────────
    if result["sanctioned"]:
        result["risk_level"] = "HIGH"
    elif result["pep"]:
        result["risk_level"] = "MEDIUM"

    return result

@app.get("/sanctions")
def sanctions_only(name: str = Query(...)):
    try:
        r = httpx.get(f"{WATCHMAN}/v2/search", params={"name": name, "limit": 10}, timeout=10.0)
        return r.json() if r.status_code == 200 else {"error": f"Watchman HTTP {r.status_code}"}
    except Exception as e:
        return {"error": str(e)}

@app.get("/health")
def health():
    watchman_ok = False
    watchman_entities = 0
    try:
        w = httpx.get(f"{WATCHMAN}/v2/search?name=test&limit=1", timeout=3.0)
        if w.status_code == 200:
            watchman_ok = True
            entities = w.json().get("entities") or []
            watchman_entities = len(entities)
    except Exception:
        pass
    return {
        "status": "ok",
        "watchman": watchman_ok,
        "wikidata": "api.cc0",
        "watchman_has_data": watchman_entities > 0
    }
