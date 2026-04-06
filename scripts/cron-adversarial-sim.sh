#!/usr/bin/env bash
# cron-adversarial-sim.sh — wrapper for adversarial simulation cron job
#
# Crontab entry (GMKtec, run every 6 hours):
#   0 */6 * * * /data/vibe-coding/scripts/cron-adversarial-sim.sh
#
# Or Sunday 02:00 (aligned with existing banxe-adversarial cron):
#   0 2 * * 0 root bash /data/vibe-coding/scripts/cron-adversarial-sim.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${REPO_DIR}/logs"
CORPUS_DIR="${REPO_DIR}/src/compliance/training/corpus"
DATE=$(date +%Y%m%d)
OUTFILE="${LOG_DIR}/adversarial-${DATE}.jsonl"
ERRFILE="${LOG_DIR}/adversarial-errors.log"

mkdir -p "${LOG_DIR}"

echo "[$(date -Iseconds)] adversarial-sim starting" >> "${ERRFILE}"

python3 "${REPO_DIR}/src/compliance/training/adversarial_sim.py" \
    --corpus-dir "${CORPUS_DIR}" \
    --json \
    >> "${OUTFILE}" 2>> "${ERRFILE}"

EXIT_CODE=$?

if [ "${EXIT_CODE}" -ne 0 ]; then
    echo "[$(date -Iseconds)] ERROR: adversarial_sim exited ${EXIT_CODE}" >> "${ERRFILE}"
    exit "${EXIT_CODE}"
fi

echo "[$(date -Iseconds)] adversarial-sim done → ${OUTFILE}" >> "${ERRFILE}"
