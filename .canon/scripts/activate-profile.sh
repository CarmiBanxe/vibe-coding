#!/bin/bash
set -euo pipefail

# Описание: активировать профиль CANON (banxe | legal | mixed)
# Usage: bash ~/developer/canon/scripts/activate-profile.sh [banxe|legal|mixed]

CANON_DIR="$HOME/developer/canon"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROFILE="${1:-}"

if [ -z "$PROFILE" ]; then
  echo "Usage: bash scripts/activate-profile.sh [banxe|legal|mixed]"
  echo ""
  echo "Профили:"
  echo "  banxe  — BANXE/DEV: CORE + DOC + DEV + DECISION (LEGAL=off)"
  echo "  legal  — LEGAL: CORE + DOC + LEGAL + DECISION + FR_MODULE (DEV=off)"
  echo "  mixed  — MIXED: все модули, DEV primary + LEGAL overlay"
  exit 1
fi

echo "=== Step 1: Проверка профиля ==="
case "$PROFILE" in
  banxe)
    PROFILE_DISPLAY="BANXE/DEV"
    ACTIVE_MODULES="CORE DOC DEV DECISION"
    INACTIVE_MODULES="LEGAL FR_MODULE"
    ;;
  legal)
    PROFILE_DISPLAY="LEGAL"
    ACTIVE_MODULES="CORE DOC LEGAL DECISION FR_MODULE"
    INACTIVE_MODULES="DEV"
    ;;
  mixed)
    PROFILE_DISPLAY="MIXED"
    ACTIVE_MODULES="CORE DOC DEV LEGAL DECISION FR_MODULE"
    INACTIVE_MODULES=""
    ;;
  *)
    echo -e "${RED}ОШИБКА: Неизвестный профиль '$PROFILE'${NC}"
    echo "Допустимые: banxe | legal | mixed"
    exit 1
    ;;
esac

echo -e "Профиль: ${YELLOW}$PROFILE_DISPLAY${NC}"

echo ""
echo "=== Step 2: Активные модули ==="
for m in $ACTIVE_MODULES; do
  FILE="$CANON_DIR/modules/$m.md"
  if [ -f "$FILE" ]; then
    echo -e "${GREEN}✅ ACTIVE${NC}: $m"
  else
    echo -e "${RED}❌ MISSING${NC}: $m — файл не найден: $FILE"
  fi
done

if [ -n "$INACTIVE_MODULES" ]; then
  echo ""
  echo "=== Step 3: Неактивные модули ==="
  for m in $INACTIVE_MODULES; do
    echo -e "${BLUE}⏸  OFF${NC}: $m"
  done
fi

echo ""
echo "=== Step 4: Правила профиля ==="
case "$PROFILE" in
  banxe)
    echo "• Compliance через GAP-REGISTER + INVARIANTS"
    echo "• Тесты: baseline 747, регрессии недопустимы"
    echo "• Governance: CLASS_A авто, CLASS_B/C/D → человек"
    echo "• Один терминал = один проект (CANON 9)"
    echo "• GUIYON — абсолютный запрет"
    ;;
  legal)
    echo "• Все правовые ответы со ссылкой на статьи"
    echo "• FR_MODULE активен для французского права"
    echo "• КАНОН 7: предлагаю → пользователь одобряет"
    echo "• Не давать юридических советов как окончательных"
    ;;
  mixed)
    echo "• DEV-контекст сохраняется как primary"
    echo "• LEGAL активируется как overlay при юридических вопросах"
    echo "• После юридического ответа — возврат в DEV-режим"
    ;;
esac

echo ""
echo -e "${GREEN}✅ Профиль $PROFILE_DISPLAY активирован${NC}"
echo ""
echo "Для проверки: bash ~/developer/canon/scripts/check-canon.sh"
