#!/bin/bash
###############################################################################
# sync-memory-all-workspaces.sh — Копирует MEMORY.md во ВСЕ workspace
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/sync-memory-all-workspaces.sh
###############################################################################

echo "=========================================="
echo "  СИНХРОНИЗАЦИЯ MEMORY.md ВО ВСЕ WORKSPACE"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

# Обновляем репо
cd /data/vibe-coding
chattr -i .semgrep/banxe-rules.yml 2>/dev/null
git checkout -- . 2>/dev/null
git pull 2>&1 | tail -3
chattr +i .semgrep/banxe-rules.yml 2>/dev/null

SRC="/data/vibe-coding/docs/MEMORY.md"
SRC_STATE="/data/vibe-coding/docs/SYSTEM-STATE.md"

echo "  MEMORY.md: $(wc -l < "$SRC" 2>/dev/null) строк"
echo "  Версия: $(head -2 "$SRC" | tail -1)"
echo ""

# Находим ВСЕ workspace на сервере
echo "  Копирую во ВСЕ workspace:"
find / -maxdepth 6 -type d -name "workspace*" \
    -not -path "*/node_modules/*" \
    -not -path "*/.npm/*" \
    -not -path "*/vibe-coding/*" \
    2>/dev/null | while read WS; do
    cp "$SRC" "$WS/MEMORY.md" 2>/dev/null
    [ -f "$SRC_STATE" ] && cp "$SRC_STATE" "$WS/SYSTEM-STATE.md" 2>/dev/null
    echo "    ✓ $WS"
done

# Также в корневые директории OpenClaw
for DIR in \
    "/home/mmber/.openclaw" \
    "/root/.openclaw-moa" \
    "/root/.openclaw-moa/.openclaw" \
    "/root/.openclaw-default" \
    "/root/.openclaw-default/.openclaw"; do
    if [ -d "$DIR" ]; then
        cp "$SRC" "$DIR/MEMORY.md" 2>/dev/null
        echo "    ✓ $DIR/MEMORY.md"
    fi
done

echo ""
echo "  Проверка 8/10:"
grep "8/10" /home/mmber/.openclaw/workspace/MEMORY.md 2>/dev/null | head -1 | sed 's/^/    /'
grep "8/10" /root/.openclaw-moa/workspace-moa/MEMORY.md 2>/dev/null | head -1 | sed 's/^/    /'

REMOTE_END

echo ""
echo "=========================================="
echo '  Напиши боту: "Прочитай MEMORY.md заново. Security Score?"'
echo "=========================================="
