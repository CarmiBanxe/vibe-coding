#!/usr/bin/env bash
# quality-gate.sh — Banxe Unified Quality Gate
# IL-016 | Developer Plane | banxe-ai-bank
#
# Supports: vibe-coding (src/compliance/) AND banxe-emi-stack (services/)
# Exit: 0 = ALL PASS, 1 = AT LEAST ONE FAIL
#
# Usage:
#   bash scripts/quality-gate.sh          # auto-detect repo
#   bash scripts/quality-gate.sh --fast   # skip coverage (faster)
#   bash scripts/quality-gate.sh --ci     # CI mode (no colours)

set -uo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--ci" ]] || [[ ! -t 1 ]]; then
    RED="" GREEN="" YELLOW="" BOLD="" RESET=""
else
    RED="\033[0;31m" GREEN="\033[0;32m" YELLOW="\033[1;33m"
    BOLD="\033[1m" RESET="\033[0m"
fi

FAST=0
[[ "${1:-}" == "--fast" || "${2:-}" == "--fast" ]] && FAST=1

# ── Detect repo root ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

# ── Detect repo type ──────────────────────────────────────────────────────────
REPO_TYPE="unknown"
if [[ -d "src/compliance" ]]; then
    REPO_TYPE="vibe-coding"
    SRC_DIRS="src/"
    TEST_CMD="python3 -m pytest src/compliance/ -q --tb=short --override-ini='addopts='"
    COV_CMD="python3 -m pytest src/compliance/ --cov=src --cov-fail-under=75 -q --override-ini='addopts='"
elif [[ -d "services" && -f "services/config.py" ]]; then
    REPO_TYPE="banxe-emi-stack"
    SRC_DIRS="services/"
    TEST_CMD="python3 -m pytest tests/ -q --tb=short"
    COV_CMD="python3 -m pytest tests/ --cov=services --cov-fail-under=75 -q"
else
    SRC_DIRS="."
    TEST_CMD="python3 -m pytest tests/ -q --tb=short 2>/dev/null || true"
    COV_CMD=""
fi

# ── Result tracking ───────────────────────────────────────────────────────────
SEMGREP_STATUS="SKIP"
RUFF_STATUS="SKIP"
TESTS_STATUS="SKIP"
COV_STATUS="SKIP"
INVARIANTS_STATUS="PASS"
SEMGREP_ISSUES=0
RUFF_ISSUES=0
TESTS_PASS=0
TESTS_TOTAL=0
COV_PCT="—"

OVERALL_FAIL=0

echo ""
echo -e "${BOLD}═══ BANXE QUALITY GATE ═══════════════════════════════${RESET}"
echo -e "  Repo:   ${REPO_TYPE} (${REPO_DIR})"
echo -e "  Date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo -e "${BOLD}═══════════════════════════════════════════════════════${RESET}"
echo ""

# ── 1. Semgrep ────────────────────────────────────────────────────────────────
SEMGREP_RULES=".semgrep/banxe-rules.yml"
if command -v semgrep &>/dev/null && [[ -f "$SEMGREP_RULES" ]]; then
    SEMGREP_OUT=$(semgrep --config "$SEMGREP_RULES" --error $SRC_DIRS 2>&1) || true
    SEMGREP_ISSUES=$(echo "$SEMGREP_OUT" | grep -c "^.*:.*: error:" 2>/dev/null; true)
    if echo "$SEMGREP_OUT" | grep -q "ERROR\|error:"; then
        SEMGREP_STATUS="FAIL"
        OVERALL_FAIL=1
    else
        SEMGREP_STATUS="PASS"
    fi
else
    SEMGREP_STATUS="SKIP (not installed or no rules)"
fi

# ── 2. Ruff ───────────────────────────────────────────────────────────────────
if command -v ruff &>/dev/null || python3 -c "import ruff" &>/dev/null; then
    RUFF_OUT=$(python3 -m ruff check $SRC_DIRS 2>&1) || true
    RUFF_ISSUES=$(echo "$RUFF_OUT" | grep -cE "^.*\.py:[0-9]+" 2>/dev/null; true)
    if [[ $RUFF_ISSUES -gt 0 ]]; then
        RUFF_STATUS="FAIL ($RUFF_ISSUES issues)"
        OVERALL_FAIL=1
    else
        RUFF_STATUS="PASS"
    fi
else
    RUFF_STATUS="SKIP (ruff not installed)"
fi

