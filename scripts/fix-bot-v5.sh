#!/bin/bash
# ============================================
#  FIX-BOT-V5 — Диагностика Telegram polling
# ============================================
#
#  Бот стартует но НЕ видит сообщения.
#  Этот скрипт:
#  1. Проверяет сеть WSL2 → Telegram API
#  2. Вручную делает getUpdates (long-poll)
#     — ты пишешь боту, скрипт ловит сообщение
#  3. Показывает твой РЕАЛЬНЫЙ Telegram user ID
#  4. Проверяет нет ли другого процесса
#     который "съедает" updates
#  5. Останавливает бота, делает getUpdates,
#     запускает бота — чтобы бот стартовал
#     с чистой очередью
#
#  Запуск: cd ~/vibe-coding && git pull && bash scripts/fix-bot-v5.sh
#
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

BOT_TOKEN="8793039199:AAHo8zr7ksY5jBsX0x1KLCRT1KHHltvcYF8"

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  FIX-BOT-V5 — Диагностика Telegram polling${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================
# ШАГ 1: Сеть WSL2 → Telegram
# ============================================
echo -e "${YELLOW}[1/7] Проверяю сеть WSL2 → Telegram API...${NC}"
echo ""

# DNS
echo "  a) DNS резолвинг api.telegram.org..."
TG_IP=$(dig +short api.telegram.org 2>/dev/null | head -1)
if [ -z "$TG_IP" ]; then
    TG_IP=$(nslookup api.telegram.org 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
fi
if [ -z "$TG_IP" ]; then
    TG_IP=$(getent hosts api.telegram.org 2>/dev/null | awk '{print $1}')
fi
if [ -n "$TG_IP" ]; then
    echo -e "  ${GREEN}✅ DNS: api.telegram.org → $TG_IP${NC}"
else
    echo -e "  ${RED}❌ DNS не резолвит api.telegram.org!${NC}"
fi

# HTTPS
echo "  b) HTTPS к api.telegram.org..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
    echo -e "  ${GREEN}✅ HTTPS работает (код: $HTTP_CODE)${NC}"
else
    echo -e "  ${RED}❌ HTTPS проблема (код: $HTTP_CODE)${NC}"
fi

# Замеряем время ответа
echo "  c) Время ответа Telegram API..."
TIME=$(curl -s -o /dev/null -w "%{time_total}" --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
echo "  Время: ${TIME}s"
echo ""

# ============================================
# ШАГ 2: Останавливаю ВСЁ что может читать updates
# ============================================
echo -e "${YELLOW}[2/7] Останавливаю ВСЕ процессы бота...${NC}"
echo ""

systemctl --user stop openclaw-gateway-moa.service 2>/dev/null
sleep 1
pkill -9 -f "openclaw" 2>/dev/null
sleep 2

# Проверяем нет ли других процессов
LEFTOVER=$(ps aux | grep -i "telegram\|openclaw\|grammy\|telegraf" | grep -v grep | grep -v "fix-bot")
if [ -n "$LEFTOVER" ]; then
    echo -e "  ${RED}⚠️  Найдены другие процессы:${NC}"
    echo "$LEFTOVER"
    echo "  Убиваю их..."
    echo "$LEFTOVER" | awk '{print $2}' | xargs kill -9 2>/dev/null
    sleep 1
else
    echo "  Других процессов нет"
fi
echo -e "  ${GREEN}✅ Всё остановлено${NC}"
echo ""

# ============================================
# ШАГ 3: Сбрасываю все pending updates
# ============================================
echo -e "${YELLOW}[3/7] Сбрасываю ВСЕ pending updates...${NC}"
echo ""

# Метод: getUpdates с offset=-1 чтобы пропустить все старые
RESP=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=-1&timeout=1" 2>/dev/null)
LAST_ID=$(echo "$RESP" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    results = d.get('result',[])
    if results:
        print(results[-1]['update_id'])
    else:
        print('0')
except:
    print('error')
" 2>/dev/null)

if [ "$LAST_ID" != "0" ] && [ "$LAST_ID" != "error" ] && [ -n "$LAST_ID" ]; then
    NEXT=$((LAST_ID + 1))
    curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${NEXT}&timeout=1" > /dev/null 2>&1
    echo -e "  ${GREEN}✅ Старые updates сброшены (last_id: $LAST_ID)${NC}"
else
    echo "  Старых updates нет"
fi
echo ""

# ============================================
# ШАГ 4: Ручной тест getUpdates (long-polling)
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${CYAN}  ❗ СЕЙЧАС ОТПРАВЬ СООБЩЕНИЕ БОТУ${NC}"
echo -e "${CYAN}  ❗ @mycarmi_moa_bot в Telegram!${NC}"
echo -e "${CYAN}  ❗ У тебя 30 секунд...${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo -e "${YELLOW}[4/7] Жду сообщение через getUpdates (30 сек)...${NC}"
echo ""

# Long-polling — ждём 30 секунд новое сообщение
POLL_RESP=$(curl -s --max-time 35 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=30&limit=5" 2>/dev/null)

python3 << PYEOF
import json

resp = '''$POLL_RESP'''

try:
    d = json.loads(resp)
    ok = d.get('ok', False)
    results = d.get('result', [])
    
    if not ok:
        print(f"  ❌ Telegram API ошибка: {d}")
    elif not results:
        print("  ⚠️  НИ ОДНОГО сообщения не получено за 30 секунд!")
        print("  Возможные причины:")
        print("    - Ты не отправил сообщение")
        print("    - Ты пишешь ДРУГОМУ боту (не @mycarmi_moa_bot)")
        print("    - Telegram заблокирован в сети")
        print("    - Бот-токен недействителен")
    else:
        print(f"  ✅ ПОЛУЧЕНО {len(results)} update(s)!")
        for upd in results:
            uid = upd.get('update_id', '?')
            msg = upd.get('message', {})
            chat = msg.get('chat', {})
            frm = msg.get('from', {})
            text = msg.get('text', '<нет текста>')
            
            print(f"")
            print(f"  === UPDATE {uid} ===")
            print(f"  От:      {frm.get('first_name','')} {frm.get('last_name','')} (@{frm.get('username','?')})")
            print(f"  User ID: {frm.get('id', '?')}")
            print(f"  Chat ID: {chat.get('id', '?')}")
            print(f"  Текст:   {text}")
            print(f"  Тип чата: {chat.get('type', '?')}")
            
            # Проверяем совпадение с allowFrom
            user_id = frm.get('id')
            if user_id == 508602494:
                print(f"  ✅ User ID совпадает с allowFrom!")
            else:
                print(f"  ❌ User ID ({user_id}) НЕ совпадает с allowFrom (508602494)!")
                print(f"     НУЖНО исправить allowFrom в конфиге!")
except Exception as e:
    print(f"  ❌ Ошибка разбора: {e}")
    print(f"  Raw: {resp[:300]}")
PYEOF
echo ""

# Сбрасываем offset чтобы бот мог потом получить эти updates
# НЕ сбрасываем — пусть бот их получит

# ============================================
# ШАГ 5: Проверяю service-файл бота
# ============================================
echo -e "${YELLOW}[5/7] Проверяю service-файл бота...${NC}"
echo ""

SERVICE_FILE="$HOME/.config/systemd/user/openclaw-gateway-moa.service"
if [ -f "$SERVICE_FILE" ]; then
    echo "  Содержимое service-файла:"
    cat "$SERVICE_FILE" | while IFS= read -r line; do
        echo "    $line"
    done
else
    echo -e "  ${RED}❌ Service-файл не найден: $SERVICE_FILE${NC}"
fi
echo ""

# ============================================
# ШАГ 6: Запускаю бота
# ============================================
echo -e "${YELLOW}[6/7] Запускаю бота...${NC}"
echo ""

# Очищаю лог
LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
mkdir -p /tmp/openclaw
[ -f "$LOG_FILE" ] && mv "$LOG_FILE" "${LOG_FILE}.pre-v5"

systemctl --user start openclaw-gateway-moa.service 2>/dev/null
sleep 5

if pgrep -f "openclaw" > /dev/null 2>&1; then
    PID=$(pgrep -f "openclaw" | head -1)
    echo -e "  ${GREEN}✅ Бот запущен (PID: $PID)${NC}"
else
    echo -e "  ${RED}❌ Бот не запустился${NC}"
    systemctl --user status openclaw-gateway-moa.service 2>&1 | tail -10
fi
echo ""

# ============================================
# ШАГ 7: Живой лог 60 секунд
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${CYAN}  ❗ ОТПРАВЬ ЕЩЁ ОДНО СООБЩЕНИЕ БОТУ!${NC}"
echo -e "${CYAN}  ❗ (слежу за логом 60 секунд)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

if [ -f "$LOG_FILE" ]; then
    timeout 60 tail -f "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
        PARSED=$(echo "$line" | python3 -c "
import sys, json
line = sys.stdin.readline().strip()
if not line:
    sys.exit(0)
try:
    d = json.loads(line)
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
    print(out)
except:
    print(f'  RAW: {line[:200]}')
" 2>/dev/null)
        echo "$PARSED"
    done
else
    echo "  Лог не найден"
    sleep 60
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ДИАГНОСТИКА ЗАВЕРШЕНА${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "  Скопируй ВЕСЬ вывод и отправь в Perplexity."
echo "  САМОЕ ВАЖНОЕ — шаг 4 (получено ли сообщение)."
echo ""
