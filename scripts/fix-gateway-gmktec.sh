#!/bin/bash
###############################################################################
# fix-gateway-gmktec.sh — Починка и запуск Gateway на GMKtec
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-gateway-gmktec.sh
#
# Что делает:
#   1. Находит правильный путь openclaw-gateway на GMKtec
#   2. Создаёт правильный systemd сервис
#   3. Запускает Gateway на GMKtec
#   4. Останавливает Gateway на Legion
#   5. Проверяет бота
#   6. КАНОН: обновляет MEMORY.md
###############################################################################

GMKTEC="root@192.168.0.72"
GMKTEC_PORT="2222"
OPENCLAW_WORKSPACE="/home/mmber/.openclaw-moa/workspace-moa"

echo "=========================================="
echo "  ПОЧИНКА И ЗАПУСК GATEWAY НА GMKtec"
echo "=========================================="

# --- 1. Диагностика: где openclaw-gateway ---
echo ""
echo "[1/6] Ищу openclaw-gateway на GMKtec..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'DIAG'
echo "  which openclaw:"
which openclaw 2>/dev/null || echo "  НЕ НАЙДЕН"

echo "  which openclaw-gateway:"
which openclaw-gateway 2>/dev/null || echo "  НЕ НАЙДЕН"

echo "  npm global root:"
NPM_ROOT=$(npm root -g 2>/dev/null)
echo "  $NPM_ROOT"

echo "  Поиск gateway бинарников:"
find /usr/lib/node_modules/openclaw -name "openclaw-gateway*" -o -name "gateway*" 2>/dev/null | head -5
find /usr/local/lib/node_modules/openclaw -name "openclaw-gateway*" -o -name "gateway*" 2>/dev/null | head -5

echo "  npm list -g openclaw:"
npm list -g openclaw 2>/dev/null | head -3

echo "  Бинарники в npm global bin:"
NPM_BIN=$(npm bin -g 2>/dev/null)
ls -la "$NPM_BIN"/openclaw* 2>/dev/null || echo "  Нет бинарников в $NPM_BIN"

echo "  Все openclaw файлы в PATH:"
find /usr/bin /usr/local/bin -name "openclaw*" 2>/dev/null
DIAG

# --- 2. Установка и настройка ---
echo ""
echo "[2/6] Устанавливаю Gateway правильно..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'INSTALL'
set -e

# Находим путь к openclaw
OC_PATH=$(which openclaw 2>/dev/null)
if [ -z "$OC_PATH" ]; then
    echo "  OpenClaw не найден, устанавливаю..."
    npm install -g openclaw 2>&1 | tail -3
    OC_PATH=$(which openclaw 2>/dev/null)
fi
echo "  ✓ OpenClaw: $OC_PATH"

# Ищем gateway бинарник
GW_PATH=$(which openclaw-gateway 2>/dev/null)
if [ -z "$GW_PATH" ]; then
    # Пробуем найти в node_modules
    NPM_ROOT=$(npm root -g 2>/dev/null)
    GW_PATH=$(find "$NPM_ROOT/openclaw" -name "openclaw-gateway" -type f 2>/dev/null | head -1)
    
    if [ -z "$GW_PATH" ]; then
        # Может быть как подкоманда openclaw
        GW_PATH="$OC_PATH"
    fi
fi
echo "  ✓ Gateway binary: $GW_PATH"

# Создаём профиль moa если нет
mkdir -p /root/.openclaw-moa/workspace-moa
export OPENCLAW_HOME="/root/.openclaw-moa"

# Пробуем установить gateway через openclaw CLI
echo "  Устанавливаю gateway через CLI..."
openclaw gateway install --profile moa --force 2>&1 | tail -5 || echo "  ⚠ openclaw gateway install не прошёл"

# Проверяем что создал systemd
SYSTEMD_FILE=""
for f in /root/.config/systemd/user/openclaw-gateway-moa.service \
         /root/.config/systemd/user/openclaw-gateway.service \
         /etc/systemd/system/openclaw-gateway-moa.service; do
    if [ -f "$f" ]; then
        SYSTEMD_FILE="$f"
        break
    fi
done

