#!/bin/bash
###############################################################################
# set-training-token.sh — установить TRAINING_DATA_TOKEN в vibe-coding secrets
#
# Использование (на Legion):
#   bash scripts/set-training-token.sh <PAT_VALUE>
#
# PAT нужен с правами: repo (read/write) на CarmiBanxe/banxe-training-data
# Готовый токен: oleg-mirror-banxe-training (expires Jul 2026)
#   GitHub → Settings → Personal Access Tokens → найди токен и скопируй значение
#   Если значение не сохранено — создай новый PAT с правами repo
###############################################################################

set -euo pipefail

GH="$HOME/.local/bin/gh"
REPO="CarmiBanxe/vibe-coding"
SECRET_NAME="TRAINING_DATA_TOKEN"

if [ -z "${1:-}" ]; then
    echo "Использование: bash $0 <PAT_VALUE>"
    echo ""
    echo "Где взять PAT:"
    echo "  https://github.com/settings/tokens"
    echo "  Нужен токен с правами: repo (read/write)"
    echo "  Уже существует: oleg-mirror-banxe-training (expires Jul 2 2026)"
    exit 1
fi

TOKEN_VALUE="$1"

# Авторизуемся в gh через тот же токен
echo "Авторизация gh CLI..."
echo "$TOKEN_VALUE" | "$GH" auth login --with-token --git-protocol ssh

echo "Установка секрета $SECRET_NAME в $REPO..."
echo "$TOKEN_VALUE" | "$GH" secret set "$SECRET_NAME" --repo "$REPO"

echo ""
echo "Проверка:"
"$GH" secret list --repo "$REPO"

echo ""
echo "Готово! Workflow extract-training-data.yml теперь активен."
echo "Следующий push в main запустит синхронизацию corpus."
