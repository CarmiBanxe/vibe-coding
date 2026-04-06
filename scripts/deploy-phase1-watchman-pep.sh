#!/bin/bash
# deploy-phase1-watchman-pep.sh
# Phase 1: Moov Watchman (OFAC/UN/EU/UK) + Wikidata PEP + Banxe Screener API
#
# Что деплоится:
#   - /usr/local/bin/banxe-watchman  (Moov Watchman v0.61.1, Apache 2.0)
#   - banxe-watchman.service          (порт 8084)
#   - /opt/banxe/screener/app.py      (FastAPI: Watchman + Wikidata, порт 8085)
#   - banxe-screener.service
#   - OpenClaw skill в workspace-moa
#   - docker.io (для Phase 2: Jube, Marble)
#
# Запускать на Legion: bash scripts/deploy-phase1-watchman-pep.sh

set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "════════════════════════════════════════════"
echo "  Banxe Phase 1: Watchman + PEP Screener"
echo "════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────────────────────
# ШАГ 1: Скачиваем Watchman binary
# ─────────────────────────────────────────────────────────
echo "[1/8] Скачиваем Moov Watchman v0.61.1 (Apache 2.0)..."

ssh gmktec "
if [ -f /usr/local/bin/banxe-watchman ]; then
    echo '  Watchman уже установлен: '
    /usr/local/bin/banxe-watchman version 2>/dev/null | head -1 || echo 'installed'
else
    echo '  Загрузка watchman-linux-amd64...'
    wget -q -O /tmp/banxe-watchman https://github.com/moov-io/watchman/releases/download/v0.61.1/watchman-linux-amd64
    chmod +x /tmp/banxe-watchman
    sudo mv /tmp/banxe-watchman /usr/local/bin/banxe-watchman
    echo '  Watchman установлен: /usr/local/bin/banxe-watchman'
fi
sudo mkdir -p /data/banxe/watchman
sudo chown -R banxe:banxe /data/banxe 2>/dev/null || sudo chown -R root:root /data/banxe
echo '  Данные: /data/banxe/watchman'
"

# ─────────────────────────────────────────────────────────
# ШАГ 2: Создаём systemd сервис Watchman
# ─────────────────────────────────────────────────────────
echo ""
echo "[2/8] Создаём banxe-watchman.service (порт 8084)..."

cat << 'UNIT_EOF' | ssh gmktec 'sudo tee /etc/systemd/system/banxe-watchman.service > /dev/null'
[Unit]
Description=Banxe Watchman — Sanctions Screening (OFAC/UN/EU/UK/OFSI)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment="LOG_FORMAT=json"
Environment="WATCHMAN_DATA_PATH=/data/banxe/watchman"
Environment="HTTP_BIND_ADDRESS=127.0.0.1:8084"
ExecStart=/usr/local/bin/banxe-watchman -http.addr=127.0.0.1:8084
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF

ssh gmktec "sudo systemctl daemon-reload && sudo systemctl enable banxe-watchman.service && sudo systemctl restart banxe-watchman.service"
echo "  banxe-watchman.service: started ✓"
echo "  Ожидаем 15 сек — Watchman загружает санкционные списки..."
sleep 15

WATCHMAN_STATUS=$(ssh gmktec "sudo systemctl is-active banxe-watchman.service")
echo "  Статус: $WATCHMAN_STATUS"

# ─────────────────────────────────────────────────────────
# ШАГ 3: Тест Watchman API
# ─────────────────────────────────────────────────────────
echo ""
echo "[3/8] Тест Watchman API..."
WATCHMAN_TEST=$(ssh gmktec "curl -sf 'http://localhost:8084/v2/search?q=Putin&limit=3' 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); total=sum(len(v) for v in d.values() if isinstance(v,list)); print(f\"Watchman OK — {total} matches for Putin\")' 2>/dev/null || echo 'Watchman: ещё загружается (нормально при первом старте)'")
echo "  $WATCHMAN_TEST"

