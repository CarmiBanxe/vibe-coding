#!/bin/bash
###############################################################################
# fix-deep-search-v3.sh — Deep Search на GMKtec (не на Legion WSL2)
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-deep-search-v3.sh
#
# WSL2 не может делать поиск (блокируется). GMKtec — bare metal, работает.
###############################################################################

echo "=========================================="
echo "  DEEP SEARCH v3: переносим на GMKtec"
echo "=========================================="

echo ""
echo "[1/3] Устанавливаю на GMKtec..."

ssh gmktec 'bash -s' << 'REMOTE'

# Устанавливаем зависимости
pip3 install -q requests ddgs 2>/dev/null || pip install -q requests ddgs 2>/dev/null

# Тест поиска с GMKtec (bare metal, нормальный IP)
echo "  Тестирую поиск с GMKtec..."
python3 -c "
from ddgs import DDGS
r = DDGS().text('FCA financial regulation UK', max_results=3)
print(f'  Результатов: {len(r)}')
for x in r: print(f'  - {x[\"title\"]}: {x[\"body\"][:80]}')
" 2>/dev/null

if [ $? -ne 0 ]; then
    echo "  ddgs не работает, пробую googlesearch..."
    pip3 install -q googlesearch-python 2>/dev/null
    python3 -c "
from googlesearch import search
r = list(search('FCA regulation UK', num_results=3))
print(f'  Google: {len(r)} результатов')
for x in r: print(f'  - {x}')
" 2>/dev/null
fi

# Создаём Deep Search сервер на GMKtec
cat > /opt/deep-search-server.py << 'DEEPSEARCH'
#!/usr/bin/env python3
"""Deep Search v3 — на GMKtec (bare metal, нормальный IP)"""
import json, sys
from http.server import HTTPServer, BaseHTTPRequestHandler

def search(query):
    # Метод 1: ddgs
    try:
        from ddgs import DDGS
        results = DDGS().text(query, max_results=5)
        if results:
            text = "\n\n".join([f"**{r['title']}**\n{r['body']}\nSource: {r['href']}" for r in results])
            return {"result": text[:5000], "source": "duckduckgo", "query": query, "count": len(results)}
    except:
        pass
    
    # Метод 2: googlesearch
    try:
        from googlesearch import search as gsearch
        import requests
        results = list(gsearch(query, num_results=5, lang="en"))
        if results:
            texts = []
            for url in results[:3]:
                try:
                    r = requests.get(url, timeout=5, headers={"User-Agent": "Mozilla/5.0"})
                    # Простое извлечение текста
                    from html.parser import HTMLParser
                    class TextExtractor(HTMLParser):
                        def __init__(self):
                            super().__init__()
                            self.texts = []
                            self.skip = False
                        def handle_starttag(self, tag, attrs):
                            if tag in ('script', 'style', 'nav', 'header', 'footer'):
                                self.skip = True
                        def handle_endtag(self, tag):
                            if tag in ('script', 'style', 'nav', 'header', 'footer'):
                                self.skip = False
                        def handle_data(self, data):
                            if not self.skip and len(data.strip()) > 30:
                                self.texts.append(data.strip())
                    te = TextExtractor()
                    te.feed(r.text)
                    if te.texts:
                        texts.append(f"**{url}**\n" + "\n".join(te.texts[:5]))
                except:
                    texts.append(url)
            if texts:
                return {"result": "\n\n".join(texts)[:5000], "source": "google", "query": query, "count": len(results)}
    except:
        pass
    
    # Метод 3: Wikipedia
    try:
        import requests
        r = requests.get(f"https://en.wikipedia.org/api/rest_v1/page/summary/{query.replace(' ','_')}", timeout=10)
        if r.status_code == 200:
            data = r.json()
            extract = data.get("extract", "")
            if extract:
                return {"result": extract[:5000], "source": "wikipedia", "query": query}
    except:
        pass
    
    return {"error": "All methods failed", "result": "", "query": query}

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        try:
            query = json.loads(body).get("query", "")
        except:
            query = body
        result = search(query)
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(json.dumps(result, ensure_ascii=False).encode())
    
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok","version":3,"location":"gmktec"}')
    
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8088
    print(f"Deep Search v3 on http://0.0.0.0:{port} (GMKtec)")
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
DEEPSEARCH

chmod +x /opt/deep-search-server.py

# Systemd сервис
cat > /etc/systemd/system/deep-search.service << 'SVC'
[Unit]
Description=Deep Search v3 (GMKtec)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/deep-search-server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable deep-search
systemctl restart deep-search
sleep 3

if systemctl is-active deep-search &>/dev/null; then
    echo "  ✓ Deep Search v3 ACTIVE на GMKtec (порт 8088)"
else
    echo "  ✗ Не запустился:"
    systemctl status deep-search | tail -5
fi

# Обновляем deep-search команду (теперь localhost)
cat > /usr/local/bin/deep-search << 'CMD'
#!/bin/bash
QUERY="$*"
[ -z "$QUERY" ] && read -p "Запрос: " QUERY
RESULT=$(curl -s --max-time 30 -X POST http://localhost:8088/search -H "Content-Type: application/json" -d "{\"query\": \"$QUERY\"}")
if [ -n "$RESULT" ]; then
    echo "$RESULT" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r.get('result','Нет ответа'))" 2>/dev/null || echo "$RESULT"
else
    echo "Ошибка: Deep Search недоступен"
fi
CMD
chmod +x /usr/local/bin/deep-search
echo "  ✓ deep-search команда обновлена (localhost)"
REMOTE

echo ""
echo "[2/3] Тестирую..."

TEST=$(ssh gmktec "deep-search 'FCA financial regulation UK'" 2>/dev/null)
if [ -n "$TEST" ] && ! echo "$TEST" | grep -q "error\|Ошибка\|failed"; then
    echo "  ✓ Deep Search РАБОТАЕТ!"
    echo ""
    echo "  Ответ (первые 300 символов):"
    echo "  ${TEST:0:300}"
else
    echo "  ✗ Результат: $TEST"
fi

# КАНОН
echo ""
echo "[3/3] КАНОН..."
ssh gmktec "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << 'EOF'

## Обновление: Deep Search v3 на GMKtec ($(date '+%Y-%m-%d %H:%M'))
- Перенесён с Legion (WSL2 блокирует поиск) на GMKtec (bare metal)
- Systemd сервис: deep-search.service на порту 8088
- Методы: DuckDuckGo → Google → Wikipedia
- Команда: deep-search 'запрос' (на GMKtec, localhost)
EOF
done" 2>/dev/null
echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  Deep Search теперь на GMKtec"
echo "  Использование: ssh gmktec \"deep-search 'запрос'\""
echo "=========================================="
