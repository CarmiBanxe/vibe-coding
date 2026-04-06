#!/bin/bash
###############################################################################
# fix-all-broken-configs.sh — Чистка ВСЕХ сломанных конфигов OpenClaw
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-all-broken-configs.sh
#
# Проблема: OpenClaw сканирует ВСЕ profile-директории при запуске.
#   Даже если moa-бот в /opt/openclaw чистый, сломанные конфиги в
#   ~/.openclaw-default и ~/.openclaw-moa вызывают ошибки.
#
# Ошибки найдены в:
#   1. ~/.openclaw-default/.openclaw/openclaw.json:
#      - agents.defaults: Unrecognized key: "systemPrompt"
#      - <root>: Unrecognized key: "systemPrompt"
#   2. ~/.openclaw-moa/openclaw.json:
#      - agents.defaults.models.default: Invalid input
#      - agents.defaults: Unrecognized key: "systemPrompt"
#      - tools: Unrecognized key: "gateway"
#      - <root>: Unrecognized keys: "configWrites", "provider", "systemPrompt"
#
# Что делает:
#   1. Бэкапит все конфиги
#   2. Удаляет неподдерживаемые ключи из каждого
#   3. Запускает openclaw doctor для проверки
#   4. Перезапускает gateway
###############################################################################

echo "=========================================="
echo "  ЧИСТКА ВСЕХ СЛОМАННЫХ КОНФИГОВ"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

BACKUP_TS=$(date +%Y%m%d-%H%M%S)

# Все конфиги которые OpenClaw может найти
# OpenClaw ищет: ~/.openclaw-*/openclaw.json И ~/.openclaw-*/.openclaw/openclaw.json
# Также в HOME пользователя openclaw

echo ""
echo "[1/4] Ищу ВСЕ конфиги OpenClaw..."
echo ""

CONFIGS=()
for home_dir in /root /opt/openclaw /home/mmber /home/ctio; do
    for pattern in \
        "$home_dir/.openclaw*/openclaw.json" \
        "$home_dir/.openclaw*/.openclaw/openclaw.json"; do
        for f in $pattern; do
            if [ -f "$f" ]; then
                CONFIGS+=("$f")
                echo "  Найден: $f ($(du -h "$f" | cut -f1))"
            fi
        done
    done
done

echo ""
echo "  Всего конфигов: ${#CONFIGS[@]}"

echo ""
echo "[2/4] Бэкапы + чистка каждого конфига..."
echo ""

for cfg in "${CONFIGS[@]}"; do
    echo "  ── $cfg ──"
    
    # Бэкап
    cp "$cfg" "${cfg}.bak-clean-${BACKUP_TS}" 2>/dev/null
    echo "    Бэкап: OK"
    
    # Чистка через Python
    python3 << PYEOF
import json, sys

cfg_path = "$cfg"
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except (json.JSONDecodeError, FileNotFoundError) as e:
    print(f"    ✗ Не удалось прочитать: {e}")
    sys.exit(0)

changes = []

# 1. Удаляем root-level неподдерживаемые ключи
root_bad = ["systemPrompt", "configWrites", "provider"]
for k in root_bad:
    if k in cfg:
        del cfg[k]
        changes.append(f"Удалён <root>.{k}")

# 2. Чистим agents.defaults
agents = cfg.get("agents", {})
defaults = agents.get("defaults", {})

# Удаляем systemPrompt из defaults
defaults_bad = ["systemPrompt", "params", "tools"]
for k in defaults_bad:
    if k in defaults:
        del defaults[k]
        changes.append(f"Удалён agents.defaults.{k}")

# Фиксим agents.defaults.models.default если строка вместо объекта
models = defaults.get("models", {})
if isinstance(models, dict):
    for model_name, model_val in list(models.items()):
        if isinstance(model_val, str):
            # Строка вместо объекта — заменяем на пустой объект
            models[model_name] = {}
            changes.append(f"Исправлен agents.defaults.models.{model_name}: string → {{}}")

# 3. Чистим agents.main (если есть — не поддерживается)
if "main" in agents:
    del agents["main"]
    changes.append("Удалён agents.main")

# 4. Удаляем tools.gateway (не поддерживается)
tools = cfg.get("tools", {})
if "gateway" in tools:
    del tools["gateway"]
    changes.append("Удалён tools.gateway")

# 5. Удаляем tools.deny если есть (может быть старый формат)  
if "deny" in tools:
    del tools["deny"]
    changes.append("Удалён tools.deny")

with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

if changes:
    for ch in changes:
        print(f"    ✓ {ch}")
else:
    print("    · Чистый, изменений нет")
PYEOF
    
    echo ""
done

echo ""
echo "[3/4] Проверяю openclaw doctor..."
echo ""

# Проверяем основной конфиг (moa на /opt/openclaw)
echo "  === /opt/openclaw ==="
cd /opt/openclaw
OPENCLAW_HOME=/opt/openclaw OLLAMA_API_KEY=ollama-local \
    npx openclaw doctor 2>&1 | grep -E "warning|error|problem|invalid|Unrecognized|✓|✗" | head -10 | sed 's/^/    /'

echo ""

# Проверяем default конфиг
if [ -d "/root/.openclaw-default" ]; then
    echo "  === /root/.openclaw-default ==="
    cd /root/.openclaw-default
    OPENCLAW_HOME=/root/.openclaw-default OLLAMA_API_KEY=ollama-local \
        npx openclaw doctor 2>&1 | grep -E "warning|error|problem|invalid|Unrecognized|✓|✗" | head -10 | sed 's/^/    /'
fi

echo ""
echo "[4/4] Перезапускаю gateway..."

systemctl stop openclaw-gateway-moa 2>/dev/null
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

systemctl start openclaw-gateway-moa 2>/dev/null
sleep 20

echo ""
if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ЗАПУЩЕН (порт 18789)"
    ps aux | grep -E "[o]penclaw.*gate" | awk '{print "    User: "$1", PID: "$2}' | head -1
    
    echo ""
    echo "  Лог (последние 10 строк):"
    for logpath in \
        /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log \
        /data/logs/gateway-moa.log; do
        if [ -f "$logpath" ]; then
            tail -10 "$logpath" 2>/dev/null | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    try:
        d = json.loads(line)
        msg = d.get('0','')
        level = d.get('_meta',{}).get('logLevelName','')
        time = d.get('time','')[:19]
        if msg:
            print(f'    [{level}] {time} {msg[:100]}')
    except:
        print(f'    {line[:120]}')
" 2>/dev/null
            break
        fi
    done
    
    echo ""
    echo "  Ошибки после перезапуска:"
    for logpath in /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log /data/logs/gateway-moa.log; do
        if [ -f "$logpath" ]; then
            grep -c "Config invalid" "$logpath" 2>/dev/null | xargs -I{} echo "    Config invalid: {} раз"
            grep -c "Unrecognized" "$logpath" 2>/dev/null | xargs -I{} echo "    Unrecognized key: {} раз"
            grep -c "EACCES" "$logpath" 2>/dev/null | xargs -I{} echo "    EACCES: {} раз"
            break
        fi
    done
else
    echo "  ✗ Gateway НЕ запустился"
    journalctl -u openclaw-gateway-moa --no-pager -n 15 | tail -10 | sed 's/^/    /'
fi

REMOTE

echo ""
echo "=========================================="
echo "  Напиши боту: Кто ты?"
echo "=========================================="
