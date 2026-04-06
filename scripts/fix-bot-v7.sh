#!/bin/bash
# ============================================
#  FIX-BOT-V7 — Окончательная починка
# ============================================
#
#  ДИАГНОЗ: Бот отправляет сообщения, но getUpdates
#  пустой. Причина: systemd авто-рестарт "съедает"
#  updates, или OpenClaw polling не работает корректно
#  в версии 2026.3.8 service-файла с Node 2026.3.24.
#
#  Этот скрипт:
#  1. ПОЛНОСТЬЮ отключает автозапуск (disable)
#  2. Убивает ВСЕ процессы
#  3. Убеждается что getUpdates работает
#  4. Обновляет service-файл под новую версию
#  5. Запускает бота и тестирует
#
#  Запуск: cd ~/vibe-coding && git pull && bash scripts/fix-bot-v7.sh
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
echo -e "${BLUE}  FIX-BOT-V7 — Окончательная починка${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================
# ШАГ 1: ПОЛНАЯ остановка + disable
# ============================================
echo -e "${YELLOW}[1/8] Полная остановка и отключение автозапуска...${NC}"
echo ""

# Disable чтобы systemd НЕ перезапускал
systemctl --user disable openclaw-gateway-moa.service 2>/dev/null
systemctl --user stop openclaw-gateway-moa.service 2>/dev/null
sleep 1

# Убиваем ВСЁ
pkill -9 -f "openclaw" 2>/dev/null
sleep 1

# Убиваем ещё раз на всякий случай
pkill -9 -f "openclaw" 2>/dev/null
sleep 1

# Проверяем
REMAINING=$(pgrep -f "openclaw" 2>/dev/null)
if [ -n "$REMAINING" ]; then
    echo -e "  ${RED}Ещё есть процессы: $REMAINING — убиваю...${NC}"
    kill -9 $REMAINING 2>/dev/null
    sleep 1
fi

# Финальная проверка
if pgrep -f "openclaw" > /dev/null 2>&1; then
    echo -e "  ${RED}❌ НЕ УДАЛОСЬ остановить все процессы!${NC}"
    ps aux | grep openclaw | grep -v grep
else
    echo -e "  ${GREEN}✅ Все процессы OpenClaw убиты${NC}"
    echo "  Автозапуск отключён (disabled)"
fi
echo ""

# ============================================
# ШАГ 2: Ждём 5 секунд и проверяем getUpdates
# ============================================
echo -e "${YELLOW}[2/8] Жду 5 секунд и проверяю что нет polling...${NC}"
sleep 5

# Убеждаемся что никто не делает polling
if pgrep -f "openclaw" > /dev/null 2>&1; then
    echo -e "  ${RED}❌ OpenClaw снова запустился! Systemd restart!${NC}"
    echo "  Убиваю и отключаю mask..."
    systemctl --user mask openclaw-gateway-moa.service 2>/dev/null
    pkill -9 -f "openclaw" 2>/dev/null
    sleep 2
else
    echo -e "  ${GREEN}✅ Никто не запущен${NC}"
fi
echo ""

# ============================================
# ШАГ 3: Тестовый getUpdates БЕЗ timeout
# ============================================
echo -e "${YELLOW}[3/8] getUpdates мгновенный (проверка очереди)...${NC}"
echo ""

