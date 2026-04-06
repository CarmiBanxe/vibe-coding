#!/bin/bash
###############################################################################
# fix-rdp-nopassword.sh — RDP без запроса пароля на GMKtec
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-rdp-nopassword.sh
#
# Создаёт RDP-файл на Windows Legion с сохранённым паролем.
# Двойной клик на файл — сразу рабочий стол GMKtec, без логина.
###############################################################################

echo "=========================================="
echo "  RDP БЕЗ ПАРОЛЯ (ярлык на Windows)"
echo "=========================================="

# Путь к рабочему столу Windows
WIN_DESKTOP="/mnt/c/Users/mmber/Desktop"

if [ ! -d "$WIN_DESKTOP" ]; then
    WIN_DESKTOP="/mnt/c/Users/mmber/Рабочий стол"
fi
if [ ! -d "$WIN_DESKTOP" ]; then
    WIN_DESKTOP="/mnt/c/Users/mmber/OneDrive/Desktop"
fi
if [ ! -d "$WIN_DESKTOP" ]; then
    # Ищем
    WIN_DESKTOP=$(find /mnt/c/Users/mmber -maxdepth 2 -name "Desktop" -type d 2>/dev/null | head -1)
fi

echo ""
echo "[1/3] Сохраняю пароль в Windows Credential Manager..."

# Сохраняем credentials через cmdkey (Windows)
cmd.exe /c "cmdkey /generic:192.168.0.117 /user:banxe /pass:mmber2025!" 2>/dev/null
cmd.exe /c "cmdkey /generic:192.168.0.72 /user:banxe /pass:mmber2025!" 2>/dev/null
cmd.exe /c "cmdkey /generic:TERMSRV/192.168.0.117 /user:banxe /pass:mmber2025!" 2>/dev/null
cmd.exe /c "cmdkey /generic:TERMSRV/192.168.0.72 /user:banxe /pass:mmber2025!" 2>/dev/null

echo "  ✓ Пароль сохранён в Windows"

echo ""
echo "[2/3] Создаю RDP-ярлык на рабочем столе..."

# RDP файл с сохранёнными credentials
cat > /tmp/GMKtec.rdp << 'RDPFILE'
screen mode id:i:2
use multimon:i:0
desktopwidth:i:1920
desktopheight:i:1080
session bpp:i:32
winposstr:s:0,1,0,0,1920,1080
compression:i:1
keyboardhook:i:2
audiocapturemode:i:0
videoplaybackmode:i:1
connection type:i:7
networkautodetect:i:1
bandwidthautodetect:i:1
displayconnectionbar:i:1
enableworkspacereconnect:i:0
disable wallpaper:i:0
allow font smoothing:i:1
allow desktop composition:i:1
disable full window drag:i:0
disable menu anims:i:0
disable themes:i:0
disable cursor setting:i:0
bitmapcachepersistenable:i:1
full address:s:192.168.0.117
username:s:banxe
enablecredsspsupport:i:1
authentication level:i:0
prompt for credentials:i:0
negotiate security layer:i:0
remoteapplicationmode:i:0
alternate shell:s:
shell working directory:s:
gatewayhostname:s:
gatewayusagemethod:i:4
gatewaycredentialssource:i:4
gatewayprofileusagemethod:i:0
promptcredentialonce:i:0
gatewaybrokeringtype:i:0
use redirection server name:i:0
rdgiskdcproxy:i:0
kdcproxyname:s:
autoreconnection enabled:i:1
RDPFILE

# Копируем на рабочий стол Windows
if [ -n "$WIN_DESKTOP" ] && [ -d "$WIN_DESKTOP" ]; then
    cp /tmp/GMKtec.rdp "$WIN_DESKTOP/GMKtec.rdp"
    echo "  ✓ Ярлык создан: $WIN_DESKTOP/GMKtec.rdp"
else
    # Пробуем в Documents
    cp /tmp/GMKtec.rdp "/mnt/c/Users/mmber/GMKtec.rdp" 2>/dev/null
    echo "  ✓ Файл: C:\\Users\\mmber\\GMKtec.rdp"
    echo "  ⚠ Рабочий стол не найден — перемести файл вручную"
fi

echo ""
echo "[3/3] Проверяю..."

# Проверяем что credentials сохранены
CREDS=$(cmd.exe /c "cmdkey /list" 2>/dev/null | grep -i "192.168.0")
if [ -n "$CREDS" ]; then
    echo "  ✓ Credentials сохранены в Windows"
else
    echo "  ⚠ Credentials могли не сохраниться"
    echo "  При первом подключении поставь галочку 'Запомнить'"
fi

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "  На рабочем столе Windows появился файл GMKtec.rdp"
echo "  Двойной клик → сразу рабочий стол GMKtec"
echo "  Без логина и пароля!"
echo ""
echo "  Если спросит пароль первый раз:"
echo "    Username: banxe"
echo "    Password: mmber2025!"
echo "    Галочка: 'Запомнить учётные данные'"
echo "=========================================="
