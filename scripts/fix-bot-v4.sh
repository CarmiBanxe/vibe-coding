#!/bin/bash
# ============================================
#  FIX-BOT-V4 — Чистый перезапуск + живой лог
# ============================================
#
#  OpenClaw уже обновлён до 2026.3.24
#  Конфиг уже исправлен (allowlist)
#  IP Ollama уже исправлен (192.168.0.72)
#
#  Этот скрипт:
#  1. Останавливает бота
#  2. Очищает лог
#  3. Запускает бота заново
#  4. Показывает 90 секунд живого лога
#     (ты в это время пишешь боту!)
#
#  Запуск: cd ~/vibe-coding && git pull && bash scripts/fix-bot-v4.sh
#
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  FIX-BOT-V4 — Перезапуск + живой лог${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================
# ШАГ 1: Полная остановка
# ============================================
echo -e "${YELLOW}[1/4] Полная остановка бота...${NC}"

systemctl --user stop openclaw-gateway-moa.service 2>/dev/null
sleep 1
pkill -9 -f "openclaw" 2>/dev/null
sleep 2

if pgrep -f "openclaw" > /dev/null 2>&1; then
    echo -e "  ${RED}Бот ещё работает — убиваю жёстко...${NC}"
    pkill -9 -f "openclaw" 2>/dev/null
    sleep 2
fi
echo -e "  ${GREEN}✅ Бот остановлен${NC}"
echo ""

# ============================================
# ШАГ 2: Очистка лога
# ============================================
echo -e "${YELLOW}[2/4] Очищаю лог...${NC}"

LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
mkdir -p /tmp/openclaw

if [ -f "$LOG_FILE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
    echo "  Старый лог перемещён"
fi
echo ""

# ============================================
# ШАГ 3: Запуск бота
# ============================================
echo -e "${YELLOW}[3/4] Запускаю бота...${NC}"

systemctl --user start openclaw-gateway-moa.service 2>/dev/null
sleep 5

if pgrep -f "openclaw" > /dev/null 2>&1; then
    PID=$(pgrep -f "openclaw" | head -1)
    echo -e "  ${GREEN}✅ Бот запущен (PID: $PID)${NC}"
else
    echo -e "  ${RED}❌ Бот не запустился через systemd${NC}"
    echo ""
    echo "  Статус сервиса:"
    systemctl --user status openclaw-gateway-moa.service 2>&1 | tail -10
    echo ""
    echo "  Скопируй всё выше и отправь в Perplexity."
    exit 1
fi
echo ""

# Показываем лог запуска
echo "  Лог запуска:"
sleep 2
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

# ============================================
# ШАГ 4: Живой лог — 90 секунд
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${CYAN}  ❗ ОТПРАВЬ СООБЩЕНИЕ БОТУ @mycarmi_moa_bot${NC}"
echo -e "${CYAN}  ❗ ПРЯМО СЕЙЧАС В TELEGRAM!${NC}"
echo -e "${CYAN}  ❗ (слежу за логом 90 секунд)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

if [ -f "$LOG_FILE" ]; then
    timeout 90 tail -f "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
        echo "$line" | python3 -c "
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
    print(out, flush=True)
except:
    print(f'  RAW: {line[:200]}', flush=True)
" 2>/dev/null
    done
else
    echo "  Лог не найден, жду..."
    sleep 90
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  90 секунд прошли${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "  Скопируй ВЕСЬ вывод и отправь в Perplexity."
echo "  Особенно важно — появились ли строки"
echo "  когда ты писал боту в Telegram."
echo ""
