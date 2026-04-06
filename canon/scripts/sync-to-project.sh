#!/bin/bash
set -euo pipefail

# Описание: синхронизировать CANON в целевой проект
# Usage: bash ~/developer/canon/scripts/sync-to-project.sh [vibe-coding|banxe-architecture|guiyon|all]

CANON_DIR="$HOME/developer/canon"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  echo "Usage: bash scripts/sync-to-project.sh [vibe-coding|banxe-architecture|guiyon|all]"
  echo ""
  echo "Целевые проекты:"
  echo "  vibe-coding        — BANXE/DEV профиль"
  echo "  banxe-architecture — BANXE/DEV профиль"
  echo "  guiyon             — LEGAL профиль (только юридические модули)"
  echo "  all                — все проекты"
  exit 1
fi

sync_project() {
  local name="$1"
  local dir="$2"
  local profile="$3"

  echo ""
  echo "=== Синхронизация: $name ($profile) ==="

  if [ ! -d "$dir" ]; then
    echo -e "${YELLOW}⚠️  Пропущено: $dir не существует${NC}"
    return
  fi

  DEST="$dir/.canon"
  mkdir -p "$DEST/modules" "$DEST/rules" "$DEST/scripts"

  # Всегда копировать: CORE, DOC, DECISION + общие rules
  cp "$CANON_DIR/CANON.md" "$DEST/"
  cp "$CANON_DIR/modules/CORE.md" "$DEST/modules/"
  cp "$CANON_DIR/modules/DOC.md" "$DEST/modules/"
  cp "$CANON_DIR/modules/DECISION.md" "$DEST/modules/"
  cp "$CANON_DIR/rules/DIALOGUE.md" "$DEST/rules/"
  cp "$CANON_DIR/rules/AUTOMATION.md" "$DEST/rules/"
  cp "$CANON_DIR/rules/REPORTING.md" "$DEST/rules/"
  cp "$CANON_DIR/rules/VERIFICATION.md" "$DEST/rules/"
  cp "$CANON_DIR/scripts/check-canon.sh" "$DEST/scripts/"
  cp "$CANON_DIR/scripts/activate-profile.sh" "$DEST/scripts/"

  case "$profile" in
    banxe|dev)
      cp "$CANON_DIR/modules/DEV.md" "$DEST/modules/"
      cp "$CANON_DIR/rules/COLLABORATION.md" "$DEST/rules/"
      echo -e "${GREEN}✅ DEV модули добавлены${NC}"
      ;;
    legal)
      cp "$CANON_DIR/modules/LEGAL.md" "$DEST/modules/"
      cp "$CANON_DIR/modules/FR_MODULE.md" "$DEST/modules/"
      echo -e "${GREEN}✅ LEGAL + FR_MODULE добавлены${NC}"
      ;;
    mixed)
      cp "$CANON_DIR/modules/DEV.md" "$DEST/modules/"
      cp "$CANON_DIR/modules/LEGAL.md" "$DEST/modules/"
      cp "$CANON_DIR/modules/FR_MODULE.md" "$DEST/modules/"
      cp "$CANON_DIR/rules/COLLABORATION.md" "$DEST/rules/"
      echo -e "${GREEN}✅ Все модули добавлены (MIXED)${NC}"
      ;;
  esac

  # Создать указатель профиля
  echo "$profile" > "$DEST/.active-profile"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DEST/.synced-at"

  echo -e "${GREEN}✅ $name синхронизирован → $DEST${NC}"
}

echo "=== Step 1: Проверка источника ==="
bash "$CANON_DIR/scripts/check-canon.sh" > /dev/null 2>&1 || {
  echo -e "${RED}ОШИБКА: CANON неполный — сначала проверьте $CANON_DIR${NC}"
  exit 1
}
echo -e "${GREEN}OK${NC}: CANON источник готов"

echo ""
echo "=== Step 2: Синхронизация ==="
case "$TARGET" in
  vibe-coding)
    sync_project "vibe-coding" "$HOME/vibe-coding" "banxe"
    ;;
  banxe-architecture)
    sync_project "banxe-architecture" "$HOME/banxe-architecture" "banxe"
    ;;
  guiyon)
    # LEGAL-only sync для guiyon — НЕ включать DEV модули
    sync_project "guiyon" "$HOME/guiyon" "legal"
    ;;
  all)
    sync_project "vibe-coding" "$HOME/vibe-coding" "banxe"
    sync_project "banxe-architecture" "$HOME/banxe-architecture" "banxe"
    # guiyon пропускается для all — отдельная команда во избежание ошибок
    echo ""
    echo -e "${YELLOW}⚠️  guiyon пропущен при 'all' — запустите отдельно: sync-to-project.sh guiyon${NC}"
    ;;
  *)
    echo -e "${RED}ОШИБКА: Неизвестный проект '$TARGET'${NC}"
    exit 1
    ;;
esac

echo ""
echo "=== Step 3: Коммит ==="
if [ "$TARGET" = "all" ] || [ "$TARGET" = "vibe-coding" ]; then
  cd "$HOME/vibe-coding"
  if git diff --quiet && git diff --staged --quiet; then
    echo "vibe-coding: нет изменений"
  else
    git add .canon/
    git commit -m "chore(canon): sync CANON v1.0 from developer-core

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>" && git push
    echo -e "${GREEN}✅ vibe-coding: запушен${NC}"
  fi
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "banxe-architecture" ]; then
  cd "$HOME/banxe-architecture"
  if git diff --quiet && git diff --staged --quiet; then
    echo "banxe-architecture: нет изменений"
  else
    git add .canon/
    git commit -m "chore(canon): sync CANON v1.0 from developer-core

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>" && git push
    echo -e "${GREEN}✅ banxe-architecture: запушен${NC}"
  fi
fi

echo ""
echo -e "${GREEN}✅ Готово: CANON синхронизирован${NC}"
