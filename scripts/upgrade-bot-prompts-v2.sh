#!/bin/bash
###############################################################################
# upgrade-bot-prompts-v2.sh — Безопасное обновление промптов бота
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/upgrade-bot-prompts-v2.sh
#
# ВАЖНО: НЕ трогает openclaw.json! Только создаёт .md файлы в workspace.
#
# Как это работает (из документации OpenClaw, стр. 94-96):
#   OpenClaw при КАЖДОМ ходе агента загружает 9 файлов .md из workspace:
#   AGENTS.md, SOUL.md, TOOLS.md, IDENTITY.md, USER.md,
#   HEARTBEAT.md, BOOTSTRAP.md, MEMORY.md, memory.md
#   Каждый усекается до 20 000 символов.
#   Они вводятся в системный промпт как доверенный контекст.
#
# Что создаём:
#   - SOUL.md     — кто ты (идентичность, роль, правила)
#   - BOOTSTRAP.md — режимы работы (стратегический, исследование)
#   - USER.md     — информация о пользователе (CEO)
#   - IDENTITY.md — краткая карточка бота
#
# MEMORY.md не трогаем — он уже есть и синхронизируется через cron.
###############################################################################

echo "=========================================="
echo "  UPGRADE BOT PROMPTS v2 (безопасный)"
echo "  НЕ трогает openclaw.json!"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

LOG="/data/logs/upgrade-prompts-v2.log"
mkdir -p /data/logs
exec > >(tee -a "$LOG") 2>&1

###########################################################################
# 0. ОПРЕДЕЛЯЕМ WORKSPACE
###########################################################################
echo ""
echo "[0/5] Определяю workspace директорию..."

# Читаем workspace из конфига
CFG="/root/.openclaw-moa/.openclaw/openclaw.json"
WORKSPACE=""

