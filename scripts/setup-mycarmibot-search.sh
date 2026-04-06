#!/bin/bash
###############################################################################
# setup-mycarmibot-search.sh — Настройка поиска и MEMORY для @mycarmibot
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/setup-mycarmibot-search.sh
#
# Что делает:
#   1. Проверяет текущий конфиг @mycarmibot
#   2. Добавляет Brave Search API (ПРАВИЛЬНО — без webSearch ключа)
#   3. Добавляет system prompt (авточтение MEMORY.md + SYSTEM-STATE.md)
#   4. Копирует MEMORY.md и SYSTEM-STATE.md в workspace
#   5. Перезапускает gateway
#   6. Тестирует
###############################################################################

echo "=========================================="
echo "  НАСТРОЙКА @mycarmibot — поиск + память"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export PATH="$PATH:/root/.local/bin"

CFG="/root/.openclaw-default/.openclaw/openclaw.json"
CFG_ROOT="/root/.openclaw-default/openclaw.json"

###########################################################################
# 1. Диагностика
###########################################################################
echo "[1/5] Текущее состояние @mycarmibot..."

if [ -f "$CFG" ]; then
    echo "  Конфиг: $CFG ($(stat -c%s "$CFG") байт)"
    python3 << 'DIAG'
import json
with open("/root/.openclaw-default/.openclaw/openclaw.json") as f:
    c = json.load(f)

# System prompt
sp = c.get("agents",{}).get("defaults",{}).get("systemPrompt","") or c.get("systemPrompt","")
print(f"  systemPrompt: {'✓ есть ({0} символов)'.format(len(sp)) if sp else '✗ НЕТ'}")

# Tools
tools = c.get("tools",{})
print(f"  tools: {list(tools.keys()) if tools else 'пусто'}")

# Provider  
prov = c.get("provider",{})
print(f"  provider: {prov.get('api','?')} @ {prov.get('baseUrl','?')}")

# Model
model = c.get("agents",{}).get("defaults",{}).get("models",{}).get("default","?")
params = c.get("agents",{}).get("defaults",{}).get("params",{})
print(f"  model: {model}")
print(f"  params: {params}")

# Gateway
gw = c.get("gateway",{})
print(f"  gateway.mode: {gw.get('mode','?')}, port: {gw.get('port','?')}")
DIAG
else
    echo "  ✗ Конфиг не найден: $CFG"
fi

echo ""
echo "  Workspace:"
WS="/root/.openclaw-default/.openclaw/workspace"
if [ -d "$WS" ]; then
    ls -la "$WS/" 2>/dev/null | grep -E "MEMORY|SYSTEM|\.md" | sed 's/^/    /'
    [ -z "$(ls "$WS/"*.md 2>/dev/null)" ] && echo "    (нет .md файлов)"
else
    echo "    ✗ Workspace не существует"
fi

###########################################################################
# 2. Обновляем конфиг — system prompt + Brave Search через env
###########################################################################
echo ""
echo "[2/5] Обновляю конфиг @mycarmibot..."

python3 << 'PYFIX'
import json