INSTANT=$(curl -4 -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=0" 2>/dev/null)
INSTANT_COUNT=$(echo "$INSTANT" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null)
echo "  Updates в очереди: $INSTANT_COUNT"

if [ "$INSTANT_COUNT" != "0" ] && [ -n "$INSTANT_COUNT" ]; then
    echo "  Содержимое:"
    echo "$INSTANT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for u in d.get('result',[]):
    msg = u.get('message',{})
    frm = msg.get('from',{})
    print(f'    update_id={u[\"update_id\"]} from={frm.get(\"id\")} @{frm.get(\"username\",\"?\")} text=\"{msg.get(\"text\",\"?\")}\"')
" 2>/dev/null
fi
echo ""

# ============================================
# ШАГ 4: Отправляем сообщение от бота ТЕБЕ
# ============================================
echo -e "${YELLOW}[4/8] Отправляю тестовое сообщение от бота...${NC}"
echo ""

SEND=$(curl -4 -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=508602494" \
    -d "text=Напиши мне ОТВЕТ на это сообщение. Просто напиши: тест" 2>/dev/null)

if echo "$SEND" | python3 -c "import sys,json;print(json.load(sys.stdin).get('ok',False))" 2>/dev/null | grep -q "True"; then
    echo -e "  ${GREEN}✅ Сообщение отправлено${NC}"
else
    echo -e "  ${RED}❌ Ошибка отправки${NC}"
    echo "  $SEND" | head -c 200
fi
echo ""

# ============================================
# ШАГ 5: Long-poll 45 секунд (с подробным выводом)
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${CYAN}  ❗ ОТВЕТЬ БОТУ В TELEGRAM!${NC}"
echo -e "${CYAN}  ❗ Напиши: тест${NC}"
echo -e "${CYAN}  ❗ (жду 45 секунд)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

echo -e "${YELLOW}[5/8] Long-poll 45 секунд (IPv4)...${NC}"
echo "  Начало: $(date '+%H:%M:%S')"

POLL=$(curl -4 -v -s --max-time 50 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=45" 2>/tmp/curl-debug-v7.txt)
CURL_EXIT=$?

echo "  Конец: $(date '+%H:%M:%S')"
echo "  curl exit code: $CURL_EXIT"
echo ""

# Показываем debug info от curl
echo "  curl debug (подключение):"
grep -E "Connected to|Trying|SSL|< HTTP" /tmp/curl-debug-v7.txt 2>/dev/null | head -10 | while IFS= read -r line; do
    echo "    $line"
done
echo ""

echo "  RAW ответ:"
echo "  $POLL" | head -c 500
echo ""

POLL_COUNT=$(echo "$POLL" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null)
echo "  Updates получено: $POLL_COUNT"

if [ "$POLL_COUNT" != "0" ] && [ -n "$POLL_COUNT" ]; then
    echo ""
    echo "$POLL" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for u in d.get('result',[]):
    msg = u.get('message',{})
    frm = msg.get('from',{})
    print(f'  ✅ UPDATE: id={u[\"update_id\"]} user_id={frm.get(\"id\")} @{frm.get(\"username\",\"?\")} text=\"{msg.get(\"text\",\"?\")}\"')
    if frm.get('id') == 508602494:
        print(f'  ✅ User ID СОВПАДАЕТ с allowFrom!')
    else:
        print(f'  ❌ User ID НЕ совпадает! Нужно: 508602494, получено: {frm.get(\"id\")}')
" 2>/dev/null
else
    echo ""
    echo -e "  ${RED}❌ ПУСТО — getUpdates не видит твоих сообщений${NC}"
    echo ""
    echo "  Это значит одно из двух:"
    echo "  1) В Telegram ты НЕ нажал /start для @mycarmi_moa_bot"
    echo "  2) Ты пишешь другому боту или в другой чат"
    echo ""
    echo "  РЕШЕНИЕ:"
    echo "  → Открой Telegram"
    echo "  → Найди @mycarmi_moa_bot"
    echo "  → Нажми МЕНЮ (три полоски) → 'Удалить и остановить бота'"
    echo "  → Потом снова найди @mycarmi_moa_bot"
    echo "  → Нажми кнопку 'НАЧАТЬ' (Start)"
    echo "  → Напиши: тест"
fi
echo ""

# ============================================
# ШАГ 6: Обновляю service-файл
# ============================================
echo -e "${YELLOW}[6/8] Обновляю service-файл OpenClaw...${NC}"
echo ""

SERVICE_FILE="$HOME/.config/systemd/user/openclaw-gateway-moa.service"

# Регенерируем через openclaw
echo "  Пробую: openclaw --profile moa service install..."
openclaw --profile moa service install 2>&1 | head -10
echo ""

# Если не сработало, обновляем вручную
if [ -f "$SERVICE_FILE" ]; then
    # Обновляем версию в описании
    sed -i 's/v2026.3.8/v2026.3.24/g' "$SERVICE_FILE"
    sed -i 's/OPENCLAW_SERVICE_VERSION=2026.3.8/OPENCLAW_SERVICE_VERSION=2026.3.24/g' "$SERVICE_FILE"
    echo "  Service-файл обновлён"
    
    # Reload systemd
    systemctl --user daemon-reload
    echo "  systemd перезагружен"
fi
echo ""

# ============================================
# ШАГ 7: Включаю и запускаю бота
# ============================================
echo -e "${YELLOW}[7/8] Включаю и запускаю бота...${NC}"
echo ""

# Unmask если замаскировали
systemctl --user unmask openclaw-gateway-moa.service 2>/dev/null
systemctl --user enable openclaw-gateway-moa.service 2>/dev/null

# Очищаю лог
LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
mkdir -p /tmp/openclaw
[ -f "$LOG_FILE" ] && mv "$LOG_FILE" "${LOG_FILE}.pre-v7"

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
# ШАГ 8: Живой лог 60 секунд
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${CYAN}  НАПИШИ БОТУ: тест${NC}"
echo -e "${CYAN}  (слежу 60 секунд)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

if [ -f "$LOG_FILE" ]; then
    timeout 60 tail -f "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
        PARSED=$(echo "$line" | python3 -c "
import sys, json
line = sys.stdin.readline().strip()
if not line: sys.exit(0)
try:
    d = json.loads(line)
    ts = d.get('time','')[-12:]
    level = d.get('_meta',{}).get('logLevelName','?')
    msg0 = str(d.get('0', ''))[:150]
    msg1 = str(d.get('1', ''))[:150]
    out = f'  {ts} [{level:5}] {msg0}'
    if msg1 and msg1 != msg0: out += f' | {msg1}'
    print(out)
except:
    print(f'  RAW: {line[:200]}')
" 2>/dev/null)
        echo "$PARSED"
    done
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ГОТОВО${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "  Скопируй ВЕСЬ вывод и отправь в Perplexity."
echo ""
