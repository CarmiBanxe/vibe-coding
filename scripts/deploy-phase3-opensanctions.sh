#!/usr/bin/env bash
# deploy-phase3-opensanctions.sh — Yente (OpenSanctions) stub deploy on GMKtec
#
# ADR-009: OpenSanctions/Yente — MIT licence, Phase 3 primary sanctions/PEP source.
# Port:    8086 (per SERVICE-MAP.md)
# Primary: Yente :8086  → sanctions_check.py (POST /match)
# Fallback: Watchman :8084 (existing, remains active)
#
# What this script does:
#   [1/5] Verify dependencies on GMKtec (docker, docker compose)
#   [2/5] Create deploy directory + write docker-compose.yml, manifest.yml, .env.example
#   [3/5] Pull Yente image + docker compose up -d
#   [4/5] Health check (retry 3×30s)
#   [5/5] Print integration TODO + next steps
#
# Usage:
#   bash scripts/deploy-phase3-opensanctions.sh [--dry-run]
#
# After deploy:
#   Test:    ssh gmktec 'curl -s http://localhost:8086/ | python3 -m json.tool'
#   Reindex: ssh gmktec 'cd /opt/banxe/opensanctions && docker compose run --rm app yente reindex -f'
#   Logs:    ssh gmktec 'cd /opt/banxe/opensanctions && docker compose logs -f --tail=50'

set -euo pipefail

FLAG_DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  FLAG_DRY_RUN=true
  echo "[DRY RUN] — no changes will be made on GMKtec"
fi

DEPLOY_DIR="/opt/banxe/opensanctions"
COMPOSE_PROJECT="banxe-opensanctions"
YENTE_IMAGE="ghcr.io/opensanctions/yente"
YENTE_VERSION="3.12.0"    # version pin — update via ADR-009 review
YENTE_PORT="8086"          # per SERVICE-MAP.md
HEALTH_RETRIES=6
HEALTH_WAIT=20

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  BANXE Phase 3 — OpenSanctions/Yente deploy (ADR-009)"
echo "  Target:  GMKtec:${YENTE_PORT}"
echo "  Image:   ${YENTE_IMAGE}:${YENTE_VERSION}"
echo "  Dir:     ${DEPLOY_DIR}"
echo "══════════════════════════════════════════════════════════════════"
echo ""

if $FLAG_DRY_RUN; then
  echo "[DRY RUN] Skipping all SSH commands."
  echo "Would create: ${DEPLOY_DIR}/{docker-compose.yml,manifest.yml,.env.example}"
  echo "Would pull + start: ${YENTE_IMAGE}:${YENTE_VERSION} on port ${YENTE_PORT}"
  exit 0
fi

# ── [1/5] Verify dependencies ─────────────────────────────────────────────────
echo "[1/5] Checking dependencies on GMKtec..."

ssh gmktec 'docker --version && docker compose version' 2>&1 | sed 's/^/  /'

echo "  OK: docker available"

# ── [2/5] Create deploy directory + config files ──────────────────────────────
echo ""
echo "[2/5] Creating ${DEPLOY_DIR} and config files..."

ssh gmktec "mkdir -p ${DEPLOY_DIR}/data"

ssh gmktec "cat > ${DEPLOY_DIR}/docker-compose.yml" <<'COMPOSE_EOF'
version: "3.8"

services:
  app:
    image: ghcr.io/opensanctions/yente:3.12.0
    container_name: banxe-yente
    restart: unless-stopped
    ports:
      - "8086:8000"
    environment:
      YENTE_MANIFEST: /app/manifest.yml
      YENTE_LOG_LEVEL: INFO
      YENTE_CACHE_SIZE: "10000"
    env_file:
      - .env
    volumes:
      - ./manifest.yml:/app/manifest.yml:ro
      - yente-data:/var/lib/yente
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8000/"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

volumes:
  yente-data:
    driver: local
COMPOSE_EOF

ssh gmktec "cat > ${DEPLOY_DIR}/manifest.yml" <<'MANIFEST_EOF'
# manifest.yml — Yente dataset manifest (OpenSanctions/BANXE)
# Governance: update via ADR-009 quarterly review
# Add local BANXE datasets by uncommenting the 'local_dataset' section below.

datasets:
  - name: default
    title: "OpenSanctions Default Catalog"
    # Covers: OFAC SDN, UN Consolidated, EU Sanctions, UK OFSI, US BIS
    # ~200K+ entities indexed; updated weekly by OpenSanctions
    type: catalog
    entry: https://data.opensanctions.org/datasets/latest/default/index.json

  - name: pep_wikidata
    title: "PEP — Wikidata (Public CC0)"
    # Politically Exposed Persons from Wikidata
    type: catalog
    entry: https://data.opensanctions.org/datasets/latest/wd_peps/index.json

  # ── Local BANXE dataset (Phase 4 — custom internal list) ─────────────────
  # Uncomment and populate /opt/banxe/opensanctions/data/banxe_internal.csv
  # when custom entity watchlist is ready.
  #
  # - name: banxe_internal
  #   title: "BANXE Internal Watchlist"
  #   type: nomenklatura
  #   path: /var/lib/yente/datasets/banxe_internal.yml
