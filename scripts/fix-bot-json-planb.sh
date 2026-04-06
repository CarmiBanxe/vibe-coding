#!/usr/bin/env bash
# ============================================================
#  fix-bot-json-planb.sh — ПЛАН Б: Обход LiteLLM
# ============================================================
#  Если fix-bot-json.sh не помог и бот всё ещё отвечает
#  сырым JSON — этот скрипт ОБХОДИТ LiteLLM полностью
#  и подключает OpenClaw НАПРЯМУЮ к Groq API.
#
#  Что делает:
#  1. Останавливает бота
#  2. Меняет groq провайдер:
#     - baseUrl: https://api.groq.com/openai/v1 (напрямую!)
#     - apiKey: настоящий Groq ключ
#     - модель: llama-3.3-70b-versatile
#  3. Очищает сессии
#  4. Перезапускает бота
#
#  LiteLLM остаётся запущенным — он нужен для ollama моделей.
#  Но groq провайдер теперь идёт напрямую через Groq API.
# ============================================================
set -euo pipefail

CONF="/home/mmber/.openclaw-moa/openclaw.json"
SESSIONS_DIR="/home/mmber/.openclaw-moa/agents/main/sessions"
WORKSPACES_DIR="/home/mmber/.openclaw-moa/agents/main/workspaces"
# Groq ключ берём из LiteLLM конфига автоматически
GROQ_KEY=$(grep -oP 'GROQ_API_KEY:\s*\K\S+' /home/mmber/litellm-config.yaml 2>/dev/null || echo "")
if [ -z "$GROQ_KEY" ]; then
    echo "✗ Не удалось найти GROQ_API_KEY в litellm-config.yaml"
    echo "  Укажи ключ вручную: export GROQ_KEY=gsk_..."
    exit 1
fi

echo "============================================"
echo "  ПЛАН Б: Обход LiteLLM → прямое Groq API"
echo "============================================"
echo ""

# ── Шаг 1: Остановить бота ───────────────────────────────
echo "── Шаг 1: Останавливаем бота ──"
systemctl --user stop openclaw-gateway-moa.service 2>/dev/null || true
pkill -f "openclaw" 2>/dev/null || true
sleep 2
echo "  ✓ Бот остановлен"
echo ""

# ── Шаг 2: Бэкап ────────────────────────────────────────
echo "── Шаг 2: Бэкап конфига ──"
cp "$CONF" "${CONF}.bak-planb-$(date +%H%M%S)"
echo "  ✓ Бэкап создан"
echo ""

# ── Шаг 3: Перенастроить провайдер на прямой Groq API ────
echo "── Шаг 3: Переключаем groq → прямой Groq API ──"
echo ""
echo "  БЫЛО: groq → LiteLLM (127.0.0.1:8080) → Groq API"
echo "  СТАЛО: groq → Groq API напрямую (api.groq.com)"
echo ""

python3 << PYEOF
import json, subprocess

CONF = "/home/mmber/.openclaw-moa/openclaw.json"
# Читаем ключ напрямую из litellm конфига (без bash подстановки)
with open("/home/mmber/litellm-config.yaml") as kf:
    for line in kf:
        if "GROQ_API_KEY" in line and ":" in line:
            GROQ_KEY = line.split(":", 1)[1].strip().strip('"').strip("'")
            break
    else:
        GROQ_KEY = ""

with open(CONF) as f:
    c = json.load(f)

providers = c.get("models", {}).get("providers", {})

# Перенастроить groq провайдер
if "groq" in providers:
    old_url = providers["groq"].get("baseUrl", "не указан")
    
    # Новые настройки — прямой Groq API
    providers["groq"]["baseUrl"] = "https://api.groq.com/openai/v1"
    providers["groq"]["apiKey"] = GROQ_KEY
    providers["groq"]["api"] = "openai-completions"
    
    # Обновить модели — правильное имя для прямого Groq API
    if "models" in providers["groq"]:
        for model in providers["groq"]["models"]:
            # Groq API ожидает полное имя модели
            if model.get("id") == "llama-3.3-70b":
                model["id"] = "llama-3.3-70b-versatile"
                print(f"  ✓ Модель: llama-3.3-70b → llama-3.3-70b-versatile")
    
    print(f"  ✓ baseUrl: {old_url} → https://api.groq.com/openai/v1")
    print(f"  ✓ apiKey: установлен ({GROQ_KEY[:15]}...)")
    print(f"  ✓ api: openai-completions")
else:
    print("  ✗ Провайдер 'groq' не найден — создаём")
    providers["groq"] = {
        "baseUrl": "https://api.groq.com/openai/v1",
        "apiKey": GROQ_KEY,
        "api": "openai-completions",
        "models": [
            {
                "id": "llama-3.3-70b-versatile",
                "name": "Llama 3.3 70B",
                "reasoning": False,
                "input": ["text"],
                "contextWindow": 128000,
                "maxTokens": 8192
            }
        ]
    }

