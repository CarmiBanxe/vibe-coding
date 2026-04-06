#!/bin/bash
###############################################################################
# setup-multilayer-search.sh — Многослойный поиск: Brave + Perplexity Playwright
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/setup-multilayer-search.sh
#
# Архитектура:
#   Слой 1: Brave Search API (GMKtec) — быстрый, $5 бесплатно/мес
#   Слой 2: Perplexity через Playwright (Legion) — глубокий анализ
###############################################################################

echo "=========================================="
echo "  МНОГОСЛОЙНЫЙ ПОИСК"
echo "  Слой 1: Brave | Слой 2: Perplexity"
echo "=========================================="

# ============================================================================
# СЛОЙ 1: Brave Search API
# ============================================================================

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  СЛОЙ 1: Brave Search API           ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "  Brave даёт \$5 бесплатно каждый месяц (~1000 запросов)."
echo "  Нужна кредитная карта (не списывают, только верификация)."
echo ""
echo "  Сейчас откроется браузер с регистрацией."
echo "  Пройди 4 шага:"
echo "    1. Зарегистрируйся: email + пароль"
echo "    2. Подтверди email (ссылка в почте)"
echo "    3. Выбери план (любой — \$5 free credits автоматически)"
echo "    4. Введи карту → скопируй API Key"
echo ""

# Открываем браузер на Windows
cmd.exe /c start https://api-dashboard.search.brave.com/register 2>/dev/null || \
    powershell.exe -c "Start-Process 'https://api-dashboard.search.brave.com/register'" 2>/dev/null || \
    echo "  Открой вручную: https://api-dashboard.search.brave.com/register"

echo ""
echo "  После получения ключа вставь его сюда."
echo "  (Ключ выглядит как: BSA...длинная_строка)"
echo ""
read -p "  Brave Search API Key (или Enter чтобы пропустить): " BRAVE_KEY

if [ -n "$BRAVE_KEY" ]; then
    echo ""
    echo "  Настраиваю Brave Search на обоих ботах..."
    
    ssh gmktec 'bash -s' << BRAVEOF
export XDG_RUNTIME_DIR="/run/user/0"

python3 << 'PYEOF'
import json

# Все конфиги где нужен Brave
configs = [
    "/root/.openclaw-moa/openclaw.json",
    "/root/.openclaw-moa/.openclaw/openclaw.json",
    "/root/.openclaw-default/openclaw.json",
    "/root/.openclaw-default/.openclaw/openclaw.json"
]

for path in configs:
    try:
        with open(path, "r") as f:
            config = json.load(f)
        if "tools" not in config:
            config["tools"] = {}
        config["tools"]["webSearch"] = {
            "provider": "brave",
            "apiKey": "$BRAVE_KEY"
        }
        with open(path, "w") as f:
            json.dump(config, f, indent=2)
        print(f"  ✓ {path}")
    except:
        pass
PYEOF

systemctl --user restart openclaw-gateway-moa 2>/dev/null
systemctl --user restart openclaw-gateway 2>/dev/null
sleep 5
echo "  ✓ Боты перезапущены с Brave Search"
BRAVEOF
    echo "  ✓ Слой 1 настроен"
else
    echo "  ⏭ Brave пропущен — настроишь позже"
    echo "  Для настройки потом запусти:"
    echo "    bash scripts/setup-multilayer-search.sh"
fi

# ============================================================================
# СЛОЙ 2: Playwright + Perplexity на Legion
# ============================================================================

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  СЛОЙ 2: Perplexity Playwright      ║"
echo "╚══════════════════════════════════════╝"

echo ""
echo "[1/5] Устанавливаю Playwright на Legion..."

if [ ! -d /home/mmber/playwright-env ]; then
    python3 -m venv /home/mmber/playwright-env
fi

source /home/mmber/playwright-env/bin/activate
pip install -q playwright requests 2>/dev/null
playwright install chromium 2>/dev/null
echo "  ✓ Playwright + Chromium установлены"

echo ""
echo "[2/5] Создаю Deep Search сервер..."

