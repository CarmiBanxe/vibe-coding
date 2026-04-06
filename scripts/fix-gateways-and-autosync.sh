#!/bin/bash
###############################################################################
# fix-gateways-and-autosync.sh — Поднять gateway + установить автосинк
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-gateways-and-autosync.sh
#
# Что делает:
#   1. Диагностика: как gateway были запущены раньше
#   2. Поднимает оба gateway (18789 + 18793)
#   3. Клонирует репо на GMKtec
#   4. Ставит docs/MEMORY.md как source of truth
#   5. Устанавливает cron-автосинк (каждые 5 мин)
#   6. Проверяет что всё работает
###############################################################################

echo "=========================================="
echo "  FIX GATEWAYS + АВТОСИНК MEMORY.md"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

###########################################################################
# ЧАСТЬ 1: ДИАГНОСТИКА — как gateway запускались
###########################################################################
echo "[1/6] Диагностика gateway..."
echo ""

echo "  systemd сервисы (openclaw):"
systemctl list-units --all 2>/dev/null | grep -i openclaw || echo "    (нет systemd сервисов)"
echo ""
ls -la /etc/systemd/system/*openclaw* 2>/dev/null || echo "    (нет файлов в /etc/systemd/system/)"
echo ""

echo "  crontab (root):"
crontab -l 2>/dev/null | grep -i openclaw || echo "    (нет cron записей)"
echo ""

echo "  screen сессии:"
screen -ls 2>/dev/null || echo "    (screen не установлен или нет сессий)"
echo ""

echo "  tmux сессии:"
tmux ls 2>/dev/null || echo "    (tmux нет сессий)"
echo ""

echo "  Процессы openclaw (если есть):"
ps aux | grep -E "[o]penclaw" || echo "    (нет запущенных процессов openclaw)"
echo ""

echo "  Процессы на портах 18789/18793:"
ss -tlnp | grep -E "1878[0-9]|1879[0-9]" || echo "    (порты свободны)"
echo ""

echo "  Конфиг MoA бота:"
ls -la /root/.openclaw-moa/.openclaw/openclaw.json 2>/dev/null || echo "    НЕ НАЙДЕН"
echo ""

echo "  Конфиг mycarmibot:"
find /root -maxdepth 4 -name "openclaw.json" 2>/dev/null | head -5
echo ""

echo "  Node.js/npx доступны:"
which node && node --version
which npx && npx --version 2>/dev/null | head -1
echo ""

###########################################################################
# ЧАСТЬ 2: ПОДНИМАЕМ GATEWAY
###########################################################################
echo "=========================================="
echo "[2/6] Поднимаю gateway..."
echo ""

# Находим правильные директории
MOA_DIR=""
CARMI_DIR=""

for d in /root/.openclaw-moa /home/mmber/.openclaw-moa; do
    if [ -f "$d/.openclaw/openclaw.json" ]; then
        MOA_DIR="$d"
        break
    fi
done

for d in /root/.openclaw-mycarmibot /home/mmber/.openclaw-mycarmibot /root/.openclaw-carmibot; do
    if [ -d "$d" ]; then
        CARMI_DIR="$d"
        break
    fi
done

echo "  MoA директория: ${MOA_DIR:-НЕ НАЙДЕНА}"
echo "  Carmibot директория: ${CARMI_DIR:-НЕ НАЙДЕНА}"
echo ""

# Создаём systemd сервисы (правильные)
echo "  Создаю systemd сервис для @mycarmi_moa_bot..."
cat > /etc/systemd/system/openclaw-gateway-moa.service << 'SVC'
[Unit]
Description=OpenClaw Gateway — @mycarmi_moa_bot (port 18789)
After=network.target ollama.service

[Service]
Type=simple
WorkingDirectory=/root/.openclaw-moa
ExecStart=/usr/bin/npx openclaw gateway --port 18789
Restart=always
RestartSec=10
Environment=HOME=/root
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
SVC

# Проверяем нет ли бага двойного пути
sed -i 's|/.openclaw-moa/.openclaw-moa|/.openclaw-moa|g' /etc/systemd/system/openclaw-gateway-moa.service

echo "  Создаю systemd сервис для @mycarmibot..."
if [ -n "$CARMI_DIR" ]; then
    cat > /etc/systemd/system/openclaw-gateway-mycarmibot.service << SVC2
[Unit]
Description=OpenClaw Gateway — @mycarmibot (port 18793)
After=network.target ollama.service

[Service]
Type=simple
WorkingDirectory=$CARMI_DIR
ExecStart=/usr/bin/npx openclaw gateway --port 18793
Restart=always
RestartSec=10
Environment=HOME=/root
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
SVC2
    echo "  ✓ mycarmibot сервис создан (WorkingDirectory=$CARMI_DIR)"
else
    echo "  ⚠ Директория mycarmibot не найдена — пропускаю"
fi

# Reload и запуск
systemctl daemon-reload

echo ""
echo "  Запускаю @mycarmi_moa_bot (порт 18789)..."
systemctl enable openclaw-gateway-moa 2>/dev/null
systemctl start openclaw-gateway-moa 2>/dev/null
sleep 5

if systemctl is-active openclaw-gateway-moa &>/dev/null; then
    echo "  ✓ @mycarmi_moa_bot ACTIVE (systemd)"
else
    echo "  ⚠ systemd не сработал, пробую напрямую..."
    # Запускаем через nohup как fallback
    cd /root/.openclaw-moa
    nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
    sleep 5
    if ss -tlnp | grep -q 18789; then
        echo "  ✓ @mycarmi_moa_bot ACTIVE (nohup, PID: $!)"
    else
        echo "  ✗ @mycarmi_moa_bot НЕ ЗАПУСТИЛСЯ"
        echo "    Последние строки лога:"
        tail -10 /data/logs/gateway-moa.log 2>/dev/null
    fi
fi

if [ -n "$CARMI_DIR" ]; then
    echo ""
    echo "  Запускаю @mycarmibot (порт 18793)..."
    systemctl enable openclaw-gateway-mycarmibot 2>/dev/null
    systemctl start openclaw-gateway-mycarmibot 2>/dev/null
    sleep 5

    if systemctl is-active openclaw-gateway-mycarmibot &>/dev/null; then
        echo "  ✓ @mycarmibot ACTIVE (systemd)"
    else
        echo "  ⚠ systemd не сработал, пробую напрямую..."
        cd "$CARMI_DIR"
        nohup npx openclaw gateway --port 18793 > /data/logs/gateway-mycarmibot.log 2>&1 &
        sleep 5
        if ss -tlnp | grep -q 18793; then
            echo "  ✓ @mycarmibot ACTIVE (nohup, PID: $!)"
        else
            echo "  ✗ @mycarmibot НЕ ЗАПУСТИЛСЯ"
            echo "    Последние строки лога:"
            tail -10 /data/logs/gateway-mycarmibot.log 2>/dev/null
        fi
    fi
fi

###########################################################################
# ЧАСТЬ 3: КЛОНИРУЕМ РЕПО НА GMKTEC
###########################################################################
echo ""
echo "=========================================="
echo "[3/6] Настраиваю git репо на GMKtec..."

if [ -d "/data/vibe-coding/.git" ]; then
    cd /data/vibe-coding && git pull --ff-only 2>&1 | head -5
    echo "  ✓ Репо обновлён: /data/vibe-coding"
else
    cd /data && git clone https://github.com/CarmiBanxe/vibe-coding.git 2>&1 | tail -3
    echo "  ✓ Репо клонирован: /data/vibe-coding"
fi

###########################################################################
# ЧАСТЬ 4: СОЗДАЁМ WATCHER-СКРИПТ
###########################################################################
echo ""
echo "=========================================="
echo "[4/6] Создаю watcher для автосинка..."

cat > /data/vibe-coding/memory-autosync-watcher.sh << 'WATCHER'
#!/bin/bash
###############################################################################
# memory-autosync-watcher.sh — cron каждые 5 минут
# git pull → если docs/MEMORY.md изменился → копирует во все workspace ботов
###############################################################################

REPO_DIR="/data/vibe-coding"
MEMORY_SRC="$REPO_DIR/docs/MEMORY.md"
HASH_FILE="/data/logs/memory-last-hash.txt"
LOG_FILE="/data/logs/memory-sync.log"

mkdir -p /data/logs

# git pull (тихо)
cd "$REPO_DIR"
git pull --ff-only >> "$LOG_FILE" 2>&1

# Есть ли MEMORY.md?
if [ ! -f "$MEMORY_SRC" ]; then
    exit 0
fi

# Хэш
NEW_HASH=$(md5sum "$MEMORY_SRC" | awk '{print $1}')
OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null)

# Если не изменился — тихо выходим
if [ "$NEW_HASH" == "$OLD_HASH" ]; then
    exit 0
fi

# ИЗМЕНИЛСЯ — синхронизируем
echo "$(date '+%Y-%m-%d %H:%M'): MEMORY.md изменился, синхронизирую..." >> "$LOG_FILE"
echo "$NEW_HASH" > "$HASH_FILE"

# Копируем во все workspace
for DIR in \
    "/home/mmber/.openclaw/workspace-moa" \
    "/root/.openclaw-moa/workspace-moa" \
    "/root/.openclaw-moa/.openclaw/workspace" \
    "/root/.openclaw-moa/.openclaw/workspace-moa"; do
    [ -d "$DIR" ] && cp "$MEMORY_SRC" "$DIR/MEMORY.md" && echo "$(date '+%H:%M'):   → $DIR" >> "$LOG_FILE"
done

# mycarmibot
for DIR in /root/.openclaw-mycarmibot/workspace*; do
    [ -d "$DIR" ] && cp "$MEMORY_SRC" "$DIR/MEMORY.md" && echo "$(date '+%H:%M'):   → $DIR" >> "$LOG_FILE"
done

# CTIO
if [ -d "/home/ctio/.openclaw-ctio/workspace" ]; then
    cp "$MEMORY_SRC" /home/ctio/.openclaw-ctio/workspace/MEMORY.md
    chown ctio:ctio /home/ctio/.openclaw-ctio/workspace/MEMORY.md 2>/dev/null
    echo "$(date '+%H:%M'):   → CTIO" >> "$LOG_FILE"
fi

echo "$(date '+%H:%M'): ✓ Синхронизация завершена" >> "$LOG_FILE"
WATCHER

chmod +x /data/vibe-coding/memory-autosync-watcher.sh
echo "  ✓ Watcher создан"

###########################################################################
# ЧАСТЬ 5: СТАВИМ CRON
###########################################################################
echo ""
echo "=========================================="
echo "[5/6] Устанавливаю cron (каждые 5 минут)..."

# Удаляем старые записи
crontab -l 2>/dev/null | grep -v "memory-autosync" > /tmp/crontab-clean.txt
# Добавляем новую
echo "*/5 * * * * /bin/bash /data/vibe-coding/memory-autosync-watcher.sh" >> /tmp/crontab-clean.txt
crontab /tmp/crontab-clean.txt
rm /tmp/crontab-clean.txt