# Обновить default model если нужно
agents = c.get("agents", {})
defaults = agents.get("defaults", {})
model = defaults.get("model", {})
primary = model.get("primary", "")

if "llama-3.3-70b" in primary and "versatile" not in primary:
    model["primary"] = primary.replace("llama-3.3-70b", "llama-3.3-70b-versatile")
    print(f"  ✓ Default model: {primary} → {model['primary']}")

# Также обновить модели в agents.list
agent_list = agents.get("list", [])
for agent in agent_list:
    agent_model = agent.get("model", "")
    if "llama-3.3-70b" in agent_model and "versatile" not in agent_model:
        agent["model"] = agent_model.replace("llama-3.3-70b", "llama-3.3-70b-versatile")
        print(f"  ✓ Агент '{agent.get('id', '?')}': модель → {agent['model']}")

# Убедиться tools.profile = full
c.setdefault("tools", {})["profile"] = "full"

with open(CONF, 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)

print("  ✓ Конфиг сохранён")
PYEOF
echo ""

# ── Шаг 4: Очистить сессии ───────────────────────────────
echo "── Шаг 4: Очистка сессий ──"
rm -rf "$SESSIONS_DIR"/* 2>/dev/null || true
rm -rf "$WORKSPACES_DIR"/* 2>/dev/null || true
echo "  ✓ Сессии и рабочие пространства очищены"
echo ""

# ── Шаг 5: Тест прямого Groq API ─────────────────────────
echo "── Шаг 5: Тестируем прямой Groq API ──"
RESPONSE=$(curl -sf --max-time 15 https://api.groq.com/openai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${GROQ_KEY}" \
  -d '{
    "model": "llama-3.3-70b-versatile",
    "messages": [
      {"role": "user", "content": "Say hello in Russian, just one sentence"}
    ],
    "max_tokens": 50
  }' 2>&1) || true

if echo "$RESPONSE" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    content = r['choices'][0]['message']['content']
    print(f'  ✓ Groq API ответил: {content[:80]}')
except Exception as e:
    print(f'  ✗ Ошибка парсинга: {e}')
    sys.exit(1)
" 2>/dev/null; then
    echo "  Прямой Groq API работает!"
else
    echo "  ✗ Groq API не ответил. Проверьте интернет и ключ."
    echo "  Ответ: $RESPONSE" | head -3
fi
echo ""

# ── Шаг 6: Запустить бота ────────────────────────────────
echo "── Шаг 6: Запускаем бота ──"
systemctl --user start openclaw-gateway-moa.service
sleep 5

if systemctl --user is-active openclaw-gateway-moa.service > /dev/null 2>&1; then
    echo "  ✓ Бот запущен"
else
    echo "  ⏳ systemd не запустил — пробуем вручную"
    nohup openclaw --profile moa gateway > /tmp/openclaw-planb.log 2>&1 &
    sleep 5
    if pgrep -f "openclaw.*moa" > /dev/null; then
        echo "  ✓ Бот запущен вручную"
    else
        echo "  ✗ Бот не запустился!"
    fi
fi
echo ""

# ── Шаг 7: Показать что получилось ───────────────────────
echo "── Шаг 7: Итоговый конфиг ──"
python3 << 'PYEOF2'
import json
with open("/home/mmber/.openclaw-moa/openclaw.json") as f:
    c = json.load(f)

providers = c.get("models", {}).get("providers", {})
for name, prov in providers.items():
    safe = {}
    for k, v in prov.items():
        if k == "models":
            safe[k] = [m.get("id", "?") for m in v] if isinstance(v, list) else v
        elif k == "apiKey" and isinstance(v, str):
            safe[k] = v[:15] + "..." if len(v) > 15 else v
        else:
            safe[k] = v
    print(f"  {name}: {json.dumps(safe, ensure_ascii=False)}")

model = c.get("agents", {}).get("defaults", {}).get("model", {})
print(f"  Default model: {json.dumps(model, ensure_ascii=False)}")
tools = c.get("tools", {})
print(f"  Tools: {json.dumps(tools, ensure_ascii=False)}")
PYEOF2
echo ""

echo "============================================"
echo "  ПЛАН Б ВЫПОЛНЕН!"
echo ""
echo "  Groq теперь работает НАПРЯМУЮ (без LiteLLM)."
echo "  Напиши боту 'привет' в Telegram."
echo ""
echo "  Если бот ответит нормальным текстом — победа!"
echo "  Если опять JSON — проблема в системном промпте"
echo "  агента, и нужно смотреть файлы в"
echo "  /home/mmber/.openclaw-moa/agents/main/agent/"
echo "============================================"
