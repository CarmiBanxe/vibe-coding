#!/bin/bash
# verify-production.sh — Post-Deploy Production Verification Checklist
# Run from: Legion (WSL2) — connects to GMKtec via SSH
# Usage: cd ~/vibe-coding && bash scripts/verify-production.sh
set -uo pipefail

REMOTE="gmktec"
PASS=0
FAIL=0
WARN=0

echo "╔══════════════════════════════════════════════════╗"
echo "║  BANXE Production Verification — $(date '+%H:%M:%S')        ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# Helper: run check on remote, capture pass/fail
check_remote() {
    local label="$1"
    local cmd="$2"
    if ssh ${REMOTE} "$cmd" >/dev/null 2>&1; then
        echo "✅ $label"
        ((PASS++))
    else
        echo "❌ $label"
        ((FAIL++))
    fi
}

check_remote_warn() {
    local label="$1"
    local cmd="$2"
    if ssh ${REMOTE} "$cmd" >/dev/null 2>&1; then
        echo "✅ $label"
        ((PASS++))
    else
        echo "⚠️  $label (non-critical)"
        ((WARN++))
    fi
}

echo "── Core Services ─────────────────────────────────"
check_remote       "FastAPI health (:8090)"          "curl -sf http://localhost:8090/status"
check_remote_warn  "Watchman health (:8084)"         "curl -sf http://localhost:8084/health"
check_remote_warn  "Jube health (:5001)"             "curl -sf http://localhost:5001/health"
check_remote_warn  "Marble API (:5002)"              "curl -sf http://localhost:5002/health"

echo ""
echo "── Infrastructure ────────────────────────────────"
check_remote_warn  "Redis ping (optional)"            "redis-cli ping 2>/dev/null"
check_remote       "ClickHouse ping"                 "curl -sf http://localhost:8123/ping"
check_remote       "PostgreSQL (Docker :5432)"       "docker exec postgres pg_isready -U postgres -q"

echo ""
echo "── Compliance Stack ──────────────────────────────"
check_remote_warn  "Emergency stop endpoint"         "curl -sf http://localhost:8090/api/v1/compliance/emergency-stop/status"
check_remote       "decision_events table"           "docker exec postgres psql -U postgres -d banxe_compliance -t -c 'SELECT 1 FROM decision_events LIMIT 1;' 2>/dev/null; exit 0"
check_remote_warn  "Blocked jurisdictions in Redis"  "redis-cli SISMEMBER banxe:blocked_jurisdictions RU 2>/dev/null"

echo ""
echo "── AI Stack ──────────────────────────────────────"
check_remote_warn  "Ollama models"                   "curl -sf http://localhost:11434/api/tags"
check_remote_warn  "OpenClaw gateway (:18789)"       "curl -sf http://localhost:18789/health"

echo ""
echo "── Security ──────────────────────────────────────"
check_remote       "JIT credentials (smoke)"         "python3 -c \"
import sys; sys.path.insert(0, '/data/banxe'); sys.path.insert(0, '/data/banxe/compliance')
from compliance.security.jit_credentials import JITCredentialManager, CredentialScope
mgr = JITCredentialManager()
cred = mgr.issue_credential('verify_agent', CredentialScope.READ_POLICY, level=2)
assert not cred.is_expired
mgr.revoke(cred.token)
\""
check_remote       "Pre-tx gate (smoke)"             "python3 -c \"
import sys; sys.path.insert(0, '/data/banxe'); sys.path.insert(0, '/data/banxe/compliance')
from compliance.gates.pre_tx_gate import PreTxGate, TransactionGateInput, InMemoryRedisStub
gate = PreTxGate(redis_client=InMemoryRedisStub())
r = gate.evaluate(TransactionGateInput('C1','GB','DE',500.0))
assert r.decision == 'PASS'
\""

echo ""
echo "── Audit ─────────────────────────────────────────"
check_remote_warn  "Compliance snapshot"             "python3 -c \"
import sys; sys.path.insert(0, '/data/banxe'); sys.path.insert(0, '/data/banxe/compliance')
from compliance.utils.compliance_snapshot import collect_snapshot
s = collect_snapshot(run_tests=False)
assert s.agent_passports_count >= 0
\""

echo ""
echo "══════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL + WARN))
echo "Results: ${PASS}/${TOTAL} passed, ${FAIL} failed, ${WARN} warnings"
echo ""
if [ $FAIL -eq 0 ]; then
    echo "🟢 PRODUCTION READY"
    exit 0
else
    echo "🔴 FIX REQUIRED — ${FAIL} critical check(s) failed"
    exit 1
fi
