#!/bin/bash
# ============================================
#  FIX-GMKTEC — Ремонт GMKtec одним скриптом
# ============================================
#
#  Что делает:
#  1. Починит SSH (чтобы подключаться с Legion)
#  2. Починит пароль пользователя banxe
#  3. Найдёт модели Ollama на Windows-диске
#  4. Скопирует модели в Ollama на Ubuntu
#  5. Настроит автомонтирование Windows-диска
#
#  Запуск на GMKtec:
#    curl -sL https://raw.githubusercontent.com/CarmiBanxe/vibe-coding/main/scripts/fix-gmktec.sh | bash
#
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  FIX-GMKTEC — Ремонт одним скриптом${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# -------------------------------------------
# ЭТАП 1: Починка SSH
# -------------------------------------------
echo -e "${YELLOW}[1/5] Чиню SSH...${NC}"

# Устанавливаем нормальный пароль (больше 8 символов)
echo "banxe:mmber2025!" | sudo chpasswd 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}✅ Пароль banxe установлен: mmber2025!${NC}"
else
    echo -e "  ${RED}❌ Не удалось сменить пароль${NC}"
fi

# Включаем вход по паролю
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null

# Перезапускаем SSH (пробуем оба имени сервиса)
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}✅ SSH перезапущен${NC}"
else
    echo -e "  ${RED}❌ Не удалось перезапустить SSH${NC}"
    echo -e "  Попробую починить конфиг..."
    # Если конфиг сломан — восстанавливаем минимальный
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    sudo bash -c 'cat > /etc/ssh/sshd_config << SSHEOF
Port 22
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
SSHEOF'
    sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✅ SSH починен с новым конфигом${NC}"
    else
        echo -e "  ${RED}❌ SSH всё ещё не работает. Проверь вручную: sudo systemctl status ssh${NC}"
    fi
fi
echo ""

# -------------------------------------------
# ЭТАП 2: Проверка Ollama
# -------------------------------------------
echo -e "${YELLOW}[2/5] Проверяю Ollama...${NC}"

if command -v ollama &> /dev/null; then
    echo -e "  ${GREEN}✅ Ollama установлена${NC}"
    ollama --version 2>/dev/null
else
    echo -e "  ${RED}❌ Ollama не найдена, устанавливаю...${NC}"
    curl -fsSL https://ollama.com/install.sh | sh
fi

# Проверяем что Ollama слушает на всех интерфейсах
OLLAMA_CONF="/etc/systemd/system/ollama.service.d/override.conf"
if [ -f "$OLLAMA_CONF" ]; then
    echo -e "  ${GREEN}✅ Конфиг Ollama на месте${NC}"
else
    echo -e "  Создаю конфиг для внешнего доступа..."
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    echo -e '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\nEnvironment="OLLAMA_KEEP_ALIVE=24h"' | sudo tee "$OLLAMA_CONF" > /dev/null
    sudo systemctl daemon-reload
    sudo systemctl restart ollama
    echo -e "  ${GREEN}✅ Ollama настроена на внешний доступ${NC}"
fi
echo ""

# -------------------------------------------
# ЭТАП 3: Монтирование Windows-диска
# -------------------------------------------
echo -e "${YELLOW}[3/5] Подключаю Windows-диск (2 ТБ)...${NC}"

WINDOWS_PART="/dev/nvme0n1p3"
WINDOWS_MOUNT="/mnt/windows"

if mountpoint -q "$WINDOWS_MOUNT" 2>/dev/null; then
    echo -e "  ${GREEN}✅ Windows-диск уже подключён${NC}"
else
    sudo mkdir -p "$WINDOWS_MOUNT"
    sudo mount -t ntfs3 "$WINDOWS_PART" "$WINDOWS_MOUNT" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✅ Windows-диск подключён к $WINDOWS_MOUNT${NC}"
    else
        # Пробуем ntfs-3g если ntfs3 не работает
        sudo mount -t ntfs-3g "$WINDOWS_PART" "$WINDOWS_MOUNT" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}✅ Windows-диск подключён (ntfs-3g)${NC}"
        else
            echo -e "  ${RED}❌ Не удалось подключить Windows-диск${NC}"
        fi
    fi
fi
echo ""

# -------------------------------------------
# ЭТАП 4: Поиск и перенос моделей Ollama
# -------------------------------------------
echo -e "${YELLOW}[4/5] Ищу модели Ollama на Windows-диске...${NC}"

# Ищем во всех возможных местах
OLLAMA_FOUND=""
SEARCH_PATHS=(
    "$WINDOWS_MOUNT/Users/GMK tec/.ollama"
    "$WINDOWS_MOUNT/Users/GMK tec/AppData/Local/Ollama"
    "$WINDOWS_MOUNT/Users/rdpuser/.ollama"
    "$WINDOWS_MOUNT/Users/rdpuser/AppData/Local/Ollama"
    "$WINDOWS_MOUNT/ProgramData/Ollama"
)

