#!/bin/bash
# ============================================
#  DEEP-DIAG — Глубокая диагностика и ремонт
# ============================================
#
#  Запуск: cd ~/vibe-coding && git pull && bash scripts/deep-diag.sh
#
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

GMKTEC_IP="192.168.0.72"

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  DEEP-DIAG — Глубокая диагностика${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================
# ТЕСТ 1: Groq API напрямую (минуя бота)
# ============================================
echo -e "${YELLOW}[1/8] Тестирую Groq API напрямую...${NC}"

# Берём Groq API key из конфига LiteLLM
GROQ_KEY=$(grep -A2 "groq" /home/mmber/litellm-config.yaml 2>/dev/null | grep "api_key" | head -1 | sed 's/.*: *//' | tr -d '"' | tr -d "'" | sed 's/os.environ\///')
if [ "$GROQ_KEY" = "GROQ_API_KEY" ] || [ -z "$GROQ_KEY" ]; then
    GROQ_KEY="${GROQ_API_KEY}"
fi

if [ -n "$GROQ_KEY" ] && [ "$GROQ_KEY" != "GROQ_API_KEY" ]; then
    GROQ_RESPONSE=$(curl -s --max-time 15 https://api.groq.com/openai/v1/chat/completions \
        -H "Authorization: Bearer $GROQ_KEY" \
        -H "Content-Type: application/json" \
        -d '{"model":"llama-3.3-70b-versatile","messages":[{"role":"user","content":"say hello"}],"max_tokens":10}' 2>/dev/null)
    
    if echo "$GROQ_RESPONSE" | grep -q "choices"; then
        echo -e "  ${GREEN}✅ Groq API работает напрямую${NC}"
        echo "  Ответ: $(echo $GROQ_RESPONSE | python3 -c 'import sys,json;print(json.load(sys.stdin)["choices"][0]["message"]["content"])' 2>/dev/null)"
    else
        echo -e "  ${RED}❌ Groq API НЕ работает${NC}"
        echo "  Ответ: $(echo $GROQ_RESPONSE | head -c 200)"
    fi
else
    echo -e "  ${YELLOW}⚠️  Groq API key не найден в litellm-config.yaml${NC}"
    echo "  Проверяю env..."
    if [ -n "$GROQ_API_KEY" ]; then
        echo "  GROQ_API_KEY задан в env"
    else
        echo -e "  ${RED}❌ GROQ_API_KEY отсутствует!${NC}"
    fi
fi
echo ""

# ============================================
# ТЕСТ 2: LiteLLM проксирование
# ============================================
echo -e "${YELLOW}[2/8] Тестирую LiteLLM проксирование...${NC}"

LITELLM_RESPONSE=$(curl -s --max-time 20 http://localhost:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"groq/llama-3.3-70b-versatile","messages":[{"role":"user","content":"say hello"}],"max_tokens":10}' 2>/dev/null)

if echo "$LITELLM_RESPONSE" | grep -q "choices"; then
    echo -e "  ${GREEN}✅ LiteLLM проксирует запросы к Groq${NC}"
    echo "  Ответ: $(echo $LITELLM_RESPONSE | python3 -c 'import sys,json;print(json.load(sys.stdin)["choices"][0]["message"]["content"])' 2>/dev/null)"
else
    echo -e "  ${RED}❌ LiteLLM НЕ проксирует${NC}"
    echo "  Ответ: $(echo $LITELLM_RESPONSE | head -c 300)"
fi
echo ""

# ============================================
# ТЕСТ 3: Ollama на GMKtec
# ============================================
echo -e "${YELLOW}[3/8] Тестирую Ollama на GMKtec ($GMKTEC_IP)...${NC}"

OLLAMA_MODELS=$(curl -s --max-time 5 http://$GMKTEC_IP:11434/api/tags 2>/dev/null)
if [ -n "$OLLAMA_MODELS" ]; then
    MODEL_COUNT=$(echo "$OLLAMA_MODELS" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null)
    echo -e "  ${GREEN}✅ Ollama доступна — моделей: $MODEL_COUNT${NC}"
    
    # Тестируем генерацию
    echo "  Тестирую генерацию (glm-4.7-flash)..."
    OLLAMA_GEN=$(curl -s --max-time 30 http://$GMKTEC_IP:11434/api/generate \
        -d '{"model":"huihui_ai/glm-4.7-flash-abliterated","prompt":"say hello","stream":false,"options":{"num_predict":10}}' 2>/dev/null)
    
    if echo "$OLLAMA_GEN" | grep -q "response"; then
        echo -e "  ${GREEN}✅ Ollama генерирует ответы${NC}"
        echo "  Ответ: $(echo $OLLAMA_GEN | python3 -c 'import sys,json;print(json.load(sys.stdin).get(\"response\",\"?\")[:100])' 2>/dev/null)"
    else
        echo -e "  ${RED}❌ Ollama не генерирует ответы${NC}"
        echo "  Ответ: $(echo $OLLAMA_GEN | head -c 200)"
    fi
else
    echo -e "  ${RED}❌ Ollama недоступна${NC}"
fi
echo ""

# ============================================
# ТЕСТ 4: Конфиг бота — все настройки
# ============================================
echo -e "${YELLOW}[4/8] Полный анализ конфига бота...${NC}"

python3 << 'PYEOF'
import json

with open('/home/mmber/.openclaw-moa/openclaw.json') as f:
    c = json.load(f)

# Providers
print("  ПРОВАЙДЕРЫ:")
providers = c.get('models', {}).get('providers', {})
for name, p in providers.items():
    url = p.get('baseUrl', '?')
    key = p.get('apiKey', '?')
    key_display = key[:10] + '...' if len(str(key)) > 10 else key
    models = [m.get('id','?') for m in p.get('models', [])]
    print(f"    {name}: url={url} key={key_display}")
    print(f"      модели: {', '.join(models)}")

# Defaults
defaults = c.get('agents', {}).get('defaults', {})
print(f"\n  МОДЕЛЬ ПО УМОЛЧАНИЮ:")
print(f"    {json.dumps(defaults.get('model', {}))}")

# Agents
agents = c.get('agents', {}).get('list', [])
print(f"\n  АГЕНТЫ ({len(agents)}):")
for i, a in enumerate(agents):
    model = a.get('model', 'default')
    name = a.get('name', f'агент-{i+1}')
    print(f"    {i+1}. {name} → {model}")

# Telegram
tg = c.get('channels', {}).get('telegram', {})
print(f"\n  TELEGRAM:")
print(f"    dmPolicy: {tg.get('dmPolicy', '?')}")
print(f"    allowFrom: {tg.get('allowFrom', 'все')}")

# Gateway
gw = c.get('gateway', {})
if gw:
    print(f"\n  GATEWAY:")
    print(f"    {json.dumps(gw, default=str)[:300]}")
PYEOF
echo ""

# ============================================
# ТЕСТ 5: OpenClaw версия и обновление
# ============================================
echo -e "${YELLOW}[5/8] Версия OpenClaw...${NC}"
OPENCLAW_VER=$(openclaw --version 2>/dev/null || echo "не найден")
echo "  Текущая: $OPENCLAW_VER"
echo ""

# ============================================
# ТЕСТ 6: Лог бота — ВСЕ строки после запуска
# ============================================
echo -e "${YELLOW}[6/8] Полный лог бота (последний запуск)...${NC}"
LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
if [ -f "$LOG_FILE" ]; then
    echo "  Размер лога: $(wc -l < $LOG_FILE) строк"
    echo ""
    echo "  === ПОСЛЕДНИЕ 30 СТРОК (читаемый формат) ==="
    tail -30 "$LOG_FILE" | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        ts = d.get('time','')[-12:]
        level = d.get('_meta',{}).get('logLevelName','?')
        msg1 = str(d.get('1', ''))[:120]
        msg0 = str(d.get('0', ''))[:60]
        msg2 = str(d.get('2', ''))[:60]
        out = f'  {ts} [{level:5}] {msg0}'
        if msg1 and msg1 != msg0:
            out += f' | {msg1}'
        if msg2:
            out += f' | {msg2}'
        print(out)
    except:
        print(f'  RAW: {line.strip()[:150]}')
"
else
    echo -e "  ${RED}Лог не найден${NC}"
fi
echo ""

# ============================================
# ТЕСТ 7: Порты и процессы
# ============================================
echo -e "${YELLOW}[7/8] Порты и процессы...${NC}"
echo "  Openclaw:"
ps aux | grep "openclaw" | grep -v grep | awk '{printf "    PID=%s RAM=%s%% CPU=%s%% CMD=%s\n", $2, $4, $3, $11}'
echo "  LiteLLM:"
ps aux | grep "litellm" | grep -v grep | awk '{printf "    PID=%s RAM=%s%% CMD=%s\n", $2, $4, $11}'
echo "  Порты:"
ss -tlnp 2>/dev/null | grep -E "8080|18790|18792|30000" | awk '{printf "    %s → %s\n", $4, $6}'
echo ""

# ============================================
# ТЕСТ 8: Тестовый запрос через OpenClaw Gateway
# ============================================
echo -e "${YELLOW}[8/8] Тестирую Gateway напрямую (порт 18790)...${NC}"
GW_TEST=$(curl -s --max-time 10 http://127.0.0.1:18790/ 2>/dev/null)
if [ -n "$GW_TEST" ]; then
    echo -e "  ${GREEN}✅ Gateway отвечает${NC}"
    echo "  Ответ: $(echo $GW_TEST | head -c 200)"
else
    echo -e "  ${RED}❌ Gateway не отвечает${NC}"
fi

# Тестируем v1/models
GW_MODELS=$(curl -s --max-time 10 http://127.0.0.1:18790/v1/models 2>/dev/null)
if [ -n "$GW_MODELS" ]; then
    echo "  Модели через Gateway: $(echo $GW_MODELS | head -c 300)"
fi
echo ""

# ============================================
# ИТОГ
# ============================================
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ДИАГНОСТИКА ЗАВЕРШЕНА${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "  Скопируй ВЕСЬ вывод и отправь в Perplexity."
echo "  Я найду проблему и починю."
echo ""
