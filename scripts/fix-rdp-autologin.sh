#!/bin/bash
###############################################################################
# fix-rdp-autologin.sh — Отключение блокировки экрана и таймаута RDP
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-rdp-autologin.sh
###############################################################################

GMKTEC="root@192.168.0.72"
GMKTEC_PORT="2222"

echo "=========================================="
echo "  ОТКЛЮЧЕНИЕ БЛОКИРОВКИ RDP"
echo "=========================================="

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'REMOTE'

echo "[1/4] Отключаю screensaver и lock screen..."
sudo -u banxe DISPLAY=:10 XAUTHORITY=/home/banxe/.Xauthority bash -c '
xfconf-query -c xfce4-screensaver -p /lock/enabled -s false 2>/dev/null
xfconf-query -c xfce4-screensaver -p /saver/enabled -s false 2>/dev/null
xfconf-query -c xfce4-screensaver -p /saver/mode -s 0 2>/dev/null
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -s 0 2>/dev/null
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off -s 0 2>/dev/null
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-sleep -s 0 2>/dev/null
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -s false 2>/dev/null
' 2>/dev/null
echo "  ✓ Screensaver и lock screen отключены"

echo ""
echo "[2/4] Отключаю таймаут XRDP..."
if [ -f /etc/xrdp/sesman.ini ]; then
    sed -i 's/^idle_time=.*/idle_time=0/' /etc/xrdp/sesman.ini
    sed -i 's/^sess_kill_interval=.*/sess_kill_interval=0/' /etc/xrdp/sesman.ini
    echo "  ✓ XRDP таймаут = 0"
else
    echo "  ⚠ sesman.ini не найден"
fi

echo ""
echo "[3/4] Убиваю процессы screensaver..."
pkill -u banxe xfce4-screensaver 2>/dev/null
pkill -u banxe light-locker 2>/dev/null
pkill -u banxe xscreensaver 2>/dev/null
# Удаляем автозапуск screensaver
rm -f /home/banxe/.config/autostart/xfce4-screensaver.desktop 2>/dev/null
rm -f /home/banxe/.config/autostart/light-locker.desktop 2>/dev/null
rm -f /etc/xdg/autostart/xfce4-screensaver.desktop 2>/dev/null
echo "  ✓ Screensaver процессы убиты и автозапуск удалён"

echo ""
echo "[4/4] Перезапускаю XRDP..."
systemctl restart xrdp xrdp-sesman
echo "  ✓ XRDP перезапущен"

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "  Экран больше не будет блокироваться."
echo "  При подключении RDP введи:"
echo "    Username: banxe"
echo "    Password: mmber2025!"
echo "  Сессия не отключится по таймауту."
echo "=========================================="

REMOTE
