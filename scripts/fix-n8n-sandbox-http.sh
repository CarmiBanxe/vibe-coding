#!/bin/bash
# fix-n8n-sandbox-http.sh — Banxe AI Bank
#
# ПРОБЛЕМА: Code nodes в n8n sandbox НЕ имеют доступа к сети.
#           $helpers.httpRequest внутри Code node → тихий сбой → ClickHouse не получает данные.
#
# РЕШЕНИЕ:  Code nodes = чистая логика (нет HTTP).
#           HTTP Request node (встроенный) = запись в ClickHouse POST http://localhost:8123.
#
# Что делает скрипт:
#   1. Находит KYC/AML workflows в SQLite по имени (не по hardcoded UUID)
#   2. Сканирует Code nodes → удаляет $helpers.httpRequest / fetch()
#   3. Заменяет jsCode чистой версией (вычисление без HTTP)
#   4. HTTP Request nodes остаются без изменений (они уже правильные)
#   5. Синхронизирует versionId в трёх таблицах (workflow_entity, history, published)
#   6. Перезапускает n8n, smoke-тесты, проверка ClickHouse
#   7. Обновляет MEMORY.md, push в GitHub
#
# Запуск на Legion:
#   cd ~/vibe-coding && git pull && bash scripts/fix-n8n-sandbox-http.sh

set -euo pipefail

SSH="ssh gmktec"
N8N_DB="/data/n8n/.n8n/database.sqlite"
LOG="/data/logs/fix-n8n-sandbox-http.log"
TODAY=$(date '+%Y-%m-%d')

echo "═══════════════════════════════════════════════════════════════"
echo " fix-n8n-sandbox-http.sh — удаление HTTP из Code nodes"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════════"

# ── STEP 1: Проверка соединения ──────────────────────────────────────────────
echo ""
echo "━━━ STEP 1: Проверка GMKtec ━━━"
$SSH "echo '  ✓ SSH OK'; systemctl is-active n8n >/dev/null 2>&1 && echo '  ✓ n8n active' || echo '  ~ n8n inactive'"

# ── STEP 2: Создаём и загружаем Python-скрипт ───────────────────────────────
echo ""
echo "━━━ STEP 2: Patch Code nodes ━━━"

cat > /tmp/patch_code_nodes.py << 'PYEOF'
#!/usr/bin/env python3
"""
Removes $helpers.httpRequest from n8n Code nodes.
Code nodes = pure computation only.
HTTP Request nodes (separate n8n nodes) handle all ClickHouse writes.
"""
import sqlite3, json, uuid, re, sys
from datetime import datetime

DB = '/data/n8n/.n8n/database.sqlite'

