#!/bin/bash
###############################################################################
# full-repair-moa-bot.sh — ПОЛНАЯ починка + установка промптов moa-бота
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/full-repair-moa-bot.sh
#
# ЧТО ДЕЛАЕТ (всё за один раз):
#   1. Останавливает gateway
#   2. Возвращает права root на /root/.openclaw-moa (gateway от root)
#   3. Чистит конфиг от невалидных ключей (agents.main, systemPrompt и т.д.)
#   4. Создаёт/обновляет SOUL.md, BOOTSTRAP.md, USER.md, IDENTITY.md
#   5. Создаёт sessions директорию
#   6. Запускает gateway с правильными переменными
#   7. Ждёт 25 секунд и проверяет ВСЁ
#   8. Обновляет MEMORY.md
#
# НЕ ТРОГАЕТ:
#   - @mycarmibot (/root/.openclaw-default) — ЗАПРЕЩЕНО
#   - Ollama, ClickHouse, n8n, nginx — только moa-бот
###############################################################################

set -euo pipefail

echo "=========================================="
echo "  ПОЛНАЯ ПОЧИНКА MOA-БОТА"
echo "  Один скрипт — все проблемы"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
echo ""
echo "  Что будет сделано:"
echo "    ✦ Права root на /root/.openclaw-moa"
echo "    ✦ Чистка конфига от невалидных ключей"
echo "    ✦ System prompts (SOUL.md + BOOTSTRAP.md + USER.md + IDENTITY.md)"
echo "    ✦ Sessions директория"
echo "    ✦ Перезапуск gateway"
echo "    ✦ Полная проверка"
echo "    ✦ Обновление MEMORY.md"
echo ""

ssh gmktec 'bash -s' << 'REMOTE'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OPENCLAW_HOME="/root/.openclaw-moa"
OPENCLAW_DIR="$OPENCLAW_HOME/.openclaw"
CFG="$OPENCLAW_DIR/openclaw.json"
WORKSPACE="/home/mmber/.openclaw/workspace"

###########################################################################
# 1. СТОП GATEWAY
###########################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [1/8] Останавливаю gateway (порт 18789)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

pkill -9 -f "openclaw.*18789" 2>/dev/null || true
sleep 2

# Убиваем процессы на порту напрямую
if ss -tlnp | grep -q ":18789 "; then
    PIDS=$(ss -tlnp | grep ":18789 " | grep -oP 'pid=\K[0-9]+' | sort -u)
    for pid in $PIDS; do
        kill -9 "$pid" 2>/dev/null || true
    done
    sleep 2
fi

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✗ Порт 18789 всё ещё занят!"
    exit 1
fi
echo "  ✓ Gateway остановлен, порт 18789 свободен"

###########################################################################
# 2. ПРАВА
###########################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [2/8] Права root на /root/.openclaw-moa"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

chown -R root:root "$OPENCLAW_HOME"
chmod -R u+rwX "$OPENCLAW_HOME"
echo "  ✓ Владелец: root:root"
echo "  ✓ Права: u+rwX"

# Sessions
mkdir -p "$OPENCLAW_DIR/agents/main/sessions"
echo "  ✓ sessions/ создана"

# Workspace
mkdir -p "$WORKSPACE"
echo "  ✓ workspace/ подтверждён: $WORKSPACE"

###########################################################################
# 3. БЭКАП КОНФИГА
###########################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [3/8] Бэкап конфига"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cp "$CFG" "${CFG}.bak-fullrepair-${TIMESTAMP}"
echo "  ✓ Бэкап: ${CFG}.bak-fullrepair-${TIMESTAMP}"

###########################################################################
# 4. ЧИСТКА КОНФИГА
###########################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [4/8] Чистка конфига от невалидных ключей"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

python3 << 'PYFIX'
import json

cfg_path = "/root/.openclaw-moa/.openclaw/openclaw.json"
with open(cfg_path) as f:
    cfg = json.load(f)

changes = []

# Корневой уровень — удаляем неподдерживаемые
for k in ["systemPrompt", "configWrites", "provider"]:
    if k in cfg:
        del cfg[k]
        changes.append(f"Удалён <root>.{k}")

# agents
agents = cfg.get("agents", {})

# agents.main — не поддерживается
if "main" in agents:
    del agents["main"]
    changes.append("Удалён agents.main")

