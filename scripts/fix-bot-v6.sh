#!/bin/bash
# ============================================
#  FIX-BOT-V6 — Финальная диагностика polling
# ============================================
#
#  Проблема: getUpdates возвращает пустоту.
#  Этот скрипт:
#  1. Останавливает бота
#  2. Принудительно IPv4 (WSL2 IPv6 может быть проблемой)
#  3. Делает 3 попытки getUpdates с паузами
#  4. Между попытками просит тебя отправить сообщение
#  5. Показывает RAW ответ Telegram API
#
#  Запуск: cd ~/vibe-coding && git pull && bash scripts/fix-bot-v6.sh
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
echo -e "${BLUE}  FIX-BOT-V6 — Финальная диагностика${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================
# ШАГ 1: Останавливаю ВСЁ
# ============================================
echo -e "${YELLOW}[1/6] Останавливаю бота...${NC}"
systemctl --user stop openclaw-gateway-moa.service 2>/dev/null
pkill -9 -f "openclaw" 2>/dev/null
sleep 2
echo -e "  ${GREEN}✅ Остановлен${NC}"
echo ""

# ============================================
# ШАГ 2: Базовые проверки Telegram API
# ============================================
echo -e "${YELLOW}[2/6] Проверяю Telegram API (IPv4 принудительно)...${NC}"
echo ""

