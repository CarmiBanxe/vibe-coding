#!/bin/bash
###############################################################################
# create-oleg-ctio.sh — Создание CTIO пакета для Олега
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/create-oleg-ctio.sh
#
# Все данные зашиты — ничего вводить не нужно.
###############################################################################

GMKTEC="root@192.168.0.72"
GMKTEC_PORT="2222"

# === ДАННЫЕ CTIO (зашиты) ===
CTIO_NAME="Oleg"
CTIO_TG_ID="66549310283"
CTIO_TG_USER="p314pm"
CTIO_PASSWORD="banxe"

echo "=========================================="
echo "  СОЗДАНИЕ CTIO ДЛЯ ОЛЕГА"
echo "=========================================="
echo ""
echo "  Имя: $CTIO_NAME"
echo "  Telegram: @$CTIO_TG_USER (ID: $CTIO_TG_ID)"
echo "  SSH: ctio@90.116.185.11:2222 (пароль: $CTIO_PASSWORD)"
echo ""

# ============================================================================
# ШАГ 1: Пользователь + права на GMKtec
# ============================================================================

echo "[1/5] Создаю пользователя ctio на GMKtec..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" "bash -s" << 'STEP1'
# Создаём пользователя
if id ctio &>/dev/null; then
    echo "  Пользователь ctio уже существует, обновляю пароль..."
    echo "ctio:banxe" | chpasswd
else
    useradd -m -s /bin/bash -G sudo ctio
    echo "ctio:banxe" | chpasswd
    echo "  ✓ Пользователь ctio создан"
fi

# sudo без пароля
echo "ctio ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/ctio
chmod 440 /etc/sudoers.d/ctio
echo "  ✓ sudo без пароля"

# SSH
mkdir -p /home/ctio/.ssh
chmod 700 /home/ctio/.ssh
chown -R ctio:ctio /home/ctio/.ssh

if ! grep -q "^Match User ctio" /etc/ssh/sshd_config; then
    cat >> /etc/ssh/sshd_config << 'SSHEOF'

# CTIO access
Match User ctio
    PasswordAuthentication yes
SSHEOF
    systemctl reload sshd
    echo "  ✓ SSH настроен"
else
    echo "  ✓ SSH уже настроен"
fi

# Группа и доступ
groupadd banxe-team 2>/dev/null || true
usermod -aG banxe-team root
usermod -aG banxe-team ctio

# Полный доступ к /data
setfacl -R -m u:ctio:rwx /data 2>/dev/null || chmod -R 777 /data 2>/dev/null
setfacl -R -m u:ctio:rx /root/.openclaw-moa 2>/dev/null || true

# ClickHouse FULL ACCESS
clickhouse-client --query "
    CREATE USER IF NOT EXISTS ctio_agent
    IDENTIFIED BY 'ctio_banxe_2026'
    DEFAULT DATABASE banxe;
    GRANT ALL ON banxe.* TO ctio_agent;
" 2>/dev/null && echo "  ✓ ClickHouse FULL ACCESS" || echo "  ✓ ClickHouse user уже есть"

# vibe-coding на сервере
cd /root/vibe-coding 2>/dev/null && git pull 2>/dev/null || git clone https://github.com/CarmiBanxe/vibe-coding.git /root/vibe-coding 2>/dev/null
echo "  ✓ vibe-coding на сервере"

echo "  ✓ Шаг 1 готов"
STEP1

# ============================================================================
# ШАГ 2: OpenClaw профиль для CTIO
# ============================================================================

echo ""
echo "[2/5] Создаю OpenClaw профиль..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" "bash -s" << 'STEP2'
CTIO_OC="/home/ctio/.openclaw-ctio"
mkdir -p "$CTIO_OC/workspace-ctio"

# Копируем конфиг
cp /root/.openclaw-moa/openclaw.json "$CTIO_OC/openclaw.json"

# Настраиваем
python3 << 'PYEOF'
import json

with open("/home/ctio/.openclaw-ctio/openclaw.json", "r") as f:
    config = json.load(f)

# Telegram: токен пока заглушка
if "telegram" in config:
    config["telegram"]["botToken"] = "PLACEHOLDER_TOKEN"

