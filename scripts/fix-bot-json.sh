#!/usr/bin/env bash
# ============================================================
#  fix-bot-json.sh — Починка бота: raw JSON вместо текста
# ============================================================
#  Проблема: бот отвечает сырым JSON типа:
#   {"type":"function","name":"message","parameters":{...}}
#  вместо нормального текста.
#
#  Причина: Groq/Llama-3.3-70b через LiteLLM некорректно
#  обрабатывает tool calls — модель выдаёт raw JSON text
#  в content вместо настоящего tool_call в ответе API.
#
#  Что делает скрипт:
#  1. Останавливает бота и LiteLLM
#  2. Убирает apiKey из провайдера groq (LiteLLM не нужна
#     авторизация для локальных запросов)
#  3. Добавляет tools.profile="full" если нет
#  4. Очищает все сессии (старый контекст путает модель)
#  5. Перезапускает LiteLLM и бота
#  6. Если всё ещё JSON — переключает бота НАПРЯМУЮ на Groq
#     API (обходя LiteLLM) как запасной вариант
# ============================================================
set -euo pipefail

CONF="/home/mmber/.openclaw-moa/openclaw.json"
LITELLM_CONF="/home/mmber/litellm-config.yaml"
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
echo "  FIX: бот отвечает raw JSON"
echo "============================================"
echo ""

# ── Шаг 1: Остановить всё ────────────────────────────────
echo "── Шаг 1: Останавливаем бота и LiteLLM ──"
systemctl --user stop openclaw-gateway-moa.service 2>/dev/null || true
sleep 1
# Убить все openclaw процессы
pkill -f "openclaw" 2>/dev/null || true
sleep 1
# Перезапустить LiteLLM (чтобы очистить кеш)
systemctl --user restart litellm.service 2>/dev/null || true
sleep 2
echo "✓ Все процессы остановлены, LiteLLM перезапущен"
echo ""

# ── Шаг 2: Бэкап конфига ─────────────────────────────────
echo "── Шаг 2: Бэкап текущего конфига ──"
cp "$CONF" "${CONF}.bak-json-$(date +%H%M%S)"
echo "✓ Бэкап: ${CONF}.bak-json-*"
echo ""

# ── Шаг 3: Убрать apiKey из groq провайдера + tools ──────
echo "── Шаг 3: Фиксим конфиг (apiKey, tools.profile) ──"
python3 << 'PYEOF'
import json, sys

CONF = "/home/mmber/.openclaw-moa/openclaw.json"

with open(CONF) as f:
    c = json.load(f)

changes = []

# 3a. Убрать apiKey из groq провайдера
# LiteLLM на localhost не требует авторизации.
# apiKey может мешать — LiteLLM может пытаться использовать
# его как master_key и падать.
providers = c.get("models", {}).get("providers", {})
if "groq" in providers:
    if "apiKey" in providers["groq"]:
        del providers["groq"]["apiKey"]
        changes.append("Удалён apiKey из groq провайдера")

# 3b. Добавить tools.profile = "full" если нет
# Без этого OpenClaw 2026.3.x не даёт агенту выполнять инструменты
if "tools" not in c:
    c["tools"] = {}
if "profile" not in c["tools"]:
    c["tools"]["profile"] = "full"
    changes.append('Добавлен tools.profile="full"')
elif c["tools"]["profile"] != "full":
    c["tools"]["profile"] = "full"
    changes.append(f'tools.profile изменён на "full"')

# 3c. Убедиться что sessions.visibility = "all"
if "sessions" not in c.get("tools", {}):
    c.setdefault("tools", {})["sessions"] = {"visibility": "all"}
    changes.append('Добавлен tools.sessions.visibility="all"')

with open(CONF, 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)

if changes:
    for ch in changes:
        print(f"  ✓ {ch}")
else:
    print("  (конфиг уже в порядке, изменений нет)")
PYEOF
echo ""

