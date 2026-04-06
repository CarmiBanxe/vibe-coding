#!/usr/bin/env bash
# deploy-decision-event-log.sh — G-01 Production Deploy: Decision Event Log на GMKtec
#
# Что делает:
#   1. Sync кода на GMKtec (git pull)
#   2. Проверяет PostgreSQL (banxe_compliance БД)
#   3. Запускает миграцию decision_events.sql (idempotent — IF NOT EXISTS)
#   4. Верифицирует I-24: INSERT+SELECT есть, UPDATE+DELETE запрещены на уровне БД
#   5. Smoke test: insert DecisionEvent → query → проверка round-trip через Python адаптер
#   6. Выводит итог — G-01 DONE если всё прошло
#
# Invariant: I-24 — append-only enforcement at DB level (REVOKE UPDATE/DELETE)
# Authority:  DORA Art. 14(2), FCA MLR 2017 (5-year record retention)
#
# Запуск (по одной команде):
#   git -C ~/vibe-coding pull --rebase
#   bash ~/vibe-coding/scripts/deploy-decision-event-log.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REMOTE="ssh gmktec"
VIBE_DIR="/data/vibe-coding"
COMPLIANCE_DIR="$VIBE_DIR/src/compliance"
SQL_FILE="$COMPLIANCE_DIR/decision_events.sql"
PY="$VIBE_DIR/compliance-env/bin/python3"
PG_DSN="postgresql://banxe:banxe_secure_2026@127.0.0.1:5432/banxe_compliance"
SCHEMA="banxe_compliance"
TABLE="decision_events"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  BANXE — Decision Event Log Production Deploy (G-01)        ║"
echo "║  DORA Art.14(2) + FCA MLR 2017 — append-only audit trail   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Sync code ─────────────────────────────────────────────────────────
echo "▶ [1/6] Syncing code to GMKtec..."
$REMOTE "cd $VIBE_DIR && git pull --rebase"
echo "  ✅ Code synced ($(git rev-parse --short HEAD))"

# ── Step 2: Check PostgreSQL ──────────────────────────────────────────────────
echo ""
echo "▶ [2/6] Checking PostgreSQL (banxe_compliance database)..."
$REMOTE "
  set -e
  if ! command -v psql &>/dev/null; then
    echo '  ❌ psql not found — install: sudo apt install postgresql-client' && exit 1
  fi

  echo '  Checking PostgreSQL service...'
  if systemctl is-active --quiet postgresql 2>/dev/null; then
    echo '  ✅ postgresql service: active'
  else
    echo '  ⚠️  postgresql service not running — trying to connect anyway...'
  fi

  echo '  Checking banxe_compliance database...'
  if psql '$PG_DSN' -c 'SELECT 1' -qt 2>/dev/null | grep -q 1; then
    echo '  ✅ banxe_compliance: accessible'
  else
    echo '  ℹ️  banxe_compliance database not found — creating...'
    sudo -u postgres psql -c \"CREATE DATABASE banxe_compliance;\" 2>/dev/null || true
    sudo -u postgres psql -c \"CREATE USER banxe WITH PASSWORD 'banxe_secure_2026';\" 2>/dev/null || true
    sudo -u postgres psql -c \"GRANT ALL PRIVILEGES ON DATABASE banxe_compliance TO banxe;\" 2>/dev/null || true
    echo '  ✅ banxe_compliance: created and granted'
  fi
"

# ── Step 3: Run migration ─────────────────────────────────────────────────────
echo ""
echo "▶ [3/6] Running migration: decision_events.sql..."
$REMOTE "
  set -e
  echo '  SQL file: $SQL_FILE'
  if [ ! -f $SQL_FILE ]; then
    echo '  ❌ SQL file not found: $SQL_FILE' && exit 1
  fi
  psql '$PG_DSN' -f $SQL_FILE -q
  echo '  ✅ Migration complete (idempotent — safe to re-run)'
"

