#!/bin/bash
###############################################################################
# fix-telegram-channel.sh — Починка Telegram канала (401 Unauthorized)
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-telegram-channel.sh
#
# Проблема: Telegram канал крашится с 401: Unauthorized
# Причина: при правках конфига channels мог потеряться Telegram token
#
# Что делает (АККУРАТНО, не ломает остальное):
#   1. Показывает текущий конфиг channels
#   2. Проверяет есть ли Telegram token
#   3. Если нет — ищет в бэкапах
#   4. Перезапускает ТОЛЬКО gateway (не трогает nginx, SSH туннель и т.д.)
###############################################################################

echo "=========================================="
echo "  ПОЧИНКА TELEGRAM КАНАЛА"
echo "  (не трогаем Web UI, nginx, остальное)"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export PATH="$PATH:/root/.local/bin"

###########################################################################
# 1. Диагностика — смотрим channels в конфиге
###########################################################################
echo "[1/4] Диагностика channels..."

CFG="/root/.openclaw-moa/.openclaw/openclaw.json"

python3 << 'PY1'
import json, glob

cfg_path = "/root/.openclaw-moa/.openclaw/openclaw.json"
with open(cfg_path) as f:
    cfg = json.load(f)

channels = cfg.get("channels", "НЕТ")
print(f"  channels тип: {type(channels).__name__}")
print(f"  channels значение: {json.dumps(channels, indent=4, ensure_ascii=False)[:500]}")

# Ищем Telegram token
def find_token(obj, path=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "token" and isinstance(v, str) and len(v) > 20:
                print(f"  Найден token в {path}.{k}: {v[:15]}...")
            find_token(v, f"{path}.{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            find_token(v, f"{path}[{i}]")

find_token(cfg)

# Ищем в бэкапах
print("")
print("  Бэкапы конфига:")
backups = sorted(glob.glob("/root/.openclaw-moa/.openclaw/openclaw.json.bak*"))
for b in backups[-5:]:
    try:
        with open(b) as f:
            bc = json.load(f)
        ch = bc.get("channels", {})
        # Ищем telegram token в бэкапе
        def find_tg_token(obj):
            if isinstance(obj, dict):
                if "token" in obj and isinstance(obj["token"], str) and len(obj["token"]) > 20:
                    return obj["token"]
                for v in obj.values():
                    r = find_tg_token(v)
                    if r: return r
            elif isinstance(obj, list):
                for v in obj:
                    r = find_tg_token(v)
                    if r: return r
            return None
        
        tk = find_tg_token(bc)
        if tk:
            print(f"  ✓ {b}: token найден ({tk[:15]}...)")
        else:
            print(f"    {b}: token не найден")
    except:
        print(f"    {b}: не читается")

# Также проверяем корневой конфиг
print("")
print("  Корневой конфиг:")
try:
    with open("/root/.openclaw-moa/openclaw.json") as f:
        root_cfg = json.load(f)
    root_ch = root_cfg.get("channels", {})
    tk = find_tg_token(root_cfg)
    if tk:
        print(f"  ✓ openclaw.json: token найден ({tk[:15]}...)")
    else:
        print(f"    openclaw.json: token не найден")
except:
    print("    не читается")
PY1

###########################################################################
# 2. Восстанавливаем channels из рабочего бэкапа
###########################################################################
echo ""
echo "[2/4] Восстанавливаю Telegram конфигурацию..."

python3 << 'PY2'
import json, glob

cfg_path = "/root/.openclaw-moa/.openclaw/openclaw.json"

# Загружаем текущий конфиг
with open(cfg_path) as f:
    cfg = json.load(f)

# Ищем Telegram token во ВСЕХ возможных местах
telegram_token = None

# 1. В текущем конфиге
def find_tg_token(obj):
    if isinstance(obj, dict):
        if "token" in obj and isinstance(obj["token"], str) and len(obj["token"]) > 20 and ":" in obj["token"]:
            return obj["token"]
        for v in obj.values():
            r = find_tg_token(v)
            if r: return r
    elif isinstance(obj, list):
        for v in obj:
            r = find_tg_token(v)
            if r: return r
    return None

telegram_token = find_tg_token(cfg)

# 2. В бэкапах
if not telegram_token:
    for backup in sorted(glob.glob("/root/.openclaw-moa/.openclaw/openclaw.json.bak*"), reverse=True):
        try:
            with open(backup) as f:
                bc = json.load(f)
            telegram_token = find_tg_token(bc)
            if telegram_token:
                print(f"  Token найден в бэкапе: {backup}")
                break
        except:
            continue

# 3. В корневом конфиге
if not telegram_token:
    try:
        with open("/root/.openclaw-moa/openclaw.json") as f:
            root_cfg = json.load(f)
        telegram_token = find_tg_token(root_cfg)
        if telegram_token:
            print(f"  Token найден в корневом конфиге")
    except:
        pass

if not telegram_token:
    print("  ✗ Telegram token НЕ НАЙДЕН нигде!")
    print("  Нужно заново получить от @BotFather")
else:
    print(f"  Token: {telegram_token[:15]}...")
    
    # Восстанавливаем channels как объект (правильный формат)
    cfg["channels"] = {
        "telegram": {
            "enabled": True,
            "dmPolicy": "allowlist",
            "allowFrom": [508602494],
            "token": telegram_token
        }
    }
    
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    
    print("  ✓ channels.telegram восстановлен")
    print(f"    dmPolicy: allowlist")
    print(f"    allowFrom: [508602494]")
PY2

###########################################################################
# 3. Перезапускаем ТОЛЬКО MoA gateway
###########################################################################
echo ""
echo "[3/4] Перезапускаю gateway (аккуратно)..."

# Убиваем только MoA процесс
pkill -f "openclaw.*18789" 2>/dev/null
sleep 3

# Запускаем
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
sleep 12

# Проверяем
if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ACTIVE (порт 18789)"
else
    echo "  ✗ Gateway не запустился"
    echo "  Лог:"
    tail -10 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'
fi

# Ждём и проверяем Telegram канал
sleep 5
echo ""
echo "  Лог Telegram:"
tail -5 /data/logs/gateway-moa.log 2>/dev/null | grep -i telegram | sed 's/^/    /'

###########################################################################
# 4. Проверяем что mycarmibot тоже жив
###########################################################################
echo ""
echo "[4/4] Проверяю все сервисы..."

echo "  Порты:"
ss -tlnp | grep -E "1878|1879|:443 |:80 " | while read line; do echo "    $line"; done

echo ""
echo "  Процессы:"
ps aux | grep -E "[o]penclaw.*gateway" | awk '{print "    PID "$2": "$11" "$12" "$13}'

echo ""
if ! ss -tlnp | grep -q ":18793 "; then
    echo "  ⚠ @mycarmibot не запущен — запускаю..."
    cd /root/.openclaw-default
    OPENCLAW_HOME=/root/.openclaw-default nohup npx openclaw gateway --port 18793 > /data/logs/gateway-mycarmibot.log 2>&1 &
    sleep 10
    ss -tlnp | grep -q ":18793 " && echo "  ✓ @mycarmibot ACTIVE" || echo "  ✗ не запустился"
else
    echo "  ✓ @mycarmibot ACTIVE (порт 18793)"
fi

REMOTE_END

echo ""
echo "=========================================="
echo "  ПРОВЕРЬ:"
echo "  1. Напиши @mycarmi_moa_bot в Telegram: Привет"
echo "  2. Web UI: http://127.0.0.1:18789 (если туннель жив)"
echo "  Оба должны работать параллельно"
echo "=========================================="
