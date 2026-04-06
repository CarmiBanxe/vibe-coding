#!/usr/bin/env bash
# run-drift-monitor.sh — GAP 5: evidently drift monitoring каждые 6 часов
# Запускается на GMKtec cron: 0 */6 * * *
# Usage: DEVELOPER_DIR=/data/banxe/promptfoo bash /data/vibe-coding/scripts/run-drift-monitor.sh
set -euo pipefail

DEVELOPER_DIR="${DEVELOPER_DIR:-/data/banxe/promptfoo}"
COMPLIANCE_DIR="${DEVELOPER_DIR}/compliance"
DRIFT_LOG_DIR="${DEVELOPER_DIR}/compliance/training/drift-reports"
VIBE_DIR="/data/vibe-coding"
BOT_TOKEN="${MOA_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
TELEGRAM_CHAT_ID="508602494"
DRIFT_ALERT_THRESHOLD="0.15"
LOG_FILE="/data/logs/drift-monitor.log"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$DRIFT_LOG_DIR" "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "══════════════════════════════════════════"
log "  DRIFT MONITOR — $TIMESTAMP"
log "══════════════════════════════════════════"

# ─── Load bot token ────────────────────────────────────────────────────────────
ENV_FILE="/data/banxe/.env"
if [[ -z "$BOT_TOKEN" ]] && [[ -f "$ENV_FILE" ]]; then
  BOT_TOKEN=$(grep -E "^MOA_BOT_TOKEN=|^TELEGRAM_BOT_TOKEN=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || true)
fi

send_telegram() {
  local msg="$1"
  if [[ -n "$BOT_TOKEN" ]]; then
    curl -sS "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "text=${msg}" \
      -d "parse_mode=Markdown" 2>/dev/null || log "WARN: Telegram send failed"
  fi
}

# ─── Python drift analysis ─────────────────────────────────────────────────────
DRIFT_SCRIPT=$(cat <<'PYEOF'
import sys, os, json, glob
from pathlib import Path
from datetime import datetime, timezone

DEVELOPER_DIR = os.environ.get("DEVELOPER_DIR", "/data/banxe/promptfoo")
CORPUS_DIR = Path(DEVELOPER_DIR) / "compliance" / "training" / "corpus"
DRIFT_DIR = Path(DEVELOPER_DIR) / "compliance" / "training" / "drift-reports"
TIMESTAMP = os.environ.get("DRIFT_TIMESTAMP", datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S"))
THRESHOLD = float(os.environ.get("DRIFT_THRESHOLD", "0.15"))

if not CORPUS_DIR.exists():
    print(json.dumps({"status": "no_corpus", "drift_score": 0.0, "alert": False}))
    sys.exit(0)

# Load all corpus entries (last 7 days)
from datetime import timedelta
cutoff = datetime.now(timezone.utc) - timedelta(days=7)

entries = []
for path in sorted(CORPUS_DIR.glob("corpus_*.jsonl")):
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
                # Try to parse timestamp
                ts_str = e.get("timestamp", "")
                if ts_str:
                    try:
                        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                        if ts < cutoff:
                            continue
                    except Exception:
                        pass
                entries.append(e)
            except Exception:
                pass

if not entries:
    print(json.dumps({"status": "no_recent_entries", "drift_score": 0.0, "alert": False}))
    sys.exit(0)

# Compute drift metrics
total = len(entries)
refuted = sum(1 for e in entries if e.get("consensus") == "REFUTED")
uncertain = sum(1 for e in entries if e.get("consensus") == "UNCERTAIN")
training_flags = sum(1 for e in entries if e.get("training_flag", False))
drift_scores = [float(e.get("drift_score", 0.0)) for e in entries if e.get("drift_score")]
avg_drift = sum(drift_scores) / len(drift_scores) if drift_scores else 0.0
refuted_rate = refuted / total if total else 0.0
uncertain_rate = uncertain / total if total else 0.0

# Per-role breakdown
from collections import defaultdict
by_role = defaultdict(lambda: {"total": 0, "refuted": 0, "flags": 0})
for e in entries:
    role = e.get("agent_role", "unknown")
    by_role[role]["total"] += 1
    if e.get("consensus") == "REFUTED":
        by_role[role]["refuted"] += 1
    if e.get("training_flag"):
        by_role[role]["flags"] += 1

# Compute composite drift score
# Heuristic: combine avg_drift + refuted rate + training flag rate
composite_drift = (avg_drift * 0.4 + refuted_rate * 0.4 + (training_flags / total) * 0.2) if total else 0.0
composite_drift = round(composite_drift, 4)

alert = composite_drift > THRESHOLD

result = {
    "status": "ok",
    "timestamp": TIMESTAMP,
    "total_entries": total,
    "refuted_rate": round(refuted_rate, 4),
    "uncertain_rate": round(uncertain_rate, 4),
    "avg_drift_score": round(avg_drift, 4),
    "training_flags": training_flags,
    "composite_drift": composite_drift,
    "threshold": THRESHOLD,
    "alert": alert,
    "by_role": {k: dict(v) for k, v in by_role.items()},
}

# Try evidently AI if available
try:
    import evidently
    from evidently.metrics import DataDriftTable
    from evidently.report import Report
    import pandas as pd

    # Build reference (confirmed/correct) vs current (all recent)
    confirmed = [e for e in entries if e.get("expected_consensus") == e.get("consensus")]
    if len(confirmed) > 10 and len(entries) > 10:
        ref_df = pd.DataFrame([{
            "drift_score": float(e.get("drift_score", 0.0)),
            "training_flag": int(e.get("training_flag", False)),
        } for e in confirmed])
        cur_df = pd.DataFrame([{
            "drift_score": float(e.get("drift_score", 0.0)),
            "training_flag": int(e.get("training_flag", False)),
        } for e in entries])
        report = Report(metrics=[DataDriftTable()])
        report.run(reference_data=ref_df, current_data=cur_df)
        ev_result = report.as_dict()
        result["evidently_drift"] = ev_result.get("metrics", [{}])[0].get("result", {})
        # Update composite with evidently drift if available
        ev_drift = result["evidently_drift"].get("dataset_drift_score", None)
        if ev_drift is not None:
            result["composite_drift"] = round(
                composite_drift * 0.5 + float(ev_drift) * 0.5, 4
            )
            result["alert"] = result["composite_drift"] > THRESHOLD
except ImportError:
    result["evidently_note"] = "evidently not available — using heuristic drift only"
except Exception as ex:
    result["evidently_error"] = str(ex)

# Save report
report_path = DRIFT_DIR / f"drift_{TIMESTAMP}.json"
report_path.parent.mkdir(parents=True, exist_ok=True)
with open(report_path, "w") as f:
    json.dump(result, f, indent=2)

result["report_path"] = str(report_path)
print(json.dumps(result))
PYEOF
)

# ─── Run drift analysis ────────────────────────────────────────────────────────
log "Running drift analysis..."

DRIFT_RESULT=$(DEVELOPER_DIR="$DEVELOPER_DIR" DRIFT_TIMESTAMP="$TIMESTAMP" DRIFT_THRESHOLD="$DRIFT_ALERT_THRESHOLD" \
  python3 -c "$DRIFT_SCRIPT" 2>>"$LOG_FILE") || {
    log "ERROR: Drift analysis script failed"
    exit 1
  }

# Parse result
STATUS=$(echo "$DRIFT_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null || echo "error")
COMPOSITE=$(echo "$DRIFT_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('composite_drift',0.0))" 2>/dev/null || echo "0")
ALERT=$(echo "$DRIFT_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('alert',False))" 2>/dev/null || echo "False")
TOTAL=$(echo "$DRIFT_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('total_entries',0))" 2>/dev/null || echo "0")
REFUTED_RATE=$(echo "$DRIFT_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('refuted_rate',0.0))" 2>/dev/null || echo "0")
FLAGS=$(echo "$DRIFT_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('training_flags',0))" 2>/dev/null || echo "0")

log "Status       : $STATUS"
log "Composite    : $COMPOSITE (threshold: $DRIFT_ALERT_THRESHOLD)"
log "Alert        : $ALERT"
log "Total entries: $TOTAL"
log "Refuted rate : $REFUTED_RATE"
log "Training flags: $FLAGS"

# ─── Alert if drift exceeds threshold ─────────────────────────────────────────
if [[ "$ALERT" == "True" ]]; then
  log "ALERT: drift $COMPOSITE > $DRIFT_ALERT_THRESHOLD — sending Telegram notification"
  ALERT_MSG="⚠️ *Banxe Drift Alert*

Composite drift score: \`${COMPOSITE}\` > threshold \`${DRIFT_ALERT_THRESHOLD}\`
Corpus entries (7d): ${TOTAL}
Refuted rate: ${REFUTED_RATE}
Training flags: ${FLAGS}

Action required:
1. Review drift report: \`drift_${TIMESTAMP}.json\`
2. Run: \`bash scripts/train-agent.sh --agent <role> --feedback\`
3. Apply patches: \`bash scripts/apply-feedback.sh --apply\`"
  send_telegram "$ALERT_MSG"
else
  log "OK: drift $COMPOSITE within threshold — no alert"
fi

# ─── Write latest drift to a fixed path for easy querying ─────────────────────
LATEST_FILE="$DRIFT_LOG_DIR/drift_latest.json"
echo "$DRIFT_RESULT" > "$LATEST_FILE"
log "Report saved: $DRIFT_LOG_DIR/drift_${TIMESTAMP}.json"
log "Latest link : $LATEST_FILE"

# ─── Cleanup old reports (keep 30 days) ───────────────────────────────────────
find "$DRIFT_LOG_DIR" -name "drift_*.json" -not -name "drift_latest.json" -mtime +30 -delete 2>/dev/null || true

log "Done."