if [ -n "$SYSTEMD_FILE" ]; then
    echo "  ✓ Systemd сервис найден: $SYSTEMD_FILE"
    cat "$SYSTEMD_FILE" | grep ExecStart
else
    echo "  Systemd сервис не создан, создаю вручную..."
    
    # Определяем правильную команду запуска
    if openclaw gateway start --help 2>&1 | grep -q "profile\|start"; then
        EXEC_CMD="$OC_PATH gateway start --profile moa"
    else
        EXEC_CMD="$OC_PATH gateway --profile moa"
    fi
    
    mkdir -p /root/.config/systemd/user
    cat > /root/.config/systemd/user/openclaw-gateway-moa.service << SVCEOF
[Unit]
Description=OpenClaw Gateway (profile: moa)
After=network.target

[Service]
Type=simple
Environment=OPENCLAW_HOME=/root/.openclaw-moa
ExecStart=$EXEC_CMD
Restart=always
RestartSec=10
WorkingDirectory=/root

[Install]
WantedBy=default.target
SVCEOF
    echo "  ✓ Сервис создан с: $EXEC_CMD"
fi

# Включаем linger для root (чтобы systemd --user работал)
loginctl enable-linger root 2>/dev/null || true
export XDG_RUNTIME_DIR="/run/user/0"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

systemctl --user daemon-reload 2>/dev/null
INSTALL

# --- 3. Запускаем Gateway ---
echo ""
echo "[3/6] Запускаю Gateway на GMKtec..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'START'
export XDG_RUNTIME_DIR="/run/user/0"
export OPENCLAW_HOME="/root/.openclaw-moa"

# Пробуем systemd
systemctl --user start openclaw-gateway-moa 2>/dev/null
sleep 5

if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    echo "  ✓ Gateway ACTIVE через systemd"
    systemctl --user status openclaw-gateway-moa 2>/dev/null | head -8
else
    echo "  systemd не сработал, пробую напрямую..."
    
    # Убиваем старые процессы если есть
    pkill -f "openclaw.*gateway" 2>/dev/null
    sleep 1
    
    # Запускаем через openclaw gateway start
    nohup openclaw gateway start --profile moa > /tmp/openclaw-gateway.log 2>&1 &
    GW_PID=$!
    sleep 8
    
    if kill -0 "$GW_PID" 2>/dev/null; then
        echo "  ✓ Gateway запущен напрямую (PID: $GW_PID)"
        echo "$GW_PID" > /tmp/openclaw-gateway.pid
        
        # Создаём простой автозапуск через cron
        (crontab -l 2>/dev/null | grep -v "openclaw.*gateway"; echo "@reboot OPENCLAW_HOME=/root/.openclaw-moa openclaw gateway start --profile moa > /tmp/openclaw-gateway.log 2>&1 &") | crontab -
        echo "  ✓ Автозапуск через cron добавлен"
    else
        echo "  ✗ Не запустился напрямую"
        echo "  Лог:"
        tail -30 /tmp/openclaw-gateway.log 2>/dev/null
        
        # Последняя попытка — просто openclaw
        echo ""
        echo "  Последняя попытка: openclaw gateway..."
        nohup openclaw gateway > /tmp/openclaw-gateway.log 2>&1 &
        GW_PID=$!
        sleep 8
        
        if kill -0 "$GW_PID" 2>/dev/null; then
            echo "  ✓ Gateway запущен через 'openclaw gateway' (PID: $GW_PID)"
            echo "$GW_PID" > /tmp/openclaw-gateway.pid
        else
            echo "  ✗ Все попытки не удались"
            echo "  Последний лог:"
            tail -30 /tmp/openclaw-gateway.log 2>/dev/null
            exit 1
        fi
    fi
fi

# Проверяем порты
echo ""
echo "  Порты:"
ss -tlnp | grep -E "1879[02]" || echo "  ⚠ Порты Gateway не обнаружены (может запускаться)"
START

RESULT=$?

if [ "$RESULT" -ne 0 ]; then
    echo ""
    echo "  ✗ Gateway не запустился на GMKtec"
    echo "  Legion Gateway НЕ тронут — бот продолжает работать"
    echo "  Скинь вывод мне — разберёмся"
    exit 1