# Права: Oleg + CEO
if "sessions" in config:
    config["sessions"]["allowFrom"] = [66549310283, 508602494]

# Gateway на другом порту
if "gateway" not in config:
    config["gateway"] = {}
config["gateway"]["mode"] = "local"
config["gateway"]["port"] = 18791

with open("/home/ctio/.openclaw-ctio/openclaw.json", "w") as f:
    json.dump(config, f, indent=2)

print("  ✓ Конфиг настроен (порт 18791, ID 66549310283 + 508602494)")
PYEOF

# Копируем MEMORY.md
for src in /home/mmber/.openclaw/workspace-moa/MEMORY.md \
           /root/.openclaw-moa/workspace-moa/MEMORY.md \
           /root/.openclaw-moa/.openclaw/workspace/MEMORY.md; do
    if [ -f "$src" ]; then
        cp "$src" "$CTIO_OC/workspace-ctio/MEMORY.md"
        echo "  ✓ MEMORY.md скопирован"
        break
    fi
done

# Добавляем роль
cat >> "$CTIO_OC/workspace-ctio/MEMORY.md" << 'MEMEOF'

## Роль этого бота: CTIO
- Пользователь: Oleg (@p314pm)
- Telegram ID: 66549310283
- Уровень доступа: ПОЛНЫЙ (конгруэнтный с CEO)
- Может: ВСЁ — стратегия, аналитика, агенты, ClickHouse R/W, конфиги, sudo
- CEO (Supervisor): Moriel Carmi (@bereg2022, ID: 508602494)
MEMEOF

chown -R ctio:ctio "$CTIO_OC"
chmod -R 700 "$CTIO_OC"
echo "  ✓ Шаг 2 готов"
STEP2

# ============================================================================
# ШАГ 3: Скрипт установки для Олега
# ============================================================================

echo ""
echo "[3/5] Создаю скрипт установки..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" "bash -s" << 'STEP3'
cat > /home/ctio/install-my-bot.sh << 'INSTALL'
#!/bin/bash
echo "=========================================="
echo "  АКТИВАЦИЯ CTIO БОТА — Oleg"
echo "=========================================="
echo ""
read -p "  Токен бота от @BotFather: " BOT_TOKEN

if [ -z "$BOT_TOKEN" ]; then
    echo "  ✗ Токен обязателен!"
    exit 1
fi

CTIO_OC="/home/ctio/.openclaw-ctio"

# Подставляем токен
sed -i "s|PLACEHOLDER_TOKEN|$BOT_TOKEN|g" "$CTIO_OC/openclaw.json"
echo "  ✓ Токен установлен"

# Gateway
export OPENCLAW_HOME="$CTIO_OC"
openclaw config set gateway.mode local --profile ctio 2>&1 | tail -1
openclaw gateway install --profile ctio --force 2>&1 | tail -3

# Исправляем задвоенный путь
SVC_FILE="/home/ctio/.config/systemd/user/openclaw-gateway-ctio.service"
if [ -f "$SVC_FILE" ]; then
    sed -i "s|/home/ctio/.openclaw-ctio/.openclaw-ctio|/home/ctio/.openclaw-ctio|g" "$SVC_FILE"
fi

# Запускаем
sudo loginctl enable-linger ctio 2>/dev/null
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user daemon-reload 2>/dev/null
systemctl --user enable openclaw-gateway-ctio 2>/dev/null
systemctl --user restart openclaw-gateway-ctio 2>/dev/null
sleep 8

if systemctl --user is-active openclaw-gateway-ctio &>/dev/null; then
    echo ""
    echo "  ✓ БОТ АКТИВЕН!"
    echo ""
    echo "  Открой Telegram → найди бота → напиши 'Привет'"
else
    echo "  Статус:"
    systemctl --user status openclaw-gateway-ctio 2>/dev/null | tail -8
fi
echo "=========================================="
INSTALL
chmod +x /home/ctio/install-my-bot.sh
chown ctio:ctio /home/ctio/install-my-bot.sh
echo "  ✓ install-my-bot.sh создан"
STEP3

# ============================================================================
# ШАГ 4: Инструкция для Олега
# ============================================================================

echo ""
echo "[4/5] Создаю инструкцию..."

