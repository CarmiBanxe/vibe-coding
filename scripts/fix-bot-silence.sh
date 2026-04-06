#!/bin/bash
###############################################################################
# fix-bot-silence.sh — Диагностика и починка молчащего бота
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-bot-silence.sh
#
# Что делает:
#   1. Проверяет — жив ли gateway (порт 18789)
#   2. Проверяет — жив ли Ollama (порт 11434)
#   3. Проверяет — отвечает ли модель
#   4. Смотрит логи на ошибки
#   5. Если gateway мёртв — перезапускает
#   6. Показывает live-лог для контроля
###############################################################################

echo "=========================================="
echo "  ДИАГНОСТИКА МОЛЧАЩЕГО БОТА"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

echo ""
echo "============================================"
echo "  ШАГ 1: Проверяю процессы gateway"
echo "============================================"
echo ""

GW_PROCS=$(pgrep -fa "openclaw" 2>/dev/null)
if [ -n "$GW_PROCS" ]; then
    echo "  Процессы openclaw:"
    echo "$GW_PROCS" | sed 's/^/    /'
else
    echo "  ✗ Процессов openclaw НЕТ — gateway мёртв!"
fi

echo ""
echo "============================================"
echo "  ШАГ 2: Проверяю порт 18789 (gateway)"
echo "============================================"
echo ""

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Порт 18789 СЛУШАЕТ"
    ss -tlnp | grep ":18789 " | sed 's/^/    /'
else
    echo "  ✗ Порт 18789 НЕ СЛУШАЕТ — gateway не запущен!"
fi

echo ""
echo "============================================"
echo "  ШАГ 3: Проверяю Ollama (порт 11434)"
echo "============================================"
echo ""

if ss -tlnp | grep -q ":11434 "; then
    echo "  ✓ Порт 11434 СЛУШАЕТ"
else
    echo "  ✗ Ollama НЕ слушает!"
fi

