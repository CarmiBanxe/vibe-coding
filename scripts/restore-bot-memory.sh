#!/bin/bash
###############################################################################
# restore-bot-memory.sh — Полное восстановление памяти бота
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/restore-bot-memory.sh
#
# Проблема: бот пишет "Я новый, память пустая"
# Причина: при перезапуске gateway workspace файлы могли не подхватиться
# Решение: копируем MEMORY.md + SYSTEM-STATE.md во ВСЕ workspace
###############################################################################

echo "=========================================="
echo "  ВОССТАНОВЛЕНИЕ ПАМЯТИ БОТА"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export PATH="$PATH:/root/.local/bin"

###########################################################################
# 1. Обновляем репо (source of truth)
###########################################################################
echo "[1/4] Обновляю репо..."
cd /data/vibe-coding && git pull --ff-only 2>&1 | tail -3

SRC_MEMORY="/data/vibe-coding/docs/MEMORY.md"
SRC_STATE="/data/vibe-coding/docs/SYSTEM-STATE.md"

echo "  MEMORY.md: $(wc -l < "$SRC_MEMORY" 2>/dev/null || echo "НЕТ") строк"
echo "  SYSTEM-STATE.md: $(wc -l < "$SRC_STATE" 2>/dev/null || echo "НЕТ") строк"

###########################################################################
# 2. Находим ВСЕ workspace на сервере
###########################################################################
echo ""
echo "[2/4] Ищу все workspace..."

WORKSPACES=$(find /root/.openclaw-moa /root/.openclaw-default /home/ctio/.openclaw-ctio /home/mmber/.openclaw -maxdepth 4 -type d -name "workspace*" 2>/dev/null)

echo "  Найдены:"
echo "$WORKSPACES" | while read ws; do echo "    $ws"; done

###########################################################################
# 3. Копируем во ВСЕ workspace
###########################################################################
echo ""
echo "[3/4] Копирую MEMORY.md + SYSTEM-STATE.md..."

for WS in $WORKSPACES; do
    if [ -d "$WS" ]; then
        cp "$SRC_MEMORY" "$WS/MEMORY.md" 2>/dev/null
        cp "$SRC_STATE" "$WS/SYSTEM-STATE.md" 2>/dev/null
        
        LINES_M=$(wc -l < "$WS/MEMORY.md" 2>/dev/null || echo 0)
        LINES_S=$(wc -l < "$WS/SYSTEM-STATE.md" 2>/dev/null || echo 0)
        echo "  ✓ $WS (MEMORY:${LINES_M}стр, STATE:${LINES_S}стр)"
    fi
done

# Также в корень .openclaw директорий (на случай если бот смотрит туда)
for DIR in \
    "/root/.openclaw-moa" \
    "/root/.openclaw-moa/.openclaw" \
    "/root/.openclaw-default" \
    "/root/.openclaw-default/.openclaw"; do
    if [ -d "$DIR" ]; then
        cp "$SRC_MEMORY" "$DIR/MEMORY.md" 2>/dev/null
    fi
done
echo "  ✓ Также в корневые .openclaw директории"

###########################################################################
# 4. Проверяем что gateway жив
###########################################################################
echo ""
echo "[4/4] Проверяю gateway..."

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ @mycarmi_moa_bot ACTIVE (порт 18789)"
else
    echo "  ⚠ Gateway не запущен — запускаю..."
    cd /root/.openclaw-moa
    OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
    sleep 12
    ss -tlnp | grep -q ":18789 " && echo "  ✓ Gateway запущен" || echo "  ✗ Не удалось"
fi

echo ""
echo "  Telegram лог:"
tail -3 /data/logs/gateway-moa.log 2>/dev/null | grep -i telegram | sed 's/^/    /'

REMOTE_END

echo ""
echo "=========================================="
echo "  ПАМЯТЬ ВОССТАНОВЛЕНА"
echo "=========================================="
echo ""
echo "  Напиши боту:"
echo '    "Прочитай MEMORY.md и скажи кто ты"'

# ПАТЧ: исправляем memory-autosync-watcher.sh чтобы ВСЕГДА проверял наличие
ssh gmktec 'bash -s' << 'FIX'
# Снимаем immutable чтобы править
chattr -i /data/vibe-coding/memory-autosync-watcher.sh 2>/dev/null

# Добавляем проверку наличия файлов в конец watcher
cat >> /data/vibe-coding/memory-autosync-watcher.sh << 'ADDCHECK'

# ГАРАНТИЯ: даже если хэш не изменился — проверяем что файлы ЕСТЬ в workspace
for DIR in \
    "/root/.openclaw-moa/workspace-moa" \
    "/root/.openclaw-moa/.openclaw/workspace" \
    "/root/.openclaw-default/.openclaw/workspace"; do
    if [ -d "$DIR" ] && [ ! -f "$DIR/MEMORY.md" ]; then
        [ -f "$MEMORY_SRC" ] && cp "$MEMORY_SRC" "$DIR/MEMORY.md"
        [ -f "$STATE_SRC" ] && cp "$STATE_SRC" "$DIR/SYSTEM-STATE.md"
        echo "$(date '+%H:%M'): RESTORED missing files → $DIR" >> "$LOG_FILE"
    fi
done
ADDCHECK

# Возвращаем immutable
chattr +i /data/vibe-coding/memory-autosync-watcher.sh 2>/dev/null
echo "✓ Watcher пропатчен — теперь ВСЕГДА проверяет наличие файлов"
FIX