MANIFEST_EOF

ssh gmktec "cat > ${DEPLOY_DIR}/.env.example" <<'ENV_EOF'
# .env.example — copy to .env and fill in secrets
# These are passed to Yente container via env_file

# Optional: API key to restrict /match endpoint (recommended for production)
# YENTE_API_KEY=change_me_before_production

# Optional: increase if GMKtec has memory pressure (default: 10000)
# YENTE_CACHE_SIZE=5000

# Optional: set to DEBUG for troubleshooting
# YENTE_LOG_LEVEL=INFO
ENV_EOF

echo "  OK: config files written"

# ── [3/5] Pull image + start ──────────────────────────────────────────────────
echo ""
echo "[3/5] Pulling ${YENTE_IMAGE}:${YENTE_VERSION} and starting..."

ssh gmktec "cd ${DEPLOY_DIR} && docker compose pull --quiet"
echo "  OK: image pulled"

ssh gmktec "cd ${DEPLOY_DIR} && docker compose up -d"
echo "  OK: container started"

# ── [4/5] Health check ────────────────────────────────────────────────────────
echo ""
echo "[4/5] Health check (up to $((HEALTH_RETRIES * HEALTH_WAIT))s for initial index)..."

HEALTHY=false
for i in $(seq 1 $HEALTH_RETRIES); do
  echo -n "  Attempt $i/${HEALTH_RETRIES}... "
  STATUS=$(ssh gmktec "curl -sf -o /dev/null -w '%{http_code}' http://localhost:${YENTE_PORT}/ 2>/dev/null || echo '000'")
  if [[ "$STATUS" == "200" ]]; then
    echo "HTTP ${STATUS} — OK"
    HEALTHY=true
    break
  else
    echo "HTTP ${STATUS} — waiting ${HEALTH_WAIT}s"
    sleep $HEALTH_WAIT
  fi
done

if ! $HEALTHY; then
  echo ""
  echo "  WARN: Yente not yet healthy after $((HEALTH_RETRIES * HEALTH_WAIT))s"
  echo "  This is expected on first start — initial indexing can take 5-15 minutes."
  echo "  Monitor: ssh gmktec 'cd ${DEPLOY_DIR} && docker compose logs -f --tail=50'"
  echo ""
else
  VERSION_RESP=$(ssh gmktec "curl -sf http://localhost:${YENTE_PORT}/ 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(\"version\",\"?\"))' 2>/dev/null || echo '?'")
  echo "  Yente version: ${VERSION_RESP}"
fi

# ── [5/5] Summary + next steps ────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  Yente (OpenSanctions) stub deployed — Phase 3"
echo ""
echo "  Endpoint: http://[gmktec]:${YENTE_PORT}/"
echo "  Match:    POST http://[gmktec]:${YENTE_PORT}/match"
echo "  Status:   GET  http://[gmktec]:${YENTE_PORT}/entities"
echo ""
echo "  Deploy dir: ${DEPLOY_DIR}"
echo ""
echo "  TODO (next steps):"
echo "    1. Wait for initial index (5-15 min, check logs):"
echo "       ssh gmktec 'cd ${DEPLOY_DIR} && docker compose logs -f'"
echo ""
echo "    2. Test a match query:"
echo "       ssh gmktec 'curl -s -X POST http://localhost:${YENTE_PORT}/match \\'"
echo "         -H \"Content-Type: application/json\" \\'"
echo "         -d \"{\\\"queries\\\":{\\\"q1\\\":{\\\"schema\\\":\\\"Person\\\",\\\"properties\\\":{\\\"name\\\":[\\\"Vladimir Putin\\\"]}}}}\" | python3 -m json.tool'"
echo ""
echo "    3. Update sanctions_check.py (ADR-009 routing):"
echo "       Primary → Yente :${YENTE_PORT}/match"
echo "       Fallback → Watchman :8084 (existing)"
echo ""
echo "    4. Add to scenario_registry.yaml:"
echo "       SCN-002 engines: + sanctions_check mode:ml rule_id:MODEL-YENTE-FUZZY-NAME"
echo ""
echo "    5. Force reindex when manifest changes:"
echo "       ssh gmktec 'cd ${DEPLOY_DIR} && docker compose run --rm app yente reindex -f'"
echo ""
echo "  NOTE: Production hardening needed before go-live:"
echo "    - Copy .env.example → .env, set YENTE_API_KEY"
echo "    - Add nginx reverse proxy + TLS"
echo "    - Add to banxe-drift-monitor if screening metrics needed"
echo "══════════════════════════════════════════════════════════════════"
echo ""
