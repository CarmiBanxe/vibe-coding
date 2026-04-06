#!/bin/bash
###############################################################################
# fix-webui-direct-access.sh — Прямой доступ к Web UI с токенизированным URL
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-webui-direct-access.sh
#
# Что делает:
#   1. Получает токенизированный URL Dashboard
#   2. Заменяет 127.0.0.1 на 192.168.0.72
#   3. Открывает в браузере Windows автоматически
###############################################################################

echo "=========================================="
echo "  WEB UI — прямой доступ"
echo "=========================================="

# Получаем URL с токеном
echo "[1/2] Получаю Dashboard URL..."
DASHBOARD_URL=$(ssh gmktec 'OPENCLAW_HOME=/root/.openclaw-moa npx openclaw dashboard --no-open 2>&1 | grep "Dashboard URL" | sed "s/Dashboard URL: //"')

if [ -z "$DASHBOARD_URL" ]; then
    echo "  ✗ Не удалось получить URL"
    echo "  Проверяю gateway..."
    ssh gmktec 'ss -tlnp | grep 18789 || echo "Gateway не запущен"'
    exit 1
fi

echo "  Оригинальный URL: $DASHBOARD_URL"

# Заменяем localhost на IP GMKtec, http на https (через nginx)
WEB_URL=$(echo "$DASHBOARD_URL" | sed 's|http://127.0.0.1:18789/|https://192.168.0.72/|')

echo "  Web URL: $WEB_URL"

echo ""
echo "[2/2] Открываю в браузере..."
# Открываем в Windows браузере
cmd.exe /c start "$WEB_URL" 2>/dev/null || echo "  Не удалось открыть автоматически"

echo ""
echo "=========================================="
echo "  Если не открылось — скопируй и вставь"
echo "  в адресную строку браузера:"
echo ""
echo "  $WEB_URL"
echo ""
echo "  Логин nginx: ceo / Banxe2026!"
echo "=========================================="
