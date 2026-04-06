#!/usr/bin/env bash
# deploy-gap3-promptfoo.sh — деплой GAP 3: promptfoo cron на GMKtec
#
# Что делает:
#   1. git pull vibe-coding на GMKtec
#   2. scp promptfoo.yaml Legion → GMKtec /data/banxe/promptfoo/ (не требует GitHub SSH на GMKtec)
#   3. chmod + YAML validate + Ollama model check
#   4. Устанавливает cron: воскресенье 04:00 UTC (после adversarial sim 02:00)
#
# Запускать с Legion:
#   cd ~/vibe-coding && git pull && bash scripts/deploy-gap3-promptfoo.sh

set -euo pipefail

PROMPTFOO_REMOTE_DIR="/data/banxe/promptfoo"
PROMPTFOO_LOCAL="$HOME/developer/compliance/training/promptfoo.yaml"
EVAL_SCRIPT="/data/vibe-coding/scripts/run-promptfoo-eval.sh"
CRON_FILE="/etc/cron.d/banxe-promptfoo-eval"

echo "=========================================="
echo "  deploy-gap3-promptfoo.sh"
echo "  Цель: GMKtec ($(date -Iseconds))"
echo "=========================================="

# ── [1/4] git pull vibe-coding на GMKtec ─────────────────────────────────────
echo ""
echo "── [1/4] git pull vibe-coding на GMKtec ────────────────"
ssh gmktec "cd /data/vibe-coding && git pull --rebase origin main && echo \"OK: \$(git log --oneline -1)\""

# ── [2/4] scp promptfoo.yaml Legion → GMKtec ─────────────────────────────────
echo ""
echo "── [2/4] scp promptfoo.yaml → gmktec:${PROMPTFOO_REMOTE_DIR} ──"
if [ ! -f "$PROMPTFOO_LOCAL" ]; then
    echo "ERROR: не найден $PROMPTFOO_LOCAL на Legion"
    exit 1
fi
ssh gmktec "mkdir -p ${PROMPTFOO_REMOTE_DIR}/compliance/training/results"
scp "$PROMPTFOO_LOCAL" \
    "gmktec:${PROMPTFOO_REMOTE_DIR}/compliance/training/promptfoo.yaml"
echo "OK: promptfoo.yaml → gmktec:${PROMPTFOO_REMOTE_DIR}/compliance/training/"

# ── [3/4] chmod + validate + model check ─────────────────────────────────────
echo ""
echo "── [3/4] chmod + YAML validate + Ollama check ──────────"
ssh gmktec bash -s << REMOTE
set -euo pipefail

chmod +x "${EVAL_SCRIPT}"

python3 -c "
import yaml
path = '${PROMPTFOO_REMOTE_DIR}/compliance/training/promptfoo.yaml'
d = yaml.safe_load(open(path))
providers = [p['id'] for p in d['providers']]
default = d['defaultTest']['options']['provider']
assert 'qwen3-banxe-v2' in providers[0], f'Wrong provider: {providers}'
assert 'qwen3-banxe-v2' in default, f'Wrong defaultTest: {default}'
print(f'YAML OK: provider={providers[0]}')
"

if ollama list 2>/dev/null | grep -q "qwen3-banxe-v2"; then
    echo "Ollama OK: qwen3-banxe-v2 found"
else
    echo "WARN: qwen3-banxe-v2 not found in ollama list"
fi
REMOTE

# ── [4/4] cron install ────────────────────────────────────────────────────────
echo ""
echo "── [4/4] cron install ──────────────────────────────────"
ssh gmktec bash -s << REMOTE
set -euo pipefail

CRON_ENTRY="0 4 * * 0 root DEVELOPER_DIR=${PROMPTFOO_REMOTE_DIR} bash ${EVAL_SCRIPT} >> /data/logs/promptfoo-eval.log 2>&1"
CRON_FILE="${CRON_FILE}"

if [ -f "\${CRON_FILE}" ]; then
    echo "OK: \${CRON_FILE} already exists:"
    cat "\${CRON_FILE}"
else
    cat > "\${CRON_FILE}" << 'CRONEOF'
# Banxe Promptfoo evaluation — Sunday 04:00 UTC (after adversarial sim 02:00)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CRONEOF
    echo "\${CRON_ENTRY}" >> "\${CRON_FILE}"
    echo "OK: \${CRON_FILE} created"
    cat "\${CRON_FILE}"
fi

echo ""
echo "── Расписание cron.d ────────────────────────────────────"
echo "adversarial sim:  \$(grep -h 'adversarial' /etc/cron.d/* 2>/dev/null | head -1 || echo 'not found')"
echo "promptfoo eval:   \$(grep -h 'promptfoo' /etc/cron.d/* 2>/dev/null | head -1 || echo 'not found')"
echo "deepeval report:  \$(grep -h 'deepeval' /etc/cron.d/* 2>/dev/null | head -1 || echo 'not found')"
REMOTE

echo ""
echo "=========================================="
echo "  deploy-gap3-promptfoo.sh COMPLETE"
echo "  promptfoo.yaml → ${PROMPTFOO_REMOTE_DIR}/compliance/training/"
echo "  cron: Sunday 04:00 UTC"
echo "=========================================="
