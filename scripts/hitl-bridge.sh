#!/usr/bin/env bash
# hitl-bridge.sh — HITL Integration Bridge
#
# Вызывается из verification_graph.py node_hitl_interrupt когда hitl_required=true.
# Что делает:
#   1. Создаёт кейс в Marble Case Management (порт 5002)
#   2. Отправляет Telegram уведомление CEO + Oleg через Bot API
#   3. Graceful degradation: если Marble недоступен — только Telegram
#
# Аргументы (все позиционные, все опциональны):
#   $1 = agent_id        (default: unknown)
#   $2 = agent_role      (default: Agent)
#   $3 = consensus       (default: UNCERTAIN)
#   $4 = reason          (default: HITL required)
#   $5 = statement       (default: "")
#   $6 = drift_score     (default: 0)
#
# Или через env vars:
#   HITL_AGENT_ID, HITL_AGENT_ROLE, HITL_CONSENSUS, HITL_REASON, HITL_STATEMENT, HITL_DRIFT
#
# Возвращает:
#   0 = успех (минимум Telegram отправлен)
#   1 = полный сбой
#
# На GMKtec: /data/vibe-coding/scripts/hitl-bridge.sh
# Логи:      /data/logs/hitl-bridge.log

set -uo pipefail

LOG_FILE="/data/logs/hitl-bridge.log"
MARBLE_API="http://localhost:5002"
ENV_FILE="/data/banxe/.env"

# ── Параметры ─────────────────────────────────────────────────────────────────
AGENT_ID="${1:-${HITL_AGENT_ID:-unknown}}"
AGENT_ROLE="${2:-${HITL_AGENT_ROLE:-Agent}}"
CONSENSUS="${3:-${HITL_CONSENSUS:-UNCERTAIN}}"
REASON="${4:-${HITL_REASON:-HITL required}}"
STATEMENT="${5:-${HITL_STATEMENT:-}}"
DRIFT="${6:-${HITL_DRIFT:-0}}"

TIMESTAMP=$(date -Iseconds)
CASE_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")

# ── Логирование ───────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
log() {
    echo "[$TIMESTAMP] $*" | tee -a "$LOG_FILE"
}

log "HITL-BRIDGE START: agent=${AGENT_ID} role=${AGENT_ROLE} consensus=${CONSENSUS}"

# ── Загрузка .env ─────────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

# Telegram bot token — из env или .env
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-${MOA_BOT_TOKEN:-}}"
# Получатели: CEO Mark (508602494) + Oleg если известен его ID
TELEGRAM_RECIPIENTS="${HITL_TELEGRAM_RECIPIENTS:-508602494}"

# ── Формат уведомления ────────────────────────────────────────────────────────
STMT_SHORT="${STATEMENT:0:200}"
if [ ${#STATEMENT} -gt 200 ]; then
    STMT_SHORT="${STMT_SHORT}..."
fi

NOTIFICATION_TEXT="BANXE HITL REVIEW REQUIRED

Agent:     ${AGENT_ID} (${AGENT_ROLE})
Consensus: ${CONSENSUS}
Drift:     ${DRIFT}
Reason:    ${REASON}
Case:      ${CASE_ID}
Statement: ${STMT_SHORT}

Action: Review in Marble UI → http://[gmktec]:5003"

# ── [1] Создание кейса в Marble ───────────────────────────────────────────────
MARBLE_OK=0
MARBLE_CASE_ID=""

MARBLE_PAYLOAD=$(python3 -c "
import json, sys
payload = {
    'name': 'HITL Review — ${AGENT_ROLE} (${CONSENSUS})',
    'status': 'pending_review',
    'decision': 'HOLD',
    'risk_score': 50,
    'requires_edd': True,
    'requires_mlro': True,
    'signals': [{'rule': 'HITL_VERIFICATION_${CONSENSUS}', 'score': 50, 'reason': '${REASON}'}],
    'audit_payload': {
        'case_id': '${CASE_ID}',
        'agent_id': '${AGENT_ID}',
        'agent_role': '${AGENT_ROLE}',
        'consensus': '${CONSENSUS}',
        'drift_score': '${DRIFT}',
        'policy_version': 'developer-core@2026-04-05',
        'statement': '${STMT_SHORT}'.replace(\"'\", '')
    }
}
print(json.dumps(payload))
" 2>/dev/null || echo '{}')

if [ "$MARBLE_PAYLOAD" != "{}" ]; then
    MARBLE_RESP=$(curl -s --max-time 5 -X POST "${MARBLE_API}/api/cases" \
        -H "Content-Type: application/json" \
        ${MARBLE_API_KEY:+-H "Authorization: Bearer ${MARBLE_API_KEY}"} \
        -d "${MARBLE_PAYLOAD}" 2>/dev/null || echo '{"error":"unreachable"}')

    MARBLE_CASE_ID=$(echo "$MARBLE_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")

    if [ -n "$MARBLE_CASE_ID" ]; then
        MARBLE_OK=1
        log "Marble case created: ${MARBLE_CASE_ID}"
        NOTIFICATION_TEXT="${NOTIFICATION_TEXT}
Marble Case: ${MARBLE_CASE_ID}"
    else
        log "WARN: Marble unavailable or failed. Response: ${MARBLE_RESP:0:200}"
    fi
else
    log "WARN: Failed to build Marble payload"
fi

# ── [2] Telegram уведомление ──────────────────────────────────────────────────
TELEGRAM_OK=0

if [ -z "$BOT_TOKEN" ]; then
    log "WARN: TELEGRAM_BOT_TOKEN not set — skipping Telegram notification"
else
    IFS=',' read -ra CHAT_IDS <<< "$TELEGRAM_RECIPIENTS"
    for CHAT_ID in "${CHAT_IDS[@]}"; do
        CHAT_ID="${CHAT_ID// /}"
        [ -z "$CHAT_ID" ] && continue

        TG_RESP=$(curl -s --max-time 5 \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${CHAT_ID}" \
            --data-urlencode "text=${NOTIFICATION_TEXT}" \
            -d "parse_mode=HTML" 2>/dev/null || echo '{"ok":false}')

        TG_OK=$(echo "$TG_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok', False))" 2>/dev/null || echo "false")

        if [ "$TG_OK" = "True" ] || [ "$TG_OK" = "true" ]; then
            TELEGRAM_OK=1
            log "Telegram sent to chat_id=${CHAT_ID}"
        else
            log "WARN: Telegram failed for chat_id=${CHAT_ID}: ${TG_RESP:0:100}"
        fi
    done
fi

# ── Итоговый статус ───────────────────────────────────────────────────────────
if [ $MARBLE_OK -eq 1 ] && [ $TELEGRAM_OK -eq 1 ]; then
    log "HITL-BRIDGE SUCCESS: marble=${MARBLE_CASE_ID} telegram=OK"
    echo "marble_case_id=${MARBLE_CASE_ID}"
    exit 0
elif [ $MARBLE_OK -eq 0 ] && [ $TELEGRAM_OK -eq 0 ]; then
    log "HITL-BRIDGE FAILURE: both Marble and Telegram failed"
    exit 1
else
    log "HITL-BRIDGE PARTIAL: marble=${MARBLE_OK} telegram=${TELEGRAM_OK}"
    echo "marble_case_id=${MARBLE_CASE_ID}"
    exit 0
fi