for path in "${SEARCH_PATHS[@]}"; do
    if [ -d "$path" ]; then
        echo -e "  ${GREEN}✅ Найдена папка: $path${NC}"
        OLLAMA_FOUND="$path"
        ls -la "$path/" 2>/dev/null | head -10
        echo ""
    fi
done

# Если не нашли — ищем глубже
if [ -z "$OLLAMA_FOUND" ]; then
    echo -e "  Ищу глубже (может занять 1-2 минуты)..."
    DEEP_SEARCH=$(find "$WINDOWS_MOUNT" -name "ollama" -type d 2>/dev/null | head -5)
    if [ -n "$DEEP_SEARCH" ]; then
        echo -e "  ${GREEN}✅ Найдены папки:${NC}"
        echo "$DEEP_SEARCH"
        OLLAMA_FOUND=$(echo "$DEEP_SEARCH" | head -1)
    else
        echo -e "  ${YELLOW}⚠️  Папки ollama не найдены на Windows-диске${NC}"
        echo -e "  Ищу файлы моделей напрямую..."
        MODEL_FILES=$(find "$WINDOWS_MOUNT" -name "*.gguf" -o -name "sha256-*" 2>/dev/null | head -5)
        if [ -n "$MODEL_FILES" ]; then
            echo -e "  ${GREEN}Найдены файлы моделей:${NC}"
            echo "$MODEL_FILES"
        else
            echo -e "  ${RED}❌ Модели не найдены на Windows-диске${NC}"
            echo -e "  Модели придётся скачать заново"
        fi
    fi
fi

# Если нашли — копируем
if [ -n "$OLLAMA_FOUND" ]; then
    MODELS_DIR="$OLLAMA_FOUND/models"
    if [ -d "$MODELS_DIR" ]; then
        SIZE=$(du -sh "$MODELS_DIR" 2>/dev/null | awk '{print $1}')
        echo ""
        echo -e "  ${BLUE}Размер моделей: $SIZE${NC}"
        echo -e "  Копирую в /usr/share/ollama/.ollama/models/..."
        echo -e "  (Это может занять долго при большом объёме)"
        sudo mkdir -p /usr/share/ollama/.ollama/
        sudo cp -r "$MODELS_DIR" /usr/share/ollama/.ollama/ 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}✅ Модели скопированы!${NC}"
            sudo systemctl restart ollama
            sleep 3
        else
            echo -e "  ${YELLOW}⚠️  Ошибка копирования. Пробую симлинк...${NC}"
            sudo ln -sf "$MODELS_DIR" /usr/share/ollama/.ollama/models
            sudo systemctl restart ollama
            sleep 3
        fi
    fi
fi
echo ""

# -------------------------------------------
# ЭТАП 5: Финальная проверка
# -------------------------------------------
echo -e "${YELLOW}[5/5] Финальная проверка...${NC}"

# SSH
SSH_STATUS=$(sudo systemctl is-active ssh 2>/dev/null || sudo systemctl is-active sshd 2>/dev/null)
echo -e "  SSH: $([ "$SSH_STATUS" = "active" ] && echo -e "${GREEN}✅ работает${NC}" || echo -e "${RED}❌ не работает${NC}")"

# Ollama
OLLAMA_STATUS=$(sudo systemctl is-active ollama 2>/dev/null)
echo -e "  Ollama: $([ "$OLLAMA_STATUS" = "active" ] && echo -e "${GREEN}✅ работает${NC}" || echo -e "${RED}❌ не работает${NC}")"

# Модели
echo -e "  Модели:"
ollama list 2>/dev/null || echo -e "  ${RED}Не удалось получить список${NC}"

# Внешний доступ
EXTERNAL=$(curl -s --max-time 3 http://0.0.0.0:11434/api/tags 2>/dev/null)
echo -e "  Внешний доступ: $([ -n "$EXTERNAL" ] && echo -e "${GREEN}✅ доступен${NC}" || echo -e "${RED}❌ недоступен${NC}")"

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ГОТОВО${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "  Новый пароль SSH: mmber2025!"
echo "  Подключение с Legion:"
echo "    ssh banxe@192.168.0.72"
echo "    пароль: mmber2025!"
echo ""
echo "  Если модели не найдены — скачай вручную:"
echo "    ollama pull huihui_ai/glm-4.7-flash-abliterated"
echo "    ollama pull huihui_ai/qwen3.5-abliterated:35b"
echo "    ollama pull gurubot/gpt-oss-derestricted:20b"
echo "    ollama pull llama3.3:70b"
echo ""
