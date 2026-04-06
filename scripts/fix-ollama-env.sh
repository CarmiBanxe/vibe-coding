#!/bin/bash
###############################################################################
# fix-ollama-env.sh — Прописать OLLAMA_API_KEY глобально
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-ollama-env.sh
###############################################################################

echo "=========================================="
echo "  OLLAMA_API_KEY — глобальная установка"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

echo "[1/4] Останавливаю gateway..."
pkill -9 -f "openclaw.*gateway" 2>/dev/null
sleep 3

echo "[2/4] Прописываю OLLAMA_API_KEY везде..."

# В /etc/environment (глобально для всех процессов)
if ! grep -q "OLLAMA_API_KEY" /etc/environment 2>/dev/null; then
    echo 'OLLAMA_API_KEY=ollama-local' >> /etc/environment
    echo "  ✓ /etc/environment"
fi

# В .bashrc root
if ! grep -q "OLLAMA_API_KEY" /root/.bashrc 2>/dev/null; then
    echo 'export OLLAMA_API_KEY=ollama-local' >> /root/.bashrc
    echo "  ✓ /root/.bashrc"
fi

# В systemd override для gateway
mkdir -p /etc/systemd/system/openclaw-gateway-moa.service.d
cat > /etc/systemd/system/openclaw-gateway-moa.service.d/ollama.conf << 'OVERRIDE'
[Service]
Environment=OLLAMA_API_KEY=ollama-local
OVERRIDE
echo "  ✓ systemd override для MoA"

mkdir -p /etc/systemd/system/openclaw-gateway-mycarmibot.service.d
cat > /etc/systemd/system/openclaw-gateway-mycarmibot.service.d/ollama.conf << 'OVERRIDE2'
[Service]
Environment=OLLAMA_API_KEY=ollama-local
OVERRIDE2
echo "  ✓ systemd override для mycarmibot"

systemctl daemon-reload

# Экспортируем прямо сейчас
export OLLAMA_API_KEY=ollama-local

echo ""
echo "[3/4] Запускаю gateway..."

cd /root/.openclaw-moa
OPENCLAW_HOME=/root/.openclaw-moa OLLAMA_API_KEY=ollama-local nohup npx openclaw gateway --port 18789 > /data/logs/gateway-moa.log 2>&1 &
echo "  Жду 15 секунд..."
sleep 15

if ss -tlnp | grep -q ":18789 "; then
    echo "  ✓ Gateway ACTIVE"
else
    echo "  ✗ Не запустился"
    tail -5 /data/logs/gateway-moa.log 2>/dev/null | sed 's/^/    /'
fi

echo ""
echo "[4/4] Проверяю..."

echo "  Модель:"
grep "agent model" /data/logs/gateway-moa.log 2>/dev/null | tail -1 | sed 's/^/    /'

echo ""
echo "  Ошибки Ollama:"
grep -i "unknown model\|ollama.*auth\|warmup failed" /data/logs/gateway-moa.log 2>/dev/null | tail -2 | sed 's/^/    /'

echo ""
echo "  Telegram:"
grep "telegram" /data/logs/gateway-moa.log 2>/dev/null | tail -2 | sed 's/^/    /'

echo ""
echo "  Тест Ollama напрямую:"
RESULT=$(OLLAMA_API_KEY=ollama-local curl -s --max-time 10 http://localhost:11434/api/generate -d '{"model":"huihui_ai/qwen3.5-abliterated:35b","prompt":"Hi","stream":false,"options":{"num_predict":5}}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('response','ERROR')[:50])" 2>/dev/null)
echo "  Ollama ответ: $RESULT"

REMOTE_END

echo ""
echo "=========================================="
echo "  Проверь: напиши @mycarmi_moa_bot Привет"
echo "=========================================="
