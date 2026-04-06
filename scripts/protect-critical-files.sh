#!/bin/bash
###############################################################################
# protect-critical-files.sh — Защита критичных файлов от удаления
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/protect-critical-files.sh
#
# Что делает:
#   1. chattr +i на критичные скрипты (watcher, integrity check, cron)
#      Даже root не может удалить без chattr -i
#   2. Защищает systemd сервисы
#   3. Защищает конфиги верификации
#   4. Создаёт внешний cron-мониторинг:
#      если SYSTEM-STATE.md не обновлялся > 15 мин — пишет алерт
###############################################################################

echo "=========================================="
echo "  ЗАЩИТА КРИТИЧНЫХ ФАЙЛОВ"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

log() { echo "$(date '+%H:%M:%S') $1"; }

###########################################################################
# 1. IMMUTABLE атрибут на критичные файлы
###########################################################################
log "[1/3] Ставлю immutable на критичные файлы..."

PROTECT_FILES=(
    # Watchers
    "/data/vibe-coding/ctio-watcher.sh"
    "/data/vibe-coding/memory-autosync-watcher.sh"
    "/data/vibe-coding/check-tools-integrity.sh"
    # Semgrep правила
    "/data/vibe-coding/.semgrep/banxe-rules.yml"
)

for f in "${PROTECT_FILES[@]}"; do
    if [ -f "$f" ]; then
        chattr +i "$f" 2>/dev/null
        if lsattr "$f" 2>/dev/null | grep -q "i"; then
            echo "  ✓ $f — IMMUTABLE"
        else
            echo "  ⚠ $f — chattr не сработал (файловая система?)"
        fi
    else
        echo "  ⏭ $f — не существует"
    fi
done

# Systemd сервисы
for svc in \
    "/etc/systemd/system/openclaw-gateway-moa.service" \
    "/etc/systemd/system/openclaw-gateway-mycarmibot.service" \
    "/etc/systemd/system/deep-search.service"; do
    if [ -f "$svc" ]; then
        chattr +i "$svc" 2>/dev/null
        lsattr "$svc" 2>/dev/null | grep -q "i" && echo "  ✓ $svc — IMMUTABLE" || echo "  ⚠ $svc — не удалось"
    fi
done

###########################################################################
# 2. Crontab — защищаем от очистки
###########################################################################
log ""
log "[2/3] Сохраняю бэкап crontab..."

crontab -l > /data/backups/crontab-root-backup.txt 2>/dev/null
echo "  ✓ Бэкап: /data/backups/crontab-root-backup.txt"

# Показываем что защищено
echo ""
echo "  Cron задачи (активные):"
crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | while read line; do
    echo "    $line"
done

###########################################################################
# 3. Watchdog — мониторинг что watcher жив
###########################################################################
log ""
log "[3/3] Создаю watchdog..."

cat > /usr/local/bin/watchdog-watcher.sh << 'WATCHDOG'
#!/bin/bash
###############################################################################
# watchdog-watcher.sh — Проверяет что watcher работает
# Cron: каждые 15 минут
# Если SYSTEM-STATE.md не обновлялся > 20 мин — алерт
###############################################################################

STATE_FILE="/data/vibe-coding/docs/SYSTEM-STATE.md"
ALERT_LOG="/data/logs/watchdog-alerts.log"
WATCHER_LOG="/data/logs/ctio-watcher.log"

if [ ! -f "$STATE_FILE" ]; then
    echo "$(date): CRITICAL — SYSTEM-STATE.md НЕ СУЩЕСТВУЕТ!" >> "$ALERT_LOG"
    exit 1
fi

# Проверяем время последнего изменения
LAST_MOD=$(stat -c %Y "$STATE_FILE" 2>/dev/null)
NOW=$(date +%s)
AGE=$(( (NOW - LAST_MOD) / 60 ))

if [ "$AGE" -gt 20 ]; then
    echo "$(date): WARNING — SYSTEM-STATE.md не обновлялся $AGE минут!" >> "$ALERT_LOG"
    
    # Проверяем жив ли watcher в cron
    if ! crontab -l 2>/dev/null | grep -q "ctio-watcher"; then
        echo "$(date): CRITICAL — ctio-watcher УДАЛЁН из cron!" >> "$ALERT_LOG"
        
        # Восстанавливаем из бэкапа
        if [ -f "/data/backups/crontab-root-backup.txt" ]; then
            crontab /data/backups/crontab-root-backup.txt
            echo "$(date): RESTORED — crontab восстановлен из бэкапа" >> "$ALERT_LOG"
        fi
    fi
    
    # Проверяем жив ли файл watcher
    if [ ! -f "/data/vibe-coding/ctio-watcher.sh" ]; then
        echo "$(date): CRITICAL — ctio-watcher.sh УДАЛЁН!" >> "$ALERT_LOG"
    fi
fi

# Проверяем immutable атрибуты
for f in /data/vibe-coding/ctio-watcher.sh /data/vibe-coding/memory-autosync-watcher.sh; do
    if [ -f "$f" ] && ! lsattr "$f" 2>/dev/null | grep -q "i"; then
        echo "$(date): WARNING — $f потерял immutable атрибут!" >> "$ALERT_LOG"
        chattr +i "$f" 2>/dev/null
    fi
done
WATCHDOG

chmod +x /usr/local/bin/watchdog-watcher.sh

# Добавляем в cron (каждые 15 минут)
if ! crontab -l 2>/dev/null | grep -q "watchdog-watcher"; then
    (crontab -l 2>/dev/null; echo "*/15 * * * * /bin/bash /usr/local/bin/watchdog-watcher.sh") | crontab -
    echo "  ✓ Watchdog cron установлен (каждые 15 мин)"
else
    echo "  ✓ Watchdog уже в cron"
fi

# Защищаем watchdog тоже
chattr +i /usr/local/bin/watchdog-watcher.sh 2>/dev/null

###########################################################################
# ИТОГ
###########################################################################
echo ""
echo "  ══════════════════════════════════════"
echo "  ЗАЩИТА УСТАНОВЛЕНА:"
echo ""
echo "  Immutable файлы (даже root не удалит):"
lsattr /data/vibe-coding/ctio-watcher.sh /data/vibe-coding/memory-autosync-watcher.sh /data/vibe-coding/check-tools-integrity.sh /usr/local/bin/watchdog-watcher.sh 2>/dev/null | sed 's/^/    /'
echo ""
echo "  Watchdog: каждые 15 мин проверяет что watcher жив"
echo "  Если cron удалён — автовосстановление из бэкапа"
echo "  Алерты: /data/logs/watchdog-alerts.log"
echo ""
echo "  Как снять защиту (только ты знаешь):"
echo "    chattr -i /data/vibe-coding/ctio-watcher.sh"
echo "  ══════════════════════════════════════"

REMOTE_END