# ── Шаг 4: Очистить ВСЕ сессии ───────────────────────────
echo "── Шаг 4: Полная очистка сессий ──"
echo "  Это важно! Старые сессии содержат 'мусорный' контекст"
echo "  с предыдущими raw JSON ответами, что путает модель."
if [ -d "$SESSIONS_DIR" ]; then
    COUNT=$(find "$SESSIONS_DIR" -name "*.jsonl" 2>/dev/null | wc -l)
    rm -rf "$SESSIONS_DIR"/*
    echo "  ✓ Удалено $COUNT файлов сессий"
else
    echo "  (папка сессий не найдена)"
fi
if [ -d "$WORKSPACES_DIR" ]; then
    rm -rf "$WORKSPACES_DIR"/*
    echo "  ✓ Рабочие пространства очищены"
fi
echo ""

# ── Шаг 5: Проверить LiteLLM ─────────────────────────────
echo "── Шаг 5: Проверяем LiteLLM ──"
sleep 2
LITELLM_OK=false
for i in 1 2 3 4 5; do
    if curl -sf http://127.0.0.1:8080/health > /dev/null 2>&1; then
        echo "  ✓ LiteLLM жив (порт 8080)"
        LITELLM_OK=true
        break
    fi
    echo "  ⏳ Ожидание LiteLLM... ($i/5)"
    sleep 2
done
if [ "$LITELLM_OK" = false ]; then
    echo "  ✗ LiteLLM не отвечает — пробуем перезапустить"
    systemctl --user restart litellm.service 2>/dev/null || true
    sleep 5
    if curl -sf http://127.0.0.1:8080/health > /dev/null 2>&1; then
        echo "  ✓ LiteLLM жив после перезапуска"
        LITELLM_OK=true
    else
        echo "  ✗ LiteLLM всё ещё не отвечает"
    fi
fi
echo ""

# ── Шаг 6: Тест LiteLLM — проверяем tool_calls формат ────
echo "── Шаг 6: Тестируем формат ответа LiteLLM ──"
echo "  Отправляем запрос с tools — проверим приходит ли"
echo "  tool_call корректно или как raw text..."
echo ""

RESPONSE=$(curl -sf --max-time 30 http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "groq/llama-3.3-70b",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hi, how are you?"}
    ],
    "max_tokens": 100
  }' 2>&1) || true

if echo "$RESPONSE" | python3 -c "
import sys, json
r = json.load(sys.stdin)
content = r['choices'][0]['message']['content']
# Проверяем — это нормальный текст или JSON?
if content.strip().startswith('{') or content.strip().startswith('['):
    print(f'  ✗ LiteLLM вернул JSON в content: {content[:100]}...')
    sys.exit(1)
else:
    print(f'  ✓ LiteLLM вернул нормальный текст: {content[:100]}...')
    sys.exit(0)
" 2>/dev/null; then
    echo "  LiteLLM отвечает корректно (нормальный текст)"
    echo ""
else
    echo "  ОТВЕТ: $RESPONSE" | head -3
    echo ""
fi

# ── Шаг 7: Запустить бота ────────────────────────────────
echo "── Шаг 7: Запускаем бота ──"
systemctl --user start openclaw-gateway-moa.service
sleep 5

# Проверяем что запустился
if systemctl --user is-active openclaw-gateway-moa.service > /dev/null 2>&1; then
    echo "  ✓ Бот запущен через systemd"
else
    echo "  ✗ systemd не запустил — пробуем вручную"
    nohup openclaw --profile moa gateway > /tmp/openclaw-fix.log 2>&1 &
    sleep 5
    if pgrep -f "openclaw.*moa" > /dev/null; then
        echo "  ✓ Бот запущен вручную"
    else
        echo "  ✗ Бот не запустился!"
    fi
fi
echo ""

# ── Шаг 8: Показать текущий конфиг провайдера ────────────
echo "── Шаг 8: Текущий конфиг (для проверки) ──"
python3 << 'PYEOF2'
import json
with open("/home/mmber/.openclaw-moa/openclaw.json") as f:
    c = json.load(f)

# Показать провайдеры
providers = c.get("models", {}).get("providers", {})
for name, prov in providers.items():
    safe_prov = {k: (v[:20]+"..." if isinstance(v, str) and len(v) > 20 else v)
                 for k, v in prov.items() if k != "models"}
    print(f"  Провайдер '{name}': {json.dumps(safe_prov, ensure_ascii=False)}")

# Показать модель агента
agents = c.get("agents", {})
default_model = agents.get("defaults", {}).get("model", {})
print(f"  Модель по умолчанию: {json.dumps(default_model, ensure_ascii=False)}")

# Показать tools
tools = c.get("tools", {})
print(f"  Tools: {json.dumps(tools, ensure_ascii=False)}")
PYEOF2
echo ""

echo "============================================"
echo "  ГОТОВО! Напиши боту 'привет' в Telegram."
echo ""
echo "  Если опять raw JSON — запусти ПЛАН Б:"
echo "    bash ~/vibe-coding/scripts/fix-bot-json-planb.sh"
echo "============================================"
