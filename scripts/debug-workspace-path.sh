#!/bin/bash
###############################################################################
# debug-workspace-path.sh — Определяем КУДА бот реально смотрит за workspace
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/debug-workspace-path.sh
#
# НЕ трогает @mycarmibot и его конфиги!
# Работает ТОЛЬКО с moa-ботом (/opt/openclaw)
###############################################################################

echo "=========================================="
echo "  DEBUG: Куда бот смотрит за workspace?"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

echo ""
echo "=== 1. Конфиг moa-бота ==="
echo ""

CFG="/opt/openclaw/.openclaw/openclaw.json"
echo "  Конфиг: $CFG"

python3 -c "
import json
with open('$CFG') as f:
    c = json.load(f)
ws = c.get('agents',{}).get('defaults',{}).get('workspace','(не задан)')
print(f'  agents.defaults.workspace: {ws}')
" 2>/dev/null

echo ""
echo "=== 2. Environment gateway ==="
echo ""

# Проверяем env переменные процесса gateway
GW_PID=$(pgrep -f "openclaw-gateway" | head -1)
if [ -n "$GW_PID" ]; then
    echo "  Gateway PID: $GW_PID"
    echo "  OPENCLAW_HOME:"
    cat /proc/$GW_PID/environ 2>/dev/null | tr '\0' '\n' | grep OPENCLAW_HOME | sed 's/^/    /'
    echo "  HOME:"
    cat /proc/$GW_PID/environ 2>/dev/null | tr '\0' '\n' | grep "^HOME=" | sed 's/^/    /'
    echo "  User:"
    ps -o user= -p $GW_PID | sed 's/^/    /'
else
    echo "  ✗ Gateway не найден!"
fi

echo ""
echo "=== 3. ВСЕ возможные workspace директории ==="
echo ""

# OpenClaw ищет workspace по: OPENCLAW_HOME/.openclaw/workspace или agents.defaults.workspace
# Также может быть ~/workspace или ~/.openclaw/workspace

for d in \
    "/opt/openclaw/workspace-moa" \
    "/opt/openclaw/.openclaw/workspace" \
    "/opt/openclaw/workspace" \
    "/home/mmber/.openclaw/workspace" \
    "/root/.openclaw-moa/workspace-moa" \
    "/root/.openclaw-moa/.openclaw/workspace" \
    "/root/.openclaw/workspace"; do
    if [ -d "$d" ]; then
        HAS_SOUL=$([ -f "$d/SOUL.md" ] && echo "✓ SOUL.md" || echo "✗ нет SOUL.md")
        HAS_MEM=$([ -f "$d/MEMORY.md" ] && echo "✓ MEMORY.md" || echo "✗ нет MEMORY.md")
        SOUL_SIZE=$(wc -c < "$d/SOUL.md" 2>/dev/null || echo "0")
        echo "  $d"
        echo "    $HAS_SOUL ($SOUL_SIZE байт) | $HAS_MEM"
    fi
done

echo ""
echo "=== 4. Что OpenClaw РЕАЛЬНО загружает ==="
echo ""

# Смотрим в лог — OpenClaw пишет workspace path при старте
for logpath in \
    /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log \
    /data/logs/gateway-moa.log; do
    if [ -f "$logpath" ]; then
        echo "  Лог: $logpath"
        # Ищем workspace-related записи
        grep -i "workspace\|bootstrap\|soul\|loading.*md\|agent.*dir\|state.*dir" "$logpath" 2>/dev/null | tail -10 | \
            python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        msg = d.get('0','')
        if msg:
            print(f'    {msg[:150]}')
    except:
        print(f'    {line.strip()[:150]}')
" 2>/dev/null
        break
    fi
done

echo ""
echo "=== 5. Systemd сервис — откуда запускается ==="
echo ""

systemctl cat openclaw-gateway-moa 2>/dev/null | grep -E "WorkingDirectory|Environment|ExecStart|User" | sed 's/^/    /'

echo ""
echo "=== 6. HOME пользователя openclaw ==="
echo ""

echo "  getent passwd openclaw:"
getent passwd openclaw | sed 's/^/    /'

echo ""
echo "  ~ для openclaw:"
su -s /bin/bash -c 'echo $HOME' openclaw 2>/dev/null | sed 's/^/    /' || echo "    (не удалось определить — shell nologin)"

echo ""
echo "  Содержимое /opt/openclaw/:"
ls -la /opt/openclaw/ | sed 's/^/    /'

echo ""
echo "=== 7. Проверяю — OpenClaw ищет workspace по HOME/.openclaw/workspace ==="
echo ""

# OpenClaw может использовать HOME (а не OPENCLAW_HOME) для workspace
# HOME openclaw = /opt/openclaw
# Значит workspace = /opt/openclaw/.openclaw/workspace (НЕ /opt/openclaw/workspace-moa!)

TARGET="/opt/openclaw/.openclaw/workspace"
echo "  Ожидаемый путь: $TARGET"

if [ -d "$TARGET" ]; then
    echo "  ✓ Существует"
    ls -la "$TARGET"/*.md 2>/dev/null | sed 's/^/    /' || echo "    (пусто)"
else
    echo "  ✗ НЕ существует!"
    echo ""
    echo "  РЕШЕНИЕ: создаю symlink или копирую..."
    
    # Создаём директорию и копируем файлы
    mkdir -p "$TARGET"
    cp /opt/openclaw/workspace-moa/*.md "$TARGET/" 2>/dev/null
    chown -R openclaw:openclaw "$TARGET"
    echo "  ✓ Создано и заполнено:"
    ls -la "$TARGET"/*.md 2>/dev/null | sed 's/^/    /'
fi

echo ""
echo "=== 8. Также проверяю OPENCLAW_HOME/.openclaw/ как workspace корень ==="
echo ""

# Некоторые версии ищут файлы прямо в .openclaw/
OC_DIR="/opt/openclaw/.openclaw"
for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md MEMORY.md; do
    if [ -f "$OC_DIR/$f" ]; then
        echo "  ✓ $OC_DIR/$f ($(wc -c < "$OC_DIR/$f") байт)"
    else
        echo "  ✗ $OC_DIR/$f (не найден)"
    fi
done

REMOTE

echo ""
echo "=========================================="
echo "  ИТОГ"
echo "=========================================="
echo "  Скинь мне вывод — увидим куда бот реально смотрит"
echo "  и почему не видит SOUL.md"
echo "=========================================="
