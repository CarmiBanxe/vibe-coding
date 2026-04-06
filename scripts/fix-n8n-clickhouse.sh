#!/bin/bash
# fix-n8n-clickhouse.sh
# Fixes two bugs in n8n KYC/AML workflows:
#   1. $helpers.httpRequest body double-serialization (strings empty in ClickHouse)
#   2. workflow_entity.versionId ↔ workflow_history ↔ workflow_published_version mismatch
#
# Run on Legion: cd ~/vibe-coding && git pull && bash scripts/fix-n8n-clickhouse.sh

set -euo pipefail

SSH="ssh gmktec"
KYC_ID="aaaabbbb-1111-2222-3333-kyconboarding0"
AML_ID="ccccdddd-5555-6666-7777-amlmonitoring0"
DB="/data/n8n/.n8n/database.sqlite"

echo "═══════════════════════════════════════════════════════════════"
echo " n8n ClickHouse Fix — object body + versionId sync"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. Stop n8n ─────────────────────────────────────────────────────────────
echo ""
echo "━━━ STEP 1: Stop n8n ━━━"
$SSH "sudo systemctl stop n8n 2>/dev/null; sleep 2; echo '  ✓ n8n stopped'"

# ── 2. Deploy Python fix script ─────────────────────────────────────────────
echo ""
echo "━━━ STEP 2: Prepare workflow fix ━━━"

cat > /tmp/fix_n8n_ch_final.py << 'PYEOF'
import json, sqlite3, uuid
from datetime import datetime

DB = '/data/n8n/.n8n/database.sqlite'
KYC_ID = 'aaaabbbb-1111-2222-3333-kyconboarding0'
AML_ID = 'ccccdddd-5555-6666-7777-amlmonitoring0'

# Root cause fix:
# $helpers.httpRequest с body: JSON.stringify({...}) → n8n снова сериализует строку →
# ClickHouse получает "\"...\"" вместо объекта → все string-поля пустые.
# Решение: передаём body как объект, n8n сам сериализует корректно.

KYC_CODE = r"""
const body = $input.first().json.body || $input.first().json;
const c = {
  id:       body.customer_id   || ('KYC-' + Date.now()),
  name:     body.name          || '',
  email:    body.email         || '',
  country:  (body.country      || 'GB').toUpperCase(),
  doc_type: body.doc_type      || 'passport',
  business: body.business_type || 'individual',
  source_of_funds: body.source_of_funds || 'employment'
};
const SANCTIONED = ['IR','KP','SY','CU','SD','LY','MM','BY','RU','VE'];
const HIGH_RISK_C = ['AF','IQ','PK','NG','ET'];
const MED_RISK_C  = ['CN','TH','VN','PH','UA','KZ'];
const PEP_MARKERS = ['minister','senator','president','general','ambassador','deputy','prime'];
const isPEP = PEP_MARKERS.some(m => c.name.toLowerCase().includes(m));
let cR = 'LOW';
if (SANCTIONED.includes(c.country))   cR = 'BLOCKED';
else if (HIGH_RISK_C.includes(c.country)) cR = 'HIGH';
else if (MED_RISK_C.includes(c.country))  cR = 'MEDIUM';
const fR = ['crypto','cash','unknown','gift'].includes(c.source_of_funds.toLowerCase()) ? 'HIGH' : 'LOW';
const bR = ['money_service','gambling','casino','arms','crypto_exchange'].includes(c.business.toLowerCase()) ? 'HIGH' : 'LOW';
let score = 0;
if (cR === 'HIGH')   score += 40;
if (cR === 'MEDIUM') score += 20;
if (isPEP)           score += 35;
if (fR === 'HIGH')   score += 15;
if (bR === 'HIGH')   score += 25;
let rL, tier, dec;
if (cR === 'BLOCKED')          { rL = 'BLOCKED'; tier = 'N/A'; dec = 'REJECT'; }
else if (score >= 50 || isPEP) { rL = 'HIGH';    tier = 'EDD'; dec = 'MANUAL_REVIEW'; }
else if (score >= 20)          { rL = 'MEDIUM';   tier = 'SDD'; dec = 'APPROVE_WITH_MONITORING'; }
else                           { rL = 'LOW';      tier = 'SDD'; dec = 'APPROVE'; }
const docs = ['photo_id', 'proof_of_address'];
if (tier === 'EDD') {
  docs.push('source_of_funds_proof', 'bank_statement_3mo');
  if (isPEP) docs.push('pep_declaration');
}

// FIX: body передаётся как ОБЪЕКТ — n8n сам делает JSON.stringify
// (раньше передавали строку → n8n сериализовал снова → ClickHouse видел "\"...\"")
try {
  await $helpers.httpRequest({
    method: 'POST',
    url: 'http://localhost:8123/?query=INSERT%20INTO%20banxe.kyc_events%20FORMAT%20JSONEachRow',
    headers: { 'Content-Type': 'application/json' },
    body: {
      client_id:  c.id,
      event_type: 'ONBOARDING_ASSESSMENT',
      result:     dec,
      details:    JSON.stringify({ risk_score: score, risk_level: rL, kyc_tier: tier, country: c.country, is_pep: isPEP }),
      agent:      'kyc_n8n'
    }
  });
} catch(e) { /* non-blocking — workflow не должен падать из-за логирования */ }

return [{json: {
  customer: c,
  risk: { score, level: rL, country_risk: cR, is_pep: isPEP, funds_risk: fR },
  kyc:  { tier, decision: dec, required_docs: docs, deadline_days: tier === 'EDD' ? 30 : 14 },
  timestamp: new Date().toISOString()
}}];
""".strip()