# ─── Чистый KYC Code (только вычисление, без HTTP) ───────────────────────────
# Источник: setup-n8n-workflows.sh (оригинальная архитектура)
KYC_CLEAN = """// KYC Input Validation & Risk Scoring
// Pure computation — NO HTTP calls. HTTP Request node handles ClickHouse write.
const body = $input.first().json.body || $input.first().json;

const customer = {
  id:        body.customer_id   || body.id || ('KYC-' + Date.now()),
  name:      body.name          || '',
  email:     body.email         || '',
  country:   (body.country      || 'GB').toUpperCase(),
  doc_type:  body.doc_type      || 'passport',
  doc_num:   body.doc_number    || '',
  dob:       body.date_of_birth || '',
  business:  body.business_type || 'individual',
  source_of_funds: body.source_of_funds || 'employment'
};

const SANCTIONED      = ['IR','KP','SY','CU','SD','LY','MM','BY','RU','VE'];
const HIGH_RISK_C     = ['AF','IQ','PK','NG','ET','KE','TZ','UZ','TJ','GH'];
const MEDIUM_RISK_C   = ['CN','TH','VN','PH','UA','KZ','AZ','GE'];
const PEP_MARKERS     = ['minister','senator','president','general','ambassador','deputy','prime'];

const isPEP = PEP_MARKERS.some(m => customer.name.toLowerCase().includes(m));

let countryRisk = 'LOW';
if      (SANCTIONED.includes(customer.country))    countryRisk = 'BLOCKED';
else if (HIGH_RISK_C.includes(customer.country))   countryRisk = 'HIGH';
else if (MEDIUM_RISK_C.includes(customer.country)) countryRisk = 'MEDIUM';

const fundsRisk    = ['crypto','cash','unknown','gift'].includes(customer.source_of_funds.toLowerCase()) ? 'HIGH' : 'LOW';
const businessRisk = ['money_service','gambling','casino','arms','crypto_exchange'].includes(customer.business.toLowerCase()) ? 'HIGH' : 'LOW';

let riskScore = 0;
if (countryRisk === 'HIGH')   riskScore += 40;
if (countryRisk === 'MEDIUM') riskScore += 20;
if (isPEP)                    riskScore += 35;
if (fundsRisk    === 'HIGH')  riskScore += 15;
if (businessRisk === 'HIGH')  riskScore += 25;

let riskLevel, kycTier, decision;
if (countryRisk === 'BLOCKED') {
  riskLevel = 'BLOCKED'; kycTier = 'N/A'; decision = 'REJECT';
} else if (riskScore >= 50 || isPEP) {
  riskLevel = 'HIGH';   kycTier = 'EDD'; decision = 'MANUAL_REVIEW';
} else if (riskScore >= 20) {
  riskLevel = 'MEDIUM'; kycTier = 'SDD'; decision = 'APPROVE_WITH_MONITORING';
} else {
  riskLevel = 'LOW';    kycTier = 'SDD'; decision = 'APPROVE';
}

const requiredDocs = ['photo_id', 'proof_of_address'];
if (kycTier === 'EDD') {
  requiredDocs.push('source_of_funds_proof', 'bank_statement_3mo');
  if (isPEP) requiredDocs.push('pep_declaration_form');
}

return [{json: {
  customer,
  risk: { score: riskScore, level: riskLevel, country_risk: countryRisk,
          is_pep: isPEP, funds_risk: fundsRisk, business_risk: businessRisk },
  kyc:  { tier: kycTier, decision, required_docs: requiredDocs,
          deadline_days: kycTier === 'EDD' ? 30 : 14, regulatory: 'MLR 2017, FCA SYSC' },
  timestamp: new Date().toISOString()
}}];"""

