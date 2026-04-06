#!/bin/bash
# ============================================
#  BOT DOCTOR — Диагностика и запуск @mycarmi_moa_bot
# ============================================
#
#  Что делает этот скрипт:
#  1. Проверяет, запущен ли бот (процесс openclaw-gateway)
#  2. Проверяет, работает ли LiteLLM (роутер моделей, порт 8080)
#  3. Проверяет, доступен ли Ollama на GMKtec (сервер с моделями)
#  4. Показывает последние ошибки из лога
#  5. Если бот не запущен — предлагает запустить
#
#  Как запустить:
#    bash ~/vibe-coding/scripts/bot-doctor.sh
#
# ============================================

# Цвета для удобного чтения
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # без цвета

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  BOT DOCTOR — @mycarmi_moa_bot${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# -------------------------------------------
# ПРОВЕРКА 1: Процесс бота
# Ищем процесс openclaw-gateway в списке процессов.
# Если найден — бот запущен. Если нет — бот мёртв.
# -------------------------------------------
echo -e "${YELLOW}[1/5] Проверяю процесс бота...${NC}"
BOT_PROCESS=$(ps aux | grep "openclaw-gateway" | grep -v grep)

if [ -n "$BOT_PROCESS" ]; then
    BOT_PID=$(echo "$BOT_PROCESS" | awk '{print $2}')
    BOT_MEM=$(echo "$BOT_PROCESS" | awk '{print $4}')
    BOT_TIME=$(echo "$BOT_PROCESS" | awk '{print $9}')
    echo -e "  ${GREEN}✅ Бот ЗАПУЩЕН${NC}"
    echo -e "  PID: $BOT_PID | RAM: ${BOT_MEM}% | Старт: $BOT_TIME"
    BOT_RUNNING=true
else
    echo -e "  ${RED}❌ Бот НЕ запущен${NC}"
    BOT_RUNNING=false
fi
echo ""

# -------------------------------------------
# ПРОВЕРКА 2: LiteLLM (роутер моделей)
# LiteLLM принимает запросы на порту 8080 и направляет
# их к нужной модели (Groq, Ollama, Claude и т.д.)
# Если он упал — бот не сможет получить ответ от модели.
# -------------------------------------------
echo -e "${YELLOW}[2/5] Проверяю LiteLLM (роутер моделей, порт 8080)...${NC}"
LITELLM_RESPONSE=$(curl -s --max-time 3 http://localhost:8080/health 2>/dev/null)

if [ -n "$LITELLM_RESPONSE" ]; then
    echo -e "  ${GREEN}✅ LiteLLM работает${NC}"
    echo -e "  Ответ: $(echo $LITELLM_RESPONSE | head -c 100)"
    LITELLM_OK=true
else
    LITELLM_PROCESS=$(ps aux | grep "litellm" | grep -v grep)
    if [ -n "$LITELLM_PROCESS" ]; then
        echo -e "  ${YELLOW}⚠️  LiteLLM процесс есть, но не отвечает на health check${NC}"
    else
        echo -e "  ${RED}❌ LiteLLM НЕ запущен${NC}"
    fi
    LITELLM_OK=false
fi
echo ""

# -------------------------------------------
# ПРОВЕРКА 3: Ollama на GMKtec
# GMKtec (192.168.0.72) — это твой мини-ПК с GPU,
# на котором крутятся локальные модели через Ollama.
# Если он недоступен — локальные модели не работают.
# -------------------------------------------
echo -e "${YELLOW}[3/5] Проверяю Ollama на GMKtec (192.168.0.72:11434)...${NC}"
OLLAMA_RESPONSE=$(curl -s --max-time 5 http://192.168.0.72:11434/api/tags 2>/dev/null)

if [ -n "$OLLAMA_RESPONSE" ]; then
    MODEL_COUNT=$(echo "$OLLAMA_RESPONSE" | python3 -c "import sys,json; data=json.load(sys.stdin); print(len(data.get('models',[])))" 2>/dev/null || echo "?")
    echo -e "  ${GREEN}✅ Ollama доступен${NC} — моделей загружено: $MODEL_COUNT"
    OLLAMA_OK=true
else
    echo -e "  ${RED}❌ Ollama НЕ отвечает${NC}"
    echo -e "  GMKtec выключен, или Ollama не запущен, или сеть недоступна"
    OLLAMA_OK=false
fi
echo ""

# -------------------------------------------
# ПРОВЕРКА 4: Конфиг бота
# Показывает какие модели и каналы настроены.
# -------------------------------------------
echo -e "${YELLOW}[4/5] Конфигурация бота...${NC}"
CONFIG_FILE="$HOME/.openclaw-moa/openclaw.json"

if [ -f "$CONFIG_FILE" ]; then
    echo -e "  Файл конфига: $CONFIG_FILE"
    
    # Показываем модели из конфига
    MODELS=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
agents = c.get('agents', {}).get('list', [])
for a in agents:
    name = a.get('name', 'без имени')
    model = a.get('model', 'не указана')
    print(f'  Агент: {name} → Модель: {model}')
if not agents:
    print('  Агенты не найдены в конфиге')
" 2>/dev/null || echo "  Не удалось прочитать конфиг")
    echo "$MODELS"
    
    # Показываем Telegram канал
    TG_BOT=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    c = json.load(f)
tg = c.get('channels', {}).get('telegram', {})
bot = tg.get('botUsername', tg.get('botToken', 'не найден')[:20]+'...' if tg.get('botToken') else 'не настроен')
policy = tg.get('dmPolicy', 'не указана')
print(f'  Telegram бот: {bot}')
print(f'  DM политика: {policy}')
" 2>/dev/null || echo "  Не удалось прочитать Telegram конфиг")
    echo "$TG_BOT"
else
    echo -e "  ${RED}❌ Конфиг не найден: $CONFIG_FILE${NC}"
fi
echo ""

# -------------------------------------------
# ПРОВЕРКА 5: Последние ошибки в логе
# Ищем строки с ошибками за сегодня.
# Это покажет, почему бот мог зависнуть.
# -------------------------------------------
echo -e "${YELLOW}[5/5] Последние ошибки в логе...${NC}"
LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"

if [ -f "$LOG_FILE" ]; then
    ERRORS=$(tail -50 "$LOG_FILE" | grep -i -E "error|fail|timeout|refuse|reject|invalid|unauthorized" | tail -5)
    if [ -n "$ERRORS" ]; then
        echo -e "  ${RED}Найдены ошибки:${NC}"
        echo "$ERRORS" | while read line; do
            # Извлекаем только полезную часть из JSON лога
            MSG=$(echo "$line" | python3 -c "
import sys,json
try:
    d = json.loads(sys.stdin.read())
    ts = d.get('time','?')[:19]
    msg = d.get('1', d.get('2', str(d.get('0',''))))
    print(f'  [{ts}] {msg}')
except:
    print(f'  {sys.stdin.read()[:200]}')" 2>/dev/null || echo "  $line" | head -c 200)
            echo "$MSG"
        done
    else
        echo -e "  ${GREEN}✅ Ошибок не найдено${NC}"
    fi
else
    echo -e "  ${YELLOW}⚠️  Лог файл не найден: $LOG_FILE${NC}"
fi
echo ""

# -------------------------------------------
# ИТОГ И ДЕЙСТВИЯ
# -------------------------------------------
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ИТОГ${NC}"
echo -e "${BLUE}============================================${NC}"

if $BOT_RUNNING && $LITELLM_OK && $OLLAMA_OK; then
    echo -e "  ${GREEN}✅ Всё работает нормально${NC}"
    echo ""
    echo "  Если бот всё равно не отвечает в Telegram,"
    echo "  попробуй перезапустить:"
    echo "    systemctl --user restart openclaw-gateway-moa.service"
elif ! $BOT_RUNNING; then
    echo -e "  ${RED}❌ Бот не запущен${NC}"
    echo ""
    read -p "  Запустить бота? (y/n): " ANSWER
    if [ "$ANSWER" = "y" ] || [ "$ANSWER" = "Y" ] || [ "$ANSWER" = "д" ] || [ "$ANSWER" = "Д" ]; then
        echo ""
        echo "  Запускаю..."
        systemctl --user start openclaw-gateway-moa.service
        sleep 3
        # Проверяем что запустился
        if ps aux | grep "openclaw-gateway" | grep -v grep > /dev/null; then
            echo -e "  ${GREEN}✅ Бот запущен!${NC}"
            echo "  Напиши ему в Telegram для проверки."
        else
            echo -e "  ${RED}❌ Не удалось запустить через systemd${NC}"
            echo "  Пробую напрямую..."
            openclaw --profile moa gateway &
            sleep 5
            if ps aux | grep "openclaw-gateway" | grep -v grep > /dev/null; then
                echo -e "  ${GREEN}✅ Бот запущен напрямую!${NC}"
            else
                echo -e "  ${RED}❌ Не удалось запустить. Покажи этот вывод в Perplexity.${NC}"
            fi
        fi
    fi
else
    echo "  Проблемы:"
    $LITELLM_OK  || echo -e "  ${RED}— LiteLLM не работает. Запусти: litellm --config ~/litellm-config.yaml --port 8080 &${NC}"
    $OLLAMA_OK   || echo -e "  ${RED}— GMKtec/Ollama недоступен. Проверь что GMKtec включён.${NC}"
    echo ""
    echo "  Исправь проблемы выше, потом запусти этот скрипт снова."
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo ""