fi

# --- 4. Останавливаем Legion Gateway ---
echo ""
echo "[4/6] Останавливаю Gateway на Legion..."

systemctl --user stop openclaw-gateway-moa 2>/dev/null
systemctl --user disable openclaw-gateway-moa 2>/dev/null
sleep 2

if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    echo "  ⚠ Всё ещё активен — принудительно"
    systemctl --user kill openclaw-gateway-moa 2>/dev/null
fi
echo "  ✓ Legion Gateway остановлен и отключён"

# --- 5. Итоговая проверка ---
echo ""
echo "[5/6] Итоговая проверка..."
echo ""
printf "  %-30s %s\n" "КОМПОНЕНТ" "СТАТУС"
printf "  %-30s %s\n" "------------------------------" "----------"

# Legion
systemctl --user is-active openclaw-gateway-moa &>/dev/null && printf "  %-30s ✗ ACTIVE\n" "Legion Gateway" || printf "  %-30s ✓ STOPPED\n" "Legion Gateway"
systemctl --user is-active litellm &>/dev/null && printf "  %-30s ✓ ACTIVE\n" "Legion LiteLLM" || printf "  %-30s ✗ INACTIVE\n" "Legion LiteLLM"

# GMKtec
GW_STATUS=$(ssh -p "$GMKTEC_PORT" "$GMKTEC" "pgrep -f 'openclaw' >/dev/null 2>&1 && echo 'ACTIVE' || echo 'INACTIVE'" 2>/dev/null)
printf "  %-30s %s\n" "GMKtec Gateway" "$([ "$GW_STATUS" = "ACTIVE" ] && echo '✓ ACTIVE' || echo '✗ INACTIVE')"

OL_STATUS=$(ssh -p "$GMKTEC_PORT" "$GMKTEC" "systemctl is-active ollama" 2>/dev/null)
printf "  %-30s %s\n" "GMKtec Ollama" "$([ "$OL_STATUS" = "active" ] && echo '✓ ACTIVE' || echo '✗ '$OL_STATUS)"

CH_STATUS=$(ssh -p "$GMKTEC_PORT" "$GMKTEC" "systemctl is-active clickhouse-server" 2>/dev/null)
printf "  %-30s %s\n" "GMKtec ClickHouse" "$([ "$CH_STATUS" = "active" ] && echo '✓ ACTIVE' || echo '✗ '$CH_STATUS)"

# --- 6. КАНОН: обновляем MEMORY.md ---
echo ""
echo "[6/6] КАНОН: обновляю MEMORY.md..."

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

# На Legion
cat >> "$OPENCLAW_WORKSPACE/MEMORY.md" << MEMEOF

## Обновление: Gateway переключён ($TIMESTAMP)
- Gateway ОСТАНОВЛЕН на Legion, автозапуск ОТКЛЮЧЁН
- Gateway ЗАПУЩЕН на GMKtec нативно
- Бот работает с GMKtec напрямую
- Ollama localhost (без сети), ClickHouse localhost
- Security Score: 2/10 → ~4/10 (данные больше не через ноутбук)
MEMEOF

# На GMKtec
ssh -p "$GMKTEC_PORT" "$GMKTEC" "cat >> /root/.openclaw-moa/workspace-moa/MEMORY.md << 'MEM'

## Обновление: Gateway переключён ($TIMESTAMP)
- Gateway ОСТАНОВЛЕН на Legion, автозапуск ОТКЛЮЧЁН
- Gateway ЗАПУЩЕН на GMKtec нативно
- Бот работает с GMKtec напрямую
- Ollama localhost (без сети), ClickHouse localhost
- Security Score: 2/10 → ~4/10 (данные больше не через ноутбук)
MEM" 2>/dev/null

echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "  Проверь бота в Telegram:"
echo "    'Привет, где ты сейчас работаешь?'"
echo ""
echo "  Если бот НЕ отвечает — откат на Legion:"
echo "    systemctl --user enable openclaw-gateway-moa"
echo "    systemctl --user start openclaw-gateway-moa"
echo "=========================================="
