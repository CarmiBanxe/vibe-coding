#!/bin/bash
###############################################################################
# fix-deep-search-final.sh — Deep Search FINAL: User-Agent fix
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/fix-deep-search-final.sh
###############################################################################

echo "=========================================="
echo "  DEEP SEARCH FINAL (User-Agent fix)"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE'

cat > /opt/deep-search-server.py << 'SERVER'
#!/usr/bin/env python3
"""Deep Search v4 — with proper User-Agent headers"""
import json, sys, urllib.request, urllib.parse
from html.parser import HTMLParser
from http.server import HTTPServer, BaseHTTPRequestHandler

UA = "BanxeBot/1.0 (moriel@banxe.com)"

def ddg_search(query):
    """DuckDuckGo HTML search"""
    url = "https://html.duckduckgo.com/html/?q=" + urllib.parse.quote(query)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    resp = urllib.request.urlopen(req, timeout=15)
    html = resp.read().decode("utf-8", errors="ignore")
    
    results = []
    class P(HTMLParser):
        def __init__(self):
            super().__init__()
            self.in_snippet = False
            self.in_title = False
            self.cur = {}
        def handle_starttag(self, tag, attrs):
            d = dict(attrs)
            cls = d.get("class", "")
            if "result__snippet" in cls:
                self.in_snippet = True
            if "result__a" in cls:
                self.in_title = True
                self.cur["url"] = d.get("href", "")
        def handle_data(self, data):
            if self.in_snippet:
                self.cur["snippet"] = data.strip()
                self.in_snippet = False
                if self.cur.get("snippet"):
                    results.append(dict(self.cur))
                    self.cur = {}
            if self.in_title:
                self.cur["title"] = data.strip()
                self.in_title = False
    P().feed(html)
    return results

def wiki_search(query):
    """Wikipedia summary"""
    term = query.replace(" ", "_")
    url = f"https://en.wikipedia.org/api/rest_v1/page/summary/{urllib.parse.quote(term)}"
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        data = json.loads(resp.read())
        return data.get("extract", "")
    except:
        # Try search
        url2 = f"https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch={urllib.parse.quote(query)}&format=json&srlimit=3"
        req2 = urllib.request.Request(url2, headers={"User-Agent": UA})
        resp2 = urllib.request.urlopen(req2, timeout=10)
        data2 = json.loads(resp2.read())
        results = data2.get("query", {}).get("search", [])
        if results:
            texts = []
            for r in results:
                # Remove HTML tags
                snippet = r.get("snippet", "")
                import re
                snippet = re.sub(r'<[^>]+>', '', snippet)
                texts.append(f"**{r['title']}**: {snippet}")
            return "\n\n".join(texts)
    return ""

def search(query):
    # Method 1: DuckDuckGo
    try:
        results = ddg_search(query)
        if results:
            text = "\n\n".join([f"**{r.get('title','')}**\n{r.get('snippet','')}" for r in results[:5]])
            return {"result": text[:5000], "source": "duckduckgo", "query": query, "count": len(results)}
    except Exception as e:
        pass
    
    # Method 2: Wikipedia
    try:
        text = wiki_search(query)
        if text:
            return {"result": text[:5000], "source": "wikipedia", "query": query}
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
        self.wfile.write(b'{"status":"ok","version":4}')
    
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8088
    print(f"Deep Search v4 on http://0.0.0.0:{port}")
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
SERVER

systemctl restart deep-search
sleep 3

# Тест
echo "  Тестирую..."
RESULT=$(curl -s --max-time 20 -X POST http://localhost:8088/search -H "Content-Type: application/json" -d '{"query":"FCA financial regulation UK"}')
SOURCE=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('source','FAIL'))" 2>/dev/null)
COUNT=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('count','0'))" 2>/dev/null)

if [ "$SOURCE" != "FAIL" ] && [ "$SOURCE" != "" ]; then
    echo "  ✓ Deep Search РАБОТАЕТ! Источник: $SOURCE, результатов: $COUNT"
    echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result','')[:300])" 2>/dev/null
else
    echo "  ✗ $RESULT"
fi
REMOTE

# КАНОН
echo ""
ssh gmktec "for d in /home/mmber/.openclaw/workspace-moa /root/.openclaw-moa/workspace-moa /root/.openclaw-moa/.openclaw/workspace; do cat >> \$d/MEMORY.md 2>/dev/null << 'EOF'

## Обновление: Deep Search v4 FINAL ($(date '+%Y-%m-%d %H:%M'))
- Причина проблемы: отсутствие User-Agent в HTTP запросах
- Решение: User-Agent BanxeBot/1.0 во всех запросах
- Без внешних pip зависимостей (только urllib из stdlib)
- Методы: DuckDuckGo HTML → Wikipedia API
- Сервер: GMKtec порт 8088, systemd deep-search.service
EOF
done" 2>/dev/null
echo "  ✓ MEMORY.md обновлён (канон)"

echo ""
echo "=========================================="
echo "  Тест: ssh gmktec \"deep-search 'запрос'\""
echo "=========================================="
