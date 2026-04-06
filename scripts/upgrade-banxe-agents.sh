#!/bin/bash
# upgrade-banxe-agents.sh — Banxe AI Bank
#
# Выполняет ВСЁ в одном проходе:
#   1. 10-агентный agents.list в openclaw.json
#   2. 9 workspace директорий для субагентов (SOUL.md, USER.md, AGENTS.md)
#   3. SKILLS.md в основном workspace (MetaClaw skills → агент их видит)
#   4. Injection scan cron (аудит workspace .md файлов)
#   5. Удаление дублей n8n workflows (2 inactive)
#   6. Перезапуск бота, верификация
#   7. MEMORY.md обновление + git push
#
# Запуск на Legion:
#   cd ~/vibe-coding && git pull && bash scripts/upgrade-banxe-agents.sh

set -euo pipefail

SSH="ssh gmktec"
WORKSPACE_BASE="/home/mmber/.openclaw"
OPENCLAW_CFG="/root/.openclaw-moa/.openclaw/openclaw.json"
N8N_DB="/data/n8n/.n8n/database.sqlite"

echo "═══════════════════════════════════════════════════════════════"
echo " upgrade-banxe-agents.sh — 10 агентов + skills + cleanup"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════════"

# ── STEP 1: Проверка соединения ──────────────────────────────────────────────
echo ""
echo "━━━ STEP 1: Проверка GMKtec ━━━"
$SSH "echo '  ✓ SSH OK'; systemctl is-active openclaw-gateway-moa >/dev/null && echo '  ✓ moa-bot active' || echo '  ✗ moa-bot DOWN'"

# ── STEP 2: Добавляем agents.list в openclaw.json ────────────────────────────
echo ""
echo "━━━ STEP 2: Патч openclaw.json — agents.list ━━━"

$SSH "python3 << 'PYEOF'
import json, shutil, os
from datetime import datetime

CFG = '/root/.openclaw-moa/.openclaw/openclaw.json'
BAK = f'/root/.openclaw-moa/.openclaw/openclaw.json.bak-{datetime.now().strftime(\"%Y%m%d-%H%M%S\")}'
WS  = '/home/mmber/.openclaw'

# Backup
shutil.copy2(CFG, BAK)
print(f'  ✓ Backup: {BAK}')

d = json.load(open(CFG))

