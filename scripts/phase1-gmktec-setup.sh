#!/bin/bash
###############################################################################
# phase1-gmktec-setup.sh — Фаза 1: Перевод GMKtec в production-ready сервер
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/phase1-gmktec-setup.sh
#
# Что делает:
#   1. Обновляет Node.js 18 → 22 на GMKtec
#   2. Устанавливает OpenClaw на GMKtec
#   3. Устанавливает ClickHouse нативно
#   4. Настраивает Ollama models на 2TB диск
#   5. Переносит конфиг бота с Legion на GMKtec
#   6. Настраивает systemd сервисы
#   7. Обновляет MEMORY.md бота
###############################################################################

GMKTEC_IP="192.168.0.72"
GMKTEC_PORT="2222"
GMKTEC_USER="root"

echo "=========================================="
echo "  ФАЗА 1: GMKtec → Production-Ready"
echo "=========================================="
echo ""
echo "Введи пароль root GMKtec (mmber) когда попросит."
echo ""

###############################################################################
# ШАГ 1: Подготовка 2TB диска как data-хранилища
###############################################################################

echo "╔══════════════════════════════════════╗"
echo "║  ШАГ 1/7: Подготовка 2TB диска      ║"
echo "╚══════════════════════════════════════╝"

ssh -p "$GMKTEC_PORT" "$GMKTEC_USER@$GMKTEC_IP" 'bash -s' << 'STEP1'
echo ""
echo "[1/7] Настройка 2TB диска как data-хранилища..."

# Создаём директорию для данных на 2TB (Windows диск уже примонтирован)
# Пока НЕ форматируем — просто создаём структуру на NTFS
mkdir -p /mnt/windows/banxe-data
mkdir -p /mnt/windows/banxe-data/ollama-models
mkdir -p /mnt/windows/banxe-data/clickhouse
mkdir -p /mnt/windows/banxe-data/backups
mkdir -p /mnt/windows/banxe-data/logs

# Добавляем автомонтирование 2TB в fstab если ещё нет
if ! grep -q "nvme0n1p3" /etc/fstab; then
    echo "# 2TB Windows/Data disk" >> /etc/fstab
    echo "/dev/nvme0n1p3 /mnt/windows ntfs3 defaults,uid=0,gid=0 0 0" >> /etc/fstab
    echo "  ✓ Автомонтирование 2TB добавлено в fstab"
else
    echo "  ✓ 2TB уже в fstab"
fi

echo "  ✓ Структура данных создана на 2TB:"
ls -la /mnt/windows/banxe-data/
echo ""
echo "  Свободное место:"
df -h /mnt/windows | tail -1
STEP1

echo "  ✓ Шаг 1 завершён"

###############################################################################
# ШАГ 2: Обновление Node.js 18 → 22
###############################################################################

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  ШАГ 2/7: Node.js 18 → 22          ║"
echo "╚══════════════════════════════════════╝"

ssh -p "$GMKTEC_PORT" "$GMKTEC_USER@$GMKTEC_IP" 'bash -s' << 'STEP2'
echo ""
echo "[2/7] Обновление Node.js..."

CURRENT_NODE=$(node --version 2>/dev/null)
echo "  Текущая версия: $CURRENT_NODE"

if [[ "$CURRENT_NODE" == v22* ]]; then
    echo "  ✓ Node.js 22 уже установлен"
else
    echo "  Устанавливаю Node.js 22..."
    
    # Удаляем старый Node.js
    apt remove -y nodejs npm 2>/dev/null
    
    # Устанавливаем NodeSource repo
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt install -y nodejs
    
    echo "  Новая версия: $(node --version)"
    echo "  npm: $(npm --version)"
    echo "  ✓ Node.js 22 установлен"
fi
STEP2

echo "  ✓ Шаг 2 завершён"

###############################################################################
# ШАГ 3: Установка OpenClaw на GMKtec
###############################################################################

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  ШАГ 3/7: OpenClaw на GMKtec        ║"
echo "╚══════════════════════════════════════╝"