echo "  ✓ Cron установлен"
echo ""
echo "  Все cron-задачи:"
crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | while read line; do
    echo "    $line"
done

###########################################################################
# ЧАСТЬ 6: ПРОВЕРКА ВСЕГО
###########################################################################
echo ""
echo "=========================================="
echo "[6/6] Финальная проверка..."
echo ""

echo "  Порты:"
ss -tlnp | grep -E "1878[0-9]|1879[0-9]|11434|8088|8089|5678|9000" | while read line; do
    echo "    $line"
done

echo ""
echo "  Gateway процессы:"
ps aux | grep -E "[o]penclaw" | awk '{print "    PID "$2": "$11" "$12" "$13}'

echo ""
echo "  MEMORY.md во всех workspace:"
for f in \
    /home/mmber/.openclaw/workspace-moa/MEMORY.md \
    /root/.openclaw-moa/workspace-moa/MEMORY.md \
    /root/.openclaw-moa/.openclaw/workspace/MEMORY.md; do
    if [ -f "$f" ]; then
        LINES=$(wc -l < "$f")
        echo "    ✓ $f ($LINES строк)"
    else
        echo "    ✗ $f (НЕТ)"
    fi
done

echo ""
echo "  Репо /data/vibe-coding:"
ls -la /data/vibe-coding/docs/MEMORY.md 2>/dev/null && echo "    ✓ docs/MEMORY.md есть" || echo "    ✗ docs/MEMORY.md НЕТ (нужен git push с Perplexity)"

echo ""
echo "  Тест Ollama (бот жив?):"
curl -s --max-time 5 http://localhost:11434/api/tags | python3 -c "import sys,json; d=json.load(sys.stdin); print('    ✓ Ollama: ' + str(len(d.get('models',[]))) + ' моделей')" 2>/dev/null || echo "    ✗ Ollama не отвечает"

REMOTE_END

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "Если gateway запустились — проверь бота в Telegram:"
echo '  "Прочитай MEMORY.md и скажи какие у тебя инструменты для поиска"'
echo ""
echo "АВТОСИНК теперь работает:"
echo "  Perplexity пушит docs/MEMORY.md → GitHub → GMKtec тянет каждые 5 мин"
echo "  Тебе больше НЕ нужно запускать скрипты вручную для обновления памяти"