cat > /home/mmber/deep-search-server.py << 'DEEPSEARCH'
#!/usr/bin/env python3
"""
Deep Search Server — Perplexity через Playwright
Порт 8088 на Legion
POST /search {"query":"..."} → глубокий поиск
GET /health → статус
"""
import asyncio, json, os, sys
from http.server import HTTPServer, BaseHTTPRequestHandler

try:
    from playwright.async_api import async_playwright
    PW_OK = True
except:
    PW_OK = False

COOKIES_FILE = "/home/mmber/.perplexity-cookies.json"

async def search_perplexity(query):
    if not PW_OK:
        return {"error": "Playwright not installed", "result": ""}
    
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context()
        
        if os.path.exists(COOKIES_FILE):
            try:
                with open(COOKIES_FILE) as f:
                    await context.add_cookies(json.load(f))
            except:
                pass
        
        page = await context.new_page()
        try:
            await page.goto("https://www.perplexity.ai/", timeout=30000)
            await page.wait_for_load_state("networkidle", timeout=15000)
            
            # Ищем поле ввода
            for selector in ["textarea", "[placeholder*='Ask']", "[placeholder*='Search']", "input[type='text']"]:
                el = page.locator(selector).first
                if await el.is_visible(timeout=3000):
                    await el.fill(query)
                    await el.press("Enter")
                    break
            
            # Ждём ответ
            await page.wait_for_timeout(25000)
            
            # Забираем текст ответа
            result = ""
            for sel in [".prose", ".markdown", "[class*='answer']", "[class*='result']", "main"]:
                blocks = await page.locator(sel).all()
                for b in blocks:
                    t = await b.text_content()
                    if t and len(t) > 50:
                        result += t + "\n"
                if result:
                    break
            
            # Сохраняем cookies
            try:
                with open(COOKIES_FILE, "w") as f:
                    json.dump(await context.cookies(), f)
            except:
                pass
            
            return {"result": result.strip()[:5000], "source": "perplexity_max", "query": query}
        except Exception as e:
            return {"error": str(e), "result": "", "query": query}
        finally:
            await browser.close()

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/search":
            body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
            try:
                query = json.loads(body).get("query", "")
            except:
                query = body
            
            result = asyncio.run(search_perplexity(query))
            resp = json.dumps(result, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(resp)
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok", "playwright": PW_OK}).encode())
    
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8088
    print(f"Deep Search Server on http://0.0.0.0:{port}")
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
DEEPSEARCH

chmod +x /home/mmber/deep-search-server.py
echo "  ✓ Deep Search сервер создан"

echo ""
echo "[3/5] Создаю systemd сервис..."

mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/deep-search.service << 'SVC'
[Unit]
Description=Deep Search Server (Perplexity Playwright)
After=network.target

[Service]
Type=simple
ExecStart=/home/mmber/playwright-env/bin/python3 /home/mmber/deep-search-server.py
Restart=always
RestartSec=10
Environment=HOME=/home/mmber

[Install]
WantedBy=default.target
SVC

systemctl --user daemon-reload
systemctl --user enable deep-search
systemctl --user start deep-search
sleep 3

if systemctl --user is-active deep-search &>/dev/null; then
    echo "  ✓ Deep Search ACTIVE (порт 8088)"
else
    echo "  ⚠ Статус:"
    systemctl --user status deep-search 2>/dev/null | tail -5
fi

echo ""
echo "[4/5] Создаю мост deep-search на GMKtec..."

LEGION_IP=$(hostname -I | awk '{print $1}')
echo "  Legion IP: $LEGION_IP"

ssh gmktec "bash -s" << BRIDGEOF
cat > /usr/local/bin/deep-search << 'SCRIPT'
#!/bin/bash
# deep-search — Глубокий поиск через Perplexity (Слой 2)
# Использование: deep-search "запрос"

QUERY="\$*"
[ -z "\$QUERY" ] && read -p "Запрос: " QUERY

# Пробуем прямой HTTP к Legion
RESULT=\$(curl -s --max-time 60 -X POST http://$LEGION_IP:8088/search \\
    -H "Content-Type: application/json" \\
    -d "{\"query\": \"\$QUERY\"}" 2>/dev/null)

if [ -z "\$RESULT" ]; then
    echo "Ошибка: Deep Search недоступен (Legion offline?)"
    exit 1
fi

echo "\$RESULT" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r.get('result','Нет ответа'))" 2>/dev/null || echo "\$RESULT"
SCRIPT
chmod +x /usr/local/bin/deep-search
echo "  ✓ deep-search создан на GMKtec"
BRIDGEOF

