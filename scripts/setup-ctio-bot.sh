#!/bin/bash
###############################################################################
# setup-ctio-bot.sh — Banxe AI Bank
# Задача #4: настроить бот CTIO (Олег) на порту 18791
#
# Использование:
#   bash scripts/setup-ctio-bot.sh <TELEGRAM_BOT_TOKEN>
#
# Где взять токен:
#   1. Открой Telegram, напиши @BotFather
#   2. Отправь: /newbot
#   3. Название: Banxe CTIO Bot (или любое)
#   4. Username: banxe_ctio_bot (или любое, должно заканчиваться на _bot)
#   5. @BotFather пришлёт токен вида: 123456789:ABCdefGHI...
#   6. Запусти: bash scripts/setup-ctio-bot.sh 123456789:ABCdefGHI...
#
# Что делает:
#   - Записывает новый токен в конфиг CTIO бота
#   - Добавляет Telegram ID Олега (66549310283) в allowFrom
#   - Фиксирует streaming: false (канон)
#   - Создаёт systemd сервис openclaw-gateway-ctio.service
#   - Запускает и верифицирует
###############################################################################

set -euo pipefail

BOT_TOKEN="${1:-}"
CTIO_PROFILE="/home/ctio/.openclaw-ctio"
CTIO_CONFIG="$CTIO_PROFILE/openclaw.json"
CTIO_TG_ID=66549310283
CEO_TG_ID=508602494
CTIO_PORT=18791
LOG="/data/logs/setup-ctio-bot.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p /data/logs
exec > >(tee -a "$LOG") 2>&1

echo ""
echo "============================================================"
echo " setup-ctio-bot.sh — $TIMESTAMP"
echo "============================================================"

###############################################################################
# Проверка токена
###############################################################################
if [ -z "$BOT_TOKEN" ]; then
    echo ""
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║  НУЖЕН TELEGRAM BOT TOKEN от @BotFather               ║"
    echo "  ╠════════════════════════════════════════════════════════╣"
    echo "  ║                                                        ║"
    echo "  ║  1. Открой Telegram → @BotFather                      ║"
    echo "  ║  2. Напиши: /newbot                                    ║"
    echo "  ║  3. Название: Banxe CTIO                               ║"
    echo "  ║  4. Username: banxe_ctio_bot (или похожее)             ║"
    echo "  ║  5. Скопируй полученный токен                          ║"
    echo "  ║                                                        ║"
    echo "  ║  Затем запусти снова:                                  ║"
    echo "  ║  bash scripts/setup-ctio-bot.sh <TOKEN>                ║"
    echo "  ╚════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Пока готовим всё остальное (конфиг, сервис)..."
    echo ""
fi

###############################################################################
# ДИАГНОСТИКА
###############################################################################
echo "[ ДИАГНОСТИКА ]"

python3 - <<DIAG
import json

try:
    c = json.load(open("$CTIO_CONFIG"))
    tg = c.get('channels', {}).get('telegram', {})
    gw = c.get('gateway', {})

    token = tg.get('botToken', 'ОТСУТСТВУЕТ')
    token_display = f"{token[:10]}...{token[-5:]}" if len(token) > 20 else token

    # Проверяем конфликт: тот же bot_id что у moa?
    moa_bot_id = "8793039199"
    conflict = token.startswith(moa_bot_id)

    allow = tg.get('allowFrom', [])
    has_oleg = $CTIO_TG_ID in allow
    has_ceo  = $CEO_TG_ID in allow

    print(f"  Токен:      {token_display}")
    print(f"  ⚠ КОНФЛИКТ с moa-ботом!" if conflict else "  ✓ Токен уникален")
    print(f"  allowFrom:  {allow}")
    print(f"  {'✓' if has_ceo else '✗'} CEO ({$CEO_TG_ID}) в allowFrom")
    print(f"  {'✓' if has_oleg else '✗'} Олег ({$CTIO_TG_ID}) в allowFrom")
    print(f"  streaming:  {tg.get('streaming', 'ОТСУТСТВУЕТ')}  {'✓' if tg.get('streaming') == False else '⚠ нужно false'}")
    print(f"  Порт:       {gw.get('port', '?')}")