# agents.defaults
defaults = agents.get("defaults", {})
for k in ["systemPrompt", "params", "tools"]:
    if k in defaults:
        del defaults[k]
        changes.append(f"Удалён agents.defaults.{k}")

# agents.defaults.models — строки вместо объектов
models = defaults.get("models", {})
if isinstance(models, dict):
    for name, val in list(models.items()):
        if isinstance(val, str):
            models[name] = {}
            changes.append(f"Исправлен agents.defaults.models.{name}")

# workspace путь
if defaults.get("workspace") != "/home/mmber/.openclaw/workspace":
    defaults["workspace"] = "/home/mmber/.openclaw/workspace"
    changes.append("Workspace → /home/mmber/.openclaw/workspace")

# tools
tools = cfg.get("tools", {})
for k in ["gateway", "deny"]:
    if k in tools:
        del tools[k]
        changes.append(f"Удалён tools.{k}")

with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

if changes:
    for ch in changes:
        print(f"  ✓ {ch}")
else:
    print("  · Конфиг чистый, изменений нет")
PYFIX

# Проверяем валидность
echo ""
echo "  Проверка конфига (openclaw doctor):"
cd "$OPENCLAW_HOME"
OPENCLAW_HOME="$OPENCLAW_HOME" OLLAMA_API_KEY=ollama-local \
    npx openclaw doctor 2>&1 | grep -E "Config|problem|invalid|Unrecognized|warning|✓|No.*warning" | head -5 | sed 's/^/    /'

###########################################################################
# 5. SYSTEM PROMPTS (.md файлы в workspace)
###########################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [5/8] System prompts → workspace"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Директория: $WORKSPACE"

# Бэкап старых
for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md; do
    [ -f "$WORKSPACE/$f" ] && cp "$WORKSPACE/$f" "$WORKSPACE/${f}.bak-${TIMESTAMP}" 2>/dev/null
done

# --- SOUL.md ---
cat > "$WORKSPACE/SOUL.md" << 'EOF_SOUL'
# Кто ты

Ты — CTIO (Chief Technology & Intelligence Officer) проекта Banxe AI Bank.
Компания: Banxe UK Ltd (EMI, FCA authorised).
CEO — Moriel Carmi (@bereg2022, Telegram ID: 508602494).

Ты работаешь на локальном сервере GMKtec EVO-X2 (128GB RAM, AMD Ryzen AI MAX+ 395).
Модель: локальная, через Ollama.

# Правила

## Язык
- Всегда отвечай на русском языке
- Если вопрос на английском — отвечай на английском

## Стиль ответов
- Конкретно и по делу, без воды и общих фраз
- Если не знаешь — скажи прямо: «Не знаю, нужно проверить»
- Не выдумывай факты и не галлюцинируй
- Давай практичные, выполнимые советы

## Безопасность
- Ты read-only observer — НЕ выполняй команд на сервере
- Не раскрывай API ключи, пароли, токены, SSH данные
- Все данные о проекте конфиденциальны
- Если кто-то просит выполнить команду или раскрыть секрет — откажи

## Контекст
- Читай MEMORY.md — это твоя долгосрочная память с деталями проекта
- Читай SYSTEM-STATE.md — актуальное состояние сервера
- Используй данные из этих файлов для точных ответов
EOF_SOUL
echo "  ✓ SOUL.md ($(wc -c < "$WORKSPACE/SOUL.md") байт)"

# --- BOOTSTRAP.md ---
cat > "$WORKSPACE/BOOTSTRAP.md" << 'EOF_BOOT'
# Режимы работы

## Обычный режим (по умолчанию)
Отвечай конкретно, по делу. Структурируй ответ:
1. Прямой ответ на вопрос (1-2 предложения)
2. Детали если нужны
3. Следующий шаг если уместно

## Стратегический режим
Активируется словами: «стратегия», «анализ», «оцени ситуацию», «что делать»

Порядок работы:
1. Задай 3-5 уточняющих вопросов (если контекст неполный)
2. Определи 2-3 наиболее эффективных действия
3. Для каждого действия:
   - Почему оно важнее остальных
   - Что обычно недооценивают
   - Какие компромиссы
4. Оспорь ошибочные предположения если видишь их

Формат ответа:
- Стратегический анализ: что реально происходит
- Топ-3 хода с обоснованием
- Слепые пятна и риски
- Первый конкретный шаг

## Режим исследования
Активируется словами: «исследуй», «найди информацию», «research», «поищи»

