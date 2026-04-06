#!/bin/bash
# diagnose-ports-and-services.sh
# Диагностика: порт 18793, 8090/8091, HITL Dashboard
# Запуск: cd ~/vibe-coding && git pull && bash scripts/diagnose-ports-and-services.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MEMORY_FILE="$REPO_DIR/docs/MEMORY.md"
REPORT_FILE="$REPO_DIR/docs/diagnostic-report.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M CEST')

echo "=============================================="
echo "  Banxe Diagnostic: Ports & Services"
echo "  $TIMESTAMP"
echo "=============================================="

# ── 1. SSH connectivity check ──────────────────────────────────────────────
echo ""
echo "[1/5] Проверка SSH соединения с GMKtec..."
if ! ssh -o ConnectTimeout=10 -q gmktec exit 2>/dev/null; then
  echo "  ОШИБКА: SSH недоступен. Проверь VPN / сеть."
  exit 1
fi
echo "  OK: SSH gmktec доступен."

# ── 2. Run full remote diagnostics ─────────────────────────────────────────
echo ""
echo "[2/5] Сбор данных с GMKtec..."

REMOTE_OUTPUT=$(ssh gmktec bash << 'ENDSSH'
echo "=== PORT 18793 ==="
PID_18793=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:18793$/ {match($0, /pid=([0-9]+)/, a); print a[1]}')
if [ -n "$PID_18793" ]; then
  echo "STATUS: ACTIVE (pid=$PID_18793)"
  echo "CMDLINE: $(cat /proc/$PID_18793/cmdline 2>/dev/null | tr '\0' ' ')"
  echo "SERVICE: $(systemctl status --no-pager 2>/dev/null | grep -l "MainPID=$PID_18793" /etc/systemd/system/*.service 2>/dev/null || echo unknown)"
  # find service by pid
  SVC=$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | \
        awk '{print $1}' | \
        while read s; do
          pid=$(systemctl show "$s" --property=MainPID --value 2>/dev/null)
          [ "$pid" = "$PID_18793" ] && echo "$s" && break
        done)
  echo "SERVICE_NAME: ${SVC:-not_found}"
else
  echo "STATUS: INACTIVE (port 18793 not listening)"
  # check if service exists
  for svc in openclaw-gateway-mycarmibot openclaw-gateway-default openclaw-gateway-18793; do
    if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc"; then
      echo "SERVICE_FILE: $svc.service exists ($(systemctl is-active $svc.service 2>/dev/null || echo unknown))"
    fi
  done
fi

echo ""
echo "=== PORT 8090 ==="
PID_8090=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:8090$/ {match($0, /pid=([0-9]+)/, a); print a[1]}')
if [ -n "$PID_8090" ]; then
  echo "STATUS: ACTIVE (pid=$PID_8090)"
  echo "CMDLINE: $(cat /proc/$PID_8090/cmdline 2>/dev/null | tr '\0' ' ')"
  echo "USER: $(ps -o user= -p $PID_8090 2>/dev/null)"
  echo "WORKDIR: $(ls -la /proc/$PID_8090/cwd 2>/dev/null | awk '{print $NF}')"
  SVC=$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | \
        awk '{print $1}' | \
        while read s; do
          pid=$(systemctl show "$s" --property=MainPID --value 2>/dev/null)
          [ "$pid" = "$PID_8090" ] && echo "$s" && break
        done)
  echo "SERVICE_NAME: ${SVC:-not_found}"
else
  echo "STATUS: INACTIVE"
fi

echo ""
echo "=== PORT 8091 ==="
PID_8091=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:8091$/ {match($0, /pid=([0-9]+)/, a); print a[1]}')
if [ -n "$PID_8091" ]; then
  echo "STATUS: ACTIVE (pid=$PID_8091)"
  echo "CMDLINE: $(cat /proc/$PID_8091/cmdline 2>/dev/null | tr '\0' ' ')"
  echo "USER: $(ps -o user= -p $PID_8091 2>/dev/null)"
  echo "WORKDIR: $(ls -la /proc/$PID_8091/cwd 2>/dev/null | awk '{print $NF}')"
  SVC=$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | \
        awk '{print $1}' | \
        while read s; do
          pid=$(systemctl show "$s" --property=MainPID --value 2>/dev/null)
          [ "$pid" = "$PID_8091" ] && echo "$s" && break
        done)
  echo "SERVICE_NAME: ${SVC:-not_found}"
