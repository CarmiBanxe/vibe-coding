#!/bin/bash
###############################################################################
# fix-model-ollama.sh — Возврат модели на Ollama + полная диагностика конфига
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-model-ollama.sh
#
# Проблема: бот переключился на anthropic/claude-sonnet-4-6 (облако)
# Решение: вернуть ollama/huihui_ai/qwen3.5-abliterated:35b (локально)
#
# Также:
#   - Проверяет и исправляет ВСЕ параметры конфига
#   - Убеждается что channels.telegram работает
#   - Убеждается что system prompt на месте
#   - Перезапускает gateway
#   - dangerouslyDisableDeviceAuth → false
###############################################################################

echo "=========================================="
echo "  ВОЗВРАТ НА OLLAMA + ПОЛНАЯ РЕВИЗИЯ"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'
export PATH="$PATH:/root/.local/bin"

###########################################################################
# 1. Диагностика — что сейчас в конфиге
###########################################################################
echo "[1/5] Текущее состояние конфига..."

python3 << 'DIAG'
import json

for name, path in [
    ("MoA (.openclaw)", "/root/.openclaw-moa/.openclaw/openclaw.json"),
    ("MoA (root)", "/root/.openclaw-moa/openclaw.json"),
]:
    try:
        with open(path) as f:
            c = json.load(f)
        
        # Модель
        agents = c.get("agents", {})
        defaults = agents.get("defaults", {})
        models = defaults.get("models", {})
        model = models.get("default", "НЕ ЗАДАНА")
        
        # Provider
        provider = c.get("provider", {})
        
        # Channels
        channels = c.get("channels", {})
        
        # Gateway
        gw = c.get("gateway", {})
        cui = gw.get("controlUi", {})
        
        print(f"\n  {name}:")
        print(f"    model: {model}")
        print(f"    provider.api: {provider.get('api', 'НЕТ')}")
        print(f"    provider.baseUrl: {provider.get('baseUrl', 'НЕТ')}")
        print(f"    channels type: {type(channels).__name__}")
        if isinstance(channels, dict) and "telegram" in channels:
            tg = channels["telegram"]
            print(f"    telegram.botToken: {tg.get('botToken','НЕТ')[:20]}...")
            print(f"    telegram.dmPolicy: {tg.get('dmPolicy','НЕТ')}")
        print(f"    gateway.auth.token: {gw.get('auth',{}).get('token','НЕТ')[:16]}...")
        print(f"    controlUi.dangerouslyDisableDeviceAuth: {cui.get('dangerouslyDisableDeviceAuth','НЕТ')}")
        print(f"    systemPrompt: {'есть (' + str(len(defaults.get('systemPrompt','') or c.get('systemPrompt',''))) + ' символов)' if (defaults.get('systemPrompt') or c.get('systemPrompt')) else 'НЕТ'}")
    except Exception as e:
        print(f"\n  {name}: ОШИБКА — {e}")
DIAG

###########################################################################
# 2. Исправляем конфиг — модель + все параметры
###########################################################################
echo ""
echo "[2/5] Исправляю конфиг..."

# Исправляем оба конфига
for CFG in \
    "/root/.openclaw-moa/.openclaw/openclaw.json" \
    "/root/.openclaw-moa/openclaw.json"; do
    
    [ ! -f "$CFG" ] && continue
    
    # Бэкап
    cp "$CFG" "${CFG}.bak-model-$(date +%Y%m%d-%H%M)"
    
    python3 << PYFIX
import json

cfg_path = "$CFG"
with open(cfg_path) as f:
    cfg = json.load(f)

changes = []

# === МОДЕЛЬ: Ollama direct ===
agents = cfg.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
models = defaults.setdefault("models", {})

old_model = models.get("default", "?")
models["default"] = "ollama/huihui_ai/qwen3.5-abliterated:35b"
if old_model != "ollama/huihui_ai/qwen3.5-abliterated:35b":
    changes.append(f"model: {old_model} → ollama/huihui_ai/qwen3.5-abliterated:35b")

# === PROVIDER: прямой Ollama ===
cfg["provider"] = {
    "api": "ollama",
    "baseUrl": "http://localhost:11434"
}
changes.append("provider: ollama @ localhost:11434")

# === SYSTEM PROMPT ===
SYSTEM_PROMPT = """Ты — CTIO проекта Banxe AI Bank (EMI, FCA authorised).
CEO — Moriel Carmi (@bereg2022, Telegram ID: 508602494).

ВАЖНО: При КАЖДОМ ответе ты ОБЯЗАН прочитать эти файлы из своего workspace:
1. MEMORY.md — твоя память (кто ты, инфраструктура, инструменты, история, план)
2. SYSTEM-STATE.md — актуальное состояние сервера (сервисы, порты, модели, таблицы)

Используй данные из этих файлов для точных, актуальных ответов.
Для поиска в интернете используй Brave Search API (ключ в MEMORY.md).
Для локального поиска используй Deep Search (порт 8088).

Отвечай на русском. Будь конкретен и полезен.
Не выполняй команд на сервере — ты read-only observer."""

