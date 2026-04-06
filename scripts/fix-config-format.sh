#!/bin/bash
###############################################################################
# fix-config-format.sh — Исправление формата конфига OpenClaw
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-config-format.sh
###############################################################################

echo "=========================================="
echo "  ИСПРАВЛЕНИЕ ФОРМАТА КОНФИГА"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

###########################################################################
# 1. Находим РАБОЧИЙ бэкап — смотрим структуру
###########################################################################
echo "[1/4] Ищу рабочий бэкап конфига..."

# Ищем бэкап где бот работал (до наших правок)
for BAK in \
    "/root/.openclaw-moa/.openclaw/openclaw.json.backup-20260302-0259" \
    "/root/.openclaw-moa/.openclaw/openclaw.json.backup-20260302-0122" \
    "/root/.openclaw-moa/.openclaw/openclaw.json.backup-before-gemini" \
    "/root/.openclaw-moa/.openclaw/openclaw.json.bak.2" \
    "/root/.openclaw-moa/.openclaw/openclaw.json.bak.3"; do
    if [ -f "$BAK" ]; then
        echo "  Найден: $BAK"
        echo "  Структура модели:"
        python3 -c "
import json
with open('$BAK') as f:
    c = json.load(f)
# Показываем как была задана модель
agents = c.get('agents',{})
defaults = agents.get('defaults',{})
models = defaults.get('models',{})
print(f'    agents.defaults.models: {json.dumps(models, indent=6)[:300]}')
print(f'    provider: {json.dumps(c.get(\"provider\",{}), indent=6)[:200]}')
print(f'    channels type: {type(c.get(\"channels\")).__name__}')
# Ищем systemPrompt
sp_locations = []
if c.get('systemPrompt'): sp_locations.append('root')
if defaults.get('systemPrompt'): sp_locations.append('agents.defaults')
if agents.get('systemPrompt'): sp_locations.append('agents')
print(f'    systemPrompt locations: {sp_locations if sp_locations else \"нигде\"}')
# Все ключи корневого уровня
print(f'    root keys: {list(c.keys())}')
" 2>/dev/null
        break
    fi
done

# Также смотрим текущий сломанный конфиг
echo ""
echo "  Текущий (сломанный) — корневые ключи:"
python3 -c "
import json
with open('/root/.openclaw-moa/.openclaw/openclaw.json') as f:
    c = json.load(f)
print(f'    {list(c.keys())}')
" 2>/dev/null

###########################################################################
# 2. Восстанавливаем правильный формат из бэкапа + наши настройки
###########################################################################
echo ""
echo "[2/4] Восстанавливаю правильный формат..."

python3 << 'PYFIX'
import json, glob

cfg_path = "/root/.openclaw-moa/.openclaw/openclaw.json"

# Ищем рабочий бэкап
backup_cfg = None
for bak in sorted(glob.glob(cfg_path + ".bak*") + glob.glob(cfg_path + ".backup*"), reverse=True):
    try:
        with open(bak) as f:
            bc = json.load(f)
        # Проверяем что это рабочий конфиг (есть channels с telegram)
        channels = bc.get("channels", {})
        has_tg = False
        if isinstance(channels, dict) and "telegram" in channels:
            has_tg = bool(channels["telegram"].get("botToken"))
        elif isinstance(channels, list):
            for ch in channels:
                if isinstance(ch, dict) and ch.get("botToken"):
                    has_tg = True
                    break
        if has_tg:
            backup_cfg = bc
            print(f"  Рабочий бэкап: {bak}")
            break
    except:
        continue

if not backup_cfg:
    print("  ✗ Рабочий бэкап не найден — строю конфиг с нуля")

# Загружаем текущий
with open(cfg_path) as f:
    cfg = json.load(f)

