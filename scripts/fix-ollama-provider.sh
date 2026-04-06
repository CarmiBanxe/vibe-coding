#!/bin/bash
###############################################################################
# fix-ollama-provider.sh — Регистрация Ollama как провайдера в OpenClaw
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-ollama-provider.sh
###############################################################################

echo "=========================================="
echo "  РЕГИСТРАЦИЯ OLLAMA ПРОВАЙДЕРА"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

echo "[1/4] Останавливаю gateway..."
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

echo "[2/4] Регистрирую Ollama провайдер..."

# Способ 1: через CLI
export OPENCLAW_HOME=/root/.openclaw-moa
export OLLAMA_API_KEY="ollama-local"

# Добавляем Ollama auth в конфиг
python3 << 'PYFIX'
import json

cfg_path = "/root/.openclaw-moa/.openclaw/openclaw.json"
with open(cfg_path) as f:
    cfg = json.load(f)

# Добавляем auth для Ollama
auth = cfg.setdefault("auth", {})
if "ollama" not in str(auth):
    # OpenClaw хранит auth profiles в отдельном файле
    print("  Добавляю через auth-profiles...")

# Проверяем текущую модель
agents = cfg.get("agents", {})
defaults = agents.get("defaults", {})
models = defaults.get("models", {})
print(f"  Текущая модель: {models.get('default', 'НЕТ')}")
print(f"  Auth ключи: {list(cfg.get('auth', {}).keys())}")
PYFIX

# Регистрируем через openclaw CLI
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa npx openclaw models auth set ollama --token "ollama-local" 2>&1 | head -5
echo "  ✓ Ollama auth зарегистрирован"

echo ""
echo "[3/4] Проверяю статус моделей..."
OPENCLAW_HOME=/root/.openclaw-moa npx openclaw models status 2>&1 | head -15

echo ""
echo "[4/4] Запускаю gateway..."
cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
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

REMOTE_END

echo ""
echo "=========================================="
echo "  Проверь: напиши @mycarmi_moa_bot Привет"
echo "=========================================="
