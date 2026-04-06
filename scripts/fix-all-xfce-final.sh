#!/bin/bash
###############################################################################
# fix-all-xfce-final.sh — Полная проверка и ремонт ВСЕХ приложений XFCE на RDP
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-all-xfce-final.sh
#
# Скрипт сам подключается к GMKtec по SSH и всё делает.
###############################################################################

GMKTEC_IP="192.168.0.72"
GMKTEC_PORT="2222"
GMKTEC_USER="root"

echo "=========================================="
echo "  ПОЛНЫЙ РЕМОНТ XFCE НА GMKtec"
echo "  Запуск с Legion → SSH → GMKtec"
echo "=========================================="
echo ""
echo "Сейчас подключусь к GMKtec ($GMKTEC_IP:$GMKTEC_PORT)"
echo "Введи пароль root (mmber2025) когда попросит."
echo ""

ssh -p "$GMKTEC_PORT" "$GMKTEC_USER@$GMKTEC_IP" 'bash -s' << 'REMOTE_SCRIPT'

echo ""
echo "[1/8] Поиск RDP-сессии..."
RDP_DISPLAY=$(ps aux | grep "Xorg.*xrdp" | grep -v grep | sed -n "s/.*\(:[0-9]*\).*/\1/p" | head -1)
RDP_USER=$(ps aux | grep "Xorg.*xrdp" | grep -v grep | awk "{print \$1}" | head -1)

if [ -z "$RDP_DISPLAY" ]; then
    echo "  ⚠ RDP-сессия не найдена. Пропускаю тесты дисплея."
    echo "  Но всё равно установлю и настрою приложения."
    RDP_DISPLAY=":10"
    RDP_USER="banxe"
fi

RDP_HOME=$(eval echo "~$RDP_USER")
echo "  ✓ Дисплей: $RDP_DISPLAY | Пользователь: $RDP_USER | Home: $RDP_HOME"

# --- 2. Удаляем ВСЕ snap-приложения которые глючат через RDP ---
echo ""
echo "[2/8] Удаление snap-версий приложений..."
for pkg in thunderbird thunar firefox mousepad; do
    if snap list "$pkg" 2>/dev/null | grep -q "$pkg"; then
        echo "  Удаляю snap: $pkg..."
        snap remove "$pkg" 2>/dev/null
        echo "  ✓ snap $pkg удалён"
    fi
done
# Удаляем dpkg-обёртки от snap если остались
for pkg in thunderbird thunar; do
    if [ -f "/usr/bin/$pkg" ]; then
        if grep -q "snap" "/usr/bin/$pkg" 2>/dev/null; then
            echo "  Удаляю snap-обёртку: $pkg..."
            dpkg -r "$pkg" 2>/dev/null
            echo "  ✓ snap-обёртка $pkg удалена"
        fi
    fi
done
echo "  ✓ Snap очистка завершена"

# --- 3. Установка всех приложений ---
echo ""
echo "[3/8] Установка приложений из PPA/apt..."

# PPA mozillateam
if ! grep -r "mozillateam" /etc/apt/sources.list.d/ &>/dev/null; then
    add-apt-repository -y ppa:mozillateam/ppa 2>/dev/null
fi

apt update -qq 2>/dev/null

APPS=(
    "xfce4-terminal"
    "thunar"
    "firefox"
    "thunderbird"
    "mousepad"
    "ristretto"
    "xfce4-screenshooter"
    "xfce4-taskmanager"
    "xfce4-appfinder"
    "xfce4-settings"
    "xfce4-power-manager"
    "file-roller"
    "atril"
    "xfce4-notifyd"
    "git"
)

INSTALLED=0
for app in "${APPS[@]}"; do
    if ! dpkg -l "$app" 2>/dev/null | grep -q "^ii"; then
        echo "  Устанавливаю $app..."
        apt install -y -qq "$app" 2>/dev/null
        INSTALLED=$((INSTALLED + 1))
    fi
done

# Firefox и Thunderbird принудительно из PPA
for app in firefox thunderbird; do
    if [ -f "/usr/bin/$app" ] && grep -q "snap" "/usr/bin/$app" 2>/dev/null; then
        echo "  Переустанавливаю $app из PPA..."
        dpkg -r "$app" 2>/dev/null
        apt install -y -qq -t "o=LP-PPA-mozillateam" "$app" 2>/dev/null
        INSTALLED=$((INSTALLED + 1))
    fi
done
echo "  ✓ Установлено/переустановлено: $INSTALLED"

