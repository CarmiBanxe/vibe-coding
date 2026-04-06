#!/bin/bash
###############################################################################
# copy-prompts-to-active-workspace.sh
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/copy-prompts-to-active-workspace.sh
#
# Gateway сейчас от root, HOME=/root → читает /root/.openclaw-moa/
# Workspace из конфига: /home/mmber/.openclaw/workspace (или agents.defaults.workspace)
#
# Стратегия: определяем РЕАЛЬНЫЙ workspace, копируем туда новые промпты.
# Миграцию на openclaw делаем позже, отдельной задачей.
#
# НЕ трогает @mycarmibot!
###############################################################################

echo "=========================================="
echo "  КОПИРОВАНИЕ ПРОМПТОВ В РАБОЧИЙ WORKSPACE"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

echo ""
echo "[1/4] Определяю какой конфиг РЕАЛЬНО используется..."

# Gateway от root → OPENCLAW_HOME не задан → OpenClaw ищет ~/.openclaw-moa
# Проверяем конфиг moa
CFG="/root/.openclaw-moa/.openclaw/openclaw.json"
echo "  Конфиг: $CFG"

WORKSPACE=$(python3 -c "
import json
with open('$CFG') as f:
    c = json.load(f)
ws = c.get('agents',{}).get('defaults',{}).get('workspace','')
print(ws)
" 2>/dev/null)

echo "  agents.defaults.workspace: $WORKSPACE"

# Проверяем существует ли
if [ -d "$WORKSPACE" ]; then
    echo "  ✓ Директория существует"
else
    echo "  ✗ Директория не существует!"
    # Создаём
    mkdir -p "$WORKSPACE"
    echo "  ✓ Создана"
fi

echo ""
echo "[2/4] Текущие .md файлы в рабочем workspace..."

echo "  $WORKSPACE:"
for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md MEMORY.md SYSTEM-STATE.md AGENTS.md TOOLS.md HEARTBEAT.md; do
    if [ -f "$WORKSPACE/$f" ]; then
        SIZE=$(wc -c < "$WORKSPACE/$f")
        echo "    $f: $SIZE байт"
    else
        echo "    $f: ✗ ОТСУТСТВУЕТ"
    fi
done

echo ""
echo "[3/4] Копирую обновлённые промпты..."

# Источник — /home/mmber/.openclaw/workspace (туда upgrade-bot-prompts-v2.sh записал)
SRC="/home/mmber/.openclaw/workspace"

echo "  Источник: $SRC"
echo ""

for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md; do
    if [ -f "$SRC/$f" ]; then
        SRC_SIZE=$(wc -c < "$SRC/$f")
        DST_SIZE=$(wc -c < "$WORKSPACE/$f" 2>/dev/null || echo "0")
        
        cp "$SRC/$f" "$WORKSPACE/$f"
        echo "  ✓ $f: $SRC_SIZE байт (было: $DST_SIZE)"
    else
        echo "  ⚠ $f не найден в источнике!"
    fi
done

echo ""
echo "[4/4] Проверка — все файлы на месте..."
echo ""

echo "  $WORKSPACE:"
for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md MEMORY.md; do
    if [ -f "$WORKSPACE/$f" ]; then
        SIZE=$(wc -c < "$WORKSPACE/$f")
        # Показываем первую строку для контроля
        FIRST=$(head -1 "$WORKSPACE/$f")
        echo "    ✓ $f ($SIZE байт): $FIRST"
    else
        echo "    ✗ $f ОТСУТСТВУЕТ"
    fi
done

echo ""
echo "  Gateway:"
if ss -tlnp | grep -q ":18789 "; then
    echo "    ✓ Жив (порт 18789)"
    echo "    Перезапуск НЕ нужен — OpenClaw читает .md при каждом сообщении"
else
    echo "    ✗ Мёртв!"
fi

REMOTE

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo "  Промпты скопированы в РАБОЧИЙ workspace бота."
echo "  Перезапуск НЕ нужен."
echo "  Напиши боту: Кто ты?"
echo "=========================================="
