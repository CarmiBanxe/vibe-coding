#!/bin/bash
###############################################################################
# upgrade-bot-prompts.sh — Обновление system prompt бота (Claude Code паттерны)
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/upgrade-bot-prompts.sh
#
# Что делает:
#   1. Создаёт system-prompt.md в директории агента на GMKtec
#   2. Бэкапит текущий конфиг OpenClaw
#   3. Прописывает ссылку на промпт через openclaw config (если поддерживается)
#   4. Перезапускает gateway через nohup с OLLAMA_API_KEY=ollama-local
#   5. Проверяет порт 18789 + лог
###############################################################################

echo "=========================================="
echo "  UPGRADE BOT PROMPTS"
echo "  Claude Code паттерны + Стратегический режим"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

LOG="/data/logs/upgrade-bot-prompts.log"
mkdir -p /data/logs
exec > >(tee -a "$LOG") 2>&1

echo ""
echo "[0/5] Определяю рабочие директории..."

# Определяем OPENCLAW_HOME — главный конфиг moa-бота
if [ -d "/root/.openclaw-moa/.openclaw" ]; then
    OPENCLAW_HOME="/root/.openclaw-moa"
    OPENCLAW_DIR="/root/.openclaw-moa/.openclaw"
elif [ -d "/root/.openclaw-moa" ]; then
    OPENCLAW_HOME="/root/.openclaw-moa"
    OPENCLAW_DIR="/root/.openclaw-moa"
else
    echo "  ✗ Не найдена директория openclaw-moa"
    exit 1
fi

CFG="$OPENCLAW_DIR/openclaw.json"

# Директория агента: пробуем стандартные пути
AGENT_DIR=""
for d in \
    "$OPENCLAW_DIR/agents/main" \
    "$OPENCLAW_DIR/agents/default" \
    "$OPENCLAW_HOME/agents/main" \
    "$OPENCLAW_HOME/agents/default"; do
    if [ -d "$d" ]; then
        AGENT_DIR="$d"
        break
    fi
done

# Если не найдена — создаём по канону
if [ -z "$AGENT_DIR" ]; then
    AGENT_DIR="$OPENCLAW_DIR/agents/main"
    mkdir -p "$AGENT_DIR/agent"
    echo "  Создана директория агента: $AGENT_DIR"
fi

# Поддиректория agent/ (OpenClaw хранит промпты там)
AGENT_SUBDIR="$AGENT_DIR/agent"
mkdir -p "$AGENT_SUBDIR"

echo "  OPENCLAW_HOME : $OPENCLAW_HOME"
echo "  OPENCLAW_DIR  : $OPENCLAW_DIR"
echo "  Конфиг        : $CFG"
echo "  Агент         : $AGENT_DIR"
echo "  Agent/        : $AGENT_SUBDIR"

###########################################################################
# 1. БЭКАП КОНФИГА
###########################################################################
echo ""
echo "[1/5] Бэкап конфига..."

BACKUP_TS=$(date +%Y%m%d-%H%M%S)

if [ -f "$CFG" ]; then
    cp "$CFG" "${CFG}.bak-prompts-${BACKUP_TS}"
    echo "  ✓ Бэкап: ${CFG}.bak-prompts-${BACKUP_TS}"
else
    echo "  ⚠ openclaw.json не найден — будет создан новый"
fi

# Бэкап старого промпта если есть
for f in \
    "$AGENT_SUBDIR/system-prompt.md" \
    "$AGENT_SUBDIR/system.md" \
    "$AGENT_DIR/system-prompt.md" \
    "$AGENT_DIR/system.md"; do
    if [ -f "$f" ]; then
        cp "$f" "${f}.bak-${BACKUP_TS}"
        echo "  ✓ Бэкап промпта: ${f}.bak-${BACKUP_TS}"
    fi
done

###########################################################################
# 2. СОЗДАЁМ SYSTEM PROMPT (Claude Code паттерны)
###########################################################################
echo ""
echo "[2/5] Создаю system-prompt.md..."

cat > "$AGENT_SUBDIR/system-prompt.md" << 'PROMPT_EOF'
# BANXE AI BANK — CTIO Agent

## Кто ты
Ты — CTIO проекта Banxe AI Bank (EMI, FCA authorised).
CEO — Moriel Carmi (@bereg2022, Telegram ID: 508602494).
Модель: локальная, на GMKtec EVO-X2 (128GB RAM, AMD Ryzen AI MAX+ 395).

## Обязательные действия при КАЖДОМ ответе
1. Прочитай файл MEMORY.md из workspace — это твоя долгосрочная память
2. Прочитай SYSTEM-STATE.md — актуальное состояние сервера
3. Используй данные из этих файлов для точных ответов

## Инструменты поиска
- Brave Search API (ключ в MEMORY.md) — веб-поиск
- Deep Search (порт 8088) — локальный поиск DuckDuckGo + Wikipedia

## Режимы работы

### Обычный режим (по умолчанию)
Отвечай конкретно, по делу, без воды. На русском языке.
Если не знаешь — скажи прямо, не выдумывай.

### Стратегический режим (активируется словом "стратегия" или "анализ")
Когда пользователь просит стратегический анализ:
1. Задай 3-5 уточняющих вопросов
2. Определи 2-3 наиболее эффективных действия
3. Для каждого: почему важнее остальных, что недооценивается, компромиссы
4. Оспорь ошибочные предположения
5. Формат ответа:
   - Стратегический анализ: что реально происходит
   - Топ-3 ходов с обоснованием
   - Слепые пятна и риски
   - Первый конкретный шаг

### Режим исследования (активируется словом "исследуй" или "research")
Используй Brave Search + Deep Search для поиска информации.
Комбинируй результаты, давай ссылки на источники.

