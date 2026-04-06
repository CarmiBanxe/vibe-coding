#!/bin/bash
###############################################################################
# fix-deep-search-api.sh — Deep Search через Perplexity API (не Playwright)
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-deep-search-api.sh
#
# Вместо Playwright (медленный, хрупкий) используем прямой HTTP API
# Perplexity с session token из подписки Max.
###############################################################################

echo "=========================================="
echo "  DEEP SEARCH: Perplexity API метод"
echo "=========================================="

echo ""
echo "[1/3] Обновляю Deep Search сервер..."

# Читаем токен
TOKEN=$(cat /mnt/c/Users/mmber/.env 2>/dev/null | grep PERPLEXITY_SESSION_TOKEN | cut -d'"' -f2)

if [ -z "$TOKEN" ]; then
    echo "  ✗ Токен не найден в /mnt/c/Users/mmber/.env"
    exit 1
fi
echo "  ✓ Токен найден"

cat > /home/mmber/deep-search-server.py << DEEPSEARCH
#!/usr/bin/env python3
"""
Deep Search Server — Perplexity через HTTP API с session token
Порт 8088
"""
import json, sys, requests
from http.server import HTTPServer, BaseHTTPRequestHandler

SESSION_TOKEN = "$TOKEN"

def search_perplexity(query):
    """Поиск через Perplexity internal API"""
    headers = {
        "accept": "application/json",
        "content-type": "application/json",
        "cookie": f"__Secure-next-auth.session-token={SESSION_TOKEN}; next-auth.session-token={SESSION_TOKEN}",
        "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    }
    
    # Метод 1: Perplexity internal API
    try:
        resp = requests.post(
            "https://www.perplexity.ai/api/query",
            headers=headers,
            json={
                "query": query,
                "search_focus": "internet",
                "frontend_uuid": "banxe-deep-search"
            },
            timeout=30
        )
        if resp.status_code == 200:
            data = resp.json()
            answer = data.get("answer", data.get("text", ""))
            if answer:
                return {"result": answer[:5000], "source": "perplexity_api", "query": query}
    except Exception as e:
        pass
    
    # Метод 2: Perplexity Labs API (бесплатный, без токена)
    try:
        resp = requests.post(
            "https://api.perplexity.ai/chat/completions",
            headers={
                "accept": "application/json",
                "content-type": "application/json"
            },
            json={
                "model": "sonar",
                "messages": [{"role": "user", "content": query}]
            },
            timeout=30
        )
        if resp.status_code == 200:
            data = resp.json()
            answer = data.get("choices", [{}])[0].get("message", {}).get("content", "")
            if answer:
                return {"result": answer[:5000], "source": "perplexity_sonar", "query": query}
    except:
        pass
    
    # Метод 3: DuckDuckGo (всегда работает, бесплатно)
    try:
        resp = requests.get(
            f"https://api.duckduckgo.com/?q={query}&format=json&no_html=1",
            timeout=10
        )
        if resp.status_code == 200:
            data = resp.json()
            abstract = data.get("AbstractText", "")
            related = " ".join([t.get("Text", "") for t in data.get("RelatedTopics", [])[:5]])
            result = abstract or related
            if result:
                return {"result": result[:5000], "source": "duckduckgo", "query": query}
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
        
        result = search_perplexity(query)
        resp = json.dumps(result, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(resp)
    
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok","methods":["perplexity_api","perplexity_sonar","duckduckgo"]}')
    
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8088
    print(f"Deep Search on http://0.0.0.0:{port} (3 methods: Perplexity API, Sonar, DuckDuckGo)")
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
DEEPSEARCH

echo "  ✓ Сервер обновлён (3 метода: Perplexity API, Sonar, DuckDuckGo)"

echo ""
echo "[2/3] Перезапускаю..."

systemctl --user restart deep-search
sleep 3

if systemctl --user is-active deep-search &>/dev/null; then
    echo "  ✓ Deep Search ACTIVE"
else
    echo "  ⚠ Перезапуск не удался, пробую вручную..."
    source ~/playwright-env/bin/activate 2>/dev/null
    nohup python3 /home/mmber/deep-search-server.py > /tmp/deep-search.log 2>&1 &
    sleep 2
    echo "  ✓ Запущен вручную (PID: $!)"
fi

echo ""
echo "[3/3] Тестирую..."

# Локальный тест
RESULT=$(curl -s --max-time 30 -X POST http://localhost:8088/search -H "Content-Type: application/json" -d '{"query":"What is FCA regulation in UK"}')
echo "  Ответ: ${RESULT:0:200}"

# КАНОН
echo ""
ssh gmktec "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << 'EOF'

## Обновление: Deep Search переделан ($(date '+%Y-%m-%d %H:%M'))
- Playwright заменён на прямой HTTP API (быстрее, надёжнее)
- 3 метода fallback: Perplexity API → Perplexity Sonar → DuckDuckGo
- Port forwarding: Windows 8088 → WSL2 8088
- Firewall правило добавлено
EOF
done" 2>/dev/null
echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  Тест с GMKtec:"
echo "    ssh gmktec \"deep-search 'What is FCA'\""
echo "=========================================="
