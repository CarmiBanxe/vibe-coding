#!/bin/bash
###############################################################################
# migrate-from-root.sh — Миграция OpenClaw с root на пользователя openclaw
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/migrate-from-root.sh
#
# По руководству OpenClaw (стр. 38): запуск от root ЗАПРЕЩЁН
# Пользователь openclaw уже создан (protect-critical-files.sh)
###############################################################################

echo "=========================================="
echo "  МИГРАЦИЯ OpenClaw: root → openclaw"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export OLLAMA_API_KEY="ollama-local"

echo "[1/6] Останавливаю gateway..."
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

echo "[2/6] Проверяю пользователя openclaw..."
if id openclaw &>/dev/null; then
    echo "  ✓ Пользователь openclaw существует"
else
    useradd --system --home-dir /opt/openclaw --shell /bin/bash openclaw
    echo "  ✓ Создан"
fi

echo ""
echo "[3/6] Копирую конфиги и workspace..."

# Создаём структуру
mkdir -p /opt/openclaw/.openclaw/agents/main/agent
mkdir -p /opt/openclaw/.openclaw/canvas
mkdir -p /opt/openclaw/workspace-moa

# Копируем конфиг
cp /root/.openclaw-moa/.openclaw/openclaw.json /opt/openclaw/.openclaw/openclaw.json
echo "  ✓ openclaw.json"

# Копируем auth-profiles
cp /root/.openclaw-moa/.openclaw/agents/main/agent/auth-profiles.json /opt/openclaw/.openclaw/agents/main/agent/ 2>/dev/null
echo "  ✓ auth-profiles.json"

# Копируем models.json
cp /root/.openclaw-moa/.openclaw/agents/main/agent/models.json /opt/openclaw/.openclaw/agents/main/agent/ 2>/dev/null
echo "  ✓ models.json"

# Копируем workspace
cp /root/.openclaw-moa/workspace-moa/MEMORY.md /opt/openclaw/workspace-moa/ 2>/dev/null
cp /root/.openclaw-moa/workspace-moa/SYSTEM-STATE.md /opt/openclaw/workspace-moa/ 2>/dev/null
echo "  ✓ MEMORY.md + SYSTEM-STATE.md"

# Копируем sessions
cp -r /root/.openclaw-moa/.openclaw/agents/main/sessions /opt/openclaw/.openclaw/agents/main/ 2>/dev/null
echo "  ✓ sessions"

# Права
chown -R openclaw:openclaw /opt/openclaw
echo "  ✓ Права установлены"

echo ""
echo "[4/6] Обновляю systemd сервис..."

# Снимаем immutable
chattr -i /etc/systemd/system/openclaw-gateway-moa.service 2>/dev/null

cat > /etc/systemd/system/openclaw-gateway-moa.service << 'SVC'
[Unit]
Description=OpenClaw Gateway — @mycarmi_moa_bot (port 18789)
After=network.target ollama.service

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/opt/openclaw
ExecStart=/usr/bin/npx openclaw gateway --port 18789
Restart=always
RestartSec=10
Environment=HOME=/opt/openclaw
Environment=NODE_ENV=production
Environment=OPENCLAW_HOME=/opt/openclaw
Environment=OLLAMA_API_KEY=ollama-local

# Ограничения ресурсов
MemoryMax=8G
MemoryHigh=6G
CPUQuota=200%
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SVC

chattr +i /etc/systemd/system/openclaw-gateway-moa.service 2>/dev/null
systemctl daemon-reload
echo "  ✓ Systemd сервис обновлён (User=openclaw)"

echo ""
echo "[5/6] Запускаю gateway от openclaw..."

systemctl start openclaw-gateway-moa 2>/dev/null
sleep 15

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ACTIVE от пользователя openclaw"
    ps aux | grep -E "[o]penclaw.*gateway" | awk '{print "    User: "$1", PID: "$2}'
else
    echo "  ✗ systemd не сработал"
    journalctl -u openclaw-gateway-moa --no-pager -n 10 2>/dev/null | tail -5 | sed 's/^/    /'
    
    echo ""
    echo "  Пробую через nohup от openclaw..."
    su -s /bin/bash -c 'cd /opt/openclaw && OPENCLAW_HOME=/opt/openclaw OLLAMA_API_KEY=ollama-local nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &' openclaw
    sleep 15
    ss -tlnp | grep -q ":18789 " && echo "  ✓ Gateway ACTIVE (nohup)" || echo "  ✗ Не запустился"
fi

echo ""
echo "[6/6] Проверка..."

echo "  Модель:"
grep "agent model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

echo "  Telegram:"
grep "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -2 | sed 's/^/    /'

echo "  Ollama:"
curl -s --max-time 10 http://localhost:11434/api/generate -d '{"model":"huihui_ai/glm-4.7-flash-abliterated","prompt":"test","stream":false,"options":{"num_predict":1}}' 2>/dev/null | python3 -c "import sys,json; print('    ✓ OK')" 2>/dev/null || echo "    ✗ НЕ ОТВЕЧАЕТ"

echo "  Процесс gateway:"
ps aux | grep -E "[o]penclaw.*gateway" | awk '{print "    User: "$1", PID: "$2}' | head -1

# Обновляем autosync чтобы копировал в новый workspace тоже
if ! grep -q "/opt/openclaw" /data/vibe-coding/memory-autosync-watcher.sh 2>/dev/null; then
    chattr -i /data/vibe-coding/memory-autosync-watcher.sh 2>/dev/null
    echo '
# Новый workspace для пользователя openclaw
[ -d "/opt/openclaw/workspace-moa" ] && [ -f "$MEMORY_SRC" ] && cp "$MEMORY_SRC" /opt/openclaw/workspace-moa/MEMORY.md
[ -d "/opt/openclaw/workspace-moa" ] && [ -f "$STATE_SRC" ] && cp "$STATE_SRC" /opt/openclaw/workspace-moa/SYSTEM-STATE.md
' >> /data/vibe-coding/memory-autosync-watcher.sh
    chattr +i /data/vibe-coding/memory-autosync-watcher.sh 2>/dev/null
    echo "  ✓ Autosync обновлён для /opt/openclaw"
fi

REMOTE_END
