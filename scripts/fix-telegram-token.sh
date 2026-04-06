#!/bin/bash
###############################################################################
# fix-telegram-token.sh — Обновление Telegram токена и перезапуск
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-telegram-token.sh
###############################################################################

echo "=========================================="
echo "  ОБНОВЛЕНИЕ TELEGRAM ТОКЕНА"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

NEW_TOKEN="8793039199:AAHo8zr7ksY5jBsX0x1KLCRT1KHHltvcYF8"

# 1. Убиваем ВСЕ процессы openclaw
echo "[1/4] Убиваю все gateway..."
pkill -9 -f openclaw 2>/dev/null
sleep 5
echo "  ✓ Все процессы убиты"

# 2. Обновляем токен в конфиге
echo "[2/4] Обновляю токен..."
python3 << PYFIX
import json

cfg_path = "/root/.openclaw-moa/.openclaw/openclaw.json"
with open(cfg_path) as f:
    cfg = json.load(f)

# Обновляем botToken
cfg["channels"]["telegram"]["botToken"] = "$NEW_TOKEN"

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

# Проверяем
with open(cfg_path) as f:
    cfg2 = json.load(f)
actual = cfg2["channels"]["telegram"]["botToken"]
print(f"  Токен в файле: {actual[:20]}...")
if actual == "$NEW_TOKEN":
    print("  ✓ Совпадает с новым")
else:
    print("  ✗ НЕ совпадает!")
PYFIX

# 3. Проверяем токен через Telegram API
echo "[3/4] Проверяю токен через Telegram API..."
RESULT=$(curl -s "https://api.telegram.org/bot${NEW_TOKEN}/getMe")
echo "  $RESULT"

# 4. Запускаем gateway
echo "[4/4] Запускаю gateway..."
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 15 секунд..."
sleep 15

echo ""
echo "  Порт 18789:"
ss -tlnp | grep 18789 | head -1

echo ""
echo "  Лог Telegram:"
tail -10 /data/logs/gateway-moa.log | grep -i telegram | tail -3

echo ""
if tail -10 /data/logs/gateway-moa.log | grep -q "polling started\|listening\|connected"; then
    echo "  ✓ TELEGRAM РАБОТАЕТ!"
elif tail -10 /data/logs/gateway-moa.log | grep -q "401"; then
    echo "  ✗ Всё ещё 401 — токен не подхватился"
else
    echo "  ? Статус неясен — проверь бота в Telegram"
fi

REMOTE_END

echo ""
echo "=========================================="
echo "  Проверь: напиши @mycarmi_moa_bot Привет"
echo "=========================================="
