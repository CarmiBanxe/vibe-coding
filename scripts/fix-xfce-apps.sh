#!/bin/bash
###############################################################################
# fix-xfce-apps.sh — Проверка и ремонт всех приложений XFCE на GMKtec
# Запускать на GMKtec от root: bash scripts/fix-xfce-apps.sh
###############################################################################
set -e

echo "=========================================="
echo "  РЕМОНТ ПРИЛОЖЕНИЙ XFCE НА GMKtec"
echo "=========================================="

# --- 1. Починка locale (убираем warning) ---
echo ""
echo "[1/7] Починка locale..."
if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
    locale-gen en_US.UTF-8
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    echo "  ✓ Locale en_US.UTF-8 сгенерирована"
else
    echo "  ✓ Locale уже в порядке"
fi

# --- 2. Установка недостающих приложений ---
echo ""
echo "[2/7] Установка недостающих приложений..."
apt update -qq

# Список приложений для проверки и установки
APPS=(
    "xfce4-terminal"        # Terminal Emulator
    "thunar"                # File Manager
    "thunderbird"           # Mail Reader (замена стандартного)
    "firefox"               # Web Browser
    "mousepad"              # Text Editor
    "ristretto"             # Image Viewer
    "xfce4-screenshooter"   # Screenshot tool
    "xfce4-taskmanager"     # Task Manager
    "xfce4-appfinder"       # Application Finder
    "xfce4-settings"        # Settings Manager
    "xfce4-power-manager"   # Power Manager
    "file-roller"           # Archive Manager
    "atril"                 # PDF/Document Viewer
    "xfce4-notifyd"         # Notifications
)

INSTALLED=0
for app in "${APPS[@]}"; do
    if ! dpkg -l "$app" 2>/dev/null | grep -q "^ii"; then
        echo "  Устанавливаю $app..."
        apt install -y -qq "$app" 2>/dev/null
        INSTALLED=$((INSTALLED + 1))
    fi
done
echo "  ✓ Установлено новых пакетов: $INSTALLED"

# --- 3. Починка прав на домашнюю папку banxe ---
echo ""
echo "[3/7] Починка прав файлов banxe..."
chown -R banxe:banxe /home/banxe/.config 2>/dev/null || true
chown -R banxe:banxe /home/banxe/.local 2>/dev/null || true
chown -R banxe:banxe /home/banxe/.cache 2>/dev/null || true
chown -R banxe:banxe /home/banxe/.mozilla 2>/dev/null || true
chown -R banxe:banxe /home/banxe/.thunderbird 2>/dev/null || true
echo "  ✓ Права исправлены"

# --- 4. Настройка дефолтных приложений ---
echo ""
echo "[4/7] Настройка приложений по умолчанию..."
sudo -u banxe bash -c '
mkdir -p /home/banxe/.config/xfce4/helpers
cat > /home/banxe/.config/xfce4/helpers.rc << EOF
WebBrowser=firefox
MailReader=thunderbird
TerminalEmulator=xfce4-terminal
FileManager=thunar
TextEditor=mousepad
EOF
'
echo "  ✓ Приложения по умолчанию настроены"

# --- 5. Починка .desktop файлов (чтобы меню работало) ---
echo ""
echo "[5/7] Обновление меню приложений..."
update-desktop-database /usr/share/applications 2>/dev/null || true
sudo -u banxe bash -c 'update-desktop-database /home/banxe/.local/share/applications 2>/dev/null || true'
echo "  ✓ Меню обновлено"

# --- 6. Перезапуск панели XFCE ---
echo ""
echo "[6/7] Перезапуск панели XFCE..."
sudo -u banxe bash -c 'DISPLAY=:10 XAUTHORITY=/home/banxe/.Xauthority xfce4-panel -r 2>/dev/null &'
sleep 2
echo "  ✓ Панель перезапущена"

# --- 7. Проверка всех приложений ---
echo ""
echo "[7/7] Проверка установленных приложений..."
echo ""
printf "  %-25s %s\n" "ПРИЛОЖЕНИЕ" "СТАТУС"
printf "  %-25s %s\n" "-------------------------" "----------"

check_app() {
    local name="$1"
    local cmd="$2"
    if command -v "$cmd" &>/dev/null; then
        printf "  %-25s ✓ OK\n" "$name"
    else
        printf "  %-25s ✗ НЕ НАЙДЕН\n" "$name"
    fi
}

check_app "Terminal Emulator" "xfce4-terminal"
check_app "File Manager (Thunar)" "thunar"
check_app "Web Browser (Firefox)" "firefox"
check_app "Mail Reader (Thunderbird)" "thunderbird"
check_app "Text Editor (Mousepad)" "mousepad"
check_app "Image Viewer (Ristretto)" "ristretto"
check_app "Screenshot" "xfce4-screenshooter"
check_app "Task Manager" "xfce4-taskmanager"
check_app "Archive Manager" "file-roller"
check_app "PDF Viewer (Atril)" "atril"
check_app "Settings Manager" "xfce4-settings-manager"
check_app "App Finder" "xfce4-appfinder"

echo ""
echo "=========================================="
echo "  ГОТОВО!"
echo "=========================================="
echo ""
echo "Теперь попробуй на RDP-экране:"
echo "  Applications → Terminal Emulator"
echo "  Applications → Web Browser"
echo "  Applications → Mail Reader"
echo "  Applications → File Manager"
echo "  Applications → Settings → ..."
echo ""
echo "Всё должно открываться из меню."
echo "=========================================="
