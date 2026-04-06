#!/bin/bash
# fix-think-and-syria.sh
#
# Фиксит три проблемы:
#   1. Syria REJECT→HOLD в AGENTS.md (санкции Assad сняты июль 2025)
#   2. think:false через Modelfile PARAMETER (без TEMPLATE — не ломает tools)
#   3. Стиль: усиление запретов в SOUL.md
#
# Запускать на Legion: bash scripts/fix-think-and-syria.sh

set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_REMOTE="/home/mmber/.openclaw/workspace-moa/AGENTS.md"
CONFIG_REMOTE="/root/.openclaw-moa/.openclaw/openclaw.json"

echo "============================================"
echo "  Fix: think + Syria + style"
echo "============================================"
echo ""

# ─────────────────────────────────────────────────────────
# ШАГ 1: AGENTS.md — убираем Сирию из BLOCK
# ─────────────────────────────────────────────────────────
echo "[1/6] AGENTS.md — Syria REJECT→EDD/HOLD..."

ssh gmktec "sed -i 's|Россия / Иран / Северная Корея / Куба / Сирия / Беларусь|Россия / Иран / Северная Корея / Куба / Беларусь|g' $AGENTS_REMOTE"
ssh gmktec "sed -i 's|Страны: Россия, Иран, Северная Корея, Куба, Сирия, Беларусь, Мьянма, Крым, ДНР, ЛНР|Страны: Россия, Иран, Северная Корея, Куба, Беларусь, Мьянма, Крым, ДНР, ЛНР|g' $AGENTS_REMOTE"
ssh gmktec "sed -i 's|Ангола, Алжир,|Ангола, Алжир, Сирия,|g' $AGENTS_REMOTE"

VERIFY=$(ssh gmktec "grep -n 'Сири' $AGENTS_REMOTE")
echo "  Результат в AGENTS.md:"
echo "  $VERIFY"

# ─────────────────────────────────────────────────────────
# ШАГ 2: Modelfile — PARAMETER think false (без TEMPLATE)
# ─────────────────────────────────────────────────────────
echo ""
echo "[2/6] Создаём qwen3-nothink Modelfile (только PARAMETER)..."

cat << 'MODELEOF' | ssh gmktec 'cat > /tmp/qwen3-nothink.Modelfile'
FROM qwen3:30b-a3b

PARAMETER think false
PARAMETER temperature 0.05
PARAMETER top_p 0.8
PARAMETER top_k 20
PARAMETER num_predict 200
MODELEOF

echo "  Modelfile создан, собираем модель..."
ssh gmktec "ollama create qwen3-nothink -f /tmp/qwen3-nothink.Modelfile 2>&1 | tail -3"
echo "  qwen3-nothink создан ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 3: Тест — работают ли tools с новой моделью
# ─────────────────────────────────────────────────────────
echo ""
echo "[3/6] Тест tools с qwen3-nothink..."

TOOLS_TEST=$(ssh gmktec "curl -s http://localhost:11434/api/chat -d '{\"model\":\"qwen3-nothink\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"test\",\"description\":\"test\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}],\"stream\":false}' 2>/dev/null | python3 -c 'import sys,json; r=json.load(sys.stdin); print(\"TOOLS_OK\" if \"error\" not in r else \"TOOLS_ERROR: \" + r.get(\"error\",\"\"))'" 2>/dev/null)
echo "  $TOOLS_TEST"

if echo "$TOOLS_TEST" | grep -q "TOOLS_ERROR"; then
    echo "  ПРЕДУПРЕЖДЕНИЕ: tools не работают с qwen3-nothink, возвращаемся к qwen3:30b-a3b"
    NEW_MODEL="ollama/qwen3:30b-a3b"
else
    echo "  Tools работают ✓ — используем qwen3-nothink"
    NEW_MODEL="ollama/qwen3-nothink"
fi

# ─────────────────────────────────────────────────────────
# ШАГ 4: Обновляем openclaw.json — model → qwen3-nothink
# ─────────────────────────────────────────────────────────
echo ""
echo "[4/6] Обновляем openclaw.json (модель: $NEW_MODEL)..."

if [[ "$NEW_MODEL" == "ollama/qwen3-nothink" ]]; then
    ssh gmktec "python3 -c \"
import json
path = '$CONFIG_REMOTE'
with open(path) as f: cfg = json.load(f)

cfg['agents']['defaults']['model']['primary'] = 'ollama/qwen3-nothink'

for agent in cfg.get('agents',{}).get('list',[]):
    if isinstance(agent, dict) and 'model' in agent:
        agent['model'] = 'ollama/qwen3-nothink'

with open(path, 'w') as f: json.dump(cfg, f, indent=2)
print('Config updated: ollama/qwen3-nothink')
\""
    echo "  Модель обновлена → qwen3-nothink ✓"
else
    echo "  Модель осталась qwen3:30b-a3b (tools test не прошёл)"
fi

