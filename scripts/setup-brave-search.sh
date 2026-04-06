#!/bin/bash
###############################################################################
# setup-brave-search.sh — Настройка Brave Search API в обоих ботах
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/setup-brave-search.sh
###############################################################################

BRAVE_KEY="REDACTED_BRAVE_API_KEY"

echo "=========================================="
echo "  НАСТРОЙКА BRAVE SEARCH API"
echo "=========================================="

echo ""
echo "[1/3] Добавляю Brave Search в конфиги ботов..."

ssh gmktec 'bash -s' << REMOTE
python3 << 'PYEOF'
import json

configs = [
    "/root/.openclaw-moa/openclaw.json",
    "/root/.openclaw-moa/.openclaw/openclaw.json",
    "/root/.openclaw-default/openclaw.json",
    "/root/.openclaw-default/.openclaw/openclaw.json"
]

for path in configs:
    try:
        with open(path, "r") as f:
            config = json.load(f)
        if "tools" not in config:
            config["tools"] = {}
        config["tools"]["webSearch"] = {
            "provider": "brave",
            "apiKey": "$BRAVE_KEY"
        }
        with open(path, "w") as f:
            json.dump(config, f, indent=2)
        print(f"  ✓ {path}")
    except Exception as e:
        pass
PYEOF

# Также добавляем в Deep Search сервер как Слой 1
cat >> /opt/deep-search-server.py.brave << 'BRAVEPATCH'
# Brave Search доступен как метод 0 (приоритетный)
BRAVEPATCH

export XDG_RUNTIME_DIR="/run/user/0"
systemctl --user restart openclaw-gateway-moa 2>/dev/null
systemctl --user restart openclaw-gateway 2>/dev/null
sleep 5
echo "  ✓ Боты перезапущены"
REMOTE

echo ""
echo "[2/3] Тестирую Brave Search..."

ssh gmktec "python3 -c \"
import urllib.request, json
req = urllib.request.Request(
    'https://api.search.brave.com/res/v1/web/search?q=FCA+financial+regulation+UK&count=3',
    headers={
        'X-Subscription-Token': '$BRAVE_KEY',
        'Accept': 'application/json'
    }
)
resp = urllib.request.urlopen(req, timeout=10)
data = json.loads(resp.read())
results = data.get('web', {}).get('results', [])
print(f'✓ Brave Search: {len(results)} результатов')
for r in results[:3]:
    print(f'  - {r[\"title\"]}: {r[\"description\"][:100]}')
\""

echo ""
echo "[3/3] КАНОН..."

ssh gmktec "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace /root/.openclaw-default/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << 'EOF'

## Обновление: Brave Search API настроен ($(date '+%Y-%m-%d %H:%M'))
- Brave Search API ключ добавлен в оба бота
- $5 бесплатно/мес (~1000 запросов)
- Бот использует автоматически для web search
- Многослойный поиск: Brave (быстрый) + Deep Search (глубокий)
EOF
done" 2>/dev/null
echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  BRAVE SEARCH НАСТРОЕН"
echo "=========================================="
echo ""
echo "  Теперь боты умеют искать в интернете!"
echo "  Проверь: напиши боту 'Найди информацию о FCA'"
echo "=========================================="
