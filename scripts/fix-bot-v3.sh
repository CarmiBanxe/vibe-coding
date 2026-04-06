#!/bin/bash
# ============================================
#  FIX-BOT-V3 — Радикальная диагностика и починка
# ============================================
#
#  Что делает:
#  1. Полный дамп конфигов (OpenClaw + LiteLLM)
#  2. Проверяет версию OpenClaw и обновляет если можно
#  3. Проверяет ВСЕ провайдеры моделей
#  4. Проверяет Telegram Webhook/Polling
#  5. Запускает бота с ПОЛНЫМ DEBUG логом
#  6. Следит за логом в реальном времени 60 секунд
#     (ты в это время пишешь боту в Telegram)
#
#  Запуск: cd ~/vibe-coding && git pull && bash scripts/fix-bot-v3.sh
#
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

OPENCLAW_CONFIG="/home/mmber/.openclaw-moa/openclaw.json"
LITELLM_CONFIG="/home/mmber/litellm-config.yaml"
BOT_TOKEN="8793039199:AAHo8zr7ksY5jBsX0x1KLCRT1KHHltvcYF8"
GMKTEC_IP="192.168.0.72"

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  FIX-BOT-V3 — Радикальная починка${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================
# ШАГ 1: Версия OpenClaw + обновление
# ============================================
echo -e "${YELLOW}[1/8] Версия OpenClaw и обновление...${NC}"
echo ""

CURRENT_VER=$(openclaw --version 2>/dev/null || echo "не найден")
echo "  Текущая версия: $CURRENT_VER"

# Проверяем доступные обновления
echo "  Проверяю обновления npm..."
LATEST_VER=$(npm view openclaw version 2>/dev/null || echo "не удалось проверить")
echo "  Последняя версия в npm: $LATEST_VER"

if [ "$CURRENT_VER" != "$LATEST_VER" ] && [ "$LATEST_VER" != "не удалось проверить" ]; then
    echo ""
    echo -e "  ${YELLOW}⚠️  Доступно обновление! Устанавливаю...${NC}"
    npm install -g openclaw@latest 2>&1 | tail -5
    NEW_VER=$(openclaw --version 2>/dev/null || echo "ошибка")
    echo -e "  Установлена версия: ${GREEN}$NEW_VER${NC}"
else
    echo "  Обновление не требуется"
fi
echo ""

# ============================================
# ШАГ 2: Telegram API — прямая проверка
# ============================================
echo -e "${YELLOW}[2/8] Проверяю Telegram API напрямую...${NC}"
echo ""

# getMe — информация о боте
BOT_INFO=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
if echo "$BOT_INFO" | python3 -c "import sys,json;d=json.load(sys.stdin);print('OK' if d.get('ok') else 'FAIL')" 2>/dev/null | grep -q "OK"; then
    BOT_NAME=$(echo "$BOT_INFO" | python3 -c "import sys,json;r=json.load(sys.stdin)['result'];print(f\"@{r['username']} (ID: {r['id']})\")" 2>/dev/null)
    echo -e "  ${GREEN}✅ Бот доступен: $BOT_NAME${NC}"
else
    echo -e "  ${RED}❌ Бот НЕ доступен через Telegram API!${NC}"
    echo "  Ответ: $(echo $BOT_INFO | head -c 200)"
fi

# getWebhookInfo — проверяем нет ли webhook (конфликтует с polling)
WEBHOOK_INFO=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo" 2>/dev/null)
WEBHOOK_URL=$(echo "$WEBHOOK_INFO" | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',{}).get('url',''))" 2>/dev/null)
PENDING=$(echo "$WEBHOOK_INFO" | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',{}).get('pending_update_count',0))" 2>/dev/null)

if [ -n "$WEBHOOK_URL" ] && [ "$WEBHOOK_URL" != "" ]; then
    echo -e "  ${RED}❌ НАЙДЕН WEBHOOK: $WEBHOOK_URL${NC}"
    echo -e "  ${RED}   Это конфликтует с polling! Удаляю...${NC}"
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
    echo -e "  ${GREEN}✅ Webhook удалён, pending updates сброшены${NC}"
else
    echo -e "  ${GREEN}✅ Webhook не установлен (polling должен работать)${NC}"
fi
echo "  Ожидающие сообщения: $PENDING"

# Сбрасываем pending updates через getUpdates
echo "  Сбрасываю застрявшие сообщения..."
UPDATES=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=-1&timeout=1" 2>/dev/null)
LAST_ID=$(echo "$UPDATES" | python3 -c "
import sys,json
d=json.load(sys.stdin)
results = d.get('result',[])
if results:
    last = results[-1]
    uid = last['update_id']
    print(uid)
    # Подтверждаем offset
else:
    print('none')
" 2>/dev/null)

if [ "$LAST_ID" != "none" ] && [ -n "$LAST_ID" ]; then
    # Подтверждаем получение, сдвигая offset
    NEXT_OFFSET=$((LAST_ID + 1))
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${NEXT_OFFSET}&timeout=1" > /dev/null 2>&1
    echo -e "  ${GREEN}✅ Сброшены застрявшие updates (last_id: $LAST_ID)${NC}"
else
    echo "  Застрявших updates нет"
fi
echo ""

# ============================================
# ШАГ 3: Проверяю полный конфиг OpenClaw
# ============================================
echo -e "${YELLOW}[3/8] Полный конфиг OpenClaw:${NC}"
echo ""

python3 << 'PYEOF'
import json

with open('/home/mmber/.openclaw-moa/openclaw.json') as f:
    c = json.load(f)

# Маскируем токены
def mask(obj):
    if isinstance(obj, dict):
        return {k: mask(v) if k not in ('botToken','apiKey','token','api_key') else (str(v)[:8]+'...') for k,v in obj.items()}
    elif isinstance(obj, list):
        return [mask(i) for i in obj]
    return obj

masked = mask(c)
print(json.dumps(masked, indent=2, ensure_ascii=False))
PYEOF
echo ""

# ============================================
# ШАГ 4: Проверяю ВСЕ модели
# ============================================
echo -e "${YELLOW}[4/8] Тестирую все провайдеры моделей...${NC}"
echo ""

# Groq через LiteLLM
echo "  a) Groq через LiteLLM (порт 8080)..."
RESP=$(curl -s --max-time 15 http://localhost:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"groq/llama-3.3-70b-versatile","messages":[{"role":"user","content":"say OK"}],"max_tokens":5}' 2>/dev/null)
if echo "$RESP" | grep -q "choices"; then
    echo -e "  ${GREEN}✅ Groq через LiteLLM работает${NC}"
else
    echo -e "  ${RED}❌ Groq через LiteLLM НЕ работает${NC}"
    echo "  $(echo $RESP | head -c 200)"
fi

# Ollama через LiteLLM
echo "  b) Ollama через LiteLLM..."
RESP2=$(curl -s --max-time 30 http://localhost:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"ollama/glm-flash","messages":[{"role":"user","content":"say OK"}],"max_tokens":5}' 2>/dev/null)
if echo "$RESP2" | grep -q "choices"; then
    echo -e "  ${GREEN}✅ Ollama через LiteLLM работает${NC}"
else
    echo -e "  ${YELLOW}⚠️  Ollama через LiteLLM не ответила (может загружается)${NC}"
    echo "  $(echo $RESP2 | head -c 200)"
fi

# Ollama напрямую
echo "  c) Ollama напрямую ($GMKTEC_IP)..."
RESP3=$(curl -s --max-time 10 http://$GMKTEC_IP:11434/api/tags 2>/dev/null)
if echo "$RESP3" | grep -q "models"; then
    echo -e "  ${GREEN}✅ Ollama доступна напрямую${NC}"
else
    echo -e "  ${RED}❌ Ollama недоступна напрямую${NC}"
fi

# Модель по умолчанию — groq/llama-3.3-70b через OpenClaw Gateway
echo "  d) Gateway (порт 18790)..."
GW_RESP=$(curl -s --max-time 10 http://127.0.0.1:18790/v1/models 2>/dev/null)
if [ -n "$GW_RESP" ]; then
    echo -e "  ${GREEN}✅ Gateway отвечает${NC}"
else
    echo -e "  ${RED}❌ Gateway не отвечает${NC}"
fi
echo ""

# ============================================
# ШАГ 5: Запуск openclaw doctor
# ============================================
echo -e "${YELLOW}[5/8] Запускаю openclaw doctor...${NC}"
echo ""

openclaw --profile moa doctor 2>&1 | head -30
echo ""

# ============================================
# ШАГ 6: Чистый перезапуск бота
# ============================================
echo -e "${YELLOW}[6/8] Чистый перезапуск бота...${NC}"
echo ""

# Полная остановка
systemctl --user stop openclaw-gateway-moa.service 2>/dev/null
sleep 1
pkill -9 -f "openclaw" 2>/dev/null
sleep 2

# Очищаем лог для чистоты
LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
if [ -f "$LOG_FILE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old-$(date +%H%M%S)"
    echo "  Старый лог архивирован"
fi

# Запускаем
systemctl --user start openclaw-gateway-moa.service 2>/dev/null
sleep 5

if pgrep -f "openclaw" > /dev/null 2>&1; then
    echo -e "  ${GREEN}✅ Бот запущен${NC}"
else
    echo -e "  ${RED}❌ Бот не запустился${NC}"
    systemctl --user status openclaw-gateway-moa.service 2>&1 | tail -15
fi
echo ""

# ============================================
# ШАГ 7: Показываем свежий лог запуска
# ============================================
echo -e "${YELLOW}[7/8] Лог запуска:${NC}"
echo ""

LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE" | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        ts = d.get('time','')[-12:]
        level = d.get('_meta',{}).get('logLevelName','?')
        msg0 = str(d.get('0', ''))[:120]
        msg1 = str(d.get('1', ''))[:120]
        out = f'  {ts} [{level:5}] {msg0}'
        if msg1 and msg1 != msg0:
            out += f' | {msg1}'
        print(out)
    except:
        print(f'  RAW: {line.strip()[:180]}')
"
else
    echo "  Лог не создан"
fi
echo ""

# ============================================
# ШАГ 8: Слежение за логом в реальном времени
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${CYAN}  ОТПРАВЬ СООБЩЕНИЕ БОТУ В TELEGRAM СЕЙЧАС${NC}"
echo -e "${CYAN}  (слежу за логом 60 секунд...)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

if [ -f "$LOG_FILE" ]; then
    # Следим за логом 60 секунд в реальном времени
    timeout 60 tail -f "$LOG_FILE" | python3 -c "
import sys, json, signal

def handler(sig, frame):
    sys.exit(0)
signal.signal(signal.SIGPIPE, handler)

for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        ts = d.get('time','')[-12:]
        level = d.get('_meta',{}).get('logLevelName','?')
        msg0 = str(d.get('0', ''))[:150]
        msg1 = str(d.get('1', ''))[:150]
        msg2 = str(d.get('2', ''))[:100]
        out = f'  {ts} [{level:5}] {msg0}'
        if msg1 and msg1 != msg0:
            out += f' | {msg1}'
        if msg2:
            out += f' | {msg2}'
        print(out, flush=True)
    except:
        print(f'  RAW: {line.strip()[:200]}', flush=True)
" 2>/dev/null
else
    echo "  Не могу следить — лог не создан"
    echo "  Подожди 60 секунд..."
    sleep 60
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  60 секунд прошли${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "  Скопируй ВЕСЬ вывод этого скрипта и отправь в Perplexity."
echo "  Особенно важны строки после 'ОТПРАВЬ СООБЩЕНИЕ БОТУ'."
echo ""
