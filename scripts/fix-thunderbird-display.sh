#!/bin/bash
###############################################################################
# fix-thunderbird-display.sh — Починка Thunderbird и других приложений на RDP
# Запускать на GMKtec от root: bash scripts/fix-thunderbird-display.sh
###############################################################################

echo "=========================================="
echo "  ДИАГНОСТИКА И ПОЧИНКА ДИСПЛЕЯ RDP"
echo "=========================================="

# --- 1. Находим RDP-дисплей ---
echo ""
echo "[1/6] Поиск RDP-дисплея..."
RDP_DISPLAY=$(ps aux | grep 'Xorg.*xrdp' | grep -v grep | sed -n 's/.*\(:[0-9]*\).*/\1/p' | head -1)
if [ -z "$RDP_DISPLAY" ]; then
    echo "  ✗ RDP-сессия не найдена! Подключись через RDP и запусти снова."
    exit 1
fi
echo "  ✓ RDP дисплей: $RDP_DISPLAY"

# --- 2. Находим пользователя RDP-сессии ---
echo ""
echo "[2/6] Поиск пользователя RDP..."
RDP_USER=$(ps aux | grep 'Xorg.*xrdp' | grep -v grep | awk '{print $1}' | head -1)
echo "  ✓ Пользователь: $RDP_USER"
RDP_HOME=$(eval echo "~$RDP_USER")
echo "  ✓ Home: $RDP_HOME"

# --- 3. Проверяем .Xauthority ---
echo ""
echo "[3/6] Проверка .Xauthority..."
XAUTH_FILE="$RDP_HOME/.Xauthority"
if [ -f "$XAUTH_FILE" ]; then
    echo "  ✓ Файл найден: $XAUTH_FILE"
    ls -la "$XAUTH_FILE"
    # Убедимся что он принадлежит пользователю
    chown "$RDP_USER:$RDP_USER" "$XAUTH_FILE"
    echo "  ✓ Права исправлены"
else
    echo "  ✗ .Xauthority не найден!"
fi

# --- 4. Диагностика — почему приложения не подключаются ---
echo ""
echo "[4/6] Диагностика подключения к дисплею..."

# Тест от пользователя
echo "  Тест xdpyinfo..."
su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$XAUTH_FILE xdpyinfo >/dev/null 2>&1" && echo "  ✓ xdpyinfo работает" || echo "  ✗ xdpyinfo НЕ работает"

# Проверим сокет
echo "  Проверка X11 сокета..."
DISPLAY_NUM=$(echo "$RDP_DISPLAY" | tr -d ':')
if [ -S "/tmp/.X11-unix/X$DISPLAY_NUM" ]; then
    echo "  ✓ Сокет /tmp/.X11-unix/X$DISPLAY_NUM существует"
    ls -la "/tmp/.X11-unix/X$DISPLAY_NUM"
else
    echo "  ✗ Сокет не найден!"
fi

# --- 5. Починка — разрешаем локальные подключения ---
echo ""
echo "[5/6] Починка доступа к дисплею..."

# Разрешаем все локальные подключения
su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$XAUTH_FILE xhost +local: 2>/dev/null" && echo "  ✓ xhost +local: применён" || echo "  ⚠ xhost не удался"
su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$XAUTH_FILE xhost +si:localuser:$RDP_USER 2>/dev/null" && echo "  ✓ xhost +si:localuser:$RDP_USER применён" || true
su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$XAUTH_FILE xhost +si:localuser:root 2>/dev/null" && echo "  ✓ xhost +si:localuser:root применён" || true

# Фикс — создаём обёртки для проблемных приложений, принудительно X11
echo ""
echo "  Создаю обёртки для Thunderbird и Mail Reader..."

# Thunderbird wrapper
cat > /usr/local/bin/thunderbird-x11 << 'WRAPPER'
#!/bin/bash
export MOZ_ENABLE_WAYLAND=0
export GDK_BACKEND=x11
exec /usr/bin/thunderbird "$@"
WRAPPER
chmod +x /usr/local/bin/thunderbird-x11

# Обновляем .desktop файл для Mail Reader
DESKTOP_FILE="/usr/share/applications/thunderbird.desktop"
if [ -f "$DESKTOP_FILE" ]; then
    # Добавляем переменные окружения в Exec
    sed -i 's|^Exec=thunderbird|Exec=env MOZ_ENABLE_WAYLAND=0 GDK_BACKEND=x11 thunderbird|' "$DESKTOP_FILE" 2>/dev/null
    echo "  ✓ thunderbird.desktop обновлён"
fi

# Настраиваем Mail Reader в XFCE на thunderbird
sudo -u "$RDP_USER" bash -c "
mkdir -p $RDP_HOME/.config/xfce4
cat > $RDP_HOME/.config/xfce4/helpers.rc << EOF
WebBrowser=firefox
MailReader=thunderbird
TerminalEmulator=xfce4-terminal
FileManager=thunar
TextEditor=mousepad
EOF

# Создаём custom helper для thunderbird
mkdir -p $RDP_HOME/.local/share/xfce4/helpers
cat > $RDP_HOME/.local/share/xfce4/helpers/thunderbird.desktop << EOF2
[Desktop Entry]
NoDisplay=true
Version=1.0
Encoding=UTF-8
Type=X-XFCE-Helper
X-XFCE-Binaries=thunderbird
X-XFCE-Category=MailReader
Name=Thunderbird
Icon=thunderbird
X-XFCE-Commands=/usr/local/bin/thunderbird-x11
X-XFCE-CommandsWithParameter=/usr/local/bin/thunderbird-x11 %s
EOF2
"
echo "  ✓ XFCE helpers настроены"

# Права
chown -R "$RDP_USER:$RDP_USER" "$RDP_HOME/.config" "$RDP_HOME/.local" 2>/dev/null

# --- 6. Тестируем запуск ---
echo ""
echo "[6/6] Тестируем запуск приложений..."

test_app() {
    local name="$1"
    local cmd="$2"
    # Запускаем и ждём 3 секунды — если процесс жив, значит OK
    su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$XAUTH_FILE MOZ_ENABLE_WAYLAND=0 GDK_BACKEND=x11 $cmd &" 2>/dev/null
    sleep 3
    if pgrep -u "$RDP_USER" -f "$cmd" >/dev/null 2>&1; then
        printf "  %-25s ✓ ОТКРЫЛСЯ\n" "$name"
        # Закрываем тестовое окно
        pkill -u "$RDP_USER" -f "$cmd" 2>/dev/null
    else
        printf "  %-25s ✗ НЕ ОТКРЫЛСЯ\n" "$name"
    fi
}

printf "  %-25s %s\n" "ПРИЛОЖЕНИЕ" "СТАТУС"
printf "  %-25s %s\n" "-------------------------" "----------"
test_app "Thunderbird" "thunderbird"
test_app "Firefox" "firefox"
test_app "Thunar" "thunar"
test_app "Terminal" "xfce4-terminal"
test_app "Mousepad" "mousepad"

echo ""
echo "=========================================="
echo "  ГОТОВО!"
echo "=========================================="
echo ""
echo "Попробуй на RDP-экране:"
echo "  Applications → Mail Reader"
echo "  Applications → Web Browser"
echo "  Applications → Terminal Emulator"
echo "  Applications → File Manager"
echo ""
echo "Если Mail Reader всё ещё не работает из меню,"
echo "используй: Applications → Internet → Thunderbird"
echo "=========================================="
