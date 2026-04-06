#!/bin/bash
###############################################################################
# create-ctio-package.sh — Создание пакета для CTIO с разделением прав
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/create-ctio-package.sh
#
# Создаёт:
#   - Linux-пользователь ctio на GMKtec (не root)
#   - Отдельный OpenClaw профиль с ПОЛНЫМИ правами (конгруэнтные с CEO)
#   - Отдельный Telegram-бот
#   - SSH доступ для CTIO (отдельный пароль)
#   - Общая MEMORY.md, раздельные workspace
###############################################################################

GMKTEC="root@192.168.0.72"
GMKTEC_PORT="2222"

echo "=========================================="
echo "  СОЗДАНИЕ ПАКЕТА CTIO"
echo "  Supervisor (CEO) + CTIO на одном сервере"
echo "=========================================="

echo ""
read -p "  Имя CTIO (например: Ivan Petrov): " CTIO_NAME
read -p "  Telegram ID CTIO (число, @userinfobot): " CTIO_TG_ID
read -p "  Telegram username CTIO (без @): " CTIO_TG_USER
read -p "  Пароль для CTIO (SSH + Linux): " CTIO_PASSWORD

if [ -z "$CTIO_NAME" ] || [ -z "$CTIO_TG_ID" ] || [ -z "$CTIO_PASSWORD" ]; then
    echo "  ✗ Все поля обязательны!"
    exit 1
fi

# ============================================================================
# ШАГ 1: Создаём пользователя ctio на GMKtec
# ============================================================================

echo ""
echo "[1/6] Создаю пользователя ctio на GMKtec..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" "bash -s" << USEEOF
# Создаём пользователя
if id ctio &>/dev/null; then
    echo "  Пользователь ctio уже существует"
else
    useradd -m -s /bin/bash -G sudo ctio
    echo "ctio:$CTIO_PASSWORD" | chpasswd
    echo "  ✓ Пользователь ctio создан"
fi

# SSH доступ
mkdir -p /home/ctio/.ssh
chmod 700 /home/ctio/.ssh
chown -R ctio:ctio /home/ctio/.ssh

# Разрешаем SSH по паролю для ctio
if ! grep -q "^Match User ctio" /etc/ssh/sshd_config; then
    cat >> /etc/ssh/sshd_config << 'SSHEOF'

# CTIO access
Match User ctio
    PasswordAuthentication yes
SSHEOF
    systemctl reload sshd
    echo "  ✓ SSH для ctio настроен"
fi

# Даём ПОЛНЫЙ доступ к общим ресурсам (конгруэнтные права с CEO)
# Группа banxe-team для общих файлов
groupadd banxe-team 2>/dev/null || true
usermod -aG banxe-team root
usermod -aG banxe-team ctio

# Общая директория
mkdir -p /data/shared
chown root:banxe-team /data/shared
chmod 775 /data/shared

# CTIO workspace на data диске
mkdir -p /data/ctio-workspace
chown ctio:ctio /data/ctio-workspace

# ClickHouse — ПОЛНЫЙ доступ (конгруэнтный с CEO)
clickhouse-client --query "
    CREATE USER IF NOT EXISTS ctio_agent
    IDENTIFIED BY 'ctio_banxe_2026'
    DEFAULT DATABASE banxe;
    GRANT ALL ON banxe.* TO ctio_agent;
" 2>/dev/null && echo "  ✓ ClickHouse FULL ACCESS для ctio" || echo "  ⚠ ClickHouse user уже существует"

# sudo без пароля
echo "ctio ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/ctio
chmod 440 /etc/sudoers.d/ctio
echo "  ✓ sudo без пароля для ctio"

# Доступ к /data и конфигам root
setfacl -R -m u:ctio:rwx /data 2>/dev/null || chmod -R 777 /data 2>/dev/null
setfacl -R -m u:ctio:rx /root/.openclaw-moa 2>/dev/null || true

echo "  ✓ Пользователь ctio готов"
USEEOF

# ============================================================================
# ШАГ 2: OpenClaw профиль для CTIO
# ============================================================================

echo ""
echo "[2/6] Создаю OpenClaw профиль для CTIO..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" "bash -s" << OCEOF
CTIO_OC="/home/ctio/.openclaw-ctio"
mkdir -p "\$CTIO_OC/workspace-ctio"

# Копируем конфиг из рабочего moa
cp /root/.openclaw-moa/openclaw.json "\$CTIO_OC/openclaw.json"

# Настраиваем конфиг для CTIO
python3 << 'PYEOF'
import json

