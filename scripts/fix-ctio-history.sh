#!/bin/bash
# fix-ctio-history.sh — включает мгновенную запись команд Олега (ctio) в bash_history
#
# Проблема: Action Analyzer (cron */2) читает /home/ctio/.bash_history, но файл
#   не существует и history пишется только при logout — команды теряются.
# Решение: PROMPT_COMMAND="history -a" → каждая команда пишется немедленно.
#
# Запуск: cd ~/vibe-coding && git pull && bash scripts/fix-ctio-history.sh

set -euo pipefail
SSH="ssh gmktec"

echo "═══════════════════════════════════════════════════════════════"
echo " fix-ctio-history.sh — instant bash history для ctio"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════════"

# Шаг 1: добавляем PROMPT_COMMAND в .bashrc
echo ""
echo "── Шаг 1: PROMPT_COMMAND в /home/ctio/.bashrc ──"
$SSH "grep -q 'banxe-action-analyzer' /home/ctio/.bashrc 2>/dev/null && echo '  Уже настроено — пропускаем' || {
cat >> /home/ctio/.bashrc << 'BASHRC_EOF'

# banxe-action-analyzer — instant history write for HITL learning
export HISTFILE=/home/ctio/.bash_history
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTTIMEFORMAT=\"%Y-%m-%d %H:%M:%S  \"
export PROMPT_COMMAND=\"history -a\${PROMPT_COMMAND:+; \$PROMPT_COMMAND}\"
BASHRC_EOF
echo '  OK: PROMPT_COMMAND добавлен'
}"

# Шаг 2: создаём .bash_history
echo ""
echo "── Шаг 2: /home/ctio/.bash_history ──"
$SSH "
if [ ! -f /home/ctio/.bash_history ]; then
    touch /home/ctio/.bash_history
    chown ctio:ctio /home/ctio/.bash_history
    chmod 600 /home/ctio/.bash_history
    echo '  OK: создан (ctio:ctio 600)'
else
    chown ctio:ctio /home/ctio/.bash_history
    chmod 600 /home/ctio/.bash_history
    echo '  Уже существует: '\$(wc -l < /home/ctio/.bash_history)' строк, права подтверждены'
fi"

# Шаг 3: активные сессии ctio
echo ""
echo "── Шаг 3: активные сессии ctio ──"
ACTIVE=$($SSH "who | grep -c '^ctio' || true")
echo "  Активных сессий: $ACTIVE"

# Шаг 4: проверка
echo ""
echo "── Шаг 4: итоговая проверка ──"
$SSH "echo '  .bashrc (последние 7 строк):' && tail -7 /home/ctio/.bashrc | sed 's/^/    /' && echo '' && echo '  .bash_history:' && ls -la /home/ctio/.bash_history | sed 's/^/    /'"

# Шаг 5: MEMORY.md
echo ""
echo "── Шаг 5: MEMORY.md ──"
DATE=$(date '+%Y-%m-%d')
MEMORY="docs/MEMORY.md"
if grep -q "PROMPT_COMMAND настроен" "$MEMORY" 2>/dev/null; then
    echo "  Запись уже есть"
else
    sed -i "s/- Тест: systemctl status fail2ban → создан skill verify_fail2ban_status/- Тест: systemctl status fail2ban → создан skill verify_fail2ban_status\n- PROMPT_COMMAND настроен ($DATE): history -a после каждой команды ctio, HISTTIMEFORMAT с timestamp/" "$MEMORY"
    echo "  OK: обновлён"
fi

echo ""
echo "══ ГОТОВО ══"
echo ""
if [ "$ACTIVE" -gt 0 ]; then
    echo "⚠️  Олег сейчас залогинен. Нужно:"
    echo "   Попросить выполнить: source ~/.bashrc"
    echo "   Или переlogиниться на GMKtec."
else
    echo "✓ Активных сессий нет — вступит в силу при следующем логине Олега."
fi
echo ""
echo "Action Analyzer (cron */2 мин) начнёт видеть команды Олега сразу после этого."