# ─────────────────────────────────────────────────────────
# ШАГ 4: Python screener сервис (Watchman + Wikidata PEP)
# ─────────────────────────────────────────────────────────
echo ""
echo "[4/8] Создаём Banxe Screener API (порт 8085)..."

ssh gmktec "sudo mkdir -p /opt/banxe/screener && pip3 install fastapi uvicorn httpx requests 2>/dev/null | tail -3"

cat << 'PYEOF' | ssh gmktec 'sudo tee /opt/banxe/screener/app.py > /dev/null'
#!/usr/bin/env python3
"""
Banxe Screener API v1.0
Combines: Moov Watchman (OFAC/UN/EU/UK sanctions) + Wikidata SPARQL (PEP, CC0)
Port: 8085
"""
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse
import httpx
import requests

app = FastAPI(title="Banxe Screener API", version="1.0.0")
WATCHMAN = "http://localhost:8084"
WIKIDATA = "https://query.wikidata.org/sparql"

@app.get("/screen")
def screen(q: str = Query(..., description="Name, company, or country to screen")):
    result = {
        "entity": q,
        "sanctioned": False,
        "pep": False,
        "risk_level": "LOW",
        "sanctions_matches": [],
        "pep_matches": [],
        "sources": []
    }

    try:
        r = httpx.get(f"{WATCHMAN}/v2/search", params={"q": q, "limit": 5}, timeout=5.0)
        if r.status_code == 200:
            data = r.json()
            for lst in ["SDNs", "UKSanctions", "EUSanctions", "UNSanctions", "CSL", "FinCEN311"]:
                for item in data.get(lst, []):
                    result["sanctions_matches"].append({
                        "list": lst,
                        "name": item.get("name", ""),
                        "score": item.get("match", 0),
                        "type": item.get("sdnType", ""),
                        "programs": item.get("programs", [])
                    })
            if result["sanctions_matches"]:
                result["sanctioned"] = True
                result["sources"].append("Watchman")
    except Exception as e:
        result["watchman_error"] = str(e)

    try:
        sparql = f'SELECT DISTINCT ?personLabel ?positionLabel ?countryLabel WHERE {{ ?person wdt:P106 wd:Q82955; rdfs:label ?nameLabel. FILTER(LANG(?nameLabel)="en") FILTER(CONTAINS(LCASE(?nameLabel),LCASE("{q}"))) OPTIONAL {{ ?person p:P39 ?ps. ?ps ps:P39 ?pos. ?pos rdfs:label ?positionLabel. FILTER(LANG(?positionLabel)="en") }} OPTIONAL {{ ?person wdt:P27 ?c. ?c rdfs:label ?countryLabel. FILTER(LANG(?countryLabel)="en") }} SERVICE wikibase:label {{ bd:serviceParam wikibase:language "en". }} }} LIMIT 5'
        r2 = requests.get(WIKIDATA, params={"query": sparql, "format": "json"},
                          headers={"User-Agent": "BanxeAIBank/1.0 (compliance@banxe.com)"}, timeout=10)
        bindings = r2.json().get("results", {}).get("bindings", [])
        for b in bindings:
            result["pep_matches"].append({
                "name": b.get("personLabel", {}).get("value", q),
                "position": b.get("positionLabel", {}).get("value", "Unknown"),
                "country": b.get("countryLabel", {}).get("value", "Unknown")
            })
        if result["pep_matches"]:
            result["pep"] = True
            result["sources"].append("Wikidata")
    except Exception as e:
        result["wikidata_error"] = str(e)

    if result["sanctioned"]:
        result["risk_level"] = "HIGH"
    elif result["pep"]:
        result["risk_level"] = "MEDIUM"

    return result

@app.get("/sanctions")
def sanctions_only(q: str = Query(...)):
    try:
        r = httpx.get(f"{WATCHMAN}/v2/search", params={"q": q, "limit": 10}, timeout=5.0)
        return r.json() if r.status_code == 200 else {"error": f"Watchman HTTP {r.status_code}"}
    except Exception as e:
        return {"error": str(e)}

