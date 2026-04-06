#!/bin/bash
###############################################################################
# fix-permissions-openclaw.sh — Починка прав после миграции
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-permissions-openclaw.sh
#
# Проблема:
#   Gateway от openclaw пытается писать в /root/.openclaw-moa/ (нет прав)
#   Ошибка: EACCES: permission denied, mkdir '/root/.openclaw-moa/.openclaw/agents/main/sessions'
#
# Причина:
#   OPENCLAW_HOME=/opt/openclaw, но внутри конфига или кода остались
#   ссылки на /root/.openclaw-moa или /home/mmber/.openclaw
#
# Решение:
#   1. Проверяем куда реально смотрит конфиг
#   2. Копируем sessions в /opt/openclaw
#   3. Исправляем пути в конфиге
#   4. Перезапускаем gateway
###############################################################################

echo "=========================================="
echo "  ПОЧИНКА ПРАВ: EACCES permission denied"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

echo ""
echo "[1/6] Диагностика — куда смотрит конфиг..."

CFG="/opt/openclaw/.openclaw/openclaw.json"

if [ -f "$CFG" ]; then
    echo "  Конфиг: $CFG (существует)"
    
    # Ищем все пути в конфиге
    echo ""
    echo "  Пути в конфиге:"
    grep -oE '"[^"]*(/root/|/home/mmber/)[^"]*"' "$CFG" | sort -u | sed 's/^/    /'
    
    echo ""
    echo "  Workspace:"
    python3 -c "
import json
with open('$CFG') as f:
    c = json.load(f)
ws = c.get('agents',{}).get('defaults',{}).get('workspace','(не задан)')
print(f'    {ws}')
" 2>/dev/null
else
    echo "  ✗ Конфиг НЕ найден: $CFG"
fi

echo ""
echo "[2/6] Проверяю структуру /opt/openclaw..."
echo ""
echo "  /opt/openclaw/.openclaw/:"
ls -la /opt/openclaw/.openclaw/ 2>/dev/null | sed 's/^/    /'
echo ""
echo "  /opt/openclaw/.openclaw/agents/:"
ls -laR /opt/openclaw/.openclaw/agents/ 2>/dev/null | head -20 | sed 's/^/    /'
echo ""
echo "  Sessions в /opt/openclaw:"
ls -la /opt/openclaw/.openclaw/agents/main/sessions/ 2>/dev/null | head -5 | sed 's/^/    /' || echo "    (нет или пусто)"

echo ""
echo "[3/6] Копирую sessions из /root/.openclaw-moa..."

# Убеждаемся что структура есть
mkdir -p /opt/openclaw/.openclaw/agents/main/sessions

# Копируем sessions
if [ -d "/root/.openclaw-moa/.openclaw/agents/main/sessions" ]; then
    cp -r /root/.openclaw-moa/.openclaw/agents/main/sessions/* \
        /opt/openclaw/.openclaw/agents/main/sessions/ 2>/dev/null
    echo "  ✓ Sessions скопированы"
else
    echo "  · Нет sessions в /root/.openclaw-moa"
fi

# Убеждаемся что ВСЯ структура agents есть
mkdir -p /opt/openclaw/.openclaw/agents/main/agent
for f in auth-profiles.json models.json; do
    if [ -f "/root/.openclaw-moa/.openclaw/agents/main/agent/$f" ]; then
        cp "/root/.openclaw-moa/.openclaw/agents/main/agent/$f" \
           "/opt/openclaw/.openclaw/agents/main/agent/$f" 2>/dev/null
    fi
done

echo ""
echo "[4/6] Исправляю пути в конфиге..."

python3 << 'PYFIX'
import json

cfg_path = "/opt/openclaw/.openclaw/openclaw.json"
with open(cfg_path) as f:
    cfg = json.load(f)

changes = []

# Заменяем workspace
agents = cfg.get("agents", {})
defaults = agents.get("defaults", {})
old_ws = defaults.get("workspace", "")

if "/root/" in old_ws or "/home/mmber/" in old_ws:
    defaults["workspace"] = "/opt/openclaw/workspace-moa"
    changes.append(f"workspace: {old_ws} → /opt/openclaw/workspace-moa")

# Ищем и заменяем любые пути на /root/.openclaw-moa в JSON
cfg_str = json.dumps(cfg)
if "/root/.openclaw-moa" in cfg_str:
    cfg_str = cfg_str.replace("/root/.openclaw-moa", "/opt/openclaw")
    cfg = json.loads(cfg_str)
    changes.append("Заменены все /root/.openclaw-moa → /opt/openclaw")

if "/home/mmber/.openclaw" in cfg_str:
    cfg_str = cfg_str.replace("/home/mmber/.openclaw", "/opt/openclaw/.openclaw")
    cfg = json.loads(cfg_str)
    changes.append("Заменены все /home/mmber/.openclaw → /opt/openclaw/.openclaw")

with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

if changes:
    for ch in changes:
        print(f"  ✓ {ch}")
else:
    print("  (пути уже корректные)")
PYFIX

# Все права openclaw
chown -R openclaw:openclaw /opt/openclaw
echo "  ✓ Права обновлены"

echo ""
echo "[5/6] Перезапускаю gateway..."

# Стопаем
systemctl stop openclaw-gateway-moa 2>/dev/null
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

# Стартуем
systemctl start openclaw-gateway-moa 2>/dev/null
sleep 20

echo ""
echo "[6/6] Проверка..."

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ЗАПУЩЕН (порт 18789)"
    ps aux | grep -E "[o]penclaw.*gate" | awk '{print "    User: "$1", PID: "$2}' | head -1
else
    echo "  ✗ Gateway не запустился через systemd"
    echo "  Journal:"
    journalctl -u openclaw-gateway-moa --no-pager -n 10 | sed 's/^/    /'
    
    echo ""
    echo "  Пробую nohup..."
    su -s /bin/bash -c '
        cd /opt/openclaw
        OPENCLAW_HOME=/opt/openclaw \
        OLLAMA_API_KEY=ollama-local \
        nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
    ' openclaw
    sleep 20
    ss -tlnp | grep -q ":18789 " && echo "  ✓ Gateway запущен (nohup)" || echo "  ✗ НЕ запустился"
fi

echo ""
echo "  Лог (последние 15 строк):"
# Лог может быть в разных местах
for logpath in \
    /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log \
    /data/logs/gateway-moa.log; do
    if [ -f "$logpath" ]; then
        echo "  ($logpath)"
        tail -15 "$logpath" | sed 's/^/    /'
        
        echo ""
        echo "  Ошибки EACCES:"
        grep -i "EACCES\|permission denied" "$logpath" | tail -5 | sed 's/^/    /' || echo "    (нет ошибок EACCES)"
        break
    fi
done

echo ""
echo "  Конфиг workspace:"
python3 -c "
import json
with open('/opt/openclaw/.openclaw/openclaw.json') as f:
    c = json.load(f)
print('    ' + c.get('agents',{}).get('defaults',{}).get('workspace','(не задан)'))
" 2>/dev/null

REMOTE

echo ""
echo "=========================================="
echo "  ИТОГ"
echo "=========================================="
echo "  Если ✓ Gateway ЗАПУЩЕН и нет EACCES:"
echo "    Напиши боту: Кто ты?"
echo "=========================================="
