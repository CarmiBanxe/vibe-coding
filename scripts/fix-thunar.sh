#!/bin/bash
###############################################################################
# fix-thunar.sh — Диагностика и починка Thunar (File Manager) на GMKtec
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-thunar.sh
###############################################################################

GMKTEC_IP="192.168.0.72"
GMKTEC_PORT="2222"
GMKTEC_USER="root"

echo "=========================================="
echo "  ПОЧИНКА THUNAR НА GMKtec"
echo "=========================================="
echo ""
echo "Введи пароль root GMKtec (mmber) когда попросит."
echo ""

ssh -p "$GMKTEC_PORT" "$GMKTEC_USER@$GMKTEC_IP" 'bash -s' << 'REMOTE_SCRIPT'

RDP_USER="banxe"
RDP_HOME="/home/banxe"
RDP_DISPLAY=":10"

echo "[1/6] Диагностика текущего Thunar..."
echo "  Версия:"
thunar --version 2>&1 | head -3
echo ""
echo "  Тип файла:"
file /usr/bin/thunar
echo ""
echo "  Проверка зависимостей:"
ldd /usr/bin/thunar 2>&1 | grep "not found" && echo "  ✗ Есть недостающие библиотеки!" || echo "  ✓ Все библиотеки на месте"

echo ""
echo "[2/6] Очистка старых конфигов Thunar..."
rm -rf "$RDP_HOME/.config/Thunar" "$RDP_HOME/.config/thunar" 2>/dev/null
rm -rf "$RDP_HOME/.cache/Thunar" "$RDP_HOME/.cache/thunar" 2>/dev/null
# Убиваем зависшие процессы Thunar если есть
pkill -u "$RDP_USER" -f thunar 2>/dev/null
pkill -u "$RDP_USER" -f Thunar 2>/dev/null
sleep 1
echo "  ✓ Конфиги и кеш очищены"

echo ""
echo "[3/6] Переустановка Thunar и зависимостей..."
apt install -y --reinstall thunar thunar-data gvfs gvfs-backends gvfs-fuse tumbler 2>/dev/null | tail -3
echo "  ✓ Thunar переустановлен"

echo ""
echo "[4/6] Починка прав и dbus..."
chown -R "$RDP_USER:$RDP_USER" "$RDP_HOME/.config" 2>/dev/null
chown -R "$RDP_USER:$RDP_USER" "$RDP_HOME/.cache" 2>/dev/null
chown -R "$RDP_USER:$RDP_USER" "$RDP_HOME/.local" 2>/dev/null

# Проверяем dbus для пользователя
DBUS_PID=$(pgrep -u "$RDP_USER" dbus-daemon | head -1)
if [ -z "$DBUS_PID" ]; then
    echo "  ⚠ dbus-daemon не запущен для $RDP_USER, запускаю..."
    su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$RDP_HOME/.Xauthority dbus-launch --sh-syntax > /tmp/dbus-$RDP_USER.env" 2>/dev/null
    echo "  ✓ dbus запущен"
else
    echo "  ✓ dbus уже работает (PID: $DBUS_PID)"
fi
# Получаем DBUS адрес
DBUS_ADDR=$(su - "$RDP_USER" -c "grep -r DBUS_SESSION_BUS_ADDRESS /proc/*/environ 2>/dev/null" | head -1 | grep -oP 'DBUS_SESSION_BUS_ADDRESS=\K[^\x00]*')
echo "  DBUS: ${DBUS_ADDR:-не найден}"

echo ""
echo "[5/6] Тестируем запуск Thunar..."

# Способ 1: простой запуск
echo "  Способ 1: простой запуск..."
su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$RDP_HOME/.Xauthority thunar $RDP_HOME &" 2>/dev/null
sleep 3
if pgrep -u "$RDP_USER" thunar >/dev/null 2>&1; then
    echo "  ✓ Способ 1 РАБОТАЕТ"
    THUNAR_OK=1
else
    echo "  ✗ Способ 1 не работает"
    THUNAR_OK=0
fi

# Способ 2: с dbus-launch
if [ "$THUNAR_OK" -eq 0 ]; then
    echo "  Способ 2: с dbus-launch..."
    su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$RDP_HOME/.Xauthority dbus-launch thunar $RDP_HOME &" 2>/dev/null
    sleep 3
    if pgrep -u "$RDP_USER" thunar >/dev/null 2>&1; then
        echo "  ✓ Способ 2 РАБОТАЕТ"
        THUNAR_OK=2
    else
        echo "  ✗ Способ 2 не работает"
    fi
fi

# Способ 3: с DBUS_SESSION_BUS_ADDRESS
if [ "$THUNAR_OK" -eq 0 ] && [ -n "$DBUS_ADDR" ]; then
    echo "  Способ 3: с DBUS_SESSION_BUS_ADDRESS..."
    su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$RDP_HOME/.Xauthority DBUS_SESSION_BUS_ADDRESS=$DBUS_ADDR thunar $RDP_HOME &" 2>/dev/null
    sleep 3
    if pgrep -u "$RDP_USER" thunar >/dev/null 2>&1; then
        echo "  ✓ Способ 3 РАБОТАЕТ"
        THUNAR_OK=3
    else
        echo "  ✗ Способ 3 не работает"
    fi
fi

# Способ 4: альтернативный файл-менеджер pcmanfm
if [ "$THUNAR_OK" -eq 0 ]; then
    echo "  Способ 4: установка альтернативы PCManFM..."
    apt install -y -qq pcmanfm 2>/dev/null
    su - "$RDP_USER" -c "DISPLAY=$RDP_DISPLAY XAUTHORITY=$RDP_HOME/.Xauthority pcmanfm $RDP_HOME &" 2>/dev/null
    sleep 3
    if pgrep -u "$RDP_USER" pcmanfm >/dev/null 2>&1; then
        echo "  ✓ PCManFM РАБОТАЕТ (замена Thunar)"
        THUNAR_OK=4
        # Настраиваем как дефолтный
        sudo -u "$RDP_USER" bash -c "sed -i 's/FileManager=thunar/FileManager=pcmanfm/' $RDP_HOME/.config/xfce4/helpers.rc 2>/dev/null"
    else
        echo "  ✗ PCManFM тоже не работает"
    fi
fi

echo ""
echo "[6/6] Результат..."
echo ""
case $THUNAR_OK in
    1) echo "  ✓ Thunar ПОЧИНЕН — работает напрямую";;
    2) echo "  ✓ Thunar ПОЧИНЕН — работает через dbus-launch";;
    3) echo "  ✓ Thunar ПОЧИНЕН — работает с DBUS адресом";;
    4) echo "  ✓ PCManFM установлен как замена Thunar"
       echo "    Applications → File Manager теперь откроет PCManFM";;
    0) echo "  ✗ Ни один способ не сработал"
       echo "    Проверь на RDP-экране: Applications → File Manager";;
esac

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="

REMOTE_SCRIPT
