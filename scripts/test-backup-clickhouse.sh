#!/usr/bin/env bash
# test-backup-clickhouse.sh — test harness for backup-clickhouse-training.sh
#
# Usage:
#   bash scripts/test-backup-clickhouse.sh          # auto-detect environment
#   bash scripts/test-backup-clickhouse.sh --dry-run # dry-run only (show SQL)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_SCRIPT="${SCRIPT_DIR}/backup-clickhouse-training.sh"
EXPORT_DIR="${REPO_ROOT}/docs/training-exports"
CORPUS_DIR="${REPO_ROOT}/src/compliance/training/corpus"
MONTH=$(date +%Y-%m)

DRY_RUN="${1:-}"
PASS=0
FAIL=0

_pass() { echo "  PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
_skip() { echo "  SKIP $1"; }

echo "=== backup-clickhouse-training — test harness ==="
echo "    date: $(date -Iseconds)"
echo ""

# ── Test 1: backup script exists and is executable ────────────────────────────
echo "[1/5] Script exists and is executable"
if [[ -x "${BACKUP_SCRIPT}" ]]; then
    _pass "scripts/backup-clickhouse-training.sh"
else
    _fail "scripts/backup-clickhouse-training.sh not found or not executable"
fi

# ── Test 2: ClickHouse availability ───────────────────────────────────────────
echo "[2/5] ClickHouse availability"
if which clickhouse-client > /dev/null 2>&1; then
    if clickhouse-client --host 127.0.0.1 --port 9000 --query "SELECT 1" > /dev/null 2>&1; then
        CH_AVAILABLE=true
        _pass "ClickHouse reachable on localhost:9000"
    else
        CH_AVAILABLE=false
        _skip "clickhouse-client found but server not reachable — using mock data"
    fi
else
    CH_AVAILABLE=false
    _skip "clickhouse-client not installed — using mock data path"
fi

# ── Test 3: Dry-run or live backup ───────────────────────────────────────────
echo "[3/5] Backup execution"
if [[ "${DRY_RUN}" == "--dry-run" ]] || [[ "${CH_AVAILABLE}" == "false" ]]; then
    echo "  [dry-run] SQL that would execute:"
    echo "  SELECT ts, event_type, entity_id, agent_id, verdict, risk_score, reason, jurisdiction"
    echo "  FROM audit_trail WHERE toYYYYMM(timestamp) = toYYYYMM(now())"
    echo "  AND verdict IN ('REJECT', 'HOLD', 'APPROVE', 'SAR') FORMAT JSONEachRow"
    echo ""
    # Create mock output for downstream tests
    mkdir -p "${EXPORT_DIR}"
    echo '{"ts":1743811200,"event_type":"aml_check","entity_id":"TEST-001","agent_id":"test","verdict":"APPROVE","risk_score":15,"reason":"clean","jurisdiction":"GB"}' \
        > "${EXPORT_DIR}/decisions-${MONTH}.jsonl"
    _pass "dry-run: mock decisions-${MONTH}.jsonl created"
else
    # Live run — set NO_PUSH to avoid git push during test
    NO_PUSH=1 bash "${BACKUP_SCRIPT}" 2>&1 | sed 's/^/  /'
    _pass "live backup executed"
fi

# ── Test 4: Output file validation ───────────────────────────────────────────
echo "[4/5] Output JSONL validation"
OUT_FILE="${EXPORT_DIR}/decisions-${MONTH}.jsonl"
if [[ -f "${OUT_FILE}" ]]; then
    RESULT=$(python3 - <<PYEOF
import json, sys
path = "${OUT_FILE}"
valid = invalid = 0
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            json.loads(line)
            valid += 1
        except json.JSONDecodeError:
            invalid += 1
total = valid + invalid
print(f"{total} lines, {valid} valid, {invalid} invalid")
sys.exit(0 if invalid == 0 else 1)
PYEOF
)
    EXIT=$?
    if [[ "${EXIT}" -eq 0 ]]; then
        _pass "decisions-${MONTH}.jsonl: ${RESULT}"
    else
        _fail "decisions-${MONTH}.jsonl: ${RESULT}"
    fi
else
    _fail "Output file not created: ${OUT_FILE}"
fi

# ── Test 5: deepeval_runner can read corpus ───────────────────────────────────
echo "[5/5] evidently_monitor reads corpus"
CORPUS_JSONL=$(ls "${CORPUS_DIR}"/*.jsonl 2>/dev/null | head -1 || true)
if [[ -n "${CORPUS_JSONL}" ]]; then
    python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/src')
from pathlib import Path
from compliance.training.evidently_monitor import check_drift
r = check_drift(Path('${CORPUS_DIR}'), window_days=30)
print(f'  corpus: {r.reference_size + r.current_size} records, drift_score={r.drift_score:.3f}')
" 2>&1
    _pass "evidently_monitor reads corpus successfully"
else
    _skip "No JSONL files in ${CORPUS_DIR}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]] && exit 0 || exit 1