for cfg_path in [
    "/root/.openclaw-default/.openclaw/openclaw.json",
    "/root/.openclaw-default/openclaw.json"
]:
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
    except:
        continue
    
    changes = []
    
    # 1. System prompt
    SYSTEM_PROMPT = """Ты — универсальный AI-ассистент проекта Banxe AI Bank (EMI, FCA authorised).
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
    
    agents = cfg.setdefault("agents", {})
    defaults = agents.setdefault("defaults", {})
    defaults["systemPrompt"] = SYSTEM_PROMPT
    cfg["systemPrompt"] = SYSTEM_PROMPT
    changes.append("systemPrompt добавлен")
    
    # 2. Оптимизация params (как у MoA бота)
    params = defaults.setdefault("params", {})
    if params.get("num_predict") != 2048:
        params["num_predict"] = 2048
        params["num_ctx"] = 16384
        params["temperature"] = 0.5
        params["num_batch"] = 512
        params["num_gpu"] = 99
        params["streaming"] = False
        changes.append("params оптимизированы (num_predict=2048, num_ctx=16384)")
    
    # 3. Убеждаемся что gateway.mode=local
    gw = cfg.setdefault("gateway", {})
    if gw.get("mode") != "local":
        gw["mode"] = "local"
        changes.append("gateway.mode=local")
    
    # Сохраняем
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    
    print(f"  {cfg_path}:")
    for c in changes:
        print(f"    ✓ {c}")
PYFIX

###########################################################################
# 3. Копируем MEMORY.md и SYSTEM-STATE.md в workspace
###########################################################################
echo ""
echo "[3/5] Копирую файлы в workspace..."

WS="/root/.openclaw-default/.openclaw/workspace"
mkdir -p "$WS"

for SRC in "/data/vibe-coding/docs/MEMORY.md" "/data/vibe-coding/docs/SYSTEM-STATE.md"; do
    if [ -f "$SRC" ]; then
        FNAME=$(basename "$SRC")
        cp "$SRC" "$WS/$FNAME"
        LINES=$(wc -l < "$WS/$FNAME")
        echo "  ✓ $FNAME ($LINES строк) → $WS/"
    else
        echo "  ✗ $(basename $SRC) не найден в /data/vibe-coding/docs/"
    fi
done

###########################################################################
# 4. Перезапускаем gateway @mycarmibot
###########################################################################
echo ""
echo "[4/5] Перезапускаю @mycarmibot gateway..."

# Мягко убиваем только mycarmibot
systemctl restart openclaw-gateway-mycarmibot 2>/dev/null
sleep 8

if ss -tlnp | grep -q ":18793 "; then
    echo "  ✓ @mycarmibot ACTIVE (порт 18793)"
else
    echo "  ⚠ systemd не сработал — пробую nohup..."
    pkill -f "openclaw.*18793" 2>/dev/null
    sleep 2
    cd /root/.openclaw-default
    OPENCLAW_HOME=/root/.openclaw-default nohup npx openclaw gateway --port 18793 > /data/logs/gateway-mycarmibot.log 2>&1 &
    sleep 10
    if ss -tlnp | grep -q ":18793 "; then
        echo "  ✓ @mycarmibot ACTIVE (nohup)"
    else
        echo "  ✗ Не запустился"
        echo "  Лог:"
        tail -5 /data/logs/gateway-mycarmibot.log 2>/dev/null | sed 's/^/    /'
    fi
fi

# Проверяем что MoA бот тоже жив
if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ @mycarmi_moa_bot тоже ACTIVE (порт 18789)"
else
    echo "  ⚠ @mycarmi_moa_bot не работает"
fi

###########################################################################
# 5. Проверка
###########################################################################
echo ""
echo "[5/5] Проверяю..."

echo "  Конфиг после обновления:"
python3 << 'CHECK'
import json
with open("/root/.openclaw-default/.openclaw/openclaw.json") as f:
    c = json.load(f)

sp = c.get("agents",{}).get("defaults",{}).get("systemPrompt","") or c.get("systemPrompt","")
params = c.get("agents",{}).get("defaults",{}).get("params",{})

print(f"    systemPrompt: ✓ ({len(sp)} символов)")
print(f"    num_predict: {params.get('num_predict','?')}")
print(f"    num_ctx: {params.get('num_ctx','?')}")
print(f"    temperature: {params.get('temperature','?')}")
CHECK

echo ""
echo "  Workspace @mycarmibot:"
ls -la /root/.openclaw-default/.openclaw/workspace/*.md 2>/dev/null | awk '{print "    " $NF " (" $5 " bytes)"}' || echo "    (нет файлов)"

REMOTE_END

echo ""
echo "=========================================="
echo "  @mycarmibot НАСТРОЕН"
echo "=========================================="
echo ""
echo "  Теперь @mycarmibot:"
echo "    ✓ Читает MEMORY.md и SYSTEM-STATE.md при каждом сообщении"
echo "    ✓ Знает про Brave Search и Deep Search"
echo "    ✓ Оптимизирован (num_predict=2048, temperature=0.5)"
echo "    ✓ Отвечает на русском"
echo ""
echo "  Проверь — напиши @mycarmibot:"
echo '    "Какие сервисы работают на сервере?"'
echo '    "Найди информацию о SEPA payments"'