# Берём структуру из бэкапа, но с нашими обновлениями
if backup_cfg:
    # Используем бэкап как базу
    result = backup_cfg.copy()
    
    # Обновляем telegram token (новый)
    channels = result.get("channels", {})
    if isinstance(channels, dict) and "telegram" in channels:
        channels["telegram"]["botToken"] = "8793039199:AAGj2RrwI1ShQlNbKCsXl3IMpbs3hWMTPAo"
    elif isinstance(channels, list):
        for ch in channels:
            if isinstance(ch, dict) and "botToken" in ch:
                ch["botToken"] = "8793039199:AAGj2RrwI1ShQlNbKCsXl3IMpbs3hWMTPAo"
    
    # Сохраняем gateway auth и security из текущего конфига
    gw = result.setdefault("gateway", {})
    current_gw = cfg.get("gateway", {})
    if current_gw.get("auth", {}).get("token"):
        gw["auth"] = current_gw["auth"]
    gw.setdefault("controlUi", {})["dangerouslyDisableDeviceAuth"] = False
    if current_gw.get("controlUi", {}).get("allowedOrigins"):
        gw["controlUi"]["allowedOrigins"] = current_gw["controlUi"]["allowedOrigins"]
    gw["trustedProxies"] = ["127.0.0.1"]
    
    # mdns off
    result.setdefault("discovery", {}).setdefault("mdns", {})["mode"] = "off"
    
else:
    # Строим минимальный рабочий конфиг
    result = {
        "gateway": {
            "mode": "local",
            "auth": cfg.get("gateway", {}).get("auth", {}),
            "controlUi": {
                "dangerouslyDisableDeviceAuth": False,
                "allowedOrigins": cfg.get("gateway", {}).get("controlUi", {}).get("allowedOrigins", [])
            },
            "trustedProxies": ["127.0.0.1"]
        },
        "channels": {
            "telegram": {
                "enabled": True,
                "botToken": "8793039199:AAGj2RrwI1ShQlNbKCsXl3IMpbs3hWMTPAo",
                "dmPolicy": "allowlist",
                "allowFrom": [508602494],
                "groupPolicy": "allowlist",
                "streaming": "off"
            }
        },
        "discovery": {"mdns": {"mode": "off"}}
    }

# Удаляем ключи которые OpenClaw не понимает
for bad_key in ["provider", "systemPrompt", "configWrites"]:
    result.pop(bad_key, None)

# Удаляем systemPrompt из agents.defaults если есть
if "agents" in result:
    defaults = result["agents"].get("defaults", {})
    defaults.pop("systemPrompt", None)
    defaults.pop("params", None)
    defaults.pop("tools", None)
    # Убеждаемся что models.default — объект если нужен
    models = defaults.get("models", {})
    if isinstance(models.get("default"), str):
        # OpenClaw хочет объект — но возможно в бэкапе он строка
        # Оставляем как есть — если бэкап работал со строкой
        pass

# Сохраняем
with open(cfg_path, "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

print(f"  ✓ Конфиг восстановлен")
print(f"  Корневые ключи: {list(result.keys())}")
agents = result.get("agents", {})
defaults = agents.get("defaults", {})
models = defaults.get("models", {})
print(f"  Модель: {models.get('default', 'из бэкапа')}")
PYFIX

###########################################################################
# 3. Проверяем конфиг через openclaw doctor
###########################################################################
echo ""
echo "[3/4] Проверяю конфиг через doctor..."

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa npx openclaw doctor 2>&1 | head -15 | sed 's/^/    /'

###########################################################################
# 4. Запускаем gateway
###########################################################################
echo ""
echo "[4/4] Запускаю gateway..."

pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 5

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 15 секунд..."
sleep 15

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ACTIVE"
else
    echo "  ✗ Не запустился. Лог:"
    tail -10 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'
fi

echo ""
echo "  Модель в логе:"
grep -i "agent model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

echo ""
echo "  Telegram:"
grep -i "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -3 | sed 's/^/    /'

REMOTE_END
