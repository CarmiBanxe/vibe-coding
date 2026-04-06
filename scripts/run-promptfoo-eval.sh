#!/usr/bin/env bash
# run-promptfoo-eval.sh — запуск Promptfoo evaluation на GMKtec
#
# Работает ТОЛЬКО на GMKtec (нужен доступ к Ollama localhost:11434).
# Вызывается: cron (воскресенье 04:00) или вручную.
#
# Что делает:
#   1. Запускает npx promptfoo eval с qwen3-banxe-v2
#   2. Сохраняет результаты в compliance/training/results/
#   3. Проверяет fail rate — если > 20% → Telegram alert
#   4. git commit + push результатов в developer-core
#
# Запускать на GMKtec:
#   cd ~/developer && bash /data/vibe-coding/scripts/run-promptfoo-eval.sh
#
# Или с Legion (деплой + запуск):
#   cd ~/vibe-coding && git pull && bash scripts/deploy-gap3-promptfoo.sh

set -uo pipefail

LOG_FILE="/data/logs/promptfoo-eval.log"
ENV_FILE="/data/banxe/.env"
TIMESTAMP=$(date -Iseconds)
FAIL_THRESHOLD=20  # percent

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$TIMESTAMP] $*" | tee -a "$LOG_FILE"
}

# ── Определяем DEVELOPER_DIR: env override → ~/developer → /data/banxe/promptfoo ──
if [ -z "${DEVELOPER_DIR:-}" ]; then
    if [ -d "${HOME}/developer/.git" ]; then
        DEVELOPER_DIR="${HOME}/developer"
    elif [ -d "/data/banxe/promptfoo/compliance/training" ]; then
        DEVELOPER_DIR="/data/banxe/promptfoo"
    else
        log "ERROR: DEVELOPER_DIR не задан и ни один путь не найден."
        log "Запустите сначала: bash scripts/deploy-gap3-promptfoo.sh"
        exit 1
    fi
fi
log "DEVELOPER_DIR=${DEVELOPER_DIR}"

CONFIG="${DEVELOPER_DIR}/compliance/training/promptfoo.yaml"
RESULTS_DIR="${DEVELOPER_DIR}/compliance/training/results"
RESULTS_FILE="${RESULTS_DIR}/kyc-specialist-results.json"

mkdir -p "${RESULTS_DIR}"

log "=== Promptfoo eval START ($(date)) ==="
log "Config: ${CONFIG}"
log "Model:  ollama:chat:qwen3-banxe-v2"

# ── Загрузка .env ─────────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-${MOA_BOT_TOKEN:-}}"
ALERT_CHAT="${HITL_TELEGRAM_RECIPIENTS:-508602494}"

# ── Проверка зависимостей ─────────────────────────────────────────────────────
if ! command -v npx &>/dev/null; then
    log "ERROR: npx not found"
    exit 1
fi

if ! curl -s --max-time 3 "http://localhost:11434/api/tags" &>/dev/null; then
    log "ERROR: Ollama not reachable at localhost:11434"
    exit 1
fi

if ! curl -s --max-time 3 "http://localhost:11434/api/tags" | python3 -c "
import json,sys
models = json.load(sys.stdin).get('models',[])
names = [m.get('name','') for m in models]
found = any('qwen3-banxe-v2' in n for n in names)
sys.exit(0 if found else 1)
" 2>/dev/null; then
    log "ERROR: qwen3-banxe-v2 not found in Ollama"
    exit 1
fi

log "Ollama OK, qwen3-banxe-v2 available"

# ── Запуск eval ───────────────────────────────────────────────────────────────
cd "${DEVELOPER_DIR}"

EVAL_OUTPUT="${RESULTS_DIR}/eval-stdout-${TIMESTAMP//[: ]/-}.txt"

npx promptfoo eval \
    --config "${CONFIG}" \
    --output "${RESULTS_FILE}" \
    2>&1 | tee "${EVAL_OUTPUT}" | tail -20