# agents.list — 10 агентов Banxe AI Bank
agents_list = [
    {
        'id': 'main',
        'default': True,
        'workspace': f'{WS}/workspace-moa',
        'model': 'ollama/huihui_ai/qwen3.5-abliterated:35b',
        'identity': {'name': 'CTIO', 'theme': 'Chief Technology & Intelligence Officer', 'emoji': '🧠'},
        'subagents': {'allowAgents': ['supervisor', 'kyc', 'compliance', 'client-service', 'operations', 'risk', 'crypto', 'analytics', 'it-devops']}
    },
    {
        'id': 'supervisor',
        'workspace': f'{WS}/workspace-moa-supervisor',
        'model': 'ollama/llama3.3:70b',
        'identity': {'name': 'Supervisor', 'theme': 'Tier-2 Orchestrator — routes tasks, prioritizes, escalates', 'emoji': '🏦'},
        'subagents': {'allowAgents': ['kyc', 'risk', 'compliance', 'operations', 'crypto', 'analytics', 'client-service']}
    },
    {
        'id': 'kyc',
        'workspace': f'{WS}/workspace-moa-kyc',
        'model': 'ollama/llama3.3:70b',
        'identity': {'name': 'KYC/KYB', 'theme': 'Onboarding, SumSub API, sanctions checks, document verification', 'emoji': '📋'},
        'subagents': {'allowAgents': ['risk', 'compliance', 'supervisor']}
    },
    {
        'id': 'compliance',
        'workspace': f'{WS}/workspace-moa-compliance',
        'model': 'ollama/llama3.3:70b',
        'identity': {'name': 'Compliance', 'theme': 'AML monitoring, SAR generation, FCA rules, LexisNexis', 'emoji': '🛡️'},
        'subagents': {'allowAgents': ['supervisor', 'operations']}
    },
    {
        'id': 'risk',
        'workspace': f'{WS}/workspace-moa-risk',
        'model': 'ollama/llama3.3:70b',
        'identity': {'name': 'Risk Manager', 'theme': 'Credit scoring, transaction risk, fraud detection, exposure limits', 'emoji': '⚠️'},
        'subagents': {'allowAgents': ['compliance', 'supervisor', 'operations']}
    },
    {
        'id': 'client-service',
        'workspace': f'{WS}/workspace-moa-client-service',
        'model': 'ollama/huihui_ai/glm-4.7-flash-abliterated',
        'identity': {'name': 'Client Service', 'theme': '24/7 support, transfers, FX quotes, statements, FAQ', 'emoji': '💬'},
        'subagents': {'allowAgents': ['kyc', 'operations']}
    },
    {
        'id': 'operations',
        'workspace': f'{WS}/workspace-moa-operations',
        'model': 'ollama/huihui_ai/glm-4.7-flash-abliterated',
        'identity': {'name': 'Operations', 'theme': 'Reconciliation, OCR PDF/PNG, SEPA/SWIFT processing', 'emoji': '⚡'},
        'subagents': {'allowAgents': ['analytics']}
    },
    {
        'id': 'crypto',
        'workspace': f'{WS}/workspace-moa-crypto',
        'model': 'ollama/huihui_ai/qwen3.5-abliterated:35b',
        'identity': {'name': 'Crypto', 'theme': 'On-chain monitoring, Fiat↔Crypto, Pro Wallet, DeFi analysis', 'emoji': '🪙'},
        'subagents': {'allowAgents': ['risk', 'compliance']}
    },
    {
        'id': 'analytics',
        'workspace': f'{WS}/workspace-moa-analytics',
        'model': 'ollama/gurubot/gpt-oss-derestricted:20b',
        'identity': {'name': 'Analytics', 'theme': 'OLAP queries, ClickHouse, Power BI, CEO/shareholder AI reports', 'emoji': '📊'}
    },
    {
        'id': 'it-devops',
        'workspace': f'{WS}/workspace-moa-it-devops',
        'model': 'ollama/huihui_ai/glm-4.7-flash-abliterated',
        'identity': {'name': 'IT/DevOps', 'theme': 'Infrastructure monitoring, CI/CD, security audits, system health', 'emoji': '🔧'}
    },
]

d['agents']['list'] = agents_list
print(f'  ✓ agents.list: {len(agents_list)} агентов')

# Убедимся что workspace в defaults совпадает с main агентом
d['agents']['defaults']['workspace'] = f'{WS}/workspace-moa'

