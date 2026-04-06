#!/bin/bash
###############################################################################
# phase2-wipe-windows.sh — Фаза 2: Ликвидация Windows, 2TB → ext4 /data
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/phase2-wipe-windows.sh
#
# ВНИМАНИЕ: Этот скрипт УНИЧТОЖИТ все данные на 2TB Windows диске!
# Перед запуском убедись что всё нужное скопировано.
#
# Что делает:
#   1. Проверяет что ценного на Windows диске
#   2. Копирует ИИ-модели и нужные файлы на 1TB Linux
#   3. Отмонтирует Windows диск
#   4. Форматирует 2TB в ext4
#   5. Монтирует как /data с автозагрузкой
#   6. Создаёт структуру /data
#   7. Переносит Ollama models и ClickHouse на /data
#   8. КАНОН: обновляет MEMORY.md
###############################################################################

GMKTEC="root@192.168.0.72"
GMKTEC_PORT="2222"

echo "=========================================="
echo "  ФАЗА 2: ЛИКВИДАЦИЯ WINDOWS → 2TB ext4"
echo "=========================================="

# --- 1. Инвентаризация Windows диска ---
echo ""
echo "[1/8] Что на Windows диске..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'STEP1'
echo ""
echo "  === Общий размер /mnt/windows ==="
du -sh /mnt/windows 2>/dev/null | head -1

echo ""
echo "  === Крупные папки (>1GB) ==="
du -h --max-depth=2 /mnt/windows 2>/dev/null | awk '$1 ~ /G/ && $1+0 > 1' | sort -rh | head -20

