#!/bin/bash
set -euo pipefail

# aider-banxe.sh — Aider через LiteLLM с умной маршрутизацией
# Usage: bash aider-banxe.sh [--fast|--full|--banxe|--unrestricted] [aider args...]

LITELLM="http://localhost:4000/v1"
KEY="anything"

# Первый аргумент — режим (или просто передаётся в Aider)
MODE="${1:-}"

case "$MODE" in
  --fast)         MODEL="glm-4-flash"; shift ;;
  --full)         MODEL="qwen3-30b"; shift ;;
  --banxe)        MODEL="qwen3-banxe"; shift ;;
  --unrestricted) MODEL="gpt-oss-20b"; shift ;;
  *)              MODEL="qwen3-30b" ;;   # default: full
esac

echo "[aider-banxe] Model: $MODEL via LiteLLM :4000"

aider \
  --openai-api-base "$LITELLM" \
  --openai-api-key "$KEY" \
  --model "$MODEL" \
  --auto-commits \
  "$@"