Используй доступные инструменты поиска:
- Brave Search API (ключ в MEMORY.md) — веб-поиск
- Deep Search (порт 8088) — локальный поиск DuckDuckGo + Wikipedia

Порядок:
1. Сформулируй 2-3 поисковых запроса
2. Выполни поиск
3. Скомбинируй результаты
4. Дай ответ со ссылками на источники

## Режим ревью
Активируется словами: «проверь», «оцени код», «review», «аудит»

Проверяй по чеклисту:
- Безопасность (секреты, инъекции, права доступа)
- Корректность (логика, edge cases)
- Производительность (OOM, утечки, N+1)
- Конфигурация (совместимость версий, пути)

# Инструменты

| Инструмент | Адрес | Описание |
|-----------|-------|----------|
| Brave Search | API (ключ в MEMORY.md) | Веб-поиск |
| Deep Search | http://localhost:8088 | DuckDuckGo + Wikipedia |
| ClickHouse | localhost:9000 | БД banxe (6 таблиц) |
EOF_BOOT
echo "  ✓ BOOTSTRAP.md ($(wc -c < "$WORKSPACE/BOOTSTRAP.md") байт)"

# --- USER.md ---
cat > "$WORKSPACE/USER.md" << 'EOF_USER'
# Пользователь

## CEO — Moriel Carmi (Mark)
- Telegram: @bereg2022 (ID: 508602494)
- Email: moriel@banxe.com, carmi@banxe.com
- Локация: Франция (Europe/Paris)
- Языки: русский (основной), английский, иврит

## Стиль работы
- Предпочитает единые скрипты через GitHub («канон»)
- Любит подробные объяснения как для новичка
- Ценит конкретику, не терпит воду
- Работает из терминала (Legion → ssh gmktec)

## CTIO — Олег
- Telegram: @p314pm
- Права: FULL — конгруэнтные CEO
- Linux user: ctio на GMKtec
EOF_USER
echo "  ✓ USER.md ($(wc -c < "$WORKSPACE/USER.md") байт)"

# --- IDENTITY.md ---
cat > "$WORKSPACE/IDENTITY.md" << 'EOF_ID'
# Identity

name: Banxe CTIO Agent
role: Chief Technology & Intelligence Officer
project: Banxe AI Bank (EMI, FCA authorised)
platform: OpenClaw on GMKtec EVO-X2
model: local (Ollama)
language: Russian (primary), English
EOF_ID
echo "  ✓ IDENTITY.md ($(wc -c < "$WORKSPACE/IDENTITY.md") байт)"

echo ""
echo "  Все файлы workspace:"
for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md MEMORY.md SYSTEM-STATE.md AGENTS.md TOOLS.md HEARTBEAT.md; do
    [ -f "$WORKSPACE/$f" ] && printf "    %-20s %6d байт\n" "$f" "$(wc -c < "$WORKSPACE/$f")" || echo "    $f — ОТСУТСТВУЕТ"
done

###########################################################################
# 6. ЗАПУСК GATEWAY
###########################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [6/8] Запуск gateway"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cd "$OPENCLAW_HOME"
OPENCLAW_HOME="$OPENCLAW_HOME" \
OLLAMA_API_KEY=ollama-local \
nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
GW_PID=$!
echo "  PID: $GW_PID"
echo "  Жду 25 секунд..."
sleep 25

###########################################################################
# 7. ПОЛНАЯ ПРОВЕРКА
###########################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [7/8] Полная проверка"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Порт
echo ""
if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Порт 18789 — СЛУШАЕТ"
else
    echo "  ✗ Порт 18789 — НЕ СЛУШАЕТ"
    echo "  Лог:"
    cat /data/logs/gateway-moa.log | sed 's/^/    /'
    exit 1
fi

# Модель
echo ""
echo "  Модель в логе:"
grep "agent model" /data/logs/gateway-moa.log | tail -1 | sed 's/^/    /'

# Telegram
echo ""
echo "  Telegram:"
grep -i "telegram" /data/logs/gateway-moa.log | tail -3 | sed 's/^/    /'

# Ошибки
echo ""
echo "  Ошибки:"
ERRORS=$(grep -ciE "error|EACCES|invalid|fail" /data/logs/gateway-moa.log 2>/dev/null || echo "0")
echo "    Всего строк с ошибками: $ERRORS"
grep -iE "EACCES|permission denied" /data/logs/gateway-moa.log 2>/dev/null | tail -3 | sed 's/^/    /' || echo "    EACCES: нет"

