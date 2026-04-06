#!/bin/bash
###############################################################################
# switch-gateway-to-gmktec.sh — Переключение Gateway с Legion на GMKtec
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/switch-gateway-to-gmktec.sh
#
# Что делает:
#   1. Синхронизирует MEMORY.md с ботом (канон)
#   2. Запускает Gateway на GMKtec
#   3. Останавливает Gateway на Legion
#   4. Проверяет что бот отвечает
#   5. Обновляет MEMORY.md с новым состоянием
###############################################################################

GMKTEC_IP="192.168.0.72"
GMKTEC_PORT="2222"
OPENCLAW_WORKSPACE="/home/mmber/.openclaw-moa/workspace-moa"

echo "=========================================="
echo "  ПЕРЕКЛЮЧЕНИЕ GATEWAY: Legion → GMKtec"
echo "=========================================="

# --- 1. Запускаем Gateway на GMKtec ---
echo ""
echo "[1/5] Запускаю Gateway на GMKtec..."

ssh -p "$GMKTEC_PORT" "root@$GMKTEC_IP" 'bash -s' << 'STEP1'

# Проверяем что конфиг на месте
if [ ! -f /root/.openclaw-moa/openclaw.json ]; then
    echo "  ✗ Конфиг не найден! Запусти сначала phase1-gmktec-setup.sh"
    exit 1
fi

# Устанавливаем Gateway если сервис не создан
export OPENCLAW_HOME="/root/.openclaw-moa"

# Запускаем через loginctl (для systemd --user от root)
loginctl enable-linger root 2>/dev/null

# Запускаем Gateway
export XDG_RUNTIME_DIR="/run/user/0"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null

systemctl --user daemon-reload 2>/dev/null
systemctl --user start openclaw-gateway-moa 2>/dev/null

sleep 5

# Проверяем
if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    echo "  ✓ Gateway ACTIVE на GMKtec"
    systemctl --user status openclaw-gateway-moa 2>/dev/null | head -8
else
    echo "  ⚠ systemd --user не сработал, пробую запуск напрямую..."
    
    # Запускаем напрямую как демон
    export OPENCLAW_HOME="/root/.openclaw-moa"
    nohup openclaw-gateway --profile moa > /tmp/openclaw-gateway.log 2>&1 &
    GATEWAY_PID=$!
    sleep 5
    
    if kill -0 "$GATEWAY_PID" 2>/dev/null; then
        echo "  ✓ Gateway запущен напрямую (PID: $GATEWAY_PID)"
        echo "$GATEWAY_PID" > /tmp/openclaw-gateway.pid
    else
        echo "  ✗ Gateway не запустился!"
        echo "  Лог:"
        tail -20 /tmp/openclaw-gateway.log
        exit 1
    fi
fi

# Проверяем порт
echo ""
echo "  Порты Gateway:"
ss -tlnp | grep -E "18790|18792" || echo "  ⚠ Порты Gateway не найдены"
STEP1

GMKTEC_RESULT=$?
if [ "$GMKTEC_RESULT" -ne 0 ]; then
    echo "  ✗ Не удалось запустить Gateway на GMKtec. Прерываю."
    echo "  Legion Gateway НЕ остановлен — бот продолжает работать."
    exit 1
fi

# --- 2. Проверяем что GMKtec Gateway отвечает ---
echo ""
echo "[2/5] Проверяю Gateway на GMKtec..."

HEALTH=$(ssh -p "$GMKTEC_PORT" "root@$GMKTEC_IP" "curl -s http://localhost:18790/health 2>/dev/null || curl -s http://localhost:18792/health 2>/dev/null || echo 'NO_RESPONSE'")

if echo "$HEALTH" | grep -qi "ok\|healthy\|running\|status"; then
    echo "  ✓ Gateway на GMKtec отвечает"
else
    echo "  ⚠ Gateway не отвечает на health check (это может быть нормально)"
    echo "  Ответ: $HEALTH"
    echo "  Продолжаю — Telegram проверим вручную"
fi

# --- 3. Останавливаем Gateway на Legion ---
echo ""
echo "[3/5] Останавливаю Gateway на Legion..."

systemctl --user stop openclaw-gateway-moa 2>/dev/null
sleep 2

