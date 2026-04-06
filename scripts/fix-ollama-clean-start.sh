#!/bin/bash
###############################################################################
# fix-ollama-clean-start.sh — Чистый старт: убить ВСЁ, очистить RAM, запустить
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-ollama-clean-start.sh
###############################################################################

echo "=========================================="
echo "  ЧИСТЫЙ СТАРТ: Ollama + Gateway"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

echo "[1/7] Убиваю ВСЁ..."
pkill -9 -f openclaw 2>/dev/null
pkill -9 -f ollama 2>/dev/null
pkill -9 -f "node.*openclaw" 2>/dev/null
sleep 5
echo "  ✓"

echo ""
echo "[2/7] Очищаю RAM..."
sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
sleep 2
free -h | grep Mem | awk '{print "  RAM: " $3 " / " $2 " (free: " $4 ")"}'

echo ""
echo "[3/7] Проверяю что Ollama сервис существует..."
systemctl status ollama --no-pager 2>&1 | head -5 | sed 's/^/    /'

echo ""
echo "[4/7] Запускаю Ollama..."
systemctl start ollama 2>/dev/null
echo "  Жду 15 секунд..."
sleep 15

OLLAMA_OK=$(curl -s --max-time 5 http://localhost:11434/api/tags 2>/dev/null)
if [ -n "$OLLAMA_OK" ]; then
    echo "  ✓ Ollama API отвечает"
else
    echo "  ✗ Ollama не отвечает. Статус:"
    systemctl status ollama --no-pager 2>&1 | head -10 | sed 's/^/    /'
    echo ""
    echo "  Журнал:"
    journalctl -u ollama --no-pager -n 10 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  Пробую запустить вручную..."
    OLLAMA_HOST=0.0.0.0:11434 nohup ollama serve > /data/logs/ollama-manual.log 2>&1 &
    sleep 10
    curl -s --max-time 5 http://localhost:11434/api/tags > /dev/null 2>&1 && echo "  ✓ Ollama запущена вручную" || echo "  ✗ Всё ещё не работает"
fi

echo ""
echo "[5/7] Загружаю модель..."
free -h | grep Mem | awk '{print "  RAM до загрузки: " $3 " / " $2 " (free: " $4 ")"}'

RESP=$(curl -s --max-time 120 http://localhost:11434/api/generate -d '{
    "model": "huihui_ai/qwen3.5-abliterated:35b",
    "prompt": "Привет! Скажи одно слово.",
    "stream": false,
    "options": {"num_predict": 10, "num_ctx": 4096}
}' 2>/dev/null)

if [ -n "$RESP" ]; then
    echo "$RESP" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    r = d.get('response','')
    print(f'  ✓ Ответ: {r[:50]}')
except:
    print('  ✗ JSON ошибка')
" 2>/dev/null
else
    echo "  ✗ Ollama не ответила за 120 секунд"
fi

free -h | grep Mem | awk '{print "  RAM после загрузки: " $3 " / " $2 " (free: " $4 ")"}'

echo ""
echo "[6/7] Запускаю gateway..."
export OLLAMA_API_KEY="ollama-local"
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa OLLAMA_API_KEY="ollama-local" nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 20 секунд..."
sleep 20

echo ""
echo "[7/7] Финальная проверка..."

echo "  Gateway:"
ss -tlnp | grep 18789 | head -1 | sed 's/^/    /' || echo "    НЕ СЛУШАЕТ"

echo "  Лог (последние 5 строк):"
tail -5 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'

echo "  Ollama:"
curl -s --max-time 10 http://localhost:11434/api/generate -d '{"model":"huihui_ai/qwen3.5-abliterated:35b","prompt":"test","stream":false,"options":{"num_predict":1}}' 2>/dev/null | python3 -c "import sys,json; print('    ✓ OK')" 2>/dev/null || echo "    ✗ НЕ ОТВЕЧАЕТ"

echo "  RAM:"
free -h | grep Mem | awk '{print "    " $3 " / " $2 " (free: " $4 ")"}'

REMOTE_END