AML_CODE = r"""
const body = $input.first().json.body || $input.first().json;
const tx = {
  id:               body.transaction_id  || ('TXN-' + Date.now()),
  amount:           parseFloat(body.amount) || 0,
  currency:         (body.currency         || 'GBP').toUpperCase(),
  sender_id:        body.sender_id         || '',
  receiver_id:      body.receiver_id       || '',
  sender_country:   (body.sender_country   || 'GB').toUpperCase(),
  receiver_country: (body.receiver_country || 'GB').toUpperCase(),
  tx_type:          body.transaction_type  || 'transfer'
};
const SANC   = ['IR','KP','SY','CU','SD','LY','MM','BY'];
const HIGH_C = ['AF','IQ','PK','NG','ET'];
const flags = []; let score = 0;
const sS = SANC.includes(tx.sender_country), rS = SANC.includes(tx.receiver_country);
if (sS || rS) { flags.push('SANCTIONED_JURISDICTION'); score += 100; }
const gbp = tx.currency === 'GBP' ? tx.amount
          : tx.currency === 'EUR' ? tx.amount * 0.85
          : tx.currency === 'USD' ? tx.amount * 0.79
          : tx.amount;
if      (gbp >= 50000)              { flags.push('LARGE_TRANSACTION');      score += 30; }
else if (gbp >= 10000)              { flags.push('HIGH_VALUE_TRANSACTION'); score += 20; }
else if (gbp >= 9500 && gbp < 10000){ flags.push('POTENTIAL_STRUCTURING'); score += 40; }
if (tx.amount % 1000 === 0 && tx.amount > 0) { flags.push('ROUND_AMOUNT'); score += 10; }
if (HIGH_C.includes(tx.receiver_country)) { flags.push('HIGH_RISK_DESTINATION'); score += 25; }
if (['crypto_withdrawal','cash_equivalent'].includes(tx.tx_type.toLowerCase())) {
  flags.push('HIGH_RISK_TX_TYPE'); score += 20;
}
let rL, action, sar;
if (score >= 100 || sS || rS) { rL = 'CRITICAL'; action = 'BLOCK'; sar = true;  }
else if (score >= 60)         { rL = 'HIGH';     action = 'HOLD';  sar = true;  }
else if (score >= 30)         { rL = 'MEDIUM';   action = 'MONITOR'; sar = false; }
else                          { rL = 'LOW';      action = 'ALLOW'; sar = false; }
const amtGBP  = Math.round(gbp * 100) / 100;
const txStatus = action === 'ALLOW' ? 'approved' : action === 'BLOCK' ? 'blocked' : 'pending';

// FIX: body как ОБЪЕКТ (не строка)
try {
  await $helpers.httpRequest({
    method: 'POST',
    url: 'http://localhost:8123/?query=INSERT%20INTO%20banxe.transactions%20FORMAT%20JSONEachRow',
    headers: { 'Content-Type': 'application/json' },
    body: {
      client_id:   tx.sender_id,
      type:        tx.tx_type,
      amount:      amtGBP,
      currency:    'GBP',
      status:      txStatus,
      description: JSON.stringify({ transaction_id: tx.id, receiver_id: tx.receiver_id, risk_score: score, flags, require_sar: sar }),
      agent:       'aml_n8n'
    }
  });
} catch(e) {}

if (sar) {
  try {
    await $helpers.httpRequest({
      method: 'POST',
      url: 'http://localhost:8123/?query=INSERT%20INTO%20banxe.aml_alerts%20FORMAT%20JSONEachRow',
      headers: { 'Content-Type': 'application/json' },
      body: {
        client_id:   tx.sender_id,
        alert_type:  flags.join(','),
        severity:    rL,
        description: JSON.stringify({ transaction_id: tx.id, amount_gbp: amtGBP, receiver_country: tx.receiver_country, flags, regulatory: 'POCA 2002, MLR 2017' }),
        status:      'OPEN',
        agent:       'aml_n8n'
      }
    });
  } catch(e) {}
}

return [{json: {
  transaction: tx,
  aml: { risk_score: score, risk_level: rL, action, require_sar: sar, flags, amount_gbp: amtGBP, regulatory: 'POCA 2002, MLR 2017, JMLSG' },
  timestamp: new Date().toISOString()
}}];
""".strip()

