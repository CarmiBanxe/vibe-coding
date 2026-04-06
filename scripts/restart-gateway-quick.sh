#!/bin/bash
###############################################################################
# restart-gateway-quick.sh — Быстрый перезапуск gateway + диагностика
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/restart-gateway-quick.sh
###############################################################################

echo "=========================================="
echo "  БЫСТРЫЙ ПЕРЕЗАПУСК GATEWAY"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export OLLAMA_API_KEY="ollama-local"

# Диагностика
echo "[1/3] Диагностика..."
echo "  Gateway:"
ss -tlnp | grep 18789 | head -1 | sed 's/^/    /' || echo "    НЕ СЛУШАЕТ"
echo "  Процессы:"
ps aux | grep -E "[o]penclaw" | awk '{print "    PID "$2": "$11" "$12}' | head -3
echo "  Ollama:"
curl -s --max-time 3 http://localhost:11434/api/tags | python3 -c "import sys,json; print(f'    ✓ {len(json.load(sys.stdin).get(\"models\",[]))} моделей')" 2>/dev/null || echo "    ✗ не отвечает"

# Перезапуск
echo ""
echo "[2/3] Перезапускаю..."
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 5

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa OLLAMA_API_KEY="ollama-local" nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 20 секунд..."
sleep 20

# Проверка
echo ""
echo "[3/3] Результат..."
if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ACTIVE"
else
    echo "  ✗ НЕ запустился"
fi

echo "  Модель:"
grep "agent model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

echo "  Telegram:"
grep "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -2 | sed 's/^/    /'

echo "  Ошибки:"
grep -iE "error|failed|unknown" /data/logs/gateway-moa.log 2>/dev/null | tail -3 | sed 's/^/    /'

REMOTE_END