except Exception as e:
    print(f"  Ошибка чтения конфига: {e}")
DIAG

echo ""
echo "  Systemd сервис openclaw-gateway-ctio:"
systemctl is-active openclaw-gateway-ctio 2>/dev/null && echo "  ✓ ACTIVE" \
    || systemctl is-enabled openclaw-gateway-ctio 2>/dev/null && echo "  ~ enabled но не active" \
    || echo "  ✗ не существует"

###############################################################################
# ПОЧИНКА
###############################################################################
echo ""
echo "[ ПОЧИНКА ]"

# Бэкап конфига
cp "$CTIO_CONFIG" "/data/backups/openclaw-ctio-backup-$(date +%Y%m%d-%H%M%S).json" 2>/dev/null || true

# ── 1. Обновляем openclaw.json ────────────────────────────────────────────
python3 - <<PATCH
import json

CONFIG = "$CTIO_CONFIG"
BOT_TOKEN = """$BOT_TOKEN"""

with open(CONFIG) as f:
    c = json.load(f)

changes = []
tg = c.setdefault('channels', {}).setdefault('telegram', {})

# Обновляем токен если передан
if BOT_TOKEN.strip():
    old_token = tg.get('botToken', '')
    if old_token != BOT_TOKEN.strip():
        tg['botToken'] = BOT_TOKEN.strip()
        changes.append(f'botToken: обновлён на новый')
    else:
        print('  ~ botToken без изменений')

# Добавляем Олега в allowFrom
allow = tg.get('allowFrom', [])
if $CTIO_TG_ID not in allow:
    allow.append($CTIO_TG_ID)
    tg['allowFrom'] = allow
    changes.append(f'allowFrom: добавлен Олег ({$CTIO_TG_ID})')
else:
    print('  ~ Олег уже в allowFrom')

# CEO должен быть (оставляем)
if $CEO_TG_ID not in allow:
    allow.append($CEO_TG_ID)
    tg['allowFrom'] = allow
    changes.append(f'allowFrom: добавлен CEO ({$CEO_TG_ID})')

# streaming: false (канон)
if tg.get('streaming') is not False:
    tg['streaming'] = False
    changes.append('streaming: false (канон)')
else:
    print('  ~ streaming уже false')

# configWrites: false (security)
if tg.get('configWrites') is not False:
    tg['configWrites'] = False
    changes.append('configWrites: false')

# workspace → CTIO-специфичный
agent_defaults = c.setdefault('agents', {}).setdefault('defaults', {})
if agent_defaults.get('workspace') != '/home/ctio/.openclaw-ctio/workspace':
    agent_defaults['workspace'] = '/home/ctio/.openclaw-ctio/workspace'
    changes.append('workspace: /home/ctio/.openclaw-ctio/workspace')

if changes:
    with open(CONFIG, 'w') as f:
        json.dump(c, f, indent=2, ensure_ascii=False)
    print('\n  Применено:')
    for ch in changes:
        print(f'  ✓ {ch}')
else:
    print('  ~ конфиг уже актуален')
PATCH

# Права на конфиг
chmod 600 "$CTIO_CONFIG"
chown ctio:ctio "$CTIO_CONFIG" 2>/dev/null || true
echo "  ✓ chmod 600 + chown ctio:ctio на openclaw.json"

# Создаём workspace если нет
mkdir -p "$CTIO_PROFILE/workspace"
chown -R ctio:ctio "$CTIO_PROFILE/workspace" 2>/dev/null || true

# ── 2. Systemd сервис ─────────────────────────────────────────────────────
echo ""
echo "  Создаю systemd сервис openclaw-gateway-ctio.service..."

cat > /etc/systemd/system/openclaw-gateway-ctio.service << 'SERVICE'
[Unit]
Description=OpenClaw Gateway — CTIO бот Олег (port 18791)
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=ctio
Group=ctio
WorkingDirectory=/home/ctio/.openclaw-ctio
ExecStart=/usr/bin/npx openclaw gateway --port 18791
Restart=on-failure
RestartSec=10
Environment=HOME=/home/ctio
Environment=NODE_ENV=production
Environment=OPENCLAW_HOME=/home/ctio/.openclaw-ctio
Environment=OLLAMA_API_KEY=ollama-local

