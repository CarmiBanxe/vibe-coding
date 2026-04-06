#!/bin/bash
# backup-clickhouse-training.sh — Export ClickHouse audit trail for training corpus (D-decisions)
#
# Запускать на GMKtec: bash /data/vibe-coding/scripts/backup-clickhouse-training.sh
# Или с Legion через SSH:
#   cd ~/vibe-coding && bash scripts/backup-clickhouse-training.sh
#
# Экспортирует из ClickHouse:
#   banxe.audit_trail   → decisions-YYYY-MM.jsonl
#   banxe.aml_decisions → aml-YYYY-MM.jsonl
#
# Результат кладётся в docs/training-exports/ и пушится в GitHub.
# GitHub Actions workflow extract-training-data.yml подберёт файлы при следующем push.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
EXPORT_DIR="$REPO_ROOT/docs/training-exports"
MONTH=$(date +%Y-%m)

# --dry-run: show SQL query without executing; exit 0
if [[ "${1:-}" == "--dry-run" ]]; then
    echo "[dry-run] backup-clickhouse-training.sh — would execute:"
    echo "  SELECT ts,event_type,entity_id,agent_id,verdict,risk_score,reason,jurisdiction"
    echo "  FROM banxe.audit_trail WHERE toYYYYMM(timestamp)=toYYYYMM(now())"
    echo "  AND verdict IN ('REJECT','HOLD','APPROVE','SAR') ORDER BY timestamp FORMAT JSONEachRow"
    echo "  → docs/training-exports/decisions-${MONTH}.jsonl"
    exit 0
fi

# If ClickHouse is unreachable — skip gracefully (not exit 1)
if ! clickhouse-client --host 127.0.0.1 --port 9000 --query "SELECT 1" > /dev/null 2>&1; then
    echo "[INFO] ClickHouse not reachable on localhost:9000 — skipping export"
    exit 0
fi

# Запускаем локально или по SSH?
if [[ "$(hostname)" == *"gmktec"* ]] || [[ "$(hostname)" == "gmktec" ]]; then
    REMOTE=false
else
    REMOTE=true
fi

if [[ "$REMOTE" == "true" ]]; then
    echo "[INFO] Запуск через SSH на GMKtec..."
    ssh gmktec "bash /data/vibe-coding/scripts/backup-clickhouse-training.sh"
    echo "[INFO] SSH завершён. Подтягиваю изменения..."
    cd "$REPO_ROOT"
    git pull --rebase origin main
    exit 0
fi

# ─── Локально на GMKtec ────────────────────────────────────────────────

CLICKHOUSE="clickhouse-client --host 127.0.0.1 --port 9000 --database banxe"

mkdir -p "$EXPORT_DIR"

echo "[INFO] Экспорт audit_trail → decisions-${MONTH}.jsonl"

# audit_trail: транзакции + решения AML/KYC
$CLICKHOUSE --query "
SELECT
    toUnixTimestamp(timestamp)   AS ts,
    event_type,
    entity_id,
    agent_id,
    verdict,
    risk_score,
    reason,
    jurisdiction
FROM audit_trail
WHERE toYYYYMM(timestamp) = toYYYYMM(now())
  AND verdict IN ('REJECT', 'HOLD', 'APPROVE', 'SAR')
ORDER BY timestamp
FORMAT JSONEachRow
" > "$EXPORT_DIR/decisions-${MONTH}.jsonl" 2>/dev/null || {
    echo "[WARN] audit_trail export failed — таблица может быть пустой или схема другая"
    echo '{"error":"audit_trail export skipped","month":"'"$MONTH"'"}' > "$EXPORT_DIR/decisions-${MONTH}.jsonl"
}

ROWS=$(wc -l < "$EXPORT_DIR/decisions-${MONTH}.jsonl")
echo "[INFO] decisions-${MONTH}.jsonl: $ROWS строк"

# aml_decisions (если таблица существует)
TABLE_EXISTS=$($CLICKHOUSE --query "EXISTS TABLE banxe.aml_decisions" 2>/dev/null || echo "0")
if [[ "$TABLE_EXISTS" == "1" ]]; then
    echo "[INFO] Экспорт aml_decisions → aml-${MONTH}.jsonl"
    $CLICKHOUSE --query "
    SELECT *
    FROM aml_decisions
    WHERE toYYYYMM(created_at) = toYYYYMM(now())
    ORDER BY created_at
    FORMAT JSONEachRow
    " > "$EXPORT_DIR/aml-${MONTH}.jsonl" 2>/dev/null || true
    echo "[INFO] aml-${MONTH}.jsonl: $(wc -l < "$EXPORT_DIR/aml-${MONTH}.jsonl" 2>/dev/null || echo 0) строк"
fi

# ─── Git commit & push ────────────────────────────────────────────────

cd "$REPO_ROOT"

git add docs/training-exports/
if git diff --cached --quiet; then
    echo "[INFO] Нет новых данных — push пропущен"
else
    git commit -m "corpus: D-decisions export ${MONTH} from ClickHouse audit_trail"
    git push origin main
    echo "[OK] Запушено. GitHub Actions подберёт файл при следующем push."
fi

echo ""
echo "Экспорт завершён:"
echo "  → $EXPORT_DIR/decisions-${MONTH}.jsonl ($ROWS строк)"
echo "  → GitHub Actions workflow extract-training-data.yml скопирует их в banxe-training-data"
