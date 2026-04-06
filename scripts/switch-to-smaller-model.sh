#!/bin/bash
###############################################################################
# switch-to-smaller-model.sh — Переключить на gpt-oss:20b (15GB вместо 22GB)
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/switch-to-smaller-model.sh
#
# Проблема: qwen3.5:35b (22GB) + все сервисы = не хватает 30GB RAM
# Решение: gpt-oss:20b (15GB) — освобождает 7GB RAM, бот стабильно работает
###############################################################################

echo "=========================================="
echo "  ПЕРЕКЛЮЧЕНИЕ НА МЕНЬШУЮ МОДЕЛЬ"
echo "  gpt-oss:20b (15GB вместо 22GB)"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export OLLAMA_API_KEY="ollama-local"

echo "[1/5] Убиваю всё, очищаю RAM..."
pkill -9 -f openclaw 2>/dev/null
pkill -9 -f ollama 2>/dev/null
sleep 5
sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
sleep 2
free -h | grep Mem | awk '{print "  RAM: " $3 " / " $2 " (free: " $4 ")"}'

echo ""
echo "[2/5] Запускаю Ollama..."
systemctl start ollama 2>/dev/null
sleep 10
curl -s --max-time 5 http://localhost:11434/api/tags > /dev/null 2>&1 && echo "  ✓ Ollama OK" || echo "  ✗ Ollama не отвечает"

echo ""
echo "[3/5] Переключаю модель на gpt-oss:20b..."
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa npx openclaw models set "ollama/gurubot/gpt-oss-derestricted:20b" 2>&1 | head -3 | sed 's/^/    /'

# Прогреваем
echo "  Прогреваю модель..."
RESP=$(curl -s --max-time 60 http://localhost:11434/api/generate -d '{
    "model": "gurubot/gpt-oss-derestricted:20b",
    "prompt": "Привет! Ответь одним предложением.",
    "stream": false,
    "options": {"num_predict": 20, "num_ctx": 4096}
}' 2>/dev/null)

echo "$RESP" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'  ✓ Ответ: {d.get(\"response\",\"?\")[:60]}')
    dur=d.get('eval_duration',1)
    cnt=d.get('eval_count',0)
    if dur > 0: print(f'  Скорость: {cnt/(dur/1e9):.1f} tok/s')
except:
    print('  ✗ Нет ответа')
" 2>/dev/null

free -h | grep Mem | awk '{print "  RAM после загрузки: " $3 " / " $2 " (free: " $4 ")"}'

echo ""
echo "[4/5] Запускаю gateway..."
OPENCLAW_HOME=/root/.openclaw-moa OLLAMA_API_KEY="ollama-local" nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 20 секунд..."
sleep 20

echo ""
echo "[5/5] Проверка..."
echo "  Gateway:"
ss -tlnp | grep 18789 | head -1 | sed 's/^/    /' || echo "    НЕ СЛУШАЕТ"

echo "  Модель:"
grep "agent model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

echo "  Telegram:"
grep "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -2 | sed 's/^/    /'

echo "  Ollama:"
curl -s --max-time 10 http://localhost:11434/api/generate -d '{"model":"gurubot/gpt-oss-derestricted:20b","prompt":"test","stream":false,"options":{"num_predict":1}}' 2>/dev/null | python3 -c "import sys,json; print('    ✓ OK')" 2>/dev/null || echo "    ✗ НЕ ОТВЕЧАЕТ"

echo "  RAM:"
free -h | grep Mem | awk '{print "    " $3 " / " $2 " (free: " $4 ")"}'

REMOTE_END

echo ""
echo "=========================================="
echo "  Модель: gpt-oss:20b (15GB, экономит 7GB RAM)"
echo "  Напиши @mycarmi_moa_bot: Привет"
echo ""
echo "  Вернуть qwen3.5:35b позже когда разберёмся с RAM"
echo "=========================================="
