#!/bin/bash
###############################################################################
# memory-autosync-watcher.sh — cron каждые 5 минут
# git pull → если MEMORY.md или SYSTEM-STATE.md изменились →
# копирует во все workspace ботов
###############################################################################

REPO_DIR="/data/vibe-coding"
MEMORY_SRC="$REPO_DIR/docs/MEMORY.md"
STATE_SRC="$REPO_DIR/docs/SYSTEM-STATE.md"
HASH_FILE="/data/logs/memory-last-hash.txt"
LOG_FILE="/data/logs/memory-sync.log"

mkdir -p /data/logs

# git pull
cd "$REPO_DIR"
# Fetch remote, merge только если не опережаем (race-safe с ctio-watcher)
# Замена git pull --ff-only которое падало 456 раз при race condition
git fetch origin main >> "$LOG_FILE" 2>&1 || true
git merge --ff-only origin/main >> "$LOG_FILE" 2>&1 || true

# Считаем общий хэш обоих файлов
NEW_HASH=$(cat "$MEMORY_SRC" "$STATE_SRC" 2>/dev/null | md5sum | awk '{print $1}')
OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null)

# Если не изменился — тихо выходим
if [ "$NEW_HASH" == "$OLD_HASH" ]; then
    exit 0
fi

# ИЗМЕНИЛОСЬ — синхронизируем
echo "$(date '+%Y-%m-%d %H:%M'): Файлы изменились, синхронизирую..." >> "$LOG_FILE"
echo "$NEW_HASH" > "$HASH_FILE"

# Все workspace ботов
TARGETS=(
    "/home/mmber/.openclaw/workspace-moa"
    "/root/.openclaw-moa/workspace-moa"
    "/root/.openclaw-moa/.openclaw/workspace"
    "/root/.openclaw-moa/.openclaw/workspace-moa"
    "/root/.openclaw-default/.openclaw/workspace"
)

for DIR in "${TARGETS[@]}"; do
    if [ -d "$DIR" ] || mkdir -p "$DIR" 2>/dev/null; then
        [ -f "$MEMORY_SRC" ] && cp "$MEMORY_SRC" "$DIR/MEMORY.md"
        [ -f "$STATE_SRC" ] && cp "$STATE_SRC" "$DIR/SYSTEM-STATE.md"
    fi
done

# CTIO workspace
if [ -d "/home/ctio/.openclaw-ctio" ]; then
    mkdir -p /home/ctio/.openclaw-ctio/workspace 2>/dev/null
    [ -f "$MEMORY_SRC" ] && cp "$MEMORY_SRC" /home/ctio/.openclaw-ctio/workspace/MEMORY.md
    [ -f "$STATE_SRC" ] && cp "$STATE_SRC" /home/ctio/.openclaw-ctio/workspace/SYSTEM-STATE.md
    chown -R ctio:ctio /home/ctio/.openclaw-ctio/workspace/ 2>/dev/null
fi

echo "$(date '+%H:%M'): ✓ Синхронизация завершена" >> "$LOG_FILE"

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

# Новый workspace для пользователя openclaw
[ -d "/opt/openclaw/workspace-moa" ] && [ -f "$MEMORY_SRC" ] && cp "$MEMORY_SRC" /opt/openclaw/workspace-moa/MEMORY.md
[ -d "/opt/openclaw/workspace-moa" ] && [ -f "$STATE_SRC" ] && cp "$STATE_SRC" /opt/openclaw/workspace-moa/SYSTEM-STATE.md