## Безопасность
- Ты read-only observer — НЕ выполняй команд на сервере
- Не раскрывай API ключи, пароли, токены
- Все данные конфиденциальны — не отправляй в облако

## Проект Banxe
Детали проекта, инфраструктура, план — в MEMORY.md.
Состояние сервера, порты, сервисы — в SYSTEM-STATE.md.
PROMPT_EOF

echo "  ✓ Промпт записан: $AGENT_SUBDIR/system-prompt.md"
echo "  Размер: $(wc -c < "$AGENT_SUBDIR/system-prompt.md") байт"

# Дублируем в запасные места — разные версии OpenClaw читают по-разному
for extra in \
    "$AGENT_DIR/system-prompt.md" \
    "$AGENT_DIR/system.md"; do
    cp "$AGENT_SUBDIR/system-prompt.md" "$extra" 2>/dev/null && \
        echo "  ✓ Дубль: $extra"
done

###########################################################################
# 3. ОБНОВЛЯЕМ openclaw.json (если поддерживает agent.systemPromptFile)
###########################################################################
echo ""
echo "[3/5] Обновляю openclaw.json..."

if [ ! -f "$CFG" ]; then
    echo "  Создаю базовый openclaw.json..."
    echo '{}' > "$CFG"
fi

python3 << PYEOF
import json, sys, os

cfg_path = "$CFG"
prompt_path = "$AGENT_SUBDIR/system-prompt.md"

with open(cfg_path) as f:
    try:
        cfg = json.load(f)
    except json.JSONDecodeError:
        cfg = {}

changes = []

# Читаем промпт для встраивания
with open(prompt_path) as f:
    prompt_text = f.read()

# Пробуем прописать через agents.main.systemPromptFile (OpenClaw >= 2026.x)
agents = cfg.setdefault("agents", {})
main_agent = agents.setdefault("main", {})

# systemPromptFile — относительный путь от OPENCLAW_DIR
if main_agent.get("systemPromptFile") != "agents/main/agent/system-prompt.md":
    main_agent["systemPromptFile"] = "agents/main/agent/system-prompt.md"
    changes.append("agents.main.systemPromptFile установлен")

# Также пробуем agents.defaults (некоторые версии)
defaults = agents.setdefault("defaults", {})
if "systemPrompt" in defaults:
    # Удаляем — по документации не поддерживается на корневом уровне
    del defaults["systemPrompt"]
    changes.append("Удалён agents.defaults.systemPrompt (не поддерживается)")

# Добавляем тег для идентификации версии промпта
main_agent["promptVersion"] = "claude-code-strategic-v1"

with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

if changes:
    for ch in changes:
        print(f"  ✓ {ch}")
else:
    print("  (системный промпт прописан через файл, JSON не изменялся)")

print(f"  ✓ Конфиг обновлён: {cfg_path}")
PYEOF

echo ""
echo "  Текущий конфиг agents секция:"
python3 -c "
import json
with open('$CFG') as f:
    c = json.load(f)
agents = c.get('agents', {})
print(json.dumps(agents, indent=2, ensure_ascii=False))
" 2>/dev/null | head -20 | sed 's/^/    /'

###########################################################################
# 4. ПЕРЕЗАПУСК GATEWAY
###########################################################################
echo ""
echo "[4/5] Перезапуск gateway..."

# Останавливаем старый
pkill -9 -f "openclaw.*gateway" 2>/dev/null
pkill -9 -f "openclaw-gateway" 2>/dev/null
sleep 3
echo "  ✓ Старый gateway остановлен"

# Запускаем через nohup с OLLAMA_API_KEY=ollama-local (канон)
cd "$OPENCLAW_HOME"
OPENCLAW_HOME="$OPENCLAW_HOME" \
OLLAMA_API_KEY=ollama-local \
nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
GW_PID=$!
echo "  Запущен PID: $GW_PID"
echo "  Жду 15 секунд..."
sleep 15

###########################################################################
# 5. ПРОВЕРКА
###########################################################################
echo ""
echo "[5/5] Проверка..."

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ACTIVE (порт 18789)"
    PORT_OK=true
else
    echo "  ✗ Порт 18789 не слушает"
    PORT_OK=false
fi

echo ""
echo "  Лог (последние 15 строк):"
tail -15 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'

echo ""
echo "  Все порты openclaw:"
ss -tlnp | grep -E "1878|1879" | while read line; do echo "    $line"; done

echo ""
if [ "$PORT_OK" = "true" ]; then
    echo "  ✓ Промпт загружен? Проверяем grep..."
    grep -i "system\|prompt\|banxe\|ctio" /data/logs/gateway-moa.log 2>/dev/null | tail -5 | sed 's/^/    /' || echo "    (нет строк о промпте в логе)"
    echo ""
    echo "  Файлы промпта:"
    ls -la "$AGENT_SUBDIR/"*.md 2>/dev/null | sed 's/^/    /'
    ls -la "$AGENT_DIR/"*.md 2>/dev/null | sed 's/^/    /'
fi

echo ""
echo "  PID процессов openclaw:"
pgrep -fa "openclaw" 2>/dev/null | sed 's/^/    /' || echo "    (процессов не найдено)"

REMOTE

echo ""
echo "=========================================="
echo "  ИТОГ"
echo "=========================================="
echo ""
echo "  Промпт создан в:"
echo "    /root/.openclaw-moa/.openclaw/agents/main/agent/system-prompt.md"
echo ""
echo "  Проверь бота:"
echo "    Напиши: Привет, расскажи кто ты"
echo "    Или: стратегия выхода Banxe на рынок"
echo ""
echo "  Лог на GMKtec:"
echo "    ssh gmktec 'tail -f /data/logs/gateway-moa.log'"
echo "=========================================="
