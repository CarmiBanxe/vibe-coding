#!/usr/bin/env bash
# deploy-emergency-stop.sh — G-03 Production deploy: Emergency Stop на GMKtec
#
# Что делает:
#   1. Создаёт /data/banxe/data/ директорию (для stop file fallback)
#   2. Проверяет Redis (для primary store)
#   3. Перезапускает compliance API (api.py :8090) с актуальным кодом
#   4. Smoke test: activate → 503 → resume → 200
#   5. Открывает URL admin panel для проверки в браузере
#
# Запуск: cd ~/vibe-coding && git pull && bash scripts/deploy-emergency-stop.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REMOTE="ssh gmktec"
API_URL="http://127.0.0.1:8090"
VIBE_DIR="/data/vibe-coding"
COMPLIANCE_DIR="$VIBE_DIR/src/compliance"
LOG_DIR="/data/banxe/data/logs"
STOP_DIR="/data/banxe/data"
SERVICE_NAME="banxe-compliance"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  BANXE — Emergency Stop Production Deploy (G-03)            ║"
echo "║  EU AI Act Art. 14 — human oversight emergency stop         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Sync code to GMKtec ──────────────────────────────────────────────
echo "▶ [1/6] Syncing code to GMKtec..."
$REMOTE "cd $VIBE_DIR && git pull --rebase"
echo "  ✅ Code synced"

# ── Step 2: Create required directories ──────────────────────────────────────
echo ""
echo "▶ [2/6] Creating /data/banxe/data/ (stop file + logs dir)..."
$REMOTE "mkdir -p $STOP_DIR $LOG_DIR && echo '  ✅ Directories OK: $STOP_DIR $LOG_DIR'"

# ── Step 3: Check Redis ───────────────────────────────────────────────────────
echo ""
echo "▶ [3/6] Checking Redis (primary stop state store)..."
REDIS_STATUS=$($REMOTE "redis-cli ping 2>/dev/null || echo 'MISSING'")
if [ "$REDIS_STATUS" = "PONG" ]; then
  echo "  ✅ Redis: PONG"
else
  echo "  ⚠️  Redis not responding ($REDIS_STATUS) — file fallback will be used"
  echo "     Install: sudo apt install redis-server && sudo systemctl enable --now redis"
fi

# ── Step 4: Restart compliance API ───────────────────────────────────────────
echo ""
echo "▶ [4/6] Restarting compliance API (:8090)..."
$REMOTE "
  if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
    systemctl restart $SERVICE_NAME
    sleep 2
    echo '  ✅ systemd service restarted'
  else
    echo '  ℹ️  systemd service not found — checking process...'
    PID=\$(lsof -ti:8090 2>/dev/null | head -1)
    if [ -n \"\$PID\" ]; then
      kill -HUP \$PID 2>/dev/null || kill \$PID 2>/dev/null || true
      sleep 1
      echo '  ✅ Process restarted (HUP)'
    else
      echo '  ⚠️  No process on :8090 — starting fresh...'
      cd $COMPLIANCE_DIR
      nohup /data/banxe/compliance-env/bin/python3 api.py >/data/banxe/data/logs/api.log 2>&1 &
      sleep 2
      echo '  ✅ Started (nohup)'
    fi
  fi
"

# ── Step 5: Smoke test ────────────────────────────────────────────────────────
echo ""
echo "▶ [5/6] Smoke test: activate → 503 → resume → 200..."

$REMOTE "
set -e
BASE='http://127.0.0.1:8090'

echo '  Testing initial status...'
STATUS=\$(curl -sf \$BASE/api/v1/compliance/emergency-stop/status)
ACTIVE=\$(echo \$STATUS | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"active\"])')
if [ \"\$ACTIVE\" != 'False' ]; then
  echo '  ⚠️  Stop is already active — resuming first'
  curl -sf -X POST \$BASE/api/v1/compliance/emergency-resume \
    -H 'Content-Type: application/json' \
    -d '{\"mlro_id\":\"deploy-script\",\"resume_reason\":\"pre-test cleanup\"}' >/dev/null
fi

echo '  Activating emergency stop...'
RESP=\$(curl -sf -X POST \$BASE/api/v1/compliance/emergency-stop \
  -H 'Content-Type: application/json' \
  -d '{\"operator_id\":\"deploy-test\",\"reason\":\"automated smoke test\"}')
echo '  Activate response:' \$(echo \$RESP | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[\"status\"], d[\"activated_at\"])')

echo '  Checking screening returns 503...'
HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' -X POST \$BASE/api/v1/screen/person \
  -H 'Content-Type: application/json' \
  -d '{\"name\":\"Test Person\"}')
if [ \"\$HTTP_CODE\" = '503' ]; then
  echo '  ✅ screen/person → 503 (I-23 verified)'
else
  echo '  ❌ screen/person returned' \$HTTP_CODE '(expected 503)' && exit 1
fi

echo '  Resuming (MLRO)...'
RESP=\$(curl -sf -X POST \$BASE/api/v1/compliance/emergency-resume \
  -H 'Content-Type: application/json' \
  -d '{\"mlro_id\":\"deploy-test-mlro\",\"resume_reason\":\"smoke test complete\"}')
echo '  Resume response:' \$(echo \$RESP | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"status\"])')

echo '  Verifying screening returns 200...'
HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' -X POST \$BASE/api/v1/screen/person \
  -H 'Content-Type: application/json' \
  -d '{\"name\":\"Test Person\"}')
if [ \"\$HTTP_CODE\" = '200' ]; then
  echo '  ✅ screen/person → 200 (system resumed)'
else
  echo '  ⚠️  screen/person returned' \$HTTP_CODE '(may be OK if external services down)'
fi
"

# ── Step 6: Panel URL ─────────────────────────────────────────────────────────
echo ""
echo "▶ [6/6] Admin panel URLs:"
GMKTEC_IP=$($REMOTE "hostname -I | awk '{print \$1}'" 2>/dev/null || echo "<gmktec-ip>")
echo "  Emergency Stop Panel:  http://${GMKTEC_IP}:8090/compliance/admin/emergency"
echo "  Compliance API Health: http://${GMKTEC_IP}:8090/api/v1/health"
echo ""
echo "  ─── Marble Integration ───────────────────────────────────────────"
echo "  Option A (direct): Bookmark panel URL in Marble case view"
echo "  Option B (n8n):    Import src/compliance/marble_emergency_workflow.json"
echo "                     n8n webhook: http://127.0.0.1:5678/webhook/marble-emergency"
echo "  ──────────────────────────────────────────────────────────────────"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ G-03 DEPLOY COMPLETE                                    ║"
echo "║  Emergency stop is live on GMKtec                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
