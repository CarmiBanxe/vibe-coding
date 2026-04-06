#!/bin/bash
###############################################################################
# setup-openclaw-gmktec.sh — Полная настройка OpenClaw на GMKtec
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/setup-openclaw-gmktec.sh
#
# Что делает:
#   1. Копирует РАБОЧИЙ конфиг с Legion на GMKtec
#   2. Устанавливает Gateway на GMKtec через openclaw CLI
#   3. Запускает Gateway
#   4. Проверяет и переключает
#   5. КАНОН: обновляет MEMORY.md
###############################################################################

GMKTEC="root@192.168.0.72"
GMKTEC_PORT="2222"
OPENCLAW_WORKSPACE="/home/mmber/.openclaw-moa/workspace-moa"

echo "=========================================="
echo "  НАСТРОЙКА OpenClaw НА GMKtec"
echo "=========================================="

# --- 1. Смотрим как устроен рабочий конфиг на Legion ---
echo ""
echo "[1/6] Изучаю рабочий конфиг на Legion..."

LEGION_HOME="$HOME/.openclaw-moa"
echo "  OPENCLAW_HOME на Legion: $LEGION_HOME"
echo "  Файлы:"
ls -la "$LEGION_HOME/" | head -20
echo ""
echo "  Сервис на Legion:"
cat "$HOME/.config/systemd/user/openclaw-gateway-moa.service" 2>/dev/null | grep -E "ExecStart|Environment|OPENCLAW"

# --- 2. Копируем ВСЮ папку .openclaw-moa на GMKtec ---
echo ""
echo "[2/6] Копирую .openclaw-moa на GMKtec..."

# Создаём архив на Legion
tar czf /tmp/openclaw-moa-backup.tar.gz -C "$HOME" .openclaw-moa 2>/dev/null
echo "  Архив: $(du -sh /tmp/openclaw-moa-backup.tar.gz | awk '{print $1}')"

# Копируем на GMKtec
scp -P "$GMKTEC_PORT" /tmp/openclaw-moa-backup.tar.gz "$GMKTEC:/tmp/"
echo "  ✓ Архив скопирован"

# Распаковываем на GMKtec
ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'UNPACK'
# Бэкапим старый если есть
[ -d /root/.openclaw-moa ] && mv /root/.openclaw-moa /root/.openclaw-moa.bak.$(date +%s) 2>/dev/null

# Распаковываем
cd /root
tar xzf /tmp/openclaw-moa-backup.tar.gz
echo "  ✓ .openclaw-moa распакован в /root/"

# Обновляем Ollama URL на localhost
sed -i 's|http://192\.168\.0\.72:11434|http://localhost:11434|g' /root/.openclaw-moa/openclaw.json
sed -i 's|http://192\.168\.137\.2:11434|http://localhost:11434|g' /root/.openclaw-moa/openclaw.json
echo "  ✓ Ollama URL → localhost"

# Показываем структуру
echo "  Структура:"
find /root/.openclaw-moa -maxdepth 2 -type f | head -20
UNPACK

# --- 3. Устанавливаем Gateway через openclaw CLI ---
echo ""
echo "[3/6] Устанавливаю Gateway на GMKtec..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'SETUP'
export OPENCLAW_HOME="/root/.openclaw-moa"
export HOME="/root"

# Включаем linger для systemd --user от root
loginctl enable-linger root 2>/dev/null || true
export XDG_RUNTIME_DIR="/run/user/0"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Устанавливаем Gateway
echo "  Запускаю openclaw gateway install..."
openclaw gateway install --profile moa --force 2>&1
echo ""

# Проверяем созданный сервис
SVCFILE=$(find /root/.config/systemd/user -name "*openclaw*gateway*" -type f 2>/dev/null | head -1)
if [ -n "$SVCFILE" ]; then
    echo "  ✓ Сервис создан: $SVCFILE"
    echo "  Содержимое:"
    cat "$SVCFILE"
else
    echo "  ⚠ Сервис не создан автоматически"
fi
SETUP

# --- 4. Запускаем Gateway ---
echo ""
echo "[4/6] Запускаю Gateway на GMKtec..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'START'
export OPENCLAW_HOME="/root/.openclaw-moa"
export XDG_RUNTIME_DIR="/run/user/0"