if [ -f "$CFG" ]; then
    WORKSPACE=$(python3 -c "
import json
with open('$CFG') as f:
    c = json.load(f)
ws = c.get('agents',{}).get('defaults',{}).get('workspace','')
print(ws)
" 2>/dev/null)
fi

# Fallback — стандартные пути
if [ -z "$WORKSPACE" ] || [ ! -d "$WORKSPACE" ]; then
    for d in \
        /root/.openclaw-moa/workspace-moa \
        /root/.openclaw-moa/.openclaw/workspace \
        /root/.openclaw/workspace \
        /home/mmber/.openclaw/workspace; do
        if [ -d "$d" ]; then
            WORKSPACE="$d"
            break
        fi
    done
fi

if [ -z "$WORKSPACE" ]; then
    echo "  ✗ Workspace не найден! Создаю стандартный..."
    WORKSPACE="/root/.openclaw-moa/workspace-moa"
    mkdir -p "$WORKSPACE"
fi

echo "  ✓ Workspace: $WORKSPACE"
echo "  Текущие файлы:"
ls -la "$WORKSPACE"/*.md 2>/dev/null | sed 's/^/    /' || echo "    (пусто)"

###########################################################################
# 1. БЭКАПЫ СУЩЕСТВУЮЩИХ ФАЙЛОВ
###########################################################################
echo ""
echo "[1/5] Бэкапы..."

BACKUP_TS=$(date +%Y%m%d-%H%M%S)
for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md; do
    if [ -f "$WORKSPACE/$f" ]; then
        cp "$WORKSPACE/$f" "$WORKSPACE/${f}.bak-${BACKUP_TS}"
        echo "  ✓ Бэкап: $f"
    fi
done

###########################################################################
# 2. SOUL.md — Идентичность и правила
###########################################################################
echo ""
echo "[2/5] Создаю SOUL.md (идентичность + правила)..."

cat > "$WORKSPACE/SOUL.md" << 'SOUL_EOF'
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
SOUL_EOF

echo "  ✓ SOUL.md создан ($(wc -c < "$WORKSPACE/SOUL.md") байт)"

###########################################################################
# 3. BOOTSTRAP.md — Режимы работы + Claude Code паттерны
###########################################################################
echo ""
echo "[3/5] Создаю BOOTSTRAP.md (режимы работы)..."

cat > "$WORKSPACE/BOOTSTRAP.md" << 'BOOT_EOF'
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
```
## Стратегический анализ
Что реально происходит: [суть ситуации]

## Топ-3 хода
1. [действие] — [почему, компромиссы]
2. [действие] — [почему, компромиссы]
3. [действие] — [почему, компромиссы]

## Слепые пятна и риски
- [что могли не заметить]

## Первый конкретный шаг
[что сделать прямо сейчас]
```

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

# Инструменты поиска

| Инструмент | Адрес | Описание |
|-----------|-------|----------|
| Brave Search | API (ключ в MEMORY.md) | Веб-поиск |
| Deep Search | http://localhost:8088 | DuckDuckGo + Wikipedia |
| ClickHouse | localhost:9000 | БД banxe (6 таблиц) |
BOOT_EOF

echo "  ✓ BOOTSTRAP.md создан ($(wc -c < "$WORKSPACE/BOOTSTRAP.md") байт)"

###########################################################################
# 4. USER.md — Информация о пользователе
###########################################################################
echo ""
echo "[4/5] Создаю USER.md (информация о CEO)..."

cat > "$WORKSPACE/USER.md" << 'USER_EOF'
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
USER_EOF

echo "  ✓ USER.md создан ($(wc -c < "$WORKSPACE/USER.md") байт)"

###########################################################################
# 4b. IDENTITY.md — Краткая карточка
###########################################################################

cat > "$WORKSPACE/IDENTITY.md" << 'ID_EOF'
# Identity

name: Banxe CTIO Agent
role: Chief Technology & Intelligence Officer
project: Banxe AI Bank (EMI, FCA authorised)
platform: OpenClaw on GMKtec EVO-X2
model: local (Ollama)
language: Russian (primary), English
ID_EOF

echo "  ✓ IDENTITY.md создан ($(wc -c < "$WORKSPACE/IDENTITY.md") байт)"

###########################################################################
# 5. ПРОВЕРКА — копируем также в /opt/openclaw если есть
###########################################################################
echo ""
echo "[5/5] Проверка и копирование..."

echo "  Файлы в workspace:"
ls -la "$WORKSPACE"/*.md 2>/dev/null | grep -v ".bak" | sed 's/^/    /'

echo ""
echo "  Размеры:"
for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md MEMORY.md SYSTEM-STATE.md; do
    if [ -f "$WORKSPACE/$f" ]; then
        SIZE=$(wc -c < "$WORKSPACE/$f")
        if [ "$SIZE" -gt 20000 ]; then
            echo "    ⚠ $f: ${SIZE} байт (ПРЕВЫШАЕТ лимит 20000!)"
        else
            echo "    ✓ $f: ${SIZE} байт"
        fi
    fi
done

# Копируем в /opt/openclaw/workspace-moa если существует (для будущей миграции)
if [ -d "/opt/openclaw/workspace-moa" ]; then
    for f in SOUL.md BOOTSTRAP.md USER.md IDENTITY.md; do
        cp "$WORKSPACE/$f" "/opt/openclaw/workspace-moa/$f" 2>/dev/null
    done
    echo ""
    echo "  ✓ Скопировано в /opt/openclaw/workspace-moa/"
fi

# Перезапуск gateway НЕ нужен — OpenClaw подхватывает .md при каждом ходе
echo ""
echo "  ℹ Перезапуск gateway НЕ нужен!"
echo "  OpenClaw загружает .md файлы при КАЖДОМ сообщении автоматически."

echo ""
echo "  ✓ Gateway работает?"
if ss -tlnp | grep -q ":18789 "; then
    echo "    ✓ Да, порт 18789 слушает"
else
    echo "    ✗ Gateway не запущен! Запускаю..."
    pkill -9 -f "openclaw.*gateway" 2>/dev/null
    sleep 2
    cd /root/.openclaw-moa
    OPENCLAW_HOME=/root/.openclaw-moa \
    OLLAMA_API_KEY=ollama-local \
    nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
    sleep 15
    ss -tlnp | grep -q ":18789 " && echo "    ✓ Gateway запущен" || echo "    ✗ НЕ запустился"
fi

REMOTE

echo ""
echo "=========================================="
echo "  ИТОГ"
echo "=========================================="
echo ""
echo "  Созданные файлы в workspace бота:"
echo "    SOUL.md      — кто ты, правила, безопасность"
echo "    BOOTSTRAP.md — режимы: обычный, стратегический, исследование, ревью"
echo "    USER.md      — информация о CEO и CTIO"
echo "    IDENTITY.md  — краткая карточка бота"
echo ""
echo "  openclaw.json НЕ ТРОНУТ!"
echo "  Перезапуск НЕ нужен — OpenClaw читает .md при каждом сообщении."
echo ""
echo "  Проверь бота:"
echo "    1. «Привет, кто ты?» — должен ответить как CTIO Banxe"
echo "    2. «стратегия выхода на рынок UK» — стратегический режим"
echo "    3. «исследуй FCA requirements for EMI» — режим исследования"
echo "=========================================="
