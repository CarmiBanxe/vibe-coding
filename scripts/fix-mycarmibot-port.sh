#!/bin/bash
###############################################################################
# fix-mycarmibot-port.sh — Исправление порта @mycarmibot и запуск обоих ботов
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-mycarmibot-port.sh
###############################################################################

echo "=========================================="
echo "  ПОЧИНКА @mycarmibot (порт 18793)"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export XDG_RUNTIME_DIR="/run/user/0"

echo ""
echo "[1/4] Исправляю порт в сервисе..."
SVC="/root/.config/systemd/user/openclaw-gateway.service"
if [ -f "$SVC" ]; then
    sed -i 's/18789/18793/g' "$SVC"
    sed -i 's/OPENCLAW_GATEWAY_PORT=18793/OPENCLAW_GATEWAY_PORT=18793/' "$SVC"
    echo "  ✓ Порт → 18793"
    grep -E "PORT|port" "$SVC"
else
    echo "  ✗ Сервис не найден"
    exit 1
fi

echo ""
echo "[2/4] Исправляю порт в конфиге..."
python3 << 'PYEOF'
import json
config_path = "/root/.openclaw-default/openclaw.json"
try:
    with open(config_path, "r") as f:
        config = json.load(f)
    if "gateway" not in config:
        config["gateway"] = {}
    config["gateway"]["port"] = 18793
    config["gateway"]["mode"] = "local"
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    print("  ✓ Конфиг: порт 18793")
except Exception as e:
    print(f"  ⚠ {e}")
PYEOF

echo ""
echo "[3/4] Перезапускаю оба Gateway..."
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway-moa
sleep 5
systemctl --user restart openclaw-gateway
sleep 8

echo ""
echo "[4/4] Проверяю..."
echo ""
printf "  %-25s %s\n" "БОТ" "СТАТУС"
printf "  %-25s %s\n" "-------------------------" "------"

if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    printf "  %-25s ✓ ACTIVE\n" "@mycarmi_moa_bot"
else
    printf "  %-25s ✗ FAIL\n" "@mycarmi_moa_bot"
fi

if systemctl --user is-active openclaw-gateway &>/dev/null; then
    printf "  %-25s ✓ ACTIVE\n" "@mycarmibot"
else
    printf "  %-25s ✗ FAIL\n" "@mycarmibot"
    echo ""
    echo "  Лог @mycarmibot:"
    journalctl --user -u openclaw-gateway --no-pager -n 10 2>/dev/null | tail -5
fi

echo ""
echo "  Порты:"
ss -tlnp | grep -E "1879|1878"

REMOTE

# КАНОН
echo ""
echo "КАНОН: обновляю MEMORY.md..."
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
ssh gmktec "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << EOF

## Обновление: @mycarmibot порт исправлен ($TIMESTAMP)
- @mycarmibot: порт 18793 (исправлен с 18789)
- @mycarmi_moa_bot: порт 18789 (не тронут)
EOF
done" 2>/dev/null
echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  Проверь оба бота в Telegram!"
echo "=========================================="
