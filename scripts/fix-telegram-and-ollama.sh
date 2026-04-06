#!/bin/bash
###############################################################################
# fix-telegram-and-ollama.sh — Полная починка: конфиг + Ollama + Telegram
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-telegram-and-ollama.sh
###############################################################################

echo "=========================================="
echo "  ПОЛНАЯ ПОЧИНКА БОТА"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export OLLAMA_API_KEY="ollama-local"

echo "[1/6] Убиваю всё..."
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

echo "[2/6] Показываю текущий конфиг channels..."
python3 << 'PY'
import json
cfg = json.load(open("/root/.openclaw-moa/.openclaw/openclaw.json"))
ch = cfg.get("channels")
print(f"  тип: {type(ch).__name__}")
print(f"  содержимое: {json.dumps(ch, indent=2, ensure_ascii=False)[:500]}")
PY

echo ""
echo "[3/6] Смотрю как channels был в рабочем состоянии..."
# Читаем openclaw.json (корневой — тот что onboard не трогал)
python3 << 'PY2'
import json
cfg = json.load(open("/root/.openclaw-moa/openclaw.json"))
ch = cfg.get("channels")
print(f"  корневой тип: {type(ch).__name__}")
print(f"  содержимое: {json.dumps(ch, indent=2, ensure_ascii=False)[:500]}")
PY2

echo ""
echo "[4/6] Восстанавливаю channels + запуск напрямую..."

# Читаем текущий конфиг
python3 << 'PYFIX'
import json

cfg_path = "/root/.openclaw-moa/.openclaw/openclaw.json"
with open(cfg_path) as f:
    cfg = json.load(f)

# Показываем все ключи
print(f"  Все ключи: {list(cfg.keys())}")

# Проверяем channels — onboard мог поставить свой формат
ch = cfg.get("channels")
if isinstance(ch, dict) and "telegram" in ch:
    tg = ch["telegram"]
    print(f"  telegram.botToken: {tg.get('botToken','НЕТ')[:20]}...")
    print(f"  telegram.enabled: {tg.get('enabled','?')}")
    # Убеждаемся что всё на месте
    tg["botToken"] = "8793039199:AAGj2RrwI1ShQlNbKCsXl3IMpbs3hWMTPAo"
    tg["enabled"] = True
    tg["dmPolicy"] = "allowlist"
    tg["allowFrom"] = [508602494]
    tg["streaming"] = "off"
    print("  ✓ channels.telegram обновлён")
elif isinstance(ch, list):
    print(f"  channels = list ({len(ch)} элементов)")
    # Ищем telegram в списке
    found = False
    for item in ch:
        if isinstance(item, dict) and (item.get("type") == "telegram" or item.get("botToken")):
            item["botToken"] = "8793039199:AAGj2RrwI1ShQlNbKCsXl3IMpbs3hWMTPAo"
            item["enabled"] = True
            item["dmPolicy"] = "allowlist"
            item["allowFrom"] = [508602494]
            found = True
            print("  ✓ telegram в списке обновлён")
    if not found:
        ch.append({
            "type": "telegram",
            "botToken": "8793039199:AAGj2RrwI1ShQlNbKCsXl3IMpbs3hWMTPAo",
            "enabled": True,
            "dmPolicy": "allowlist",
            "allowFrom": [508602494],
            "streaming": "off"
        })
        print("  ✓ telegram добавлен в список")
elif ch is None:
    # channels отсутствуют — onboard мог удалить
    cfg["channels"] = {
        "telegram": {
            "botToken": "8793039199:AAGj2RrwI1ShQlNbKCsXl3IMpbs3hWMTPAo",
            "enabled": True,
            "dmPolicy": "allowlist",
            "allowFrom": [508602494],
            "groupPolicy": "allowlist",
            "streaming": "off"
        }
    }
    print("  ✓ channels создан с нуля")
else:
    print(f"  ⚠ channels неизвестного формата: {type(ch)}")

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print("  ✓ Конфиг сохранён")
PYFIX

echo ""
echo "[5/6] Запускаю gateway и жду полный лог..."

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa OLLAMA_API_KEY="ollama-local" npx openclaw gateway --port 18789 2>&1 | head -25

echo ""
echo "[6/6] Если дошли сюда — gateway остановился. Запускаю в фоне..."
OPENCLAW_HOME=/root/.openclaw-moa OLLAMA_API_KEY="ollama-local" nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
sleep 15

echo "  Gateway:"
ss -tlnp | grep 18789 | head -1 | sed 's/^/    /' || echo "    НЕ СЛУШАЕТ"

echo "  Telegram в логе:"
grep -i "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -5 | sed 's/^/    /'

REMOTE_END