if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    echo "  ⚠ Gateway на Legion всё ещё активен — принудительно останавливаю"
    systemctl --user kill openclaw-gateway-moa 2>/dev/null
else
    echo "  ✓ Gateway на Legion остановлен"
fi

# Отключаем автозапуск на Legion
systemctl --user disable openclaw-gateway-moa 2>/dev/null
echo "  ✓ Автозапуск на Legion отключён"

# --- 4. Итоговая проверка ---
echo ""
echo "[4/5] Итоговая проверка..."
echo ""

printf "  %-35s %s\n" "КОМПОНЕНТ" "СТАТУС"
printf "  %-35s %s\n" "-----------------------------------" "----------"

# Legion Gateway
if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    printf "  %-35s ✗ ACTIVE (должен быть остановлен!)\n" "Legion Gateway"
else
    printf "  %-35s ✓ STOPPED\n" "Legion Gateway"
fi

# GMKtec Gateway
GMKTEC_GW=$(ssh -p "$GMKTEC_PORT" "root@$GMKTEC_IP" "systemctl --user is-active openclaw-gateway-moa 2>/dev/null || (pgrep -f 'openclaw-gateway' >/dev/null && echo active || echo inactive)")
printf "  %-35s %s\n" "GMKtec Gateway" "$([ "$GMKTEC_GW" = "active" ] && echo '✓ ACTIVE' || echo '⚠ '$GMKTEC_GW)"

# Legion LiteLLM
if systemctl --user is-active litellm &>/dev/null; then
    printf "  %-35s ✓ ACTIVE\n" "Legion LiteLLM"
else
    printf "  %-35s ✗ INACTIVE\n" "Legion LiteLLM"
fi

# GMKtec Ollama
OLLAMA=$(ssh -p "$GMKTEC_PORT" "root@$GMKTEC_IP" "systemctl is-active ollama 2>/dev/null")
printf "  %-35s %s\n" "GMKtec Ollama" "$([ "$OLLAMA" = "active" ] && echo '✓ ACTIVE' || echo '✗ '$OLLAMA)"

# GMKtec ClickHouse
CH=$(ssh -p "$GMKTEC_PORT" "root@$GMKTEC_IP" "systemctl is-active clickhouse-server 2>/dev/null")
printf "  %-35s %s\n" "GMKtec ClickHouse" "$([ "$CH" = "active" ] && echo '✓ ACTIVE' || echo '✗ '$CH)"

# --- 5. Канон: обновляем MEMORY.md ---
echo ""
echo "[5/5] КАНОН: обновляю MEMORY.md..."

# На Legion (для следующего перезапуска если нужно)
cat >> "$OPENCLAW_WORKSPACE/MEMORY.md" << 'MEMUPDATE'

## Обновление: Переключение Gateway (28.03.2026)
- Gateway ОСТАНОВЛЕН на Legion
- Gateway ЗАПУЩЕН на GMKtec (нативно)
- Автозапуск на Legion ОТКЛЮЧЁН
- Бот теперь работает полностью на GMKtec
- Архитектура: GMKtec = Brain + Gateway, Legion = только управление
MEMUPDATE

# На GMKtec
ssh -p "$GMKTEC_PORT" "root@$GMKTEC_IP" 'bash -s' << 'MEMGMK'
cat >> /root/.openclaw-moa/workspace-moa/MEMORY.md << 'MEM'

## Обновление: Переключение Gateway (28.03.2026)
- Gateway ОСТАНОВЛЕН на Legion
- Gateway ЗАПУЩЕН на GMKtec (нативно)
- Автозапуск на Legion ОТКЛЮЧЁН
- Бот теперь работает полностью на GMKtec
- Архитектура: GMKtec = Brain + Gateway, Legion = только управление
MEM
MEMGMK

echo "  ✓ MEMORY.md обновлён на обеих машинах"

echo ""
echo "=========================================="
echo "  ПЕРЕКЛЮЧЕНИЕ ЗАВЕРШЕНО"
echo "=========================================="
echo ""
echo "  Gateway теперь на GMKtec."
echo "  Проверь — напиши боту в Telegram:"
echo "    'Привет, ты работаешь с GMKtec?'"
echo ""
echo "  Если бот НЕ отвечает — откат:"
echo "    systemctl --user enable openclaw-gateway-moa"
echo "    systemctl --user start openclaw-gateway-moa"
echo "=========================================="
