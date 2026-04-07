#!/bin/bash
set -euo pipefail

# parallel-verify.sh — 3-модельная верификация через LiteLLM параллельно
# Usage:
#   bash parallel-verify.sh "проверь этот rule..."
#   bash parallel-verify.sh --file src/compliance/sanctions_check.py

LITELLM="http://localhost:4000/v1"
KEY="anything"
TMPDIR=$(mktemp -d)

# Подготовить prompt
if [ "${1:-}" = "--file" ]; then
  FILE="${2:-}"
  [ -f "$FILE" ] || { echo "ERROR: file not found: $FILE"; exit 1; }
  CONTENT=$(head -200 "$FILE")
  PROMPT="Review this code for compliance issues, security vulnerabilities, and correctness. Be concise.\n\n\`\`\`\n${CONTENT}\n\`\`\`"
else
  PROMPT="${*}"
fi

[ -z "$PROMPT" ] && { echo "Usage: parallel-verify.sh \"text\" OR --file path.py"; exit 1; }

declare -A MODELS=(
  ["compliance"]="qwen3-banxe"
  ["security"]="glm-4-flash"
  ["alternative"]="gpt-oss-20b"
)

echo "════════════ PARALLEL VERIFICATION (3 models via LiteLLM :4000) ════════════"

# Запустить 3 модели параллельно
for ROLE in "${!MODELS[@]}"; do
  MODEL="${MODELS[$ROLE]}"
  (
    RESPONSE=$(curl -sf "$LITELLM/chat/completions" \
      -H "Authorization: Bearer $KEY" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"${MODEL}\",
        \"messages\": [{\"role\":\"user\",\"content\":\"${PROMPT}\"}],
        \"max_tokens\": 1000,
        \"temperature\": 0.1
      }" 2>/dev/null || echo '{"error":"timeout"}')
    echo "$RESPONSE" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('message',{}).get('content','ERROR: '+str(d.get('error',''))))" \
      2>/dev/null > "${TMPDIR}/${ROLE}.txt"
    echo "  [${ROLE}] done (${MODEL})"
  ) &
done

wait

echo ""
for ROLE in compliance security alternative; do
  echo "─── ${ROLE^^} (${MODELS[$ROLE]}) ───"
  cat "${TMPDIR}/${ROLE}.txt" 2>/dev/null || echo "[TIMEOUT/ERROR]"
  echo ""
done

echo "════════════ CONSENSUS ════════════"
PASS_COUNT=0
for ROLE in compliance security alternative; do
  grep -qiE "(no issues|looks good|pass|correct|clean|approved)" \
    "${TMPDIR}/${ROLE}.txt" 2>/dev/null && PASS_COUNT=$((PASS_COUNT + 1)) || true
done

if [ "$PASS_COUNT" -ge 2 ]; then
  echo "Result: ${PASS_COUNT}/3 models PASS → ✅ CONSENSUS PASS"
  EXIT_CODE=0
else
  echo "Result: ${PASS_COUNT}/3 models PASS → ⚠️  NEEDS REVIEW"
  EXIT_CODE=1
fi

rm -rf "$TMPDIR"
exit $EXIT_CODE
