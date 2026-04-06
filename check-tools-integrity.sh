#!/bin/bash
###############################################################################
# check-tools-integrity.sh — Проверяет что все верификационные инструменты
# на месте. Если что-то удалено — сигнализирует через SYSTEM-STATE.md
# Вызывается из ctio-watcher.sh каждые 5 минут.
###############################################################################

SNAPSHOT="/data/logs/verification-tools-snapshot.txt"
ALERT_FILE="/data/logs/tool-removal-alerts.log"

REQUIRED_TOOLS="semgrep snyk pre-commit"
MISSING=""
INSTALLED=""

for TOOL in $REQUIRED_TOOLS; do
    if command -v "$TOOL" &>/dev/null; then
        VER=$($TOOL --version 2>/dev/null | head -1)
        INSTALLED="${INSTALLED}| $TOOL | ✓ ACTIVE | $VER |\n"
    else
        MISSING="${MISSING}| $TOOL | ⚠ УДАЛЁН/НЕ НАЙДЕН | — |\n"
        echo "$(date '+%Y-%m-%d %H:%M'): ⚠ ALERT: $TOOL УДАЛЁН с сервера!" >> "$ALERT_FILE"
    fi
done

# CodeRabbit может быть под разными именами
if command -v coderabbit &>/dev/null || command -v cr &>/dev/null; then
    INSTALLED="${INSTALLED}| coderabbit | ✓ ACTIVE | CLI |\n"
else
    # Не алерт — CodeRabbit работает через GitHub, CLI опционален
    INSTALLED="${INSTALLED}| coderabbit | ○ CLI не установлен (GitHub OK) | — |\n"
fi

# Вывод для вставки в SYSTEM-STATE.md
echo "## Верификационные инструменты (КАНОН)"
echo ""
if [ -n "$MISSING" ]; then
    echo "### ⚠ ALERT: ИНСТРУМЕНТЫ УДАЛЕНЫ"
    echo "Следующие инструменты были удалены с сервера. Это нарушение канона."
    echo ""
fi
echo "| Инструмент | Статус | Версия |"
echo "|------------|--------|--------|"
echo -e "$INSTALLED"
if [ -n "$MISSING" ]; then
    echo -e "$MISSING"
fi

# Semgrep правила
if [ -f "/data/vibe-coding/.semgrep/banxe-rules.yml" ]; then
    RULES=$(grep -c "^  - id:" /data/vibe-coding/.semgrep/banxe-rules.yml 2>/dev/null || echo "?")
    echo ""
    echo "### Semgrep правила"
    echo "- Файл: \`.semgrep/banxe-rules.yml\`"
    echo "- Правил: $RULES"
else
    echo ""
    echo "### ⚠ Semgrep правила ОТСУТСТВУЮТ"
    echo "Файл .semgrep/banxe-rules.yml удалён или не создан."
fi

# Pre-commit hooks
if [ -f "/data/vibe-coding/.pre-commit-config.yaml" ]; then
    echo ""
    echo "### Pre-commit hooks"
    echo "- Статус: ✓ Настроены"
else
    echo ""
    echo "### ⚠ Pre-commit hooks НЕ настроены"
fi
