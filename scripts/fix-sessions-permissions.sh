#!/bin/bash
###############################################################################
# fix-sessions-permissions.sh — Починка прав на sessions
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-sessions-permissions.sh
#
# Проблема: gateway от root, но sessions в /root/.openclaw-moa принадлежит
#   пользователю openclaw (после миграции). Root не может создать sessions.
#
# Решение: вернуть права root на /root/.openclaw-moa
###############################################################################

echo "=========================================="
echo "  ПОЧИНКА ПРАВ НА SESSIONS"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'

echo ""
echo "[1/3] Права на /root/.openclaw-moa..."
echo ""

echo "  До починки:"
ls -la /root/.openclaw-moa/.openclaw/agents/main/ 2>/dev/null | sed 's/^/    /'

echo ""

# Возвращаем root владельцем всего в /root/.openclaw-moa
chown -R root:root /root/.openclaw-moa/
echo "  ✓ chown -R root:root /root/.openclaw-moa/"

# Создаём sessions если не существует
mkdir -p /root/.openclaw-moa/.openclaw/agents/main/sessions
echo "  ✓ sessions директория создана/подтверждена"

echo ""
echo "  После починки:"
ls -la /root/.openclaw-moa/.openclaw/agents/main/ 2>/dev/null | sed 's/^/    /'

echo ""
echo "[2/3] Перезапускаю gateway..."

pkill -9 -f "openclaw.*18789" 2>/dev/null
sleep 3

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa \
OLLAMA_API_KEY=ollama-local \
nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  PID: $!"
echo "  Жду 20 секунд..."
sleep 20

echo ""
echo "[3/3] Проверка..."

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway жив (порт 18789)"
    
    echo ""
    echo "  Лог:"
    tail -10 /data/logs/gateway-moa.log | sed 's/^/    /'
else
    echo "  ✗ Не запустился"
    tail -20 /data/logs/gateway-moa.log | sed 's/^/    /'
fi

REMOTE

echo ""
echo "=========================================="
echo "  Напиши боту: Прочитай SOUL.md"
echo "=========================================="