else
  echo "STATUS: INACTIVE"
fi

echo ""
echo "=== HITL DASHBOARD ==="
SVC_STATUS=$(systemctl is-active hitl-dashboard.service 2>/dev/null || echo "unknown")
echo "SERVICE_STATUS: $SVC_STATUS"
if [ "$SVC_STATUS" = "active" ]; then
  PID_HITL=$(systemctl show hitl-dashboard.service --property=MainPID --value 2>/dev/null)
  echo "PID: $PID_HITL"
  echo "CMDLINE: $(cat /proc/$PID_HITL/cmdline 2>/dev/null | tr '\0' ' ')"
  echo "USER: $(ps -o user= -p $PID_HITL 2>/dev/null)"
  echo "WORKDIR: $(ls -la /proc/$PID_HITL/cwd 2>/dev/null | awk '{print $NF}')"
  # find listening port
  HITL_PORT=$(ss -tlnp 2>/dev/null | awk -v pid="$PID_HITL" '$0 ~ "pid="pid {split($4, a, ":"); print a[length(a)]}' | head -1)
  echo "PORT: ${HITL_PORT:-unknown}"
  # check service file
  echo "--- SERVICE FILE ---"
  systemctl cat hitl-dashboard.service 2>/dev/null | head -20
fi

echo ""
echo "=== ALL ACTIVE OPENCLAW SERVICES ==="
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | grep -i openclaw || echo "none"

echo ""
echo "=== ALL PYTHON PROCESSES ==="
ps aux 2>/dev/null | grep -E '[p]ython' | grep -v grep | awk '{print $1, $2, substr($0, index($0,$11))}'

ENDSSH
)

echo "$REMOTE_OUTPUT"

# ── 3. Parse results ────────────────────────────────────────────────────────
echo ""
echo "[3/5] Анализ результатов..."

PORT_18793_STATUS=$(echo "$REMOTE_OUTPUT" | grep -A1 "=== PORT 18793 ===" | grep "STATUS:" | awk '{print $2}')
PORT_8090_STATUS=$(echo "$REMOTE_OUTPUT"  | grep -A1 "=== PORT 8090 ===" | grep "STATUS:" | awk '{print $2}')
PORT_8091_STATUS=$(echo "$REMOTE_OUTPUT"  | grep -A1 "=== PORT 8091 ===" | grep "STATUS:" | awk '{print $2}')
HITL_SVC_STATUS=$(echo "$REMOTE_OUTPUT"   | grep -A1 "=== HITL DASHBOARD ===" | grep "SERVICE_STATUS:" | awk '{print $2}')

echo "  Порт 18793 (@mycarmibot): $PORT_18793_STATUS"
echo "  Порт 8090:                $PORT_8090_STATUS"
echo "  Порт 8091:                $PORT_8091_STATUS"
echo "  HITL Dashboard service:   $HITL_SVC_STATUS"

# ── 4. Write diagnostic report ─────────────────────────────────────────────
echo ""
echo "[4/5] Запись diagnostic-report.md..."

cat > "$REPORT_FILE" << ENDREPORT
# Diagnostic Report — Ports & Services
> Сформирован: $TIMESTAMP
> Скрипт: scripts/diagnose-ports-and-services.sh

## Резюме

| Объект | Статус |
|--------|--------|
| Порт 18793 (@mycarmibot) | $PORT_18793_STATUS |
| Порт 8090 | $PORT_8090_STATUS |
| Порт 8091 | $PORT_8091_STATUS |
| hitl-dashboard.service | $HITL_SVC_STATUS |

## Полный вывод с GMKtec

\`\`\`
$REMOTE_OUTPUT
\`\`\`
ENDREPORT

echo "  Записан: docs/diagnostic-report.md"

# ── 5. Git commit & push ────────────────────────────────────────────────────
echo ""
echo "[5/5] Git commit & push..."
cd "$REPO_DIR"
git add docs/diagnostic-report.md
git commit -m "diag: ports 18793/8090/8091 + HITL Dashboard scan ($TIMESTAMP)"
git push origin main

echo ""
echo "=============================================="
echo "  ГОТОВО. Результаты: docs/diagnostic-report.md"
echo "=============================================="
