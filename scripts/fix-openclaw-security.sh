#!/bin/bash
###############################################################################
# fix-openclaw-security.sh — Banxe AI Bank
# Задача: security hardening OpenClaw @mycarmi_moa_bot (порт 18789)
# Канон: диагностика → починка → верификация
# Идемпотентен: безопасно запускать повторно
# НЕ трогает: @mycarmibot, Guiyon (порт 18794)
###############################################################################

set -euo pipefail

CONFIG="/root/.openclaw-moa/.openclaw/openclaw.json"
PROFILE_DIR="/root/.openclaw-moa"
LOG="/data/logs/fix-openclaw-security.log"
BACKUP_DIR="/data/backups/openclaw-security-fix"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p /data/logs "$BACKUP_DIR"
exec > >(tee -a "$LOG") 2>&1

echo ""
echo "============================================================"
echo " fix-openclaw-security.sh — $TIMESTAMP"
echo "============================================================"

###############################################################################
# ДИАГНОСТИКА
###############################################################################
echo ""
echo "[ ДИАГНОСТИКА ]"

if [ ! -f "$CONFIG" ]; then
    echo "КРИТИЧНО: Конфиг не найден: $CONFIG"
    exit 1
fi

cp "$CONFIG" "$BACKUP_DIR/openclaw.json.bak-$(date +%Y%m%d-%H%M%S)"
echo "✓ Бэкап создан: $BACKUP_DIR/"

echo ""
echo "Текущие security-параметры:"
python3 - <<'DIAG'
import json

CONFIG = "/root/.openclaw-moa/.openclaw/openclaw.json"
c = json.load(open(CONFIG))

def val(v):
    return str(v) if v != 'ОТСУТСТВУЕТ' else v

checks = [
    ('gateway.auth.mode',       c.get('gateway',{}).get('auth',{}).get('mode', 'ОТСУТСТВУЕТ')),
    ('gateway.auth.token',      'SET' if c.get('gateway',{}).get('auth',{}).get('token') else 'ОТСУТСТВУЕТ'),
    ('gateway.bind',            c.get('gateway',{}).get('bind', 'ОТСУТСТВУЕТ')),
    ('gateway.controlUi.dangerouslyDisableDeviceAuth', c.get('gateway',{}).get('controlUi',{}).get('dangerouslyDisableDeviceAuth', 'ОТСУТСТВУЕТ')),
    ('gateway.controlUi.allowedOrigins', str(c.get('gateway',{}).get('controlUi',{}).get('allowedOrigins', 'ОТСУТСТВУЕТ'))),
    ('tools.profile',           c.get('tools',{}).get('profile', 'ОТСУТСТВУЕТ')),
    ('tools.deny',              str(c.get('tools',{}).get('deny', 'ОТСУТСТВУЕТ'))),
    ('commands.config',         c.get('commands',{}).get('config', 'ОТСУТСТВУЕТ')),
    ('channels.telegram.configWrites', c.get('channels',{}).get('telegram',{}).get('configWrites', 'ОТСУТСТВУЕТ')),
    ('discovery.mdns.mode',     c.get('discovery',{}).get('mdns',{}).get('mode', 'ОТСУТСТВУЕТ')),
    ('browser.evaluateEnabled', c.get('browser',{}).get('evaluateEnabled', 'ОТСУТСТВУЕТ')),
    ('logging.redactSensitive', c.get('logging',{}).get('redactSensitive', 'ОТСУТСТВУЕТ')),
    ('agents.primary model',    c.get('agents',{}).get('defaults',{}).get('model',{}).get('primary','ОТСУТСТВУЕТ')),
]

for name, v in checks:
    ok = v not in ('ОТСУТСТВУЕТ', None)
    if name == 'tools.deny' and 'gateway' in str(v): icon = '✓'
    elif name == 'commands.config' and v is False: icon = '✓'
    elif name == 'browser.evaluateEnabled' and v is False: icon = '✓'
    elif name == 'gateway.controlUi.allowedOrigins' and str(v) == "['*']": icon = '⚠'
    elif ok: icon = '✓'
    else: icon = '✗'
    print(f'  {icon} {name}: {v}')
DIAG

