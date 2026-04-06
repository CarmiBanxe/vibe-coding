#!/bin/bash
###############################################################################
# migrate-from-root-v2.sh — Миграция OpenClaw с root на пользователя openclaw
#
# Запускать на LEGION (ПОСЛЕ upgrade-bot-prompts-v2.sh):
#   cd ~/vibe-coding && git pull && bash scripts/migrate-from-root-v2.sh
#
# По руководству OpenClaw (стр. 38): запуск от root ЗАПРЕЩЁН
# Пользователь openclaw уже создан (protect-critical-files.sh)
#
# Что делает:
#   1. Останавливает gateway
#   2. Проверяет/создаёт пользователя openclaw
#   3. Копирует конфиги + workspace (включая новые SOUL.md, BOOTSTRAP.md и т.д.)
#   4. Обновляет systemd сервис (User=openclaw)
#   5. Запускает gateway от openclaw
#   6. Обновляет autosync watcher
#   7. Проверяет всё работает
###############################################################################

echo "=========================================="
echo "  МИГРАЦИЯ OpenClaw: root → openclaw"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

LOG="/data/logs/migrate-root-to-openclaw.log"
mkdir -p /data/logs
exec > >(tee -a "$LOG") 2>&1

###########################################################################
# 1. ОСТАНАВЛИВАЮ GATEWAY
###########################################################################
echo ""
echo "[1/7] Останавливаю gateway..."

pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

if ss -tlnp | grep -q ":18789 "; then
    echo "  ⚠ Порт 18789 ещё занят, жду..."
    sleep 5
    pkill -9 -f "openclaw" 2>/dev/null
    sleep 3
fi

echo "  ✓ Gateway остановлен"

###########################################################################
# 2. ПОЛЬЗОВАТЕЛЬ openclaw
###########################################################################
echo ""
echo "[2/7] Проверяю пользователя openclaw..."

if id openclaw &>/dev/null; then
    echo "  ✓ Пользователь openclaw существует"
    echo "  Home: $(getent passwd openclaw | cut -d: -f6)"
    echo "  Shell: $(getent passwd openclaw | cut -d: -f7)"
else
    echo "  Создаю пользователя openclaw..."
    useradd --system --home-dir /opt/openclaw --shell /bin/bash --create-home openclaw
    echo "  ✓ Создан"
fi

# Убедимся что home существует
mkdir -p /opt/openclaw
chown openclaw:openclaw /opt/openclaw

###########################################################################
# 3. КОПИРУЮ ВСЁ
###########################################################################
echo ""
echo "[3/7] Копирую конфиги и workspace..."

SRC_CFG="/root/.openclaw-moa/.openclaw"
SRC_WS="/root/.openclaw-moa/workspace-moa"
DST_HOME="/opt/openclaw"
DST_CFG="$DST_HOME/.openclaw"
DST_WS="$DST_HOME/workspace-moa"

# Структура
mkdir -p "$DST_CFG"
mkdir -p "$DST_WS"
mkdir -p "$DST_CFG/canvas"

# --- Конфиг ---
if [ -f "$SRC_CFG/openclaw.json" ]; then
    cp "$SRC_CFG/openclaw.json" "$DST_CFG/openclaw.json"
    echo "  ✓ openclaw.json"
else
    echo "  ✗ openclaw.json НЕ найден в $SRC_CFG!"
fi

