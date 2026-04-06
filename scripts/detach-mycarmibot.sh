#!/bin/bash
###############################################################################
# detach-mycarmibot.sh — Отвязка @mycarmibot от проекта Banxe
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/detach-mycarmibot.sh
#
# Что делает:
#   1. Очищает MEMORY.md от Banxe контента
#   2. Убирает Banxe агентов из конфига
#   3. Делает @mycarmibot чистым универсальным ботом
#   4. Не трогает @mycarmi_moa_bot
#   5. КАНОН: обновляет MEMORY.md moa
###############################################################################

echo "=========================================="
echo "  ОТВЯЗКА @mycarmibot ОТ BANXE"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export XDG_RUNTIME_DIR="/run/user/0"

echo ""
echo "[1/3] Очищаю workspace @mycarmibot от Banxe..."

WORKSPACE="/root/.openclaw-default/.openclaw/workspace"
mkdir -p "$WORKSPACE"

# Создаём чистый MEMORY.md без Banxe
cat > "$WORKSPACE/MEMORY.md" << 'MEMEOF'
# MEMORY — @mycarmibot

## О боте
Я — персональный AI-ассистент @mycarmibot.
Работаю на платформе OpenClaw, подключён через Telegram.

## О пользователе
- Имя: Moriel Carmi (Mark Fr.)
- Telegram: @bereg2022 (ID: 508602494)

## Настройки
- Модель: ollama/huihui_ai/qwen3.5-abliterated:35b (локальная)
- Сервер: GMKtec EVO-X2
- Порт Gateway: 18793
- Универсальный бот — не привязан к конкретному проекту
MEMEOF

# Удаляем Banxe-специфичные файлы из workspace
rm -f "$WORKSPACE/ARCHIVE-ANALYSIS.md" 2>/dev/null
rm -f "$WORKSPACE/AGENTS.md" 2>/dev/null
rm -rf "$WORKSPACE/memory" 2>/dev/null

echo "  ✓ Workspace очищен"

echo ""
echo "[2/3] Очищаю конфиг от Banxe агентов..."

python3 << 'PYEOF'
import json

config_path = "/root/.openclaw-default/.openclaw/openclaw.json"
with open(config_path, "r") as f:
    config = json.load(f)

# Убираем Banxe агентов — оставляем только main
if "agents" in config:
    if "list" in config["agents"]:
        # Оставляем только main агента
        config["agents"]["list"] = [a for a in config["agents"]["list"] if a.get("id") == "main"]
        print(f"  Агенты: оставлен только main ({len(config['agents']['list'])} шт)")

# Убираем Banxe-специфичные модели из aliases
if "models" in config and "aliases" in config["models"]:
    banxe_aliases = [k for k in config["models"]["aliases"] if "banxe" in k.lower()]
    for alias in banxe_aliases:
        del config["models"]["aliases"][alias]
    if banxe_aliases:
        print(f"  Удалены Banxe алиасы: {banxe_aliases}")

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)

print("  ✓ Конфиг очищен от Banxe")
PYEOF

echo ""
echo "[3/3] Перезапускаю @mycarmibot..."
systemctl --user restart openclaw-gateway
sleep 8

if systemctl --user is-active openclaw-gateway &>/dev/null; then
    echo "  ✓ @mycarmibot ACTIVE (чистый, без Banxe)"
else
    echo "  ✗ Не запустился"
    journalctl --user -u openclaw-gateway --no-pager -n 5 --output=cat 2>/dev/null | tail -3
fi

# Проверяем что moa не тронут
echo ""
printf "  %-25s %s\n" "БОТ" "СТАТУС"
printf "  %-25s %s\n" "-------------------------" "------"
systemctl --user is-active openclaw-gateway-moa &>/dev/null && printf "  %-25s ✓ ACTIVE (Banxe)\n" "@mycarmi_moa_bot" || printf "  %-25s ✗\n" "@mycarmi_moa_bot"
systemctl --user is-active openclaw-gateway &>/dev/null && printf "  %-25s ✓ ACTIVE (чистый)\n" "@mycarmibot" || printf "  %-25s ✗\n" "@mycarmibot"

REMOTE

# КАНОН
echo ""
echo "КАНОН: обновляю MEMORY.md..."
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
ssh gmktec "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << EOF

## Обновление: @mycarmibot отвязан от Banxe ($TIMESTAMP)
- @mycarmibot: очищен от Banxe контента, теперь универсальный бот
- @mycarmi_moa_bot: не тронут, остаётся ботом Banxe
- @mycarmibot workspace и MEMORY.md очищены
EOF
done" 2>/dev/null
echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "  @mycarmi_moa_bot — Banxe AI Bank (как было)"
echo "  @mycarmibot      — чистый универсальный бот"
echo "=========================================="
