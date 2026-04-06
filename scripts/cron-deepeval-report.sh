#!/usr/bin/env bash
# cron-deepeval-report.sh — weekly DeepEval quality report
#
# Crontab entry (GMKtec, every Monday 03:00):
#   0 3 * * 1 root bash /data/vibe-coding/scripts/cron-deepeval-report.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="${REPO_DIR}/reports"
CORPUS_DIR="${REPO_DIR}/src/compliance/training/corpus"
DATE=$(date +%Y%m%d)
OUTFILE="${REPORT_DIR}/deepeval-${DATE}.json"
ERRFILE="${REPO_DIR}/logs/deepeval-errors.log"

mkdir -p "${REPORT_DIR}" "${REPO_DIR}/logs"

echo "[$(date -Iseconds)] deepeval-report starting" >> "${ERRFILE}"

python3 "${REPO_DIR}/src/compliance/training/deepeval_runner.py" \
    --corpus-dir "${CORPUS_DIR}" \
    --json \
    > "${OUTFILE}" 2>> "${ERRFILE}"

EXIT_CODE=$?

if [ "${EXIT_CODE}" -ne 0 ]; then
    echo "[$(date -Iseconds)] ERROR: deepeval_runner exited ${EXIT_CODE}" >> "${ERRFILE}"
    exit "${EXIT_CODE}"
fi

LINES=$(wc -l < "${OUTFILE}" 2>/dev/null || echo "?")
echo "[$(date -Iseconds)] deepeval-report done → ${OUTFILE} (${LINES} lines)" >> "${ERRFILE}"