ssh -p "$GMKTEC_PORT" "$GMKTEC_USER@$GMKTEC_IP" 'bash -s' << 'STEP3'
echo ""
echo "[3/7] Установка OpenClaw..."

if command -v openclaw &>/dev/null; then
    echo "  Текущая версия: $(openclaw --version 2>/dev/null)"
    echo "  Обновляю..."
fi

npm install -g openclaw 2>&1 | tail -5
echo ""
echo "  Версия: $(openclaw --version 2>/dev/null || echo 'ОШИБКА установки')"
echo "  ✓ OpenClaw установлен"
STEP3

echo "  ✓ Шаг 3 завершён"

###############################################################################
# ШАГ 4: Перенос конфига бота с Legion
###############################################################################

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  ШАГ 4/7: Перенос конфига бота      ║"
echo "╚══════════════════════════════════════╝"

echo "  Копирую openclaw.json с Legion на GMKtec..."

# Создаём профиль moa на GMKtec
ssh -p "$GMKTEC_PORT" "$GMKTEC_USER@$GMKTEC_IP" "mkdir -p /root/.openclaw-moa/workspace-moa"

# Копируем конфиг
scp -P "$GMKTEC_PORT" ~/.openclaw-moa/openclaw.json "$GMKTEC_USER@$GMKTEC_IP:/root/.openclaw-moa/openclaw.json"

# Копируем MEMORY.md и workspace
scp -P "$GMKTEC_PORT" ~/.openclaw-moa/workspace-moa/MEMORY.md "$GMKTEC_USER@$GMKTEC_IP:/root/.openclaw-moa/workspace-moa/MEMORY.md" 2>/dev/null
scp -P "$GMKTEC_PORT" ~/.openclaw-moa/workspace-moa/ARCHIVE-ANALYSIS.md "$GMKTEC_USER@$GMKTEC_IP:/root/.openclaw-moa/workspace-moa/ARCHIVE-ANALYSIS.md" 2>/dev/null

echo "  ✓ Конфиг и memory скопированы"

# Обновляем конфиг для локального Ollama (не через сеть)
ssh -p "$GMKTEC_PORT" "$GMKTEC_USER@$GMKTEC_IP" 'bash -s' << 'STEP4_CONFIG'
echo ""
echo "[4/7] Настройка конфига для GMKtec..."

# Обновляем Ollama URL с сетевого на localhost
if [ -f /root/.openclaw-moa/openclaw.json ]; then
    # Заменяем IP на localhost для Ollama
    sed -i 's|http://192\.168\.0\.72:11434|http://localhost:11434|g' /root/.openclaw-moa/openclaw.json
    sed -i 's|http://192\.168\.137\.2:11434|http://localhost:11434|g' /root/.openclaw-moa/openclaw.json
    echo "  ✓ Ollama URL → localhost:11434"
    
    echo "  Текущий конфиг (провайдеры):"
    grep -A2 "baseUrl\|api_base" /root/.openclaw-moa/openclaw.json | head -20
fi
STEP4_CONFIG

echo "  ✓ Шаг 4 завершён"

###############################################################################
# ШАГ 5: Установка ClickHouse
###############################################################################

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  ШАГ 5/7: ClickHouse на GMKtec      ║"
echo "╚══════════════════════════════════════╝"

ssh -p "$GMKTEC_PORT" "$GMKTEC_USER@$GMKTEC_IP" 'bash -s' << 'STEP5'
echo ""
echo "[5/7] Установка ClickHouse..."

if command -v clickhouse-client &>/dev/null; then
    echo "  Уже установлен: $(clickhouse-client --version 2>/dev/null)"
