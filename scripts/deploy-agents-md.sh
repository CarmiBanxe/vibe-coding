#!/bin/bash
# deploy-agents-md.sh — деплоит кастомный AGENTS.md в workspace main-агента (@mycarmi_moa_bot)
#
# Что делает:
#   1. Копирует agents/workspace-moa/AGENTS.md → workspace-moa на GMKtec
#   2. Перезапускает openclaw-gateway-moa для применения изменений
#   3. Проверяет что файл применён
#
# Запуск: cd ~/vibe-coding && git pull && bash scripts/deploy-agents-md.sh

set -euo pipefail
SSH="ssh gmktec"
SRC="/data/vibe-coding/agents/workspace-moa/AGENTS.md"
# ВАЖНО: бот читает из workspace/ (не workspace-moa/)
WORKSPACE="/home/mmber/.openclaw/workspace"
WORKSPACE_MOA="/home/mmber/.openclaw/workspace-moa"

echo "═══════════════════════════════════════════════════════════════"
echo " deploy-agents-md.sh — Banxe CTIO routing rules"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════════"

# Шаг 1: обновить репо на GMKtec
echo ""
echo "── Шаг 1: git pull на GMKtec ──"
$SSH "cd /data/vibe-coding && git pull 2>&1 | tail -2"

# Шаг 2: скопировать AGENTS.md в workspace (бот читает отсюда) + workspace-moa (backup)
echo ""
echo "── Шаг 2: деплой AGENTS.md в workspace (основной) и workspace-moa ──"
$SSH "
cp '$SRC' '$WORKSPACE/AGENTS.md' &&
cp '$SRC' '$WORKSPACE_MOA/AGENTS.md' &&
echo '  OK: скопировано в $WORKSPACE/AGENTS.md (ОСНОВНОЙ)' &&
echo '  OK: скопировано в $WORKSPACE_MOA/AGENTS.md (backup)' &&
echo '  Строк:' \$(wc -l < '$WORKSPACE/AGENTS.md') &&
grep -c 'agentToAgent\|Роутинг\|делегир\|HARD REJECT' '$WORKSPACE/AGENTS.md' | xargs -I{} echo '  Routing+Sanctions строк: {}'
"

# Шаг 3: перезапустить бота для применения
echo ""
echo "── Шаг 3: рестарт openclaw-gateway-moa ──"
$SSH "systemctl restart openclaw-gateway-moa && sleep 5 && systemctl is-active openclaw-gateway-moa && echo '  ✓ moa-bot ACTIVE'"

# Шаг 4: проверить содержимое
echo ""
echo "── Шаг 4: проверка ──"
$SSH "head -5 '$WORKSPACE/AGENTS.md'"

echo ""
echo "══ ГОТОВО ══"
echo ""
echo "Следующий шаг:"
echo "  Напиши @mycarmi_moa_bot: «проверь транзакцию на 50000 GBP из России»"
echo "  Бот должен вызвать субагент 'risk', а не отвечать самостоятельно."
