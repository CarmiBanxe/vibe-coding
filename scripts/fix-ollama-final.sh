#!/bin/bash
###############################################################################
# fix-ollama-final.sh — Правильная настройка Ollama по документации OpenClaw
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-ollama-final.sh
#
# Источник: https://docs.openclaw.ai/providers/ollama
# Два метода: openclaw onboard --non-interactive + ручная правка конфига
###############################################################################

echo "=========================================="
echo "  OLLAMA — НАСТРОЙКА ПО ДОКУМЕНТАЦИИ"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

echo "[1/4] Останавливаю gateway..."
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

echo "[2/4] Настраиваю Ollama через openclaw onboard..."

cd /root/.openclaw-moa
export OPENCLAW_HOME=/root/.openclaw-moa
export OLLAMA_API_KEY="ollama-local"

# Метод 1: non-interactive onboard
npx openclaw onboard --non-interactive \
    --auth-choice ollama \
    --custom-base-url "http://localhost:11434" \
    --custom-model-id "huihui_ai/qwen3.5-abliterated:35b" \
    --accept-risk 2>&1 | tail -10 | sed 's/^/    /'

echo ""
echo "  Также настраиваю через config set..."

# Метод 2: config set (если onboard не сработал)
npx openclaw config set models.providers.ollama.apiKey "ollama-local" 2>&1 | head -3 | sed 's/^/    /'
npx openclaw config set models.providers.ollama.baseUrl "http://localhost:11434" 2>&1 | head -3 | sed 's/^/    /'
npx openclaw config set models.providers.ollama.api "ollama" 2>&1 | head -3 | sed 's/^/    /'

echo ""
echo "  Проверяю модели..."
npx openclaw models list 2>&1 | head -10 | sed 's/^/    /'

echo ""
echo "[3/4] Ставлю модель по умолчанию..."
npx openclaw models set "ollama/huihui_ai/qwen3.5-abliterated:35b" 2>&1 | head -5 | sed 's/^/    /'

echo ""
echo "  Статус моделей:"
npx openclaw models status 2>&1 | head -20 | sed 's/^/    /'

echo ""
echo "[4/4] Запускаю gateway..."

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa OLLAMA_API_KEY="ollama-local" nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 20 секунд..."
sleep 20

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
echo "  Warmup:"
grep -i "warmup" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

echo ""
echo "  Telegram:"
grep "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -2 | sed 's/^/    /'

REMOTE_END

echo ""
echo "=========================================="
echo "  Проверь: напиши @mycarmi_moa_bot Привет"
echo "=========================================="
