#!/bin/bash
###############################################################################
# fix-ollama-auth.sh — Регистрация Ollama auth в OpenClaw
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-ollama-auth.sh
#
# Проблема: "Ollama requires authentication to be registered as a provider"
# Решение: openclaw models auth set + OLLAMA_API_KEY в environment
###############################################################################

echo "=========================================="
echo "  РЕГИСТРАЦИЯ OLLAMA AUTH"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

echo "[1/5] Останавливаю gateway..."
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

echo "[2/5] Читаю документацию OpenClaw по Ollama..."
# По docs.openclaw.ai/providers/ollama:
# Нужно либо OLLAMA_API_KEY env var, либо openclaw configure

echo "[3/5] Регистрирую Ollama через configure..."
cd /root/.openclaw-moa
export OPENCLAW_HOME=/root/.openclaw-moa
export OLLAMA_API_KEY="ollama-local"

# Пробуем разные CLI команды для регистрации auth
echo "  Пробую: models auth set ollama..."
npx openclaw models auth set ollama 2>&1 | head -5 | sed 's/^/    /'

echo "  Пробую: models auth add ollama..."
npx openclaw models auth add ollama --api-key "ollama-local" 2>&1 | head -5 | sed 's/^/    /'

echo "  Пробую: models register ollama..."
npx openclaw models register ollama --base-url "http://localhost:11434" 2>&1 | head -5 | sed 's/^/    /'

# Прямая правка auth-profiles.json
echo ""
echo "[4/5] Прямая правка auth-profiles.json..."

AUTH_FILE="/root/.openclaw-moa/.openclaw/agents/main/agent/auth-profiles.json"
if [ -f "$AUTH_FILE" ]; then
    python3 << 'PYFIX'
import json

auth_path = "/root/.openclaw-moa/.openclaw/agents/main/agent/auth-profiles.json"
with open(auth_path) as f:
    auth = json.load(f)

# Добавляем Ollama провайдер
if "ollama" not in auth:
    auth["ollama"] = {
        "ollama:local": {
            "type": "token",
            "token": "ollama-local"
        }
    }
    print("  ✓ Добавлен ollama:local в auth-profiles.json")
else:
    print(f"  Ollama уже есть: {list(auth['ollama'].keys())}")

# Также добавляем huihui_ai если нет
if "huihui_ai" not in auth:
    auth["huihui_ai"] = {
        "huihui_ai:local": {
            "type": "token",
            "token": "ollama-local"
        }
    }
    print("  ✓ Добавлен huihui_ai:local в auth-profiles.json")

with open(auth_path, "w") as f:
    json.dump(auth, f, indent=2)

print(f"  Провайдеры в auth: {list(auth.keys())}")
PYFIX
else
    echo "  ✗ auth-profiles.json не найден: $AUTH_FILE"
    echo "  Создаю..."
    mkdir -p "$(dirname "$AUTH_FILE")"
    cat > "$AUTH_FILE" << 'AUTHJSON'
{
  "anthropic": {
    "anthropic:default": {
      "type": "token",
      "token": ""
    }
  },
  "ollama": {
    "ollama:local": {
      "type": "token",
      "token": "ollama-local"
    }
  },
  "huihui_ai": {
    "huihui_ai:local": {
      "type": "token",
      "token": "ollama-local"
    }
  }
}
AUTHJSON
    echo "  ✓ auth-profiles.json создан"
fi

# Также добавляем Ollama в models.json если есть
MODELS_FILE="/root/.openclaw-moa/.openclaw/agents/main/agent/models.json"
if [ -f "$MODELS_FILE" ]; then
    python3 << 'PYFIX2'
import json

models_path = "/root/.openclaw-moa/.openclaw/agents/main/agent/models.json"
with open(models_path) as f:
    models = json.load(f)

# Добавляем Ollama модель
ollama_key = "ollama/huihui_ai/qwen3.5-abliterated:35b"
if ollama_key not in models:
    models[ollama_key] = {
        "providerId": "ollama",
        "baseUrl": "http://localhost:11434",
        "apiKey": "ollama-local"
    }
    print(f"  ✓ {ollama_key} добавлена в models.json")
else:
    print(f"  Модель уже в models.json")

with open(models_path, "w") as f:
    json.dump(models, f, indent=2)

print(f"  Модели в models.json: {list(models.keys())}")
PYFIX2
fi

echo ""
echo "[5/5] Запускаю gateway с OLLAMA_API_KEY..."

cd /root/.openclaw-moa
export OPENCLAW_HOME=/root/.openclaw-moa
export OLLAMA_API_KEY="ollama-local"
nohup env OLLAMA_API_KEY="ollama-local" npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 15 секунд..."
sleep 15

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ACTIVE"
else
    echo "  ✗ Не запустился"
    tail -5 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'
fi

echo ""
echo "  Модель:"
grep "agent model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

echo ""
echo "  Telegram:"
grep "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -2 | sed 's/^/    /'

echo ""
echo "  Ошибки Ollama:"
grep -i "ollama\|unknown model\|auth" /data/logs/gateway-moa.log 2>/dev/null | tail -3 | sed 's/^/    /'

REMOTE_END

echo ""
echo "=========================================="
echo "  Проверь: напиши @mycarmi_moa_bot Привет"
echo "=========================================="