defaults["systemPrompt"] = SYSTEM_PROMPT
cfg["systemPrompt"] = SYSTEM_PROMPT
changes.append("systemPrompt обновлён")

# === ПАРАМЕТРЫ МОДЕЛИ (в правильном месте для Ollama) ===
# Для Ollama params идут через provider options, не через agents.defaults
# Но system prompt передаём через defaults
# num_ctx и num_predict передаются как опции Ollama

# === CHANNELS: проверяем telegram ===
channels = cfg.get("channels", {})
if isinstance(channels, dict) and "telegram" in channels:
    tg = channels["telegram"]
    # Проверяем токен
    if not tg.get("botToken") or "AAGj2Rrw" not in tg.get("botToken", ""):
        tg["botToken"] = "8793039199:AAGj2RrwI1ShQlNbKCsXl3IMpbs3hWMTPAo"
        changes.append("telegram.botToken обновлён")
    # dmPolicy
    if tg.get("dmPolicy") != "allowlist":
        tg["dmPolicy"] = "allowlist"
    # allowFrom
    if 508602494 not in tg.get("allowFrom", []) and "508602494" not in [str(x) for x in tg.get("allowFrom", [])]:
        tg["allowFrom"] = [508602494]
    # streaming off
    tg["streaming"] = "off"

# === GATEWAY: вернуть безопасные настройки ===
gw = cfg.setdefault("gateway", {})
cui = gw.setdefault("controlUi", {})
if cui.get("dangerouslyDisableDeviceAuth") == True:
    cui["dangerouslyDisableDeviceAuth"] = False
    changes.append("dangerouslyDisableDeviceAuth → false")

# === DISCOVERY: mdns off ===
cfg.setdefault("discovery", {}).setdefault("mdns", {})["mode"] = "off"

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

short_name = cfg_path.split("/")[-1]
if cfg_path.count(".openclaw") > 1:
    short_name = ".openclaw/" + short_name
print(f"  ✓ {short_name}:")
for c in changes:
    print(f"      {c}")
PYFIX
done

###########################################################################
# 3. Проверяем Ollama
###########################################################################
echo ""
echo "[3/5] Проверяю Ollama..."

if curl -s --max-time 5 http://localhost:11434/api/tags > /dev/null 2>&1; then
    MODELS=$(curl -s http://localhost:11434/api/tags | python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d.get('models',[]):
    print(f'    {m[\"name\"]} ({m[\"size\"]/1024**3:.1f}GB)')
" 2>/dev/null)
    echo "  ✓ Ollama ACTIVE"
    echo "  Модели:"
    echo "$MODELS"
else
    echo "  ✗ Ollama не отвечает!"
fi

###########################################################################
# 4. Перезапускаем gateway
###########################################################################
echo ""
echo "[4/5] Перезапускаю gateway..."

pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 5

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 15 секунд..."
sleep 15

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ACTIVE (порт 18789)"
else
    echo "  ✗ Не запустился. Лог:"
    tail -10 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'
fi

# Лог Telegram
echo ""
echo "  Telegram:"
grep -i "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -3 | sed 's/^/    /'

# Модель в логе
echo ""
echo "  Модель в логе:"
grep -i "agent model\|default model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

###########################################################################
# 5. Запускаем mycarmibot тоже
###########################################################################
echo ""
echo "[5/5] Запускаю @mycarmibot..."

if ! ss -tlnp | grep -q ":18793 "; then
    cd /root/.openclaw-default
    OPENCLAW_HOME=/root/.openclaw-default nohup npx openclaw gateway --port 18793 > /data/logs/gateway-mycarmibot.log 2>&1 &
    sleep 10
    ss -tlnp | grep -q ":18793 " && echo "  ✓ @mycarmibot ACTIVE" || echo "  ⚠ Не запустился"
else
    echo "  ✓ @mycarmibot уже ACTIVE"
fi

echo ""
echo "  Все порты:"
ss -tlnp | grep -E "1878|1879" | while read line; do echo "    $line"; done

REMOTE_END

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "  Модель: ollama/huihui_ai/qwen3.5-abliterated:35b (локально)"
echo "  dangerouslyDisableDeviceAuth: false (безопасно)"
echo ""
echo "  Проверь: напиши @mycarmi_moa_bot в Telegram"
echo '    "Какая у тебя модель?"'