# getMe
echo "  a) getMe (информация о боте):"
GETME=$(curl -4 -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
echo "  $GETME" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if d.get('ok'):
    r=d['result']
    print(f\"  ✅ Бот: @{r['username']} (ID: {r['id']})  can_read_all_group_messages: {r.get('can_read_all_group_messages', '?')}\")
else:
    print(f\"  ❌ Ошибка: {d}\")
" 2>/dev/null
echo ""

# getWebhookInfo
echo "  b) getWebhookInfo:"
WHINFO=$(curl -4 -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo" 2>/dev/null)
echo "  RAW: $WHINFO" | head -c 300
echo ""
echo ""

# ============================================
# ШАГ 3: Проверяю offset — есть ли ЛЮБЫЕ updates
# ============================================
echo -e "${YELLOW}[3/6] Проверяю ВСЕ updates без offset (RAW)...${NC}"
echo ""

# Без offset и без timeout — просто покажи что есть
echo "  a) getUpdates без параметров:"
RAW1=$(curl -4 -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" 2>/dev/null)
echo "$RAW1" | python3 -c "
import sys,json
d=json.load(sys.stdin)
results = d.get('result',[])
print(f'  ok={d.get(\"ok\")}  updates={len(results)}')
for u in results[:5]:
    msg = u.get('message', u.get('edited_message', u.get('callback_query', {})))
    if isinstance(msg, dict):
        frm = msg.get('from', {})
        text = msg.get('text', msg.get('data', '<нет текста>'))
        print(f'    update_id={u[\"update_id\"]} from={frm.get(\"id\",\"?\")} (@{frm.get(\"username\",\"?\")}) text=\"{text}\"')
    else:
        print(f'    update_id={u[\"update_id\"]} type={list(u.keys())}')
if not results:
    print('  (пусто)')
" 2>/dev/null
echo ""

# ============================================
# ШАГ 4: Первая попытка long-poll
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${CYAN}  ПОПЫТКА 1 из 3${NC}"
echo -e "${CYAN}  ❗ ОТПРАВЬ СООБЩЕНИЕ @mycarmi_moa_bot${NC}"
echo -e "${CYAN}  ❗ ПРЯМО СЕЙЧАС! (жду 30 секунд)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

echo -e "${YELLOW}[4/6] Long-poll #1 (IPv4, 30 сек)...${NC}"
POLL1=$(curl -4 -s --max-time 35 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=30&allowed_updates=%5B%22message%22%5D" 2>/dev/null)
POLL1_EXIT=$?

echo "  curl exit code: $POLL1_EXIT"
echo "  RAW ответ (первые 500 символов):"
echo "  $POLL1" | head -c 500
echo ""

python3 << PYEOF1
import json
try:
    d = json.loads('''$POLL1''')
    results = d.get('result', [])
    print(f"  ok={d.get('ok')}  updates={len(results)}")
    if results:
        for u in results:
            msg = u.get('message', {})
            frm = msg.get('from', {})
            print(f"  ✅ UPDATE: id={u['update_id']} user_id={frm.get('id')} @{frm.get('username','?')} text=\"{msg.get('text','?')}\"")
    else:
        print("  ❌ Пусто")
except Exception as e:
    print(f"  Ошибка парсинга: {e}")
PYEOF1
echo ""

# ============================================
# ШАГ 5: Вторая попытка с другими параметрами
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${CYAN}  ПОПЫТКА 2 из 3${NC}"
echo -e "${CYAN}  ❗ ОТПРАВЬ ЕЩЁ ОДНО СООБЩЕНИЕ!${NC}"
echo -e "${CYAN}  ❗ (жду 30 секунд)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

echo -e "${YELLOW}[5/6] Long-poll #2 (без фильтров, 30 сек)...${NC}"
# Без allowed_updates фильтра — получаем ВСЁ
POLL2=$(curl -4 -s --max-time 35 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=30" 2>/dev/null)
POLL2_EXIT=$?

echo "  curl exit code: $POLL2_EXIT"
echo "  RAW ответ (первые 500 символов):"
echo "  $POLL2" | head -c 500
echo ""

python3 << PYEOF2
import json
try:
    d = json.loads('''$POLL2''')
    results = d.get('result', [])
    print(f"  ok={d.get('ok')}  updates={len(results)}")
    if results:
        for u in results:
            msg = u.get('message', {})
            frm = msg.get('from', {})
            print(f"  ✅ UPDATE: id={u['update_id']} user_id={frm.get('id')} @{frm.get('username','?')} text=\"{msg.get('text','?')}\"")
    else:
        print("  ❌ Пусто")
except Exception as e:
    print(f"  Ошибка парсинга: {e}")
PYEOF2
echo ""

# ============================================
# ШАГ 6: Проверяю не забанен ли бот / не удалён ли чат
# ============================================
echo -e "${YELLOW}[6/6] Пробую ОТПРАВИТЬ сообщение от бота...${NC}"
echo ""

# Попробуем отправить сообщение тебе (user ID 508602494)
SEND_RESP=$(curl -4 -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=508602494" \
    -d "text=🤖 Тестовое сообщение от бота! Если ты это видишь — связь бот→тебе работает." 2>/dev/null)

echo "  RAW: $SEND_RESP" | head -c 300
echo ""

python3 << PYEOF3
import json
try:
    d = json.loads('''$SEND_RESP''')
    if d.get('ok'):
        print("  ✅ Бот УСПЕШНО отправил тебе сообщение!")
        print("  Проверь Telegram — должно прийти тестовое сообщение.")
    else:
        err = d.get('description', '?')
        code = d.get('error_code', '?')
        print(f"  ❌ Ошибка отправки: [{code}] {err}")
        if 'blocked' in str(err).lower():
            print("  ⚠️  ТЫ ЗАБЛОКИРОВАЛ БОТА! Разблокируй его в Telegram!")
        elif 'chat not found' in str(err).lower():
            print("  ⚠️  Бот не знает этот чат. Нажми /start в чате с ботом!")
        elif 'Forbidden' in str(err):
            print("  ⚠️  Бот не может писать тебе. Нажми /start в чате с @mycarmi_moa_bot!")
except Exception as e:
    print(f"  Ошибка: {e}")
PYEOF3
echo ""

# ============================================
# ИТОГ
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ДИАГНОСТИКА ЗАВЕРШЕНА${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "  Скопируй ВЕСЬ вывод и отправь в Perplexity."
echo ""
echo "  Если бот отправил тебе тестовое сообщение,"
echo "  но getUpdates пустой — проблема в polling."
echo ""
echo "  Если бот НЕ смог отправить — нужно"
echo "  нажать /start в чате с @mycarmi_moa_bot."
echo ""