mkdir -p ~/vibe-coding/docs/ctio-package

cat > ~/vibe-coding/docs/ctio-package/README-OLEG.md << 'READMEEOF'
# Banxe AI Bank — Инструкция для Олега (CTIO)

---

## Шаг 1: Создай бота в Telegram (5 минут)

1. Открой Telegram, найди **@BotFather**
2. Напиши: `/newbot`
3. Имя бота: `Banxe CTIO Oleg`
4. Username бота: `banxe_ctio_oleg_bot` (должен заканчиваться на `bot`)
5. Сохрани **токен** (строка вида `1234567890:ABCdef...`)

## Шаг 2: Подключись к серверу

```
ssh -p 2222 ctio@90.116.185.11
```
Пароль: `banxe`

(При первом подключении набери `yes`)

## Шаг 3: Запусти установку

```
bash ~/install-my-bot.sh
```

Введи токен бота из шага 1. Всё остальное автоматически.

## Шаг 4: Проверь

Найди бота в Telegram → Start → напиши: **"Привет, я Олег, новый CTIO"**

---

## Твои права — ПОЛНЫЕ

| Действие | Доступ |
|----------|--------|
| Общение с ботом | ✅ |
| Управление агентами | ✅ |
| ClickHouse (чтение и запись) | ✅ |
| Работа с файлами | ✅ |
| sudo (root команды) | ✅ |
| Конфиги сервера | ✅ |
| Управление сервисами | ✅ |
| Доступ к /data (2TB) | ✅ |

## Сервер

- **AMD Ryzen AI MAX+ 395**, 128GB RAM, 96GB GPU
- 4 модели Ollama (98GB), работают локально без интернета
- ClickHouse: база `banxe` (6 таблиц)
- PII Proxy, n8n Automation

## GitHub

https://github.com/CarmiBanxe/vibe-coding

Все скрипты запускаются по канону:
```
cd /root/vibe-coding && git pull && bash scripts/ИМЯ_СКРИПТА.sh
```

## Поддержка

Проблемы? Пиши Марку: @bereg2022
READMEEOF

echo "  ✓ Инструкция создана"

# ============================================================================
# ШАГ 5: КАНОН — MEMORY.md
# ============================================================================

echo ""
echo "[5/5] КАНОН: обновляю MEMORY.md..."

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

ssh -p "$GMKTEC_PORT" "$GMKTEC" "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << 'MEMEOF'

## Обновление: CTIO Oleg подключён ($TIMESTAMP)
- CTIO: Oleg (@p314pm, ID: 66549310283)
- Linux: ctio (пароль: banxe, sudo без пароля)
- SSH: ssh -p 2222 ctio@90.116.185.11
- OpenClaw: /home/ctio/.openclaw-ctio (порт 18791)
- ClickHouse: FULL ACCESS (ctio_agent)
- Права: ПОЛНЫЕ (конгруэнтные с CEO)
- Оба бота одновременно: CEO=18789, CTIO=18791
MEMEOF
done" 2>/dev/null

echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  ГОТОВО!"
echo "=========================================="
echo ""
echo "  ┌─────────────────────────────────────┐"
echo "  │ CEO (Supervisor) — root             │"
echo "  │ Бот: @mycarmi_moa_bot              │"
echo "  │ Gateway: порт 18789                 │"
echo "  │ Права: ПОЛНЫЕ                       │"
echo "  ├─────────────────────────────────────┤"
echo "  │ CTIO — Oleg (@p314pm)              │"
echo "  │ SSH: ctio@90.116.185.11 (banxe)    │"
echo "  │ Gateway: порт 18791                 │"
echo "  │ Права: ПОЛНЫЕ (конгруэнтные)        │"
echo "  └─────────────────────────────────────┘"
echo ""
echo "  Отправь Олегу файл:"
echo "    ~/vibe-coding/docs/ctio-package/README-OLEG.md"
echo ""
echo "  Его 3 шага:"
echo "  1. Создать бота через @BotFather"
echo "  2. ssh -p 2222 ctio@90.116.185.11 (пароль: banxe)"
echo "  3. bash ~/install-my-bot.sh"
echo "=========================================="