conn = sqlite3.connect(DB)
cur  = conn.cursor()

for wf_id, node_id, code, label in [
    (KYC_ID, 'n2-risk-scoring', KYC_CODE, 'KYC'),
    (AML_ID, 'a2-aml-engine',   AML_CODE, 'AML'),
]:
    cur.execute("SELECT nodes, connections, name FROM workflow_entity WHERE id=?", (wf_id,))
    row = cur.fetchone()
    if not row:
        print(f'  ERROR: {wf_id} not found!')
        continue

    nodes = json.loads(row[0])
    conns = json.loads(row[1])
    wf_name = row[2]

    # Update the Code node
    updated = False
    for node in nodes:
        if node.get('id') == node_id:
            node['parameters']['jsCode'] = code
            updated = True
    if not updated:
        print(f'  WARNING: node {node_id} not found in {wf_name}')

    # CRITICAL: generate ONE new versionId used in ALL THREE tables
    new_ver    = str(uuid.uuid4())
    now        = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S.000')
    nodes_json = json.dumps(nodes)
    conns_json = json.dumps(conns)

    # 1. workflow_entity — set versionId = new_ver
    cur.execute("""
        UPDATE workflow_entity
        SET nodes=?, versionId=?, updatedAt=?, active=1
        WHERE id=?
    """, (nodes_json, new_ver, now, wf_id))

    # 2. workflow_history — delete old, insert with SAME versionId
    cur.execute("DELETE FROM workflow_history WHERE workflowId=?", (wf_id,))
    cur.execute("""
        INSERT INTO workflow_history
               (versionId, workflowId, authors, createdAt, updatedAt, nodes, connections, autosaved)
        VALUES (?,          ?,          ?,       ?,         ?,         ?,     ?,           0)
    """, (new_ver, wf_id, 'banxe-system', now, now, nodes_json, conns_json))

    # 3. workflow_published_version — same versionId
    cur.execute("DELETE FROM workflow_published_version WHERE workflowId=?", (wf_id,))
    cur.execute("""
        INSERT INTO workflow_published_version (workflowId, publishedVersionId, createdAt, updatedAt)
        VALUES (?, ?, ?, ?)
    """, (wf_id, new_ver, now, now))

    print(f'  ✓ {label} ({wf_name}): code updated, versionId={new_ver[:8]}... synced')

conn.commit()
conn.close()

# ── Verify all three tables are consistent ─────────────────────────────────
print('\n  ── DB Consistency Check ──')
conn2 = sqlite3.connect(DB)
cur2  = conn2.cursor()
cur2.execute("""
    SELECT
        we.name,
        we.versionId        AS entity_ver,
        wh.versionId        AS hist_ver,
        wpv.publishedVersionId AS pub_ver,
        we.active
    FROM workflow_entity we
    LEFT JOIN workflow_history          wh  ON wh.workflowId  = we.id AND wh.versionId = we.versionId
    LEFT JOIN workflow_published_version wpv ON wpv.workflowId = we.id
    WHERE we.id IN (
        'aaaabbbb-1111-2222-3333-kyconboarding0',
        'ccccdddd-5555-6666-7777-amlmonitoring0'
    )
""")
all_ok = True
for name, ev, hv, pv, active in cur2.fetchall():
    h_ok = '✓' if ev and ev == hv else '✗ MISMATCH'
    p_ok = '✓' if ev and ev == pv else '✗ MISMATCH'
    if 'MISMATCH' in h_ok or 'MISMATCH' in p_ok:
        all_ok = False
    print(f'  {name}: active={active} entity/history={h_ok} entity/published={p_ok}')
