#!/bin/bash
# CANON Preflight — запускается как Claude Code hook (PreToolUse)
# Проверяет что CANON modules загружены и доступны

CANON_DIR="$(dirname "$0")/.."
REQUIRED_MODULES=("CORE.md" "DEV.md" "DECISION.md")
ERRORS=0

for mod in "${REQUIRED_MODULES[@]}"; do
  if [ ! -f "$CANON_DIR/modules/$mod" ]; then
    echo "CANON PREFLIGHT FAIL: missing $mod"
    ERRORS=$((ERRORS + 1))
  fi
done

# Check active profile
PROFILE="${CANON_PROFILE:-DEV}"
if [ "$PROFILE" = "LEGAL" ] && [ ! -f "$CANON_DIR/modules/FR_MODULE.md" ]; then
  echo "CANON PREFLIGHT FAIL: LEGAL profile requires FR_MODULE.md"
  ERRORS=$((ERRORS + 1))
fi

if [ $ERRORS -gt 0 ]; then
  echo "CANON PREFLIGHT: $ERRORS errors — fix before proceeding"
  exit 1
fi

echo "CANON PREFLIGHT OK — profile: $PROFILE, modules: $(ls $CANON_DIR/modules/*.md | wc -l)"
exit 0
