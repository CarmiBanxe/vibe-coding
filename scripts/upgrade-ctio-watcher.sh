#!/bin/bash
###############################################################################
# upgrade-ctio-watcher.sh — Расширенный CTIO Watcher v2
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/upgrade-ctio-watcher.sh
#
# Что делает:
#   Заменяет ctio-watcher.sh на GMKtec расширенной версией которая
#   ловит ВСЁ что Олег (или кто угодно) делает на сервере:
#
#   БЫЛО (v1):                    СТАЛО (v2):
#   - /home/ctio/ только          - /home/ctio/ + /opt/ + /data/ + /root/
#   - systemd сервисы             - systemd + crontab всех юзеров
#   - порты                       - порты + процессы
#   - Ollama модели               - Ollama + pip пакеты
#   - ClickHouse таблицы          - ClickHouse таблицы + row counts
#   - Docker                      - Docker + git repos
#   - /etc/ конфиги               - /etc/ + openclaw.json все
#   - (нет)                       - bash_history (ctio + root)
#   - (нет)                       - diff с предыдущим состоянием
###############################################################################

echo "=========================================="
echo "  UPGRADE: CTIO Watcher v2"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

echo "[1/3] Создаю расширенный watcher v2..."

cat > /data/vibe-coding/ctio-watcher.sh << 'WATCHER_V2'
#!/bin/bash
###############################################################################
# ctio-watcher.sh v2 — Полный мониторинг сервера
# Cron: каждые 5 минут
# Сканирует ВСЁ → docs/SYSTEM-STATE.md → GitHub (если изменения)
###############################################################################

REPO_DIR="/data/vibe-coding"
STATE_FILE="$REPO_DIR/docs/SYSTEM-STATE.md"
PREV_STATE="/data/logs/system-state-prev.md"
LOG_FILE="/data/logs/ctio-watcher.log"
LASTRUN="/data/logs/ctio-watcher-lastrun.txt"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M %Z')

mkdir -p "$REPO_DIR/docs" /data/logs

# git pull (тихо)
cd "$REPO_DIR"
git pull --ff-only >> "$LOG_FILE" 2>&1

# Сохраняем предыдущее состояние для diff
[ -f "$STATE_FILE" ] && cp "$STATE_FILE" "$PREV_STATE"

# Создаём метку если первый запуск
[ ! -f "$LASTRUN" ] && touch -d "1 hour ago" "$LASTRUN"

###############################################################################
# СБОР ДАННЫХ
###############################################################################

# === 1. СЕРВИСЫ systemd (все важные) ===
SERVICES=$(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | \
    grep -vE "^(sys-|dev-|user@|systemd-|dbus|getty|ssh\.)" | \
    awk '{print $1, $4}' | sort)