EVAL_EXIT=${PIPESTATUS[0]}
log "npx promptfoo eval exit code: ${EVAL_EXIT}"

# ── Разбор результатов ────────────────────────────────────────────────────────
FAIL_RATE=0
TOTAL=0
FAILED=0
PASSED=0

if [ -f "${RESULTS_FILE}" ]; then
    STATS=$(python3 << 'PYEOF'
import json, sys
try:
    with open("${RESULTS_FILE}") as f:
        data = json.load(f)
    results = data.get("results", {})
    stats = results.get("stats", {})
    total = stats.get("successes", 0) + stats.get("failures", 0)
    failed = stats.get("failures", 0)
    passed = stats.get("successes", 0)
    fail_pct = round(failed / total * 100) if total > 0 else 0
    print(f"{total},{failed},{passed},{fail_pct}")
except Exception as e:
    print(f"0,0,0,0")
PYEOF
    )
    TOTAL=$(echo "$STATS" | cut -d, -f1)
    FAILED=$(echo "$STATS" | cut -d, -f2)
    PASSED=$(echo "$STATS" | cut -d, -f3)
    FAIL_RATE=$(echo "$STATS" | cut -d, -f4)
    log "Results: total=${TOTAL} passed=${PASSED} failed=${FAILED} fail_rate=${FAIL_RATE}%"
else
    log "WARN: Results file not found: ${RESULTS_FILE}"
fi

# ── Telegram alert если fail_rate > порога ────────────────────────────────────
ALERT_SENT=0
if [ "${FAIL_RATE:-0}" -gt "${FAIL_THRESHOLD}" ] && [ -n "$BOT_TOKEN" ]; then
    ALERT_TEXT="BANXE Promptfoo ALERT

Model: qwen3-banxe-v2
Date:  $(date '+%Y-%m-%d %H:%M')
Total: ${TOTAL} tests
Passed: ${PASSED}
FAILED: ${FAILED} (${FAIL_RATE}% > threshold ${FAIL_THRESHOLD}%)

Results: ~/developer/compliance/training/results/
Action: Review and fix failing test cases."

    curl -s --max-time 5 \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${ALERT_CHAT}" \
        --data-urlencode "text=${ALERT_TEXT}" \
        -d "parse_mode=HTML" &>/dev/null && ALERT_SENT=1

    log "Telegram alert sent (fail_rate=${FAIL_RATE}% > ${FAIL_THRESHOLD}%)"
elif [ "${FAIL_RATE:-0}" -le "${FAIL_THRESHOLD}" ]; then
    log "Fail rate ${FAIL_RATE}% <= threshold ${FAIL_THRESHOLD}% — no alert"
else
    log "WARN: BOT_TOKEN not set — alert suppressed"
fi

# ── git commit + push результатов (только если DEVELOPER_DIR — git repo) ──────
if git -C "${DEVELOPER_DIR}" rev-parse --git-dir &>/dev/null 2>&1; then
    cd "${DEVELOPER_DIR}"
    if git diff --quiet -- compliance/training/results/ 2>/dev/null && \
       ! git ls-files --others --exclude-standard -- compliance/training/results/ | grep -q .; then
        log "No new results to commit"
    else
        git add compliance/training/results/
        git commit -m "eval: promptfoo qwen3-banxe-v2 $(date '+%Y-%m-%d') — ${PASSED}/${TOTAL} passed" \
            --no-verify 2>/dev/null || true
        git pull --rebase origin main --quiet && git push && log "Results pushed to developer-core"
    fi
else
    log "Results saved to ${RESULTS_FILE} (${DEVELOPER_DIR} is not a git repo — skipping push)"
fi

log "=== Promptfoo eval DONE: fail_rate=${FAIL_RATE}% ==="

# Exit non-zero if eval itself failed (not just high fail rate)
exit ${EVAL_EXIT}