# Проверяем отвечает ли Ollama
OLLAMA_RESP=$(curl -s --max-time 10 http://localhost:11434/api/tags 2>/dev/null)
if echo "$OLLAMA_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  ✓ Ollama OK, моделей: {len(d.get(\"models\",[]))}')" 2>/dev/null; then
    echo "  Загруженные модели:"
    echo "$OLLAMA_RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d.get('models',[]):
    sz = m.get('size',0)/(1024**3)
    print(f'    - {m[\"name\"]} ({sz:.1f} GB)')
" 2>/dev/null
else
    echo "  ✗ Ollama НЕ отвечает на /api/tags!"
fi

echo ""
echo "============================================"
echo "  ШАГ 4: Проверяю модель (быстрый тест)"
echo "============================================"
echo ""

MODEL_RESP=$(curl -s --max-time 30 http://localhost:11434/api/generate \
    -d '{"model":"huihui_ai/glm-4.7-flash-abliterated","prompt":"Say OK","stream":false,"options":{"num_predict":5}}' 2>/dev/null)

if echo "$MODEL_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  ✓ Модель отвечает: {d.get(\"response\",\"(пусто)\")[:50]}')" 2>/dev/null; then
    true
else
    echo "  ✗ Модель НЕ отвечает (таймаут или ошибка)"
    echo "  Ответ: $MODEL_RESP"
fi

echo ""
echo "============================================"
echo "  ШАГ 5: Логи gateway (последние ошибки)"  
echo "============================================"
echo ""

# Проверяем где лог
for LOGPATH in \
    /data/logs/gateway-moa.log \
    /root/.openclaw-moa/gateway.log \
    /opt/openclaw/gateway.log; do
    if [ -f "$LOGPATH" ]; then
        echo "  Лог: $LOGPATH"
        echo "  Размер: $(du -h "$LOGPATH" | cut -f1)"
        echo ""
        echo "  --- Последние 30 строк ---"
        tail -30 "$LOGPATH" | sed 's/^/    /'
        echo ""
        echo "  --- Ошибки (последние 10) ---"
        grep -iE "error|fail|crash|exception|ECONNREFUSED|timeout|reject|fatal" "$LOGPATH" | tail -10 | sed 's/^/    /' || echo "    (ошибок не найдено)"
        break
    fi
done

echo ""
echo "============================================"
echo "  ШАГ 6: Память и нагрузка"
echo "============================================"
echo ""

echo "  RAM:"
free -h | head -2 | sed 's/^/    /'
echo ""
echo "  Загрузка GPU (если есть):"
cat /sys/class/drm/card*/device/mem_info_vram_used 2>/dev/null | while read v; do echo "    VRAM used: $((v/1024/1024/1024)) GB"; done || echo "    (нет данных GPU)"
echo ""
echo "  Top процессы по RAM:"
ps aux --sort=-%mem | head -6 | awk '{printf "    %-10s %s %s %s\n", $1, $4"%", $11, $12}' 

echo ""
echo "============================================"
echo "  ШАГ 7: Конфиг бота — Telegram token"
echo "============================================"
echo ""

CFG="/root/.openclaw-moa/.openclaw/openclaw.json"
if [ -f "$CFG" ]; then
    echo "  Конфиг существует: $CFG"
    # Проверяем telegram секцию (без показа токена)
    python3 -c "
import json
with open('$CFG') as f:
    c = json.load(f)
# Telegram
tg = None
agents = c.get('agents', {})
for name, agent in agents.items():
    if isinstance(agent, dict):
        interfaces = agent.get('interfaces', {})
        telegram = interfaces.get('telegram', {})
        if telegram:
            token = telegram.get('token', '')
            masked = token[:10] + '...' + token[-4:] if len(token) > 14 else '(пусто)'
            print(f'  Агент \"{name}\": Telegram token = {masked}')
            tg = True
if not tg:
    # Проверим корневой уровень
    ifaces = c.get('interfaces', {})
    tg_root = ifaces.get('telegram', {})
    if tg_root:
        token = tg_root.get('token', '')
        masked = token[:10] + '...' + token[-4:] if len(token) > 14 else '(пусто)'
        print(f'  Корневой Telegram token = {masked}')
    else:
        print('  ✗ Telegram секция НЕ НАЙДЕНА в конфиге!')
" 2>/dev/null
    
    # Проверяем модель
    python3 -c "
import json
with open('$CFG') as f:
    c = json.load(f)
agents = c.get('agents', {})
for name, agent in agents.items():
    if isinstance(agent, dict):
        model = agent.get('model', '(не указана)')
        print(f'  Агент \"{name}\": model = {model}')
" 2>/dev/null

else
    echo "  ✗ Конфиг НЕ найден: $CFG"
fi

echo ""
echo "============================================"
echo "  ШАГ 8: ПЕРЕЗАПУСК GATEWAY (если мёртв)"
echo "============================================"
echo ""

if ! ss -tlnp | grep -q ":18789 "; then
    echo "  Gateway мёртв — ПЕРЕЗАПУСКАЮ..."
    
    pkill -9 -f "openclaw.*gateway" 2>/dev/null
    sleep 2
    
    cd /root/.openclaw-moa
    OPENCLAW_HOME=/root/.openclaw-moa \
    OLLAMA_API_KEY=ollama-local \
    nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
    GW_PID=$!
    echo "  Запущен PID: $GW_PID"
    echo "  Жду 20 секунд..."
    sleep 20
    
    if ss -tlnp | grep -q ":18789 "; then
        echo "  ✓ Gateway ПЕРЕЗАПУЩЕН УСПЕШНО!"
        echo ""
        echo "  Последние строки лога:"
        tail -10 /data/logs/gateway-moa.log | sed 's/^/    /'
    else
        echo "  ✗ Gateway НЕ запустился!"
        echo "  Лог:"
        tail -20 /data/logs/gateway-moa.log | sed 's/^/    /'
    fi
else
    echo "  Gateway жив (порт 18789) — перезапуск не нужен"
    echo ""
    echo "  Но бот молчит... Проблема может быть в:"
    echo "    - Telegram polling зависло"  
    echo "    - Модель не отвечает (OOM/таймаут)"
    echo "    - Конфиг Telegram token устарел"
    echo ""
    echo "  Принудительный ПЕРЕЗАПУСК..."
    
    pkill -9 -f "openclaw.*gateway" 2>/dev/null
    sleep 3
    
    cd /root/.openclaw-moa
    OPENCLAW_HOME=/root/.openclaw-moa \
    OLLAMA_API_KEY=ollama-local \
    nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
    GW_PID=$!
    echo "  Запущен PID: $GW_PID"
    echo "  Жду 20 секунд..."
    sleep 20
    
    if ss -tlnp | grep -q ":18789 "; then
        echo "  ✓ Gateway ПЕРЕЗАПУЩЕН!"
        echo ""
        echo "  Последние строки лога:"
        tail -15 /data/logs/gateway-moa.log | sed 's/^/    /'
    else
        echo "  ✗ Не запустился после перезапуска"
        tail -20 /data/logs/gateway-moa.log | sed 's/^/    /'
    fi
fi

echo ""
echo "============================================"
echo "  ИТОГ"
echo "============================================"
echo ""
echo "  Порт 18789:"
ss -tlnp | grep ":18789 " | sed 's/^/    /' || echo "    НЕ СЛУШАЕТ"
echo ""
echo "  Процесс gateway:"
pgrep -fa "openclaw" | sed 's/^/    /' || echo "    НЕТ ПРОЦЕССА"

REMOTE

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "  Если бот заработал — напиши ему: Привет, кто ты?"
echo "  Если нет — скинь мне вывод этого скрипта"
echo "=========================================="
