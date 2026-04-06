#!/bin/bash
###############################################################################
# fix-config-and-restart.sh — Починка конфига + перезапуск gateway
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-config-and-restart.sh
#
# Проблема:
#   - upgrade-bot-prompts.sh добавил agents.main — OpenClaw не понимает
#   - Telegram token пропал из конфига
#
# Что делает:
#   1. Бэкапит текущий сломанный конфиг
#   2. Показывает текущий конфиг (для диагностики)
#   3. Восстанавливает из последнего рабочего бэкапа
#   4. Если бэкапа нет — фиксит конфиг через Python
#   5. Перезапускает gateway
###############################################################################

echo "=========================================="
echo "  ПОЧИНКА КОНФИГА openclaw.json"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'
export PATH="$PATH:/root/.local/bin:/usr/local/bin"

CFG="/root/.openclaw-moa/.openclaw/openclaw.json"
BACKUP_TS=$(date +%Y%m%d-%H%M%S)

echo ""
echo "============================================"
echo "  ШАГ 1: Текущий конфиг (для анализа)"
echo "============================================"
echo ""

if [ -f "$CFG" ]; then
    echo "  Размер: $(du -h "$CFG" | cut -f1)"
    echo ""
    echo "  --- ПОЛНЫЙ КОНФИГ ---"
    cat "$CFG" | python3 -m json.tool 2>/dev/null | sed 's/^/    /' || cat "$CFG" | sed 's/^/    /'
    echo ""
    echo "  --- КОНЕЦ КОНФИГА ---"
else
    echo "  ✗ Конфиг не найден!"
fi

echo ""
echo "============================================"
echo "  ШАГ 2: Ищу рабочие бэкапы"
echo "============================================"
echo ""

echo "  Все бэкапы конфига:"
ls -la /root/.openclaw-moa/.openclaw/openclaw.json.bak* 2>/dev/null | sed 's/^/    /' || echo "    (бэкапов нет)"
echo ""

# Ищем последний бэкап ДО скрипта upgrade-bot-prompts
LAST_GOOD=""
for f in $(ls -t /root/.openclaw-moa/.openclaw/openclaw.json.bak* 2>/dev/null); do
    # Проверяем: содержит ли бэкап ключ "main" в agents?
    if python3 -c "
import json
with open('$f') as fh:
    c = json.load(fh)
agents = c.get('agents', {})
if 'main' in agents:
    exit(1)  # Этот тоже сломан
# Проверяем есть ли telegram token
import sys
cfg_str = json.dumps(c)
if 'telegram' in cfg_str.lower() and ('8793039199' in cfg_str or 'AAG' in cfg_str):
    exit(0)  # Хороший — есть telegram
exit(2)  # Нет telegram
" 2>/dev/null; then
        LAST_GOOD="$f"
        echo "  ✓ Рабочий бэкап найден: $f"
        break
    fi
done

echo ""
echo "============================================"
echo "  ШАГ 3: Бэкап сломанного конфига"
echo "============================================"
echo ""

cp "$CFG" "${CFG}.bak-broken-${BACKUP_TS}"
echo "  ✓ Бэкап: ${CFG}.bak-broken-${BACKUP_TS}"

echo ""
echo "============================================"
echo "  ШАГ 4: Восстановление конфига"
echo "============================================"
echo ""

if [ -n "$LAST_GOOD" ]; then
    echo "  Восстанавливаю из бэкапа: $LAST_GOOD"
    cp "$LAST_GOOD" "$CFG"
    echo "  ✓ Конфиг восстановлен из бэкапа"
    echo ""
    echo "  Восстановленный конфиг:"
    cat "$CFG" | python3 -m json.tool 2>/dev/null | sed 's/^/    /'
else
    echo "  Рабочий бэкап не найден — починю текущий конфиг через Python"
    echo ""
    
    python3 << 'PYFIX'
import json

cfg_path = "/root/.openclaw-moa/.openclaw/openclaw.json"

with open(cfg_path) as f:
    cfg = json.load(f)

changes = []

# 1. Удаляем agents.main (OpenClaw не понимает этот ключ)
agents = cfg.get("agents", {})
if "main" in agents:
    del agents["main"]
    changes.append("Удалён agents.main (Unrecognized key)")

# 2. Удаляем agents.defaults если пуст или с неподдерживаемыми ключами
defaults = agents.get("defaults", {})
unsupported = ["systemPrompt", "params", "tools"]
for k in unsupported:
    if k in defaults:
        del defaults[k]
        changes.append(f"Удалён agents.defaults.{k}")

# 3. Удаляем promptVersion если есть
if "promptVersion" in agents.get("main", {}):
    changes.append("Удалён promptVersion")

