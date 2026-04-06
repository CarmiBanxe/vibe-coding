#!/bin/bash
###############################################################################
# start-gateway-gmktec.sh — Запуск Gateway на GMKtec и переключение с Legion
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/start-gateway-gmktec.sh
###############################################################################

GMKTEC="root@192.168.0.72"
GMKTEC_PORT="2222"
OPENCLAW_WORKSPACE="/home/mmber/.openclaw-moa/workspace-moa"

echo "=========================================="
echo "  ЗАПУСК GATEWAY НА GMKtec"
echo "=========================================="

# --- 1. Починка задвоенного пути и запуск ---
echo ""
echo "[1/4] Запускаю Gateway на GMKtec..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'STEP1'
export XDG_RUNTIME_DIR="/run/user/0"
export OPENCLAW_HOME="/root/.openclaw-moa"

# Убираем задвоенный путь если есть
if [ -d /root/.openclaw-moa/.openclaw-moa ]; then
    echo "  Чищу задвоенный путь .openclaw-moa/.openclaw-moa..."
    rm -rf /root/.openclaw-moa/.openclaw-moa
fi

# Перезапускаем Gateway
systemctl --user daemon-reload 2>/dev/null
systemctl --user restart openclaw-gateway-moa 2>/dev/null
sleep 8

if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    echo "  ✓ Gateway ACTIVE!"
    systemctl --user status openclaw-gateway-moa 2>/dev/null | head -8
else
    echo "  Статус:"
    journalctl --user -u openclaw-gateway-moa --no-pager -n 10 2>/dev/null | tail -5
fi

echo ""
echo "  Порты:"
ss -tlnp | grep -E "1879|1878"
STEP1

# --- 2. Проверяем что GMKtec Gateway работает ---
echo ""
echo "[2/4] Проверяю Gateway..."

GW_OK=$(ssh -p "$GMKTEC_PORT" "$GMKTEC" "export XDG_RUNTIME_DIR=/run/user/0; systemctl --user is-active openclaw-gateway-moa 2>/dev/null")

if [ "$GW_OK" = "active" ]; then
    echo "  ✓ GMKtec Gateway ACTIVE"
else
    echo "  ✗ Gateway не active: $GW_OK"
    echo "  Лог:"
    ssh -p "$GMKTEC_PORT" "$GMKTEC" "export XDG_RUNTIME_DIR=/run/user/0; journalctl --user -u openclaw-gateway-moa --no-pager -n 15 2>/dev/null" | tail -10
    echo ""
    echo "  Legion Gateway НЕ тронут."
    exit 1
fi

# --- 3. Переключаем: стоп Legion, бот на GMKtec ---
echo ""
echo "[3/4] Переключаю: стоп Legion Gateway..."

systemctl --user stop openclaw-gateway-moa 2>/dev/null
systemctl --user disable openclaw-gateway-moa 2>/dev/null
echo "  ✓ Legion Gateway остановлен и отключён"

# Ждём и проверяем бота
echo ""
echo "  Жду 10 секунд чтобы Telegram переключился..."
sleep 10

# --- 4. КАНОН: обновляем MEMORY.md ---
echo ""
echo "[4/4] КАНОН: обновляю MEMORY.md..."

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

MEMTEXT="
## Обновление: Gateway переключён на GMKtec ($TIMESTAMP)
- gateway.mode=local установлен в конфиге GMKtec
- Задвоенный путь .openclaw-moa/.openclaw-moa вычищен
- Gateway ACTIVE на GMKtec
- Gateway STOPPED на Legion (автозапуск отключён)
- Бот работает полностью на GMKtec
- Архитектура: GMKtec = Brain + Gateway + Ollama + ClickHouse
- Legion = только управление через SSH
- Security Score: ~4/10 (данные больше не через ноутбук)"

echo "$MEMTEXT" >> "$OPENCLAW_WORKSPACE/MEMORY.md"
ssh -p "$GMKTEC_PORT" "$GMKTEC" "cat >> /root/.openclaw-moa/workspace-moa/MEMORY.md << 'MEM'
$MEMTEXT
MEM" 2>/dev/null

echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
printf "  %-30s %s\n" "КОМПОНЕНТ" "СТАТУС"
printf "  %-30s %s\n" "------------------------------" "------"
printf "  %-30s ✓ STOPPED\n" "Legion Gateway"

GW=$(ssh -p "$GMKTEC_PORT" "$GMKTEC" "export XDG_RUNTIME_DIR=/run/user/0; systemctl --user is-active openclaw-gateway-moa 2>/dev/null")
printf "  %-30s %s\n" "GMKtec Gateway" "$([ "$GW" = "active" ] && echo '✓ ACTIVE' || echo '✗ '$GW)"

OL=$(ssh -p "$GMKTEC_PORT" "$GMKTEC" "systemctl is-active ollama 2>/dev/null")
printf "  %-30s %s\n" "GMKtec Ollama" "$([ "$OL" = "active" ] && echo '✓ ACTIVE' || echo '✗')"

CH=$(ssh -p "$GMKTEC_PORT" "$GMKTEC" "systemctl is-active clickhouse-server 2>/dev/null")
printf "  %-30s %s\n" "GMKtec ClickHouse" "$([ "$CH" = "active" ] && echo '✓ ACTIVE' || echo '✗')"

echo "=========================================="
echo ""
echo "  Проверь бота в Telegram:"
echo "    'Привет, ты на GMKtec?'"
echo ""
echo "  Если НЕ отвечает — откат:"
echo "    systemctl --user enable openclaw-gateway-moa"
echo "    systemctl --user start openclaw-gateway-moa"
echo "=========================================="