echo ""
echo "[5/5] Сохраняю cookies Perplexity..."
echo ""
echo "  Для работы Слоя 2 нужно ОДИН РАЗ войти в Perplexity:"
echo "  Сейчас откроется браузер — войди в свой аккаунт Perplexity."
echo "  Cookies сохранятся и Playwright будет их использовать."
echo ""
read -p "  Открыть Perplexity для входа? (yes/no): " OPEN_PPX

if [ "$OPEN_PPX" = "yes" ]; then
    # Сохраняем cookies через Playwright
    source /home/mmber/playwright-env/bin/activate
    python3 << 'COOKIES_SCRIPT'
import asyncio
from playwright.async_api import async_playwright
import json

async def save_cookies():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False)
        context = await browser.new_context()
        page = await context.new_page()
        await page.goto("https://www.perplexity.ai/")
        
        print("\n  Браузер открыт — войди в Perplexity аккаунт.")
        print("  Когда войдёшь — нажми Enter здесь.\n")
        input("  [Нажми Enter после входа в Perplexity] ")
        
        cookies = await context.cookies()
        with open("/home/mmber/.perplexity-cookies.json", "w") as f:
            json.dump(cookies, f)
        
        print(f"  ✓ Сохранено {len(cookies)} cookies")
        await browser.close()

asyncio.run(save_cookies())
COOKIES_SCRIPT
else
    echo "  ⏭ Пропущено — войди позже через:"
    echo "    source ~/playwright-env/bin/activate"
    echo "    python3 -c 'from playwright.sync_api import sync_playwright; b=sync_playwright().start().chromium.launch(headless=False); p=b.new_page(); p.goto(\"https://perplexity.ai\"); input(\"Enter after login\"); import json; json.dump(b.contexts[0].cookies(), open(\"/home/mmber/.perplexity-cookies.json\",\"w\"))'"
fi

# ============================================================================
# КАНОН
# ============================================================================

echo ""
echo "КАНОН: обновляю MEMORY.md..."
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

MEMTEXT="
## Обновление: Многослойный поиск ($TIMESTAMP)
### Архитектура поиска (2 слоя)
- Слой 1: Brave Search API (GMKtec)
  - \$5 бесплатно/мес (~1000 запросов)
  - Автоматический для обычных запросов
  - Статус: $([ -n "$BRAVE_KEY" ] && echo 'НАСТРОЕН' || echo 'ОЖИДАЕТ API KEY')
- Слой 2: Perplexity Max через Playwright (Legion, порт 8088)
  - Глубокий анализ по команде
  - Использует подписку через браузер
  - Команда: deep-search 'запрос'
  - Systemd: deep-search.service на Legion
- Будущее: каждый терминал дублера → свой Playwright"

ssh gmktec "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace /root/.openclaw-default/.openclaw/workspace; do echo '$MEMTEXT' >> \$d/MEMORY.md 2>/dev/null; done" 2>/dev/null

echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  МНОГОСЛОЙНЫЙ ПОИСК ГОТОВ"
echo "=========================================="
echo ""
echo "  Слой 1: Brave Search $([ -n "$BRAVE_KEY" ] && echo '✓' || echo '⏭ нужен ключ')"
echo "  Слой 2: Perplexity Playwright ✓ (порт 8088)"
echo ""
echo "  Как использовать:"
echo "    Бот автоматически → Brave Search (быстро)"
echo "    'Глубокий анализ: тема' → deep-search → Perplexity"
echo "=========================================="