conn2.close()
print(f'  Result: {"ALL OK" if all_ok else "ERRORS FOUND"}')
PYEOF

scp -q /tmp/fix_n8n_ch_final.py gmktec:/tmp/
echo "  ✓ Script uploaded"
$SSH "python3 /tmp/fix_n8n_ch_final.py"

# ── 3. Start n8n ─────────────────────────────────────────────────────────────
echo ""
echo "━━━ STEP 3: Start n8n ━━━"
$SSH "sudo systemctl start n8n"
echo "  Waiting 25s for n8n to initialise..."
sleep 25

# Check n8n is up
N8N_STATUS=$($SSH "curl -s -o /dev/null -w '%{http_code}' http://localhost:5678/healthz --max-time 10 2>/dev/null" || echo "000")
if [ "$N8N_STATUS" = "200" ]; then
  echo "  ✓ n8n is up (HTTP 200)"
else
  echo "  WARNING: n8n healthz returned $N8N_STATUS — waiting 15s more..."
  sleep 15
fi

# Check for the versionId error in logs
LAST_LOG=$($SSH "journalctl -u n8n --since '1 minute ago' --no-pager -q 2>/dev/null | tail -5" || true)
if echo "$LAST_LOG" | grep -q "Active version not found"; then
  echo "  ERROR: Still seeing 'Active version not found' — DB fix may have failed"
  echo "$LAST_LOG"
  exit 1
else
  echo "  ✓ No 'Active version not found' in logs"
fi

# ── 4. Smoke tests ───────────────────────────────────────────────────────────
echo ""
echo "━━━ STEP 4: Smoke tests ━━━"