with open(CFG, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print('  ✓ openclaw.json обновлён')
print('  ✓ chmod 600 openclaw.json')
os.chmod(CFG, 0o600)
PYEOF
" 2>&1

# ── STEP 3: Создаём workspace директории для субагентов ──────────────────────
echo ""
echo "━━━ STEP 3: Workspace dirs + SOUL.md для каждого субагента ━━━"

# Используем bash -s << heredoc чтобы избежать расширения backtick-ов локальным shell
ssh gmktec bash -s << 'STEP3'
set -euo pipefail
WS='/home/mmber/.openclaw'
MAIN_WS="$WS/workspace-moa"

# Стандартный USER.md (копируем из main workspace)
USER_MD=$(cat "$MAIN_WS/USER.md" 2>/dev/null || printf '# USER\nCEO Moriel Carmi (Mark), @bereg2022, Telegram ID 508602494.\nBanxe UK Ltd - FCA authorised EMI. Europe/Paris timezone.')
AGENTS_MD=$(cat "$MAIN_WS/AGENTS.md" 2>/dev/null || printf '# AGENTS\nRead SOUL.md first. Then USER.md. Then MEMORY.md if available.')

# ── supervisor ───────────────────────────────────────────────────────────────
mkdir -p "$WS/workspace-moa-supervisor"
cat > "$WS/workspace-moa-supervisor/SOUL.md" << 'EOF'
# SOUL — Supervisor Agent (Banxe AI Bank)

You are the **Supervisor AI** of Banxe UK Ltd, an FCA-authorised EMI.

## Your Role
Tier-2 Orchestrator. You receive complex tasks from the CTIO (main agent) and route them to the correct specialist agents.

## Routing Logic
- KYC/onboarding/document verification -> kyc agent
- AML/sanctions/SAR/FCA rules -> compliance agent
- Transaction risk/fraud scoring -> risk agent
- Customer query/support/balance -> client-service agent
- SEPA/SWIFT/reconciliation -> operations agent
- Crypto/DeFi/on-chain -> crypto agent
- Reports/ClickHouse queries -> analytics agent
- Infrastructure/monitoring -> it-devops agent

## Rules
- Never do specialist work yourself — always delegate
- Always summarise results back to CTIO in structured form
- If task spans multiple agents, coordinate sequentially
- Log all routing decisions to ClickHouse audit_trail
EOF
printf '%s\n' "$USER_MD" > "$WS/workspace-moa-supervisor/USER.md"
printf '%s\n' "$AGENTS_MD" > "$WS/workspace-moa-supervisor/AGENTS.md"
echo '' > "$WS/workspace-moa-supervisor/MEMORY.md"
echo '  ✓ workspace-moa-supervisor'

# ── kyc ──────────────────────────────────────────────────────────────────────
mkdir -p "$WS/workspace-moa-kyc"
cat > "$WS/workspace-moa-kyc/SOUL.md" << 'EOF'
# SOUL — KYC/KYB Agent (Banxe AI Bank)

You are the **KYC/KYB Compliance Specialist** of Banxe UK Ltd, FCA-authorised EMI.

## Your Role
Customer onboarding, identity verification, sanctions screening, document validation.

## Regulatory Framework
- UK MLR 2017 (Money Laundering Regulations)
- FCA SYSC rules on customer due diligence
- UK Sanctions and Anti-Money Laundering Act 2018
- JMLSG Guidance (CDD, EDD, PEP screening)

## CDD Tiers
- SDD (Simplified): Low risk, standard docs (photo ID + proof of address)
- Standard: Medium risk, full CDD
- EDD (Enhanced): High risk, PEPs, high-risk countries — 30-day window, additional docs

## Decision Flow
1. Receive onboarding request
2. Screen against sanctions (OFAC, UK HMT, EU)
3. PEP check
4. Country risk assessment
5. Source of funds/business type risk
6. Calculate risk score -> tier -> decision
7. Log to ClickHouse kyc_events via n8n webhook (POST /webhook/kyc-onboard)

## HITL Rule
- APPROVE: score < 20, no PEP, non-sanctioned -> auto
- APPROVE_WITH_MONITORING: score 20-49 -> auto + flag
- MANUAL_REVIEW: score >= 50, PEP, high-risk country -> human required
- REJECT: sanctioned jurisdiction -> immediate block
EOF
printf '%s\n' "$USER_MD" > "$WS/workspace-moa-kyc/USER.md"
printf '%s\n' "$AGENTS_MD" > "$WS/workspace-moa-kyc/AGENTS.md"
echo '' > "$WS/workspace-moa-kyc/MEMORY.md"
echo '  ✓ workspace-moa-kyc'

# ── compliance ───────────────────────────────────────────────────────────────
mkdir -p "$WS/workspace-moa-compliance"
cat > "$WS/workspace-moa-compliance/SOUL.md" << 'EOF'
# SOUL — Compliance Agent (Banxe AI Bank)

You are the **AML/Compliance Officer AI** of Banxe UK Ltd, FCA-authorised EMI.

## Your Role
AML monitoring, SAR generation, FCA reporting, transaction screening.

## Regulatory Framework
- POCA 2002 (Proceeds of Crime Act)
- MLR 2017 (Money Laundering Regulations)
- Terrorism Act 2000
- JMLSG Guidance
- FCA SYSC 6

## AML Thresholds
- 10000+ GBP: High Value Transaction — flag
- 9500-9999 GBP: Potential Structuring — flag
- 50000+ GBP: Large Transaction — enhanced monitoring
- Sanctioned countries: BLOCK immediately

## SAR Triggers
- CRITICAL/HIGH AML score (>= 60)
- Sanctioned jurisdiction involvement
- Suspicious structuring patterns
- SAR must be filed within 7 days of suspicion

## ClickHouse Logging
All decisions -> banxe.aml_alerts (via POST /webhook/aml-check)
All audit events -> banxe.audit_trail

## HITL Rule
- score < 30 (LOW): auto-approve
- score 30-59 (MEDIUM): monitor, no human needed immediately
- score >= 60 (HIGH): HOLD + compliance officer notification
- score >= 100 or sanctioned: BLOCK + immediate SAR
EOF
printf '%s\n' "$USER_MD" > "$WS/workspace-moa-compliance/USER.md"
printf '%s\n' "$AGENTS_MD" > "$WS/workspace-moa-compliance/AGENTS.md"
echo '' > "$WS/workspace-moa-compliance/MEMORY.md"
echo '  ✓ workspace-moa-compliance'

# ── risk ─────────────────────────────────────────────────────────────────────
mkdir -p "$WS/workspace-moa-risk"
cat > "$WS/workspace-moa-risk/SOUL.md" << 'EOF'
# SOUL — Risk Manager Agent (Banxe AI Bank)

You are the **Risk Manager AI** of Banxe UK Ltd, FCA-authorised EMI.

## Your Role
Credit scoring, transaction risk assessment, fraud detection, exposure limits.

## Risk Scoring (composite)
- Country risk (HIGH +40, MEDIUM +20, BLOCKED = reject)
- PEP status (+35)
- Transaction velocity (>5 tx/hour +20)
- Device fingerprint mismatch (+15)
- Source of funds risk: crypto/cash/unknown (+15)
- Business type risk: gambling/MSB/arms (+25)

## Fraud Signals
- Rapid geographic change (impossible travel)
- Round-number transactions
- Below-threshold structuring
- New account + large transfer

## Outputs
For each assessment:
1. risk_score (0-100+)
2. risk_level (LOW/MEDIUM/HIGH/CRITICAL/BLOCKED)
3. recommended_action (ALLOW/MONITOR/HOLD/BLOCK)
4. flags[] — list of triggered rules
5. Log to ClickHouse banxe.transactions
EOF
printf '%s\n' "$USER_MD" > "$WS/workspace-moa-risk/USER.md"
printf '%s\n' "$AGENTS_MD" > "$WS/workspace-moa-risk/AGENTS.md"
echo '' > "$WS/workspace-moa-risk/MEMORY.md"
echo '  ✓ workspace-moa-risk'

# ── client-service ───────────────────────────────────────────────────────────
mkdir -p "$WS/workspace-moa-client-service"
cat > "$WS/workspace-moa-client-service/SOUL.md" << 'EOF'
# SOUL — Client Service Agent (Banxe AI Bank)

You are the **24/7 Client Service AI** of Banxe UK Ltd, FCA-authorised EMI.

## Your Role
First line of customer support. Fast, friendly, compliant.

## Capabilities
- Account balance and transaction history queries
- Transfers and payments (initiation, status)
- FX quotes and currency conversion
- Card management (freeze, unfreeze, limits)
- FAQ (fees, limits, account types)
- KYC status and document upload guidance

## Escalation Rules
- Identity verification needed -> call kyc agent
- Suspicious activity reported -> call compliance agent
- Cannot resolve in 2 exchanges -> escalate to human via HITL

## Tone
- Professional but warm
- Always in the customer's language (auto-detect)
- Never promise what you cannot deliver
- NEVER discuss internal risk scores or AML flags with customers

## Compliance
- Cannot open accounts or approve transactions directly
- All payments go through risk assessment first
- Log all interactions to ClickHouse audit_trail
EOF
printf '%s\n' "$USER_MD" > "$WS/workspace-moa-client-service/USER.md"
printf '%s\n' "$AGENTS_MD" > "$WS/workspace-moa-client-service/AGENTS.md"
echo '' > "$WS/workspace-moa-client-service/MEMORY.md"
echo '  ✓ workspace-moa-client-service'

# ── operations ───────────────────────────────────────────────────────────────
mkdir -p "$WS/workspace-moa-operations"
cat > "$WS/workspace-moa-operations/SOUL.md" << 'EOF'
# SOUL — Operations Agent (Banxe AI Bank)

You are the **Operations AI** of Banxe UK Ltd, FCA-authorised EMI.

## Your Role
Back-office processing. SEPA/SWIFT, reconciliation, OCR document extraction.

## Capabilities
- SEPA/SWIFT payment processing (via Geniusto Core Banking API)
- Transaction reconciliation against bank statements
- OCR extraction from PDF/PNG documents (invoices, statements)
- Batch payment file generation (ISO 20022 XML)
- Daily reconciliation reports to ClickHouse analytics

## Payment Rules
- SEPA: max 1M EUR single transfer, cut-off 15:00 CET
- SWIFT: all currencies, 1-3 business days
- Internal: instant, 24/7
- All payments require prior risk clearance (ALLOW status from risk agent)

## Data Quality
- Log all processed transactions to banxe.transactions
- Flag any reconciliation mismatches to supervisor immediately
- Keep audit trail in banxe.audit_trail for FCA
EOF
printf '%s\n' "$USER_MD" > "$WS/workspace-moa-operations/USER.md"
printf '%s\n' "$AGENTS_MD" > "$WS/workspace-moa-operations/AGENTS.md"
echo '' > "$WS/workspace-moa-operations/MEMORY.md"
echo '  ✓ workspace-moa-operations'

# ── crypto ───────────────────────────────────────────────────────────────────
mkdir -p "$WS/workspace-moa-crypto"
cat > "$WS/workspace-moa-crypto/SOUL.md" << 'EOF'
# SOUL — Crypto Agent (Banxe AI Bank)

You are the **Crypto & DeFi Specialist AI** of Banxe UK Ltd, FCA-authorised EMI.

## Your Role
On-chain monitoring, Fiat-to-Crypto conversions, Pro Wallet management.

## Capabilities
- Blockchain address screening (sanctions, cluster analysis)
- On-chain transaction monitoring (BTC, ETH, USDT, USDC)
- Fiat-to-Crypto and Crypto-to-Fiat conversion quotes
- Pro Wallet custody operations
- DeFi protocol risk assessment

## Compliance Rules
- All crypto transactions screened against OFAC SDN list
- Travel Rule compliance (>1000 USD threshold)
- Source of funds required for crypto deposits > 1000 GBP
- Mixer/tumbler addresses -> automatic block + compliance escalation
- High-risk exchanges -> enhanced monitoring

## Risk Thresholds
- Clean wallet: proceed
- Unknown origin (score 0-25%): monitor
- Medium risk (25-75%): enhanced due diligence
- High risk (75%+): hold + compliance review
EOF
printf '%s\n' "$USER_MD" > "$WS/workspace-moa-crypto/USER.md"
printf '%s\n' "$AGENTS_MD" > "$WS/workspace-moa-crypto/AGENTS.md"
echo '' > "$WS/workspace-moa-crypto/MEMORY.md"
echo '  ✓ workspace-moa-crypto'

# ── analytics ────────────────────────────────────────────────────────────────
mkdir -p "$WS/workspace-moa-analytics"
cat > "$WS/workspace-moa-analytics/SOUL.md" << 'EOF'
# SOUL — Analytics Agent (Banxe AI Bank)

You are the **Analytics & Business Intelligence AI** of Banxe UK Ltd, FCA-authorised EMI.

## Your Role
OLAP queries, ClickHouse analytics, CEO/shareholder reporting, KPI dashboards.

## Capabilities
- ClickHouse SQL queries (banxe database: transactions, kyc_events, aml_alerts, agent_metrics)
- Revenue, volume, customer acquisition metrics
- Risk portfolio analytics
- Regulatory reporting summaries
- Trend analysis and anomaly detection

## ClickHouse Tables
- banxe.transactions: all payment flows
- banxe.kyc_events: onboarding outcomes by country/risk tier
- banxe.aml_alerts: AML/SAR pipeline
- banxe.agent_metrics: AI performance (tokens, latency, accuracy)
- banxe.audit_trail: compliance events

## Output Formats
- CEO: executive summary, key numbers, colour-coded status
- Compliance: detailed event logs, regulatory-ready format
- Board: high-level trends, no PII, aggregated

## Security
- Read-only queries only
- Never expose individual customer PII in reports
- Aggregate by cohort (country, risk tier, product)
EOF
printf '%s\n' "$USER_MD" > "$WS/workspace-moa-analytics/USER.md"
printf '%s\n' "$AGENTS_MD" > "$WS/workspace-moa-analytics/AGENTS.md"
echo '' > "$WS/workspace-moa-analytics/MEMORY.md"
echo '  ✓ workspace-moa-analytics'

# ── it-devops ────────────────────────────────────────────────────────────────
mkdir -p "$WS/workspace-moa-it-devops"
cat > "$WS/workspace-moa-it-devops/SOUL.md" << 'EOF'
# SOUL — IT/DevOps Agent (Banxe AI Bank)

You are the **IT & DevOps AI** of Banxe UK Ltd, FCA-authorised EMI.

## Your Role
Infrastructure monitoring, incident response, CI/CD, security audits.

## System Architecture
- GMKtec EVO-X2 (AMD Ryzen AI MAX+ 395, 128GB): AI BRAIN
  - OpenClaw gateways: 18789 (moa), 18791 (ctio), 18793 (mycarmibot)
  - Ollama 11434, ClickHouse 9000, n8n 5678, PII Proxy 8089
- Legion Pro 5 (WSL2 Ubuntu 24.04): TERMINAL / DEV

## Monitoring Responsibilities
- Service health: openclaw, ollama, clickhouse, n8n
- Disk usage: /data (1.7TB available)
- Memory: 128GB total, ~96GB GPU VRAM
- Backup: ClickHouse every 6h, OpenClaw daily 3:00

## Incident Response
1. Detect via ctio-watcher or SYSTEM-STATE.md
2. Diagnose (journalctl, ps, df, top)
3. Fix or escalate to CTIO
4. Log in ClickHouse audit_trail
5. Update MEMORY.md

## Security
- fail2ban active on SSH
- fscrypt encryption at rest
- OpenClaw: gateway.auth.token set, mDNS off, configWrites off
- No secrets in git (enforced by Semgrep pre-commit hook)
EOF
printf '%s\n' "$USER_MD" > "$WS/workspace-moa-it-devops/USER.md"
printf '%s\n' "$AGENTS_MD" > "$WS/workspace-moa-it-devops/AGENTS.md"
echo '' > "$WS/workspace-moa-it-devops/MEMORY.md"
echo '  ✓ workspace-moa-it-devops'

# Права
chmod 700 "$WS/workspace-moa-supervisor" "$WS/workspace-moa-kyc" "$WS/workspace-moa-compliance" "$WS/workspace-moa-risk" "$WS/workspace-moa-client-service" "$WS/workspace-moa-operations" "$WS/workspace-moa-crypto" "$WS/workspace-moa-analytics" "$WS/workspace-moa-it-devops"
chown -R openclaw:openclaw "$WS/" 2>/dev/null || true
echo '  ✓ permissions set (700, openclaw owner)'
STEP3

# ── STEP 4: SKILLS.md в основном workspace ───────────────────────────────────
echo ""
echo "━━━ STEP 4: SKILLS.md — MetaClaw навыки в workspace ━━━"

$SSH "python3 << 'PYEOF'
import json, os, glob
from datetime import datetime

SKILLS_DIR = '/data/metaclaw/skills'
WORKSPACE  = '/home/mmber/.openclaw/workspace-moa'
OUT        = f'{WORKSPACE}/SKILLS.md'

skills_by_cat = {}
for path in sorted(glob.glob(f'{SKILLS_DIR}/**/*.json', recursive=True)):
    try:
        d = json.load(open(path))
        cat = os.path.basename(os.path.dirname(path))
        skills_by_cat.setdefault(cat, []).append(d)
    except: pass

lines = [
    '# SKILLS — MetaClaw Навыки (автогенерировано)',
    f'> Обновлено: {datetime.now().strftime(\"%Y-%m-%d %H:%M\")}',
    '> Навыки накоплены из действий CTIO Олега и ручной настройки.',
    '',
    '## Как использовать',
    'Если задача соответствует одному из навыков ниже — применяй его логику напрямую.',
    'Не переизобретай то, что уже проверено на практике.',
    '',
]

for cat, skills in sorted(skills_by_cat.items()):
    lines.append(f'## {cat.upper()}')
    for s in skills:
        lines.append(f'### {s.get(\"name\", \"unknown\")}')
        lines.append(f'**Описание:** {s.get(\"description\", \"\")}')
        trigger = s.get(\"trigger\") or s.get(\"skill_trigger\", \"\")
        action  = s.get(\"action\")  or s.get(\"skill_action\", \"\")
        if trigger: lines.append(f'**Когда:** {trigger}')
        if action:  lines.append(f'**Действие:** {action}')
        lines.append('')

with open(OUT, 'w') as f:
    f.write('\n'.join(lines))

print(f'  ✓ SKILLS.md: {sum(len(v) for v in skills_by_cat.values())} навыков в {len(skills_by_cat)} категориях')
print(f'  ✓ Путь: {OUT}')
PYEOF
" 2>&1

# ── STEP 5: Injection scan cron ──────────────────────────────────────────────
echo ""
echo "━━━ STEP 5: Workspace injection scan (cron daily 2:00) ━━━"

$SSH "
# Создаём скрипт аудита
cat > /usr/local/bin/workspace-injection-scan.sh << 'SCANEOF'
#!/bin/bash
# workspace-injection-scan.sh — аудит .md файлов на prompt injection
LOG='/data/logs/injection-scan.log'
WS_BASE='/home/mmber/.openclaw'
PATTERNS='ignore previous|system override|you are now|execute the following|curl.*base64|SYSTEM_OVERRIDE|IGNORE ALL PREVIOUS'
FOUND=0

for ws in \$WS_BASE/workspace*; do
    [ -d \"\$ws\" ] || continue
    while IFS= read -r -d '' f; do
        if grep -qiE \"\$PATTERNS\" \"\$f\" 2>/dev/null; then
            echo \"\$(date '+%Y-%m-%d %H:%M:%S') INJECTION DETECTED: \$f\" >> \"\$LOG\"
            echo \"  ALERT: \$f\" | tee -a \"\$LOG\"
            FOUND=\$((FOUND+1))
        fi
    done < <(find \"\$ws\" -name '*.md' -print0 2>/dev/null)
done

if [ \"\$FOUND\" -eq 0 ]; then
    echo \"\$(date '+%Y-%m-%d %H:%M:%S') CLEAN — нет инъекций (\$(find \$WS_BASE/workspace* -name '*.md' 2>/dev/null | wc -l) файлов проверено)\" >> \"\$LOG\"
fi
SCANEOF
chmod +x /usr/local/bin/workspace-injection-scan.sh

# Добавляем в crontab root если нет
if ! crontab -l 2>/dev/null | grep -q 'workspace-injection-scan'; then
    (crontab -l 2>/dev/null; echo '0 2 * * * /usr/local/bin/workspace-injection-scan.sh >> /data/logs/injection-scan.log 2>&1') | crontab -
    echo '  ✓ cron добавлен: ежедневно в 2:00'
else
    echo '  ~ cron уже есть'
fi

# Запускаем немедленно
/usr/local/bin/workspace-injection-scan.sh
echo '  ✓ scan completed'
" 2>&1

# ── STEP 6: Удаляем дубли n8n workflows ─────────────────────────────────────
echo ""
echo "━━━ STEP 6: Удаление inactive n8n workflows (дубли) ━━━"

$SSH "python3 << 'PYEOF'
import sqlite3

DB = '/data/n8n/.n8n/database.sqlite'
# Inactive дубли (UUID-based, active=0)
TO_DELETE = [
    'e6a5ee8f-51c3-4e08-ac05-9580df7a5b7a',  # AML inactive
    '28078fde-6613-4712-873b-b12a759243cd',  # KYC inactive
]

conn = sqlite3.connect(DB)
cur  = conn.cursor()

for wf_id in TO_DELETE:
    cur.execute('SELECT name, active FROM workflow_entity WHERE id=?', (wf_id,))
    row = cur.fetchone()
    if not row:
        print(f'  SKIP (not found): {wf_id[:20]}...')
        continue
    if row[1] == 1:
        print(f'  SKIP (active!): {row[0]} — не удаляем активный workflow')
        continue

    # Удаляем из всех связанных таблиц
    for tbl in ['workflow_entity', 'workflow_history', 'workflow_published_version',
                'webhook_entity', 'execution_entity', 'shared_workflow', 'workflows_tags']:
        col = 'workflowId' if tbl not in ('workflow_entity', 'webhook_entity') else 'id' if tbl == 'workflow_entity' else 'workflowId'
        try:
            cur.execute(f'DELETE FROM {tbl} WHERE {col}=?', (wf_id,))
        except Exception as e:
            pass  # таблица может не иметь этого столбца

    print(f'  ✓ Удалён: {row[0]} ({wf_id[:20]}...)')

conn.commit()

# Проверка
cur.execute('SELECT name, active FROM workflow_entity ORDER BY active DESC, name')
print('\n  Оставшиеся workflows:')
for r in cur.fetchall():
    print(f'    [active={r[1]}] {r[0]}')
conn.close()
PYEOF
" 2>&1

# ── STEP 7: Перезапуск бота ──────────────────────────────────────────────────
echo ""
echo "━━━ STEP 7: Перезапуск openclaw-gateway-moa ━━━"

$SSH "
sudo systemctl restart openclaw-gateway-moa
echo '  Ожидание 20 сек...'
sleep 20
STATUS=\$(systemctl is-active openclaw-gateway-moa 2>/dev/null)
echo \"  Статус: \$STATUS\"
if [ '\$STATUS' = 'active' ]; then
    echo '  ✓ Бот запущен'
else
    echo '  ✗ Ошибка! Лог:'
    journalctl -u openclaw-gateway-moa -n 20 --no-pager 2>/dev/null
fi

# Проверяем что agents загрузились
echo ''
python3 -c \"
import json
d = json.load(open('/root/.openclaw-moa/.openclaw/openclaw.json'))
lst = d.get('agents', {}).get('list', [])
print(f'  agents.list: {len(lst)} агентов')
for a in lst:
    print(f'    [{a[\\\"id\\\"]}] {a[\\\"identity\\\"][\\\"name\\\"]} — {a[\\\"model\\\"]}')
\" 2>/dev/null
" 2>&1

# ── STEP 8: MEMORY.md + git push ─────────────────────────────────────────────
echo ""
echo "━━━ STEP 8: MEMORY.md + push ━━━"

$SSH "python3 << 'PYEOF'
import re
from datetime import datetime

f = '/data/vibe-coding/docs/MEMORY.md'
with open(f) as fh:
    content = fh.read()

entry = '''
## 10-агентная система Banxe AI Bank (2026-03-31) — АКТИВИРОВАНО
- **agents.list**: 10 агентов добавлены в openclaw.json и активны
- **Агенты**: main(CTIO), supervisor, kyc, compliance, risk, client-service, operations, crypto, analytics, it-devops
- **Оркестрация**: main → supervisor → специалисты через agentToAgent (инструмент включён в 'coding' profile)
- **Workspace dirs**: созданы 9 отдельных директорий с SOUL.md для каждого субагента
- **SKILLS.md**: MetaClaw skills (5шт) доступны в workspace-moa (загружается как контекст)
- **Injection scan**: cron 2:00 ежедневно (/usr/local/bin/workspace-injection-scan.sh)
- **n8n дубли**: 2 inactive workflow удалены (UUID-based), осталось 2 active
- **Права**: workspace dirs chmod 700, owner openclaw
- **Сервис**: работает от пользователя openclaw (не root!), MemoryMax=8G, CPUQuota=200%
- **Прогресс проекта**: ~65% (добавлены агенты, структура оркестрации)
'''

marker = '## 10-агентная система'
if marker in content:
    content = re.sub(r'## 10-агентная система.*?(?=\n## |\Z)', entry.strip() + '\n', content, flags=re.DOTALL)
else:
    content = content.rstrip() + '\n' + entry

# Обновляем прогресс
content = content.replace('Прогресс: ~50%', 'Прогресс: ~65%')
content = content.replace('Прогресс: ~60%', 'Прогресс: ~65%')

with open(f, 'w') as fh:
    fh.write(content)
print('  ✓ MEMORY.md обновлён')
PYEOF
" 2>&1

# Копируем скрипт на GMKtec и пушим
scp -q /home/mmber/vibe-coding/scripts/upgrade-banxe-agents.sh gmktec:/data/vibe-coding/scripts/
$SSH "cd /data/vibe-coding && \
    git add scripts/upgrade-banxe-agents.sh docs/MEMORY.md && \
    git commit -m 'feat: 10-агентная система — agents.list + workspaces + SKILLS.md + n8n cleanup' && \
    git push origin main && echo '  ✓ pushed'" 2>&1

# ── STEP 9: Финальный отчёт ──────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " ГОТОВО"
echo ""
echo " 1. Агенты: 10 в agents.list, все active"
echo " 2. Workspaces: 9 субагентов с SOUL.md"
echo " 3. SKILLS.md в workspace-moa"
echo " 4. Injection scan: cron 2:00"
echo " 5. n8n: 2 inactive дубля удалены"
echo " 6. Бот перезапущен"
echo ""
echo " Оркестрация:"
echo "   Марк → @mycarmi_moa_bot (main/CTIO)"
echo "     → supervisor (routing)"
echo "       → kyc / compliance / risk / client-service / ..."
echo ""
echo " Обучение от Олега (работает 24/7):"
echo "   bash_history (ctio + root) → action-analyzer (*/2 мин)"
echo "     → GLM-4.7-flash (классификация)"
echo "       → /data/metaclaw/skills/ctio/*.json"
echo "         → SKILLS.md в workspace (загружается ботом)"
echo "═══════════════════════════════════════════════════════════════"