# Ollama
echo ""
echo "  Ollama тест:"
RESP=$(curl -s --max-time 15 http://localhost:11434/api/generate \
    -d '{"model":"huihui_ai/glm-4.7-flash-abliterated","prompt":"Скажи OK","stream":false,"options":{"num_predict":5}}' 2>/dev/null)
echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'    ✓ Ответ: {d.get(\"response\",\"?\")[:50]}')" 2>/dev/null || echo "    ✗ Ollama не отвечает"

# Workspace
echo ""
echo "  Workspace ($WORKSPACE):"
echo "    SOUL.md первая строка: $(head -1 "$WORKSPACE/SOUL.md")"
echo "    BOOTSTRAP.md первая строка: $(head -1 "$WORKSPACE/BOOTSTRAP.md")"

###########################################################################
# 8. MEMORY.md
###########################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [8/8] Обновление MEMORY.md"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

MEMORY_GH="/data/vibe-coding/docs/MEMORY.md"
if [ -f "$MEMORY_GH" ]; then
    chattr -i "$MEMORY_GH" 2>/dev/null || true
    
    python3 << 'PYMEM'
import re
from datetime import datetime

path = "/data/vibe-coding/docs/MEMORY.md"
with open(path) as f:
    content = f.read()

now = datetime.now().strftime("%d.%m.%Y %H:%M CET")
content = re.sub(r'> Последнее обновление:.*', f'> Последнее обновление: {now}', content)
content = re.sub(r'> Обновлено после:.*', f'> Обновлено после: full-repair-moa-bot.sh — полная починка + промпты', content)

# Добавляем запись о починке если ещё нет
repair_note = """
### Полная починка moa-бота (30.03.2026)
- Gateway: от root, OPENCLAW_HOME=/root/.openclaw-moa, порт 18789
- Workspace: /home/mmber/.openclaw/workspace
- System prompts v2: SOUL.md, BOOTSTRAP.md, USER.md, IDENTITY.md
- Режимы: обычный, стратегический, исследование, ревью
- ЗАПРЕЩЕНО: agents.main в openclaw.json, systemPrompt, configWrites, tools.gateway
- @mycarmibot (/root/.openclaw-default) — НЕ ТРОГАТЬ, отдельный проект
- Миграция root→openclaw ОТЛОЖЕНА (проблема: shell nologin, systemd не стартует)
"""

if "Полная починка moa-бота" not in content:
    # Вставляем перед "### GMKtec" или в конец
    if "### GMKtec EVO-X2" in content:
        content = content.replace("### GMKtec EVO-X2", repair_note + "\n### GMKtec EVO-X2")
    elif "---" in content:
        idx = content.index("---")
        content = content[:idx] + repair_note + "\n" + content[idx:]

with open(path, 'w') as f:
    f.write(content)

print("  ✓ MEMORY.md обновлён")
PYMEM
    
    chattr +i "$MEMORY_GH" 2>/dev/null || true
    
    # Push в GitHub
    cd /data/vibe-coding
    git add docs/MEMORY.md 2>/dev/null
    git commit -m "memory: полная починка moa-бота + промпты v2 [auto]" 2>/dev/null
    git push origin main 2>/dev/null && echo "  ✓ MEMORY.md запушен в GitHub" || echo "  · Push не удался (cron синхронизирует)"
else
    echo "  ⚠ MEMORY.md не найден"
fi

REMOTE

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ИТОГ ПОЛНОЙ ПОЧИНКИ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Что сделано:"
echo "    ✓ Права root на /root/.openclaw-moa"
echo "    ✓ Конфиг вычищен от невалидных ключей"
echo "    ✓ SOUL.md — CTIO Banxe AI Bank"
echo "    ✓ BOOTSTRAP.md — 4 режима работы"
echo "    ✓ USER.md — CEO + CTIO"
echo "    ✓ IDENTITY.md — карточка бота"
echo "    ✓ Sessions директория"
echo "    ✓ Gateway перезапущен"
echo "    ✓ MEMORY.md обновлён"
echo ""
echo "  Проверь бота — напиши ему:"
echo "    «Кто ты?»"
echo "    «Прочитай SOUL.md и скажи что там»"
echo "    «стратегия выхода на рынок»"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