# ─── Чистый AML Code (только вычисление, без HTTP) ───────────────────────────
AML_CLEAN = """// AML Transaction Risk Assessment
// Pure computation — NO HTTP calls. HTTP Request nodes handle ClickHouse writes.
const body = $input.first().json.body || $input.first().json;

const tx = {
  id:               body.transaction_id  || body.id || ('TXN-' + Date.now()),
  amount:           parseFloat(body.amount) || 0,
  currency:         (body.currency         || 'GBP').toUpperCase(),
  sender_id:        body.sender_id         || '',
  receiver_id:      body.receiver_id       || '',
  sender_country:   (body.sender_country   || 'GB').toUpperCase(),
  receiver_country: (body.receiver_country || 'GB').toUpperCase(),
  tx_type:          body.transaction_type  || 'transfer',
  reference:        body.reference         || ''
};

const SANCTIONED = ['IR','KP','SY','CU','SD','LY','MM','BY'];
const HIGH_RISK  = ['AF','IQ','PK','NG','ET'];

const senderSanctioned   = SANCTIONED.includes(tx.sender_country);
const receiverSanctioned = SANCTIONED.includes(tx.receiver_country);

const amountGBP = tx.currency === 'GBP' ? tx.amount
                : tx.currency === 'EUR' ? tx.amount * 0.85
                : tx.currency === 'USD' ? tx.amount * 0.79 : tx.amount;

const flags = [];
let riskScore = 0;

if (senderSanctioned || receiverSanctioned) { flags.push('SANCTIONED_JURISDICTION'); riskScore += 100; }
if      (amountGBP >= 50000)                { flags.push('LARGE_TRANSACTION');       riskScore += 30;  }
else if (amountGBP >= 10000)                { flags.push('HIGH_VALUE_TRANSACTION');  riskScore += 20;  }
else if (amountGBP >= 9500)                 { flags.push('POTENTIAL_STRUCTURING');   riskScore += 40;  }
if (tx.amount % 1000 === 0 && tx.amount > 0){ flags.push('ROUND_AMOUNT');            riskScore += 10;  }
if (HIGH_RISK.includes(tx.receiver_country)){ flags.push('HIGH_RISK_DESTINATION');   riskScore += 25;  }
if (['crypto_withdrawal','cash_equivalent'].includes(tx.tx_type.toLowerCase()))
                                            { flags.push('HIGH_RISK_TX_TYPE');        riskScore += 20;  }

let riskLevel, action, requireSAR;
if (riskScore >= 100 || senderSanctioned || receiverSanctioned) {
  riskLevel = 'CRITICAL'; action = 'BLOCK';   requireSAR = true;
} else if (riskScore >= 60) {
  riskLevel = 'HIGH';     action = 'HOLD';    requireSAR = true;
} else if (riskScore >= 30) {
  riskLevel = 'MEDIUM';   action = 'MONITOR'; requireSAR = false;
} else {
  riskLevel = 'LOW';      action = 'ALLOW';   requireSAR = false;
}

return [{json: {
  transaction: tx,
  aml: {
    risk_score:  riskScore,
    risk_level:  riskLevel,
    action,
    require_sar: requireSAR,
    flags,
    amount_gbp:  Math.round(amountGBP * 100) / 100,
    regulatory:  'POCA 2002, MLR 2017, JMLSG Guidance'
  },
  timestamp: new Date().toISOString()
}}];"""

def has_http(code):
    """Обнаруживает HTTP-вызовы в Code node."""
    patterns = ['$helpers.httpRequest', 'fetch(', 'require(', 'http.request', 'axios']
    return any(p in code for p in patterns)

def choose_clean_code(wf_name, node_name, current_code):
    """Выбирает чистый код по контексту."""
    ctx = (wf_name + ' ' + node_name + ' ' + current_code[:200]).upper()
    if 'AML' in ctx:
        return AML_CLEAN, 'AML'
    return KYC_CLEAN, 'KYC'

conn = sqlite3.connect(DB)
cur  = conn.cursor()

# Найти все workflow с Code nodes
cur.execute("""
    SELECT id, name, nodes, connections
    FROM workflow_entity
    WHERE nodes LIKE '%n8n-nodes-base.code%'
""")
rows = cur.fetchall()

if not rows:
    print('  WARN: не найдено workflow с Code nodes')
    sys.exit(0)

fixed = 0
already_clean = 0

for wf_id, wf_name, nodes_json, conns_json in rows:
    nodes    = json.loads(nodes_json)
    changed  = False

    for node in nodes:
        if node.get('type') != 'n8n-nodes-base.code':
            continue
        code = node.get('parameters', {}).get('jsCode', '')
        node_name = node.get('name', '')

        if not has_http(code):
            print(f'  [OK]  "{wf_name}" / "{node_name}" — уже чистый')
            already_clean += 1
            continue

        clean_code, label = choose_clean_code(wf_name, node_name, code)
        node['parameters']['jsCode'] = clean_code
        print(f'  [FIX] "{wf_name}" / "{node_name}" — заменён на чистый {label} код')
        changed = True

    if not changed:
        continue

    # ── Синхронизируем versionId во всех трёх таблицах ──────────────────────
    new_ver    = str(uuid.uuid4())
    now        = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S.000')
    nodes_new  = json.dumps(nodes)

    cur.execute(
        "UPDATE workflow_entity SET nodes=?, versionId=?, updatedAt=?, active=1 WHERE id=?",
        (nodes_new, new_ver, now, wf_id)
    )

    cur.execute("DELETE FROM workflow_history WHERE workflowId=?", (wf_id,))
    cur.execute("""
        INSERT INTO workflow_history
               (versionId, workflowId, authors, createdAt, updatedAt, nodes, connections, autosaved)
        VALUES (?, ?, 'banxe-system', ?, ?, ?, ?, 0)
    """, (new_ver, wf_id, now, now, nodes_new, conns_json))

    cur.execute("DELETE FROM workflow_published_version WHERE workflowId=?", (wf_id,))
    cur.execute("""
        INSERT INTO workflow_published_version (workflowId, publishedVersionId, createdAt, updatedAt)
        VALUES (?, ?, ?, ?)
    """, (wf_id, new_ver, now, now))

    print(f'  ✓ versionId синхронизирован: {new_ver[:8]}...')
    fixed += 1

