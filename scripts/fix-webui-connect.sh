#!/bin/bash
###############################################################################
# fix-webui-connect.sh — Диагностика и починка Web UI Connect
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-webui-connect.sh
#
# Проблема: кнопка "Соединить" не реагирует
# Диагностика: проверяем WebSocket, конфиг controlUi, порты
###############################################################################

echo "=========================================="
echo "  ДИАГНОСТИКА WEB UI CONNECT"
echo "=========================================="

# 1. Проверяем SSH туннель
echo "[1/5] SSH туннель..."
if ss -tlnp 2>/dev/null | grep -q ":18789.*ssh"; then
    echo "  ✓ Туннель активен (порт 18789 → GMKtec)"
else
    echo "  ⚠ Туннель не найден, создаю..."
    ssh -L 18789:127.0.0.1:18789 gmktec -N -f 2>/dev/null
    sleep 2
    ss -tlnp 2>/dev/null | grep ":18789" && echo "  ✓ Туннель создан" || echo "  ✗ Не удалось"
fi

# 2. Проверяем что Gateway отвечает через туннель
echo ""
echo "[2/5] Gateway через туннель..."
HTTP_CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/ 2>/dev/null)
echo "  HTTP GET http://127.0.0.1:18789/ → $HTTP_CODE"

# 3. Проверяем WebSocket
echo ""
echo "[3/5] WebSocket..."
# Пробуем подключиться к WebSocket
WS_TEST=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
    -H "Upgrade: websocket" \
    -H "Connection: Upgrade" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    -H "Sec-WebSocket-Version: 13" \
    http://127.0.0.1:18789/ 2>/dev/null)
echo "  WebSocket upgrade → HTTP $WS_TEST (101=OK, другое=проблема)"

# 4. Диагностика на GMKtec
echo ""
echo "[4/5] Состояние Gateway на GMKtec..."
ssh gmktec 'bash -s' << 'REMOTE'
echo "  Процессы gateway:"
ps aux | grep -E "[o]penclaw.*gateway" | awk '{print "    PID "$2" "$11" "$12" "$13}'

echo ""
echo "  Порты 18789:"
ss -tlnp | grep 18789 | sed 's/^/    /'

echo ""
echo "  Лог gateway (последние 10 строк):"
tail -10 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'

echo ""
echo "  Конфиг controlUi:"
python3 -c "
import json
with open('/root/.openclaw-moa/.openclaw/openclaw.json') as f:
    c = json.load(f)
gw = c.get('gateway',{})
print(f'    bind: {gw.get(\"bind\", gw.get(\"mode\",\"?\"))}')
print(f'    auth.mode: {gw.get(\"auth\",{}).get(\"mode\",\"?\")}')
print(f'    auth.token: {gw.get(\"auth\",{}).get(\"token\",\"?\")[:16]}...')
print(f'    controlUi: {gw.get(\"controlUi\",{})}')
print(f'    trustedProxies: {gw.get(\"trustedProxies\",\"?\")}')
" 2>/dev/null

echo ""
echo "  OpenClaw версия:"
npx openclaw --version 2>/dev/null || echo "    не определена"

echo ""
echo "  Пробую openclaw doctor..."
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa npx openclaw doctor 2>&1 | head -20 | sed 's/^/    /'
REMOTE

# 5. Пробуем другой подход — dangerouslyDisableDeviceAuth
echo ""
echo "[5/5] Пробую отключить device auth (для диагностики)..."
ssh gmktec 'python3 << "PY"
import json
cfg_path = "/root/.openclaw-moa/.openclaw/openclaw.json"
with open(cfg_path) as f:
    cfg = json.load(f)
gw = cfg.setdefault("gateway", {})
cui = gw.setdefault("controlUi", {})
cui["dangerouslyDisableDeviceAuth"] = True
cui["allowedOrigins"] = ["*"]
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print("  ✓ dangerouslyDisableDeviceAuth=true, allowedOrigins=[*]")
print("  ⚠ Это только для диагностики! Потом вернём false")
PY

# Перезапуск gateway
pkill -f "openclaw.*18789" 2>/dev/null
sleep 3
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
sleep 10

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway перезапущен"
    # Получаем новый URL
    OPENCLAW_HOME=/root/.openclaw-moa npx openclaw dashboard --no-open 2>&1 | grep "Dashboard URL" | sed "s/^/  /"
else
    echo "  ✗ Gateway не запустился"
    tail -10 /data/logs/gateway-moa.log | sed "s/^/    /"
fi'

# Пересоздаём туннель
echo ""
echo "  Пересоздаю SSH туннель..."
kill $(pgrep -f "ssh.*18789.*gmktec") 2>/dev/null
sleep 1
ssh -L 18789:127.0.0.1:18789 gmktec -N -f 2>/dev/null
sleep 2

# Финальный URL
echo ""
echo "=========================================="
echo "  ПОПРОБУЙ ОТКРЫТЬ В БРАУЗЕРЕ:"
echo ""
echo "  http://127.0.0.1:18789"
echo ""
echo "  (без токена — device auth отключен)"
echo "  Если заработает — скинь скриншот"
echo "  Потом вернём безопасные настройки"
echo "=========================================="
