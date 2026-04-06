#!/bin/bash
###############################################################################
# setup-action-analyzer.sh — Banxe AI Bank
# Задача #5: Action Analyzer — HITL feedback loop
#
# Что делает:
#   - Устанавливает /usr/local/bin/ctio-action-analyzer.sh на GMKtec
#   - Добавляет cron: каждую минуту анализирует bash_history Олега
#   - Новые системные команды → Ollama (glm-4.7-flash) → MetaClaw skill JSON
#   - Логирует в ClickHouse banxe.agent_metrics
#   - Добавляет таблицу banxe.ctio_actions для аудита
#
# Запуск: bash scripts/setup-action-analyzer.sh
###############################################################################

set -euo pipefail

LOG="/data/logs/setup-action-analyzer.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p /data/logs
exec > >(tee -a "$LOG") 2>&1

echo ""
echo "============================================================"
echo " setup-action-analyzer.sh — $TIMESTAMP"
echo "============================================================"

###############################################################################
# 1. Таблица ctio_actions в ClickHouse
###############################################################################
echo ""
echo "[ CLICKHOUSE: создаю таблицу ctio_actions ]"

clickhouse-client --query "
CREATE TABLE IF NOT EXISTS banxe.ctio_actions (
    ts          DateTime    DEFAULT now(),
    user        String,
    command     String,
    category    String,     -- system_admin, security, database, networking, other
    skill_name  String DEFAULT '',
    skill_file  String DEFAULT '',
    summary     String,
    raw_response String DEFAULT '',
    model       String DEFAULT 'glm-4.7-flash-abliterated',
    processed   UInt8 DEFAULT 1
) ENGINE = MergeTree()
ORDER BY (ts, user)
SETTINGS index_granularity = 8192
" 2>/dev/null && echo "  ✓ banxe.ctio_actions создана (или уже была)"

###############################################################################
# 2. Основной анализатор /usr/local/bin/ctio-action-analyzer.sh
###############################################################################
echo ""
echo "[ АНАЛИЗАТОР: создаю /usr/local/bin/ctio-action-analyzer.sh ]"

cat > /usr/local/bin/ctio-action-analyzer.sh << 'ANALYZER_SCRIPT'
#!/bin/bash
###############################################################################
# ctio-action-analyzer.sh — запускается cron каждые 2 минуты
# Читает bash_history Олега (ctio) → анализирует Ollama → MetaClaw skill
###############################################################################

LOG="/data/logs/action-analyzer.log"
OFFSET_DIR="/data/logs/action-analyzer-offsets"
SKILLS_DIR="/data/metaclaw/skills/ctio"
OLLAMA_URL="http://localhost:11434/api/generate"
MODEL="huihui_ai/glm-4.7-flash-abliterated:latest"
CLICKHOUSE="clickhouse-client"

mkdir -p "$OFFSET_DIR" "$SKILLS_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Команды которые НЕ стоит анализировать (шум)
is_noise() {
    local cmd="$1"
    # Пустые строки, cd, ls, pwd, history, clear, exit, echo, man, vim без файла
    echo "$cmd" | grep -qE '^\s*$|^(cd|ls|pwd|ll|la|history|clear|exit|logout|echo|man|vim?|nano|cat|less|more|top|htop|ps|df|du|free|uptime|whoami|date|uname)\s*$'
}

# Список файлов для мониторинга: user → history_path
declare -A HISTORY_FILES=(
    ["ctio"]="/home/ctio/.bash_history"
    ["root"]="/root/.bash_history"
)

for USER_NAME in "${!HISTORY_FILES[@]}"; do
    HIST_FILE="${HISTORY_FILES[$USER_NAME]}"
    OFFSET_FILE="$OFFSET_DIR/${USER_NAME}.offset"

    [ -f "$HIST_FILE" ] || continue

    # Определяем смещение (последняя обработанная строка)
    LAST_LINE=0
    [ -f "$OFFSET_FILE" ] && LAST_LINE=$(cat "$OFFSET_FILE")

    TOTAL_LINES=$(wc -l < "$HIST_FILE")

    if [ "$TOTAL_LINES" -le "$LAST_LINE" ]; then
        continue  # Нет новых команд
    fi

    # Читаем только новые строки
    NEW_COMMANDS=$(tail -n +"$((LAST_LINE + 1))" "$HIST_FILE" | head -n 50)

    if [ -z "$NEW_COMMANDS" ]; then
        echo "$TOTAL_LINES" > "$OFFSET_FILE"
        continue
    fi

    log "Новые команды от $USER_NAME: $((TOTAL_LINES - LAST_LINE)) строк"

    # Обрабатываем каждую команду
    while IFS= read -r CMD; do
        CMD=$(echo "$CMD" | xargs 2>/dev/null || echo "$CMD")  # trim whitespace
        [ -z "$CMD" ] && continue
        is_noise "$CMD" && continue

        START_MS=$(date +%s%3N)

        # Промпт для Ollama
        PROMPT="You are an IT operations analyst for a UK EMI bank (Banxe). A system administrator ran this command:
COMMAND: $CMD

Analyze it and respond with ONLY valid JSON (no markdown, no explanation):
{
  \"category\": \"<one of: system_admin, security, database, networking, monitoring, deployment, other>\",
  \"is_significant\": <true if this is a notable sysadmin action worth learning from, false for trivial>,
  \"summary\": \"<1 sentence: what does this command do and why would a bank admin use it>\",
  \"skill_name\": \"<snake_case name if significant, empty string if not>\",
  \"skill_trigger\": \"<when should this skill be used, empty if not significant>\",
  \"skill_action\": \"<what to do, empty if not significant>\"
}"

        # Вызываем Ollama
        RESPONSE=$(curl -s -m 90 -X POST "$OLLAMA_URL" \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"$MODEL\", \"prompt\": $(printf '%s' "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), \"stream\": false}" \
            2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("response",""))' 2>/dev/null || echo "")

        END_MS=$(date +%s%3N)
        DURATION_MS=$(( END_MS - START_MS ))

        if [ -z "$RESPONSE" ]; then
            log "  WARN: нет ответа от Ollama для: $CMD"
            continue
        fi

        # Парсим JSON ответ
        PARSED=$(echo "$RESPONSE" | python3 -c "
import sys, json, re
raw = sys.stdin.read().strip()
# Извлекаем первый JSON объект
m = re.search(r'\{.*\}', raw, re.DOTALL)
if not m:
    print('ERROR')
    sys.exit(1)
try:
    d = json.loads(m.group())
    print(json.dumps(d))
except:
    print('ERROR')
" 2>/dev/null || echo "ERROR")

        if [ "$PARSED" = "ERROR" ]; then
            log "  WARN: не удалось разобрать JSON для: $CMD"
            continue
        fi

        # Извлекаем поля
        CATEGORY=$(echo "$PARSED" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('category','other'))" 2>/dev/null || echo "other")
        IS_SIG=$(echo "$PARSED" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('is_significant') else 'false')" 2>/dev/null || echo "false")
        SUMMARY=$(echo "$PARSED" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('summary',''))" 2>/dev/null || echo "")
        SKILL_NAME=$(echo "$PARSED" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('skill_name',''))" 2>/dev/null || echo "")
        SKILL_TRIGGER=$(echo "$PARSED" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('skill_trigger',''))" 2>/dev/null || echo "")
        SKILL_ACTION=$(echo "$PARSED" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('skill_action',''))" 2>/dev/null || echo "")

        SKILL_FILE=""

        # Если значимая команда — создаём MetaClaw skill
        if [ "$IS_SIG" = "true" ] && [ -n "$SKILL_NAME" ]; then
            SKILL_FILE="$SKILLS_DIR/${SKILL_NAME}.json"
            TS_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

            python3 -c "
import json
skill = {
    'name': '$SKILL_NAME',
    'description': '''$SUMMARY''',
    'trigger': '''$SKILL_TRIGGER''',
    'action': '''$SKILL_ACTION''',
    'source': 'ctio_bash_history',
    'learned_from': '$USER_NAME',
    'example_command': '''${CMD}''',
    'created_at': '$TS_ISO',
    'category': '$CATEGORY'
}
print(json.dumps(skill, indent=2, ensure_ascii=False))
" > "$SKILL_FILE" 2>/dev/null && log "  ✓ Skill создан: $SKILL_FILE"
        fi

        # Логируем в ClickHouse
        CMD_ESCAPED=$(printf '%s' "$CMD" | python3 -c "import sys; s=sys.stdin.read(); print(s.replace(\"'\", \"''\"))" 2>/dev/null || echo "$CMD")
        SUMMARY_ESCAPED=$(printf '%s' "$SUMMARY" | python3 -c "import sys; s=sys.stdin.read(); print(s.replace(\"'\", \"''\"))" 2>/dev/null || echo "$SUMMARY")
        RESPONSE_ESCAPED=$(printf '%s' "$PARSED" | python3 -c "import sys; s=sys.stdin.read(); print(s.replace(\"'\", \"''\")[:500])" 2>/dev/null || echo "")

        $CLICKHOUSE --query "INSERT INTO banxe.ctio_actions
            (user, command, category, skill_name, skill_file, summary, raw_response, model)
            VALUES (
                '$USER_NAME',
                '${CMD_ESCAPED:0:500}',
                '$CATEGORY',
                '$SKILL_NAME',
                '$SKILL_FILE',
                '${SUMMARY_ESCAPED:0:500}',
                '${RESPONSE_ESCAPED}',
                '$MODEL'
            )" 2>/dev/null || log "  WARN: ClickHouse INSERT failed для $CMD"

        # Логируем в agent_metrics
        $CLICKHOUSE --query "INSERT INTO banxe.agent_metrics
            (agent, model, task, duration_ms, tokens_in, tokens_out, success)
            VALUES ('action_analyzer', '$MODEL', 'classify_command', $DURATION_MS, 0, 0, 1)" 2>/dev/null || true

        log "  → $USER_NAME | [$CATEGORY] $CMD → skill=${SKILL_NAME:-none}"
    done <<< "$NEW_COMMANDS"

    # Сохраняем новое смещение
    echo "$TOTAL_LINES" > "$OFFSET_FILE"
done

log "--- цикл завершён ---"
ANALYZER_SCRIPT

chmod +x /usr/local/bin/ctio-action-analyzer.sh
echo "  ✓ /usr/local/bin/ctio-action-analyzer.sh создан"

###############################################################################
# 3. Cron — каждые 2 минуты
###############################################################################
echo ""
echo "[ CRON: добавляю задачу ]"

CRON_LINE="*/2 * * * * /usr/local/bin/ctio-action-analyzer.sh >> /data/logs/action-analyzer.log 2>&1"
CRON_COMMENT="# Action Analyzer — HITL feedback loop (Banxe AI Bank)"

# Удаляем старую запись если есть
( crontab -l 2>/dev/null | grep -v 'action-analyzer' || true ) | \
    { cat; echo "$CRON_COMMENT"; echo "$CRON_LINE"; } | \
    crontab -

echo "  ✓ cron: */2 * * * * ctio-action-analyzer.sh"

###############################################################################
# 4. Первый тестовый запуск
###############################################################################
echo ""
echo "[ ТЕСТ: запускаю анализатор вручную ]"
echo "  (Если bash_history пустой — анализировать нечего, это нормально)"

# Добавляем тестовую команду в history root для проверки работы
TEST_CMD="systemctl status fail2ban"
echo "$TEST_CMD" >> /root/.bash_history
echo "  + Добавлена тестовая команда: $TEST_CMD"

# Сбрасываем offset для root чтобы подхватил тестовую команду
OFFSET_DIR="/data/logs/action-analyzer-offsets"
mkdir -p "$OFFSET_DIR"
ROOT_HIST_LINES=$(wc -l < /root/.bash_history)
echo "$((ROOT_HIST_LINES - 1))" > "$OFFSET_DIR/root.offset"

# Запускаем
timeout 60 /usr/local/bin/ctio-action-analyzer.sh || true
echo ""
echo "  Лог анализатора (последние 20 строк):"
tail -20 /data/logs/action-analyzer.log 2>/dev/null || echo "  (лог пока пустой)"

###############################################################################
# 5. Верификация
###############################################################################
echo ""
echo "[ ВЕРИФИКАЦИЯ ]"

# Проверяем cron
CRON_OK=$(crontab -l 2>/dev/null | grep -c 'action-analyzer' || echo 0)
echo "  $([ "$CRON_OK" -gt 0 ] && echo '✓' || echo '✗') cron задача зарегистрирована"

# Проверяем скрипт
[ -x /usr/local/bin/ctio-action-analyzer.sh ] && echo "  ✓ скрипт существует и исполняемый" || echo "  ✗ скрипт не найден"

# Проверяем таблицу ClickHouse
CH_OK=$(clickhouse-client --query "SELECT count() FROM banxe.ctio_actions" 2>/dev/null || echo "ERROR")
if [ "$CH_OK" != "ERROR" ]; then
    echo "  ✓ banxe.ctio_actions: $CH_OK строк"
else
    echo "  ✗ banxe.ctio_actions недоступна"
fi

# Проверяем skills директорию
SKILLS_COUNT=$(ls /data/metaclaw/skills/ctio/*.json 2>/dev/null | wc -l || echo 0)
echo "  ✓ MetaClaw skills (ctio): $SKILLS_COUNT файлов"

echo ""
echo "============================================================"
echo " ✅ Action Analyzer настроен"
echo ""
echo " Как работает:"
echo "   1. cron запускает ctio-action-analyzer.sh каждые 2 мин"
echo "   2. Читает новые команды из /home/ctio/.bash_history"
echo "   3. Ollama (glm-4.7-flash) классифицирует команды"
echo "   4. Значимые действия → /data/metaclaw/skills/ctio/*.json"
echo "   5. Все действия → banxe.ctio_actions (ClickHouse)"
echo ""
echo " Просмотр результатов:"
echo "   tail -f /data/logs/action-analyzer.log"
echo "   clickhouse-client --query 'SELECT ts, user, category, command, skill_name FROM banxe.ctio_actions ORDER BY ts DESC LIMIT 20'"
echo "   ls /data/metaclaw/skills/ctio/"
echo " Лог: $LOG"
echo "============================================================"