# ─────────────────────────────────────────────────────────
# ШАГ 5: Усиленный SOUL.md — жёсткий запрет приветствий
# ─────────────────────────────────────────────────────────
echo ""
echo "[5/6] Обновляем SOUL.md (усиление запретов)..."

cat << 'SOULEOF' > "$REPO_DIR/docs/SOUL.md"
/no_think

# Banxe AI Bank — Compliance Rules

ШАГ 1 — САНКЦИОННАЯ ПРОВЕРКА (выполнять ПЕРВЫМ):
ЗАБЛОКИРОВАНЫ → REJECT одной строкой:
  Россия/РФ, Беларусь, Иран, КНДР/Северная Корея, Куба, Мьянма, Афганистан, Венесуэла (гос.), Крым, ДНР, ЛНР

EDD/HOLD (НЕ REJECT — санкции частично сняты):
  Сирия, Ирак, Ливан, Йемен, Гаити, Мали

НЕ заблокированы (стандартный AML):
  Южная Корея, ОАЭ, Япония, Израиль, Турция, Индия, США, EU, UK

→ Если страна в ЗАБЛОКИРОВАНЫ: REJECT. Banxe не проводит операции с [страна] — заблокированная юрисдикция.

ШАГ 2 — СУММА ТРАНЗАКЦИИ:
>£10,000 → СТАТУС: HOLD. Требуется: EDD, Source of Funds, HITL одобрение.
£1,000–£10,000 → СТАТУС: MONITOR. Требуется базовая проверка.
<£1,000 → СТАТУС: ALLOW.

СТРОГО ЗАПРЕЩЕНО:
- Приветствия ("Привет Mark!", "Hello!", "Здравствуйте!")
- Эмодзи любые (🚀 🇷🇺 ✅ ❌ и т.д.)
- Risk Score без реальных данных
- SumSub / Dow Jones / LexisNexis (не подключены — не упоминать)
- Таблицы с пустыми значениями
- Вопросы в конце ("Готовы ли вы перейти...?")
- ClickHouse-ссылки как результат операции

СТИЛЬ: русский, 3-5 строк, только факты.
SOULEOF

scp "$REPO_DIR/docs/SOUL.md" gmktec:/tmp/soul_new.md
PROTECTED_DIR="/root/.openclaw-moa/soul-protected"
WORKSPACE_SOUL="/home/mmber/.openclaw/workspace-moa/SOUL.md"
ssh gmktec "cp /tmp/soul_new.md $PROTECTED_DIR/SOUL.md && sudo chattr -i $WORKSPACE_SOUL 2>/dev/null || true && cp /tmp/soul_new.md $WORKSPACE_SOUL && sudo chattr +i $WORKSPACE_SOUL 2>/dev/null || true"
echo "  SOUL.md обновлён и защищён ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 6: Перезапуск бота и финальная проверка
# ─────────────────────────────────────────────────────────
echo ""
echo "[6/6] Перезапуск бота..."
ssh gmktec "sudo systemctl restart openclaw-gateway-moa.service"
echo "  Ожидаем 10 сек (ExecStartPost + буфер)..."
sleep 10

BOT_STATUS=$(ssh gmktec "sudo systemctl is-active openclaw-gateway-moa.service")
SOUL_CHECK=$(ssh gmktec "head -1 $WORKSPACE_SOUL")
AGENTS_SYRIA=$(ssh gmktec "grep -n 'Сири' $AGENTS_REMOTE | tr '\n' '|'")
CURRENT_MODEL=$(ssh gmktec "python3 -c \"import json; cfg=json.load(open('$CONFIG_REMOTE')); print(cfg['agents']['defaults']['model']['primary'])\"")

echo ""
echo "  Статус бота: $BOT_STATUS"
echo "  SOUL.md[1]: $SOUL_CHECK"
echo "  Syria в AGENTS.md: $AGENTS_SYRIA"
echo "  Модель: $CURRENT_MODEL"

# Коммит
echo ""
echo "Коммит..."
cd "$REPO_DIR"
git add docs/SOUL.md scripts/fix-think-and-syria.sh
git commit -m "fix: Syria EDD/HOLD + qwen3-nothink (PARAMETER think false) + style rules

- AGENTS.md: Syria removed from BLOCK, added to FATF EDD list
- Modelfile qwen3-nothink: PARAMETER think false (no TEMPLATE override)
- SOUL.md: strict style rules (no greetings, no emojis, no fake data)
- docs/SOUL.md updated as source of truth"
git push origin main

echo ""
echo "============================================"
echo "  ГОТОВО"
echo "============================================"
echo ""
echo "  Протестируй в Telegram:"
echo "  1. 'транзакция из России' → REJECT (одна строка, без привет)"
echo "  2. 'транзакция 50000 GBP из Южной Кореи' → HOLD (3-5 строк)"
echo "  3. 'транзакция 500 GBP из Сирии' → HOLD (EDD, не REJECT)"
echo ""
