#!/usr/bin/env bash
# deploy-gap5-drift-monitor.sh — GAP 5: деплой evidently drift monitoring cron (каждые 6ч)
# Запускать с Legion:
#   cd ~/vibe-coding && git pull && bash scripts/deploy-gap5-drift-monitor.sh
set -euo pipefail

echo "=========================================="
echo "  deploy-gap5-drift-monitor.sh"
echo "  Цель: GMKtec ($(date -Iseconds))"
echo "=========================================="

ssh gmktec bash -s << 'REMOTE'
set -euo pipefail

REMOTE_REPO="/data/vibe-coding"
DRIFT_SCRIPT="${REMOTE_REPO}/scripts/run-drift-monitor.sh"
CRON_FILE="/etc/cron.d/banxe-drift-monitor"
LOG_DIR="/data/logs"

echo ""
echo "── [1/4] git pull на GMKtec ────────────────────────────"
cd "${REMOTE_REPO}"
git pull --rebase origin main
echo "OK: $(git log --oneline -1)"

echo ""
echo "── [2/4] Подготовка директорий и скрипта ──────────────"
mkdir -p "${LOG_DIR}" "/data/banxe/promptfoo/compliance/training/drift-reports"
chmod +x "${DRIFT_SCRIPT}"
echo "OK: run-drift-monitor.sh готов"

echo ""
echo "── [3/4] Cron — каждые 6 часов ────────────────────────"
cat > "${CRON_FILE}" << 'CRONEOF'
# GAP 5: Evidently drift monitoring — каждые 6 часов
# Проверяет corpus JSONL на признаки дрейфа модели
# Alert в Telegram если composite_drift > 0.15
0 */6 * * * root DEVELOPER_DIR=/data/banxe/promptfoo bash /data/vibe-coding/scripts/run-drift-monitor.sh >> /data/logs/drift-monitor.log 2>&1
CRONEOF
chmod 0644 "${CRON_FILE}"
echo "OK: cron задача установлена → ${CRON_FILE}"
cat "${CRON_FILE}"

echo ""
echo "── [4/4] Первый запуск drift monitor ──────────────────"
DEVELOPER_DIR=/data/banxe/promptfoo bash "${DRIFT_SCRIPT}" || true
echo ""
echo "Результат (drift_latest.json):"
cat /data/banxe/promptfoo/compliance/training/drift-reports/drift_latest.json 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f'  status       : {d.get(\"status\")}')
print(f'  composite    : {d.get(\"composite_drift\", 0)}')
print(f'  alert        : {d.get(\"alert\", False)}')
print(f'  total entries: {d.get(\"total_entries\", 0)}')
print(f'  evidently    : {\"available\" if \"evidently_drift\" in d else d.get(\"evidently_note\", \"n/a\")}')
" 2>/dev/null || echo "  (no corpus yet — first report will appear after train-agent.sh run)"

echo ""
echo "=========================================="
echo "  deploy-gap5-drift-monitor.sh COMPLETE"
echo "  Cron: 0 */6 * * * (каждые 6 часов)"
echo "  Alert threshold: 0.15"
echo "  Log: /data/logs/drift-monitor.log"
echo "=========================================="
REMOTE

REMOTE_EXIT=$?
if [ $REMOTE_EXIT -eq 0 ]; then
  echo ""
  echo "GAP 5 задеплоен успешно:"
  echo "  - run-drift-monitor.sh → /data/vibe-coding/scripts/"
  echo "  - Cron: /etc/cron.d/banxe-drift-monitor (0 */6 * * *)"
  echo "  - Порог алерта: composite_drift > 0.15"
  echo "  - Отчёты: /data/banxe/promptfoo/compliance/training/drift-reports/"
fi