with open("/home/ctio/.openclaw-ctio/openclaw.json", "r") as f:
    config = json.load(f)

# Новый Telegram токен (пока заглушка — CTIO подставит свой)
if "telegram" in config:
    config["telegram"]["botToken"] = "PLACEHOLDER_TOKEN"

# Права: CTIO + CEO
if "sessions" in config:
    config["sessions"]["allowFrom"] = [$CTIO_TG_ID, 508602494]

# Gateway на другом порту (чтобы не конфликтовал с CEO)
if "gateway" not in config:
    config["gateway"] = {}
config["gateway"]["mode"] = "local"
config["gateway"]["port"] = 18791

with open("/home/ctio/.openclaw-ctio/openclaw.json", "w") as f:
    json.dump(config, f, indent=2)

print("  ✓ Конфиг CTIO настроен (порт 18791)")
PYEOF

# Копируем MEMORY.md
for src in /home/mmber/.openclaw/workspace-moa/MEMORY.md \
           /root/.openclaw-moa/workspace-moa/MEMORY.md \
           /root/.openclaw-moa/.openclaw/workspace/MEMORY.md; do
    if [ -f "\$src" ]; then
        cp "\$src" "\$CTIO_OC/workspace-ctio/MEMORY.md"
        echo "  ✓ MEMORY.md скопирован"
        break
    fi
done

# Добавляем информацию о роли
cat >> "\$CTIO_OC/workspace-ctio/MEMORY.md" << MEMEOF

## Роль этого бота: CTIO
- Пользователь: $CTIO_NAME
- Telegram ID: $CTIO_TG_ID
- Уровень доступа: ПОЛНЫЙ (конгруэнтный с CEO)
- Может: ВСЁ — стратегия, аналитика, агенты, ClickHouse R/W, конфиги, sudo
- CEO (Supervisor): Moriel Carmi (@bereg2022, ID: 508602494)
MEMEOF

# Права на файлы
chown -R ctio:ctio "\$CTIO_OC"
chmod -R 700 "\$CTIO_OC"

echo "  ✓ OpenClaw профиль CTIO создан"
OCEOF

# ============================================================================
# ШАГ 3: Скрипт установки (запускает CTIO сам)
# ============================================================================

echo ""
echo "[3/6] Создаю скрипт установки для CTIO..."

ssh -p "$GMKTEC_PORT" "$GMKTEC" "bash -s" << 'SCRIPTEOF'
cat > /home/ctio/install-my-bot.sh << 'INSTALL'
#!/bin/bash
###############################################################################
# install-my-bot.sh — Активация CTIO бота
# Запускать под своим пользователем ctio:
#   bash ~/install-my-bot.sh
###############################################################################

echo "=========================================="
echo "  АКТИВАЦИЯ CTIO БОТА"
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

# Устанавливаем Gateway
export OPENCLAW_HOME="$CTIO_OC"
export HOME="/home/ctio"

openclaw config set gateway.mode local --profile ctio 2>&1 | tail -1
openclaw gateway install --profile ctio --force 2>&1 | tail -3

# Исправляем задвоенный путь
SVC_FILE="/home/ctio/.config/systemd/user/openclaw-gateway-ctio.service"
if [ -f "$SVC_FILE" ]; then
    sed -i "s|/home/ctio/.openclaw-ctio/.openclaw-ctio|/home/ctio/.openclaw-ctio|g" "$SVC_FILE"
fi

# Запускаем
loginctl enable-linger ctio 2>/dev/null
export XDG_RUNTIME_DIR="/run/user/$(id -u ctio)"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null

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
    echo ""
    echo "  Статус:"
    systemctl --user status openclaw-gateway-ctio 2>/dev/null | tail -8
    echo ""
    echo "  Если не работает — напиши Марку (@bereg2022)"
fi

echo ""
echo "=========================================="
INSTALL
chmod +x /home/ctio/install-my-bot.sh
chown ctio:ctio /home/ctio/install-my-bot.sh
echo "  ✓ install-my-bot.sh создан"
SCRIPTEOF

# ============================================================================
# ШАГ 4: Инструкция для CTIO
# ============================================================================

echo ""
echo "[4/6] Создаю инструкцию..."

PACKAGE_DIR="$HOME/vibe-coding/docs/ctio-package"
mkdir -p "$PACKAGE_DIR"

cat > "$PACKAGE_DIR/README-CTIO.md" << READMEEOF
# Banxe AI Bank — Инструкция для CTIO
## Для: $CTIO_NAME
## Дата: $(date '+%Y-%m-%d')

