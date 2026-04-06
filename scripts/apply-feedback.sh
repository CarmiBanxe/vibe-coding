#!/usr/bin/env bash
# apply-feedback.sh — Legion-side wrapper for feedback_loop.py
# Reads corpus JSONL REFUTED entries, generates and optionally applies patches
# Usage: bash scripts/apply-feedback.sh [--report|--apply] [--since YYYY-MM-DD] [--agent <id>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIBE_DIR="$(dirname "$SCRIPT_DIR")"
DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/developer}"
FEEDBACK_LOOP="$DEVELOPER_DIR/compliance/training/feedback_loop.py"
PROTECT_SOUL="$VIBE_DIR/scripts/protect-soul.sh"

# ─── Defaults ──────────────────────────────────────────────────────────────────
MODE="report"
SINCE_DATE=""
AGENT_FILTER=""

# ─── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)  MODE="report"; shift ;;
    --apply)   MODE="apply"; shift ;;
    --since)   SINCE_DATE="$2"; shift 2 ;;
    --agent)   AGENT_FILTER="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: bash apply-feedback.sh [--report|--apply] [--since YYYY-MM-DD] [--agent <id>]"
      echo ""
      echo "  --report    Show proposed patches without making changes (default)"
      echo "  --apply     Apply patches to compliance_validator.py and SOUL.md locally"
      echo "  --since     Only process corpus entries from this date onward"
      echo "  --agent     Filter corpus to specific agent ID"
      echo ""
      echo "After --apply:"
      echo "  1. compliance_validator.py is patched + committed to developer-core"
      echo "  2. SOUL.md is patched locally"
      echo "  3. Run 'bash scripts/protect-soul.sh update' on GMKtec to deploy SOUL.md"
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Checks ────────────────────────────────────────────────────────────────────
if [[ ! -f "$FEEDBACK_LOOP" ]]; then
  echo "ERROR: feedback_loop.py not found: $FEEDBACK_LOOP"
  echo "  Is developer-core cloned to $DEVELOPER_DIR ?"
  exit 1
fi

CORPUS_DIR="$DEVELOPER_DIR/compliance/training/corpus"
if [[ ! -d "$CORPUS_DIR" ]]; then
  echo "ERROR: Corpus directory not found: $CORPUS_DIR"
  echo "  Run train-agent.sh first to generate corpus entries."
  exit 1
fi

CORPUS_COUNT=$(find "$CORPUS_DIR" -name "corpus_*.jsonl" 2>/dev/null | wc -l || echo 0)
if [[ "$CORPUS_COUNT" -eq 0 ]]; then
  echo "ERROR: No corpus files found in $CORPUS_DIR"
  echo "  Run train-agent.sh first to generate corpus entries."
  exit 1
fi

# ─── Header ────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  BANXE FEEDBACK LOOP — $MODE"
echo "══════════════════════════════════════════════════════════════════"
echo "  Developer dir : $DEVELOPER_DIR"
echo "  Corpus files  : $CORPUS_COUNT"
echo "  Mode          : $MODE"
[[ -n "$SINCE_DATE" ]] && echo "  Since         : $SINCE_DATE"
[[ -n "$AGENT_FILTER" ]] && echo "  Agent filter  : $AGENT_FILTER"
echo "══════════════════════════════════════════════════════════════════"
echo ""

# ─── Build args for feedback_loop.py ──────────────────────────────────────────
LOOP_ARGS="--$MODE"
[[ -n "$SINCE_DATE" ]] && LOOP_ARGS="$LOOP_ARGS --since $SINCE_DATE"
[[ -n "$AGENT_FILTER" ]] && LOOP_ARGS="$LOOP_ARGS --agent $AGENT_FILTER"

# ─── Run feedback loop ────────────────────────────────────────────────────────
DEVELOPER_DIR="$DEVELOPER_DIR" python3 "$FEEDBACK_LOOP" $LOOP_ARGS

EXIT_CODE=$?

# ─── Post-apply instructions ──────────────────────────────────────────────────
if [[ "$MODE" == "apply" ]] && [[ $EXIT_CODE -eq 0 ]]; then
  echo ""
  echo "──────────────────────────────────────────────────────────────────"
  echo "  Patches applied locally."
  echo ""
  echo "  NEXT STEPS:"
  echo ""
  echo "  1. compliance_validator.py — committed to developer-core (git push done)"
  echo ""
  echo "  2. SOUL.md — saved locally to:"
  echo "     $HOME/.openclaw-moa/soul-protected/SOUL.md"
  echo ""
  echo "  3. To deploy SOUL.md to GMKtec (run from Legion):"
  echo "     bash scripts/protect-soul.sh update"
  echo ""
  echo "  4. AGENTS.md changes — requires GMKtec SSH:"
  echo "     SSH to GMKtec and manually apply the AGENTS.md patches shown above"
  echo "     (printed in the report above)"
  echo "──────────────────────────────────────────────────────────────────"
fi

exit $EXIT_CODE