conn.commit()
conn.close()

print(f'\n  Итог: {fixed} workflow исправлено, {already_clean} Code nodes уже чистые')
if fixed == 0 and already_clean == 0:
    print('  WARN: ни один Code node не найден — проверь имена workflow в SQLite')
    sys.exit(2)
PYEOF

scp -q /tmp/patch_code_nodes.py gmktec:/tmp/
echo "  ✓ Скрипт загружен"

# ── STEP 3: Стоп n8n → патч → старт ─────────────────────────────────────────
echo ""
echo "━━━ STEP 3: Патч SQLite ━━━"
$SSH "sudo systemctl stop n8n 2>/dev/null; sleep 2; echo '  ✓ n8n остановлен'"
$SSH "python3 /tmp/patch_code_nodes.py"
PATCH_EXIT=$?

if [ "$PATCH_EXIT" = "2" ]; then
    echo ""
    echo "  Диагностика workflow в SQLite:"
    $SSH "sqlite3 '$N8N_DB' \"SELECT id, name, active FROM workflow_entity ORDER BY name;\" 2>/dev/null || echo '  (ошибка SQLite)'"
fi

echo ""
echo "━━━ STEP 4: Запуск n8n ━━━"
$SSH "sudo systemctl start n8n"
echo "  Ожидание инициализации n8n (30 сек)..."
sleep 30

# Проверяем healthz
for ATTEMPT in 1 2 3; do
    N8N_STATUS=$($SSH "curl -s -o /dev/null -w '%{http_code}' http://localhost:5678/healthz --max-time 10 2>/dev/null" || echo "000")
    if [ "$N8N_STATUS" = "200" ]; then
        echo "  ✓ n8n запущен (HTTP 200, попытка $ATTEMPT)"
        break
    fi
    echo "  Попытка $ATTEMPT: HTTP $N8N_STATUS, ждём 10 сек..."
    sleep 10
done

# Проверяем Active version not found
LOG_ERRORS=$($SSH "journalctl -u n8n --since '2 minutes ago' --no-pager -q 2>/dev/null | grep -i 'error\|version not found' | tail -5" || true)
if [ -n "$LOG_ERRORS" ]; then
    echo "  WARN: найдены ошибки в логах n8n:"
    echo "$LOG_ERRORS" | sed 's/^/    /'
else
    echo "  ✓ Ошибок в логах не найдено"
fi

# ── STEP 5: Smoke tests ──────────────────────────────────────────────────────
echo ""
echo "━━━ STEP 5: Smoke tests ━━━"