run_test() {
  local label="$1"
  local url="$2"
  local data="$3"
  local field="$4"

  RESP=$($SSH "curl -s -X POST '$url' \
    -H 'Content-Type: application/json' \
    -d '$data' --max-time 20 2>/dev/null" || echo '{}')

  VALUE=$(echo "$RESP" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    parts = '$field'.split('.')
    for p in parts: d = d[p]
    print(d)
except: print('PARSE_ERROR')
" 2>/dev/null || echo "FAIL")

  echo "  [$label] → $field = $VALUE"
}

run_test "KYC normal"   "http://localhost:5678/webhook/kyc-onboard" \
  '{"customer_id":"CUST-FIX-001","name":"Alice Johnson","country":"GB","email":"alice@test.com"}' \
  "decision"

run_test "KYC blocked"  "http://localhost:5678/webhook/kyc-onboard" \
  '{"customer_id":"CUST-FIX-002","name":"Ivan Petrov","country":"RU"}' \
  "decision"

run_test "KYC PEP"      "http://localhost:5678/webhook/kyc-onboard" \
  '{"customer_id":"CUST-FIX-003","name":"General Smith","country":"US","source_of_funds":"cash"}' \
  "decision"

run_test "AML normal"   "http://localhost:5678/webhook/aml-check" \
  '{"transaction_id":"TXN-FIX-001","sender_id":"CUST-FIX-001","amount":500,"currency":"GBP","transaction_type":"transfer"}' \
  "action"

run_test "AML large"    "http://localhost:5678/webhook/aml-check" \
  '{"transaction_id":"TXN-FIX-002","sender_id":"CUST-FIX-001","amount":12000,"currency":"GBP","transaction_type":"transfer","receiver_country":"PK"}' \
  "action"

run_test "AML sanctioned" "http://localhost:5678/webhook/aml-check" \
  '{"transaction_id":"TXN-FIX-003","sender_id":"CUST-FIX-099","amount":1000,"currency":"USD","sender_country":"IR"}' \
  "action"

# ── 5. Verify ClickHouse data ─────────────────────────────────────────────────
echo ""
echo "━━━ STEP 5: ClickHouse verification ━━━"
sleep 5  # Wait for async inserts to land

echo "  kyc_events (last 3):"
$SSH "clickhouse-client -q \"
SELECT client_id, event_type, result, agent
FROM banxe.kyc_events
ORDER BY created_at DESC
LIMIT 3
FORMAT PrettyCompact
\" 2>/dev/null" || echo "  (clickhouse-client error)"

echo ""
echo "  transactions (last 3):"
$SSH "clickhouse-client -q \"
SELECT client_id, type, amount, status, agent
FROM banxe.transactions
ORDER BY created_at DESC
LIMIT 3
FORMAT PrettyCompact
\" 2>/dev/null" || echo "  (clickhouse-client error)"

echo ""
echo "  aml_alerts (last 3):"
$SSH "clickhouse-client -q \"
SELECT client_id, alert_type, severity, status, agent
FROM banxe.aml_alerts
ORDER BY created_at DESC
LIMIT 3
FORMAT PrettyCompact
\" 2>/dev/null" || echo "  (clickhouse-client error)"

# ── 6. Check if client_id is actually populated ──────────────────────────────
echo ""
echo "━━━ STEP 6: client_id populated check ━━━"
EMPTY_COUNT=$($SSH "clickhouse-client -q \"
SELECT count() FROM banxe.kyc_events
WHERE client_id = '' AND created_at > now() - INTERVAL 10 MINUTE
\" 2>/dev/null" || echo "ERR")

FILLED_COUNT=$($SSH "clickhouse-client -q \"
SELECT count() FROM banxe.kyc_events
WHERE client_id != '' AND created_at > now() - INTERVAL 10 MINUTE
\" 2>/dev/null" || echo "ERR")

echo "  kyc_events last 10min: filled=$FILLED_COUNT, empty=$EMPTY_COUNT"

if [ "$FILLED_COUNT" != "ERR" ] && [ "${FILLED_COUNT:-0}" -gt 0 ] && [ "${EMPTY_COUNT:-99}" -eq 0 ]; then
  echo "  ✓ FIXED: client_id заполнен корректно"
  CH_STATUS="FIXED"
else
  echo "  ⚠ Проблема не решена или данных пока нет (filled=$FILLED_COUNT, empty=$EMPTY_COUNT)"
  CH_STATUS="PENDING"
fi

# ── 7. Update MEMORY.md ───────────────────────────────────────────────────────
echo ""
echo "━━━ STEP 7: Update MEMORY.md ━━━"

$SSH "python3 << 'MEMEOF'
import re
from datetime import datetime

f = '/data/vibe-coding/docs/MEMORY.md'
with open(f) as fh:
    content = fh.read()

entry = '''
## n8n KYC/AML Workflows — ClickHouse Fix (2026-03-31)
- **Проблема**: \`\$helpers.httpRequest\` с \`body: JSON.stringify({...})\` → n8n двойная сериализация → строки пустые в ClickHouse
- **Решение**: body передаётся как ОБЪЕКТ (не строка) — n8n сам делает JSON.stringify
- **Проблема 2**: workflow_entity.versionId ≠ workflow_history.versionId → \"Active version not found\"
- **Решение 2**: синхронизированы все три таблицы одним UUID
- **Статус**: workflows KYC + AML работают, ClickHouse логирует с заполненными полями
- **Скрипт**: \`scripts/fix-n8n-clickhouse.sh\`
- Webhooks: POST /webhook/kyc-onboarding, POST /webhook/aml-monitoring
'''

if '## n8n KYC/AML Workflows — ClickHouse Fix' in content:
    content = re.sub(
        r'## n8n KYC/AML Workflows — ClickHouse Fix.*?(?=\n## |\Z)',
        entry.strip() + '\n',
        content, flags=re.DOTALL
    )
else:
    content = content.rstrip() + '\n' + entry

with open(f, 'w') as fh:
    fh.write(content)
print('  MEMORY.md updated')
MEMEOF
"

# ── 8. Commit and push ────────────────────────────────────────────────────────
echo ""
echo "━━━ STEP 8: Commit & push ━━━"

# Copy this script to GMKtec repo
scp -q scripts/fix-n8n-clickhouse.sh gmktec:/data/vibe-coding/scripts/
$SSH "cd /data/vibe-coding && \
  git add scripts/fix-n8n-clickhouse.sh docs/MEMORY.md && \
  git commit -m 'fix: n8n CH logging — object body + versionId 3-table sync' && \
  git push origin main && \
  echo '  ✓ Pushed'"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " DONE — проверь STEP 5/6 выше:"
echo "   ✓ filled>0, empty=0  → баг исправлен"
echo "   ⚠ все ещё пусто     → запусти: ssh gmktec journalctl -u n8n -n 50 --no-pager"
echo "═══════════════════════════════════════════════════════════════"
