#!/bin/bash
###############################################################################
# fix-gateways-v2.sh — Починка gateway после сбоя
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-gateways-v2.sh
#
# Что делает:
#   1. Находит ВСЕ конфиги openclaw на GMKtec
#   2. Проверяет что gateway.mode=local есть в конфигах
#   3. Находит реальную директорию mycarmibot
#   4. Правит systemd сервисы с правильными путями
#   5. Запускает оба gateway
#   6. Проверяет что порты слушают
###############################################################################

echo "=========================================="
echo "  FIX GATEWAYS v2"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

###########################################################################
# 1. ДИАГНОСТИКА: все конфиги, все профили
###########################################################################
echo "[1/6] Ищу все конфиги и профили OpenClaw..."
echo ""

echo "  ВСЕ файлы openclaw.json на системе:"
find / -name "openclaw.json" -not -path "*/node_modules/*" 2>/dev/null | while read f; do
    SIZE=$(stat -c%s "$f" 2>/dev/null)
    # Проверяем есть ли gateway.mode
    MODE=$(python3 -c "import json; print(json.load(open('$f')).get('gateway',{}).get('mode','НЕТ'))" 2>/dev/null)
    # Проверяем port
    PORT=$(python3 -c "import json; c=json.load(open('$f')); print(c.get('gateway',{}).get('port', c.get('port','НЕТ')))" 2>/dev/null)
    # Проверяем telegram token (первые 10 символов)
    TOKEN=$(python3 -c "
import json
c=json.load(open('$f'))
t=c.get('telegram',{}).get('token','')
if not t:
    t=c.get('gateway',{}).get('telegram',{}).get('token','')
print(t[:15]+'...' if t else 'НЕТ')
" 2>/dev/null)
    echo "  $f"
    echo "    size=$SIZE, gateway.mode=$MODE, port=$PORT, token=$TOKEN"
done

echo ""
echo "  Все профили OpenClaw (директории):"
find / -maxdepth 4 -name ".openclaw" -type d 2>/dev/null | while read d; do
    echo "  $d"
    ls -la "$d/" 2>/dev/null | grep -E "openclaw.json|workspace" | head -5 | sed 's/^/    /'
done

echo ""
echo "  Текущие systemd сервисы openclaw:"
cat /etc/systemd/system/openclaw-gateway-moa.service 2>/dev/null
echo "---"
ls /etc/systemd/system/openclaw-gateway-*.service 2>/dev/null

###########################################################################
# 2. ТЕКУЩИЕ ПРОЦЕССЫ — что запущено СЕЙЧАС
###########################################################################
echo ""
echo "[2/6] Текущие процессы openclaw:"
ps aux | grep -E "[o]penclaw|[g]ateway" | head -10
echo ""
echo "  Порты 18789/18793:"
ss -tlnp | grep -E "1878|1879"

###########################################################################
# 3. ПРОВЕРЯЕМ И ПРАВИМ КОНФИГ MoA
###########################################################################
echo ""
echo "[3/6] Проверяю конфиг MoA бота..."

MOA_CONFIG="/root/.openclaw-moa/.openclaw/openclaw.json"
if [ -f "$MOA_CONFIG" ]; then
    echo "  Конфиг найден: $MOA_CONFIG"
    
    # Проверяем gateway.mode=local
    HAS_MODE=$(python3 -c "
import json
c=json.load(open('$MOA_CONFIG'))
gw = c.get('gateway',{})
print(gw.get('mode','НЕТ'))
" 2>/dev/null)
    echo "  gateway.mode = $HAS_MODE"
    
    if [ "$HAS_MODE" != "local" ]; then
        echo "  ПРАВЛЮ: добавляю gateway.mode=local..."
        python3 << PYFIX
import json
with open("$MOA_CONFIG") as f:
    c = json.load(f)
if "gateway" not in c:
    c["gateway"] = {}
c["gateway"]["mode"] = "local"
with open("$MOA_CONFIG", "w") as f:
    json.dump(c, f, indent=2)
print("  ✓ gateway.mode=local добавлен")
PYFIX
    else
        echo "  ✓ gateway.mode=local уже есть"
    fi
else
    echo "  ✗ Конфиг НЕ НАЙДЕН: $MOA_CONFIG"
fi

###########################################################################
# 4. НАХОДИМ MYCARMIBOT
###########################################################################
echo ""
echo "[4/6] Ищу конфиг @mycarmibot (порт 18793)..."

# Ищем конфиг с портом 18793
CARMIBOT_CONFIG=""
CARMIBOT_DIR=""

while IFS= read -r f; do
    PORT=$(python3 -c "
import json
c=json.load(open('$f'))
p = c.get('gateway',{}).get('port','')
if not p: p = c.get('port','')
print(p)
" 2>/dev/null)
    if [ "$PORT" = "18793" ]; then
        CARMIBOT_CONFIG="$f"
        CARMIBOT_DIR=$(dirname $(dirname "$f"))
        echo "  ✓ Найден конфиг 18793: $f"
        echo "    Директория: $CARMIBOT_DIR"
        break
    fi
done < <(find / -name "openclaw.json" -not -path "*/node_modules/*" -not -path "*/vibe-coding/*" 2>/dev/null)

if [ -z "$CARMIBOT_CONFIG" ]; then
    echo "  Конфиг с портом 18793 не найден"
    echo "  Ищу по имени бота в конфигах..."
    
    find / -name "openclaw.json" -not -path "*/node_modules/*" 2>/dev/null | while read f; do
        python3 -c "
import json
c=json.load(open('$f'))
# Ищем имя mycarmibot или второй telegram token
bot = c.get('telegram',{}).get('botName','')
if not bot: bot = c.get('gateway',{}).get('telegram',{}).get('botName','')
if bot: print(f'  {f}: botName={bot}')
" 2>/dev/null
    done
fi

###########################################################################
# 5. ПРАВИМ SYSTEMD И ЗАПУСКАЕМ
###########################################################################
echo ""
echo "[5/6] Создаю/обновляю systemd сервисы..."

# Убиваем текущие процессы если зависли
pkill -f "openclaw.*gateway" 2>/dev/null
sleep 2

# MoA сервис
cat > /etc/systemd/system/openclaw-gateway-moa.service << 'SVC'
[Unit]
Description=OpenClaw Gateway — @mycarmi_moa_bot (port 18789)
After=network.target ollama.service

[Service]
Type=simple
WorkingDirectory=/root/.openclaw-moa
ExecStart=/usr/bin/npx openclaw gateway --port 18789
Restart=always
RestartSec=10
Environment=HOME=/root
Environment=NODE_ENV=production
Environment=OPENCLAW_HOME=/root/.openclaw-moa

[Install]
WantedBy=multi-user.target
SVC

# mycarmibot сервис — если нашли директорию
if [ -n "$CARMIBOT_DIR" ]; then
    cat > /etc/systemd/system/openclaw-gateway-mycarmibot.service << SVC2
[Unit]
Description=OpenClaw Gateway — @mycarmibot (port 18793)
After=network.target ollama.service

[Service]
Type=simple
WorkingDirectory=$CARMIBOT_DIR
ExecStart=/usr/bin/npx openclaw gateway --port 18793
Restart=always
RestartSec=10
Environment=HOME=/root
Environment=NODE_ENV=production
Environment=OPENCLAW_HOME=$CARMIBOT_DIR

[Install]
WantedBy=multi-user.target
SVC2
    echo "  ✓ mycarmibot сервис создан (dir=$CARMIBOT_DIR)"
fi

systemctl daemon-reload

# Запускаем MoA
echo ""
echo "  Запускаю @mycarmi_moa_bot..."
systemctl start openclaw-gateway-moa
sleep 8

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ @mycarmi_moa_bot ACTIVE на порту 18789"
    systemctl enable openclaw-gateway-moa 2>/dev/null
else
    echo "  ✗ Порт 18789 не слушает"
    echo "  Лог systemd:"
    journalctl -u openclaw-gateway-moa --no-pager -n 15 2>/dev/null
    
    echo ""
    echo "  Пробую ручной запуск..."
    cd /root/.openclaw-moa
    OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
    MOA_PID=$!
    sleep 8
    if ss -tlnp | grep -q ":18789 "; then
        echo "  ✓ @mycarmi_moa_bot ACTIVE (nohup PID=$MOA_PID)"
    else
        echo "  ✗ Всё ещё не работает"
        echo "  Последние строки лога:"
        tail -20 /data/logs/gateway-moa.log 2>/dev/null
    fi
fi

# Запускаем mycarmibot
if [ -n "$CARMIBOT_DIR" ]; then
    echo ""
    echo "  Запускаю @mycarmibot..."
    systemctl start openclaw-gateway-mycarmibot 2>/dev/null
    sleep 8

    if ss -tlnp | grep -q ":18793 "; then
        echo "  ✓ @mycarmibot ACTIVE на порту 18793"
        systemctl enable openclaw-gateway-mycarmibot 2>/dev/null
    else
        echo "  ✗ Порт 18793 не слушает"
        echo "  Пробую ручной запуск..."
        cd "$CARMIBOT_DIR"
        OPENCLAW_HOME="$CARMIBOT_DIR" nohup npx openclaw gateway --port 18793 > /data/logs/gateway-mycarmibot.log 2>&1 &
        CB_PID=$!
        sleep 8
        if ss -tlnp | grep -q ":18793 "; then
            echo "  ✓ @mycarmibot ACTIVE (nohup PID=$CB_PID)"
        else
            echo "  ✗ Всё ещё не работает"
            tail -20 /data/logs/gateway-mycarmibot.log 2>/dev/null
        fi
    fi
fi

###########################################################################
# 6. ФИНАЛЬНАЯ ПРОВЕРКА
###########################################################################
echo ""
echo "=========================================="
echo "[6/6] Финальная проверка..."
echo ""

echo "  Порты:"
ss -tlnp | grep -E "1878|1879|11434|8088|8089|5678|9000" | while read line; do
    echo "    $line"
done

echo ""
echo "  Процессы gateway:"
ps aux | grep -E "[o]penclaw.*gateway" | awk '{print "    PID "$2" ("$9"): "$11" "$12" "$13" "$14}'

echo ""
echo "  MEMORY.md:"
for f in /root/.openclaw-moa/workspace-moa/MEMORY.md /root/.openclaw-moa/.openclaw/workspace/MEMORY.md; do
    [ -f "$f" ] && echo "    ✓ $f ($(wc -l < "$f") строк)"
done

echo ""
echo "  Автосинк cron:"
crontab -l 2>/dev/null | grep memory-autosync || echo "    (не установлен)"

echo ""
echo "  Репо /data/vibe-coding:"
[ -d "/data/vibe-coding/.git" ] && echo "    ✓ клонирован" || echo "    ✗ нет"
[ -f "/data/vibe-coding/docs/MEMORY.md" ] && echo "    ✓ docs/MEMORY.md есть" || echo "    ✗ docs/MEMORY.md нет"

REMOTE_END

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "Если gateway запустились — проверь бота в Telegram:"
echo '  "Какие у тебя инструменты для поиска?"'
echo '  "Найди информацию о FCA"'
