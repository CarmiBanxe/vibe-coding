#!/bin/bash
###############################################################################
# fix-gateway-config.sh — Починка конфигов OpenClaw после бага webSearch
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-gateway-config.sh
#
# Проблема:
#   setup-brave-search.sh добавил ключ "webSearch" в tools — OpenClaw его
#   не понимает и отказывается запускаться. Также channels стал массивом
#   вместо объекта.
#
# Что делает:
#   1. Показывает текущие конфиги (до починки)
#   2. Удаляет "webSearch" из tools
#   3. Исправляет channels (массив → объект)
#   4. Запускает openclaw doctor --fix для проверки
#   5. Перезапускает оба gateway
#   6. Проверяет что порты слушают и боты отвечают
###############################################################################

echo "=========================================="
echo "  ПОЧИНКА КОНФИГОВ OPENCLAW"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

# Останавливаем всё что крутится
echo "[1/6] Останавливаю gateway..."
systemctl stop openclaw-gateway-moa 2>/dev/null
systemctl stop openclaw-gateway-mycarmibot 2>/dev/null
pkill -f "openclaw.*gateway" 2>/dev/null
sleep 2
echo "  ✓ Остановлено"

###########################################################################
# 2. ПОЧИНКА MoA конфига
###########################################################################
echo ""
echo "[2/6] Починка MoA конфига..."

MOA_CFG="/root/.openclaw-moa/.openclaw/openclaw.json"

if [ -f "$MOA_CFG" ]; then
    # Бэкап
    cp "$MOA_CFG" "${MOA_CFG}.bak-$(date +%Y%m%d-%H%M%S)"
    echo "  Бэкап создан"
    
    # Показываем текущее состояние
    echo "  Текущий размер: $(stat -c%s "$MOA_CFG") байт"
    
    # Починка Python-скриптом
    python3 << 'PYFIX'
import json, sys, copy

cfg_path = "/root/.openclaw-moa/.openclaw/openclaw.json"

with open(cfg_path) as f:
    cfg = json.load(f)

original = json.dumps(cfg, sort_keys=True)
changes = []

# 1. Удаляем webSearch из tools
if "tools" in cfg and "webSearch" in cfg["tools"]:
    del cfg["tools"]["webSearch"]
    changes.append("Удалён tools.webSearch")

# Также проверяем вложенные структуры
for key in list(cfg.get("tools", {}).keys()):
    if key.lower() == "websearch" or key == "web_search":
        del cfg["tools"][key]
        changes.append(f"Удалён tools.{key}")

# 2. Исправляем channels: массив → объект
if "channels" in cfg and isinstance(cfg["channels"], list):
    # Преобразуем массив каналов в объект
    channels_obj = {}
    for i, ch in enumerate(cfg["channels"]):
        if isinstance(ch, dict):
            # Берём имя канала или создаём
            name = ch.get("name", ch.get("type", f"channel_{i}"))
            channels_obj[name] = ch
        elif isinstance(ch, str):
            channels_obj[ch] = {"type": ch}
    cfg["channels"] = channels_obj
    changes.append(f"channels: массив ({len(channels_obj)} эл.) → объект")

# 3. Проверяем gateway.mode=local
if cfg.get("gateway", {}).get("mode") != "local":
    if "gateway" not in cfg:
        cfg["gateway"] = {}
    cfg["gateway"]["mode"] = "local"
    changes.append("Добавлен gateway.mode=local")

if changes:
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print("  Изменения:")
    for c in changes:
        print(f"    ✓ {c}")
else:
    print("  Конфиг уже корректен")
PYFIX
else
    echo "  ✗ Конфиг не найден: $MOA_CFG"
fi

###########################################################################
# 3. ПОЧИНКА mycarmibot конфига
###########################################################################
echo ""
echo "[3/6] Починка mycarmibot конфига..."

CARMI_CFG="/root/.openclaw-default/.openclaw/openclaw.json"

if [ -f "$CARMI_CFG" ]; then
    cp "$CARMI_CFG" "${CARMI_CFG}.bak-$(date +%Y%m%d-%H%M%S)"
    echo "  Бэкап создан"
    
    python3 << 'PYFIX2'
import json

cfg_path = "/root/.openclaw-default/.openclaw/openclaw.json"

with open(cfg_path) as f:
    cfg = json.load(f)

changes = []

# 1. Удаляем webSearch из tools
if "tools" in cfg:
    for key in list(cfg["tools"].keys()):
        if "websearch" in key.lower() or "web_search" in key.lower():
            del cfg["tools"][key]
            changes.append(f"Удалён tools.{key}")

# 2. Исправляем channels
if "channels" in cfg and isinstance(cfg["channels"], list):
    channels_obj = {}
    for i, ch in enumerate(cfg["channels"]):
        if isinstance(ch, dict):
            name = ch.get("name", ch.get("type", f"channel_{i}"))
            channels_obj[name] = ch
        elif isinstance(ch, str):
            channels_obj[ch] = {"type": ch}
    cfg["channels"] = channels_obj
    changes.append(f"channels: массив → объект")

# 3. gateway.mode=local
if cfg.get("gateway", {}).get("mode") != "local":
    if "gateway" not in cfg:
        cfg["gateway"] = {}
    cfg["gateway"]["mode"] = "local"
    changes.append("Добавлен gateway.mode=local")

if changes:
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print("  Изменения:")
    for c in changes:
        print(f"    ✓ {c}")
else:
    print("  Конфиг уже корректен")
PYFIX2
else
    echo "  ✗ Конфиг не найден: $CARMI_CFG"
fi

###########################################################################
# 4. ТАКЖЕ ЧИНИМ КОРНЕВЫЕ КОНФИГИ (если OpenClaw читает их тоже)
###########################################################################
echo ""
echo "[4/6] Проверяю корневые конфиги..."

