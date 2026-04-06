#!/bin/bash
# ============================================
#  FIX-BOT-V2 — Полная починка бота и LiteLLM
# ============================================
#
#  Что делает:
#  1. Исправляет dmPolicy → "allowlist" (чтобы бот отвечал
#     только тебе, по списку allowFrom)
#  2. Исправляет IP Ollama в litellm-config.yaml
#     (старый 192.168.137.2 → новый 192.168.0.72)
#  3. Перезапускает LiteLLM
#  4. Перезапускает бота
#  5. Проверяет лог
#
#  Запуск: cd ~/vibe-coding && git pull && bash scripts/fix-bot-v2.sh
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

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  FIX-BOT-V2 — Полная починка${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================
# ШАГ 1: Починка OpenClaw конфига
# ============================================
echo -e "${YELLOW}[1/5] Чиню конфиг OpenClaw (dmPolicy → allowlist)...${NC}"
echo ""

# Бэкап
BACKUP="${OPENCLAW_CONFIG}.backup-$(date +%Y%m%d-%H%M%S)"
cp "$OPENCLAW_CONFIG" "$BACKUP"
echo "  📦 Бэкап: $BACKUP"
echo ""

python3 << 'PYEOF'
import json

config_path = '/home/mmber/.openclaw-moa/openclaw.json'

with open(config_path) as f:
    c = json.load(f)

tg = c.get('channels', {}).get('telegram', {})
changes = []

# ИСПРАВЛЕНИЕ: dmPolicy = "allowlist" + allowFrom = [508602494]
# Это значит: бот отвечает ТОЛЬКО пользователям из списка allowFrom
old_policy = tg.get('dmPolicy', '?')
tg['dmPolicy'] = 'allowlist'
if old_policy != 'allowlist':
    changes.append(f"dmPolicy: '{old_policy}' → 'allowlist'")

# Убеждаемся что allowFrom правильный
tg['allowFrom'] = [508602494]
changes.append("allowFrom: [508602494] (твой Telegram ID)")

# Удаляем pairing/pairingCode если есть
for key in ['pairing', 'pairingCode']:
    if key in tg:
        del tg[key]
        changes.append(f"Удалён ключ '{key}'")

c['channels']['telegram'] = tg

with open(config_path, 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)

print("  ИЗМЕНЕНИЯ OpenClaw:")
for ch in changes:
    print(f"    ✏️  {ch}")

print("")
print("  ИТОГОВЫЙ TELEGRAM КОНФИГ:")
print(json.dumps(tg, indent=4, ensure_ascii=False))
PYEOF
echo ""

# ============================================
# ШАГ 2: Починка IP Ollama в LiteLLM
# ============================================
echo -e "${YELLOW}[2/5] Чиню IP Ollama в LiteLLM (137.2 → 0.72)...${NC}"
echo ""

if [ -f "$LITELLM_CONFIG" ]; then
    # Считаем сколько строк со старым IP
    OLD_COUNT=$(grep -c "192.168.137.2" "$LITELLM_CONFIG" 2>/dev/null)
    
    if [ "$OLD_COUNT" -gt 0 ]; then
        # Бэкап LiteLLM
        cp "$LITELLM_CONFIG" "${LITELLM_CONFIG}.backup-$(date +%Y%m%d-%H%M%S)"
        
        # Заменяем все вхождения старого IP на новый
        sed -i 's/192\.168\.137\.2/192.168.0.72/g' "$LITELLM_CONFIG"
        
        NEW_COUNT=$(grep -c "192.168.0.72" "$LITELLM_CONFIG" 2>/dev/null)
        echo -e "  ${GREEN}✅ Заменено $OLD_COUNT вхождений старого IP${NC}"
        echo "  Старый: 192.168.137.2"
        echo "  Новый:  192.168.0.72"
        echo "  Строк с новым IP: $NEW_COUNT"
        LITELLM_CHANGED=1
    else
        echo "  IP уже правильный (192.168.0.72), менять не нужно"
        LITELLM_CHANGED=0
    fi
else
    echo -e "  ${RED}❌ Файл $LITELLM_CONFIG не найден!${NC}"
    LITELLM_CHANGED=0
fi
echo ""

# ============================================
# ШАГ 3: Перезапуск LiteLLM (если менялся конфиг)
# ============================================
echo -e "${YELLOW}[3/5] Перезапускаю LiteLLM...${NC}"
echo ""

if [ "$LITELLM_CHANGED" = "1" ]; then
    echo "  Конфиг LiteLLM изменился — перезапускаю..."
    
    # Ищем как запущен LiteLLM
    LITELLM_PID=$(pgrep -f "litellm" | head -1)
    
    if [ -n "$LITELLM_PID" ]; then
        # Смотрим команду запуска
        LITELLM_CMD=$(ps -p $LITELLM_PID -o args= 2>/dev/null)
        echo "  Текущий процесс: PID=$LITELLM_PID"
        echo "  Команда: $LITELLM_CMD"
        
        # Пробуем через systemd
        if systemctl --user is-active litellm.service > /dev/null 2>&1; then
            echo "  Перезапуск через systemd..."
            systemctl --user restart litellm.service
            sleep 3
        elif systemctl --user is-active litellm > /dev/null 2>&1; then
            systemctl --user restart litellm
            sleep 3
        else
            # Убиваем и перезапускаем вручную
            echo "  Убиваю старый процесс..."
            kill $LITELLM_PID 2>/dev/null
            sleep 2
            
            # Перезапускаем из того же конфига
            echo "  Запускаю LiteLLM заново..."
            nohup litellm --config "$LITELLM_CONFIG" --port 8080 > /tmp/litellm.log 2>&1 &
            sleep 3
        fi
    else
        echo "  LiteLLM не был запущен — запускаю..."
        nohup litellm --config "$LITELLM_CONFIG" --port 8080 > /tmp/litellm.log 2>&1 &
        sleep 3
    fi
    
    # Проверяем
    if pgrep -f "litellm" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✅ LiteLLM запущен${NC}"
    else
        echo -e "  ${RED}❌ LiteLLM не запустился!${NC}"
    fi
else
    echo "  Конфиг не менялся — пропускаю перезапуск"
fi
echo ""

# Быстрый тест LiteLLM
echo "  Тестирую LiteLLM → Groq..."
LITELLM_RESP=$(curl -s --max-time 15 http://localhost:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"groq/llama-3.3-70b-versatile","messages":[{"role":"user","content":"say OK"}],"max_tokens":5}' 2>/dev/null)

if echo "$LITELLM_RESP" | grep -q "choices"; then
    echo -e "  ${GREEN}✅ LiteLLM → Groq работает${NC}"
else
    echo -e "  ${RED}❌ LiteLLM → Groq НЕ работает${NC}"
    echo "  Ответ: $(echo $LITELLM_RESP | head -c 200)"
fi
echo ""

# ============================================
# ШАГ 4: Перезапуск бота
# ============================================
echo -e "${YELLOW}[4/5] Перезапускаю бота OpenClaw...${NC}"
echo ""

# Останавливаем
systemctl --user stop openclaw-gateway-moa.service 2>/dev/null
sleep 2

# Убиваем если остался
pkill -f "openclaw" 2>/dev/null
sleep 1

# Запускаем
systemctl --user start openclaw-gateway-moa.service 2>/dev/null
sleep 4

# Проверяем
if pgrep -f "openclaw" > /dev/null 2>&1; then
    BOT_PID=$(pgrep -f "openclaw" | head -1)
    echo -e "  ${GREEN}✅ Бот запущен (PID: $BOT_PID)${NC}"
    BOT_OK=1
else
    echo -e "  ${RED}❌ Бот НЕ запустился через systemd${NC}"
    echo ""
    echo "  Пробую запустить напрямую для отладки..."
    echo "  (вывод первые 10 секунд)"
    echo ""
    timeout 10 /home/mmber/.nvm/versions/node/v22.22.0/bin/node \
        /home/mmber/.nvm/versions/node/v22.22.0/lib/node_modules/openclaw/dist/index.js \
        gateway --port 18790 --profile moa 2>&1 | head -30
    echo ""
    BOT_OK=0
fi
echo ""

# ============================================
# ШАГ 5: Проверяем лог
# ============================================
echo -e "${YELLOW}[5/5] Проверяю лог бота...${NC}"
echo ""

LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
if [ -f "$LOG_FILE" ]; then
    echo "  Последние 20 строк лога:"
    echo ""
    tail -20 "$LOG_FILE" | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        ts = d.get('time','')[-12:]
        level = d.get('_meta',{}).get('logLevelName','?')
        msg0 = str(d.get('0', ''))[:100]
        msg1 = str(d.get('1', ''))[:100]
        out = f'  {ts} [{level:5}] {msg0}'
        if msg1 and msg1 != msg0:
            out += f' | {msg1}'
        print(out)
    except:
        print(f'  RAW: {line.strip()[:150]}')
"
else
    echo "  Лог не найден"
fi
echo ""

# ============================================
# ИТОГ
# ============================================
echo -e "${BLUE}============================================${NC}"
if [ "$BOT_OK" = "1" ]; then
    echo -e "${GREEN}  ✅ БОТ ЗАПУЩЕН!${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    echo "  Что исправлено:"
    echo "    1. dmPolicy: 'pairing' → 'allowlist'"
    echo "    2. IP Ollama: 192.168.137.2 → 192.168.0.72"
    echo "    3. LiteLLM перезапущен"
    echo "    4. Бот перезапущен"
    echo ""
    echo -e "  ${CYAN}Отправь сообщение боту @mycarmi_moa_bot в Telegram${NC}"
    echo -e "  ${CYAN}и скажи мне, ответил или нет.${NC}"
else
    echo -e "${RED}  ❌ БОТ НЕ ЗАПУСТИЛСЯ${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    echo "  Скопируй ВЕСЬ вывод выше и отправь в Perplexity."
    echo "  Я разберусь что не так."
fi
echo ""
