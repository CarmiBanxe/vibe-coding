#!/bin/bash
###############################################################################
# fix-ollama-full.sh — Полная починка Ollama + gateway
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-ollama-full.sh
###############################################################################

echo "=========================================="
echo "  ПОЛНАЯ ПОЧИНКА OLLAMA"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

echo "[1/6] Убиваю ВСЁ (gateway + ollama)..."
pkill -9 -f "openclaw.*gateway" 2>/dev/null
pkill -9 -f ollama 2>/dev/null
sleep 5
echo "  ✓ Всё убито"

echo ""
echo "[2/6] RAM:"
free -h | grep Mem | awk '{print "  " $3 " / " $2 " (free: " $4 ")"}'

echo ""
echo "[3/6] Запускаю Ollama..."
systemctl start ollama 2>/dev/null
sleep 10

# Проверяем
if curl -s --max-time 5 http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "  ✓ Ollama запущена"
    curl -s http://localhost:11434/api/tags | python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d.get('models',[]):
    print(f'    {m[\"name\"]} ({m[\"size\"]/1024**3:.1f}GB)')
" 2>/dev/null
else
    echo "  ✗ Ollama не отвечает после systemctl start"
    echo "  Пробую напрямую..."
    nohup ollama serve > /data/logs/ollama.log 2>&1 &
    sleep 10
    curl -s --max-time 5 http://localhost:11434/api/tags > /dev/null 2>&1 && echo "  ✓ Ollama запущена (напрямую)" || echo "  ✗ Ollama не работает"
fi

echo ""
echo "[4/6] Прогреваю модель..."
RESP=$(curl -s --max-time 60 http://localhost:11434/api/generate -d '{
    "model": "huihui_ai/qwen3.5-abliterated:35b",
    "prompt": "Say hello in Russian",
    "stream": false,
    "options": {"num_predict": 10, "num_ctx": 8192}
}' 2>/dev/null)

echo "$RESP" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'  ✓ Ответ: {d.get(\"response\",\"ПУСТО\")[:50]}')
    dur = d.get('eval_duration',1)
    count = d.get('eval_count',0)
    if dur > 0:
        print(f'  Скорость: {count/(dur/1e9):.1f} tok/s')
except Exception as e:
    print(f'  ✗ Ошибка: {e}')
" 2>/dev/null

echo ""
echo "[5/6] Запускаю gateway..."
export OLLAMA_API_KEY="ollama-local"
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa OLLAMA_API_KEY="ollama-local" nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 20 секунд..."
sleep 20

echo ""
echo "[6/6] Результат..."

echo "  Gateway:"
ss -tlnp | grep 18789 | head -1 | sed 's/^/    /' || echo "    НЕ СЛУШАЕТ"

echo "  Модель:"
grep "agent model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

echo "  Telegram:"
grep "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -3 | sed 's/^/    /'

echo "  Ошибки:"
grep -iE "error|failed" /data/logs/gateway-moa.log 2>/dev/null | grep -v "xai-auth" | tail -3 | sed 's/^/    /'

echo ""
echo "  RAM:"
free -h | grep Mem | awk '{print "  " $3 " / " $2 " (free: " $4 ")"}'

echo ""
echo "  Ollama тест:"
curl -s --max-time 10 http://localhost:11434/api/generate -d '{"model":"huihui_ai/qwen3.5-abliterated:35b","prompt":"test","stream":false,"options":{"num_predict":1}}' 2>/dev/null | python3 -c "import sys,json; print(f'  ✓ OK')" 2>/dev/null || echo "  ✗ НЕ ОТВЕЧАЕТ"

REMOTE_END

echo ""
echo "=========================================="
echo "  Напиши @mycarmi_moa_bot: Привет"
echo "=========================================="