echo ""
echo "Процессы OpenClaw (порт 18789):"
ps aux | grep 'openclaw' | grep -v grep | awk '{print "  PID=" $2, "USER=" $1}' || echo "  (не найдено)"

###############################################################################
# ПОЧИНКА
###############################################################################
echo ""
echo "[ ПОЧИНКА ]"

python3 - <<'PATCH'
import json

CONFIG = "/root/.openclaw-moa/.openclaw/openclaw.json"
with open(CONFIG, 'r') as f:
    c = json.load(f)

changes = []

# 1. tools.deny: ["gateway"]
tools = c.setdefault('tools', {})
deny = tools.get('deny', [])
if 'gateway' not in deny:
    tools['deny'] = deny + ['gateway']
    changes.append('tools.deny: добавлен "gateway" — ИИ не может менять настройки gateway')
else:
    print('  ~ tools.deny["gateway"] уже задан')

# 2. commands.config: false
commands = c.setdefault('commands', {})
if commands.get('config') is not False:
    commands['config'] = False
    changes.append('commands.config: false — /config set через чат запрещён')
else:
    print('  ~ commands.config уже false')

# 3. channels.telegram.configWrites: false
telegram = c.setdefault('channels', {}).setdefault('telegram', {})
if telegram.get('configWrites') is not False:
    telegram['configWrites'] = False
    changes.append('channels.telegram.configWrites: false — изменение конфига через Telegram запрещено')
else:
    print('  ~ channels.telegram.configWrites уже false')

# 4. browser.evaluateEnabled: false
browser = c.setdefault('browser', {})
if browser.get('evaluateEnabled') is not False:
    browser['evaluateEnabled'] = False
    changes.append('browser.evaluateEnabled: false — произвольный JS в браузере запрещён')
else:
    print('  ~ browser.evaluateEnabled уже false')

# 5. logging.redactSensitive: "tools"
log_cfg = c.setdefault('logging', {})
if log_cfg.get('redactSensitive') != 'tools':
    log_cfg['redactSensitive'] = 'tools'
    changes.append('logging.redactSensitive: "tools" — секреты маскируются в логах')
else:
    print('  ~ logging.redactSensitive уже "tools"')

# 6. gateway.controlUi.allowedOrigins — убрать wildcard "*"
gateway = c.setdefault('gateway', {})
control_ui = gateway.setdefault('controlUi', {})
if control_ui.get('allowedOrigins') == ['*']:
    control_ui['allowedOrigins'] = ['http://localhost:18789', 'http://127.0.0.1:18789']
    changes.append('gateway.controlUi.allowedOrigins: заменён "*" → localhost only')
else:
    print('  ~ gateway.controlUi.allowedOrigins уже ограничен')

# 7. discovery.mdns (уже должно быть off, но проверяем)
mdns = c.setdefault('discovery', {}).setdefault('mdns', {})
if mdns.get('mode') != 'off':
    mdns['mode'] = 'off'
    changes.append('discovery.mdns.mode: "off" — mDNS анонс отключён')
else:
    print('  ~ discovery.mdns.mode уже "off"')

if changes:
    with open(CONFIG, 'w') as f:
        json.dump(c, f, indent=2, ensure_ascii=False)
    print('\n  Применены изменения:')
    for ch in changes:
        print(f'  ✓ {ch}')
else:
    print('\n  Все параметры уже настроены.')

# Флаг расхождения модели
model = c.get('agents',{}).get('defaults',{}).get('model',{}).get('primary','?')
if 'qwen3.5' not in model:
    print(f'\n  ⚠ ФЛАГ: активная модель = {model}')
    print(f'  ⚠ CLAUDE.md ожидает: ollama/huihui_ai/qwen3.5-abliterated:35b')
    print(f'  ⚠ Модель НЕ меняется этим скриптом — требует решения CEO')
PATCH

# Права на директории
echo ""
echo "  Устанавливаю права:"
chmod 700 "$PROFILE_DIR"            && echo "  ✓ chmod 700 $PROFILE_DIR"
chmod 600 "$CONFIG"                  && echo "  ✓ chmod 600 $CONFIG"

