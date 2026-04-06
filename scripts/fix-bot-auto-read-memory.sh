#!/bin/bash
###############################################################################
# fix-bot-auto-read-memory.sh — Бот автоматически читает MEMORY.md и
# SYSTEM-STATE.md при каждом запросе
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-bot-auto-read-memory.sh
#
# Что делает:
#   1. Добавляет в system prompt бота инструкцию:
#      "Перед каждым ответом читай MEMORY.md и SYSTEM-STATE.md"
#   2. Обновляет оба конфига (MoA + mycarmibot)
#   3. Перезапускает gateway
#   4. Тестирует что бот реагирует
#
# После этого бот АВТОМАТИЧЕСКИ при каждом сообщении:
#   - Читает MEMORY.md (кто он, инфраструктура, инструменты)
#   - Читает SYSTEM-STATE.md (актуальное состояние сервера)
#   - Использует эти данные в ответе
###############################################################################

echo "=========================================="
echo "  АВТОЧТЕНИЕ MEMORY.md + SYSTEM-STATE.md"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export PATH="$PATH:/root/.local/bin"

###########################################################################
# 1. Обновляем system prompt в конфигах
###########################################################################
echo "[1/3] Обновляю system prompt ботов..."

for CFG in \
    "/root/.openclaw-moa/.openclaw/openclaw.json" \
    "/root/.openclaw-default/.openclaw/openclaw.json"; do
    
    if [ ! -f "$CFG" ]; then
        echo "  ✗ $CFG не найден"
        continue
    fi
    
    # Бэкап
    cp "$CFG" "${CFG}.bak-$(date +%Y%m%d-%H%M%S)"
    
    python3 << PYFIX
import json

cfg_path = "$CFG"
with open(cfg_path) as f:
    cfg = json.load(f)

# Новый system prompt
SYSTEM_PROMPT = """Ты — CTIO проекта Banxe AI Bank (EMI, FCA authorised).
CEO — Moriel Carmi (@bereg2022, Telegram ID: 508602494).

ВАЖНО: При КАЖДОМ ответе ты ОБЯЗАН прочитать эти файлы из своего workspace:
1. MEMORY.md — твоя память (кто ты, инфраструктура, инструменты, история, план)
2. SYSTEM-STATE.md — актуальное состояние сервера (сервисы, порты, модели, таблицы)

Используй данные из этих файлов для точных, актуальных ответов.
Если пользователь спрашивает о состоянии системы — бери данные из SYSTEM-STATE.md.
Если спрашивает об истории или плане — бери из MEMORY.md.

Для поиска в интернете используй Brave Search API (ключ в MEMORY.md).
Для локального поиска используй Deep Search (порт 8088).

Отвечай на русском. Будь конкретен и полезен.
Не выполняй команд на сервере — ты read-only observer."""

# Находим где хранится system prompt
agents = cfg.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})

# Устанавливаем system prompt
defaults["systemPrompt"] = SYSTEM_PROMPT

# Также пробуем альтернативные пути где OpenClaw может хранить промпт
if "system" not in cfg:
    cfg["system"] = {}
cfg["system"]["prompt"] = SYSTEM_PROMPT

# И ещё один вариант
cfg["systemPrompt"] = SYSTEM_PROMPT

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"  ✓ {cfg_path} — system prompt обновлён")
PYFIX
done

# Также обновляем корневые конфиги
for CFG in \
    "/root/.openclaw-moa/openclaw.json" \
    "/root/.openclaw-default/openclaw.json"; do
    
    if [ ! -f "$CFG" ]; then continue; fi
    
    python3 << PYFIX2
import json

cfg_path = "$CFG"
with open(cfg_path) as f:
    cfg = json.load(f)

