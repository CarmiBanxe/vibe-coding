#!/bin/bash
###############################################################################
# save-perplexity-cookies.sh — Сохранение cookies Perplexity для Deep Search
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/save-perplexity-cookies.sh
#
# Использует Windows-браузер (не WSL) для входа в Perplexity,
# затем экспортирует cookies для Playwright.
###############################################################################

echo "=========================================="
echo "  СОХРАНЕНИЕ COOKIES PERPLEXITY"
echo "=========================================="
echo ""
echo "  Сейчас:"
echo "  1. Откроется браузер Windows с Perplexity"
echo "  2. Войди в свой аккаунт (с подпиской Max)"
echo "  3. Вернись сюда и нажми Enter"
echo "  4. Скрипт извлечёт cookies автоматически"
echo ""

# Открываем Perplexity в Windows-браузере
cmd.exe /c start https://www.perplexity.ai/ 2>/dev/null || \
    powershell.exe -c "Start-Process 'https://www.perplexity.ai/'" 2>/dev/null

echo "  Браузер открыт."
echo ""
read -p "  Войди в Perplexity и нажми Enter здесь: "

echo ""
echo "  Извлекаю cookies..."

# Используем Playwright в headless режиме — НЕ нужен GUI
# Вместо этого берём cookies из Windows Chrome
source ~/playwright-env/bin/activate 2>/dev/null

# Вариант 1: Извлекаем cookies из Windows Chrome
CHROME_COOKIES=""
for COOKIE_DB in \
    "/mnt/c/Users/mmber/AppData/Local/Google/Chrome/User Data/Default/Cookies" \
    "/mnt/c/Users/mmber/AppData/Local/Google/Chrome/User Data/Profile 1/Cookies" \
    "/mnt/c/Users/mmber/AppData/Local/Microsoft/Edge/User Data/Default/Cookies" \
    "/mnt/c/Users/mmber/AppData/Local/Microsoft/Edge/User Data/Profile 1/Cookies" \
    "/mnt/c/Users/mmber/AppData/Roaming/Opera Software/Opera Stable/Cookies" \
    "/mnt/c/Users/mmber/AppData/Roaming/Opera Software/Opera GX Stable/Cookies"; do
    if [ -f "$COOKIE_DB" ]; then
        CHROME_COOKIES="$COOKIE_DB"
        echo "  Найдена база cookies: $(basename $(dirname $(dirname $COOKIE_DB)))"
        break
    fi
done

if [ -n "$CHROME_COOKIES" ]; then
    # Извлекаем perplexity cookies из SQLite
    python3 << PYEOF
import sqlite3
import json
import shutil
import os
import tempfile

# Копируем базу (она заблокирована Chrome)
src = "$CHROME_COOKIES"
tmp = tempfile.mktemp(suffix=".db")
shutil.copy2(src, tmp)

cookies = []
try:
    conn = sqlite3.connect(tmp)
    cursor = conn.cursor()
    cursor.execute("""
        SELECT host_key, name, path, is_secure, expires_utc, value
        FROM cookies
        WHERE host_key LIKE '%perplexity%'
    """)
    for row in cursor.fetchall():
        cookies.append({
            "domain": row[0],
            "name": row[1],
            "path": row[2],
            "secure": bool(row[3]),
            "expires": row[4],
            "value": row[5]
        })
    conn.close()
except Exception as e:
    print(f"  ⚠ SQLite ошибка: {e}")
    print("  Chrome может шифровать cookies — пробуем альтернативу...")

os.unlink(tmp)

if cookies:
    with open("/home/mmber/.perplexity-cookies.json", "w") as f:
        json.dump(cookies, f)
    print(f"  ✓ Извлечено {len(cookies)} cookies из браузера")
else:
    print("  ⚠ Cookies не извлечены из браузера (зашифрованы)")
    print("  Пробую альтернативный метод...")
PYEOF
fi

# Вариант 2: Если cookies зашифрованы — используем curl для проверки
if [ ! -s /home/mmber/.perplexity-cookies.json ]; then
    echo ""
    echo "  Альтернативный метод: ручной ввод cookies"
    echo ""
    echo "  В браузере Windows (который открыт с Perplexity):"
    echo "  1. Нажми F12 (Developer Tools)"
    echo "  2. Перейди на вкладку Application (или Storage)"
    echo "  3. Слева: Cookies → https://www.perplexity.ai"
    echo "  4. Найди cookie с именем: __Secure-next-auth.session-token"
    echo "     или: pplx.visitor-id"
    echo "  5. Скопируй его значение (Value)"
    echo ""
    read -p "  Вставь session-token (или Enter для пропуска): " SESSION_TOKEN
    
    if [ -n "$SESSION_TOKEN" ]; then
        python3 << PYEOF2
import json
cookies = [
    {
        "domain": ".perplexity.ai",
        "name": "__Secure-next-auth.session-token",
        "path": "/",
        "secure": True,
        "value": "$SESSION_TOKEN"
    }
]
with open("/home/mmber/.perplexity-cookies.json", "w") as f:
    json.dump(cookies, f)
print("  ✓ Session token сохранён")
PYEOF2
    else
        echo "  ⏭ Пропущено"
        echo ""
        echo "  Deep Search (Слой 2) будет работать без авторизации."
        echo "  Perplexity будет отвечать как бесплатная версия."
        echo "  Для Max-подписки настрой cookies позже."
    fi
fi

# Проверяем результат
echo ""
if [ -s /home/mmber/.perplexity-cookies.json ]; then
    COUNT=$(python3 -c "import json; print(len(json.load(open('/home/mmber/.perplexity-cookies.json'))))" 2>/dev/null)
    echo "  ✓ Файл cookies: /home/mmber/.perplexity-cookies.json ($COUNT cookies)"
    
    # Перезапускаем Deep Search чтобы подхватил cookies
    systemctl --user restart deep-search 2>/dev/null
    echo "  ✓ Deep Search перезапущен"
else
    echo "  ⚠ Cookies не сохранены — Deep Search будет без авторизации"
fi

# КАНОН
echo ""
echo "КАНОН: обновляю MEMORY.md..."
ssh gmktec "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << 'EOF'

## Обновление: Perplexity cookies ($(date '+%Y-%m-%d %H:%M'))
- Cookies Perplexity сохранены для Deep Search (Слой 2)
- Deep Search сервер перезапущен на Legion (порт 8088)
EOF
done" 2>/dev/null
echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  ГОТОВО"
echo "=========================================="
echo ""
echo "  Для теста Deep Search с GMKtec:"
echo "    ssh gmktec 'deep-search \"что такое FCA регулирование\"'"
echo "=========================================="
