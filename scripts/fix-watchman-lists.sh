#!/bin/bash
# fix-watchman-lists.sh
#
# Что фиксит:
#   1. Watchman INCLUDED_LISTS — env var в systemd (YAML config не работает из-за отсутствия YAML-тегов в Go-структуре)
#   2. Screener app.py — параметр name вместо q для Watchman v2 API + корректный парсинг ответа
#   3. Перезапуск обоих сервисов + верификация загрузки данных
#
# Запускать на Legion: bash scripts/fix-watchman-lists.sh

set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "════════════════════════════════════════════"
echo "  Fix: Watchman lists + Screener API"
echo "════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────────────────────
# ШАГ 1: Обновляем banxe-watchman.service — добавляем INCLUDED_LISTS
# ─────────────────────────────────────────────────────────
echo "[1/4] Обновляем banxe-watchman.service..."

ssh gmktec "sudo tee /etc/systemd/system/banxe-watchman.service > /dev/null" << 'UNIT_EOF'
[Unit]
Description=Banxe Watchman — Sanctions Screening (OFAC/UN/EU/UK/OFSI)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/data/banxe/watchman
# Root cause fix: Go struct lacks YAML tags for IncludedLists — must use env var
Environment=INCLUDED_LISTS=us_ofac,us_csl,us_non_sdn,us_fincen_311,uk_csl,eu_csl,un_csl
ExecStart=/usr/local/bin/banxe-watchman
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT_EOF

echo "  banxe-watchman.service обновлён ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 2: Обновляем screener app.py
# ─────────────────────────────────────────────────────────
echo ""
echo "[2/4] Обновляем screener app.py (v2 API: name param + entities response)..."

ssh gmktec "cat > /opt/banxe/screener/app.py" << 'APP_EOF'
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
                sanctions_info = entity.get("sanctionsInfo") or {}
                programs = sanctions_info.get("programs", []) if sanctions_info else []
                result["sanctions_matches"].append({
                    "list": source_list,
                    "name": entity_name,
                    "score": score,
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
APP_EOF

echo "  screener app.py обновлён ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 3: Перезапуск сервисов
# ─────────────────────────────────────────────────────────
echo ""
echo "[3/4] Перезапуск banxe-watchman и banxe-screener..."

ssh gmktec "sudo systemctl daemon-reload && sudo systemctl restart banxe-watchman.service"
echo "  Ждём 15 сек (первоначальная загрузка данных)..."
sleep 15

ssh gmktec "sudo systemctl restart banxe-screener.service"
sleep 3

WATCHMAN_STATUS=$(ssh gmktec "sudo systemctl is-active banxe-watchman.service")
SCREENER_STATUS=$(ssh gmktec "sudo systemctl is-active banxe-screener.service")

echo "  banxe-watchman: $WATCHMAN_STATUS"
echo "  banxe-screener: $SCREENER_STATUS"

# ─────────────────────────────────────────────────────────
# ШАГ 4: Верификация данных
# ─────────────────────────────────────────────────────────
echo ""
echo "[4/4] Верификация загрузки данных..."

WATCHMAN_LOG=$(ssh gmktec "sudo journalctl -u banxe-watchman.service --since '1 min ago' --no-pager 2>/dev/null | grep -E '(entities|lists|configured|refresh)' | tail -5")
echo "  Watchman logs:"
echo "  $WATCHMAN_LOG"

echo ""
echo "  Тест 1: Поиск 'Putin'..."
PUTIN=$(ssh gmktec "curl -s 'http://localhost:8085/screen?name=Putin' 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(\"sanctioned=\"+str(d[\"sanctioned\"])+\" matches=\"+str(len(d[\"sanctions_matches\"])))'")
echo "  $PUTIN"

echo "  Тест 2: Поиск 'Bashar al-Assad'..."
ASSAD=$(ssh gmktec "curl -s 'http://localhost:8085/screen?name=Bashar+al-Assad' 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(\"sanctioned=\"+str(d[\"sanctioned\"])+\" pep=\"+str(d[\"pep\"]))'")
echo "  $ASSAD"

echo "  Тест 3: Health check..."
HEALTH=$(ssh gmktec "curl -s 'http://localhost:8085/health' 2>/dev/null")
echo "  $HEALTH"

# ─────────────────────────────────────────────────────────
# Коммит
# ─────────────────────────────────────────────────────────
echo ""
echo "Коммит..."
cd "$REPO_DIR"
git add scripts/fix-watchman-lists.sh
git commit -m "fix: Watchman INCLUDED_LISTS via env var + screener v1.1 (name param)

Root cause: Go struct Config.IncludedLists has no YAML tags, so YAML config
is ignored. Fix: INCLUDED_LISTS env var in systemd unit.

Screener v1.1 fixes:
- Watchman API: ?name= param (not ?q=)
- Response parsing: entities[] array (v2 API format)
- Health endpoint checks actual data presence"
git pull --rebase origin main
git push origin main

echo ""
echo "════════════════════════════════════════════"
echo "  ГОТОВО"
echo "════════════════════════════════════════════"
echo ""
echo "  Следующий шаг: Протестируй скрининг в Telegram через бота"
echo "  curl 'http://localhost:8085/screen?name=Vladimir+Putin'"
echo ""