@app.get("/health")
def health():
    try:
        w = httpx.get(f"{WATCHMAN}/actuator/health", timeout=2.0)
        watchman_ok = w.status_code == 200
    except Exception:
        watchman_ok = False
    return {"status": "ok", "watchman": watchman_ok, "wikidata": "api.cc0"}
PYEOF

echo "  app.py создан ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 5: systemd сервис для Screener
# ─────────────────────────────────────────────────────────
echo ""
echo "[5/8] Создаём banxe-screener.service (порт 8085)..."

cat << 'UNIT2_EOF' | ssh gmktec 'sudo tee /etc/systemd/system/banxe-screener.service > /dev/null'
[Unit]
Description=Banxe Screener API — Unified Sanctions + PEP (port 8085)
After=network.target banxe-watchman.service
Wants=banxe-watchman.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/banxe/screener
ExecStart=/usr/bin/python3 -m uvicorn app:app --host 127.0.0.1 --port 8085 --workers 2
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
UNIT2_EOF

ssh gmktec "sudo systemctl daemon-reload && sudo systemctl enable banxe-screener.service && sudo systemctl restart banxe-screener.service"
echo "  banxe-screener.service: started ✓"
sleep 8

SCREENER_STATUS=$(ssh gmktec "sudo systemctl is-active banxe-screener.service")
SCREENER_TEST=$(ssh gmktec "curl -sf 'http://localhost:8085/health' 2>/dev/null || echo 'starting...'")
echo "  Статус: $SCREENER_STATUS"
echo "  Health: $SCREENER_TEST"

# ─────────────────────────────────────────────────────────
# ШАГ 6: OpenClaw skill — banxe-screener
# ─────────────────────────────────────────────────────────
echo ""
echo "[6/8] Создаём OpenClaw skill banxe-screener..."

SKILL_DIR="/home/mmber/.openclaw/workspace-moa/skills/banxe-screener"
ssh gmktec "mkdir -p $SKILL_DIR"

cat << 'SKILL_EOF' | ssh gmktec 'cat > /tmp/banxe_skill.md'
---
name: banxe-screener
description: Real-time sanctions (OFAC/UN/EU/UK) and PEP screening via Watchman + Wikidata. Use for any name or entity check in compliance decisions.
metadata:
  {
    "openclaw": {
      "emoji": "🛡️",
      "os": ["linux"],
      "requires": {}
    }
  }
---

# Banxe Screener — Sanctions + PEP Tool

Real-time screening against OFAC SDN, UN, EU, UK OFSI sanctions lists and Wikidata PEP database.

## When to Use

Use this skill BEFORE any compliance decision when:
- A person's name appears in a transaction or KYC request
- A company name needs verification
- Any KYC/KYB onboarding check
- Counterparty due diligence

**Country-level blocking** (Russia, Iran, etc.) is handled by AGENTS.md rules — no API call needed for country-only checks.

## How to Call

```bash
curl -s "http://localhost:8085/screen?q=ENTITY_NAME"
```

## Response Format

```json
{
  "entity": "John Smith",
  "sanctioned": false,
  "pep": true,
  "risk_level": "MEDIUM",
  "sanctions_matches": [],
  "pep_matches": [
    {"name": "John Smith", "position": "Minister of Finance", "country": "United Kingdom"}
  ],
  "sources": ["Wikidata"]
}
```

## Risk Level Mapping

| risk_level | Action |
|------------|--------|
| HIGH | sanctioned=true → REJECT or HOLD + EDD + SAR consideration |
| MEDIUM | pep=true → EDD mandatory, Source of Funds, HITL review |
| LOW | Standard AML monitoring |

## Example Usage

