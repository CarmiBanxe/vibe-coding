#!/bin/bash
###############################################################################
# restart-gateway-clean.sh — Чистый перезапуск gateway от openclaw
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/restart-gateway-clean.sh
#
# НЕ трогает @mycarmibot!
#
# Проблема: gateway запустился от root вместо openclaw
# Решение: убить все openclaw-gateway, запустить через systemd
###############################################################################

echo "=========================================="
echo "  ЧИСТЫЙ ПЕРЕЗАПУСК GATEWAY"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

echo ""
echo "[1/5] Убиваю ВСЕ процессы openclaw-gateway..."

# Показываем что убиваем
echo "  Текущие процессы:"
pgrep -fa "openclaw" | grep -v "mycarmibot" | sed 's/^/    /'

# Убиваем ВСЕ gateway (но НЕ @mycarmibot если он на другом порту)
# moa-бот на 18789, mycarmibot может быть на другом
pkill -9 -f "openclaw.*18789" 2>/dev/null
sleep 2

# Проверяем не остались ли
REMAINING=$(pgrep -f "openclaw.*gateway" 2>/dev/null | wc -l)
if [ "$REMAINING" -gt 0 ]; then
    echo "  ⚠ Остались процессы, принудительный kill..."
    pkill -9 -f "openclaw-gateway" 2>/dev/null
    sleep 2
fi

echo "  ✓ Все gateway-процессы убиты"

# Проверяем порт
if ss -tlnp | grep -q ":18789 "; then
    echo "  ⚠ Порт 18789 ещё занят!"
    PIDS=$(ss -tlnp | grep ":18789 " | grep -oP 'pid=\K[0-9]+')
    for pid in $PIDS; do
        echo "    Убиваю PID $pid..."
        kill -9 "$pid" 2>/dev/null
    done
    sleep 3
fi

echo ""
echo "[2/5] Проверяю systemd сервис..."

echo "  Статус сервиса:"
systemctl is-enabled openclaw-gateway-moa 2>/dev/null | sed 's/^/    /'
systemctl is-active openclaw-gateway-moa 2>/dev/null | sed 's/^/    /'

echo ""
echo "  Конфиг сервиса:"
systemctl cat openclaw-gateway-moa 2>/dev/null | grep -E "User|Home|Working|Exec|OPENCLAW" | sed 's/^/    /'

echo ""
echo "[3/5] Также создаю symlink workspace → workspace-moa..."

# OpenClaw может искать workspace в .openclaw/workspace
# Создаём symlink чтобы не копировать файлы дважды
WS_LINK="/opt/openclaw/.openclaw/workspace"
WS_REAL="/opt/openclaw/workspace-moa"

# Удаляем директорию если это не symlink (была создана debug-скриптом)
if [ -d "$WS_LINK" ] && [ ! -L "$WS_LINK" ]; then
    rm -rf "$WS_LINK"
fi

# Создаём symlink
if [ ! -L "$WS_LINK" ]; then
    ln -s "$WS_REAL" "$WS_LINK"
    echo "  ✓ Symlink: $WS_LINK → $WS_REAL"
else
    echo "  ✓ Symlink уже есть: $(readlink "$WS_LINK")"
fi

# Проверяем что файлы доступны через symlink
echo "  Файлы через symlink:"
ls "$WS_LINK"/SOUL.md "$WS_LINK"/BOOTSTRAP.md "$WS_LINK"/MEMORY.md 2>/dev/null | sed 's/^/    /'

# Также обновляем конфиг — workspace путь
python3 << 'PYFIX'
import json

cfg_path = "/opt/openclaw/.openclaw/openclaw.json"
with open(cfg_path) as f:
    cfg = json.load(f)

agents = cfg.get("agents", {})
defaults = agents.get("defaults", {})
old_ws = defaults.get("workspace", "")

# Ставим путь который symlink разрешит правильно
if old_ws != "/opt/openclaw/workspace-moa":
    defaults["workspace"] = "/opt/openclaw/workspace-moa"
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"  ✓ Конфиг: workspace = /opt/openclaw/workspace-moa")
else:
    print(f"  · Конфиг workspace уже OK")
PYFIX

chown -R openclaw:openclaw /opt/openclaw

echo ""
echo "[4/5] Запускаю через systemd..."

systemctl stop openclaw-gateway-moa 2>/dev/null
sleep 2
systemctl start openclaw-gateway-moa 2>/dev/null

echo "  Жду 25 секунд..."
sleep 25

echo ""
echo "[5/5] Проверка..."

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Порт 18789 слушает"
else
    echo "  ✗ Порт 18789 НЕ слушает!"
    echo "  Journal последние 20 строк:"
    journalctl -u openclaw-gateway-moa --no-pager -n 20 | sed 's/^/    /'
    
    echo ""
    echo "  Пробую запуск вручную через su..."
    su -s /bin/bash -c '
        export HOME=/opt/openclaw
        export OPENCLAW_HOME=/opt/openclaw
        export OLLAMA_API_KEY=ollama-local
        cd /opt/openclaw
        nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
        echo "PID: $!"
    ' openclaw
    sleep 25
    
    if ss -tlnp | grep -q ":18789 "; then
        echo "  ✓ Gateway запущен через su openclaw"
    else
        echo "  ✗ Не запустился от openclaw"
        echo "  Лог:"
        tail -20 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'
    fi
fi

echo ""
echo "  Кто запустил gateway:"
GW_PID=$(pgrep -f "openclaw-gateway" | head -1)
if [ -n "$GW_PID" ]; then
    GW_USER=$(ps -o user= -p $GW_PID)
    GW_HOME=$(cat /proc/$GW_PID/environ 2>/dev/null | tr '\0' '\n' | grep "^HOME=" || echo "неизвестно")
    GW_OC_HOME=$(cat /proc/$GW_PID/environ 2>/dev/null | tr '\0' '\n' | grep "OPENCLAW_HOME=" || echo "неизвестно")
    echo "  PID: $GW_PID"
    echo "  User: $GW_USER"
    echo "  $GW_HOME"
    echo "  $GW_OC_HOME"
else
    echo "  ✗ Процесс gateway НЕ найден!"
fi

echo ""
echo "  Лог (последние 10 строк):"
for logpath in /data/logs/gateway-moa.log /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log; do
    if [ -f "$logpath" ]; then
        echo "  ($logpath)"
        tail -10 "$logpath" 2>/dev/null | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    try:
        d = json.loads(line)
        msg = d.get('0','')
        ts = d.get('time','')[:19]
        lvl = d.get('_meta',{}).get('logLevelName','')
        if msg:
            print(f'    [{lvl}] {ts} {msg[:120]}')
    except:
        if line:
            print(f'    {line[:120]}')
" 2>/dev/null
        break
    fi
done

echo ""
echo "  Telegram ошибки в логе:"
for logpath in /data/logs/gateway-moa.log /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log; do
    if [ -f "$logpath" ]; then
        grep -i "telegram.*error\|telegram.*fail\|409\|conflict" "$logpath" 2>/dev/null | tail -5 | \
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

REMOTE

echo ""
echo "=========================================="
echo "  ИТОГ"
echo "=========================================="
echo "  Если User: openclaw и OPENCLAW_HOME=/opt/openclaw"
echo "  — напиши боту: Кто ты?"
echo ""
echo "  Если User: root — скинь вывод, будем разбираться"
echo "=========================================="
