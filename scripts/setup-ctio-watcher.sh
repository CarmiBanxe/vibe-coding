#!/bin/bash
###############################################################################
# setup-ctio-watcher.sh — Автосбор изменений CTIO (Олег) → GitHub → бот
#
# Запускать на LEGION (ОДИН РАЗ):
#   cd ~/vibe-coding && git pull && bash scripts/setup-ctio-watcher.sh
#
# Что делает:
#   1. Создаёт скрипт ctio-watcher.sh на GMKtec
#      - Каждые 5 минут сканирует состояние сервера:
#        * Конфиги systemd сервисов
#        * Базы данных ClickHouse (таблицы, размеры)
#        * Активные порты и сервисы
#        * Модели Ollama
#        * Docker контейнеры (если появятся)
#        * Файлы Олега в /home/ctio/
#        * Новые pip/apt пакеты
#      - Формирует docs/SYSTEM-STATE.md
#      - Коммитит в GitHub ТОЛЬКО если есть изменения
#
#   2. Ставит cron на GMKtec (каждые 5 мин)
#
#   3. Автосинк (уже работает) подхватит SYSTEM-STATE.md
#      и скопирует в workspace ботов вместе с MEMORY.md
#
#   4. Бот читает оба файла, обучается, НО НЕ выполняет
#      никаких команд на сервере (read-only)
#
# Схема:
#   Олег делает изменения → watcher фиксирует → GitHub → бот читает
###############################################################################

echo "=========================================="
echo "  SETUP: CTIO Watcher"
echo "  Автосбор изменений Олега → GitHub → бот"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

###########################################################################
# 1. НАСТРАИВАЕМ GIT НА GMKTEC (для push)
###########################################################################
echo "[1/4] Настраиваю git для автокоммитов..."

# Проверяем/обновляем репо
if [ -d "/data/vibe-coding/.git" ]; then
    cd /data/vibe-coding && git pull --ff-only 2>/dev/null
else
    cd /data && git clone https://github.com/CarmiBanxe/vibe-coding.git
fi

cd /data/vibe-coding

# Настраиваем git identity для коммитов от watcher
git config user.email "watcher@banxe-gmktec.local"
git config user.name "GMKtec CTIO Watcher"

# Настраиваем push через SSH (не нужен токен)
REMOTE_URL=$(git remote get-url origin 2>/dev/null)
echo "  Текущий remote: $REMOTE_URL"

# Переключаем на SSH remote если ещё HTTPS
if echo "$REMOTE_URL" | grep -q "https://"; then
    echo "  Переключаю на SSH remote..."
    git remote set-url origin git@github.com:CarmiBanxe/vibe-coding.git
    echo "  ✓ Remote → git@github.com:CarmiBanxe/vibe-coding.git"
fi

# Генерируем SSH ключ для GMKtec если нет
if [ ! -f /root/.ssh/id_ed25519 ]; then
    echo "  Генерирую SSH ключ для GMKtec..."
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "gmktec-watcher@banxe"
    echo "  ✓ Ключ создан"
fi

# Показываем публичный ключ — нужно добавить в GitHub
echo ""
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │ ВАЖНО: Добавь этот ключ в GitHub Deploy Keys:       │"
echo "  │ https://github.com/CarmiBanxe/vibe-coding/settings/keys │"
echo "  │ Title: GMKtec Watcher                                │"
echo "  │ Allow write access: ✓                                │"
echo "  └──────────────────────────────────────────────────────┘"
echo ""
echo "  Публичный ключ:"
cat /root/.ssh/id_ed25519.pub
echo ""

# Добавляем github.com в known_hosts
ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null
echo "  ✓ github.com добавлен в known_hosts"

# Сохраняем ключ в файл для последующего добавления в GitHub
cat /root/.ssh/id_ed25519.pub > /tmp/gmktec-deploy-key.pub

###########################################################################
# 2. СОЗДАЁМ WATCHER-СКРИПТ
###########################################################################
echo ""
echo "[2/4] Создаю ctio-watcher.sh..."

cat > /data/vibe-coding/ctio-watcher.sh << 'WATCHER_SCRIPT'
#!/bin/bash
###############################################################################
# ctio-watcher.sh — Сканирует сервер, формирует SYSTEM-STATE.md,
#                    коммитит в GitHub если есть изменения.
#                    Запускается cron каждые 5 минут.
###############################################################################