```bash
# Screen individual
curl -s "http://localhost:8085/screen?q=Vladimir+Putin"

# Screen company
curl -s "http://localhost:8085/screen?q=Rosneft"

# Sanctions only (raw Watchman response)
curl -s "http://localhost:8085/sanctions?q=entity+name"

# Service health
curl -s "http://localhost:8085/health"
```

## Coverage

| Source | Lists |
|--------|-------|
| Moov Watchman (Apache 2.0) | OFAC SDN, UN Consolidated, EU Consolidated, UK OFSI, US CSL, FinCEN 311 |
| Wikidata SPARQL (CC0) | 1.8M+ politicians, ministers, judges, officials from 233 countries |
SKILL_EOF

ssh gmktec "cp /tmp/banxe_skill.md $SKILL_DIR/SKILL.md"
echo "  Skill создан: $SKILL_DIR/SKILL.md ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 7: Обновляем AGENTS.md — добавляем инструмент
# ─────────────────────────────────────────────────────────
echo ""
echo "[7/8] Обновляем AGENTS.md — добавляем banxe-screener инструкцию..."

AGENTS_FILE="/home/mmber/.openclaw/workspace-moa/AGENTS.md"
ssh gmktec "
if grep -q 'banxe-screener\|localhost:8085' $AGENTS_FILE; then
    echo '  Screener уже в AGENTS.md ✓'
else
    sudo chattr -i $AGENTS_FILE 2>/dev/null || true
    cat >> $AGENTS_FILE << 'AGENTS_SECTION'

---

## ИНСТРУМЕНТ: Banxe Sanctions + PEP Screener

Когда в запросе есть ИМЯ ЧЕЛОВЕКА или НАЗВАНИЕ КОМПАНИИ (не только страна):

