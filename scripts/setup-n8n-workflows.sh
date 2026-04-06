#!/bin/bash
###############################################################################
# setup-n8n-workflows.sh — Banxe AI Bank
# Задача #6: n8n KYC/AML workflows
#
# Создаёт:
#   1. KYC Onboarding Workflow  — POST /webhook/kyc-onboard
#   2. AML Transaction Monitor  — POST /webhook/aml-check
#   3. API ключ n8n в SQLite (для скриптового доступа)
#
# Запуск на GMKtec: bash /data/vibe-coding/scripts/setup-n8n-workflows.sh
###############################################################################

set -euo pipefail

LOG="/data/logs/setup-n8n-workflows.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
N8N_DB="/data/n8n/.n8n/database.sqlite"
WORKFLOW_DIR="/tmp/banxe-n8n-workflows"
N8N_USER_ID="9f4c8c4c-7851-4771-abd6-e975d7c562f4"
N8N_API_KEY="banxe-n8n-$(openssl rand -hex 16)"

mkdir -p /data/logs "$WORKFLOW_DIR"
exec > >(tee -a "$LOG") 2>&1

echo ""
echo "============================================================"
echo " setup-n8n-workflows.sh — $TIMESTAMP"
echo "============================================================"

###############################################################################
# 1. Создаём n8n API ключ (один раз)
###############################################################################
echo ""
echo "[ API KEY ]"

EXISTING_KEY=$(sqlite3 "$N8N_DB" "SELECT apiKey FROM user_api_keys WHERE userId='$N8N_USER_ID' AND label='banxe-automation' LIMIT 1;" 2>/dev/null || echo "")

if [ -n "$EXISTING_KEY" ]; then
    N8N_API_KEY="$EXISTING_KEY"
    echo "  ~ API ключ уже существует: ${N8N_API_KEY:0:20}..."
else
    KEY_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    sqlite3 "$N8N_DB" "INSERT INTO user_api_keys (id, userId, label, apiKey, scopes, audience) VALUES ('$KEY_ID', '$N8N_USER_ID', 'banxe-automation', '$N8N_API_KEY', NULL, 'public-api');" 2>/dev/null
    echo "  ✓ API ключ создан: ${N8N_API_KEY:0:20}..."
    # Сохраняем в файл конфига (не в репозиторий)
    echo "N8N_API_KEY=$N8N_API_KEY" > /data/n8n/banxe-api.env
    chmod 600 /data/n8n/banxe-api.env
fi