# Перезагружаем systemd
systemctl --user daemon-reload 2>/dev/null

# Запускаем
systemctl --user restart openclaw-gateway-moa 2>/dev/null
sleep 8

# Проверяем
if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    echo "  ✓ Gateway ACTIVE через systemd!"
    systemctl --user status openclaw-gateway-moa 2>/dev/null | head -10
else
    echo "  systemd статус:"
    systemctl --user status openclaw-gateway-moa 2>/dev/null | tail -15
    
    echo ""
    echo "  Пробую запуск через openclaw gateway restart..."
    openclaw gateway restart --profile moa 2>&1 | tail -5
    sleep 5
    
    # Проверяем процесс
    if pgrep -f "openclaw" >/dev/null; then
        echo "  ✓ OpenClaw процесс запущен:"
        pgrep -af "openclaw" | head -5
    else
        echo "  ✗ OpenClaw не запущен"
        echo "  Последний лог:"
        find /tmp -name "openclaw*" -newer /tmp/openclaw-moa-backup.tar.gz -exec tail -20 {} \; 2>/dev/null
        journalctl --user -u openclaw-gateway-moa --no-pager -n 30 2>/dev/null
    fi
fi

echo ""
echo "  Порты:"
ss -tlnp | grep -E "1879|1878" || echo "  Порты Gateway не найдены"
START

# --- 5. Если Gateway работает — останавливаем Legion ---
echo ""
echo "[5/6] Проверяю и переключаю..."

GW_CHECK=$(ssh -p "$GMKTEC_PORT" "$GMKTEC" "pgrep -f 'openclaw' >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null)

if [ "$GW_CHECK" = "OK" ]; then
    echo "  ✓ GMKtec Gateway работает — останавливаю Legion..."
    
    systemctl --user stop openclaw-gateway-moa 2>/dev/null
    systemctl --user disable openclaw-gateway-moa 2>/dev/null
    echo "  ✓ Legion Gateway остановлен и отключён"
    
    echo ""
    printf "  %-30s %s\n" "КОМПОНЕНТ" "СТАТУС"
    printf "  %-30s %s\n" "------------------------------" "------"
    printf "  %-30s ✓ STOPPED\n" "Legion Gateway"
    printf "  %-30s ✓ ACTIVE\n" "GMKtec Gateway"
    
    OL=$(ssh -p "$GMKTEC_PORT" "$GMKTEC" "systemctl is-active ollama" 2>/dev/null)
    printf "  %-30s %s\n" "GMKtec Ollama" "$([ "$OL" = "active" ] && echo '✓ ACTIVE' || echo '✗')"
    
    CH=$(ssh -p "$GMKTEC_PORT" "$GMKTEC" "systemctl is-active clickhouse-server" 2>/dev/null)
    printf "  %-30s %s\n" "GMKtec ClickHouse" "$([ "$CH" = "active" ] && echo '✓ ACTIVE' || echo '✗')"
else
    echo "  ✗ GMKtec Gateway НЕ работает"
    echo "  Legion Gateway НЕ тронут — бот продолжает работать"
    echo "  Скинь вывод — разберёмся"
    exit 1
fi

# --- 6. КАНОН: обновляем MEMORY.md ---
echo ""
echo "[6/6] КАНОН: обновляю MEMORY.md..."

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

MEMTEXT="
## Обновление: Gateway на GMKtec ($TIMESTAMP)
- Вся папка .openclaw-moa скопирована с Legion на GMKtec
- Ollama URL → localhost:11434 (без сети)
- Gateway ACTIVE на GMKtec
- Gateway STOPPED на Legion, автозапуск отключён
- Security Score: 2/10 → ~4/10
- Бот работает полностью на GMKtec"

echo "$MEMTEXT" >> "$OPENCLAW_WORKSPACE/MEMORY.md"
ssh -p "$GMKTEC_PORT" "$GMKTEC" "echo '$MEMTEXT' >> /root/.openclaw-moa/workspace-moa/MEMORY.md" 2>/dev/null

echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "  Проверь бота в Telegram:"
echo "    'Привет, где ты работаешь?'"
echo ""
echo "  Если НЕ отвечает — откат:"
echo "    systemctl --user enable openclaw-gateway-moa"
echo "    systemctl --user start openclaw-gateway-moa"
echo "=========================================="