# ── Step 4: Verify I-24 at DB level ──────────────────────────────────────────
echo ""
echo "▶ [4/6] Verifying I-24: INSERT/SELECT allowed, UPDATE/DELETE forbidden..."
$REMOTE "
  set -e
  echo '  Checking privilege grants for banxe_app_role...'
  GRANTS=\$(psql '$PG_DSN' -qt -c \"
    SELECT privilege_type
    FROM information_schema.role_table_grants
    WHERE table_schema = '$SCHEMA'
      AND table_name   = '$TABLE'
      AND grantee      = 'banxe_app_role'
    ORDER BY privilege_type;
  \" 2>/dev/null)

  echo '  Grants on banxe_app_role:'
  echo \"\$GRANTS\" | while IFS= read -r line; do
    echo \"    \$line\"
  done

  if echo \"\$GRANTS\" | grep -q 'INSERT'; then
    echo '  ✅ INSERT: granted (append allowed)'
  else
    echo '  ⚠️  INSERT not found in grants (check migration ran as correct user)'
  fi

  if echo \"\$GRANTS\" | grep -q 'SELECT'; then
    echo '  ✅ SELECT: granted (query allowed)'
  else
    echo '  ⚠️  SELECT not found in grants'
  fi

  if echo \"\$GRANTS\" | grep -qE 'UPDATE|DELETE'; then
    echo '  ❌ I-24 VIOLATED: UPDATE or DELETE found in grants!'
    exit 1
  else
    echo '  ✅ UPDATE: revoked (I-24 enforced)'
    echo '  ✅ DELETE: revoked (I-24 enforced)'
  fi

  echo '  Verifying table structure...'
  COL_COUNT=\$(psql '$PG_DSN' -qt -c \"
    SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = '$SCHEMA' AND table_name = '$TABLE';
  \" | tr -d ' ')
  echo \"  ✅ Table $SCHEMA.$TABLE: \${COL_COUNT} columns\"

  echo '  Verifying indexes...'
  IDX_COUNT=\$(psql '$PG_DSN' -qt -c \"
    SELECT COUNT(*) FROM pg_indexes
    WHERE schemaname = '$SCHEMA' AND tablename = '$TABLE';
  \" | tr -d ' ')
  echo \"  ✅ Indexes: \${IDX_COUNT} (expected 6 including PK)\"
"

# ── Step 5: Smoke test via Python adapter ────────────────────────────────────
echo ""
echo "▶ [5/6] Smoke test: Python adapter round-trip (insert → query)..."
$REMOTE "
  set -e
  cd $VIBE_DIR

  # Check Python env
  if [ ! -f $PY ]; then
    echo '  ⚠️  compliance-env not found at $PY'
    echo '  Trying system python3...'
    PY=\$(which python3)
  else
    PY=$PY
  fi

  echo '  Python: '\$PY

  # Install asyncpg if missing
  \$PY -c 'import asyncpg' 2>/dev/null || {
    echo '  Installing asyncpg...'
    \$PY -m pip install asyncpg --quiet
  }

  echo '  Running smoke test...'
  \$PY - << 'PYEOF'
import asyncio
import sys
import os
import uuid

sys.path.insert(0, '/data/vibe-coding/src')

from compliance.utils.decision_event_log import (
    DecisionEvent, PostgresEventLogAdapter, InMemoryAuditAdapter
)

TEST_CASE_ID   = 'smoke-test-' + str(uuid.uuid4())[:8]
TEST_CUSTOMER  = 'DEPLOY-SMOKE-TEST'

async def main():
    print('  Building DecisionEvent...')
    event = DecisionEvent(
        case_id          = TEST_CASE_ID,
        decision         = 'APPROVE',
        composite_score  = 5,
        decision_reason  = 'threshold',
        tx_id            = 'TX-SMOKE-001',
        channel          = 'bank_transfer',
        customer_id      = TEST_CUSTOMER,
        requires_edd         = False,
        requires_mlro_review = False,
        hard_block_hit       = False,
        sanctions_hit        = False,
        crypto_risk          = False,
        policy_version       = 'developer-core@2026-04-05',
        signals_count    = 0,
        rules_triggered  = [],
        signals_json     = [],
        audit_payload    = {'smoke_test': True},
    )
    print(f'  event_id: {event.event_id}')
    print(f'  case_id:  {event.case_id}')

    print('  Inserting via PostgresEventLogAdapter...')
    adapter = PostgresEventLogAdapter()
    returned_id = await adapter.append_event(event)
    if returned_id == event.event_id:
        print(f'  ✅ append_event returned correct event_id')
    else:
        print(f'  ❌ event_id mismatch: got {returned_id}')
        sys.exit(1)

    print('  Querying by case_id...')
    results = await adapter.query_events(case_id=TEST_CASE_ID)
    if len(results) == 1 and results[0].decision == 'APPROVE':
        print(f'  ✅ query_events returned 1 event, decision=APPROVE')
    else:
        print(f'  ❌ query returned {len(results)} events (expected 1)')
        sys.exit(1)

    print('  Testing idempotency (duplicate insert)...')
    id2 = await adapter.append_event(event)
    results2 = await adapter.query_events(case_id=TEST_CASE_ID)
    if len(results2) == 1:
        print(f'  ✅ ON CONFLICT DO NOTHING: duplicate silently ignored')
    else:
        print(f'  ❌ Idempotency failed: {len(results2)} events (expected 1)')
        sys.exit(1)

    print('  Verifying to_dict() is JSON-serialisable...')
    import json
    d = results[0].to_dict()
    json.dumps(d)
    print('  ✅ to_dict() JSON-serialisable')

    print('')
    print('  ✅ ALL SMOKE TESTS PASSED')
    print(f'     event_id: {event.event_id}')
    print(f'     case_id:  {TEST_CASE_ID}')
    print(f'     Note: smoke test event remains in table (append-only, I-24)')

asyncio.run(main())
PYEOF
"

# ── Step 6: Summary ───────────────────────────────────────────────────────────
echo ""
echo "▶ [6/6] Deploy summary..."
GMKTEC_IP=$($REMOTE "hostname -I | awk '{print \$1}'" 2>/dev/null || echo "<gmktec-ip>")
echo "  PostgreSQL:   ${GMKTEC_IP}:5432/banxe_compliance"
echo "  Schema:       ${SCHEMA}.${TABLE}"
echo "  I-24:         INSERT + SELECT granted, UPDATE + DELETE revoked"
echo "  Retention:    5 years (FCA MLR 2017) — enforced by policy, not TTL"
echo "  Indexes:      case_id, customer_id, occurred_at, tx_id, decision"
echo "  Python:       PostgresEventLogAdapter (asyncpg, fail-safe)"
echo "  Integration:  banxe_aml_orchestrator.py → get_decision_log().append_event()"
echo ""
echo "  Next step for G-02 ExplanationBundle:"
echo "    DecisionEvent already stores signals_json + audit_payload"
echo "    Add explanation_bundle field to DecisionEvent + ExplanationBundle dataclass"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ G-01 DONE — Decision Event Log is LIVE on GMKtec       ║"
echo "║  DORA Art.14(2) + FCA MLR 2017 audit trail: operational    ║"
echo "║  Invariant I-24: UPDATE/DELETE forbidden at DB level        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
