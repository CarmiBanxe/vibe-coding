#!/bin/bash
###############################################################################
# check-bot-now.sh — Моментальная проверка: бот жив или нет
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/check-bot-now.sh
###############################################################################

ssh gmktec 'bash -s' << 'REMOTE_END'

echo "=== ПОРТ ==="
ss -tlnp | grep 18789 | head -1 || echo "НЕ СЛУШАЕТ"

echo ""
echo "=== ПОСЛЕДНИЕ 10 СТРОК ЛОГА ==="
tail -10 /data/logs/gateway-moa.log 2>/dev/null

echo ""
echo "=== TELEGRAM POLLING ==="
grep -E "polling|getUpdates|sendMessage|telegram.*error|telegram.*fail|channel exited" /data/logs/gateway-moa.log 2>/dev/null | tail -5

echo ""
echo "=== OLLAMA СЕЙЧАС ==="
curl -s --max-time 5 http://localhost:11434/api/generate -d '{"model":"huihui_ai/qwen3.5-abliterated:35b","prompt":"test","stream":false,"options":{"num_predict":1}}' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'OK: {d.get(\"response\",\"?\")}')" 2>/dev/null || echo "НЕ ОТВЕЧАЕТ"

REMOTE_END
