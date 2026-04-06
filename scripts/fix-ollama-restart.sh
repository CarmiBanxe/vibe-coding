#!/bin/bash
###############################################################################
# fix-ollama-restart.sh — Перезапуск Ollama + освобождение RAM
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-ollama-restart.sh
###############################################################################

echo "=========================================="
echo "  ПЕРЕЗАПУСК OLLAMA + ОСВОБОЖДЕНИЕ RAM"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

echo "[1/5] Текущее состояние RAM:"
free -h | grep Mem | awk '{print "  RAM: " $3 " / " $2 " (free: " $4 ")"}'

echo ""
echo "[2/5] Перезапускаю Ollama..."
systemctl restart ollama 2>/dev/null || { pkill -f ollama; sleep 3; ollama serve &>/dev/null & }
sleep 10

echo "  RAM после перезапуска Ollama:"
free -h | grep Mem | awk '{print "  RAM: " $3 " / " $2 " (free: " $4 ")"}'

echo ""
echo "[3/5] Загружаю модель qwen3.5:35b..."
# Прогрев модели — загружаем в GPU память
curl -s --max-time 60 http://localhost:11434/api/generate -d '{
    "model": "huihui_ai/qwen3.5-abliterated:35b",
    "prompt": "Hello",
    "stream": false,
    "options": {"num_predict": 5, "num_ctx": 16384}
}' | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'  ✓ Модель ответила: {d.get(\"response\",\"?\")[:30]}')
    print(f'  Токенов: {d.get(\"eval_count\",0)}, скорость: {d.get(\"eval_count\",0)/(d.get(\"eval_duration\",1)/1e9):.1f} tok/s')
except:
    print('  ✗ Модель не ответила')
" 2>/dev/null

echo ""
echo "  RAM после загрузки модели:"
free -h | grep Mem | awk '{print "  RAM: " $3 " / " $2 " (free: " $4 ")"}'

echo ""
echo "[4/5] Перезапускаю gateway..."
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

export OLLAMA_API_KEY="ollama-local"
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa OLLAMA_API_KEY="ollama-local" nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 15 секунд..."
sleep 15

echo ""
echo "[5/5] Проверка..."

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ACTIVE"
else
    echo "  ✗ Gateway не запустился"
fi

echo ""
echo "  Модель:"
grep "agent model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

echo "  Telegram:"
grep "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -2 | sed 's/^/    /'

echo "  Ошибки:"
grep -iE "error|failed|unknown" /data/logs/gateway-moa.log 2>/dev/null | grep -v "xai-auth" | tail -3 | sed 's/^/    /'

echo ""
echo "  RAM финал:"
free -h | grep Mem | awk '{print "  RAM: " $3 " / " $2 " (free: " $4 ")"}'

REMOTE_END