for CFG_FILE in /root/.openclaw-moa/openclaw.json /root/.openclaw-default/openclaw.json; do
    if [ -f "$CFG_FILE" ]; then
        python3 << PYFIX3
import json

cfg_path = "$CFG_FILE"
with open(cfg_path) as f:
    cfg = json.load(f)

changes = []
if "tools" in cfg:
    for key in list(cfg["tools"].keys()):
        if "websearch" in key.lower() or "web_search" in key.lower():
            del cfg["tools"][key]
            changes.append(f"Удалён tools.{key}")

if "channels" in cfg and isinstance(cfg["channels"], list):
    channels_obj = {}
    for i, ch in enumerate(cfg["channels"]):
        if isinstance(ch, dict):
            name = ch.get("name", ch.get("type", f"channel_{i}"))
            channels_obj[name] = ch
        elif isinstance(ch, str):
            channels_obj[ch] = {"type": ch}
    cfg["channels"] = channels_obj
    changes.append("channels: массив → объект")

if changes:
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"  {cfg_path}:")
    for c in changes:
        print(f"    ✓ {c}")
else:
    print(f"  {cfg_path}: OK")
PYFIX3
    fi
done

###########################################################################
# 5. ЗАПУСКАЕМ openclaw doctor --fix (если доступно)
###########################################################################
echo ""
echo "[5/6] Запускаю openclaw doctor..."

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa npx openclaw doctor --fix 2>&1 | head -20 || echo "  (doctor не доступен или не нужен)"

echo ""
cd /root/.openclaw-default
OPENCLAW_HOME=/root/.openclaw-default npx openclaw doctor --fix 2>&1 | head -20 || echo "  (doctor не доступен)"

###########################################################################
# 6. ПЕРЕЗАПУСК GATEWAY
###########################################################################
echo ""
echo "[6/6] Запускаю gateway..."

# Обновляем systemd сервисы с OPENCLAW_HOME
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
Environment=OPENCLAW_HOME=/root/.openclaw-moa

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/openclaw-gateway-mycarmibot.service << 'SVC2'
[Unit]
Description=OpenClaw Gateway — @mycarmibot (port 18793)
After=network.target ollama.service

[Service]
Type=simple
WorkingDirectory=/root/.openclaw-default
ExecStart=/usr/bin/npx openclaw gateway --port 18793
Restart=always
RestartSec=10
Environment=HOME=/root
Environment=NODE_ENV=production
Environment=OPENCLAW_HOME=/root/.openclaw-default

[Install]
WantedBy=multi-user.target
SVC2

systemctl daemon-reload

# Запуск MoA
echo "  Запускаю @mycarmi_moa_bot (порт 18789)..."
systemctl start openclaw-gateway-moa
sleep 10

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ @mycarmi_moa_bot ACTIVE"
    systemctl enable openclaw-gateway-moa 2>/dev/null
else
    echo "  ✗ systemd не сработал"
    journalctl -u openclaw-gateway-moa --no-pager -n 5 2>/dev/null | tail -5
    echo ""
    echo "  Пробую nohup..."
    cd /root/.openclaw-moa
    OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
    sleep 10
    if ss -tlnp | grep -q ":18789 "; then
        echo "  ✓ @mycarmi_moa_bot ACTIVE (nohup)"
    else
        echo "  ✗ НЕ ЗАПУСТИЛСЯ"
        tail -10 /data/logs/gateway-moa.log 2>/dev/null
    fi
fi

# Запуск mycarmibot
echo ""
echo "  Запускаю @mycarmibot (порт 18793)..."
systemctl start openclaw-gateway-mycarmibot
sleep 10

if ss -tlnp | grep -q ":18793 "; then
    echo "  ✓ @mycarmibot ACTIVE"
    systemctl enable openclaw-gateway-mycarmibot 2>/dev/null
else
    echo "  ✗ systemd не сработал"
    journalctl -u openclaw-gateway-mycarmibot --no-pager -n 5 2>/dev/null | tail -5
    echo ""
    echo "  Пробую nohup..."
    cd /root/.openclaw-default
    OPENCLAW_HOME=/root/.openclaw-default nohup npx openclaw gateway --port 18793 > /data/logs/gateway-mycarmibot.log 2>&1 &
    sleep 10
    if ss -tlnp | grep -q ":18793 "; then
        echo "  ✓ @mycarmibot ACTIVE (nohup)"
    else
        echo "  ✗ НЕ ЗАПУСТИЛСЯ"
        tail -10 /data/logs/gateway-mycarmibot.log 2>/dev/null
    fi
fi

###########################################################################
# ФИНАЛЬНАЯ ПРОВЕРКА
###########################################################################
echo ""
echo "=========================================="
echo "  РЕЗУЛЬТАТ:"
echo ""
echo "  Порты:"
ss -tlnp | grep -E "1878|1879" | while read line; do
    echo "    $line"
done
if ! ss -tlnp | grep -qE "1878|1879"; then
    echo "    (gateway не запущены)"
fi

echo ""
echo "  Процессы:"
ps aux | grep -E "[o]penclaw.*gateway" | awk '{print "    PID "$2": "$11" "$12" "$13" "$14}'
if ! ps aux | grep -qE "[o]penclaw.*gateway"; then
    echo "    (нет процессов gateway)"
fi

echo ""
echo "  Все сервисы:"
for svc in openclaw-gateway-moa openclaw-gateway-mycarmibot; do
    STATUS=$(systemctl is-active $svc 2>/dev/null)
    echo "    $svc: $STATUS"
done

REMOTE_END

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "Если боты запустились — проверь в Telegram:"
echo '  "Какие у тебя инструменты для поиска?"'
