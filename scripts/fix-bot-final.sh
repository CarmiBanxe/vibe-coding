#!/bin/bash
# ============================================
#  FIX-BOT-FINAL — Чистый старт бота
# ============================================
#
#  ДИАГНОЗ НАЙДЕН:
#  - Polling работает (getUpdates ловит сообщения)
#  - Бот получает /start, но удаляет как "orphaned"
#  - Причина: старая сессия с накопленными сообщениями
#
#  Этот скрипт:
#  1. Останавливает бота
#  2. Сбрасывает ВСЕ pending Telegram updates
#  3. Очищает сессии/историю бота
#  4. Запускает бота чисто
#  5. Ждёт 10 секунд для инициализации
#  6. Следит за логом 90 секунд
#
#  Запуск: cd ~/vibe-coding && git pull && bash scripts/fix-bot-final.sh
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
echo -e "${BLUE}  FIX-BOT-FINAL — Чистый старт${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================
# ШАГ 1: Полная остановка
# ============================================
echo -e "${YELLOW}[1/7] Останавливаю бота...${NC}"
systemctl --user stop openclaw-gateway-moa.service 2>/dev/null
sleep 1
pkill -9 -f "openclaw" 2>/dev/null
sleep 2
echo -e "  ${GREEN}✅ Остановлен${NC}"
echo ""

# ============================================
# ШАГ 2: Сбрасываю ВСЕ Telegram updates
# ============================================
echo -e "${YELLOW}[2/7] Сбрасываю все Telegram updates...${NC}"
echo ""