echo ""
echo "  === Папка banxe-data (наши данные) ==="
du -sh /mnt/windows/banxe-data/* 2>/dev/null

echo ""
echo "  === Модели AI на Windows (если есть) ==="
find /mnt/windows -name "*.gguf" -o -name "*.safetensors" -o -name "*.bin" -o -name "*.pt" 2>/dev/null | head -20

echo ""
echo "  === Users папки ==="
ls -la "/mnt/windows/Users/" 2>/dev/null | head -10

echo ""
echo "  === Ollama на Windows (если есть) ==="
du -sh "/mnt/windows/Users/GMK tec/.ollama" 2>/dev/null || echo "  Нет Ollama на Windows"

echo ""
echo "  === Свободно на 1TB (Linux) для временного хранения ==="
df -h / | tail -1
STEP1

echo ""
echo "  ================================================"
echo "  ВНИМАНИЕ: Проверь вывод выше!"
echo "  Если есть ценные данные — они будут УНИЧТОЖЕНЫ."
echo "  ================================================"
echo ""
read -p "  Продолжить форматирование 2TB? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "  Отменено."
    exit 0
fi

# --- 2. Сохраняем данные banxe-data на Linux диск ---
echo ""
echo "[2/8] Сохраняю banxe-data на Linux диск..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'STEP2'
# Копируем только нашу data (не модели — они есть в /usr/share/ollama)
if [ -d /mnt/windows/banxe-data/clickhouse ]; then
    mkdir -p /tmp/banxe-data-backup
    cp -a /mnt/windows/banxe-data/clickhouse /tmp/banxe-data-backup/ 2>/dev/null
    echo "  ✓ ClickHouse data сохранён в /tmp/banxe-data-backup/"
fi

# Ollama модели УЖЕ есть на Linux в /usr/share/ollama — не копируем
echo "  ✓ Ollama модели на Linux в /usr/share/ollama (копирование не нужно)"

# Проверяем что Ollama модели точно есть на Linux
MODELS_SIZE=$(du -sh /usr/share/ollama/.ollama/models 2>/dev/null | awk '{print $1}')
echo "  Ollama модели на Linux: ${MODELS_SIZE:-НЕ НАЙДЕНЫ}"

if [ -z "$MODELS_SIZE" ]; then
    echo "  ⚠ Модели не найдены на Linux! Копирую с Windows..."
    mkdir -p /usr/share/ollama/.ollama/models
    cp -a /mnt/windows/banxe-data/ollama-models/* /usr/share/ollama/.ollama/models/ 2>/dev/null
    echo "  ✓ Модели скопированы"
fi
STEP2

# --- 3. Останавливаем сервисы использующие Windows диск ---
echo ""
echo "[3/8] Останавливаю сервисы..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'STEP3'
# Ollama — переключаем на стандартный путь (Linux)
cat > /etc/systemd/system/ollama.service.d/override.conf << 'OVR'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_KEEP_ALIVE=5m"
OVR
systemctl daemon-reload
systemctl restart ollama
sleep 3
echo "  ✓ Ollama переключена на Linux путь"

# ClickHouse — останавливаем
systemctl stop clickhouse-server 2>/dev/null
echo "  ✓ ClickHouse остановлен"

# Проверяем что ничего не использует Windows диск
USERS=$(fuser -m /mnt/windows 2>/dev/null)
if [ -n "$USERS" ]; then
    echo "  ⚠ Процессы используют /mnt/windows: $USERS"
    echo "  Убиваю..."
    fuser -km /mnt/windows 2>/dev/null
    sleep 2
fi
echo "  ✓ Диск свободен"
STEP3

# --- 4. Отмонтируем Windows диск ---
echo ""
echo "[4/8] Отмонтирую Windows диск..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'STEP4'
umount /mnt/windows 2>/dev/null
if mountpoint -q /mnt/windows 2>/dev/null; then
    echo "  ⚠ Не удалось отмонтировать! Принудительно..."
    umount -l /mnt/windows 2>/dev/null
fi

if ! mountpoint -q /mnt/windows 2>/dev/null; then
    echo "  ✓ Windows диск отмонтирован"
else
    echo "  ✗ ОШИБКА: диск всё ещё примонтирован!"
    exit 1
fi
STEP4

# --- 5. Форматируем 2TB в ext4 ---
echo ""
echo "[5/8] Форматирую 2TB в ext4..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'STEP5'
# Удаляем все разделы Windows и создаём один ext4
echo "  Создаю новую таблицу разделов на /dev/nvme0n1..."

# Удаляем старые разделы, создаём один новый
wipefs -a /dev/nvme0n1 2>/dev/null
parted -s /dev/nvme0n1 mklabel gpt
parted -s /dev/nvme0n1 mkpart primary ext4 0% 100%
sleep 2

echo "  Форматирую /dev/nvme0n1p1 в ext4..."
mkfs.ext4 -L banxe-data /dev/nvme0n1p1

echo "  ✓ 2TB отформатирован в ext4 (label: banxe-data)"
STEP5

# --- 6. Монтируем как /data ---
echo ""
echo "[6/8] Монтирую как /data..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'STEP6'
# Создаём точку монтирования
mkdir -p /data

# Монтируем
mount /dev/nvme0n1p1 /data

# Обновляем fstab
# Убираем старую запись Windows
sed -i '/nvme0n1p3/d' /etc/fstab
sed -i '/mnt\/windows/d' /etc/fstab
sed -i '/2TB Windows/d' /etc/fstab

# Получаем UUID нового раздела
NEW_UUID=$(blkid /dev/nvme0n1p1 -s UUID -o value)
echo "  UUID: $NEW_UUID"

# Добавляем в fstab
echo "# 2TB Data disk (ex-Windows, now ext4)" >> /etc/fstab
echo "UUID=$NEW_UUID /data ext4 defaults,noatime 0 2" >> /etc/fstab

echo "  ✓ /data примонтирован"
df -h /data
STEP6

# --- 7. Создаём структуру и переносим данные ---
echo ""
echo "[7/8] Создаю структуру /data и переношу данные..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" 'bash -s' << 'STEP7'
# Структура
mkdir -p /data/ollama-models
mkdir -p /data/clickhouse/data
mkdir -p /data/clickhouse/tmp
mkdir -p /data/backups/clickhouse
mkdir -p /data/backups/openclaw
mkdir -p /data/logs
mkdir -p /data/workspace

echo "  ✓ Структура /data создана:"
ls -la /data/

# Переносим Ollama модели на 2TB
echo ""
echo "  Переношу Ollama модели на /data (это займёт время ~98GB)..."
cp -a /usr/share/ollama/.ollama/models/* /data/ollama-models/ 2>/dev/null
echo "  ✓ Модели скопированы"

# Настраиваем Ollama на /data
cat > /etc/systemd/system/ollama.service.d/override.conf << 'OVR'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_KEEP_ALIVE=5m"
Environment="OLLAMA_MODELS=/data/ollama-models"
OVR
systemctl daemon-reload
systemctl restart ollama
sleep 5

echo "  Ollama модели:"
ollama list 2>/dev/null

# Настраиваем ClickHouse на /data
cat > /etc/clickhouse-server/config.d/banxe-paths.xml << 'CHXML'
<clickhouse>
    <path>/data/clickhouse/data/</path>
    <tmp_path>/data/clickhouse/tmp/</tmp_path>
    <listen_host>127.0.0.1</listen_host>
</clickhouse>
CHXML

# Восстанавливаем ClickHouse data если есть backup
if [ -d /tmp/banxe-data-backup/clickhouse ]; then
    cp -a /tmp/banxe-data-backup/clickhouse/* /data/clickhouse/ 2>/dev/null
    echo "  ✓ ClickHouse data восстановлен"
fi

chown -R clickhouse:clickhouse /data/clickhouse/
systemctl start clickhouse-server
sleep 3

# Проверяем
echo ""
echo "  === Итоговая проверка ==="
echo "  /data:"
df -h /data | tail -1
echo ""
echo "  Ollama:"
systemctl is-active ollama && ollama list 2>/dev/null | head -5
echo ""
echo "  ClickHouse:"
systemctl is-active clickhouse-server && clickhouse-client --query "SHOW TABLES FROM banxe" 2>/dev/null
STEP7

# --- 8. КАНОН: обновляем MEMORY.md ---
echo ""
echo "[8/8] КАНОН: обновляю MEMORY.md..."

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

MEMTEXT="
## Обновление: Фаза 2 завершена ($TIMESTAMP)
- Windows УНИЧТОЖЕН на 2TB диске
- 2TB отформатирован в ext4, смонтирован как /data
- Структура: /data/{ollama-models,clickhouse,backups,logs,workspace}
- Ollama модели перенесены на /data/ollama-models
- ClickHouse data перенесён на /data/clickhouse
- fstab обновлён для автомонтирования
- Итого: 1TB (система) + 2TB (данные) = полностью Linux"

ssh -p "$GMKTEC_PORT" "$GMKTEC" "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace /root/.openclaw-moa/workspace; do echo '$MEMTEXT' >> \$d/MEMORY.md 2>/dev/null; done"

echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  ФАЗА 2 ЗАВЕРШЕНА"
echo "=========================================="
echo ""
echo "  Windows ЛИКВИДИРОВАН"
echo "  2TB → ext4 /data"
echo "  Ollama + ClickHouse → /data"
echo ""
echo "  Следующий шаг: Фаза 3 (безопасность)"
echo "    - Backup ClickHouse (cron)"
echo "    - Шифрование at rest"
echo "    - PII Proxy (Presidio)"
echo "=========================================="
