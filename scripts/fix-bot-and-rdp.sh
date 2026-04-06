#!/bin/bash
# ============================================
#  FIX-BOT-AND-RDP
# ============================================
#
#  Что делает:
#  1. Перезапускает бота (чтобы подхватил рабочую Ollama)
#  2. Настраивает RDP на GMKtec (чтобы управлять через экран)
#  3. Настраивает клавиатуру на GMKtec (русская + английская)
#  4. Проверяет что всё работает
#
#  Запуск с Legion WSL2:
#    cd ~/vibe-coding && git pull && bash scripts/fix-bot-and-rdp.sh
#
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

GMKTEC_IP="192.168.0.72"
GMKTEC_USER="banxe"
GMKTEC_PASS="mmber2025!"

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  FIX-BOT-AND-RDP${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# --- Устанавливаем sshpass если нет ---
if ! which sshpass > /dev/null 2>&1; then
    echo -e "${YELLOW}Устанавливаю sshpass (нужен для автоматического SSH)...${NC}"
    sudo apt-get install -y sshpass > /dev/null 2>&1
fi

# Функция для SSH команд на GMKtec
run_gmktec() {
    sshpass -p "$GMKTEC_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 $GMKTEC_USER@$GMKTEC_IP "$1" 2>/dev/null
}

# Проверяем SSH
echo -e "${YELLOW}[0/4] Проверяю SSH к GMKtec...${NC}"
SSH_TEST=$(run_gmktec "echo 'ok'" 2>/dev/null)
if [ "$SSH_TEST" != "ok" ]; then
    echo -e "  ${RED}❌ Не могу подключиться к GMKtec по SSH${NC}"
    echo -e "  Проверь: ssh banxe@$GMKTEC_IP (пароль: $GMKTEC_PASS)"
    exit 1
fi
echo -e "  ${GREEN}✅ SSH работает${NC}"
echo ""

# ============================================
# ЭТАП 1: Перезапуск бота
# ============================================
echo -e "${YELLOW}[1/4] Перезапускаю бота OpenClaw...${NC}"

# Останавливаем старый процесс
systemctl --user stop openclaw-gateway-moa.service 2>/dev/null
pkill -f "openclaw-gateway" 2>/dev/null
sleep 3

# Проверяем что убился
BOT_CHECK=$(ps aux | grep "openclaw-gateway" | grep -v grep)
if [ -n "$BOT_CHECK" ]; then
    echo -e "  Процесс не завершился, убиваю принудительно..."
    pkill -9 -f "openclaw-gateway" 2>/dev/null
    sleep 2
fi

# Запускаем заново
systemctl --user start openclaw-gateway-moa.service 2>/dev/null
sleep 5

# Проверяем
BOT_CHECK=$(ps aux | grep "openclaw-gateway" | grep -v grep)
if [ -n "$BOT_CHECK" ]; then
    echo -e "  ${GREEN}✅ Бот перезапущен через systemd${NC}"
else
    echo -e "  systemd не сработал, запускаю напрямую..."
    nohup openclaw --profile moa gateway > /tmp/openclaw-restart.log 2>&1 &
    sleep 8
    BOT_CHECK=$(ps aux | grep "openclaw-gateway" | grep -v grep)
    if [ -n "$BOT_CHECK" ]; then
        echo -e "  ${GREEN}✅ Бот запущен напрямую${NC}"
    else
        echo -e "  ${RED}❌ Не удалось запустить бота${NC}"
        tail -10 /tmp/openclaw-restart.log 2>/dev/null
    fi
fi

# Ждём пока Telegram подключится
echo -e "  Жду подключения к Telegram (10 сек)..."
sleep 10

# Проверяем лог на Telegram
LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
if [ -f "$LOG_FILE" ]; then
    TG_STATUS=$(tail -30 "$LOG_FILE" | grep -i "telegram" | tail -1)
    if [ -n "$TG_STATUS" ]; then
        echo -e "  Telegram: подключение обнаружено ✓"
    fi
fi
echo ""

# ============================================
# ЭТАП 2: RDP на GMKtec
# ============================================
echo -e "${YELLOW}[2/4] Настраиваю RDP на GMKtec...${NC}"

# Проверяем есть ли xrdp
XRDP_STATUS=$(run_gmktec "which xrdp && echo 'installed' || echo 'not_installed'")

if [ "$XRDP_STATUS" = "not_installed" ]; then
    echo -e "  XRDP не установлен, устанавливаю (1-2 минуты)..."
    run_gmktec "sudo apt-get update -qq && sudo apt-get install -y xrdp > /dev/null 2>&1"
fi

# Настраиваем xrdp
run_gmktec "
    sudo systemctl enable xrdp 2>/dev/null
    sudo systemctl start xrdp 2>/dev/null
    
    # Добавляем banxe в группу ssl-cert (нужно для xrdp)
    sudo adduser banxe ssl-cert 2>/dev/null
    
    # Настраиваем сессию XFCE для RDP
    echo 'xfce4-session' > ~/.xsession 2>/dev/null
    chmod +x ~/.xsession 2>/dev/null
    
    # Разрешаем RDP через файрвол
    sudo ufw allow 3389/tcp 2>/dev/null
"

# Проверяем
XRDP_RUNNING=$(run_gmktec "sudo systemctl is-active xrdp 2>/dev/null")
if [ "$XRDP_RUNNING" = "active" ]; then
    echo -e "  ${GREEN}✅ RDP настроен и работает${NC}"
    echo -e "  Подключение: mstsc.exe /v:$GMKTEC_IP (логин: banxe, пароль: $GMKTEC_PASS)"
else
    echo -e "  ${YELLOW}⚠️  XRDP установлен, перезапускаю...${NC}"
    run_gmktec "sudo systemctl restart xrdp 2>/dev/null"
    sleep 2
    XRDP_RUNNING=$(run_gmktec "sudo systemctl is-active xrdp 2>/dev/null")
    if [ "$XRDP_RUNNING" = "active" ]; then
        echo -e "  ${GREEN}✅ RDP работает после перезапуска${NC}"
    else
        echo -e "  ${RED}❌ Не удалось запустить RDP${NC}"
    fi
fi
echo ""

# ============================================
# ЭТАП 3: Клавиатура на GMKtec
# ============================================
echo -e "${YELLOW}[3/4] Настраиваю клавиатуру на GMKtec (RU + EN)...${NC}"

run_gmktec "
    # Устанавливаем русскую раскладку + английскую, переключение Alt+Shift
    sudo sed -i 's/^XKBLAYOUT=.*/XKBLAYOUT=\"us,ru\"/' /etc/default/keyboard 2>/dev/null
    sudo sed -i 's/^XKBOPTIONS=.*/XKBOPTIONS=\"grp:alt_shift_toggle\"/' /etc/default/keyboard 2>/dev/null
    
    # Если строк нет — добавляем
    grep -q 'XKBLAYOUT' /etc/default/keyboard || echo 'XKBLAYOUT=\"us,ru\"' | sudo tee -a /etc/default/keyboard > /dev/null
    grep -q 'XKBOPTIONS' /etc/default/keyboard || echo 'XKBOPTIONS=\"grp:alt_shift_toggle\"' | sudo tee -a /etc/default/keyboard > /dev/null
    
    # Применяем
    sudo dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null
    sudo udevadm trigger 2>/dev/null
    
    # Для XFCE — настраиваем через xfconf
    xfconf-query -c keyboard-layout -p /Default/XkbDisable -s false 2>/dev/null
    xfconf-query -c keyboard-layout -p /Default/XkbLayout -s 'us,ru' 2>/dev/null
    xfconf-query -c keyboard-layout -p /Default/XkbOptions/Group -s 'grp:alt_shift_toggle' 2>/dev/null
"

echo -e "  ${GREEN}✅ Клавиатура: English + Русский, переключение Alt+Shift${NC}"
echo ""

# ============================================
# ЭТАП 4: Финальная проверка
# ============================================
echo -e "${YELLOW}[4/4] Финальная проверка...${NC}"

# Бот
BOT_OK=false
BOT_CHECK=$(ps aux | grep "openclaw-gateway" | grep -v grep)
if [ -n "$BOT_CHECK" ]; then
    BOT_OK=true
    echo -e "  Бот: ${GREEN}✅ работает${NC}"
else
    echo -e "  Бот: ${RED}❌ не работает${NC}"
fi

# Ollama
OLLAMA_OK=false
OLLAMA_CHECK=$(curl -s --max-time 5 http://$GMKTEC_IP:11434/api/tags 2>/dev/null)
if [ -n "$OLLAMA_CHECK" ]; then
    OLLAMA_OK=true
    echo -e "  Ollama: ${GREEN}✅ работает${NC}"
else
    echo -e "  Ollama: ${RED}❌ не отвечает${NC}"
fi

# LiteLLM
LITELLM_OK=false
LITELLM_CHECK=$(curl -s --max-time 5 http://localhost:8080/health 2>/dev/null)
if [ -n "$LITELLM_CHECK" ]; then
    LITELLM_OK=true
    echo -e "  LiteLLM: ${GREEN}✅ работает${NC}"
else
    echo -e "  LiteLLM: ${RED}❌ не отвечает${NC}"
fi

# RDP
RDP_OK=false
RDP_CHECK=$(run_gmktec "sudo systemctl is-active xrdp 2>/dev/null")
if [ "$RDP_CHECK" = "active" ]; then
    RDP_OK=true
    echo -e "  RDP: ${GREEN}✅ работает${NC}"
else
    echo -e "  RDP: ${RED}❌ не работает${NC}"
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ИТОГ${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

if $BOT_OK && $OLLAMA_OK && $LITELLM_OK && $RDP_OK; then
    echo -e "  ${GREEN}🎉 ВСЁ РАБОТАЕТ!${NC}"
    echo ""
    echo "  Бот: напиши @mycarmi_moa_bot в Telegram"
    echo "  RDP: Win+R → mstsc → $GMKTEC_IP"
    echo "       логин: banxe  пароль: $GMKTEC_PASS"
    echo "  Клавиатура: Alt+Shift для переключения EN/RU"
else
    echo -e "  ${YELLOW}Есть проблемы — см. выше${NC}"
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo ""
