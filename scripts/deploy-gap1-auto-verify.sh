#!/usr/bin/env bash
# deploy-gap1-auto-verify.sh — деплой GAP 1: auto-verify skill + AGENTS.md + SOUL.md
#
# Что делает:
#   1. git pull на GMKtec
#   2. Копирует auto-verify SKILL.md в workspace бота
#   3. Обновляет AGENTS.md (добавляет обязательное правило auto-verify)
#   4. Обновляет SOUL.md через protect-soul.sh (ШАГ 3 авто-верификация)
#   5. Перезапускает OpenClaw для подгрузки новых SKILL/AGENTS/SOUL
#
# Запускать с Legion:
#   cd ~/vibe-coding && git pull && bash scripts/deploy-gap1-auto-verify.sh

set -euo pipefail

echo "=========================================="
echo "  deploy-gap1-auto-verify.sh"
echo "  Цель: GMKtec ($(date -Iseconds))"
echo "=========================================="

ssh gmktec bash -s << 'REMOTE'
set -euo pipefail

REMOTE_REPO="/data/vibe-coding"
BOT_WORKSPACE="/home/mmber/.openclaw/workspace-moa"
AGENTS_MD="${BOT_WORKSPACE}/AGENTS.md"

echo ""
echo "── [1/5] git pull на GMKtec ────────────────────────────"
cd "${REMOTE_REPO}"
git pull --rebase origin main
echo "OK: $(git log --oneline -1)"

echo ""
echo "── [2/5] Skills → bot workspace ────────────────────────"
# auto-verify
SKILL_SRC="${REMOTE_REPO}/workspace-moa/skills/auto-verify"
SKILL_DST="${BOT_WORKSPACE}/skills/auto-verify"
mkdir -p "${SKILL_DST}"
cp "${SKILL_SRC}/SKILL.md" "${SKILL_DST}/SKILL.md"
echo "OK: auto-verify/SKILL.md → ${SKILL_DST}/SKILL.md"
# verify-statement
VS_SRC="${REMOTE_REPO}/workspace-moa/skills/verify-statement"
VS_DST="${BOT_WORKSPACE}/skills/verify-statement"
if [ -f "${VS_SRC}/SKILL.md" ]; then
    mkdir -p "${VS_DST}"
    cp "${VS_SRC}/SKILL.md" "${VS_DST}/SKILL.md"
    echo "OK: verify-statement/SKILL.md → ${VS_DST}/SKILL.md"
else
    echo "WARN: verify-statement/SKILL.md not found in ${VS_SRC} (skip)"
fi

echo ""
echo "── [3/5] AGENTS.md — добавить правило auto-verify ──────"
AUTO_VERIFY_RULE="## Auto-Verify Rule (MANDATORY 2026-04-05)
Roles: compliance, kyc, aml, risk, crypto
Before sending any compliance/KYC/AML/risk response:
  1. Call skill auto-verify → POST http://127.0.0.1:8094/verify
  2. CONFIRMED → send. REFUTED → rephrase using reason/correction field.
  3. UNCERTAIN + hitl_required=true → create Marble case (skill marble-cases).
  4. Timeout (>3s) → send with disclaimer [Верификация недоступна].
Hard rule: NEVER send a REFUTED response. No exceptions."

if [ ! -f "${AGENTS_MD}" ]; then
    echo "# AGENTS.md — Banxe AI Bank Agent Routing Rules" > "${AGENTS_MD}"
    echo "" >> "${AGENTS_MD}"
    echo "CREATED: $(date -Iseconds)"
    echo "Created AGENTS.md from scratch"
fi

if grep -q "Auto-Verify Rule" "${AGENTS_MD}" 2>/dev/null; then
    echo "OK: Auto-Verify Rule already in AGENTS.md (skip)"
else
    echo "" >> "${AGENTS_MD}"
    printf '%s\n' "${AUTO_VERIFY_RULE}" >> "${AGENTS_MD}"
    echo "OK: Auto-Verify Rule appended to AGENTS.md"
fi

echo "AGENTS.md size: $(wc -c < "${AGENTS_MD}") bytes"

echo ""
echo "── [4/5] SOUL.md — обновить через protect-soul.sh ──────"
bash "${REMOTE_REPO}/scripts/protect-soul.sh" update "${REMOTE_REPO}/docs/SOUL.md"
echo "OK: SOUL.md обновлён и задеплоен в workspaces"

echo ""
echo "── [5/5] Restart OpenClaw ──────────────────────────────"
systemctl restart openclaw-gateway-moa
sleep 3
STATUS=$(systemctl is-active openclaw-gateway-moa 2>/dev/null || echo "unknown")
echo "OpenClaw status: ${STATUS}"

echo ""
echo "── Проверка skills ──────────────────────────────────────"
echo "verify-statement: $(ls -la ${BOT_WORKSPACE}/skills/verify-statement/SKILL.md 2>/dev/null || echo 'NOT FOUND')"
echo "marble-cases:     $(ls -la ${BOT_WORKSPACE}/skills/marble-cases/SKILL.md 2>/dev/null || echo 'NOT FOUND')"
echo "auto-verify:      $(ls -la ${BOT_WORKSPACE}/skills/auto-verify/SKILL.md 2>/dev/null || echo 'NOT FOUND')"

echo ""
echo "=========================================="
echo "  deploy-gap1-auto-verify.sh COMPLETE"
echo "=========================================="
REMOTE

REMOTE_EXIT=$?
if [ $REMOTE_EXIT -eq 0 ]; then
    echo ""
    echo "GAP 1 задеплоен успешно:"
    echo "  - auto-verify SKILL.md → workspace"
    echo "  - AGENTS.md обновлён"
    echo "  - SOUL.md ШАГ 3 активен (chattr +i)"
    echo "  - OpenClaw перезапущен"
fi