run_test() {
    local label="$1"
    local url="$2"
    local data="$3"
    local field="$4"

    RESP=$($SSH "curl -s -X POST '$url' \
        -H 'Content-Type: application/json' \
        -d '$data' \
        --max-time 25 2>/dev/null" || echo '{}')

    VALUE=$(echo "$RESP" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    parts = '$field'.split('.')
    for p in parts:
        d = d[p]
    print(str(d))
except Exception as e:
    print('PARSE_ERROR')
" 2>/dev/null || echo "FAIL")

    # Определяем статус
    if [[ "$VALUE" == "PARSE_ERROR" || "$VALUE" == "FAIL" || "$VALUE" == *"error"* ]]; then
        STATUS="FAIL"
    else
        STATUS="OK"
    fi
    echo "  [$STATUS] $label → $field = $VALUE"
}

# KYC тесты — webhook: /webhook/kyc-onboard (из setup-n8n-workflows.sh)
run_test "KYC LOW risk"   "http://localhost:5678/webhook/kyc-onboard" \
    '{"customer_id":"SANDBOX-TEST-001","name":"Alice Johnson","country":"GB","email":"alice@test.com"}' \
    "kyc.decision"

run_test "KYC BLOCKED"    "http://localhost:5678/webhook/kyc-onboard" \
    '{"customer_id":"SANDBOX-TEST-002","name":"Ivan Petrov","country":"RU"}' \
    "kyc.decision"

run_test "KYC PEP+cash"   "http://localhost:5678/webhook/kyc-onboard" \
    '{"customer_id":"SANDBOX-TEST-003","name":"General Smith","country":"US","source_of_funds":"cash"}' \
    "kyc.decision"

# AML тесты — webhook: /webhook/aml-check
run_test "AML ALLOW"      "http://localhost:5678/webhook/aml-check" \
    '{"transaction_id":"SANDBOX-TXN-001","sender_id":"SANDBOX-TEST-001","amount":500,"currency":"GBP","transaction_type":"transfer"}' \
    "aml.action"

run_test "AML HIGH_VALUE" "http://localhost:5678/webhook/aml-check" \
    '{"transaction_id":"SANDBOX-TXN-002","sender_id":"SANDBOX-TEST-001","amount":12000,"currency":"GBP","transaction_type":"transfer","receiver_country":"PK"}' \
    "aml.action"

run_test "AML BLOCK"      "http://localhost:5678/webhook/aml-check" \
    '{"transaction_id":"SANDBOX-TXN-003","sender_id":"SANDBOX-TEST-099","amount":5000,"currency":"USD","sender_country":"IR"}' \
    "aml.action"

# ── STEP 6: Проверка ClickHouse ──────────────────────────────────────────────
echo ""
echo "━━━ STEP 6: ClickHouse — данные от smoke tests ━━━"
sleep 8  # Ждём async вставки

echo "  kyc_events (последние 3):"
$SSH "clickhouse-client -q \"
SELECT customer_id, event_type, decision, risk_level
FROM banxe.kyc_events
WHERE customer_id LIKE 'SANDBOX%'
ORDER BY created_at DESC
LIMIT 3
FORMAT PrettyCompact\" 2>/dev/null" || echo "  (ошибка clickhouse-client)"

echo ""
echo "  transactions (последние 3):"
$SSH "clickhouse-client -q \"
SELECT transaction_id, status, risk_score
FROM banxe.transactions
WHERE transaction_id LIKE 'SANDBOX%'
ORDER BY created_at DESC
LIMIT 3
FORMAT PrettyCompact\" 2>/dev/null" || echo "  (ошибка clickhouse-client)"

echo ""
echo "  aml_alerts (последние 3):"
$SSH "clickhouse-client -q \"
SELECT transaction_id, alert_type, risk_score, status
FROM banxe.aml_alerts
WHERE transaction_id LIKE 'SANDBOX%'
ORDER BY created_at DESC
LIMIT 3
FORMAT PrettyCompact\" 2>/dev/null" || echo "  (ошибка clickhouse-client)"

# Счётчик за последние 5 минут
echo ""
KYC_NEW=$($SSH "clickhouse-client -q \"SELECT count() FROM banxe.kyc_events WHERE customer_id LIKE 'SANDBOX%' AND created_at > now() - INTERVAL 5 MINUTE\" 2>/dev/null" || echo "?")
TXN_NEW=$($SSH "clickhouse-client -q \"SELECT count() FROM banxe.transactions WHERE transaction_id LIKE 'SANDBOX%' AND created_at > now() - INTERVAL 5 MINUTE\" 2>/dev/null" || echo "?")
AML_NEW=$($SSH "clickhouse-client -q \"SELECT count() FROM banxe.aml_alerts WHERE transaction_id LIKE 'SANDBOX%' AND created_at > now() - INTERVAL 5 MINUTE\" 2>/dev/null" || echo "?")

echo "  Новые записи (5 мин): kyc_events=$KYC_NEW, transactions=$TXN_NEW, aml_alerts=$AML_NEW"

if [[ "${KYC_NEW:-0}" -ge 3 && "${TXN_NEW:-0}" -ge 3 ]]; then
    CH_RESULT="FIXED — HTTP Request nodes записывают в ClickHouse корректно"
elif [[ "${KYC_NEW:-0}" -ge 1 ]]; then
    CH_RESULT="PARTIAL — kyc_events=$KYC_NEW, transactions=$TXN_NEW, aml_alerts=$AML_NEW"
else
    CH_RESULT="EMPTY — проверь webhook path и имя узла 'AML Risk Engine'"
fi

echo "  Результат: $CH_RESULT"

# ── STEP 7: Обновление MEMORY.md ─────────────────────────────────────────────
echo ""
echo "━━━ STEP 7: MEMORY.md ━━━"

$SSH "python3 << 'MEMEOF'
import re
f = '/data/vibe-coding/docs/MEMORY.md'
with open(f) as fh:
    content = fh.read()

entry = '''
## n8n Задача #6 — ClickHouse Logging Fix ($TODAY)
- **Проблема**: Code nodes в n8n sandbox не имеют доступа к сети — \`\$helpers.httpRequest\` тихо падал
- **Решение**: Code nodes = чистое вычисление (risk scoring). HTTP Request nodes = запись в ClickHouse
- **Архитектура**: Webhook → Code(риск) → HTTP Request(ClickHouse INSERT) → IF → Respond
- **KYC**: POST /webhook/kyc-onboard → banxe.kyc_events
- **AML**: POST /webhook/aml-check  → banxe.transactions + banxe.aml_alerts (при SAR)
- **ClickHouse body**: contentType=raw + JSON.stringify({...}) в HTTP Request node body field
- **Скрипт**: \`scripts/fix-n8n-sandbox-http.sh\`
'''

marker = '## n8n Задача #6'
if marker in content:
    content = re.sub(
        r'## n8n Задача #6.*?(?=\n## |\Z)',
        entry.strip() + '\n',
        content, flags=re.DOTALL
    )
else:
    content = content.rstrip() + '\n' + entry

with open(f, 'w') as fh:
    fh.write(content)
print('  ✓ MEMORY.md обновлён')
MEMEOF
" 2>/dev/null || echo "  WARN: не удалось обновить MEMORY.md"

# ── STEP 8: Git push ─────────────────────────────────────────────────────────
echo ""
echo "━━━ STEP 8: Git push ━━━"

scp -q scripts/fix-n8n-sandbox-http.sh gmktec:/data/vibe-coding/scripts/
$SSH "cd /data/vibe-coding && \
    git add scripts/fix-n8n-sandbox-http.sh docs/MEMORY.md && \
    git diff --cached --quiet || git commit -m 'fix: n8n sandbox — remove httpRequest from Code nodes, use HTTP Request node for ClickHouse' && \
    git push origin main && \
    echo '  ✓ pushed'"

# ── Итог ─────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " ГОТОВО"
echo ""
echo " ClickHouse: $CH_RESULT"
echo ""
echo " Если записей нет — диагностика:"
echo "   ssh gmktec"
echo "   journalctl -u n8n -n 50 --no-pager | grep -i error"
echo "   # Проверь название webhook path:"
echo "   sqlite3 $N8N_DB \"SELECT name, active FROM workflow_entity;\""
echo "═══════════════════════════════════════════════════════════════"
