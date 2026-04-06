#!/usr/bin/env bash
# publish-architecture-repo.sh — создаёт GitHub репо и пушит banxe-architecture
# Запускать ПОСЛЕ gh auth login
# Usage: bash scripts/publish-architecture-repo.sh
set -euo pipefail

ARCH_DIR="$HOME/banxe-architecture"

if [[ ! -d "$ARCH_DIR/.git" ]]; then
  echo "ERROR: $ARCH_DIR не инициализирован как git-репозиторий"
  echo "  Что-то пошло не так — файлы должны быть там."
  exit 1
fi

# Check gh auth
if ! gh auth status --active 2>/dev/null; then
  echo "ERROR: gh не авторизован. Запусти: gh auth login"
  exit 1
fi

echo "Создаю приватный репозиторий CarmiBanxe/banxe-architecture..."
gh repo create CarmiBanxe/banxe-architecture \
  --private \
  --description "Banxe Architecture — согласованные решения, инварианты, ограничения. Все проекты ОБЯЗАНЫ соответствовать." \
  2>&1 || {
    # Repo may already exist — try to continue
    echo "WARN: gh repo create вернул ошибку (возможно репо уже существует)"
  }

echo "Добавляю remote и пушу..."
cd "$ARCH_DIR"
git remote remove origin 2>/dev/null || true
git remote add origin "git@github.com:CarmiBanxe/banxe-architecture.git"
git push -u origin main

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  banxe-architecture опубликован!"
echo "  URL: https://github.com/CarmiBanxe/banxe-architecture"
echo ""
echo "  Структура:"
ls -1 "$ARCH_DIR/" | sed 's/^/    /'
echo "══════════════════════════════════════════════════════════════"
