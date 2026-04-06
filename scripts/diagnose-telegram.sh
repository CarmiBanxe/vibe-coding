#!/bin/bash
###############################################################################
# diagnose-telegram.sh — Полная диагностика почему бот молчит
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/diagnose-telegram.sh
###############################################################################

echo "=========================================="
echo "  ДИАГНОСТИКА TELEGRAM"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

echo "[1] Порт 18789:"
ss -tlnp | grep 18789 | head -1 || echo "  НЕ СЛУШАЕТ"

echo ""
echo "[2] Полный лог gateway (последние 30 строк):"
tail -30 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'

echo ""
echo "[3] Telegram токен в конфиге:"
python3 -c "
import json
with open('/root/.openclaw-moa/.openclaw/openclaw.json') as f:
    c = json.load(f)
ch = c.get('channels',{})
if isinstance(ch, dict) and 'telegram' in ch:
    tg = ch['telegram']
    print(f'  botToken: {tg.get(\"botToken\",\"НЕТ\")[:25]}...')
    print(f'  enabled: {tg.get(\"enabled\",\"?\")}')
    print(f'  dmPolicy: {tg.get(\"dmPolicy\",\"?\")}')
    print(f'  allowFrom: {tg.get(\"allowFrom\",\"?\")}')
elif isinstance(ch, list):
    print(f'  channels как список: {len(ch)} элементов')
    for item in ch:
        if isinstance(item, dict):
            print(f'    botToken: {item.get(\"botToken\",\"НЕТ\")[:25]}...')
else:
    print(f'  channels: {type(ch).__name__} = {str(ch)[:100]}')
" 2>/dev/null

echo ""
echo "[4] Тест Telegram API:"
TOKEN=$(python3 -c "
import json
with open('/root/.openclaw-moa/.openclaw/openclaw.json') as f:
    c = json.load(f)
ch = c.get('channels',{})
if isinstance(ch, dict) and 'telegram' in ch:
    print(ch['telegram'].get('botToken',''))
elif isinstance(ch, list):
    for item in ch:
        if isinstance(item, dict) and item.get('botToken'):
            print(item['botToken'])
            break
" 2>/dev/null)

if [ -n "$TOKEN" ]; then
    RESULT=$(curl -s "https://api.telegram.org/bot${TOKEN}/getMe")
    echo "  $RESULT"
else
    echo "  Токен не найден в конфиге!"
fi

echo ""
echo "[5] Ollama отвечает?"
RESP=$(curl -s --max-time 10 http://localhost:11434/api/generate -d '{"model":"huihui_ai/qwen3.5-abliterated:35b","prompt":"Say hello","stream":false,"options":{"num_predict":5}}' 2>/dev/null)
echo "  $(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response','ПУСТО')[:50])" 2>/dev/null || echo "Нет ответа")"

echo ""
echo "[6] RAM и нагрузка:"
free -h | grep Mem | awk '{print "  RAM: " $3 " / " $2 " (free: " $4 ")"}'
echo "  Load: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"

REMOTE_END