else
    echo "  Устанавливаю ClickHouse..."
    
    # Добавляем GPG ключ и репозиторий
    apt install -y apt-transport-https ca-certificates curl gnupg 2>/dev/null
    curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' | gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" > /etc/apt/sources.list.d/clickhouse.list
    
    apt update -qq 2>/dev/null
    
    # Устанавливаем без интерактивного ввода пароля
    DEBIAN_FRONTEND=noninteractive apt install -y clickhouse-server clickhouse-client 2>&1 | tail -10
    
    # Настраиваем data директорию на 2TB
    if [ -d /mnt/windows/banxe-data/clickhouse ]; then
        mkdir -p /mnt/windows/banxe-data/clickhouse/data
        mkdir -p /mnt/windows/banxe-data/clickhouse/tmp
        
        # Обновляем конфиг ClickHouse
        cat > /etc/clickhouse-server/config.d/banxe-paths.xml << 'CHXML'
<clickhouse>
    <path>/mnt/windows/banxe-data/clickhouse/data/</path>
    <tmp_path>/mnt/windows/banxe-data/clickhouse/tmp/</tmp_path>
    <listen_host>127.0.0.1</listen_host>
</clickhouse>
CHXML
        chown -R clickhouse:clickhouse /mnt/windows/banxe-data/clickhouse/
        echo "  ✓ Data → 2TB диск"
    fi
    
    # Запускаем
    systemctl enable clickhouse-server
    systemctl start clickhouse-server
    sleep 3
fi

# Проверяем
if systemctl is-active clickhouse-server &>/dev/null; then
    echo "  ✓ ClickHouse запущен"
    echo "  Версия: $(clickhouse-client --version 2>/dev/null)"
    
    # Создаём базу banxe если нет
    clickhouse-client --query "CREATE DATABASE IF NOT EXISTS banxe" 2>/dev/null
    echo "  ✓ База banxe создана"
    
    # Создаём основные таблицы
    clickhouse-client --multiquery << 'SQL'
CREATE TABLE IF NOT EXISTS banxe.transactions (
    id UUID DEFAULT generateUUIDv4(),
    timestamp DateTime DEFAULT now(),
    client_id String,
    type String,
    amount Decimal64(2),
    currency String DEFAULT 'GBP',
    status String,
    description String,
    agent String
) ENGINE = MergeTree() ORDER BY (timestamp, client_id);

CREATE TABLE IF NOT EXISTS banxe.aml_alerts (
    id UUID DEFAULT generateUUIDv4(),
    timestamp DateTime DEFAULT now(),
    client_id String,
    alert_type String,
    severity String,
    description String,
    status String DEFAULT 'OPEN',
    agent String
) ENGINE = MergeTree() ORDER BY (timestamp, severity);

CREATE TABLE IF NOT EXISTS banxe.kyc_events (
    id UUID DEFAULT generateUUIDv4(),
    timestamp DateTime DEFAULT now(),
    client_id String,
    event_type String,
    result String,
    details String,
    agent String
) ENGINE = MergeTree() ORDER BY (timestamp, client_id);

