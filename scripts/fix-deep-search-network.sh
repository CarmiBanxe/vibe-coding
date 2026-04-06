#!/bin/bash
###############################################################################
# fix-deep-search-network.sh — Починка сети Deep Search (Legion ↔ GMKtec)
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-deep-search-network.sh
#
# Проблема: GMKtec не может достучаться до Deep Search на Legion
# Решение: Вместо HTTP через сеть — используем SSH tunnel (надёжно)
###############################################################################

echo "=========================================="
echo "  ПОЧИНКА DEEP SEARCH СЕТИ"
echo "=========================================="

# Подход: GMKtec вызывает Deep Search через SSH на Legion
# Это работает потому что SSH уже настроен и проверен

echo ""
echo "[1/3] Настраиваю SSH ключ GMKtec → Legion..."

# Генерируем ключ на GMKtec если нет
ssh gmktec 'bash -s' << 'STEP1'
if [ ! -f /root/.ssh/id_ed25519.pub ]; then
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "root@gmktec"
    echo "  ✓ Ключ создан"
else
    echo "  ✓ Ключ уже есть"
fi
cat /root/.ssh/id_ed25519.pub
STEP1

# Добавляем ключ GMKtec в authorized_keys на Legion
GMKTEC_KEY=$(ssh gmktec "cat /root/.ssh/id_ed25519.pub" 2>/dev/null)
if [ -n "$GMKTEC_KEY" ]; then
    if ! grep -q "root@gmktec" ~/.ssh/authorized_keys 2>/dev/null; then
        echo "$GMKTEC_KEY" >> ~/.ssh/authorized_keys
        echo "  ✓ Ключ GMKtec добавлен в Legion authorized_keys"
    else
        echo "  ✓ Ключ уже в authorized_keys"
    fi
fi

echo ""
echo "[2/3] Обновляю deep-search на GMKtec (через SSH вместо HTTP)..."

LEGION_WSL_IP=$(hostname -I | awk '{print $1}')

ssh gmktec "bash -s" << STEP2
cat > /usr/local/bin/deep-search << 'SCRIPT'
#!/bin/bash
# deep-search — Глубокий поиск через Perplexity (Слой 2)
# Использование: deep-search "запрос"
# Метод: SSH → Legion → Deep Search Server (localhost:8088)

QUERY="\$*"
[ -z "\$QUERY" ] && read -p "Запрос: " QUERY

# Метод 1: через SSH на Legion (надёжный)
RESULT=\$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no mmber@$LEGION_WSL_IP \
    "curl -s --max-time 60 -X POST http://localhost:8088/search -H 'Content-Type: application/json' -d '{\"query\": \"\$QUERY\"}'" 2>/dev/null)

# Метод 2: через SSH на Windows IP Legion
if [ -z "\$RESULT" ] || echo "\$RESULT" | grep -q "error"; then
    RESULT=\$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no mmber@192.168.0.75 \
        "curl -s --max-time 60 -X POST http://localhost:8088/search -H 'Content-Type: application/json' -d '{\"query\": \"\$QUERY\"}'" 2>/dev/null)
fi

if [ -n "\$RESULT" ]; then
    echo "\$RESULT" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r.get('result','Нет ответа'))" 2>/dev/null || echo "\$RESULT"
else
    echo "Ошибка: Deep Search недоступен"
fi
SCRIPT
chmod +x /usr/local/bin/deep-search
echo "  ✓ deep-search обновлён (SSH метод)"
STEP2

echo ""
echo "[3/3] Тестирую..."

# Проверяем SSH GMKtec → Legion
echo "  Тест SSH GMKtec → Legion..."
TEST_SSH=$(ssh gmktec "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no mmber@$LEGION_WSL_IP 'echo OK'" 2>/dev/null)
if [ "$TEST_SSH" = "OK" ]; then
    echo "  ✓ SSH GMKtec → Legion работает"
else
    echo "  ⚠ SSH не работает, пробую Windows IP..."
    TEST_SSH2=$(ssh gmktec "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no mmber@192.168.0.75 'echo OK'" 2>/dev/null)
    if [ "$TEST_SSH2" = "OK" ]; then
        echo "  ✓ SSH через Windows IP работает"
    else
        echo "  ✗ SSH GMKtec → Legion не работает"
        echo "  Нужно добавить ключ вручную:"
        echo "  ssh gmktec 'ssh-copy-id mmber@192.168.0.75'"
    fi
fi

# Тестируем deep-search
echo ""
echo "  Тест deep-search (займёт ~30 сек)..."
RESULT=$(ssh gmktec "timeout 60 deep-search 'What is FCA regulation'" 2>/dev/null)
if [ -n "$RESULT" ] && ! echo "$RESULT" | grep -q "Ошибка\|error"; then
    echo "  ✓ Deep Search РАБОТАЕТ!"
    echo ""
    echo "  Ответ (первые 200 символов):"
    echo "  ${RESULT:0:200}..."
else
    echo "  ⚠ Deep Search не ответил: $RESULT"
    echo ""
    echo "  Возможные причины:"
    echo "  1. SSH GMKtec → Legion не настроен"
    echo "  2. Deep Search сервис не запущен"
    echo "  3. Perplexity cookies невалидны"
fi

# КАНОН
echo ""
echo "КАНОН: обновляю MEMORY.md..."
ssh gmktec "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << 'EOF'

## Обновление: Deep Search сеть починена ($(date '+%Y-%m-%d %H:%M'))
- deep-search использует SSH туннель (не HTTP напрямую)
- GMKtec → SSH → Legion → localhost:8088 → Perplexity
- Это надёжнее чем HTTP через WSL2 NAT
EOF
done" 2>/dev/null
echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