# Если agents пуст — удаляем
if not agents or (len(agents) == 1 and "defaults" in agents and not agents["defaults"]):
    # Оставляем defaults с model если есть
    pass

# 4. Проверяем Telegram token
# Ищем token в любом месте конфига
cfg_str = json.dumps(cfg)
has_telegram = "telegram" in cfg_str.lower() and "token" in cfg_str.lower()

if not has_telegram:
    changes.append("ВНИМАНИЕ: Telegram token ОТСУТСТВУЕТ — нужно добавить!")
    print("  ⚠ Telegram token не найден в конфиге!")
    print("  Нужно запустить: openclaw config")
    print("  Или добавить вручную")

with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

for ch in changes:
    print(f"  ✓ {ch}")

print()
print("  Исправленный конфиг:")
with open(cfg_path) as f:
    for line in f:
        print(f"    {line}", end="")
PYFIX
fi

echo ""
echo "============================================"
echo "  ШАГ 5: Проверяю openclaw doctor"
echo "============================================"
echo ""

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa npx openclaw doctor 2>&1 | head -30 | sed 's/^/    /'

echo ""
echo "============================================"
echo "  ШАГ 6: Telegram token — проверяю/добавляю"
echo "============================================"
echo ""

# Проверяем наличие token
HAS_TOKEN=$(python3 -c "
import json
with open('$CFG') as f:
    c = json.load(f)
s = json.dumps(c)
print('YES' if '8793039199' in s else 'NO')
" 2>/dev/null)

if [ "$HAS_TOKEN" = "YES" ]; then
    echo "  ✓ Telegram token присутствует в конфиге"
else
    echo "  ✗ Telegram token ОТСУТСТВУЕТ!"
    echo ""
    echo "  Пробую добавить через openclaw config..."
    
    # Пробуем через config set
    cd /root/.openclaw-moa
    OPENCLAW_HOME=/root/.openclaw-moa npx openclaw config set interfaces.telegram.token "8793039199:AAGj2RrwI1ShQlNbKCsXl3IMpbs3hWMTPAo" 2>&1 | sed 's/^/    /' || true
    
    # Если не сработало — добавляем через Python
    HAS_TOKEN2=$(python3 -c "
import json
with open('$CFG') as f:
    c = json.load(f)
s = json.dumps(c)
print('YES' if '8793039199' in s else 'NO')
" 2>/dev/null)
    
    if [ "$HAS_TOKEN2" != "YES" ]; then
        echo "  openclaw config не сработал — добавляю через Python..."
        python3 << 'PYTG'
import json

cfg_path = "/root/.openclaw-moa/.openclaw/openclaw.json"
with open(cfg_path) as f:
    cfg = json.load(f)

# Добавляем interfaces.telegram
if "interfaces" not in cfg:
    cfg["interfaces"] = {}
if "telegram" not in cfg["interfaces"]:
    cfg["interfaces"]["telegram"] = {}

cfg["interfaces"]["telegram"]["token"] = "8793039199:AAGj2RrwI1ShQlNbKCsXl3IMpbs3hWMTPAo"

with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print("  ✓ Telegram token добавлен через Python")
PYTG
    fi
    
    echo ""
    echo "  Конфиг после добавления token:"
    cat "$CFG" | python3 -m json.tool 2>/dev/null | sed 's/^/    /'
fi

echo ""
echo "============================================"
echo "  ШАГ 7: Финальная проверка конфига"
echo "============================================"
echo ""

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa npx openclaw doctor 2>&1 | head -20 | sed 's/^/    /'

echo ""
echo "============================================"
echo "  ШАГ 8: Перезапуск gateway"
echo "============================================"
echo ""

pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa \
OLLAMA_API_KEY=ollama-local \
nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
GW_PID=$!
echo "  Запущен PID: $GW_PID"
echo "  Жду 20 секунд..."
sleep 20

echo ""
if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ЗАПУЩЕН! Порт 18789 слушает"
    echo ""
    echo "  Лог (последние 15 строк):"
    tail -15 /data/logs/gateway-moa.log | sed 's/^/    /'
    echo ""
    echo "  Процесс:"
    pgrep -fa "openclaw" | sed 's/^/    /'
else
    echo "  ✗ Gateway НЕ запустился"
    echo ""
    echo "  ПОЛНЫЙ лог:"
    cat /data/logs/gateway-moa.log | sed 's/^/    /'
fi

REMOTE

echo ""
echo "=========================================="
echo "  ИТОГ"
echo "=========================================="
echo ""
echo "  Если увидел ✓ Gateway ЗАПУЩЕН — напиши боту: Привет, кто ты?"
echo "  Если ✗ — скинь мне вывод, будем разбираться дальше"
echo "=========================================="