# ── 3. Tests ──────────────────────────────────────────────────────────────────
if [[ -d "tests" ]] || [[ -d "src/compliance" ]]; then
    TESTS_OUT=$(eval "$TEST_CMD" 2>&1) || true
    # Parse "N passed" from pytest output
    TESTS_PASS=$(echo "$TESTS_OUT" | grep -oP '\d+ passed' | grep -oP '\d+' | tail -1); TESTS_PASS=${TESTS_PASS:-0}
    TESTS_FAIL_N=$(echo "$TESTS_OUT" | grep -oP '\d+ failed' | grep -oP '\d+' | tail -1); TESTS_FAIL_N=${TESTS_FAIL_N:-0}
    TESTS_TOTAL=$((TESTS_PASS + TESTS_FAIL_N))
    if [[ $TESTS_FAIL_N -gt 0 ]] || echo "$TESTS_OUT" | grep -q "ERROR\|error"; then
        TESTS_STATUS="FAIL (${TESTS_PASS}/${TESTS_TOTAL} passed)"
        OVERALL_FAIL=1
    else
        TESTS_STATUS="PASS (${TESTS_PASS} passed)"
    fi
fi

# ── 4. Coverage ───────────────────────────────────────────────────────────────
if [[ $FAST -eq 0 ]] && [[ -n "$COV_CMD" ]] && python3 -c "import coverage" &>/dev/null; then
    COV_OUT=$(eval "$COV_CMD" 2>&1) || true
    COV_PCT=$(echo "$COV_OUT" | grep -oP 'TOTAL.*\s\K\d+%' | tail -1); COV_PCT=${COV_PCT:-?}
    if echo "$COV_OUT" | grep -qE "FAIL Required test coverage|coverage.*below"; then
        COV_STATUS="FAIL (${COV_PCT})"
        OVERALL_FAIL=1
    elif [[ "$COV_PCT" == "?" ]]; then
        COV_STATUS="SKIP (no data)"
    else
        COV_STATUS="PASS (${COV_PCT})"
    fi
elif [[ $FAST -eq 1 ]]; then
    COV_STATUS="SKIP (--fast)"
else
    COV_STATUS="SKIP (coverage not installed)"
fi

# ── 5. Invariant scan ─────────────────────────────────────────────────────────
# I-05: no float() in financial context
FLOAT_HITS=$(grep -rn "float(" $SRC_DIRS 2>/dev/null \
    | grep -iv "# noqa\|# i-05-ok\|test_\|\.pyc" \
    | grep -v "^\.git/\|/\.git/\|\.lucidshark\|\.cache\|COMMIT_EDITMSG" \
    | grep -E "amount|balance|price|total|fee|rate|decimal" \
    | wc -l); FLOAT_HITS=${FLOAT_HITS:-0}
if [[ $FLOAT_HITS -gt 0 ]]; then
    INVARIANTS_STATUS="FAIL (I-05: ${FLOAT_HITS} float() in financial context)"
    OVERALL_FAIL=1
fi

# I-06: no hardcoded passwords
SECRET_HITS=$(grep -rn "password\s*=\s*['\"][^'\"]\{3,\}['\"]" $SRC_DIRS 2>/dev/null \
    | grep -iv "# noqa\|test_\|\.pyc\|getenv\|os\.environ\|default=" \
    | wc -l); SECRET_HITS=${SECRET_HITS:-0}
if [[ $SECRET_HITS -gt 0 ]]; then
    INVARIANTS_STATUS="FAIL (I-06: ${SECRET_HITS} hardcoded secret(s))"
    OVERALL_FAIL=1
fi

# ── Report ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}── Results ─────────────────────────────────────────────${RESET}"

_status_line() {
    local label="$1" value="$2"
    if [[ "$value" == PASS* ]]; then
        echo -e "  $(printf '%-14s' "$label") ${GREEN}${value}${RESET}"
    elif [[ "$value" == FAIL* ]]; then
        echo -e "  $(printf '%-14s' "$label") ${RED}${value}${RESET}"
    else
        echo -e "  $(printf '%-14s' "$label") ${YELLOW}${value}${RESET}"
    fi
}

_status_line "Semgrep:"    "$SEMGREP_STATUS"
_status_line "Ruff:"       "$RUFF_STATUS"
_status_line "Tests:"      "$TESTS_STATUS"
_status_line "Coverage:"   "$COV_STATUS"
_status_line "Invariants:" "$INVARIANTS_STATUS"

echo -e "${BOLD}───────────────────────────────────────────────────────${RESET}"
if [[ $OVERALL_FAIL -eq 0 ]]; then
    echo -e "  ${BOLD}RESULT:        ${GREEN}✅ PASS${RESET}"
else
    echo -e "  ${BOLD}RESULT:        ${RED}❌ FAIL${RESET}"
fi
echo -e "${BOLD}═══════════════════════════════════════════════════════${RESET}"
echo ""

exit $OVERALL_FAIL
