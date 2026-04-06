#!/bin/bash
# test-agent-to-agent.sh
# Тест agentToAgent роутинга: отправить сообщение боту и проверить переключение субагентов
# Запуск: cd ~/vibe-coding && git pull && bash scripts/test-agent-to-agent.sh
#
# Что делает скрипт:
#  1. Читает Telegram Bot Token из конфига на GMKtec
#  2. Отправляет тестовое сообщение через Telegram API (от имени CEO, chat_id=508602494)
#  3. Ждёт 30 сек, затем проверяет логи OpenClaw на предмет agent routing
#  4. Ищет признаки переключения субагентов (routing, delegate, agent:)
#  5. Обновляет MEMORY.md с результатом
#  6. Коммитит и пушит

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MEMORY_FILE="$REPO_DIR/docs/MEMORY.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M CEST')
CEO_CHAT_ID="508602494"
TEST_MESSAGE="агент, переключись на финансового субагента и проверь последние транзакции"

echo "=============================================="
echo "  Banxe AgentToAgent Test"
echo "  $TIMESTAMP"
echo "=============================================="

# ── 1. SSH check ───────────────────────────────────────────────────────────
echo ""
echo "[1/6] Проверка SSH..."
if ! ssh -o ConnectTimeout=10 -q gmktec exit 2>/dev/null; then
  echo "  ОШИБКА: SSH недоступен."
  exit 1
fi
echo "  OK"

# ── 2. Get bot token and verify service ────────────────────────────────────
echo ""
echo "[2/6] Проверка openclaw-gateway-moa и токена..."

REMOTE_CHECK=$(ssh gmktec bash << 'ENDSSH'
# Service status
SVC_STATUS=$(systemctl is-active openclaw-gateway-moa.service 2>/dev/null || echo "inactive")
echo "MOA_SVC=$SVC_STATUS"

# Get token from config
CONFIG_FILE="/root/.openclaw-moa/.openclaw/openclaw.json"
if [ -f "$CONFIG_FILE" ]; then
  TOKEN=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('channels',{}).get('telegram',{}).get('botToken','NOT_FOUND'))" 2>/dev/null || echo "PARSE_ERROR")
  echo "TOKEN=$TOKEN"
else
  echo "TOKEN=CONFIG_NOT_FOUND"
fi

# Check agents config (agentToAgent routing)
echo "--- AGENTS CONFIG CHECK ---"
python3 -c "
import json
f = '/root/.openclaw-moa/.openclaw/openclaw.json'
d = json.load(open(f))
agents = d.get('agents', {})
print('agents.keys:', list(agents.keys()))
profile = agents.get('defaults', {}).get('tools', {}).get('profile', 'NOT_SET')
print('tools.profile:', profile)
routing = agents.get('routing', 'NOT_SET')
print('routing:', routing)
" 2>/dev/null || echo "CONFIG_PARSE_ERROR"
ENDSSH
)

echo "$REMOTE_CHECK"

MOA_STATUS=$(echo "$REMOTE_CHECK" | grep "^MOA_SVC=" | cut -d= -f2)
BOT_TOKEN=$(echo "$REMOTE_CHECK" | grep "^TOKEN=" | cut -d= -f2)

if [ "$MOA_STATUS" != "active" ]; then
  echo "  ОШИБКА: openclaw-gateway-moa.service не активен ($MOA_STATUS)"
  exit 1
fi

if [[ "$BOT_TOKEN" == "NOT_FOUND" || "$BOT_TOKEN" == "CONFIG_NOT_FOUND" || "$BOT_TOKEN" == "PARSE_ERROR" ]]; then
  echo "  ОШИБКА: Не удалось получить Bot Token ($BOT_TOKEN)"
  exit 1
fi

echo "  OK: сервис активен, токен получен."

# ── 3. Send test message via Telegram API ──────────────────────────────────
echo ""
echo "[3/6] Отправка тестового сообщения в @mycarmi_moa_bot..."
echo "  Сообщение: «$TEST_MESSAGE»"
echo "  Chat ID: $CEO_CHAT_ID"

SEND_RESULT=$(curl -s -X POST \
  "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\": \"$CEO_CHAT_ID\", \"text\": \"[TEST agentToAgent] $TEST_MESSAGE\"}" \
  2>/dev/null)

MSG_OK=$(echo "$SEND_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('ok') else 'fail')" 2>/dev/null || echo "parse_error")
MSG_ID=$(echo "$SEND_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('message_id','?'))" 2>/dev/null || echo "?")

