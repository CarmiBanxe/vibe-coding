#!/usr/bin/env bash
# deploy-backlog-phase16.sh — деплой всех задач Phase 16 на GMKtec
#
# Запускать с Legion:
#   cd ~/vibe-coding && git pull && bash scripts/deploy-backlog-phase16.sh
#
# Что делает:
#   1. git pull последних изменений на GMKtec
#   2. pip install mkdocs + build docs
#   3. chmod + crontab для quality monitoring scripts
#   4. Запуск export-openapi-schema.sh
#   5. Запуск test-backup-clickhouse.sh --dry-run
#   6. Копирование Marble SKILL.md в workspace бота
#   7. Перезапуск OpenClaw для подгрузки нового SKILL.md

set -euo pipefail

REMOTE_REPO="/data/vibe-coding"
BOT_WORKSPACE="/home/mmber/.openclaw/workspace-moa"

echo "=========================================="
echo "  deploy-backlog-phase16.sh"
echo "  Цель: GMKtec ($(date -Iseconds))"
echo "=========================================="

ssh gmktec bash -s << 'REMOTE'
set -euo pipefail
REMOTE_REPO="/data/vibe-coding"
BOT_WORKSPACE="/home/mmber/.openclaw/workspace-moa"

echo ""
echo "── [1/7] git pull на GMKtec ────────────────────────────"
cd "${REMOTE_REPO}"
git pull --rebase origin main
echo "OK: $(git log --oneline -1)"

echo ""
echo "── [2/7] MkDocs install + build ───────────────────────"
if ! which mkdocs > /dev/null 2>&1; then
    pip install mkdocs-material mkdocstrings[python] 2>&1 | tail -3
fi
cd "${REMOTE_REPO}"
mkdocs build --strict --quiet 2>&1 || {
    echo "WARN: mkdocs build had warnings (non-fatal)"
}
echo "OK: site/ created ($(ls site/*.html 2>/dev/null | wc -l) HTML files)"

echo ""
echo "── [3/7] cron — quality monitoring scripts ─────────────"
chmod +x "${REMOTE_REPO}/scripts/cron-adversarial-sim.sh"
chmod +x "${REMOTE_REPO}/scripts/cron-deepeval-report.sh"

# Install cron entries if not already there
CRON_ADV="0 2 * * 0 root bash ${REMOTE_REPO}/scripts/cron-adversarial-sim.sh"
CRON_EVL="0 3 * * 1 root bash ${REMOTE_REPO}/scripts/cron-deepeval-report.sh"

CRON_FILE="/etc/cron.d/banxe-quality-monitoring"
if [[ ! -f "${CRON_FILE}" ]]; then
    cat > "${CRON_FILE}" << CRONEOF
# Banxe quality monitoring cron jobs
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Adversarial simulation — Sunday 02:00
${CRON_ADV}
# DeepEval weekly report — Monday 03:00
${CRON_EVL}
CRONEOF
    echo "OK: ${CRON_FILE} created"
else
    echo "OK: ${CRON_FILE} already exists"
fi

echo ""
echo "── [4/7] OpenAPI schema export ─────────────────────────"
bash "${REMOTE_REPO}/scripts/export-openapi-schema.sh" 2>&1 || echo "WARN: export skipped (API not running)"

echo ""
echo "── [5/7] ClickHouse backup dry-run ─────────────────────"
bash "${REMOTE_REPO}/scripts/test-backup-clickhouse.sh" --dry-run 2>&1

echo ""
echo "── [6/7] Marble SKILL.md → bot workspace ───────────────"
MARBLE_SKILL_SRC="${REMOTE_REPO}/workspace-moa/skills/marble-cases"
MARBLE_SKILL_DST="${BOT_WORKSPACE}/skills/marble-cases"
mkdir -p "${MARBLE_SKILL_DST}"
cp "${MARBLE_SKILL_SRC}/SKILL.md" "${MARBLE_SKILL_DST}/SKILL.md"
echo "OK: SKILL.md copied → ${MARBLE_SKILL_DST}/SKILL.md"

echo ""
echo "── [7/7] Restart OpenClaw to reload SKILL.md ───────────"
systemctl restart openclaw-gateway-moa
sleep 3
STATUS=$(systemctl is-active openclaw-gateway-moa 2>/dev/null || echo "unknown")
echo "OpenClaw status: ${STATUS}"

echo ""
echo "=========================================="
echo "  deploy-backlog-phase16.sh COMPLETE"
echo "=========================================="
REMOTE

echo ""
echo "LOCAL: verifying docs/COMPLIANCE_ARCH.md sync..."
diff docs/COMPLIANCE_ARCH.md src/compliance/COMPLIANCE_ARCH.md && echo "OK: IDENTICAL" || echo "WARN: files differ"
