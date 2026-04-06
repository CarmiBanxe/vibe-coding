#!/bin/bash
###############################################################################
# restart-gateway-ollama.sh — Перезапуск gateway после смены модели на Ollama
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/restart-gateway-ollama.sh
###############################################################################

echo "=========================================="
echo "  ПЕРЕЗАПУСК GATEWAY (Ollama)"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

echo "[1/3] Убиваю старый gateway..."
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 5
echo "  ✓ Остановлен"

echo ""
echo "[2/3] Запускаю gateway..."
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 15 секунд..."
sleep 15

echo ""
echo "[3/3] Проверяю..."

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ACTIVE (порт 18789)"
else
    echo "  ✗ Не запустился"
    tail -10 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'
fi

echo ""
echo "  Модель:"
grep "agent model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

echo ""
echo "  Telegram:"
grep "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -3 | sed 's/^/    /'

echo ""
echo "  Порты:"
ss -tlnp | grep -E "1878|1879" | while read line; do echo "    $line"; done

# Запускаем mycarmibot тоже
if ! ss -tlnp | grep -q ":18793 "; then
    echo ""
    echo "  Запускаю @mycarmibot..."
    cd /root/.openclaw-default
    OPENCLAW_HOME=/root/.openclaw-default nohup npx openclaw gateway --port 18793 > /data/logs/gateway-mycarmibot.log 2>&1 &
    sleep 10
    ss -tlnp | grep -q ":18793 " && echo "  ✓ @mycarmibot ACTIVE" || echo "  ⚠ Не запустился"
fi

REMOTE_END

echo ""
echo "=========================================="
echo "  Проверь: напиши @mycarmi_moa_bot Привет"
echo "=========================================="
