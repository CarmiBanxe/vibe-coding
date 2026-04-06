#!/bin/bash
###############################################################################
# fix-telegram-final.sh — Финальная починка Telegram бота
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-telegram-final.sh
###############################################################################

echo "=========================================="
echo "  ФИНАЛЬНАЯ ПОЧИНКА TELEGRAM"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

NEW_TOKEN="8793039199:AAGj2RrwI1ShQlNbKCsXl3IMpbs3hWMTPAo"

# 1. Убиваем всё
echo "[1/5] Останавливаю всё..."
pkill -9 -f openclaw 2>/dev/null
sleep 5
echo "  ✓ Остановлено"

# 2. Обновляем токен во ВСЕХ конфигах
echo "[2/5] Обновляю токен во всех файлах..."
find /root/.openclaw-moa -name "openclaw.json" -not -path "*/node_modules/*" | while read f; do
    python3 -c "
import json
try:
    with open('$f') as fh:
        c = json.load(fh)
    ch = c.get('channels', {})
    if isinstance(ch, dict) and 'telegram' in ch:
        c['channels']['telegram']['botToken'] = '$NEW_TOKEN'
    elif isinstance(ch, list):
        for item in ch:
            if isinstance(item, dict) and 'botToken' in item:
                item['botToken'] = '$NEW_TOKEN'
    with open('$f', 'w') as fh:
        json.dump(c, fh, indent=2, ensure_ascii=False)
    print(f'  ✓ $f')
except Exception as e:
    print(f'  ✗ $f: {e}')
" 2>/dev/null
done

# 3. Проверяем токен
echo "[3/5] Проверяю токен..."
RESULT=$(curl -s "https://api.telegram.org/bot${NEW_TOKEN}/getMe" | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if d.get('ok') else 'FAIL: ' + d.get('description','?'))" 2>/dev/null)
echo "  Telegram API: $RESULT"

# 4. Запускаем gateway
echo "[4/5] Запускаю gateway..."
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
GWPID=$!
echo "  PID: $GWPID"
echo "  Жду 20 секунд..."
sleep 20

# 5. Проверяем
echo "[5/5] Проверяю..."
echo ""

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ACTIVE (порт 18789)"
else
    echo "  ✗ Gateway не слушает порт 18789"
fi

echo ""
echo "  Telegram лог:"
grep -i "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -5 | sed 's/^/    /'

echo ""
if grep -q "polling started\|getUpdates\|[telegram] \[default\] listening" /data/logs/gateway-moa.log 2>/dev/null; then
    echo "  ✓ TELEGRAM РАБОТАЕТ!"
elif grep -q "401" /data/logs/gateway-moa.log 2>/dev/null; then
    echo "  ✗ Всё ещё 401"
    echo "  Токен в .openclaw/openclaw.json:"
    python3 -c "import json; c=json.load(open('/root/.openclaw-moa/.openclaw/openclaw.json')); print('  ', c.get('channels',{}).get('telegram',{}).get('botToken','НЕТ')[:25])" 2>/dev/null
    echo "  Токен в openclaw.json:"
    python3 -c "import json; c=json.load(open('/root/.openclaw-moa/openclaw.json')); print('  ', c.get('channels',{}).get('telegram',{}).get('botToken','НЕТ')[:25])" 2>/dev/null
else
    echo "  ? Статус неясен"
fi

REMOTE_END

echo ""
echo "=========================================="
echo "  Проверь: напиши @mycarmi_moa_bot Привет"
echo "=========================================="