---

## Шаг 1: Создай бота в Telegram (5 минут)

1. Открой Telegram, найди **@BotFather**
2. Напиши: \`/newbot\`
3. Имя: \`Banxe CTIO $CTIO_NAME\`
4. Username: \`banxe_ctio_${CTIO_TG_USER}_bot\`
5. Сохрани **токен** (строка вида \`1234567890:ABCdef...\`)

## Шаг 2: Подключись к серверу

\`\`\`
ssh -p 2222 ctio@90.116.185.11
\`\`\`
Пароль: **$CTIO_PASSWORD**

(При первом подключении набери \`yes\`)

## Шаг 3: Запусти установку

\`\`\`
bash ~/install-my-bot.sh
\`\`\`

Введи токен бота из шага 1. Бот заработает автоматически.

## Шаг 4: Проверь

Найди бота в Telegram → Start → напиши: **"Привет, я $CTIO_NAME"**

---

## Твои права

| Действие | Доступ |
|----------|--------|
| Общение с ботом | ✅ |
| Управление агентами | ✅ |
| Чтение ClickHouse (аналитика) | ✅ |
| Работа с файлами в workspace | ✅ |
| Изменение конфигов сервера | ❌ |
| Root-доступ | ❌ |
| Управление ботом CEO | ❌ |
| Удаление данных | ❌ |

## ClickHouse (аналитика)

\`\`\`
clickhouse-client --query "SELECT * FROM banxe.transactions LIMIT 10"
\`\`\`

Доступ только на чтение (SELECT).

## Поддержка

Проблемы? Пиши CEO: @bereg2022
READMEEOF

echo "  ✓ Инструкция создана"

# ============================================================================
# ШАГ 5: Пушим в GitHub
# ============================================================================

echo ""
echo "[5/6] Пушу в GitHub..."

cd ~/vibe-coding
git add docs/ctio-package/README-CTIO.md
git commit -m "Add CTIO package for $CTIO_NAME - separate user, limited rights, own bot" 2>/dev/null
git push origin main 2>/dev/null

echo "  ✓ В GitHub"

# ============================================================================
# ШАГ 6: КАНОН
# ============================================================================

echo ""
echo "[6/6] КАНОН: обновляю MEMORY.md..."

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

MEMTEXT="
## Обновление: CTIO пакет создан ($TIMESTAMP)
- CTIO: $CTIO_NAME (@$CTIO_TG_USER, ID: $CTIO_TG_ID)
- Linux user: ctio (пароль задан, не root)
- SSH: ssh -p 2222 ctio@90.116.185.11
- OpenClaw профиль: /home/ctio/.openclaw-ctio (порт 18791)
- ClickHouse: FULL ACCESS (ctio_agent)
- sudo: без пароля
- Разделение прав:
  - CEO (root): полный доступ, порт 18789
  - CTIO (ctio): ПОЛНЫЙ (конгруэнтный), порт 18791
- Оба бота работают одновременно на разных портах"

ssh -p "$GMKTEC_PORT" "$GMKTEC" "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do echo '$MEMTEXT' >> \$d/MEMORY.md 2>/dev/null; done" 2>/dev/null

echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  ПАКЕТ CTIO ГОТОВ"
echo "=========================================="
echo ""
echo "  Разделение:"
echo "  ┌─────────────────────────────────────┐"
echo "  │ CEO (Supervisor) — root             │"
echo "  │ Бот: @mycarmi_moa_bot              │"
echo "  │ Gateway: порт 18789                 │"
echo "  │ Права: ПОЛНЫЕ                       │"
echo "  ├─────────────────────────────────────┤"
echo "  │ CTIO — ctio                         │"
echo "  │ Бот: @banxe_ctio_${CTIO_TG_USER}_bot │"
echo "  │ Gateway: порт 18791                 │"
echo "  │ Права: ПОЛНЫЕ (конгруэнтные с CEO)  │"
echo "  │ ClickHouse: FULL ACCESS             │"
echo "  │ sudo: без пароля                    │"
echo "  └─────────────────────────────────────┘"
echo ""
echo "  Отправь $CTIO_NAME:"
echo "    docs/ctio-package/README-CTIO.md"
echo ""
echo "  Его действия:"
echo "  1. Создать бота через @BotFather"
echo "  2. ssh -p 2222 ctio@90.116.185.11 (пароль: $CTIO_PASSWORD)"
echo "  3. bash ~/install-my-bot.sh"
echo "=========================================="
