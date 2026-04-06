#!/bin/bash
###############################################################################
# force-sync-prompts.sh — Принудительная синхронизация промптов
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/force-sync-prompts.sh
#
# Копирует свежие промпты из /home/mmber/.openclaw/workspace
# в /opt/openclaw/workspace-moa (рабочий workspace бота)
###############################################################################

echo "=========================================="
echo "  ПРИНУДИТЕЛЬНАЯ СИНХРОНИЗАЦИЯ ПРОМПТОВ"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'

SRC="/home/mmber/.openclaw/workspace"
DST="/opt/openclaw/workspace-moa"

echo ""
echo "  Сравнение файлов:"
echo ""
printf "  %-15s %10s %10s\n" "Файл" "Источник" "Назначение"
printf "  %-15s %10s %10s\n" "----" "--------" "----------"

for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md AGENTS.md TOOLS.md HEARTBEAT.md; do
    SRC_SIZE=$(wc -c < "$SRC/$f" 2>/dev/null || echo "0")
    DST_SIZE=$(wc -c < "$DST/$f" 2>/dev/null || echo "0")
    
    if [ "$SRC_SIZE" != "$DST_SIZE" ]; then
        MARK="← РАЗНЫЕ!"
    else
        MARK="✓"
    fi
    printf "  %-15s %8s B %8s B  %s\n" "$f" "$SRC_SIZE" "$DST_SIZE" "$MARK"
done

echo ""
echo "  Копирую все из $SRC → $DST..."

for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md AGENTS.md TOOLS.md HEARTBEAT.md; do
    if [ -f "$SRC/$f" ]; then
        cp "$SRC/$f" "$DST/$f"
        chown openclaw:openclaw "$DST/$f"
        echo "  ✓ $f скопирован"
    fi
done

echo ""
echo "  Результат в $DST:"
for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md; do
    SIZE=$(wc -c < "$DST/$f" 2>/dev/null || echo "0")
    echo "    $f: $SIZE байт"
done

echo ""
echo "  Gateway:"
ss -tlnp | grep ":18789 " > /dev/null && echo "  ✓ Жив" || echo "  ✗ Мёртв"

REMOTE

echo ""
echo "  Готово. Напиши боту: Кто ты?"
echo "=========================================="
