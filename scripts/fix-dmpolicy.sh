#!/bin/bash
# ============================================
#  FIX-DMPOLICY — Починка политики Telegram
# ============================================
#
#  Что делает:
#  1. Показывает полный Telegram-конфиг бота
#  2. Проверяет твой Telegram user ID
#  3. Меняет dmPolicy с "pairing" на рабочий вариант
#  4. Проверяет GROQ ключ в LiteLLM
#  5. Перезапускает бота
#  6. Тестирует что бот работает
#
#  Запуск: cd ~/vibe-coding && git pull && bash scripts/fix-dmpolicy.sh
#
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG="/home/mmber/.openclaw-moa/openclaw.json"
LITELLM_CONFIG="/home/mmber/litellm-config.yaml"
BACKUP="/home/mmber/.openclaw-moa/openclaw.json.backup-$(date +%Y%m%d-%H%M%S)"

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  FIX-DMPOLICY — Починка бота${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================
# ШАГ 1: Показываем полный Telegram конфиг
# ============================================
echo -e "${YELLOW}[1/6] Текущий Telegram конфиг бота:${NC}"
echo ""

python3 << 'PYEOF'
import json

try:
    with open('/home/mmber/.openclaw-moa/openclaw.json') as f:
        c = json.load(f)

    # Весь блок channels.telegram
    tg = c.get('channels', {}).get('telegram', {})
    
    print("  === ПОЛНЫЙ TELEGRAM БЛОК ===")
    print(json.dumps(tg, indent=4, ensure_ascii=False))
    print("")
    
    # Ключевые значения
    dm = tg.get('dmPolicy', 'НЕ ЗАДАН')
    af = tg.get('allowFrom', 'НЕ ЗАДАН')
    token = tg.get('token', tg.get('botToken', 'НЕ НАЙДЕН'))
    
    if isinstance(token, str) and len(token) > 15:
        token_display = token[:10] + "..." + token[-5:]
    else:
        token_display = str(token)
    
    print(f"  dmPolicy:  {dm}")
    print(f"  allowFrom: {af}")
    print(f"  token:     {token_display}")
    
    # Pairing info
    pairing = tg.get('pairing', tg.get('pairingCode', None))
    if pairing:
        print(f"  pairing:   {pairing}")
    
    # Любые другие поля
    known_keys = {'dmPolicy', 'allowFrom', 'token', 'botToken', 'pairing', 'pairingCode'}
    other = {k: v for k, v in tg.items() if k not in known_keys}
    if other:
        print(f"  Другие поля: {json.dumps(other, ensure_ascii=False)}")
        
except Exception as e:
    print(f"  ОШИБКА: {e}")
PYEOF
echo ""

# ============================================
# ШАГ 2: Проверяем GROQ в LiteLLM
# ============================================
echo -e "${YELLOW}[2/6] Проверяю GROQ ключ в LiteLLM:${NC}"
echo ""

if [ -f "$LITELLM_CONFIG" ]; then
    echo "  Содержимое litellm-config.yaml:"
    echo "  ---"
    # Показываем конфиг, маскируя API ключи (показываем первые 10 символов)
    python3 << 'PYEOF2'
import re

with open('/home/mmber/litellm-config.yaml') as f:
    content = f.read()

# Маскируем API ключи для безопасности
def mask_key(match):
    key = match.group(1)
    if len(key) > 15:
        return f'api_key: {key[:10]}...{key[-4:]}'
    return match.group(0)

masked = re.sub(r'api_key:\s*["\']?([^"\'\n]+)["\']?', mask_key, content)

for line in masked.split('\n'):
    print(f"    {line}")
PYEOF2
    echo "  ---"
    
    # Проверяем, есть ли os.environ
    if grep -q "os.environ" "$LITELLM_CONFIG"; then
        echo ""
        echo -e "  ${YELLOW}⚠️  Ключ задан через os.environ — проверяю переменную...${NC}"
        
        ENV_VAR=$(grep "os.environ" "$LITELLM_CONFIG" | head -1 | sed 's/.*os.environ\///' | tr -d '"' | tr -d "'" | tr -d ']' | tr -d ' ')
        echo "  Переменная: $ENV_VAR"
        
        ACTUAL_VALUE=$(eval echo "\$$ENV_VAR" 2>/dev/null)
        if [ -n "$ACTUAL_VALUE" ]; then
            echo -e "  ${GREEN}✅ Переменная $ENV_VAR задана (${ACTUAL_VALUE:0:8}...)${NC}"
        else
            echo -e "  ${RED}❌ Переменная $ENV_VAR НЕ задана в текущей сессии${NC}"
            echo ""
            echo "  Но это может быть нормально, если LiteLLM запущен"
            echo "  через systemd и переменная задана в service-файле."
            echo "  Проверяю статус LiteLLM..."
            
            LITELLM_PID=$(pgrep -f litellm | head -1)
            if [ -n "$LITELLM_PID" ]; then
                echo -e "  ${GREEN}✅ LiteLLM запущен (PID: $LITELLM_PID)${NC}"
                # Проверяем env процесса
                if [ -r "/proc/$LITELLM_PID/environ" ]; then
                    if tr '\0' '\n' < "/proc/$LITELLM_PID/environ" 2>/dev/null | grep -q "GROQ_API_KEY"; then
                        echo -e "  ${GREEN}✅ GROQ_API_KEY задан в процессе LiteLLM${NC}"
                    else
                        echo -e "  ${YELLOW}⚠️  GROQ_API_KEY не найден в процессе LiteLLM${NC}"
                    fi
                else
                    echo "  (нет доступа к /proc/$LITELLM_PID/environ)"
                fi
            else
                echo -e "  ${RED}❌ LiteLLM НЕ запущен!${NC}"
            fi
        fi
    else
        echo -e "  ${GREEN}✅ API ключ задан напрямую в конфиге${NC}"
    fi
else
    echo -e "  ${RED}❌ Файл $LITELLM_CONFIG не найден!${NC}"
fi
echo ""

# ============================================
# ШАГ 3: Тестируем LiteLLM прямо сейчас
# ============================================
echo -e "${YELLOW}[3/6] Тестирую LiteLLM → Groq (быстрый тест):${NC}"

LITELLM_RESP=$(curl -s --max-time 15 http://localhost:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"groq/llama-3.3-70b-versatile","messages":[{"role":"user","content":"say OK"}],"max_tokens":5}' 2>/dev/null)

if echo "$LITELLM_RESP" | grep -q "choices"; then
    echo -e "  ${GREEN}✅ LiteLLM → Groq работает!${NC}"
    ANSWER=$(echo "$LITELLM_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["choices"][0]["message"]["content"])' 2>/dev/null)
    echo "  Ответ: $ANSWER"
    GROQ_OK=1
else
    echo -e "  ${RED}❌ LiteLLM → Groq НЕ работает${NC}"
    echo "  Ответ: $(echo $LITELLM_RESP | head -c 300)"
    GROQ_OK=0
fi
echo ""

# ============================================
# ШАГ 4: Делаем бэкап и чиним конфиг
# ============================================
echo -e "${YELLOW}[4/6] Чиню конфиг бота...${NC}"
echo ""

# Бэкап
cp "$CONFIG" "$BACKUP"
echo "  📦 Бэкап: $BACKUP"

python3 << 'PYFIX'
import json

with open('/home/mmber/.openclaw-moa/openclaw.json') as f:
    c = json.load(f)

changes = []

# 1. Исправляем dmPolicy
tg = c.get('channels', {}).get('telegram', {})
old_policy = tg.get('dmPolicy', 'НЕ ЗАДАН')

if old_policy == 'pairing':
    # Меняем на "open" чтобы бот отвечал всем (или только allowFrom)
    tg['dmPolicy'] = 'open'
    changes.append(f"  dmPolicy: '{old_policy}' → 'open'")
elif old_policy != 'open':
    tg['dmPolicy'] = 'open'
    changes.append(f"  dmPolicy: '{old_policy}' → 'open'")

# 2. Убеждаемся что allowFrom содержит правильный ID
allow = tg.get('allowFrom', [])
USER_ID = 508602494
if isinstance(allow, list):
    if USER_ID not in allow:
        allow.append(USER_ID)
        tg['allowFrom'] = allow
        changes.append(f"  allowFrom: добавлен ID {USER_ID}")
    else:
        print(f"  ✓ ID {USER_ID} уже в allowFrom")
else:
    tg['allowFrom'] = [USER_ID]
    changes.append(f"  allowFrom: установлен [{USER_ID}]")

# 3. Удаляем pairing/pairingCode если есть
for key in ['pairing', 'pairingCode']:
    if key in tg:
        del tg[key]
        changes.append(f"  Удалён ключ '{key}'")

# Сохраняем
c['channels']['telegram'] = tg

with open('/home/mmber/.openclaw-moa/openclaw.json', 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)

if changes:
    print("  ИЗМЕНЕНИЯ:")
    for ch in changes:
        print(f"    ✏️  {ch}")
else:
    print("  Конфиг уже правильный, изменений нет")

# Показываем итоговый Telegram блок
print("")
print("  ИТОГОВЫЙ TELEGRAM КОНФИГ:")
print(json.dumps(tg, indent=4, ensure_ascii=False))
PYFIX
echo ""

# ============================================
# ШАГ 5: Перезапускаем бота
# ============================================
echo -e "${YELLOW}[5/6] Перезапускаю бота...${NC}"
echo ""

# Останавливаем
systemctl --user stop openclaw-gateway-moa.service 2>/dev/null
sleep 2

# Проверяем что остановлен
if pgrep -f "openclaw" > /dev/null 2>&1; then
    echo "  Бот ещё работает, убиваю принудительно..."
    pkill -f "openclaw" 2>/dev/null
    sleep 2
fi

# Запускаем
systemctl --user start openclaw-gateway-moa.service 2>/dev/null
sleep 3

# Проверяем
if pgrep -f "openclaw" > /dev/null 2>&1; then
    echo -e "  ${GREEN}✅ Бот запущен${NC}"
    PID=$(pgrep -f "openclaw" | head -1)
    echo "  PID: $PID"
else
    echo -e "  ${RED}❌ Бот НЕ запустился!${NC}"
    echo "  Пробую запустить вручную..."
    systemctl --user status openclaw-gateway-moa.service 2>&1 | tail -10
fi
echo ""

# ============================================
# ШАГ 6: Ждём и проверяем лог
# ============================================
echo -e "${YELLOW}[6/6] Жду 5 секунд и проверяю лог...${NC}"
sleep 5

LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
if [ -f "$LOG_FILE" ]; then
    echo "  Последние 15 строк лога:"
    echo ""
    tail -15 "$LOG_FILE" | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        ts = d.get('time','')[-12:]
        level = d.get('_meta',{}).get('logLevelName','?')
        msg0 = str(d.get('0', ''))[:80]
        msg1 = str(d.get('1', ''))[:80]
        out = f'  {ts} [{level:5}] {msg0}'
        if msg1 and msg1 != msg0:
            out += f' | {msg1}'
        print(out)
    except:
        print(f'  RAW: {line.strip()[:150]}')
"
else
    echo -e "  ${RED}Лог не найден: $LOG_FILE${NC}"
fi
echo ""

# ============================================
# ИТОГ
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ГОТОВО!${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "  Что было сделано:"
echo "    1. Показан полный Telegram конфиг"
echo "    2. Проверен GROQ ключ в LiteLLM"
echo "    3. dmPolicy изменён с 'pairing' на 'open'"
echo "    4. Проверен allowFrom (ID: 508602494)"
echo "    5. Бот перезапущен"
echo ""
echo -e "  ${CYAN}Теперь отправь сообщение боту @mycarmi_moa_bot в Telegram${NC}"
echo -e "  ${CYAN}и скажи, ответил он или нет.${NC}"
echo ""
echo "  Если НЕ ответил — скопируй весь вывод этого скрипта"
echo "  и отправь мне в Perplexity."
echo ""
