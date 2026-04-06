#!/bin/bash
###############################################################################
# fix-webui-origin.sh — Исправление "origin not allowed" в Web UI
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-webui-origin.sh
#
# Проблема: OpenClaw Gateway отклоняет подключение из браузера
#   "origin not allowed (open the Control UI from the gateway host
#    or allow it in gateway.controlUi.allowedOrigins)"
#
# Решение: добавить allowedOrigins в конфиг + перезапустить gateway
###############################################################################

echo "=========================================="
echo "  FIX: Web UI origin not allowed"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export PATH="$PATH:/root/.local/bin"

###########################################################################
# 1. Показываем текущее состояние
###########################################################################
echo "[1/4] Текущее состояние..."
echo ""
echo "  Конфиг MoA:"
python3 << 'PY1'
import json
with open("/root/.openclaw-moa/.openclaw/openclaw.json") as f:
    c = json.load(f)
gw = c.get("gateway", {})
print(f"  Token: {gw.get('auth',{}).get('token','НЕТ')[:16]}...")
print(f"  controlUi: {gw.get('controlUi', 'НЕТ')}")
print(f"  trustedProxies: {gw.get('trustedProxies', 'НЕТ')}")
print(f"  bind: {gw.get('bind', gw.get('mode', 'НЕТ'))}")
PY1

echo ""
echo "  Порты:"
ss -tlnp | grep -E "1878|1879|:443 |:80 " | while read line; do echo "    $line"; done

###########################################################################
# 2. Добавляем allowedOrigins
###########################################################################
echo ""
echo "[2/4] Добавляю allowedOrigins..."

for CFG in \
    "/root/.openclaw-moa/.openclaw/openclaw.json" \
    "/root/.openclaw-moa/openclaw.json" \
    "/root/.openclaw-default/.openclaw/openclaw.json" \
    "/root/.openclaw-default/openclaw.json"; do
    
    [ ! -f "$CFG" ] && continue
    
    python3 << PYFIX
import json

cfg_path = "$CFG"
with open(cfg_path) as f:
    cfg = json.load(f)

changes = []
gw = cfg.setdefault("gateway", {})
cui = gw.setdefault("controlUi", {})

# Разрешаем все наши origin'ы
origins = [
    "https://192.168.0.72",
    "https://90.116.185.11",
    "https://localhost",
    "https://127.0.0.1",
    "http://192.168.0.72",
    "http://localhost"
]

if cui.get("allowedOrigins") != origins:
    cui["allowedOrigins"] = origins
    changes.append("allowedOrigins добавлены")

# Убеждаемся что dangerouslyDisableDeviceAuth = false
if "dangerouslyDisableDeviceAuth" not in cui:
    cui["dangerouslyDisableDeviceAuth"] = False

# trustedProxies
if gw.get("trustedProxies") != ["127.0.0.1"]:
    gw["trustedProxies"] = ["127.0.0.1"]
    changes.append("trustedProxies=[127.0.0.1]")

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

if changes:
    print(f"  ✓ {cfg_path.split('/')[-3]}/{cfg_path.split('/')[-1]}:")
    for c in changes:
        print(f"      {c}")
PYFIX
done

###########################################################################
# 3. Перезапускаем gateway
###########################################################################
echo ""
echo "[3/4] Перезапускаю gateway..."

# Убиваем все процессы openclaw
pkill -f "openclaw.*gateway" 2>/dev/null
sleep 3

# Проверяем что порты свободны
if ss -tlnp | grep -q ":18789 "; then
    echo "  ⚠ Порт 18789 всё ещё занят, жду..."
    sleep 5
fi

# Запускаем MoA
echo "  Запускаю @mycarmi_moa_bot..."
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
MOA_PID=$!
sleep 10

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ @mycarmi_moa_bot ACTIVE (PID $MOA_PID, порт 18789)"
else
    echo "  ✗ Не запустился. Лог:"
    tail -15 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'
fi

# Запускаем mycarmibot
echo "  Запускаю @mycarmibot..."
cd /root/.openclaw-default
OPENCLAW_HOME=/root/.openclaw-default nohup npx openclaw gateway --port 18793 > /data/logs/gateway-mycarmibot.log 2>&1 &
CB_PID=$!
sleep 10

if ss -tlnp | grep -q ":18793 "; then
    echo "  ✓ @mycarmibot ACTIVE (PID $CB_PID, порт 18793)"
else
    echo "  ✗ Не запустился. Лог:"
    tail -15 /data/logs/gateway-mycarmibot.log 2>/dev/null | sed 's/^/    /'
fi

###########################################################################
# 4. Проверка и показываем токен
###########################################################################
echo ""
echo "[4/4] Проверка..."

echo ""
echo "  Порты:"
ss -tlnp | grep -E "1878|1879|:443 |:80 " | while read line; do echo "    $line"; done

echo ""
echo "  ══════════════════════════════════════"
echo "  ДАННЫЕ ДЛЯ ВХОДА В WEB UI:"
echo "  ══════════════════════════════════════"
echo ""
echo "  URL: https://192.168.0.72"
echo "  HTTP Auth: ceo / Banxe2026!"
echo ""

# Показываем Gateway Token
TOKEN=$(python3 -c "
import json
with open('/root/.openclaw-moa/.openclaw/openclaw.json') as f:
    c = json.load(f)
print(c.get('gateway',{}).get('auth',{}).get('token',''))
" 2>/dev/null)

echo "  Gateway Token (скопируй и вставь в поле):"
echo "  $TOKEN"
echo ""
echo "  AllowedOrigins:"
python3 -c "
import json
with open('/root/.openclaw-moa/.openclaw/openclaw.json') as f:
    c = json.load(f)
for o in c.get('gateway',{}).get('controlUi',{}).get('allowedOrigins',[]):
    print(f'    {o}')
" 2>/dev/null

echo ""
echo "  ══════════════════════════════════════"
echo "  ИНСТРУКЦИЯ:"
echo "  1. Открой https://192.168.0.72"
echo "  2. Логин: ceo / Пароль: Banxe2026!"
echo "  3. В поле Gateway Token вставь токен выше"
echo "  4. Нажми Connect"
echo "  ══════════════════════════════════════"

REMOTE_END
