#!/bin/bash
# fix-compliance-workspace.sh
#
# Три проблемы:
#   1. workspace-moa-compliance/SOUL.md — старый, Syria в BLOCK, fake ClickHouse-логи
#   2. think: false — прямой JS-патч в openclaw/dist/stream-CBdzTVlm.js (line 387)
#   3. Все субагент-workspace получают единый правильный SOUL.md
#
# Запускать на Legion: bash scripts/fix-compliance-workspace.sh

set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JS_FILE="/usr/lib/node_modules/openclaw/dist/stream-CBdzTVlm.js"

echo "============================================"
echo "  Fix: compliance workspace + think patch"
echo "============================================"
echo ""

# ─────────────────────────────────────────────────────────
# ШАГ 1: JS-патч think:false в ollamaOptions (line ~387)
# ─────────────────────────────────────────────────────────
echo "[1/4] Патч stream-CBdzTVlm.js — think:false в ollamaOptions..."

# Бэкап
ssh gmktec "cp $JS_FILE ${JS_FILE}.bak 2>/dev/null || sudo cp $JS_FILE ${JS_FILE}.bak && echo 'backup OK'"

# Проверяем текущее состояние
CURRENT=$(ssh gmktec "grep -o 'num_ctx: model.contextWindow ?? [0-9]*}' $JS_FILE | head -1")
echo "  Текущее: $CURRENT"

if ssh gmktec "grep -q 'num_ctx: model.contextWindow ?? 65536, think: false' $JS_FILE"; then
    echo "  think: false уже вставлен ✓"
else
    ssh gmktec "sed -i 's/num_ctx: model\.contextWindow ?? 65536 }/num_ctx: model.contextWindow ?? 65536, think: false }/g' $JS_FILE"
    AFTER=$(ssh gmktec "grep -o 'num_ctx: model.contextWindow ?? [^}]*}' $JS_FILE | head -1")
    echo "  После патча: $AFTER"
fi

# ─────────────────────────────────────────────────────────
# ШАГ 2: compliance workspace — новый SOUL.md
# ─────────────────────────────────────────────────────────
echo ""
echo "[2/4] Обновляем workspace-moa-compliance/SOUL.md..."

cat << 'SOUL_EOF' | ssh gmktec 'cat > /tmp/compliance_soul.md'
/no_think

# Banxe Compliance Agent — Rules

ШАГ 1 — САНКЦИОННАЯ ПРОВЕРКА (ПЕРВЫМ):
REJECT (одна строка): Россия/РФ, Беларусь, Иран, КНДР, Куба, Мьянма, Афганистан, Венесуэла (гос.), Крым, ДНР, ЛНР
EDD/HOLD (НЕ REJECT): Сирия, Ирак, Ливан, Йемен, Гаити, Мали
НЕ заблокированы: Южная Корея, ОАЭ, Япония, Израиль, Турция, Индия, США, EU, UK

→ REJECT: "REJECT. Banxe не проводит операции с [страна] — заблокированная юрисдикция."

ШАГ 2 — СУММА:
>£10,000 → СТАТУС: HOLD. Требуется: EDD, Source of Funds, HITL одобрение.
£1,000–£10,000 → СТАТУС: MONITOR.
<£1,000 → СТАТУС: ALLOW.

СТРОГО ЗАПРЕЩЕНО в ответах:
- Приветствия любые ("Привет Mark!", "Hello!")
- Эмодзи (🚀 ✅ ❌ 🇷🇺 и любые другие)
- SumSub / Dow Jones / LexisNexis / любые external vendor API (не подключены)
- Risk Score без реальных данных из системы
- ClickHouse-ссылки как результат ("banxe.aml_alerts → статус HOLD")
- Таблицы с NULL/пустыми значениями
- Вопросы в конце ("Готовы ли вы...?")
- Объяснение хода мысли перед ответом

СТИЛЬ: русский. 3-5 строк. Только факт + статус + что требуется.
SOUL_EOF

ssh gmktec "cp /tmp/compliance_soul.md /home/mmber/.openclaw/workspace-moa-compliance/SOUL.md"
echo "  workspace-moa-compliance/SOUL.md обновлён ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 3: Обновляем SOUL.md во ВСЕХ субагент-workspace
# ─────────────────────────────────────────────────────────
echo ""
echo "[3/4] Синхронизируем SOUL.md во все субагент-workspace..."

WORKSPACES=(
    "workspace-moa-supervisor"
    "workspace-moa-kyc"
    "workspace-moa-risk"
    "workspace-moa-analytics"
    "workspace-moa-client-service"
    "workspace-moa-operations"
    "workspace-moa-it-devops"
    "workspace-moa-crypto"
)

for WS in "${WORKSPACES[@]}"; do
    WS_PATH="/home/mmber/.openclaw/$WS"
    if ssh gmktec "test -d $WS_PATH"; then
        ssh gmktec "cp /tmp/compliance_soul.md $WS_PATH/SOUL.md && echo '  $WS ✓'"
    fi
done

# ─────────────────────────────────────────────────────────
# ШАГ 4: Перезапуск и проверка
# ─────────────────────────────────────────────────────────
echo ""
echo "[4/4] Перезапуск OpenClaw..."
ssh gmktec "sudo systemctl restart openclaw-gateway-moa.service"
echo "  Ожидаем 10 секунд..."
sleep 10

BOT_STATUS=$(ssh gmktec "sudo systemctl is-active openclaw-gateway-moa.service")
JS_CHECK=$(ssh gmktec "grep -o 'think: false' $JS_FILE | head -1")
COMPLIANCE_CHECK=$(ssh gmktec "head -1 /home/mmber/.openclaw/workspace-moa-compliance/SOUL.md")

echo ""
echo "  Бот: $BOT_STATUS"
echo "  JS think: false: ${JS_CHECK:-НЕ НАЙДЕН}"
echo "  Compliance SOUL.md[1]: $COMPLIANCE_CHECK"

# Быстрый тест через Ollama CLI
echo ""
echo "  Тест think:false — запрос к qwen3:30b-a3b..."
THINK_TEST=$(ssh gmktec "ollama run qwen3:30b-a3b 'транзакция 500 GBP из Сирии' 2>/dev/null | head -5")
echo "  $THINK_TEST"

# Коммит
echo ""
cd "$REPO_DIR"
git add scripts/fix-compliance-workspace.sh
git commit -m "fix: compliance workspace SOUL.md + JS think:false patch

- workspace-moa-compliance/SOUL.md: Syria→EDD/HOLD, no fake vendor data
- All subagent workspaces: unified SOUL.md with style rules
- stream-CBdzTVlm.js: think:false in ollamaOptions (unconditional API-level fix)"
git pull --rebase origin main
git push origin main

echo ""
echo "============================================"
echo "  ГОТОВО"
echo "============================================"
echo ""
echo "  Протестируй в Telegram:"
echo "  1. 'транзакция из России'         → REJECT (1 строка, без Привет)"
echo "  2. 'транзакция 50000 GBP из Южной Кореи' → HOLD (3-5 строк)"
echo "  3. 'транзакция 500 GBP из Сирии'  → HOLD (не REJECT)"
echo ""