# Получаем последний update_id
LAST=$(curl -4 -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=-1&timeout=1" 2>/dev/null)
LAST_ID=$(echo "$LAST" | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('result',[])
print(r[-1]['update_id'] if r else '0')
" 2>/dev/null)

if [ "$LAST_ID" != "0" ] && [ -n "$LAST_ID" ]; then
    NEXT=$((LAST_ID + 1))
    curl -4 -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${NEXT}&timeout=1" > /dev/null 2>&1
    echo -e "  ${GREEN}✅ Сброшены все updates (last_id: $LAST_ID, offset: $NEXT)${NC}"
else
    echo "  Updates уже пустые"
fi

# Проверяем что очередь действительно пуста
sleep 1
CHECK=$(curl -4 -s --max-time 5 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=0" 2>/dev/null)
CHECK_COUNT=$(echo "$CHECK" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null)
echo "  Проверка: updates в очереди = $CHECK_COUNT"
echo ""

# ============================================
# ШАГ 3: Очищаю сессии бота
# ============================================
echo -e "${YELLOW}[3/7] Очищаю сессии и историю бота...${NC}"
echo ""

# Очищаем workspace сессии (где хранится история чатов)
WORKSPACE="/home/mmber/.openclaw/workspace-moa"
if [ -d "$WORKSPACE" ]; then
    # Бэкап на всякий
    BACKUP_DIR="/home/mmber/.openclaw/workspace-moa-backup-$(date +%Y%m%d-%H%M%S)"
    cp -r "$WORKSPACE" "$BACKUP_DIR" 2>/dev/null
    echo "  📦 Бэкап workspace: $BACKUP_DIR"
    
    # Удаляем файлы сессий (но не сам каталог)
    SESSIONS=$(find "$WORKSPACE" -name "*.json" -o -name "*.session" -o -name "*.log" 2>/dev/null | wc -l)
    echo "  Найдено файлов: $SESSIONS"
    
    # Удаляем sessions директорию если есть
    if [ -d "$WORKSPACE/sessions" ]; then
        rm -rf "$WORKSPACE/sessions"
        echo "  Удалена директория sessions/"
    fi
    
    # Удаляем conversations если есть
    if [ -d "$WORKSPACE/conversations" ]; then
        rm -rf "$WORKSPACE/conversations"
        echo "  Удалена директория conversations/"
    fi
fi

# Очищаем все workspace-ы агентов
for WS_DIR in /home/mmber/.openclaw/workspace-moa-*/; do
    if [ -d "$WS_DIR" ] && [[ "$WS_DIR" != *"backup"* ]]; then
        WS_NAME=$(basename "$WS_DIR")
        if [ -d "$WS_DIR/sessions" ]; then
            rm -rf "$WS_DIR/sessions"
            echo "  Очищены сессии: $WS_NAME"
        fi
        if [ -d "$WS_DIR/conversations" ]; then
            rm -rf "$WS_DIR/conversations"
            echo "  Очищены беседы: $WS_NAME"
        fi
    fi
done

# Очищаем state OpenClaw
STATE_DIR="/home/mmber/.openclaw-moa"
if [ -d "$STATE_DIR/sessions" ]; then
    rm -rf "$STATE_DIR/sessions"
    echo "  Очищены сессии в state dir"
fi
if [ -d "$STATE_DIR/conversations" ]; then
    rm -rf "$STATE_DIR/conversations"
    echo "  Очищены беседы в state dir"
fi

echo -e "  ${GREEN}✅ Сессии очищены${NC}"
echo ""

# ============================================
# ШАГ 4: Очищаю лог
# ============================================
echo -e "${YELLOW}[4/7] Очищаю лог...${NC}"
LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
mkdir -p /tmp/openclaw
[ -f "$LOG_FILE" ] && mv "$LOG_FILE" "${LOG_FILE}.pre-final"
echo "  ✅ Лог очищен"
echo ""

# ============================================
# ШАГ 5: Включаю и запускаю бота
# ============================================
echo -e "${YELLOW}[5/7] Запускаю бота...${NC}"
echo ""

systemctl --user enable openclaw-gateway-moa.service 2>/dev/null
systemctl --user daemon-reload 2>/dev/null
systemctl --user start openclaw-gateway-moa.service 2>/dev/null

echo "  Жду 10 секунд для полной инициализации..."
sleep 10

if pgrep -f "openclaw" > /dev/null 2>&1; then
    PID=$(pgrep -f "openclaw" | head -1)
    echo -e "  ${GREEN}✅ Бот запущен (PID: $PID)${NC}"
else
    echo -e "  ${RED}❌ Бот не запустился${NC}"
    systemctl --user status openclaw-gateway-moa.service 2>&1 | tail -10
    exit 1
fi
echo ""

# ============================================
# ШАГ 6: Показываю лог запуска
# ============================================
echo -e "${YELLOW}[6/7] Лог запуска:${NC}"
echo ""

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
" 2>/dev/null
fi
echo ""

# Проверяем есть ли ошибки
if [ -f "$LOG_FILE" ]; then
    ERRORS=$(grep -c '"ERROR"' "$LOG_FILE" 2>/dev/null)
    WARNS=$(grep -c '"WARN"' "$LOG_FILE" 2>/dev/null)
    if [ "$ERRORS" -gt 0 ]; then
        echo -e "  ${RED}⚠️  Найдено ошибок: $ERRORS${NC}"
    fi
    if [ "$WARNS" -gt 0 ]; then
        echo -e "  ${YELLOW}⚠️  Найдено предупреждений: $WARNS${NC}"
    fi
    if [ "$ERRORS" = "0" ] && [ "$WARNS" = "0" ]; then
        echo -e "  ${GREEN}✅ Ошибок и предупреждений нет${NC}"
    fi
fi
echo ""

# ============================================
# ШАГ 7: Слежу за логом 90 секунд
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${CYAN}  ❗ НАПИШИ БОТУ @mycarmi_moa_bot${NC}"
echo -e "${CYAN}  ❗ Просто напиши: привет${NC}"
echo -e "${CYAN}  ❗ (слежу 90 секунд)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

if [ -f "$LOG_FILE" ]; then
    timeout 90 tail -f "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
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
    msg2 = str(d.get('2', ''))[:100]
    out = f'  {ts} [{level:5}] {msg0}'
    if msg1 and msg1 != msg0: out += f' | {msg1}'
    if msg2: out += f' | {msg2}'
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
echo "  Если бот ответил в Telegram — НАПИШИ МНЕ!"
echo ""