# Проверяем API
sleep 1
API_TEST=$(curl -s -m 5 -H "X-N8N-API-KEY: $N8N_API_KEY" http://localhost:5678/api/v1/workflows 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK: ' + str(len(d.get('data',[]))) + ' workflows')" 2>/dev/null || echo "FAIL")
echo "  API тест: $API_TEST"

###############################################################################
# 2. Workflow: KYC Onboarding
###############################################################################
echo ""
echo "[ WORKFLOW: KYC Onboarding ]"

cat > "$WORKFLOW_DIR/kyc-onboarding.json" << 'WORKFLOW_EOF'
{
  "name": "KYC Onboarding — Banxe",
  "nodes": [
    {
      "parameters": {
        "httpMethod": "POST",
        "path": "kyc-onboard",
        "responseMode": "responseNode",
        "options": {}
      },
      "id": "webhook-kyc",
      "name": "Webhook KYC",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 2,
      "position": [240, 300],
      "webhookId": "kyc-onboard-banxe"
    },
    {
      "parameters": {
        "jsCode": "// KYC Input Validation & Risk Scoring\nconst body = $input.first().json.body || $input.first().json;\n\n// --- Входные данные ---\nconst customer = {\n  id:        body.customer_id  || body.id || ('KYC-' + Date.now()),\n  name:      body.name         || '',\n  email:     body.email        || '',\n  country:   (body.country     || 'GB').toUpperCase(),\n  doc_type:  body.doc_type     || 'passport',\n  doc_num:   body.doc_number   || '',\n  dob:       body.date_of_birth || '',\n  business:  body.business_type || 'individual',\n  source_of_funds: body.source_of_funds || 'employment'\n};\n\n// --- Санкционные страны (OFAC/UK/EU) ---\nconst SANCTIONED = ['IR','KP','SY','CU','SD','LY','MM','BY','RU','VE'];\n\n// --- PEP-маркеры в имени (упрощённо) ---\nconst PEP_MARKERS = ['minister','senator','president','general','ambassador','deputy','prime'];\nconst lowerName = customer.name.toLowerCase();\nconst isPEP = PEP_MARKERS.some(m => lowerName.includes(m));\n\n// --- Страновой риск ---\nconst HIGH_RISK_COUNTRIES = ['AF','IQ','PK','NG','ET','KE','TZ','UZ','TJ','GH'];\nconst MEDIUM_RISK_COUNTRIES = ['CN','TH','VN','PH','UA','KZ','AZ','GE'];\n\nlet countryRisk = 'LOW';\nif (SANCTIONED.includes(customer.country))      countryRisk = 'BLOCKED';\nelse if (HIGH_RISK_COUNTRIES.includes(customer.country))   countryRisk = 'HIGH';\nelse if (MEDIUM_RISK_COUNTRIES.includes(customer.country)) countryRisk = 'MEDIUM';\n\n// --- Риск источника средств ---\nconst HIGH_RISK_FUNDS = ['crypto','cash','unknown','gift'];\nconst fundsRisk = HIGH_RISK_FUNDS.includes(customer.source_of_funds.toLowerCase()) ? 'HIGH' : 'LOW';\n\n// --- Тип бизнеса ---\nconst HIGH_RISK_BUSINESS = ['money_service','gambling','casino','arms','crypto_exchange'];\nconst businessRisk = HIGH_RISK_BUSINESS.includes(customer.business.toLowerCase()) ? 'HIGH' : 'LOW';\n\n// --- Итоговый риск ---\nlet riskScore = 0;\nif (countryRisk === 'HIGH')    riskScore += 40;\nif (countryRisk === 'MEDIUM')  riskScore += 20;\nif (isPEP)                     riskScore += 35;\nif (fundsRisk === 'HIGH')      riskScore += 15;\nif (businessRisk === 'HIGH')   riskScore += 25;\n\nlet riskLevel, kycTier, decision;\nif (countryRisk === 'BLOCKED') {\n  riskLevel = 'BLOCKED'; kycTier = 'N/A'; decision = 'REJECT';\n} else if (riskScore >= 50 || isPEP) {\n  riskLevel = 'HIGH';   kycTier = 'EDD';  decision = 'MANUAL_REVIEW';\n} else if (riskScore >= 20) {\n  riskLevel = 'MEDIUM'; kycTier = 'SDD';  decision = 'APPROVE_WITH_MONITORING';\n} else {\n  riskLevel = 'LOW';    kycTier = 'SDD';  decision = 'APPROVE';\n}\n\n// --- Необходимые документы ---\nconst requiredDocs = ['photo_id', 'proof_of_address'];\nif (kycTier === 'EDD') {\n  requiredDocs.push('source_of_funds_proof', 'bank_statement_3mo');\n  if (isPEP) requiredDocs.push('pep_declaration_form');\n}\n\nreturn [{\n  json: {\n    customer,\n    risk: {\n      score:        riskScore,\n      level:        riskLevel,\n      country_risk: countryRisk,\n      is_pep:       isPEP,\n      funds_risk:   fundsRisk,\n      business_risk: businessRisk\n    },\n    kyc: {\n      tier:          kycTier,\n      decision:      decision,\n      required_docs: requiredDocs,\n      deadline_days: kycTier === 'EDD' ? 30 : 14,\n      regulatory:    'MLR 2017, FCA SYSC'\n    },\n    timestamp: new Date().toISOString()\n  }\n}];\n"
      },
      "id": "code-kyc-risk",
      "name": "Risk Scoring",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [480, 300]
    },
    {
      "parameters": {
        "method": "POST",
        "url": "http://localhost:8123/?query=INSERT%20INTO%20banxe.kyc_events%20FORMAT%20JSONEachRow",
        "sendHeaders": true,
        "headerParameters": {
          "parameters": [
            {"name": "Content-Type", "value": "application/json"}
          ]
        },
        "sendBody": true,
        "contentType": "raw",
        "rawContentType": "application/json",
        "body": "={{ JSON.stringify({ customer_id: $json.customer.id, event_type: 'ONBOARDING_ASSESSMENT', risk_level: $json.risk.level, risk_score: $json.risk.score, kyc_tier: $json.kyc.tier, decision: $json.kyc.decision, country: $json.customer.country, is_pep: $json.risk.is_pep ? 1 : 0, created_at: $json.timestamp }) }}",
        "options": {}
      },
      "id": "ch-kyc-insert",
      "name": "Log to ClickHouse",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [720, 300]
    },
    {
      "parameters": {
        "conditions": {
          "options": {"caseSensitive": true, "leftValue": "", "typeValidation": "strict"},
          "conditions": [
            {
              "id": "cond-high",
              "leftValue": "={{ $('Risk Scoring').item.json.risk.level }}",
              "rightValue": "BLOCKED",
              "operator": {"type": "string", "operation": "notEquals"}
            }
          ],
          "combinator": "and"
        },
        "options": {}
      },
      "id": "if-blocked",
      "name": "Not Blocked?",
      "type": "n8n-nodes-base.if",
      "typeVersion": 2,
      "position": [960, 300]
    },
    {
      "parameters": {
        "respondWith": "json",
        "responseBody": "={{ JSON.stringify({ status: 'success', customer_id: $('Risk Scoring').item.json.customer.id, decision: $('Risk Scoring').item.json.kyc.decision, risk_level: $('Risk Scoring').item.json.risk.level, risk_score: $('Risk Scoring').item.json.risk.score, kyc_tier: $('Risk Scoring').item.json.kyc.tier, required_documents: $('Risk Scoring').item.json.kyc.required_docs, deadline_days: $('Risk Scoring').item.json.kyc.deadline_days, is_pep: $('Risk Scoring').item.json.risk.is_pep, timestamp: $('Risk Scoring').item.json.timestamp }) }}",
        "options": {"responseCode": 200}
      },
      "id": "respond-ok",
      "name": "Respond OK",
      "type": "n8n-nodes-base.respondToWebhook",
      "typeVersion": 1.1,
      "position": [1200, 200]
    },
    {
      "parameters": {
        "respondWith": "json",
        "responseBody": "={ \"status\": \"rejected\", \"reason\": \"Sanctioned jurisdiction\", \"customer_id\": \"{{ $('Risk Scoring').item.json.customer.id }}\", \"regulatory_basis\": \"UK Sanctions and Anti-Money Laundering Act 2018\" }",
        "options": {"responseCode": 403}
      },
      "id": "respond-blocked",
      "name": "Respond Blocked",
      "type": "n8n-nodes-base.respondToWebhook",
      "typeVersion": 1.1,
      "position": [1200, 420]
    }
  ],
  "connections": {
    "Webhook KYC":     {"main": [[{"node": "Risk Scoring",      "type": "main", "index": 0}]]},
    "Risk Scoring":    {"main": [[{"node": "Log to ClickHouse", "type": "main", "index": 0}]]},
    "Log to ClickHouse": {"main": [[{"node": "Not Blocked?",    "type": "main", "index": 0}]]},
    "Not Blocked?":    {"main": [
      [{"node": "Respond OK",      "type": "main", "index": 0}],
      [{"node": "Respond Blocked", "type": "main", "index": 0}]
    ]}
  },
  "active": true,
  "settings": {"executionOrder": "v1"},
  "tags": [{"name": "KYC"}, {"name": "Compliance"}, {"name": "Banxe"}]
}
WORKFLOW_EOF

echo "  ✓ kyc-onboarding.json создан"

###############################################################################
# 3. Workflow: AML Transaction Monitor
###############################################################################
echo ""
echo "[ WORKFLOW: AML Transaction Monitor ]"

cat > "$WORKFLOW_DIR/aml-monitor.json" << 'WORKFLOW_EOF'
{
  "name": "AML Transaction Monitor — Banxe",
  "nodes": [
    {
      "parameters": {
        "httpMethod": "POST",
        "path": "aml-check",
        "responseMode": "responseNode",
        "options": {}
      },
      "id": "webhook-aml",
      "name": "Webhook AML",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 2,
      "position": [240, 300],
      "webhookId": "aml-check-banxe"
    },
    {
      "parameters": {
        "jsCode": "// AML Transaction Risk Assessment\nconst body = $input.first().json.body || $input.first().json;\n\n// --- Входные данные ---\nconst tx = {\n  id:          body.transaction_id || body.id || ('TXN-' + Date.now()),\n  amount:      parseFloat(body.amount)      || 0,\n  currency:    (body.currency || 'GBP').toUpperCase(),\n  sender_id:   body.sender_id   || '',\n  receiver_id: body.receiver_id || '',\n  sender_country:   (body.sender_country   || 'GB').toUpperCase(),\n  receiver_country: (body.receiver_country || 'GB').toUpperCase(),\n  tx_type:     body.transaction_type || 'transfer',\n  reference:   body.reference || ''\n};\n\n// --- Санкционные страны ---\nconst SANCTIONED = ['IR','KP','SY','CU','SD','LY','MM','BY'];\n\n// --- Пороги (FCA/JMLSG) ---\nconst THRESHOLD_SAR    = 10000;  // Подозрительный отчёт (SAR)\nconst THRESHOLD_LARGE  = 50000;  // Крупная транзакция\nconst THRESHOLD_STRUCT =  9500;  // Ниже порога — возможное structuring\n\n// --- Флаги ---\nconst flags = [];\nlet riskScore = 0;\n\n// Санкции\nconst senderSanctioned   = SANCTIONED.includes(tx.sender_country);\nconst receiverSanctioned = SANCTIONED.includes(tx.receiver_country);\nif (senderSanctioned || receiverSanctioned) {\n  flags.push('SANCTIONED_JURISDICTION');\n  riskScore += 100;\n}\n\n// Крупная сумма\nconst amountGBP = tx.currency === 'GBP' ? tx.amount :\n                  tx.currency === 'EUR' ? tx.amount * 0.85 :\n                  tx.currency === 'USD' ? tx.amount * 0.79 : tx.amount;\n\nif (amountGBP >= THRESHOLD_LARGE) {\n  flags.push('LARGE_TRANSACTION');\n  riskScore += 30;\n} else if (amountGBP >= THRESHOLD_SAR) {\n  flags.push('HIGH_VALUE_TRANSACTION');\n  riskScore += 20;\n} else if (amountGBP >= THRESHOLD_STRUCT && amountGBP < THRESHOLD_SAR) {\n  flags.push('POTENTIAL_STRUCTURING');\n  riskScore += 40;\n}\n\n// Круглые числа (признак структурирования)\nif (tx.amount % 1000 === 0 && tx.amount > 0) {\n  flags.push('ROUND_AMOUNT');\n  riskScore += 10;\n}\n\n// Высокорисковые страны\nconst HIGH_RISK = ['AF','IQ','PK','NG','ET'];\nif (HIGH_RISK.includes(tx.receiver_country)) {\n  flags.push('HIGH_RISK_DESTINATION');\n  riskScore += 25;\n}\n\n// Тип транзакции\nif (['crypto_withdrawal','cash_equivalent'].includes(tx.tx_type.toLowerCase())) {\n  flags.push('HIGH_RISK_TX_TYPE');\n  riskScore += 20;\n}\n\n// --- Решение ---\nlet riskLevel, action, requireSAR;\nif (riskScore >= 100 || senderSanctioned || receiverSanctioned) {\n  riskLevel = 'CRITICAL'; action = 'BLOCK';   requireSAR = true;\n} else if (riskScore >= 60) {\n  riskLevel = 'HIGH';     action = 'HOLD';    requireSAR = true;\n} else if (riskScore >= 30) {\n  riskLevel = 'MEDIUM';   action = 'MONITOR'; requireSAR = false;\n} else {\n  riskLevel = 'LOW';      action = 'ALLOW';   requireSAR = false;\n}\n\nreturn [{\n  json: {\n    transaction: tx,\n    aml: {\n      risk_score:    riskScore,\n      risk_level:    riskLevel,\n      action:        action,\n      require_sar:   requireSAR,\n      flags:         flags,\n      amount_gbp:    Math.round(amountGBP * 100) / 100,\n      regulatory:    'POCA 2002, MLR 2017, JMLSG Guidance'\n    },\n    timestamp: new Date().toISOString()\n  }\n}];\n"
      },
      "id": "code-aml-risk",
      "name": "AML Risk Engine",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [480, 300]
    },
    {
      "parameters": {
        "method": "POST",
        "url": "http://localhost:8123/?query=INSERT%20INTO%20banxe.transactions%20FORMAT%20JSONEachRow",
        "sendHeaders": true,
        "headerParameters": {
          "parameters": [{"name": "Content-Type", "value": "application/json"}]
        },
        "sendBody": true,
        "contentType": "raw",
        "rawContentType": "application/json",
        "body": "={{ JSON.stringify({ transaction_id: $json.transaction.id, sender_id: $json.transaction.sender_id, receiver_id: $json.transaction.receiver_id, amount: $json.aml.amount_gbp, currency: 'GBP', transaction_type: $json.transaction.tx_type, status: $json.aml.action === 'ALLOW' ? 'approved' : ($json.aml.action === 'BLOCK' ? 'blocked' : 'pending'), risk_score: $json.aml.risk_score, created_at: $json.timestamp }) }}",
        "options": {}
      },
      "id": "ch-tx-insert",
      "name": "Log Transaction",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [720, 200]
    },
    {
      "parameters": {
        "conditions": {
          "options": {"caseSensitive": true, "leftValue": "", "typeValidation": "strict"},
          "conditions": [
            {
              "id": "cond-sar",
              "leftValue": "={{ $('AML Risk Engine').item.json.aml.require_sar }}",
              "rightValue": true,
              "operator": {"type": "boolean", "operation": "true"}
            }
          ],
          "combinator": "and"
        },
        "options": {}
      },
      "id": "if-sar",
      "name": "Requires SAR?",
      "type": "n8n-nodes-base.if",
      "typeVersion": 2,
      "position": [960, 300]
    },
    {
      "parameters": {
        "method": "POST",
        "url": "http://localhost:8123/?query=INSERT%20INTO%20banxe.aml_alerts%20FORMAT%20JSONEachRow",
        "sendHeaders": true,
        "headerParameters": {
          "parameters": [{"name": "Content-Type", "value": "application/json"}]
        },
        "sendBody": true,
        "contentType": "raw",
        "rawContentType": "application/json",
        "body": "={{ JSON.stringify({ alert_id: 'AML-' + Date.now(), transaction_id: $('AML Risk Engine').item.json.transaction.id, customer_id: $('AML Risk Engine').item.json.transaction.sender_id, alert_type: $('AML Risk Engine').item.json.aml.flags.join(','), risk_score: $('AML Risk Engine').item.json.aml.risk_score, status: 'PENDING_REVIEW', assigned_to: 'compliance@banxe.com', created_at: $('AML Risk Engine').item.json.timestamp }) }}",
        "options": {}
      },
      "id": "ch-alert-insert",
      "name": "Create AML Alert",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [1200, 180]
    },
    {
      "parameters": {
        "respondWith": "json",
        "responseBody": "={{ JSON.stringify({ status: 'assessed', transaction_id: $('AML Risk Engine').item.json.transaction.id, action: $('AML Risk Engine').item.json.aml.action, risk_level: $('AML Risk Engine').item.json.aml.risk_level, risk_score: $('AML Risk Engine').item.json.aml.risk_score, flags: $('AML Risk Engine').item.json.aml.flags, require_sar: $('AML Risk Engine').item.json.aml.require_sar, amount_gbp: $('AML Risk Engine').item.json.aml.amount_gbp, timestamp: $('AML Risk Engine').item.json.timestamp }) }}",
        "options": {
          "responseCode": "={{ $('AML Risk Engine').item.json.aml.action === 'BLOCK' ? 403 : 200 }}"
        }
      },
      "id": "respond-aml",
      "name": "Respond AML",
      "type": "n8n-nodes-base.respondToWebhook",
      "typeVersion": 1.1,
      "position": [1440, 300]
    }
  ],
  "connections": {
    "Webhook AML":     {"main": [[{"node": "AML Risk Engine",    "type": "main", "index": 0}]]},
    "AML Risk Engine": {"main": [[{"node": "Log Transaction",    "type": "main", "index": 0}],
                                  [{"node": "Requires SAR?",     "type": "main", "index": 0}]]},
    "Log Transaction": {"main": [[{"node": "Requires SAR?",      "type": "main", "index": 0}]]},
    "Requires SAR?":   {"main": [
      [{"node": "Create AML Alert", "type": "main", "index": 0}],
      [{"node": "Respond AML",      "type": "main", "index": 0}]
    ]},
    "Create AML Alert": {"main": [[{"node": "Respond AML",       "type": "main", "index": 0}]]}
  },
  "active": true,
  "settings": {"executionOrder": "v1"},
  "tags": [{"name": "AML"}, {"name": "Compliance"}, {"name": "Banxe"}]
}
WORKFLOW_EOF

echo "  ✓ aml-monitor.json создан"

###############################################################################
# 4. Проверяем и создаём ClickHouse таблицы (полная схема)
###############################################################################
echo ""
echo "[ CLICKHOUSE: таблицы KYC/AML ]"

clickhouse-client --query "
CREATE TABLE IF NOT EXISTS banxe.kyc_events (
    id             UUID DEFAULT generateUUIDv4(),
    customer_id    String,
    event_type     String,
    risk_level     String,
    risk_score     UInt32 DEFAULT 0,
    kyc_tier       String DEFAULT 'SDD',
    decision       String,
    country        String DEFAULT '',
    is_pep         UInt8 DEFAULT 0,
    reviewer       String DEFAULT 'automated',
    notes          String DEFAULT '',
    created_at     DateTime DEFAULT now()
) ENGINE = MergeTree() ORDER BY (created_at, customer_id)
" && echo "  ✓ banxe.kyc_events (уже была или создана)"

clickhouse-client --query "
CREATE TABLE IF NOT EXISTS banxe.aml_alerts (
    id             UUID DEFAULT generateUUIDv4(),
    alert_id       String,
    transaction_id String,
    customer_id    String,
    alert_type     String,
    risk_score     UInt32 DEFAULT 0,
    status         String DEFAULT 'PENDING_REVIEW',
    assigned_to    String DEFAULT 'compliance@banxe.com',
    resolved_at    Nullable(DateTime),
    notes          String DEFAULT '',
    created_at     DateTime DEFAULT now()
) ENGINE = MergeTree() ORDER BY (created_at, status)
" && echo "  ✓ banxe.aml_alerts (уже была или создана)"

clickhouse-client --query "
CREATE TABLE IF NOT EXISTS banxe.transactions (
    id             UUID DEFAULT generateUUIDv4(),
    transaction_id String,
    sender_id      String,
    receiver_id    String,
    amount         Decimal(18,4),
    currency       String DEFAULT 'GBP',
    transaction_type String DEFAULT 'transfer',
    status         String DEFAULT 'pending',
    risk_score     UInt32 DEFAULT 0,
    aml_flag       UInt8 DEFAULT 0,
    created_at     DateTime DEFAULT now()
) ENGINE = MergeTree() ORDER BY (created_at, sender_id)
" && echo "  ✓ banxe.transactions (уже была или создана)"

###############################################################################
# 5. Импорт workflows в n8n
###############################################################################
echo ""
echo "[ IMPORT: загружаем workflows в n8n ]"

# Останавливаем n8n на время импорта (иначе DB locked)
systemctl stop n8n
sleep 2

N8N_RESULTS=""
for WF_FILE in "$WORKFLOW_DIR"/*.json; do
    WF_NAME=$(python3 -c "import json; d=json.load(open('$WF_FILE')); print(d['name'])" 2>/dev/null)
    echo "  Импортирую: $WF_NAME..."
    N8N_USER_FOLDER=/data/n8n n8n import:workflow --input="$WF_FILE" 2>&1 | tail -3
done

# Запускаем n8n обратно
systemctl start n8n
echo "  Ожидаю запуска n8n..."
for i in $(seq 1 15); do
    sleep 2
    STATUS=$(curl -s -m 3 http://localhost:5678/healthz 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
    if [ "$STATUS" = "ok" ]; then
        echo "  ✓ n8n запущен (${i}x2 сек)"
        break
    fi
done

###############################################################################
# 6. Активируем workflows через API
###############################################################################
echo ""
echo "[ АКТИВАЦИЯ: включаем workflows ]"

sleep 2

# Получаем список workflows
WF_LIST=$(curl -s -m 10 -H "X-N8N-API-KEY: $N8N_API_KEY" \
    http://localhost:5678/api/v1/workflows 2>/dev/null)

# Активируем каждый
echo "$WF_LIST" | python3 - << 'PYEOF'
import sys, json, urllib.request, os

data = json.loads(sys.stdin.read())
api_key = os.environ.get('N8N_API_KEY', '')

for wf in data.get('data', []):
    wf_id   = wf['id']
    wf_name = wf['name']
    active  = wf.get('active', False)

    if not active and 'Banxe' in wf_name:
        req = urllib.request.Request(
            f'http://localhost:5678/api/v1/workflows/{wf_id}/activate',
            method='POST',
            headers={'X-N8N-API-KEY': api_key, 'Content-Type': 'application/json'}
        )
        try:
            resp = urllib.request.urlopen(req, timeout=10)
            print(f'  ✓ Активирован: {wf_name}')
        except Exception as e:
            print(f'  ~ {wf_name}: {e}')
    else:
        print(f'  ~ {wf_name}: уже {"active" if active else "inactive (пропуск)"}')
PYEOF
export N8N_API_KEY="$N8N_API_KEY"

###############################################################################
# 7. Тестирование endpoints
###############################################################################
echo ""
echo "[ ТЕСТ: отправляем тестовые запросы ]"

sleep 3
BASE_URL="http://localhost:5678/webhook"

echo ""
echo "  --- KYC тест: стандартный клиент (UK) ---"
KYC_RESP=$(curl -s -m 30 -X POST "$BASE_URL/kyc-onboard" \
    -H "Content-Type: application/json" \
    -d '{"customer_id":"TEST-001","name":"John Smith","email":"john@example.com","country":"GB","doc_type":"passport","source_of_funds":"employment","business_type":"individual"}' 2>/dev/null)
echo "  $KYC_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  decision={d.get(\"decision\",\"?\")} risk={d.get(\"risk_level\",\"?\")} tier={d.get(\"kyc_tier\",\"?\")} score={d.get(\"risk_score\",\"?\")}' )" 2>/dev/null || echo "  $KYC_RESP"

echo ""
echo "  --- KYC тест: высокорисковый клиент (PEP, crypto) ---"
KYC_HIGH=$(curl -s -m 30 -X POST "$BASE_URL/kyc-onboard" \
    -H "Content-Type: application/json" \
    -d '{"customer_id":"TEST-002","name":"Vladimir Minister Petrov","email":"vp@offshore.io","country":"NG","source_of_funds":"crypto","business_type":"money_service"}' 2>/dev/null)
echo "$KYC_HIGH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  decision={d.get(\"decision\",\"?\")} risk={d.get(\"risk_level\",\"?\")} tier={d.get(\"kyc_tier\",\"?\")} score={d.get(\"risk_score\",\"?\")} pep={d.get(\"is_pep\",\"?\")}' )" 2>/dev/null || echo "  $KYC_HIGH"

echo ""
echo "  --- KYC тест: санкционная страна (IR) ---"
KYC_SANC=$(curl -s -m 30 -X POST "$BASE_URL/kyc-onboard" \
    -H "Content-Type: application/json" \
    -d '{"customer_id":"TEST-003","name":"Ali Khamenei","country":"IR","source_of_funds":"unknown"}' 2>/dev/null)
echo "$KYC_SANC" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  decision={d.get(\"decision\",\"?\")} risk={d.get(\"risk_level\",\"?\")}' )" 2>/dev/null || echo "  $KYC_SANC"

echo ""
echo "  --- AML тест: обычный перевод ---"
AML_OK=$(curl -s -m 30 -X POST "$BASE_URL/aml-check" \
    -H "Content-Type: application/json" \
    -d '{"transaction_id":"TXN-TEST-001","amount":500,"currency":"GBP","sender_id":"CUST-001","receiver_id":"CUST-002","sender_country":"GB","receiver_country":"GB","transaction_type":"transfer"}' 2>/dev/null)
echo "$AML_OK" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  action={d.get(\"action\",\"?\")} risk={d.get(\"risk_level\",\"?\")} score={d.get(\"risk_score\",\"?\")} flags={d.get(\"flags\",[])}' )" 2>/dev/null || echo "  $AML_OK"

echo ""
echo "  --- AML тест: структурирование + высокий риск ---"
AML_HIGH=$(curl -s -m 30 -X POST "$BASE_URL/aml-check" \
    -H "Content-Type: application/json" \
    -d '{"transaction_id":"TXN-TEST-002","amount":9500,"currency":"GBP","sender_id":"CUST-003","receiver_id":"CUST-004","sender_country":"GB","receiver_country":"NG","transaction_type":"crypto_withdrawal"}' 2>/dev/null)
echo "$AML_HIGH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  action={d.get(\"action\",\"?\")} risk={d.get(\"risk_level\",\"?\")} score={d.get(\"risk_score\",\"?\")} sar={d.get(\"require_sar\",\"?\")} flags={d.get(\"flags\",[])}' )" 2>/dev/null || echo "  $AML_HIGH"

###############################################################################
# 8. Верификация
###############################################################################
echo ""
echo "[ ВЕРИФИКАЦИЯ ]"

WF_CHECK=$(curl -s -m 10 -H "X-N8N-API-KEY: $N8N_API_KEY" \
    http://localhost:5678/api/v1/workflows 2>/dev/null)

echo "$WF_CHECK" | python3 - << 'PYEOF'
import sys, json
data = json.loads(sys.stdin.read())
wfs = data.get('data', [])
print(f'  ✓ Всего workflows в n8n: {len(wfs)}')
for wf in wfs:
    icon = '✓' if wf.get('active') else '~'
    print(f'  {icon} [{wf["id"]}] {wf["name"]} (active={wf.get("active",False)})')
PYEOF

KYC_COUNT=$(clickhouse-client --query "SELECT count() FROM banxe.kyc_events" 2>/dev/null || echo "?")
AML_COUNT=$(clickhouse-client --query "SELECT count() FROM banxe.aml_alerts" 2>/dev/null || echo "?")
TXN_COUNT=$(clickhouse-client --query "SELECT count() FROM banxe.transactions" 2>/dev/null || echo "?")
echo "  ✓ banxe.kyc_events:  $KYC_COUNT строк"
echo "  ✓ banxe.aml_alerts:  $AML_COUNT строк"
echo "  ✓ banxe.transactions: $TXN_COUNT строк"

echo ""
echo "============================================================"
echo " ✅ n8n KYC/AML Workflows запущены"
echo ""
echo " Endpoints (production):"
echo "   POST http://192.168.0.72:5678/webhook/kyc-onboard"
echo "   POST http://192.168.0.72:5678/webhook/aml-check"
echo ""
echo " n8n UI: http://192.168.0.72:5678"
echo " API ключ сохранён в: /data/n8n/banxe-api.env"
echo ""
echo " ClickHouse мониторинг:"
echo "   clickhouse-client --query 'SELECT * FROM banxe.kyc_events ORDER BY created_at DESC LIMIT 10'"
echo "   clickhouse-client --query 'SELECT * FROM banxe.aml_alerts ORDER BY created_at DESC LIMIT 10'"
echo " Лог: $LOG"
echo "============================================================"