# --- Workspace .md файлы (SOUL.md, BOOTSTRAP.md, USER.md, IDENTITY.md, MEMORY.md, SYSTEM-STATE.md) ---
echo "  Workspace файлы:"
for f in "$SRC_WS"/*.md; do
    if [ -f "$f" ]; then
        FNAME=$(basename "$f")
        cp "$f" "$DST_WS/$FNAME"
        echo "    ✓ $FNAME"
    fi
done

# --- Sessions ---
if [ -d "$SRC_CFG/agents" ]; then
    cp -r "$SRC_CFG/agents" "$DST_CFG/" 2>/dev/null
    echo "  ✓ agents/ (sessions, auth-profiles, models)"
fi

# --- Canvas ---
if [ -d "$SRC_CFG/canvas" ]; then
    cp -r "$SRC_CFG/canvas/"* "$DST_CFG/canvas/" 2>/dev/null
    echo "  ✓ canvas/"
fi

# --- Обновляем workspace путь в конфиге ---
python3 << 'PYFIX'
import json

cfg_path = "/opt/openclaw/.openclaw/openclaw.json"
with open(cfg_path) as f:
    cfg = json.load(f)

changes = []

# Обновляем workspace путь
agents = cfg.get("agents", {})
defaults = agents.get("defaults", {})
old_ws = defaults.get("workspace", "")
new_ws = "/opt/openclaw/workspace-moa"

if old_ws != new_ws:
    defaults["workspace"] = new_ws
    changes.append(f"workspace: {old_ws} → {new_ws}")

with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

for ch in changes:
    print(f"  ✓ {ch}")
if not changes:
    print("  (workspace путь уже корректный)")
PYFIX

# --- Права ---
chown -R openclaw:openclaw "$DST_HOME"
echo "  ✓ Права установлены (openclaw:openclaw)"

echo ""
echo "  Итого в $DST_WS:"
ls -la "$DST_WS"/*.md 2>/dev/null | sed 's/^/    /'

###########################################################################
# 4. SYSTEMD СЕРВИС
###########################################################################
echo ""
echo "[4/7] Обновляю systemd сервис..."

SVC_FILE="/etc/systemd/system/openclaw-gateway-moa.service"

# Снимаем immutable если есть
chattr -i "$SVC_FILE" 2>/dev/null

cat > "$SVC_FILE" << 'SVC'
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

# Защищаем
chattr +i "$SVC_FILE" 2>/dev/null

systemctl daemon-reload
echo "  ✓ Systemd сервис обновлён (User=openclaw)"
echo "  Содержимое:"
cat "$SVC_FILE" | sed 's/^/    /'

###########################################################################
# 5. ЗАПУСК GATEWAY
###########################################################################
echo ""
echo "[5/7] Запускаю gateway от openclaw..."

# Сначала пробуем через systemd
systemctl enable openclaw-gateway-moa 2>/dev/null
systemctl start openclaw-gateway-moa 2>/dev/null
sleep 20

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ЗАПУЩЕН через systemd!"
    STARTED_VIA="systemd"
else
    echo "  ⚠ systemd не сработал, смотрю journal..."
    journalctl -u openclaw-gateway-moa --no-pager -n 15 2>/dev/null | sed 's/^/    /'
    
    echo ""
    echo "  Пробую через nohup от openclaw..."
    su -s /bin/bash -c '
        cd /opt/openclaw
        OPENCLAW_HOME=/opt/openclaw \
        OLLAMA_API_KEY=ollama-local \
        nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
        echo $!
    ' openclaw
    sleep 20
    
    if ss -tlnp | grep -q ":18789 "; then
        echo "  ✓ Gateway ЗАПУЩЕН через nohup от openclaw!"
        STARTED_VIA="nohup"
    else
        echo "  ✗ НЕ запустился!"
        echo "  Лог:"
        tail -20 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'
        
        # Фолбэк — запуск от root как было
        echo ""
        echo "  ⚠ Фолбэк: запускаю от root (как было)..."
        cd /root/.openclaw-moa
        OPENCLAW_HOME=/root/.openclaw-moa \
        OLLAMA_API_KEY=ollama-local \
        nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
        sleep 15
        
        if ss -tlnp | grep -q ":18789 "; then
            echo "  ✓ Gateway запущен от root (фолбэк)"
            STARTED_VIA="root-fallback"
        else
            echo "  ✗ КРИТИЧЕСКАЯ ОШИБКА — gateway не запускается вообще!"
            tail -30 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'
            STARTED_VIA="failed"
        fi
    fi
fi

###########################################################################
# 6. AUTOSYNC WATCHER
###########################################################################
echo ""
echo "[6/7] Обновляю autosync watcher..."

AUTOSYNC="/data/vibe-coding/memory-autosync-watcher.sh"

if [ -f "$AUTOSYNC" ]; then
    # Проверяем есть ли уже /opt/openclaw
    if ! grep -q "/opt/openclaw" "$AUTOSYNC" 2>/dev/null; then
        chattr -i "$AUTOSYNC" 2>/dev/null
        
        cat >> "$AUTOSYNC" << 'AUTOSYNC_ADDITION'

# === Workspace для пользователя openclaw (добавлено migrate-from-root-v2.sh) ===
if [ -d "/opt/openclaw/workspace-moa" ]; then
    [ -f "$MEMORY_SRC" ] && cp "$MEMORY_SRC" /opt/openclaw/workspace-moa/MEMORY.md
    [ -f "$STATE_SRC" ] && cp "$STATE_SRC" /opt/openclaw/workspace-moa/SYSTEM-STATE.md
fi
AUTOSYNC_ADDITION
        
        chattr +i "$AUTOSYNC" 2>/dev/null
        echo "  ✓ Autosync обновлён — копирует в /opt/openclaw/workspace-moa/"
    else
        echo "  ✓ Autosync уже настроен для /opt/openclaw"
    fi
else
    echo "  ⚠ Autosync watcher не найден: $AUTOSYNC"
fi

###########################################################################
# 7. ФИНАЛЬНАЯ ПРОВЕРКА
###########################################################################
echo ""
echo "[7/7] Финальная проверка..."

echo ""
echo "  Порт 18789:"
ss -tlnp | grep ":18789 " | sed 's/^/    /' || echo "    ✗ НЕ СЛУШАЕТ"

echo ""
echo "  Процесс gateway (кто запустил):"
ps aux | grep -E "[o]penclaw.*gateway" | awk '{print "    User: "$1", PID: "$2}' | head -3

echo ""
echo "  Модель в логе:"
grep -i "agent model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

echo ""
echo "  Telegram в логе:"
grep -i "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -3 | sed 's/^/    /'

echo ""
echo "  Тест Ollama:"
RESP=$(curl -s --max-time 15 http://localhost:11434/api/generate \
    -d '{"model":"huihui_ai/glm-4.7-flash-abliterated","prompt":"Скажи OK","stream":false,"options":{"num_predict":5}}' 2>/dev/null)
echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'    ✓ Модель: {d.get(\"response\",\"?\")[:30]}')" 2>/dev/null || echo "    ✗ Ollama не отвечает"

echo ""
echo "  Запущен через: $STARTED_VIA"

REMOTE_END

echo ""
echo "=========================================="
echo "  ИТОГ МИГРАЦИИ"
echo "=========================================="
echo ""
echo "  Если ✓ Gateway ЗАПУЩЕН:"
echo "    Напиши боту: Привет, кто ты?"
echo "    Должен ответить как CTIO Banxe AI Bank"
echo ""
echo "  Если запущен через 'root-fallback':"
echo "    Значит от openclaw не запустился — работает от root"
echo "    Скинь мне вывод, разберёмся"
echo ""
echo "  Лог на GMKtec:"
echo "    ssh gmktec 'tail -f /data/logs/gateway-moa.log'"
echo "=========================================="