# === 2. ПОРТЫ И ПРОЦЕССЫ ===
PORTS=$(ss -tlnp 2>/dev/null | grep LISTEN | awk '{
    split($4, a, ":");
    port = a[length(a)];
    gsub(/.*users:\(\("/, "", $6);
    gsub(/".*/, "", $6);
    proc = $6;
    if (port+0 > 1000 && port+0 < 65000) printf "| %s | %s |\n", port, proc
}' | sort -t'|' -k2 -n -u)

# === 3. OLLAMA МОДЕЛИ ===
OLLAMA_MODELS=$(curl -s --max-time 5 http://localhost:11434/api/tags 2>/dev/null | \
    python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for m in d.get('models',[]):
        name=m.get('name','?')
        size=m.get('size',0)
        gb=size/(1024**3)
        mod=m.get('modified_at','?')[:10]
        print(f'| {name} | {gb:.1f} GB | {mod} |')
except: pass
" 2>/dev/null)

# === 4. CLICKHOUSE — таблицы + row counts ===
CH_TABLES=$(clickhouse-client --query "
SELECT
    database,
    name,
    formatReadableSize(total_bytes) as size,
    total_rows,
    engine
FROM system.tables
WHERE database NOT IN ('system','INFORMATION_SCHEMA','information_schema')
ORDER BY database, name
FORMAT TSV
" 2>/dev/null)

CH_DATABASES=$(clickhouse-client --query "SHOW DATABASES" 2>/dev/null | \
    grep -v -E "^(system|INFORMATION_SCHEMA|information_schema|default)$")

# === 5. DOCKER ===
DOCKER_PS=$(docker ps --format "| {{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}} |" 2>/dev/null)
DOCKER_IMAGES=$(docker images --format "| {{.Repository}}:{{.Tag}} | {{.Size}} |" 2>/dev/null | head -20)

# === 6. ДИСКИ ===
DISK_USAGE=$(df -h / /data 2>/dev/null | tail -n +2 | \
    awk '{printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5}')

# === 7. ПАМЯТЬ И CPU ===
MEM_INFO=$(free -h | awk '/Mem:/{printf "RAM: %s / %s (free: %s)", $3, $2, $4}')
LOAD_AVG=$(cat /proc/loadavg | awk '{printf "Load: %s %s %s", $1, $2, $3}')
GPU_MEM=$(cat /sys/class/drm/card*/device/mem_info_vram_used 2>/dev/null | \
    awk '{printf "GPU VRAM used: %.1f GB", $1/1024/1024/1024}')

# === 8. ВСЕ CRONTAB (root + ctio + banxe) ===
ALL_CRONS=""
for USER in root ctio banxe; do
    CRON=$(crontab -u $USER -l 2>/dev/null | grep -v "^#" | grep -v "^$")
    if [ -n "$CRON" ]; then
        ALL_CRONS="${ALL_CRONS}\n### $USER\n\`\`\`\n${CRON}\n\`\`\`\n"
    fi
done

# === 9. OPENCLAW КОНФИГИ (все) ===
OPENCLAW_CONFIGS=""
while IFS= read -r f; do
    INFO=$(python3 -c "
import json
c=json.load(open('$f'))
mode=c.get('gateway',{}).get('mode','?')
port=c.get('gateway',{}).get('port', c.get('port','?'))
model=c.get('agents',{}).get('defaults',{}).get('models',{}).get('default','?')
ctx=c.get('agents',{}).get('defaults',{}).get('params',{}).get('num_ctx','?')
print(f'| \`$f\` | {mode} | {port} | {model} | ctx={ctx} |')
" 2>/dev/null)
    [ -n "$INFO" ] && OPENCLAW_CONFIGS="${OPENCLAW_CONFIGS}${INFO}\n"
done < <(find / -name "openclaw.json" -not -path "*/node_modules/*" -not -path "*/vibe-coding/*" -not -path "*/.bak*" -not -path "*/backup*" 2>/dev/null)

# === 10. НОВЫЕ/ИЗМЕНЁННЫЕ ФАЙЛЫ (широкий scope) ===
CHANGED_FILES=""
for DIR in /home/ctio /opt /data /root; do
    FILES=$(find "$DIR" -maxdepth 4 -newer "$LASTRUN" \
        -not -path "*/.cache/*" -not -path "*/.local/share/*" \
        -not -path "*/node_modules/*" -not -path "*/.npm/*" \
        -not -path "*/__pycache__/*" -not -path "*/vibe-coding/.git/*" \
        -not -path "*/logs/*" -not -name "*.log" -not -name "*.log.*" \
        -not -path "*/backups/*" -not -name ".bash_history" \
        -type f 2>/dev/null | head -30)
    if [ -n "$FILES" ]; then
        CHANGED_FILES="${CHANGED_FILES}\n#### $DIR\n"
        while IFS= read -r f; do
            MOD=$(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1)
            SIZE=$(stat -c '%s' "$f" 2>/dev/null)
            CHANGED_FILES="${CHANGED_FILES}- \`$f\` ($SIZE bytes, $MOD)\n"
        done <<< "$FILES"
    fi
done

# === 11. BASH HISTORY (последние команды ctio + root) ===
CTIO_HISTORY=$(tail -20 /home/ctio/.bash_history 2>/dev/null | \
    grep -v "^#" | grep -v "^$" | tail -10)
ROOT_HISTORY_CTIO=""
# Проверяем если root .bash_history имеет новые записи от Олега
# (Олег может делать sudo su или ssh root)
ROOT_RECENT=$(tail -30 /root/.bash_history 2>/dev/null | \
    grep -v "^#" | grep -v "^$" | tail -10)

# === 12. PIP ПАКЕТЫ (нестандартные) ===
PIP_PACKAGES=$(pip3 list --format=columns 2>/dev/null | \
    grep -vE "^(Package|------|pip |setuptools |wheel )" | \
    awk '{print "| " $1 " | " $2 " |"}' | head -30)

# === 13. GIT РЕПОЗИТОРИИ на сервере ===
GIT_REPOS=""
for DIR in /data /opt /home/ctio /root; do
    find "$DIR" -maxdepth 3 -name ".git" -type d 2>/dev/null | while read gitdir; do
        REPO_PATH=$(dirname "$gitdir")
        REMOTE=$(cd "$REPO_PATH" && git remote get-url origin 2>/dev/null || echo "local")
        BRANCH=$(cd "$REPO_PATH" && git branch --show-current 2>/dev/null || echo "?")
        LAST=$(cd "$REPO_PATH" && git log -1 --format="%h %s" 2>/dev/null || echo "?")
        GIT_REPOS="${GIT_REPOS}| \`$REPO_PATH\` | $BRANCH | $REMOTE | $LAST |\n"
    done
done

# === 14. НЕДАВНИЕ APT УСТАНОВКИ ===
APT_RECENT=$(grep " install " /var/log/dpkg.log 2>/dev/null | tail -15 | \
    awk '{print "| " $1 " " $2 " | " $4 " |"}')

# === 15. ПОЛЬЗОВАТЕЛИ С SHELL ДОСТУПОМ ===
USERS_WITH_SHELL=$(grep -E "/(bash|sh|zsh)$" /etc/passwd | \
    awk -F: '{print "| " $1 " | " $6 " | " $7 " |"}')

###############################################################################
# ФОРМИРУЕМ SYSTEM-STATE.md
###############################################################################

cat > "$STATE_FILE" << STATE_EOF
# SYSTEM-STATE — GMKtec EVO-X2
> Автоматически обновляется каждые 5 минут
> Последнее сканирование: $TIMESTAMP
> Источник: ctio-watcher.sh v2 (cron)

## Назначение
Бот и агенты читают этот файл для актуального состояния сервера.
Все данные собраны автоматически. Бот НЕ имеет прав на изменение сервера.
Любые изменения (Олег, CEO, или автоматика) фиксируются здесь.

---

## Ресурсы
- $MEM_INFO
- $LOAD_AVG
$([ -n "$GPU_MEM" ] && echo "- $GPU_MEM")

## Диски
| Устройство | Всего | Занято | Свободно | % |
|------------|-------|--------|----------|---|
$DISK_USAGE

---

## Активные сервисы
\`\`\`
$SERVICES
\`\`\`

## Порты
| Порт | Процесс |
|------|---------|
$PORTS

---

## Ollama модели
| Модель | Размер | Изменена |
|--------|--------|----------|
$OLLAMA_MODELS

## ClickHouse
### Базы данных
$(echo "$CH_DATABASES" | awk '{print "- " $1}')

### Таблицы
| БД | Таблица | Размер | Строк | Движок |
|----|---------|--------|-------|--------|
$(echo "$CH_TABLES" | awk -F'\t' '{print "| " $1 " | " $2 " | " $3 " | " $4 " | " $5 " |"}')

---

## Docker
$(if [ -n "$DOCKER_PS" ]; then
    echo "### Контейнеры"
    echo "| Имя | Образ | Статус | Порты |"
    echo "|-----|-------|--------|-------|"
    echo "$DOCKER_PS"
    echo ""
    echo "### Образы"
    echo "| Образ | Размер |"
    echo "|-------|--------|"
    echo "$DOCKER_IMAGES"
else
    echo "Docker не используется."
fi)

---

## OpenClaw конфиги
| Файл | Mode | Port | Model | Params |
|------|------|------|-------|--------|
$(echo -e "$OPENCLAW_CONFIGS")

---

## Cron задачи (все пользователи)
$(echo -e "$ALL_CRONS")

---

## Пользователи с shell доступом
| User | Home | Shell |
|------|------|-------|
$USERS_WITH_SHELL

---

## Git репозитории на сервере
| Путь | Branch | Remote | Последний коммит |
|------|--------|--------|-----------------|
$(echo -e "$GIT_REPOS")

---

## Установленные Python пакеты (pip3)
| Пакет | Версия |
|-------|--------|
$PIP_PACKAGES

## Недавние установки (apt)
| Дата | Пакет |
|------|-------|
$APT_RECENT

---

## Последние изменения на сервере
> Файлы изменённые с последнего сканирования

$(echo -e "$CHANGED_FILES")

---

## Команды CTIO (Олег) — последние
### /home/ctio/.bash_history
\`\`\`
$(echo "$CTIO_HISTORY")
\`\`\`

### /root/.bash_history (последние)
\`\`\`
$(echo "$ROOT_RECENT")
\`\`\`

---

## Пути к сервисам (для агентов, read-only)
| Сервис | Подключение |
|--------|-------------|
| ClickHouse | localhost:9000, БД: banxe |
| Ollama API | http://localhost:11434 |
| Deep Search | http://localhost:8088 |
| PII Proxy | http://localhost:8089 |
| n8n | http://localhost:5678 |
| MetaClaw skills | /data/metaclaw/skills/ |
| Backups | /data/backups/ |
| Logs | /data/logs/ |
| Bot workspace (MoA) | /root/.openclaw-moa/workspace-moa/ |
| Bot workspace (mycarmibot) | /root/.openclaw-default/.openclaw/workspace/ |
| CTIO home | /home/ctio/ |
| CTIO bot profile | /home/ctio/.openclaw-ctio/ |

---
_Генерируется автоматически ctio-watcher.sh v2. Не редактировать вручную._
STATE_EOF

###############################################################################
# DIFF — что изменилось с прошлого раза
###############################################################################
if [ -f "$PREV_STATE" ]; then
    DIFF_COUNT=$(diff "$PREV_STATE" "$STATE_FILE" 2>/dev/null | grep -c "^[<>]")
    if [ "$DIFF_COUNT" -gt 2 ]; then
        echo "$(date '+%Y-%m-%d %H:%M'): $DIFF_COUNT строк изменились" >> "$LOG_FILE"
    fi
fi

###############################################################################
# КОММИТ В GITHUB (только если есть изменения)
###############################################################################
cd "$REPO_DIR"
touch "$LASTRUN"

git add docs/SYSTEM-STATE.md
if git diff --cached --quiet; then
    exit 0
fi

git commit -m "auto: SYSTEM-STATE v2 update ($TIMESTAMP)" >> "$LOG_FILE" 2>&1
git push origin main >> "$LOG_FILE" 2>&1

if [ $? -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M'): ✓ SYSTEM-STATE.md v2 обновлён" >> "$LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M'): ✗ git push failed" >> "$LOG_FILE"
fi
WATCHER_V2

chmod +x /data/vibe-coding/ctio-watcher.sh
echo "  ✓ ctio-watcher.sh v2 создан"

###########################################################################
# 2. ОБНОВЛЯЕМ АВТОСИНК — добавляем копирование SYSTEM-STATE.md
###########################################################################
echo ""
echo "[2/3] Первый запуск v2..."
touch /data/logs/ctio-watcher-lastrun.txt
/bin/bash /data/vibe-coding/ctio-watcher.sh

echo ""
if [ -f "/data/vibe-coding/docs/SYSTEM-STATE.md" ]; then
    LINES=$(wc -l < /data/vibe-coding/docs/SYSTEM-STATE.md)
    echo "  ✓ SYSTEM-STATE.md v2 создан ($LINES строк)"
else
    echo "  ✗ SYSTEM-STATE.md не создан"
fi

###########################################################################
# 3. КОПИРУЕМ В WORKSPACE БОТОВ
###########################################################################
echo ""
echo "[3/3] Копирую в workspace ботов..."
for DIR in \
    "/root/.openclaw-moa/workspace-moa" \
    "/root/.openclaw-moa/.openclaw/workspace" \
    "/root/.openclaw-default/.openclaw/workspace" \
    "/home/ctio/.openclaw-ctio/workspace"; do
    if [ -d "$DIR" ] || mkdir -p "$DIR" 2>/dev/null; then
        cp /data/vibe-coding/docs/SYSTEM-STATE.md "$DIR/" 2>/dev/null && echo "  ✓ $DIR"
    fi
done

# Показываем превью новых секций
echo ""
echo "  === НОВЫЕ СЕКЦИИ v2 ==="
echo ""
echo "  Ресурсы:"
grep -A2 "^## Ресурсы" /data/vibe-coding/docs/SYSTEM-STATE.md | tail -2 | sed 's/^/    /'
echo ""
echo "  OpenClaw конфиги:"
grep -A5 "^## OpenClaw" /data/vibe-coding/docs/SYSTEM-STATE.md | head -5 | sed 's/^/    /'
echo ""
echo "  Git репозитории:"
grep -A5 "^## Git" /data/vibe-coding/docs/SYSTEM-STATE.md | head -5 | sed 's/^/    /'
echo ""
echo "  Последние команды (root):"
grep -A5 "root.*bash_history" /data/vibe-coding/docs/SYSTEM-STATE.md | head -5 | sed 's/^/    /'

REMOTE_END

echo ""
echo "=========================================="
echo "  CTIO WATCHER v2 УСТАНОВЛЕН"
echo "=========================================="
echo ""
echo "  Теперь отслеживается ВСЁ:"
echo "    ✓ Файлы в /home/ctio/, /opt/, /data/, /root/"
echo "    ✓ Все crontab (root + ctio + banxe)"
echo "    ✓ Все OpenClaw конфиги (порты, модели, params)"
echo "    ✓ ClickHouse таблицы + количество строк"
echo "    ✓ pip пакеты"
echo "    ✓ Git репозитории на сервере"
echo "    ✓ bash_history (ctio + root)"
echo "    ✓ Docker контейнеры + образы"
echo "    ✓ RAM/CPU/GPU/диски"
echo "    ✓ Пользователи с shell доступом"
echo "    ✓ Недавние apt установки"
echo ""
echo "  Олег может работать как root, ctio, или banxe —"
echo "  watcher поймает всё. Бот обучается автоматически."