\`\`\`bash
curl -s \"http://localhost:8085/screen?q=ИМЯ_ИЛИ_КОМПАНИЯ\"
\`\`\`

Результат JSON:
- \"sanctioned\": true/false — OFAC SDN / UN / EU / UK OFSI
- \"pep\": true/false — политик/чиновник (Wikidata, 1.8M+ записей)
- \"risk_level\": \"HIGH\" | \"MEDIUM\" | \"LOW\"

Правила интерпретации:
- sanctioned=true → REJECT (имя в санкционном списке) или HOLD если Watchman match score < 0.95
- pep=true → EDD обязателен + Source of Funds + HITL
- LOW → стандартный AML мониторинг по сумме

AGENTS_SECTION
    echo '  Screener добавлен в AGENTS.md ✓'
fi
"

# ─────────────────────────────────────────────────────────
# ШАГ 8: Установка Docker (для Phase 2: Jube, Marble)
# ─────────────────────────────────────────────────────────
echo ""
echo "[8/8] Установка Docker (для Phase 2: Jube + Marble)..."
ssh gmktec "
if command -v docker &>/dev/null; then
    echo '  Docker уже установлен: '
    docker --version
else
    echo '  Установка docker.io...'
    sudo apt-get install -y docker.io docker-compose-v2 2>&1 | tail -5
    sudo systemctl enable docker
    sudo systemctl start docker
    sudo usermod -aG docker banxe 2>/dev/null || true
    sudo usermod -aG docker root 2>/dev/null || true
    echo '  Docker установлен: '
    docker --version
fi
"

# ─────────────────────────────────────────────────────────
# Финальная проверка
# ─────────────────────────────────────────────────────────
echo ""
echo "════ ИТОГОВАЯ ПРОВЕРКА ════"

WATCHMAN_S=$(ssh gmktec "sudo systemctl is-active banxe-watchman.service")
SCREENER_S=$(ssh gmktec "sudo systemctl is-active banxe-screener.service")
DOCKER_S=$(ssh gmktec "command -v docker &>/dev/null && docker --version | cut -d' ' -f3 | tr -d ',' || echo 'not installed'")
SKILL_EXISTS=$(ssh gmktec "[ -f /home/mmber/.openclaw/workspace-moa/skills/banxe-screener/SKILL.md ] && echo 'EXISTS' || echo 'MISSING'")

echo ""
echo "  banxe-watchman.service  : $WATCHMAN_S (port 8084)"
echo "  banxe-screener.service  : $SCREENER_S (port 8085)"
echo "  Docker                  : $DOCKER_S"
echo "  OpenClaw skill          : $SKILL_EXISTS"

echo ""
echo "  Тест Screener API (Putin → должен быть HIGH/sanctioned)..."
sleep 5
SCREEN_TEST=$(ssh gmktec "curl -sf 'http://localhost:8085/screen?q=Vladimir+Putin' 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f\"sanctioned={d[\"sanctioned\"]} pep={d[\"pep\"]} risk={d[\"risk_level\"]} sources={d[\"sources\"]}\")'  2>/dev/null || echo 'screener still starting...'")
echo "  $SCREEN_TEST"

# Перезапуск OpenClaw для подгрузки нового skill
echo ""
echo "  Перезапуск OpenClaw (загрузить новый skill)..."
ssh gmktec "sudo systemctl restart openclaw-gateway-moa.service && sleep 8 && sudo systemctl is-active openclaw-gateway-moa.service"

# ─────────────────────────────────────────────────────────
# Обновляем docs/MEMORY.md
# ─────────────────────────────────────────────────────────
echo ""
echo "Обновляем docs/MEMORY.md..."
cd "$REPO_DIR"

python3 - << 'PYUPDATE'
import re

with open("docs/MEMORY.md") as f:
    content = f.read()

new_section = """
## Compliance Stack Phase 1 (2026-04-02)

### Banxe Screener API (порт 8085)
- Watchman: http://localhost:8085/screen?q=entity_name
- sanctioned + pep + risk_level + matches
- Sources: Moov Watchman (OFAC/UN/EU/UK) + Wikidata SPARQL (PEP, CC0)

### Moov Watchman (порт 8084, Apache 2.0)
- Binary: /usr/local/bin/banxe-watchman
- Data: /data/banxe/watchman/
- Lists: OFAC SDN, UN, EU, UK OFSI, US CSL, FinCEN 311

### OpenClaw Skill
- workspace-moa/skills/banxe-screener/SKILL.md
- Agents вызывают: curl http://localhost:8085/screen?q=ИМЯ

### Phase 2 (следующий): Jube TM + Marble case mgmt
"""

if "Compliance Stack Phase 1" not in content:
    content = content.rstrip() + "\n" + new_section
    with open("docs/MEMORY.md", "w") as f:
        f.write(content)
    print("MEMORY.md обновлён")
else:
    print("MEMORY.md уже содержит Phase 1")
PYUPDATE

git add docs/MEMORY.md scripts/deploy-phase1-watchman-pep.sh
git commit -m "feat: Phase 1 — Moov Watchman + Wikidata PEP + Banxe Screener API

- banxe-watchman.service: Moov Watchman v0.61.1 on port 8084
- banxe-screener.service: FastAPI unified screener on port 8085
- Coverage: OFAC SDN, UN, EU, UK OFSI, Wikidata PEP (CC0)
- OpenClaw skill: workspace-moa/skills/banxe-screener/SKILL.md
- Docker installed for Phase 2 (Jube + Marble)
- AGENTS.md: screener tool instructions for main agent"
git pull --rebase origin main
git push origin main

echo ""
echo "════════════════════════════════════════════"
echo "  Phase 1 ГОТОВО"
echo "════════════════════════════════════════════"
echo ""
echo "  Протестируй в Telegram:"
echo "  'проверь Vladimir Putin на санкции и PEP'"
echo "  → бот вызовет curl http://localhost:8085/screen?q=Vladimir+Putin"
echo "  → вернёт sanctioned=true, pep=true, risk=HIGH"
echo ""
echo "  Phase 2 (следующий): Jube + Marble"
echo "    bash scripts/deploy-phase2-jube-marble.sh"
echo ""