REPO_DIR="/data/vibe-coding"
STATE_FILE="$REPO_DIR/docs/SYSTEM-STATE.md"
LOG_FILE="/data/logs/ctio-watcher.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M %Z')

mkdir -p "$REPO_DIR/docs" /data/logs

# Подтягиваем последние изменения
cd "$REPO_DIR"
git pull --ff-only >> "$LOG_FILE" 2>&1

###############################################################################
# СБОР ДАННЫХ
###############################################################################

# --- Сервисы systemd ---
SERVICES=$(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | \
    grep -E "openclaw|ollama|clickhouse|n8n|deep-search|metaclaw|presidio|pii|fail2ban|xrdp" | \
    awk '{print $1, $3, $4}')

# --- Порты ---
PORTS=$(ss -tlnp 2>/dev/null | grep LISTEN | awk '{
    split($4, a, ":");
    port = a[length(a)];
    proc = $6;
    gsub(/.*"/, "", proc);
    gsub(/".*/, "", proc);
    if (port+0 > 1000) print port, proc
}' | sort -n -u)

# --- Ollama модели ---
OLLAMA_MODELS=$(curl -s --max-time 5 http://localhost:11434/api/tags 2>/dev/null | \
    python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for m in d.get('models',[]):
        name=m.get('name','?')
        size=m.get('size',0)
        gb=size/(1024**3)
        print(f'| {name} | {gb:.1f} GB |')
except: pass
" 2>/dev/null)

# --- ClickHouse ---
CH_DATA=$(clickhouse-client --query "
SELECT
    database,
    name as table_name,
    formatReadableSize(total_bytes) as size,
    total_rows as rows
FROM system.tables
WHERE database NOT IN ('system','INFORMATION_SCHEMA','information_schema')
AND total_bytes > 0
ORDER BY database, name
FORMAT TSV
" 2>/dev/null)

CH_DATABASES=$(clickhouse-client --query "SHOW DATABASES" 2>/dev/null | grep -v -E "^(system|INFORMATION_SCHEMA|information_schema|default)$")

# --- Docker ---
DOCKER_CONTAINERS=$(docker ps --format "| {{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}} |" 2>/dev/null)

# --- Диски ---
DISK_USAGE=$(df -h / /data 2>/dev/null | tail -n +2 | awk '{print "| " $1 " | " $2 " | " $3 " | " $4 " | " $5 " |"}')

# --- Файлы Олега (последние изменения) ---
CTIO_RECENT=$(find /home/ctio -maxdepth 3 -newer /data/logs/ctio-watcher-lastrun.txt \
    -not -path "*/.cache/*" -not -path "*/.local/*" -not -path "*/node_modules/*" \
    -type f 2>/dev/null | head -20)

# --- Новые пакеты ---
APT_RECENT=$(zgrep "install " /var/log/dpkg.log 2>/dev/null | tail -10 | awk '{print $1, $2, $4}')

# --- Пользовательские сервисы Олега ---
CTIO_SERVICES=$(find /home/ctio -maxdepth 3 -name "*.service" -o -name "*.conf" -o -name "*.json" \
    -not -path "*/.cache/*" -not -path "*/node_modules/*" 2>/dev/null | head -20)

# --- Конфиги в /etc изменённые за последние 5 мин ---
RECENT_CONFIGS=$(find /etc -maxdepth 2 -newer /data/logs/ctio-watcher-lastrun.txt \
    -name "*.conf" -o -name "*.json" -o -name "*.service" 2>/dev/null | head -10)

###############################################################################
# ФОРМИРУЕМ SYSTEM-STATE.md
###############################################################################

cat > "$STATE_FILE" << STATE_EOF
# SYSTEM-STATE — GMKtec EVO-X2
> Автоматически обновляется каждые 5 минут
> Последнее сканирование: $TIMESTAMP
> Источник: ctio-watcher.sh (cron)

## Назначение этого файла
Бот и агенты читают этот файл для актуального состояния сервера.
Все данные собраны автоматически. Бот НЕ имеет прав на изменение сервера.
Олег (CTIO) вносит изменения → watcher фиксирует → бот обучается.

---

## Активные сервисы
\`\`\`
$SERVICES
\`\`\`

## Открытые порты
| Порт | Процесс |
|------|---------|
$(echo "$PORTS" | awk '{print "| " $1 " | " $2 " |"}')

## Ollama модели
| Модель | Размер |
|--------|--------|
$OLLAMA_MODELS

## ClickHouse
### Базы данных
$(echo "$CH_DATABASES" | awk '{print "- " $1}')

### Таблицы с данными
| БД | Таблица | Размер | Строк |
|----|---------|--------|-------|
$(echo "$CH_DATA" | awk -F'\t' '{print "| " $1 " | " $2 " | " $3 " | " $4 " |"}')

## Диски
| Устройство | Всего | Занято | Свободно | % |
|------------|-------|--------|----------|---|
$DISK_USAGE

## Docker контейнеры
$(if [ -n "$DOCKER_CONTAINERS" ]; then
    echo "| Имя | Образ | Статус | Порты |"
    echo "|-----|-------|--------|-------|"
    echo "$DOCKER_CONTAINERS"
else
    echo "Docker не используется или нет запущенных контейнеров."
fi)

## Последние изменения CTIO (Олег)
### Новые/изменённые файлы в /home/ctio
$(if [ -n "$CTIO_RECENT" ]; then
    echo "$CTIO_RECENT" | while read f; do
        MOD=$(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1)
        echo "- \`$f\` ($MOD)"
    done
else
    echo "Нет новых изменений с последнего сканирования."
fi)

### Конфигурации Олега
$(if [ -n "$CTIO_SERVICES" ]; then
    echo "$CTIO_SERVICES" | while read f; do echo "- \`$f\`"; done
else
    echo "Нет пользовательских конфигов."
fi)

### Недавние установки пакетов
$(if [ -n "$APT_RECENT" ]; then
    echo "\`\`\`"
    echo "$APT_RECENT"
    echo "\`\`\`"
else
    echo "Нет недавних установок."
fi)

### Изменённые системные конфиги (последние 5 мин)
$(if [ -n "$RECENT_CONFIGS" ]; then
    echo "$RECENT_CONFIGS" | while read f; do echo "- \`$f\`"; done
else
    echo "Нет изменений."
fi)

---

## Пути к базам данных и сервисам
Эти пути агенты используют для доступа к данным (read-only):

| Сервис | Путь/Подключение |
|--------|-----------------|
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
_Этот файл генерируется автоматически. Не редактируйте вручную._
STATE_EOF

###############################################################################
# КОММИТ В GITHUB (только если есть изменения)
###############################################################################

cd "$REPO_DIR"

# Обновляем метку времени последнего запуска
touch /data/logs/ctio-watcher-lastrun.txt

# Проверяем есть ли изменения
git add docs/SYSTEM-STATE.md
if git diff --cached --quiet; then
    # Нет изменений — тихо выходим
    exit 0
fi

# Есть изменения — коммитим и пушим
git commit -m "auto: SYSTEM-STATE update ($TIMESTAMP)" >> "$LOG_FILE" 2>&1
git push origin main >> "$LOG_FILE" 2>&1

if [ $? -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M'): ✓ SYSTEM-STATE.md обновлён и запушен" >> "$LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M'): ✗ Ошибка push — нужен git token" >> "$LOG_FILE"
fi
WATCHER_SCRIPT

chmod +x /data/vibe-coding/ctio-watcher.sh
echo "  ✓ ctio-watcher.sh создан"

###########################################################################
# 3. ОБНОВЛЯЕМ MEMORY-AUTOSYNC — добавляем SYSTEM-STATE.md
###########################################################################
echo ""
echo "[3/4] Обновляю автосинк — добавляю SYSTEM-STATE.md..."

# Обновляем memory-autosync-watcher чтобы он тоже копировал SYSTEM-STATE.md
cat > /data/vibe-coding/memory-autosync-watcher.sh << 'SYNC_SCRIPT'
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
git pull --ff-only >> "$LOG_FILE" 2>&1

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
SYNC_SCRIPT

chmod +x /data/vibe-coding/memory-autosync-watcher.sh
echo "  ✓ Автосинк обновлён (теперь копирует и SYSTEM-STATE.md)"

###########################################################################
# 4. СТАВИМ CRON ДЛЯ CTIO-WATCHER
###########################################################################
echo ""
echo "[4/4] Устанавливаю cron для ctio-watcher..."

# Текущий crontab — убираем старые записи watcher, добавляем обе задачи
crontab -l 2>/dev/null | grep -v "memory-autosync\|ctio-watcher" > /tmp/crontab-new.txt

# Автосинк (memory + system-state из GitHub → workspace ботов)
echo "*/5 * * * * /bin/bash /data/vibe-coding/memory-autosync-watcher.sh" >> /tmp/crontab-new.txt

# CTIO watcher (сканирование сервера → GitHub)
echo "*/5 * * * * /bin/bash /data/vibe-coding/ctio-watcher.sh" >> /tmp/crontab-new.txt

crontab /tmp/crontab-new.txt
rm /tmp/crontab-new.txt

echo "  ✓ Cron установлен"
echo ""
echo "  Все cron-задачи:"
crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | while read line; do
    echo "    $line"
done

###########################################################################
# 5. ПЕРВЫЙ ЗАПУСК — создаём начальный SYSTEM-STATE.md
###########################################################################
echo ""
echo "  Первый запуск watcher..."
touch /data/logs/ctio-watcher-lastrun.txt
/bin/bash /data/vibe-coding/ctio-watcher.sh

echo ""
echo "  Проверяю результат..."
if [ -f "/data/vibe-coding/docs/SYSTEM-STATE.md" ]; then
    LINES=$(wc -l < /data/vibe-coding/docs/SYSTEM-STATE.md)
    echo "  ✓ SYSTEM-STATE.md создан ($LINES строк)"
    echo ""
    echo "  Превью (первые 30 строк):"
    head -30 /data/vibe-coding/docs/SYSTEM-STATE.md | sed 's/^/    /'
else
    echo "  ✗ SYSTEM-STATE.md не создан"
fi

# Копируем в workspace ботов сразу
echo ""
echo "  Копирую в workspace ботов..."
for DIR in "/root/.openclaw-moa/workspace-moa" "/root/.openclaw-moa/.openclaw/workspace" "/root/.openclaw-default/.openclaw/workspace"; do
    if [ -d "$DIR" ]; then
        cp /data/vibe-coding/docs/SYSTEM-STATE.md "$DIR/" 2>/dev/null
        echo "  ✓ $DIR"
    fi
done

REMOTE_END

###############################################################################
# ШАГ НА LEGION: забираем SSH ключ с GMKtec и добавляем в GitHub Deploy Keys
###############################################################################
echo ""
echo "[LEGION] Забираю SSH ключ с GMKtec..."

# Копируем публичный ключ на Legion
GMKTEC_KEY=$(ssh gmktec 'cat /root/.ssh/id_ed25519.pub 2>/dev/null')

if [ -n "$GMKTEC_KEY" ]; then
    echo "  Ключ: ${GMKTEC_KEY:0:40}..."
    echo "$GMKTEC_KEY" > /tmp/gmktec-deploy-key.pub
    
    echo ""
    echo "  ┌────────────────────────────────────────────────────────┐"
    echo "  │ Добавь этот ключ как Deploy Key в GitHub:        │"
    echo "  │                                                        │"
    echo "  │ 1. Открой:                                           │"
    echo "  │    github.com/CarmiBanxe/vibe-coding/settings/keys  │"
    echo "  │                                                        │"
    echo "  │ 2. Нажми 'Add deploy key'                              │"
    echo "  │    Title: GMKtec Watcher                              │"
    echo "  │    Key: (вставь ключ ниже)                          │"
    echo "  │    [x] Allow write access                             │"
    echo "  │                                                        │"
    echo "  │ 3. Нажми 'Add key'                                    │"
    echo "  └────────────────────────────────────────────────────────┘"
    echo ""
    echo "  КЛЮЧ (скопируй полностью):"
    echo "  $GMKTEC_KEY"
else
    echo "  ⚠ Ключ не найден на GMKtec"
fi

echo ""
echo "=========================================="
echo "  CTIO WATCHER УСТАНОВЛЕН"
echo "=========================================="
echo ""
echo "  Как это работает:"
echo "    1. Олег делает изменения на сервере"
echo "    2. Каждые 5 мин watcher сканирует всё"
echo "    3. Формирует SYSTEM-STATE.md"
echo "    4. Коммитит в GitHub (если есть изменения)"
echo "    5. Автосинк копирует в workspace ботов"
echo "    6. Бот читает и обучается"
echo "    7. Бот НЕ выполняет команд на сервере"
echo ""
echo "  ❗ После добавления Deploy Key в GitHub, проверь push:"
echo "    ssh gmktec 'cd /data/vibe-coding && git push origin main'"
echo ""
echo "  Лог: ssh gmktec 'tail -20 /data/logs/ctio-watcher.log'"
echo "  Файл: https://github.com/CarmiBanxe/vibe-coding/blob/main/docs/SYSTEM-STATE.md"
