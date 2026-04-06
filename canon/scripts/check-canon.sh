#!/bin/bash
set -euo pipefail

# Описание: проверить наличие и целостность CANON в текущем проекте
# Usage: bash ~/developer/canon/scripts/check-canon.sh

CANON_DIR="$HOME/developer/canon"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Step 1: Проверка CANON директории ==="
if [ ! -d "$CANON_DIR" ]; then
  echo -e "${RED}ОШИБКА: $CANON_DIR не найдена${NC}"
  exit 1
fi
echo -e "${GREEN}OK${NC}: $CANON_DIR существует"

echo ""
echo "=== Step 2: Проверка ключевых файлов ==="
REQUIRED_FILES=(
  "CANON.md"
  "modules/CORE.md"
  "modules/DOC.md"
  "modules/DEV.md"
  "modules/DECISION.md"
  "modules/LEGAL.md"
  "modules/FR_MODULE.md"
  "rules/DIALOGUE.md"
  "rules/COLLABORATION.md"
  "rules/AUTOMATION.md"
  "rules/REPORTING.md"
  "rules/VERIFICATION.md"
)

ALL_OK=true
for f in "${REQUIRED_FILES[@]}"; do
  if [ -f "$CANON_DIR/$f" ]; then
    echo -e "${GREEN}✅${NC} $f"
  else
    echo -e "${RED}❌${NC} $f — ОТСУТСТВУЕТ"
    ALL_OK=false
  fi
done

echo ""
echo "=== Step 3: Определение активного профиля ==="
CWD=$(pwd)
if [[ "$CWD" == *"vibe-coding"* ]] || [[ "$CWD" == *"banxe"* ]] || [[ "$CWD" == *"developer"* ]]; then
  PROFILE="BANXE/DEV"
elif [[ "$CWD" == *"guiyon"* ]] || [[ "$CWD" == *"ss1"* ]]; then
  PROFILE="LEGAL"
else
  PROFILE="CORE (базовый)"
fi
echo "Текущая директория: $CWD"
echo -e "Активный профиль: ${YELLOW}$PROFILE${NC}"

echo ""
echo "=== Итог ==="
if $ALL_OK; then
  echo -e "${GREEN}✅ CANON установлен корректно${NC}"
else
  echo -e "${RED}⚠️  CANON неполный — запустите: cd ~/developer && git pull${NC}"
  exit 1
fi
