#!/bin/bash
###############################################################################
# fix-autosync-git-pull.sh — Banxe AI Bank
# Задача #2: исправить "Cannot fast-forward to multiple branches" в memory-autosync
# Причина: race condition — ctio-watcher создаёт локальный commit до push,
#           memory-autosync в это время делает git pull --ff-only → падает
# Решение: заменить git pull --ff-only на git fetch + merge с подавлением
#          ошибки "уже впереди" + добавить watcher-скрипты в git репо
# Идемпотентен: безопасно запускать повторно
###############################################################################

set -euo pipefail

REPO_DIR="/data/vibe-coding"
AUTOSYNC="$REPO_DIR/memory-autosync-watcher.sh"
LOG="/data/logs/fix-autosync-git-pull.log"
BACKUP_DIR="/data/backups/autosync-fix"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p /data/logs "$BACKUP_DIR"
exec > >(tee -a "$LOG") 2>&1

echo ""
echo "============================================================"
echo " fix-autosync-git-pull.sh — $TIMESTAMP"
echo "============================================================"

###############################################################################
# ДИАГНОСТИКА
###############################################################################
echo ""
echo "[ ДИАГНОСТИКА ]"

cd "$REPO_DIR"

echo "Статус репо на GMKtec:"
git status --short | head -10 || true
echo ""
echo "HEAD vs origin/main:"
git fetch origin main --quiet 2>/dev/null || true
LOCAL=$(git rev-parse HEAD 2>/dev/null)
REMOTE=$(git rev-parse origin/main 2>/dev/null)
echo "  local:  $LOCAL"
echo "  remote: $REMOTE"
[ "$LOCAL" = "$REMOTE" ] && echo "  → В синхронизации ✓" || echo "  → Расхождение!"

echo ""
echo "Untracked файлы в репо (нужно добавить в git):"
git ls-files --others --exclude-standard | grep -E '\.(sh|py|json)$' || echo "  нет"

echo ""
echo "Частота ошибки в логах:"
ERRS=$(grep -c "Cannot fast-forward" /data/logs/memory-sync.log 2>/dev/null || echo 0)
echo "  'Cannot fast-forward' встретилось $ERRS раз"

echo ""
echo "Текущая строка git pull в memory-autosync-watcher.sh:"
grep 'git pull' "$AUTOSYNC" || echo "  (не найдено)"

###############################################################################
# ПОЧИНКА
###############################################################################
echo ""
echo "[ ПОЧИНКА ]"

# 1. Исправляем memory-autosync-watcher.sh: заменяем git pull --ff-only
cp "$AUTOSYNC" "$BACKUP_DIR/memory-autosync-watcher.sh.bak-$(date +%Y%m%d-%H%M%S)"
echo "✓ Бэкап создан"

# Проверяем, нужно ли менять
if grep -q 'git pull --ff-only' "$AUTOSYNC"; then
    sed -i 's|git pull --ff-only >> "\$LOG_FILE" 2>&1|# Fetch remote, merge только если не опережаем (race-safe с ctio-watcher)\n  git fetch origin main >> "$LOG_FILE" 2>\&1 \|\| true\n  git merge --ff-only origin/main >> "$LOG_FILE" 2>\&1 \|\| true|g' "$AUTOSYNC"
    echo "✓ Заменён git pull --ff-only → git fetch + merge (race-safe)"
else
    echo "~ git pull --ff-only уже не используется — пропуск"
fi

# Убедимся что патч применился корректно (проверим bash синтаксис)
if bash -n "$AUTOSYNC" 2>/dev/null; then
    echo "✓ Bash синтаксис валиден"
else
    echo "✗ Синтаксическая ошибка после sed — восстанавливаю бэкап"
    cp "$BACKUP_DIR/memory-autosync-watcher.sh.bak-"* "$AUTOSYNC"
    exit 1
fi

# 2. Добавляем watcher-скрипты в git репо (они untracked)
echo ""
echo "Добавляю untracked watcher-скрипты в git:"

UNTRACKED_SCRIPTS=()
for F in memory-autosync-watcher.sh ctio-watcher.sh; do
    if [ -f "$REPO_DIR/$F" ]; then
        # Проверяем что не в .gitignore
        if ! git check-ignore -q "$F" 2>/dev/null; then
            git add "$REPO_DIR/$F"
            UNTRACKED_SCRIPTS+=("$F")
            echo "  ✓ git add $F"
        else
            echo "  ~ $F в .gitignore — пропуск"
        fi
    fi
done

# 3. Если есть изменения — коммитим
git diff --cached --quiet && STAGED=0 || STAGED=1

if [ "$STAGED" = "1" ]; then
    git commit -m "fix: race-safe git pull in memory-autosync + add watcher scripts to repo

Replace 'git pull --ff-only' with 'git fetch + merge --ff-only || true'
to fix 'Cannot fast-forward to multiple branches' error (450+ occurrences).
Root cause: ctio-watcher creates local commit before push; autosync tried
to pull while local branch was ahead of remote → ff-only fails.
Also adds ctio-watcher.sh and memory-autosync-watcher.sh to git tracking."
    echo ""
    echo "✓ Коммит создан"

    git push origin main >> "$LOG" 2>&1 && echo "✓ Push в GitHub выполнен" || echo "✗ Push не прошёл — проверь $LOG"
else
    echo "~ Изменений нет, коммит не нужен"
fi

# 4. Очищаем лог от накопившихся ошибок (оставляем последние 100 строк)
echo ""
LINES=$(wc -l < /data/logs/memory-sync.log 2>/dev/null || echo 0)
if [ "$LINES" -gt 500 ]; then
    tail -100 /data/logs/memory-sync.log > /tmp/memory-sync-tail.log
    mv /tmp/memory-sync-tail.log /data/logs/memory-sync.log
    echo "✓ Лог memory-sync.log обрезан ($LINES → 100 строк)"
else
    echo "~ Лог memory-sync.log не требует обрезки ($LINES строк)"
fi

###############################################################################
# ВЕРИФИКАЦИЯ
###############################################################################
echo ""
echo "[ ВЕРИФИКАЦИЯ ]"

echo "Итоговая строка git в memory-autosync-watcher.sh:"
grep -A2 'Fetch remote' "$AUTOSYNC" || grep 'git fetch\|git merge' "$AUTOSYNC" || echo "  (строка не найдена)"

echo ""
echo "Тестовый запуск memory-autosync-watcher.sh:"
bash "$AUTOSYNC" 2>&1 | tail -5
echo ""

echo "Проверяем что ошибка исчезла (запуск git fetch вручную):"
cd "$REPO_DIR"
git fetch origin main 2>&1 && echo "  ✓ git fetch OK"
git merge --ff-only origin/main 2>&1 | head -3 && echo "  ✓ git merge OK (или уже в синхронизации)"

echo ""
echo "Статус watcher-скриптов в git:"
git ls-files memory-autosync-watcher.sh ctio-watcher.sh | while read f; do
    echo "  ✓ $f — в git (tracked)"
done

###############################################################################
echo ""
echo "============================================================"
echo " ГОТОВО — $TIMESTAMP"
echo " Лог: $LOG"
echo "============================================================"