# Ограничения ресурсов
MemoryMax=8G
MemoryHigh=6G
CPUQuota=200%
NoNewPrivileges=true

StandardOutput=append:/data/logs/gateway-ctio.log
StandardError=append:/data/logs/gateway-ctio.log

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
echo "  ✓ /etc/systemd/system/openclaw-gateway-ctio.service создан"

# ── 3. Запускаем только если токен передан ────────────────────────────────
echo ""
if [ -n "$BOT_TOKEN" ]; then
    echo "  Запускаю openclaw-gateway-ctio..."
    systemctl enable openclaw-gateway-ctio
    systemctl restart openclaw-gateway-ctio
    sleep 5

    if systemctl is-active --quiet openclaw-gateway-ctio; then
        echo "  ✓ Сервис ACTIVE"
    else
        echo "  ✗ Сервис не поднялся — проверь:"
        echo "    journalctl -u openclaw-gateway-ctio -n 20"
        journalctl -u openclaw-gateway-ctio -n 10 --no-pager 2>/dev/null || true
    fi
else
    echo "  ⏸ Сервис НЕ запущен — ждём токен от @BotFather"
    echo "    После получения токена запусти:"
    echo "    bash scripts/setup-ctio-bot.sh <TOKEN>"
    systemctl enable openclaw-gateway-ctio 2>/dev/null || true
fi

###############################################################################
# ВЕРИФИКАЦИЯ
###############################################################################
echo ""
echo "[ ВЕРИФИКАЦИЯ ]"

python3 - <<CHECK
import json

c = json.load(open("$CTIO_CONFIG"))
tg = c.get('channels', {}).get('telegram', {})
gw = c.get('gateway', {})

ok = True
checks = [
    ('botToken задан',           bool(tg.get('botToken'))),
    ('Олег в allowFrom',         $CTIO_TG_ID in tg.get('allowFrom', [])),
    ('CEO в allowFrom',          $CEO_TG_ID in tg.get('allowFrom', [])),
    ('streaming = false',        tg.get('streaming') is False),
    ('configWrites = false',     tg.get('configWrites') is False),
    ('port = 18791',             gw.get('port') == 18791),
    ('auth.token задан',         bool(gw.get('auth', {}).get('token'))),
    ('workspace CTIO',           'ctio' in c.get('agents',{}).get('defaults',{}).get('workspace','')),
]

for name, result in checks:
    icon = '✓' if result else '✗'
    if not result: ok = False
    print(f'  {icon} {name}')

# Конфликт токена с moa?
token = tg.get('botToken', '')
if token.startswith('8793039199'):
    print('  ⚠ КОНФЛИКТ: токен совпадает с moa-ботом — нужен новый от @BotFather!')
    ok = False
else:
    print('  ✓ Токен уникален (не конфликтует с moa)')

print()
if ok:
    print('  ✅ КОНФИГ CTIO БОТА ГОТОВ')
else:
    print('  ⚠ Требуется токен от @BotFather')
CHECK

echo ""
echo "============================================================"
if [ -n "$BOT_TOKEN" ]; then
    echo " ✅ CTIO бот запущен на порту 18791"
    echo " Олег (@p314pm) может писать боту в Telegram"
else
    echo " ⏳ Ожидание токена от @BotFather"
    echo ""
    echo " Инструкция для Марка/Олега:"
    echo "   1. Telegram → @BotFather → /newbot"
    echo "   2. Название: Banxe CTIO"
    echo "   3. Username: banxe_ctio_bot"
    echo "   4. Скопируй токен (формат: 123456789:ABC...)"
    echo "   5. На Legion:"
    echo "      cd ~/vibe-coding && git pull"
    echo "      bash scripts/setup-ctio-bot.sh 123456789:ABC..."
fi
echo " Лог: $LOG"
echo "============================================================"
