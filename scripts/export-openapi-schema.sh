#!/usr/bin/env bash
# export-openapi-schema.sh — export OpenAPI schema from compliance API
#
# Запускать на GMKtec (где работает banxe-api.service на порту 8090).
# На Legion: ssh gmktec "bash /data/vibe-coding/scripts/export-openapi-schema.sh"
#
# Usage:
#   bash scripts/export-openapi-schema.sh
#   bash scripts/export-openapi-schema.sh --port 8090

set -euo pipefail

PORT="${1:-8090}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_JSON="${REPO_DIR}/docs/openapi-schema.json"
OUT_SPEC="${REPO_DIR}/docs/CHATGPT-ACTIONS-SPEC.md"

echo "[export-openapi] Fetching schema from localhost:${PORT}/openapi.json ..."

# Try live API first
if curl -sf "http://localhost:${PORT}/openapi.json" -o "${OUT_JSON}"; then
    echo "[export-openapi] Schema saved → ${OUT_JSON}"
else
    echo "[export-openapi] API not running on port ${PORT} — starting temporarily..."
    # Start uvicorn in background for schema export
    cd "${REPO_DIR}/src/compliance"
    PYTHONPATH="${REPO_DIR}/src" \
        /data/banxe/compliance-env/bin/uvicorn api:app \
        --host 127.0.0.1 --port "${PORT}" &
    UVICORN_PID=$!
    sleep 3
    curl -sf "http://localhost:${PORT}/openapi.json" -o "${OUT_JSON}"
    kill "${UVICORN_PID}" 2>/dev/null || true
    echo "[export-openapi] Schema saved → ${OUT_JSON}"
fi

# Count endpoints
ENDPOINT_COUNT=$(python3 -c "
import json
schema = json.load(open('${OUT_JSON}'))
paths = schema.get('paths', {})
count = sum(len(methods) for methods in paths.values())
print(count)
")

echo "[export-openapi] Found ${ENDPOINT_COUNT} endpoints"

# Generate CHATGPT-ACTIONS-SPEC.md
cat > "${OUT_SPEC}" << MDEOF
# ChatGPT Actions — OpenAPI Spec (Banxe Compliance API)

**Generated:** $(date -Iseconds)
**Source:** \`http://localhost:${PORT}/openapi.json\`
**Endpoints:** ${ENDPOINT_COUNT}

---

## How to import into ChatGPT Custom GPT

1. Open [ChatGPT](https://chat.openai.com) → **Explore GPTs** → your Banxe GPT → **Edit**
2. Go to **Configure** → **Actions** → **Add action**
3. Choose **Import from URL** or **Paste schema**
4. If importing from URL: use \`https://[your-ngrok-or-domain]/openapi.json\`
5. If pasting: copy contents of \`docs/openapi-schema.json\`
6. Set **Authentication**: API Key (header \`Authorization: Bearer <token>\`)

---

## Available Endpoints

See \`docs/openapi-schema.json\` for full spec.

| Method | Path | Description |
|--------|------|-------------|
| POST | /api/v1/screen/person | Sanctions + PEP + Adverse Media screening |
| POST | /api/v1/screen/company | KYB + UBO sanctions/PEP screening |
| POST | /api/v1/screen/wallet | Crypto AML (Watchman OFAC + heuristics) |
| POST | /api/v1/transaction/check | Transaction monitoring (velocity, structuring) |
| GET | /api/v1/legal/{entity} | EUR-Lex + BAILII EDD lookup |
| GET | /api/v1/report/{id} | Retrieve screening report |
| GET | /api/v1/history/{entity} | ClickHouse screening history |
| GET | /api/v1/stats | Aggregate compliance statistics |
| GET | /api/v1/health | Service health check |
| GET | /api/v1/dashboard/overview | CEO dashboard overview |

---

## Notes for ChatGPT integration

- The API runs on GMKtec (192.168.0.72:8090), not publicly accessible
- For ChatGPT Actions: expose via ngrok tunnel or Cloudflare Tunnel when testing
- Production: nginx reverse proxy with SSL termination on port 443
- Authentication: token configured in \`/data/banxe/.env\` as \`API_KEY\`
MDEOF

echo "[export-openapi] Spec written → ${OUT_SPEC}"
echo "[export-openapi] Done."