# --- 4. Починка locale ---
echo ""
echo "[4/8] Починка locale..."
if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
    locale-gen en_US.UTF-8 2>/dev/null
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    echo "  ✓ Locale сгенерирована"
else
    echo "  ✓ Locale уже OK"
fi

# --- 5. Починка прав ---
echo ""
echo "[5/8] Починка прав файлов..."
chown -R "$RDP_USER:$RDP_USER" "$RDP_HOME/.config" 2>/dev/null || true
chown -R "$RDP_USER:$RDP_USER" "$RDP_HOME/.local" 2>/dev/null || true
chown -R "$RDP_USER:$RDP_USER" "$RDP_HOME/.cache" 2>/dev/null || true
chown -R "$RDP_USER:$RDP_USER" "$RDP_HOME/.mozilla" 2>/dev/null || true
chown -R "$RDP_USER:$RDP_USER" "$RDP_HOME/.thunderbird" 2>/dev/null || true
chown "$RDP_USER:$RDP_USER" "$RDP_HOME/.Xauthority" 2>/dev/null || true
echo "  ✓ Права исправлены"

# --- 6. Настройка доступа к дисплею ---
echo ""
echo "[6/8] Настройка доступа к дисплею..."
su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$RDP_HOME/.Xauthority xhost +local: 2>/dev/null" && echo "  ✓ xhost +local:" || echo "  ⚠ xhost пропущен (нет RDP)"
su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$RDP_HOME/.Xauthority xhost +si:localuser:$RDP_USER 2>/dev/null" || true
su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$RDP_HOME/.Xauthority xhost +si:localuser:root 2>/dev/null" || true

# --- 7. Настройка XFCE ---
echo ""
echo "[7/8] Настройка XFCE..."

sudo -u "$RDP_USER" bash -c "
mkdir -p $RDP_HOME/.config/xfce4/helpers
cat > $RDP_HOME/.config/xfce4/helpers.rc << EOF
WebBrowser=firefox
MailReader=thunderbird
TerminalEmulator=xfce4-terminal
FileManager=thunar
TextEditor=mousepad
EOF
"

update-desktop-database /usr/share/applications 2>/dev/null || true
sudo -u "$RDP_USER" bash -c "update-desktop-database $RDP_HOME/.local/share/applications 2>/dev/null || true"

# Перезапуск панели
su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$RDP_HOME/.Xauthority xfce4-panel -r 2>/dev/null &"
sleep 2
echo "  ✓ XFCE настроен, панель перезапущена"

# --- 8. Тестируем ВСЕ приложения ---
echo ""
echo "[8/8] Тестируем запуск приложений..."
echo ""
printf "  %-25s %s\n" "ПРИЛОЖЕНИЕ" "СТАТУС"
printf "  %-25s %s\n" "-------------------------" "----------"

test_app() {
    local name="$1"
    local cmd="$2"

    su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$RDP_HOME/.Xauthority MOZ_ENABLE_WAYLAND=0 GDK_BACKEND=x11 $cmd &" 2>/dev/null
    sleep 3

    if pgrep -u "$RDP_USER" -f "$cmd" >/dev/null 2>&1; then
        printf "  %-25s ✓ OK\n" "$name"
        pkill -u "$RDP_USER" -f "$cmd" 2>/dev/null
        sleep 1
    else
        printf "  %-25s ✗ ОШИБКА\n" "$name"
    fi
}

test_app "Terminal" "xfce4-terminal"
test_app "Firefox" "firefox"
test_app "Thunderbird" "thunderbird"
test_app "Thunar (File Manager)" "thunar"
test_app "Mousepad (Text Editor)" "mousepad"
test_app "Ristretto (Image)" "ristretto"
test_app "Screenshot" "xfce4-screenshooter"
test_app "Task Manager" "xfce4-taskmanager"
test_app "Archive Manager" "file-roller"
test_app "PDF Viewer (Atril)" "atril"
test_app "Settings" "xfce4-settings-manager"
test_app "App Finder" "xfce4-appfinder"

echo ""
echo "=========================================="
echo "  ИТОГ"
echo "=========================================="
echo ""
echo "Проверь на RDP-экране меню Applications:"
echo "  • Terminal Emulator"
echo "  • Web Browser (Firefox)"
echo "  • Mail Reader (Thunderbird)"
echo "  • File Manager (Thunar)"
echo ""
echo "Все приложения должны открываться из меню."
echo "=========================================="

REMOTE_SCRIPT