SYSTEM_PROMPT = """Ты — CTIO проекта Banxe AI Bank (EMI, FCA authorised).
CEO — Moriel Carmi (@bereg2022, Telegram ID: 508602494).

ВАЖНО: При КАЖДОМ ответе ты ОБЯЗАН прочитать эти файлы из своего workspace:
1. MEMORY.md — твоя память (кто ты, инфраструктура, инструменты, история, план)
2. SYSTEM-STATE.md — актуальное состояние сервера (сервисы, порты, модели, таблицы)

Используй данные из этих файлов для точных, актуальных ответов.
Отвечай на русском. Будь конкретен и полезен.
Не выполняй команд на сервере — ты read-only observer."""

agents = cfg.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
defaults["systemPrompt"] = SYSTEM_PROMPT
cfg["systemPrompt"] = SYSTEM_PROMPT

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"  ✓ {cfg_path} — system prompt обновлён")
PYFIX2
done

###########################################################################
# 2. Перезапускаем gateway
###########################################################################
echo ""
echo "[2/3] Перезапускаю gateway..."

# Мягкий перезапуск — kill + systemd
systemctl restart openclaw-gateway-moa 2>/dev/null
sleep 5
systemctl restart openclaw-gateway-mycarmibot 2>/dev/null
sleep 5

# Проверяем
if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ @mycarmi_moa_bot ACTIVE (порт 18789)"
else
    echo "  ⚠ MoA не на порту — пробую nohup..."
    pkill -f "openclaw.*18789" 2>/dev/null
    sleep 2
    cd /root/.openclaw-moa
    OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
    sleep 8
    ss -tlnp | grep -q ":18789 " && echo "  ✓ MoA ACTIVE (nohup)" || echo "  ✗ MoA не запустился"
fi

if ss -tlnp | grep -q ":18793 "; then
    echo "  ✓ @mycarmibot ACTIVE (порт 18793)"
else
    echo "  ⚠ mycarmibot не на порту — пробую nohup..."
    pkill -f "openclaw.*18793" 2>/dev/null
    sleep 2
    cd /root/.openclaw-default
    OPENCLAW_HOME=/root/.openclaw-default nohup npx openclaw gateway --port 18793 > /data/logs/gateway-mycarmibot.log 2>&1 &
    sleep 8
    ss -tlnp | grep -q ":18793 " && echo "  ✓ mycarmibot ACTIVE (nohup)" || echo "  ✗ mycarmibot не запустился"
fi

###########################################################################
# 3. Проверка
###########################################################################
echo ""
echo "[3/3] Проверяю..."

echo "  Порты gateway:"
ss -tlnp | grep -E "1878|1879" | while read line; do
    echo "    $line"
done

echo ""
echo "  Файлы в workspace бота:"
for f in MEMORY.md SYSTEM-STATE.md; do
    FOUND=0
    for DIR in "/root/.openclaw-moa/workspace-moa" "/root/.openclaw-moa/.openclaw/workspace"; do
        if [ -f "$DIR/$f" ]; then
            LINES=$(wc -l < "$DIR/$f")
            echo "    ✓ $DIR/$f ($LINES строк)"
            FOUND=1
            break
        fi
    done
    [ $FOUND -eq 0 ] && echo "    ✗ $f не найден в workspace"
done

echo ""
echo "  System prompt (первые 3 строки):"
python3 -c "
import json
with open('/root/.openclaw-moa/.openclaw/openclaw.json') as f:
    c = json.load(f)
sp = c.get('agents',{}).get('defaults',{}).get('systemPrompt','') or c.get('systemPrompt','')
for line in sp.split('\n')[:3]:
    print(f'    {line}')
" 2>/dev/null

REMOTE_END

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "  Бот теперь при КАЖДОМ сообщении:"
echo "    1. Читает MEMORY.md (память, инструменты, план)"
echo "    2. Читает SYSTEM-STATE.md (сервисы, порты, модели)"
echo "    3. Использует данные в ответе"
echo ""
echo "  Проверь — напиши боту:"
echo '    "Какие сервисы сейчас работают на сервере?"'
echo '    "Какой у тебя план?"'
echo '    "Найди информацию о FCA"'