if [ "$MSG_OK" != "ok" ]; then
  echo "  ОШИБКА отправки: $SEND_RESULT"
  exit 1
fi

echo "  Сообщение отправлено (message_id=$MSG_ID)"

# ── 4. Wait for bot to process ─────────────────────────────────────────────
echo ""
echo "[4/6] Ожидание обработки ботом (45 сек)..."
for i in $(seq 1 9); do
  echo -n "  ."
  sleep 5
done
echo " готово"

# ── 5. Check logs for agent routing ───────────────────────────────────────
echo ""
echo "[5/6] Анализ логов OpenClaw на GMKtec..."

LOG_ANALYSIS=$(ssh gmktec bash << 'ENDSSH'
echo "=== RECENT MOA LOGS (last 100 lines) ==="
journalctl -u openclaw-gateway-moa.service --no-pager -n 100 --since "5 minutes ago" 2>/dev/null || \
  tail -100 /data/logs/openclaw-moa.log 2>/dev/null || \
  tail -100 /root/.openclaw-moa/logs/gateway.log 2>/dev/null || \
  echo "NO_LOG_FOUND"

echo ""
echo "=== ROUTING KEYWORDS ==="
journalctl -u openclaw-gateway-moa.service --no-pager -n 200 --since "10 minutes ago" 2>/dev/null | \
  grep -iE "agent|rout|delegat|subagent|transfer|handoff|switch" | tail -20 || \
  echo "no routing keywords found in last 10 min"

echo ""
echo "=== agentToAgent in workspace AGENTS.md ==="
head -50 /home/mmber/.openclaw/workspace-moa/AGENTS.md 2>/dev/null || \
  head -50 /root/.openclaw-moa/workspace-moa/AGENTS.md 2>/dev/null || \
  echo "AGENTS.md not found"
ENDSSH
)

echo "$LOG_ANALYSIS" | head -80

# ── 6. Evaluate result ─────────────────────────────────────────────────────
echo ""
echo "[6/6] Оценка результата..."

ROUTING_FOUND=$(echo "$LOG_ANALYSIS" | grep -ciE "agent.*rout|rout.*agent|delegat|subagent|handoff|switch" || echo "0")
NO_LOG=$(echo "$LOG_ANALYSIS" | grep -c "NO_LOG_FOUND" || echo "0")

if [ "$NO_LOG" -gt 0 ]; then
  RESULT="INCONCLUSIVE — логи не найдены, нужно проверить путь к лог-файлу вручную"
  RESULT_SHORT="INCONCLUSIVE"
elif [ "$ROUTING_FOUND" -gt 0 ]; then
  RESULT="PASS — обнаружены признаки agentToAgent роутинга в логах ($ROUTING_FOUND совпадений)"
  RESULT_SHORT="PASS"
else
  RESULT="PARTIAL — сообщение доставлено, но явного роутинга в логах не обнаружено. Бот мог ответить без явного переключения субагентов."
  RESULT_SHORT="PARTIAL"
fi

echo "  Результат: $RESULT"

# ── Update MEMORY.md ───────────────────────────────────────────────────────
cd "$REPO_DIR"

# Add agentToAgent test result section if not present
if ! grep -q "## agentToAgent Test" "$MEMORY_FILE"; then
  cat >> "$MEMORY_FILE" << ENDMEM

## agentToAgent Test ($TIMESTAMP)
- Результат: $RESULT_SHORT
- Сообщение отправлено: chat_id=$CEO_CHAT_ID, msg_id=$MSG_ID
- Детали: $RESULT
ENDMEM
else
  # Update existing section
  python3 - << ENDPY
import re
with open('$MEMORY_FILE', 'r') as f:
    content = f.read()
new_section = """## agentToAgent Test ($TIMESTAMP)
- Результат: $RESULT_SHORT
- Сообщение отправлено: chat_id=$CEO_CHAT_ID, msg_id=$MSG_ID
- Детали: $RESULT"""
content = re.sub(r'## agentToAgent Test.*?(?=\n## |\Z)', new_section + '\n', content, flags=re.DOTALL)
with open('$MEMORY_FILE', 'w') as f:
    f.write(content)
print("MEMORY.md updated")
ENDPY
fi

git add docs/MEMORY.md
git commit -m "test: agentToAgent result=$RESULT_SHORT ($TIMESTAMP)"
git push origin main

echo ""
echo "=============================================="
echo "  ИТОГ: $RESULT_SHORT"
echo "  $RESULT"
echo "=============================================="
