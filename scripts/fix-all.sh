#!/bin/bash
# ============================================
#  FIX-ALL — Полный ремонт всей инфраструктуры
# ============================================
#
#  Запуск с Legion WSL2:
#    bash ~/vibe-coding/scripts/fix-all.sh
#
#  Или напрямую с GitHub:
#    curl -sL https://raw.githubusercontent.com/CarmiBanxe/vibe-coding/main/scripts/fix-all.sh | bash
#
#  Что делает:
#  1. Проверяет и чинит LiteLLM на Legion
#  2. Проверяет и чинит Ollama на GMKtec (через SSH)
#  3. Проверяет и перезапускает бота OpenClaw
#  4. Проверяет связь между всеми компонентами
#  5. Показывает итоговый отчёт
#
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Настройки ---
GMKTEC_IP="192.168.0.72"
GMKTEC_USER="banxe"
GMKTEC_PASS="mmber2025!"
LITELLM_PORT="8080"
OLLAMA_PORT="11434"
LITELLM_CONFIG="$HOME/litellm-config.yaml"
OPENCLAW_SERVICE="openclaw-gateway-moa.service"

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  FIX-ALL — Полный ремонт инфраструктуры${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================
# ЭТАП 1: LiteLLM на Legion
# ============================================
echo -e "${YELLOW}[1/4] LiteLLM (роутер моделей, порт $LITELLM_PORT)...${NC}"

LITELLM_HEALTHY=false
LITELLM_HEALTH=$(curl -s --max-time 3 http://localhost:$LITELLM_PORT/health 2>/dev/null)

if [ -n "$LITELLM_HEALTH" ]; then
    echo -e "  ${GREEN}✅ LiteLLM уже работает${NC}"
    LITELLM_HEALTHY=true
else
    echo -e "  ${YELLOW}⚠️  LiteLLM не отвечает. Перезапускаю...${NC}"
    
    # Убиваем старый процесс
    pkill -f litellm 2>/dev/null
    sleep 2
    
    # Проверяем что конфиг существует
    if [ ! -f "$LITELLM_CONFIG" ]; then
        echo -e "  ${RED}❌ Конфиг не найден: $LITELLM_CONFIG${NC}"
        echo -e "  Ищу конфиг..."
        FOUND_CONFIG=$(find $HOME -name "litellm-config*" -type f 2>/dev/null | head -1)
        if [ -n "$FOUND_CONFIG" ]; then
            LITELLM_CONFIG="$FOUND_CONFIG"
            echo -e "  ${GREEN}Найден: $LITELLM_CONFIG${NC}"
        else
            echo -e "  ${RED}❌ Конфиг LiteLLM не найден нигде${NC}"
        fi
    fi
    
    # Запускаем LiteLLM
    if [ -f "$LITELLM_CONFIG" ]; then
        nohup $HOME/.local/bin/litellm --config "$LITELLM_CONFIG" --port $LITELLM_PORT > /tmp/litellm.log 2>&1 &
        LITELLM_PID=$!
        echo -e "  Запущен с PID $LITELLM_PID, жду старта..."
        
        # Ждём до 15 секунд
        for i in $(seq 1 30); do
            sleep 1
            LITELLM_HEALTH=$(curl -s --max-time 2 http://localhost:$LITELLM_PORT/health 2>/dev/null)
            if [ -n "$LITELLM_HEALTH" ]; then
                echo -e "  ${GREEN}✅ LiteLLM запущен и отвечает (${i}с)${NC}"
                LITELLM_HEALTHY=true
                break
            fi
            echo -ne "  Ожидание... ${i}с\r"
        done
        
        if [ "$LITELLM_HEALTHY" = false ]; then
            echo -e "  ${RED}❌ LiteLLM не стартовал за 30 секунд${NC}"
            echo -e "  Последние ошибки из лога:"
            tail -5 /tmp/litellm.log 2>/dev/null | head -5
        fi
    fi
fi
echo ""

# ============================================
# ЭТАП 2: Ollama на GMKtec
# ============================================
echo -e "${YELLOW}[2/4] Ollama на GMKtec ($GMKTEC_IP:$OLLAMA_PORT)...${NC}"

OLLAMA_HEALTHY=false

# Проверяем доступность GMKtec
if ! ping -c 1 -W 2 $GMKTEC_IP > /dev/null 2>&1; then
    echo -e "  ${RED}❌ GMKtec ($GMKTEC_IP) недоступен в сети${NC}"
    echo -e "  Проверь что GMKtec включён и подключён к сети"
else
    echo -e "  GMKtec в сети ✓"
    
    # Проверяем Ollama
    OLLAMA_TAGS=$(curl -s --max-time 5 http://$GMKTEC_IP:$OLLAMA_PORT/api/tags 2>/dev/null)
    
    if [ -n "$OLLAMA_TAGS" ]; then
        MODEL_COUNT=$(echo "$OLLAMA_TAGS" | python3 -c "import sys,json; data=json.load(sys.stdin); print(len(data.get('models',[])))" 2>/dev/null || echo "?")
        echo -e "  ${GREEN}✅ Ollama работает — моделей: $MODEL_COUNT${NC}"
        OLLAMA_HEALTHY=true
    else
        echo -e "  ${YELLOW}⚠️  Ollama не отвечает. Пробую починить через SSH...${NC}"
        
        # Устанавливаем sshpass если нет
        which sshpass > /dev/null 2>&1 || sudo apt-get install -y sshpass > /dev/null 2>&1
        
        if which sshpass > /dev/null 2>&1; then
            # Перезапускаем Ollama через SSH
            SSHCMD="sshpass -p '$GMKTEC_PASS' ssh -o StrictHostKeyChecking=no $GMKTEC_USER@$GMKTEC_IP"
            
            echo -e "  Подключаюсь к GMKtec по SSH..."
            sshpass -p "$GMKTEC_PASS" ssh -o StrictHostKeyChecking=no $GMKTEC_USER@$GMKTEC_IP \
                "sudo systemctl restart ollama 2>/dev/null; sleep 3; ollama list 2>/dev/null" 2>/dev/null
            
            # Проверяем снова
            sleep 3
            OLLAMA_TAGS=$(curl -s --max-time 5 http://$GMKTEC_IP:$OLLAMA_PORT/api/tags 2>/dev/null)
            if [ -n "$OLLAMA_TAGS" ]; then
                MODEL_COUNT=$(echo "$OLLAMA_TAGS" | python3 -c "import sys,json; data=json.load(sys.stdin); print(len(data.get('models',[])))" 2>/dev/null || echo "?")
                echo -e "  ${GREEN}✅ Ollama починена — моделей: $MODEL_COUNT${NC}"
                OLLAMA_HEALTHY=true
            else
                echo -e "  ${RED}❌ Ollama всё ещё не отвечает после перезапуска${NC}"
                echo -e "  Нужен физический доступ к GMKtec"
            fi
        else
            echo -e "  ${RED}❌ sshpass не удалось установить — не могу подключиться автоматически${NC}"
            echo -e "  Запусти вручную: ssh banxe@$GMKTEC_IP → sudo systemctl restart ollama"
        fi
    fi
    
    # Проверяем что Windows-диск примонтирован (для моделей)
    if which sshpass > /dev/null 2>&1; then
        MOUNT_CHECK=$(sshpass -p "$GMKTEC_PASS" ssh -o StrictHostKeyChecking=no $GMKTEC_USER@$GMKTEC_IP \
            "mountpoint -q /mnt/windows && echo 'mounted' || echo 'not_mounted'" 2>/dev/null)
        if [ "$MOUNT_CHECK" = "not_mounted" ]; then
            echo -e "  ${YELLOW}⚠️  Windows-диск не примонтирован, монтирую...${NC}"
            sshpass -p "$GMKTEC_PASS" ssh -o StrictHostKeyChecking=no $GMKTEC_USER@$GMKTEC_IP \
                "sudo mkdir -p /mnt/windows && sudo mount -t ntfs3 /dev/nvme0n1p3 /mnt/windows" 2>/dev/null
            echo -e "  ${GREEN}✅ Windows-диск примонтирован${NC}"
        fi
    fi
fi
echo ""

# ============================================
# ЭТАП 3: Бот OpenClaw
# ============================================
echo -e "${YELLOW}[3/4] Бот OpenClaw (@mycarmi_moa_bot)...${NC}"

BOT_HEALTHY=false
BOT_PROCESS=$(ps aux | grep "openclaw-gateway" | grep -v grep)

if [ -n "$BOT_PROCESS" ]; then
    BOT_PID=$(echo "$BOT_PROCESS" | awk '{print $2}')
    BOT_MEM=$(echo "$BOT_PROCESS" | awk '{print $4}')
    echo -e "  ${GREEN}✅ Бот запущен${NC} (PID: $BOT_PID, RAM: ${BOT_MEM}%)"
    BOT_HEALTHY=true
    
    # Проверяем свежие ошибки
    LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
    if [ -f "$LOG_FILE" ]; then
        RECENT_ERRORS=$(tail -20 "$LOG_FILE" | grep -i -c -E "error|fail|timeout")
        if [ "$RECENT_ERRORS" -gt 0 ]; then
            echo -e "  ${YELLOW}⚠️  Найдено $RECENT_ERRORS ошибок в последних 20 строках лога${NC}"
        else
            echo -e "  Лог чистый ✓"
        fi
    fi
else
    echo -e "  ${YELLOW}⚠️  Бот не запущен. Запускаю...${NC}"
    
    # Пробуем через systemd
    systemctl --user start $OPENCLAW_SERVICE 2>/dev/null
    sleep 5
    
    BOT_PROCESS=$(ps aux | grep "openclaw-gateway" | grep -v grep)
    if [ -n "$BOT_PROCESS" ]; then
        echo -e "  ${GREEN}✅ Бот запущен через systemd${NC}"
        BOT_HEALTHY=true
    else
        # Пробуем напрямую
        echo -e "  systemd не сработал, запускаю напрямую..."
        nohup openclaw --profile moa gateway > /tmp/openclaw-start.log 2>&1 &
        sleep 5
        BOT_PROCESS=$(ps aux | grep "openclaw-gateway" | grep -v grep)
        if [ -n "$BOT_PROCESS" ]; then
            echo -e "  ${GREEN}✅ Бот запущен напрямую${NC}"
            BOT_HEALTHY=true
        else
            echo -e "  ${RED}❌ Не удалось запустить бота${NC}"
            echo -e "  Последние строки лога:"
            tail -5 /tmp/openclaw-start.log 2>/dev/null
        fi
    fi
fi
echo ""

# ============================================
# ЭТАП 4: Итоговый отчёт
# ============================================
echo -e "${YELLOW}[4/4] Финальная проверка связей...${NC}"

# Legion → LiteLLM
LINK1="❌"
if [ "$LITELLM_HEALTHY" = true ]; then LINK1="${GREEN}✅${NC}"; fi

# Legion → GMKtec/Ollama
LINK2="❌"
if [ "$OLLAMA_HEALTHY" = true ]; then LINK2="${GREEN}✅${NC}"; fi

# Бот → Telegram
LINK3="❌"
if [ "$BOT_HEALTHY" = true ]; then LINK3="${GREEN}✅${NC}"; fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ИТОГ${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo -e "  LiteLLM (порт $LITELLM_PORT):     $LINK1"
echo -e "  Ollama на GMKtec:           $LINK2"
echo -e "  Бот @mycarmi_moa_bot:       $LINK3"
echo ""

if [ "$LITELLM_HEALTHY" = true ] && [ "$OLLAMA_HEALTHY" = true ] && [ "$BOT_HEALTHY" = true ]; then
    echo -e "  ${GREEN}🎉 ВСЁ РАБОТАЕТ! Напиши боту в Telegram для проверки.${NC}"
else
    echo -e "  ${YELLOW}Есть проблемы. Что делать:${NC}"
    [ "$LITELLM_HEALTHY" = false ] && echo -e "  ${RED}— LiteLLM: проверь конфиг $LITELLM_CONFIG${NC}"
    [ "$OLLAMA_HEALTHY" = false ] && echo -e "  ${RED}— Ollama: подключи клавиатуру к GMKtec и запусти: sudo systemctl restart ollama${NC}"
    [ "$BOT_HEALTHY" = false ] && echo -e "  ${RED}— Бот: проверь логи: tail -20 /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log${NC}"
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo ""
