#!/bin/bash
set -euo pipefail

# Ruflo orchestrator startup for BANXE AI Stack v2.0
# Usage: bash start-ruflo.sh [config.yaml]

CONFIG="${1:-$(dirname "$0")/config.yaml}"
LOG_DIR="/data/logs/ruflo"
mkdir -p "$LOG_DIR"

echo "[$(date)] Ruflo starting with config: $CONFIG"

echo "=== Step 1: Checking LiteLLM :4000 ==="
curl -sf http://localhost:4000/v1/models > /dev/null && \
  echo "✅ LiteLLM OK" || \
  { echo "❌ LiteLLM not responding on :4000"; exit 1; }

echo "=== Step 2: Checking Ollama :11434 ==="
curl -sf http://192.168.0.72:11434/api/tags > /dev/null && \
  echo "✅ Ollama OK" || \
  echo "⚠️  Ollama not responding (non-fatal, using LiteLLM cache)"

echo "=== Step 3: Checking OpenClaw bots ==="
for PORT in 18789 18791 18793; do
  curl -sf "http://localhost:${PORT}/api/health" > /dev/null 2>&1 && \
    echo "  ✅ Bot :${PORT} OK" || \
    echo "  ⚠️  Bot :${PORT} OFFLINE"
done

echo "=== Step 4: Checking MiroFish :5004 (backend) ==="
curl -sf http://localhost:5004/health > /dev/null && \
  echo "✅ MiroFish OK (frontend :3001, backend :5004)" || \
  echo "⚠️  MiroFish not deployed (cd /root/developer/mirofish && docker compose up -d)"

echo "=== Step 5: Checking Aider ==="
which aider > /dev/null 2>&1 && \
  echo "✅ Aider found: $(aider --version 2>/dev/null || echo 'version unknown')" || \
  echo "⚠️  Aider not found in PATH"

echo ""
echo "[$(date)] Ruflo ready — BANXE AI Stack v2.0"
echo "Partners: Claude Code + Aider CLI + MiroFish + Ruflo"
echo "Infra: MetaClaw/OpenClaw + LiteLLM :4000 + Ollama :11434"
