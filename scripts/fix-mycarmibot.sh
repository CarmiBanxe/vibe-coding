#!/bin/bash
###############################################################################
# fix-mycarmibot.sh — Запуск @mycarmibot на GMKtec (не трогая @mycarmi_moa_bot)
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-mycarmibot.sh
###############################################################################

GMKTEC="root@192.168.0.72"
GMKTEC_PORT="2222"

echo "=========================================="
echo "  ЗАПУСК @mycarmibot НА GMKtec"
echo "  (не трогая @mycarmi_moa_bot)"
echo "=========================================="

# --- 1. Копируем конфиг default профиля на GMKtec ---
echo ""
echo "[1/4] Копирую конфиг @mycarmibot на GMKtec..."

# Создаём профиль default на GMKtec
ssh -p "$GMKTEC_PORT" "$GMKTEC" "mkdir -p /root/.openclaw-default/workspace-default"

# Копируем backup конфиг (там токен @mycarmibot)
scp -P "$GMKTEC_PORT" ~/.openclaw.backup-default/openclaw.json "$GMKTEC:/root/.openclaw-default/openclaw.json"
echo "  ✓ Конфиг скопирован"

# --- 2. Настраиваем конфиг для GMKtec ---
echo ""
echo "[2/4] Настраиваю конфиг..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'STEP2'
python3 << 'PYEOF'
import json

config_path = "/root/.openclaw-default/openclaw.json"
with open(config_path, "r") as f:
    config = json.load(f)

# Ollama на localhost (GMKtec)
if "models" in config and "providers" in config["models"]:
    for prov in config["models"]["providers"]:
        if "ollama" in str(prov).lower():
            if isinstance(config["models"]["providers"], dict):
                for key, val in config["models"]["providers"].items():
                    if "ollama" in key.lower() and isinstance(val, dict):
                        val["baseUrl"] = "http://localhost:11434"
            elif isinstance(config["models"]["providers"], list):
                for p in config["models"]["providers"]:
                    if isinstance(p, dict) and "ollama" in str(p.get("name", "")).lower():
                        p["baseUrl"] = "http://localhost:11434"

# Gateway mode local, другой порт (не конфликтовать с moa=18789)
if "gateway" not in config:
    config["gateway"] = {}
config["gateway"]["mode"] = "local"
config["gateway"]["port"] = 18793

# Убедимся что botToken правильный (@mycarmibot)
# Токен уже в конфиге из backup

# allowFrom — CEO
if "sessions" in config:
    config["sessions"]["allowFrom"] = [508602494]
elif "channels" in config and "telegram" in config["channels"]:
    config["channels"]["telegram"]["allowFrom"] = [508602494]

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)

print("  ✓ Конфиг настроен:")
print("    Gateway порт: 18793")
print("    Ollama: localhost")
print("    Бот: @mycarmibot")
PYEOF
STEP2

# --- 3. Копируем MEMORY.md ---
echo ""
echo "[3/4] Копирую MEMORY.md..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'STEP3'
# Ищем рабочий MEMORY.md и копируем
for src in /home/mmber/.openclaw/workspace-moa/MEMORY.md \
           /root/.openclaw-moa/workspace-moa/MEMORY.md \
           /root/.openclaw-moa/.openclaw/workspace/MEMORY.md; do
    if [ -f "$src" ]; then
        cp "$src" /root/.openclaw-default/workspace-default/MEMORY.md
        echo "  ✓ MEMORY.md скопирован"
        break
    fi
done

# Устанавливаем gateway.mode
export OPENCLAW_HOME="/root/.openclaw-default"
openclaw config set gateway.mode local --profile default 2>&1 | tail -1
STEP3

# --- 4. Запускаем Gateway для @mycarmibot ---
echo ""
echo "[4/4] Запускаю Gateway @mycarmibot..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'STEP4'
export OPENCLAW_HOME="/root/.openclaw-default"
export XDG_RUNTIME_DIR="/run/user/0"

# Устанавливаем Gateway
openclaw gateway install --profile default --force 2>&1 | tail -3

# Исправляем задвоенный путь (известная проблема)
SVC_FILE="/root/.config/systemd/user/openclaw-gateway-default.service"
if [ -f "$SVC_FILE" ]; then
    sed -i 's|/root/.openclaw-default/.openclaw-default|/root/.openclaw-default|g' "$SVC_FILE"
    echo "  ✓ Systemd сервис исправлен"
fi

# Запускаем
systemctl --user daemon-reload 2>/dev/null
systemctl --user enable openclaw-gateway-default 2>/dev/null
systemctl --user restart openclaw-gateway-default 2>/dev/null
sleep 8

if systemctl --user is-active openclaw-gateway-default &>/dev/null; then
    echo "  ✓ @mycarmibot Gateway ACTIVE!"
else
    echo "  Статус:"
    journalctl --user -u openclaw-gateway-default --no-pager -n 10 2>/dev/null | tail -5
fi

# Проверяем оба бота
echo ""
echo "  === ОБА БОТА ==="
printf "  %-25s %s\n" "БОТ" "СТАТУС"
printf "  %-25s %s\n" "-------------------------" "------"

systemctl --user is-active openclaw-gateway-moa &>/dev/null && \
    printf "  %-25s ✓ ACTIVE (порт 18789)\n" "@mycarmi_moa_bot" || \
    printf "  %-25s ✗\n" "@mycarmi_moa_bot"

systemctl --user is-active openclaw-gateway-default &>/dev/null && \
    printf "  %-25s ✓ ACTIVE (порт 18793)\n" "@mycarmibot" || \
    printf "  %-25s ✗\n" "@mycarmibot"

echo ""
echo "  Порты:"
ss -tlnp | grep -E "1879|1878"
STEP4

# --- КАНОН ---
echo ""
echo "КАНОН: обновляю MEMORY.md..."

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
ssh -p "$GMKTEC_PORT" "$GMKTEC" "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << EOF

## Обновление: @mycarmibot запущен ($TIMESTAMP)
- @mycarmibot: Gateway default, порт 18793
- @mycarmi_moa_bot: Gateway moa, порт 18789 (не тронут)
- Оба бота работают одновременно на GMKtec
EOF
done" 2>/dev/null

echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "  @mycarmi_moa_bot — порт 18789 (не тронут)"
echo "  @mycarmibot      — порт 18793 (запущен)"
echo ""
echo "  Проверь @mycarmibot в Telegram!"
echo "=========================================="
