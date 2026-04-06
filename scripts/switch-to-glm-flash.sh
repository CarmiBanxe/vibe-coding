#!/bin/bash
###############################################################################
# switch-to-glm-flash.sh — Переключить на glm-4.7-flash (18GB)
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/switch-to-glm-flash.sh
###############################################################################

echo "=========================================="
echo "  ПЕРЕКЛЮЧЕНИЕ НА GLM-4.7-FLASH (18GB)"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export OLLAMA_API_KEY="ollama-local"

echo "[1/4] Останавливаю gateway..."
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

echo "[2/4] Переключаю модель..."
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa npx openclaw models set "ollama/huihui_ai/glm-4.7-flash-abliterated" 2>&1 | head -3 | sed 's/^/    /'

echo "  Прогреваю..."
RESP=$(curl -s --max-time 60 http://localhost:11434/api/generate -d '{
    "model": "huihui_ai/glm-4.7-flash-abliterated",
    "prompt": "Привет! Скажи одно предложение.",
    "stream": false,
    "options": {"num_predict": 20, "num_ctx": 4096}
}' 2>/dev/null)
echo "$RESP" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'  ✓ Ответ: {d.get(\"response\",\"?\")[:60]}')
except: print('  ✗ Нет ответа')
" 2>/dev/null

free -h | grep Mem | awk '{print "  RAM: " $3 " / " $2 " (free: " $4 ")"}'

echo ""
echo "[3/4] Запускаю gateway..."
OPENCLAW_HOME=/root/.openclaw-moa OLLAMA_API_KEY="ollama-local" nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 20 секунд..."
sleep 20

echo ""
echo "[4/4] Проверка..."
ss -tlnp | grep 18789 | head -1 | sed 's/^/  /' || echo "  НЕ СЛУШАЕТ"
grep "agent model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/  /'
grep "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -2 | sed 's/^/  /'
curl -s --max-time 10 http://localhost:11434/api/generate -d '{"model":"huihui_ai/glm-4.7-flash-abliterated","prompt":"test","stream":false,"options":{"num_predict":1}}' 2>/dev/null | python3 -c "import sys,json; print('  Ollama: ✓ OK')" 2>/dev/null || echo "  Ollama: ✗"
free -h | grep Mem | awk '{print "  RAM: " $3 " / " $2 " (free: " $4 ")"}'

REMOTE_END
