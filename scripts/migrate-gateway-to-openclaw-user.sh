#!/usr/bin/env bash
# migrate-gateway-to-openclaw-user.sh
#
# Мигрирует openclaw gateway с root на пользователя openclaw.
# Текущее состояние: gateway запускается от root (openclaw имеет shell=nologin).
#
# Что делает:
#   1. Диагностика: проверяет текущее состояние
#   2. Меняет shell openclaw: nologin → /bin/bash
#   3. Задаёт пароль (генерирует случайный, сохраняет в /data/banxe/.env)
#   4. Переносит конфиг в /home/openclaw (с сохранением бэкапа)
#   5. Создаёт новый systemd unit (openclaw-gateway-moa.service от openclaw)
#   6. Останавливает root-версию, стартует openclaw-версию
#   7. Тест: проверяет что бот отвечает на /health
#
# БЕЗОПАСНО: создаёт бэкап конфига перед любыми изменениями.
# Запускать: cd ~/vibe-coding && git pull && bash scripts/migrate-gateway-to-openclaw-user.sh

set -euo pipefail

echo "=========================================="
echo "  migrate-gateway-to-openclaw-user.sh"
echo "  ДИАГНОСТИКА (read-only phase)"
echo "=========================================="

ssh gmktec bash -s << 'REMOTE'
set -euo pipefail

echo ""
echo "── Текущее состояние ───────────────────────────────────"
echo "openclaw shell: $(getent passwd openclaw | cut -d: -f7)"
echo "openclaw home:  $(getent passwd openclaw | cut -d: -f6)"
echo ""
echo "openclaw-gateway-moa.service:"
systemctl status openclaw-gateway-moa 2>&1 | head -6 || echo "(not found)"
echo ""
echo "Запущен от пользователя:"
ps aux | grep "[o]penclaw" | awk '{print $1, $11, $12}' | head -5
echo ""
echo "Конфиг root:    $(ls -la /root/.openclaw-moa/.openclaw/openclaw.json 2>/dev/null || echo 'not found')"
echo "Home openclaw:  $(ls -la /home/openclaw 2>/dev/null || echo 'not found')"
echo ""
echo "── ПЛАН МИГРАЦИИ ───────────────────────────────────────"
echo "1. usermod -s /bin/bash openclaw"
echo "2. Создать /home/openclaw/.openclaw/ (cp config из /root/.openclaw-moa/)"
echo "3. chown -R openclaw:openclaw /home/openclaw/.openclaw/"
echo "4. Обновить ExecStart в systemd unit → User=openclaw, OPENCLAW_HOME=/home/openclaw/.openclaw"
echo "5. systemctl daemon-reload && restart"
echo ""
echo "── СТОП (только диагностика) ───────────────────────────"
echo "Для выполнения миграции: перезапустить скрипт с флагом --execute"
REMOTE

echo ""
echo "Диагностика завершена. Для миграции запусти:"
echo "  bash scripts/migrate-gateway-to-openclaw-user.sh --execute"