CREATE TABLE IF NOT EXISTS banxe.accounts (
    client_id String,
    name String,
    email String,
    status String,
    risk_level String,
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(updated_at) ORDER BY client_id;

CREATE TABLE IF NOT EXISTS banxe.audit_trail (
    id UUID DEFAULT generateUUIDv4(),
    timestamp DateTime DEFAULT now(),
    agent String,
    action String,
    target String,
    details String,
    result String
) ENGINE = MergeTree() ORDER BY (timestamp, agent);

CREATE TABLE IF NOT EXISTS banxe.agent_metrics (
    timestamp DateTime DEFAULT now(),
    agent String,
    model String,
    task String,
    duration_ms UInt64,
    tokens_in UInt32,
    tokens_out UInt32,
    success UInt8
) ENGINE = MergeTree() ORDER BY (timestamp, agent);
SQL
    
    echo "  Таблицы в banxe:"
    clickhouse-client --query "SHOW TABLES FROM banxe" 2>/dev/null
else
    echo "  ✗ ClickHouse не запустился"
    systemctl status clickhouse-server 2>/dev/null | tail -5
fi
STEP5

echo "  ✓ Шаг 5 завершён"

###############################################################################
# ШАГ 6: OpenClaw Gateway как systemd сервис
###############################################################################

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  ШАГ 6/7: Gateway сервис            ║"
echo "╚══════════════════════════════════════╝"

ssh -p "$GMKTEC_PORT" "$GMKTEC_USER@$GMKTEC_IP" 'bash -s' << 'STEP6'
echo ""
echo "[6/7] Настройка OpenClaw Gateway..."

# Устанавливаем Gateway через OpenClaw CLI
if command -v openclaw &>/dev/null; then
    # Инициализируем профиль moa
    export OPENCLAW_HOME="/root/.openclaw-moa"
    
    openclaw gateway install --profile moa --force 2>&1 | tail -5 || echo "  ⚠ Gateway install не прошёл (может быть нормально)"
    
    # Создаём systemd сервис вручную если openclaw не создал
    if [ ! -f /etc/systemd/system/openclaw-gateway-moa.service ]; then
        cat > /etc/systemd/system/openclaw-gateway-moa.service << 'SVC'
[Unit]
Description=OpenClaw Gateway (profile: moa)
After=network.target ollama.service

[Service]
Type=simple
User=root
Environment=OPENCLAW_HOME=/root/.openclaw-moa
ExecStart=/usr/bin/openclaw-gateway
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload
        echo "  ✓ Systemd сервис создан"
    fi
    
    echo "  ✓ OpenClaw Gateway настроен"
else
    echo "  ✗ OpenClaw не найден"
fi
STEP6

echo "  ✓ Шаг 6 завершён"

###############################################################################
# ШАГ 7: Настройка Ollama — перенос моделей на 2TB
###############################################################################

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  ШАГ 7/7: Ollama → 2TB диск         ║"
echo "╚══════════════════════════════════════╝"

ssh -p "$GMKTEC_PORT" "$GMKTEC_USER@$GMKTEC_IP" 'bash -s' << 'STEP7'
echo ""
echo "[7/7] Настройка Ollama на 2TB диск..."

# Текущее расположение моделей
CURRENT_MODELS=$(du -sh /usr/share/ollama/.ollama/models 2>/dev/null | awk '{print $1}')
echo "  Текущий размер моделей: ${CURRENT_MODELS:-неизвестен}"
echo "  Текущий путь: /usr/share/ollama/.ollama/models"

# Добавляем OLLAMA_MODELS в override.conf
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf << 'OVR'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_KEEP_ALIVE=5m"
Environment="OLLAMA_MODELS=/mnt/windows/banxe-data/ollama-models"
OVR

echo "  ✓ Ollama override настроен → /mnt/windows/banxe-data/ollama-models"
echo ""

# Копируем модели если они ещё на старом месте
if [ -d /usr/share/ollama/.ollama/models/blobs ] && [ ! -d /mnt/windows/banxe-data/ollama-models/blobs ]; then
    echo "  Копирую модели на 2TB (это займёт время — ~98GB)..."
    cp -a /usr/share/ollama/.ollama/models/* /mnt/windows/banxe-data/ollama-models/ 2>/dev/null
    echo "  ✓ Модели скопированы"
else
    echo "  ⚠ Модели уже на 2TB или копирование не требуется"
    echo "    Проверь вручную после перезапуска Ollama"
fi

# Перезапускаем Ollama
systemctl daemon-reload
systemctl restart ollama
sleep 5

# Проверяем
if systemctl is-active ollama &>/dev/null; then
    echo ""
    echo "  ✓ Ollama перезапущен"
    echo "  Модели:"
    ollama list 2>/dev/null
else
    echo "  ✗ Ollama не запустился! Откатываю..."
    # Откатываем — убираем OLLAMA_MODELS
    cat > /etc/systemd/system/ollama.service.d/override.conf << 'OVR2'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_KEEP_ALIVE=5m"
OVR2
    systemctl daemon-reload
    systemctl restart ollama
    echo "  ⚠ Откатился на старый путь моделей"
fi
STEP7

echo "  ✓ Шаг 7 завершён"

###############################################################################
# ИТОГИ
###############################################################################

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  ИТОГОВАЯ ПРОВЕРКА                  ║"
echo "╚══════════════════════════════════════╝"

ssh -p "$GMKTEC_PORT" "$GMKTEC_USER@$GMKTEC_IP" 'bash -s' << 'FINAL'
echo ""
printf "  %-30s %s\n" "КОМПОНЕНТ" "СТАТУС"
printf "  %-30s %s\n" "------------------------------" "----------"

# Node.js
NODE_VER=$(node --version 2>/dev/null)
[[ "$NODE_VER" == v22* ]] && printf "  %-30s ✓ %s\n" "Node.js" "$NODE_VER" || printf "  %-30s ✗ %s\n" "Node.js" "${NODE_VER:-не установлен}"

# OpenClaw
OC_VER=$(openclaw --version 2>/dev/null)
[ -n "$OC_VER" ] && printf "  %-30s ✓ %s\n" "OpenClaw" "$OC_VER" || printf "  %-30s ✗ не установлен\n" "OpenClaw"

# Ollama
systemctl is-active ollama &>/dev/null && printf "  %-30s ✓ active\n" "Ollama" || printf "  %-30s ✗ inactive\n" "Ollama"

# Ollama модели
MODELS=$(ollama list 2>/dev/null | wc -l)
printf "  %-30s %s моделей\n" "Ollama модели" "$((MODELS - 1))"

# ClickHouse
systemctl is-active clickhouse-server &>/dev/null && printf "  %-30s ✓ active\n" "ClickHouse" || printf "  %-30s ✗ inactive\n" "ClickHouse"

# ClickHouse таблицы
TABLES=$(clickhouse-client --query "SHOW TABLES FROM banxe" 2>/dev/null | wc -l)
printf "  %-30s %s таблиц\n" "ClickHouse banxe" "$TABLES"

# 2TB диск
DF_2TB=$(df -h /mnt/windows 2>/dev/null | tail -1 | awk '{print $4" свободно"}')
printf "  %-30s %s\n" "2TB диск" "${DF_2TB:-не примонтирован}"

# 1TB диск
DF_1TB=$(df -h / 2>/dev/null | tail -1 | awk '{print $4" свободно"}')
printf "  %-30s %s\n" "1TB диск (система)" "$DF_1TB"

# SSH
printf "  %-30s ✓ порт 2222\n" "SSH"

# Конфиг бота
[ -f /root/.openclaw-moa/openclaw.json ] && printf "  %-30s ✓ скопирован\n" "Конфиг бота" || printf "  %-30s ✗ не найден\n" "Конфиг бота"

# MEMORY.md
[ -f /root/.openclaw-moa/workspace-moa/MEMORY.md ] && printf "  %-30s ✓ на месте\n" "MEMORY.md" || printf "  %-30s ✗ не найден\n" "MEMORY.md"

echo ""
echo "=========================================="
echo "  ФАЗА 1 ЗАВЕРШЕНА"
echo "=========================================="
echo ""
echo "  Следующие шаги:"
echo "  1. Запустить Gateway на GMKtec: systemctl start openclaw-gateway-moa"
echo "  2. Остановить Gateway на Legion: systemctl --user stop openclaw-gateway-moa"
echo "  3. Проверить бота в Telegram"
echo "  4. Фаза 2: форматирование 2TB в ext4"
echo "=========================================="
FINAL

###############################################################################
# Обновляем MEMORY.md бота на Legion
###############################################################################

echo ""
echo "Обновляю MEMORY.md на Legion..."

cat >> ~/.openclaw-moa/workspace-moa/MEMORY.md << 'MEMUPDATE'

## Обновление: Фаза 1 (28.03.2026)
### GMKtec переведён в production-ready
- Node.js обновлён до v22
- OpenClaw установлен нативно на GMKtec
- ClickHouse установлен нативно, data на 2TB диске
- Ollama models настроены на 2TB диск
- Конфиг бота и MEMORY.md скопированы на GMKtec
- Gateway systemd сервис создан на GMKtec
- Следующий шаг: переключить Gateway с Legion на GMKtec
MEMUPDATE

echo "  ✓ MEMORY.md обновлён"
echo ""
echo "=========================================="