###############################################################################
# ВЕРИФИКАЦИЯ
###############################################################################
echo ""
echo "[ ВЕРИФИКАЦИЯ ]"

python3 - <<'CHECK'
import json, sys

CONFIG = "/root/.openclaw-moa/.openclaw/openclaw.json"
c = json.load(open(CONFIG))

ok = True
checks = [
    ('tools.deny содержит "gateway"',         'gateway' in c.get('tools',{}).get('deny',[])),
    ('commands.config = false',                c.get('commands',{}).get('config') is False),
    ('channels.telegram.configWrites = false', c.get('channels',{}).get('telegram',{}).get('configWrites') is False),
    ('browser.evaluateEnabled = false',        c.get('browser',{}).get('evaluateEnabled') is False),
    ('logging.redactSensitive = "tools"',      c.get('logging',{}).get('redactSensitive') == 'tools'),
    ('gateway.auth.token задан',               bool(c.get('gateway',{}).get('auth',{}).get('token'))),
    ('gateway.bind = loopback',                c.get('gateway',{}).get('bind') == 'loopback'),
    ('gateway.auth.mode = token',              c.get('gateway',{}).get('auth',{}).get('mode') == 'token'),
    ('discovery.mdns.mode = "off"',            c.get('discovery',{}).get('mdns',{}).get('mode') == 'off'),
    ('dangerouslyDisableDeviceAuth = false',   c.get('gateway',{}).get('controlUi',{}).get('dangerouslyDisableDeviceAuth') is False),
    ('allowedOrigins без wildcard "*"',        ['*'] != c.get('gateway',{}).get('controlUi',{}).get('allowedOrigins',[])),
]

print('')
for name, result in checks:
    icon = '✓' if result else '✗'
    if not result:
        ok = False
    print(f'  {icon} {name}')

print('')
if ok:
    print('  ✅ ВСЕ 11 SECURITY ПАРАМЕТРОВ ПРИМЕНЕНЫ')
else:
    print('  ✗ Часть параметров не применилась')
    sys.exit(1)
CHECK

# Перезапуск gateway
echo ""
echo "  Перезапуск @mycarmi_moa_bot gateway..."

if systemctl list-units --type=service 2>/dev/null | grep -q openclaw-gateway-moa; then
    systemctl restart openclaw-gateway-moa 2>/dev/null && sleep 3
    if systemctl is-active --quiet openclaw-gateway-moa 2>/dev/null; then
        echo "  ✓ Systemd сервис активен"
    else
        echo "  ✗ Systemd сервис не поднялся — проверь: journalctl -u openclaw-gateway-moa -n 20"
    fi
else
    # Restart через kill process
    OLD_PID=$(ps aux | grep 'openclaw-gateway.*18789' | grep -v grep | awk '{print $2}' | head -1)
    if [ -n "${OLD_PID:-}" ]; then
        echo "  Останавливаю PID=$OLD_PID..."
        kill "$OLD_PID" 2>/dev/null && sleep 3
    fi
    OPENCLAW_HOME="$PROFILE_DIR" nohup npx openclaw gateway --port 18789 >> /data/logs/gateway-moa.log 2>&1 &
    sleep 5
    NEW_PID=$(ps aux | grep 'openclaw.*18789' | grep -v grep | awk '{print $2}' | head -1)
    [ -n "${NEW_PID:-}" ] && echo "  ✓ Gateway перезапущен PID=$NEW_PID" || echo "  ✗ Gateway не запустился"
fi

# Проверка ответа
sleep 2
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:18789/health 2>/dev/null || echo "000")
if [ "$HTTP" = "200" ] || [ "$HTTP" = "401" ] || [ "$HTTP" = "403" ]; then
    echo "  ✓ Gateway отвечает (HTTP $HTTP)"
elif [ "$HTTP" = "000" ]; then
    echo "  ⚠ Gateway не ответил на /health — возможно другой healthcheck endpoint"
else
    echo "  ⚠ Неожиданный HTTP $HTTP"
fi

###############################################################################
echo ""
echo "============================================================"
echo " ГОТОВО — $TIMESTAMP"
echo " Лог:    $LOG"
echo " Бэкап:  $BACKUP_DIR/"
echo "============================================================"
