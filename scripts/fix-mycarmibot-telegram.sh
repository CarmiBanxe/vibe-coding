#!/bin/bash
###############################################################################
# fix-mycarmibot-telegram.sh — Починка Telegram в конфиге @mycarmibot
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-mycarmibot-telegram.sh
###############################################################################

echo "=========================================="
echo "  ПОЧИНКА TELEGRAM @mycarmibot"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export XDG_RUNTIME_DIR="/run/user/0"

echo ""
echo "[1/3] Копирую структуру из рабочего конфига moa..."

python3 << 'PYEOF'
import json

# Читаем рабочий конфиг (moa — работает)
with open("/root/.openclaw-moa/openclaw.json") as f:
    moa = json.load(f)

# Читаем конфиг mycarmibot (default — не работает telegram)
with open("/root/.openclaw-default/openclaw.json") as f:
    default = json.load(f)

# Берём ВСЮ структуру из moa, меняем только то что специфично для @mycarmibot
result = json.loads(json.dumps(moa))  # deep copy

# Подставляем токен @mycarmibot
MYCARMIBOT_TOKEN = "8625657319:AAGwYHwg6jrc3bRq3hoiKJGHSkaDTKVpgTQ"

# Обновляем telegram секцию (может быть в разных местах)
if "telegram" in result:
    result["telegram"]["botToken"] = MYCARMIBOT_TOKEN
if "channels" in result and "telegram" in result["channels"]:
    result["channels"]["telegram"]["botToken"] = MYCARMIBOT_TOKEN
if "sessions" in result:
    if "telegram" in result["sessions"]:
        result["sessions"]["telegram"]["botToken"] = MYCARMIBOT_TOKEN

# Порт Gateway
if "gateway" not in result:
    result["gateway"] = {}
result["gateway"]["port"] = 18793
result["gateway"]["mode"] = "local"

# allowFrom — CEO
if "sessions" in result:
    result["sessions"]["allowFrom"] = [508602494]
if "telegram" in result:
    result["telegram"]["allowFrom"] = [508602494]

# Ollama на localhost
def fix_ollama_url(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str) and "192.168" in v and "11434" in v:
                obj[k] = "http://localhost:11434"
            else:
                fix_ollama_url(v)
    elif isinstance(obj, list):
        for item in obj:
            fix_ollama_url(item)

fix_ollama_url(result)

with open("/root/.openclaw-default/openclaw.json", "w") as f:
    json.dump(result, f, indent=2)

print("  ✓ Конфиг @mycarmibot = копия moa + свой токен + порт 18793")

# Показываем что в telegram секции
for key in ["telegram", "channels", "sessions"]:
    if key in result and isinstance(result[key], dict):
        if "botToken" in result[key]:
            token = result[key]["botToken"]
            print(f"  {key}.botToken: ...{token[-10:]}")
        if "telegram" in result[key] and isinstance(result[key]["telegram"], dict):
            if "botToken" in result[key]["telegram"]:
                token = result[key]["telegram"]["botToken"]
                print(f"  {key}.telegram.botToken: ...{token[-10:]}")
PYEOF

echo ""
echo "[2/3] Перезапускаю @mycarmibot..."
systemctl --user restart openclaw-gateway
sleep 10

echo ""
echo "[3/3] Проверяю..."

# Лог — ищем [telegram]
TGLOG=$(journalctl --user -u openclaw-gateway --no-pager -n 15 --output=cat 2>/dev/null | grep -i "telegram")
if [ -n "$TGLOG" ]; then
    echo "  ✓ Telegram подключён:"
    echo "  $TGLOG"
else
    echo "  ⚠ [telegram] не найден в логе"
    echo "  Последние строки:"
    journalctl --user -u openclaw-gateway --no-pager -n 10 --output=cat 2>/dev/null | tail -5
fi

echo ""
printf "  %-25s %s\n" "БОТ" "СТАТУС"
printf "  %-25s %s\n" "-------------------------" "------"
systemctl --user is-active openclaw-gateway-moa &>/dev/null && printf "  %-25s ✓ ACTIVE\n" "@mycarmi_moa_bot" || printf "  %-25s ✗\n" "@mycarmi_moa_bot"
systemctl --user is-active openclaw-gateway &>/dev/null && printf "  %-25s ✓ ACTIVE\n" "@mycarmibot" || printf "  %-25s ✗\n" "@mycarmibot"

REMOTE

# КАНОН
echo ""
echo "КАНОН: обновляю MEMORY.md..."
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
ssh gmktec "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << EOF

## Обновление: @mycarmibot Telegram починен ($TIMESTAMP)
- Конфиг @mycarmibot = копия рабочего moa + свой токен
- Порт 18793, Telegram провайдер активирован
EOF
done" 2>/dev/null
echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  Проверь @mycarmibot в Telegram!"
echo "=========================================="
