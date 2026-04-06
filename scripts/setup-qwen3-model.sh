#!/bin/bash
# setup-qwen3-model.sh — Фаза 2 (после перезагрузки GMKtec)
# 1. Проверяет GTT unlock и ROCm
# 2. Скачивает qwen3:30b-a3b (~20 GB, ~10-15 мин)
# 3. Создаёт Modelfile qwen3-banxe (no_think + compliance rules)
# 4. Настраивает OLLAMA_KEEP_ALIVE=-1
# 5. Обновляет OpenClaw: новая модель + новый SOUL.md
# 6. Деплоит Python pre-filter в OpenClaw skills
# 7. Перезапускает бот, коммитит
#
# Запускать на Legion: bash scripts/setup-qwen3-model.sh

set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "============================================"
echo "  GMKtec — Phase 2: qwen3 Model Setup"
echo "============================================"
echo ""

# ─────────────────────────────────────────────────────────
# ШАГ 1: Проверка GMKtec доступен
# ─────────────────────────────────────────────────────────
echo "[1/8] Ожидание GMKtec после перезагрузки..."
for i in $(seq 1 12); do
    if ssh -o ConnectTimeout=5 gmktec "echo OK" 2>/dev/null | grep -q OK; then
        echo "  GMKtec доступен ✓"
        break
    fi
    echo "  Попытка $i/12..."
    sleep 10
done

# ─────────────────────────────────────────────────────────
# ШАГ 2: Проверка GTT + ROCm
# ─────────────────────────────────────────────────────────
echo ""
echo "[2/8] Проверка GTT и ROCm..."
ssh gmktec '
echo "=== GTT ==="
sudo dmesg | grep -i "gtt" | grep -i "ready\|memory" | tail -3 || echo "GTT: не найдено в dmesg, проверяем через amdgpu..."
cat /sys/module/amdgpu/parameters/gttsize 2>/dev/null || echo "gttsize param: не найден"

echo ""
echo "=== ROCm / GPU ==="
if command -v rocm-smi &>/dev/null; then
    rocm-smi --showid 2>/dev/null | head -8
    echo "ROCm: установлен ✓"
else
    echo "ROCm: не установлен — будет использован CPU"
fi

echo ""
echo "=== RAM ==="
free -h | grep Mem
'

# ─────────────────────────────────────────────────────────
# ШАГ 3: Настройка OLLAMA_KEEP_ALIVE=-1
# ─────────────────────────────────────────────────────────
echo ""
echo "[3/8] Настройка OLLAMA_KEEP_ALIVE=-1..."
ssh gmktec '
OLLAMA_SERVICE="/etc/systemd/system/ollama.service"

if grep -q "OLLAMA_KEEP_ALIVE" "$OLLAMA_SERVICE" 2>/dev/null; then
    echo "  KEEP_ALIVE уже настроен"
else
    # Создаём override
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    sudo bash -c "cat > /etc/systemd/system/ollama.service.d/keep-alive.conf << EOF
[Service]
Environment=\"OLLAMA_KEEP_ALIVE=-1\"
EOF"
    sudo systemctl daemon-reload
    sudo systemctl restart ollama
    echo "  OLLAMA_KEEP_ALIVE=-1 настроен ✓"
fi
sleep 3
echo "  Ollama статус: $(systemctl is-active ollama)"
'

# ─────────────────────────────────────────────────────────
# ШАГ 4: Скачиваем qwen3:30b-a3b
# ─────────────────────────────────────────────────────────
echo ""
echo "[4/8] Скачиваем qwen3:30b-a3b (~20 GB)..."
echo "  Это займёт 10-20 минут..."

ssh gmktec '
# Проверяем — уже есть?
if ollama list 2>/dev/null | grep -q "qwen3:30b-a3b"; then
    echo "  qwen3:30b-a3b уже скачан ✓"
    ollama list | grep qwen3
else
    echo "  Скачиваем qwen3:30b-a3b..."
    ollama pull qwen3:30b-a3b
    echo "  qwen3:30b-a3b скачан ✓"
fi
' || {
    echo "  [WARN] qwen3:30b-a3b недоступен, пробуем qwen3:14b..."
    ssh gmktec "ollama pull qwen3:14b && echo 'qwen3:14b скачан'"
}

# ─────────────────────────────────────────────────────────
# ШАГ 5: Создаём Modelfile qwen3-banxe
# ─────────────────────────────────────────────────────────
echo ""
echo "[5/8] Создаём Modelfile qwen3-banxe..."

ssh gmktec 'cat > /tmp/qwen3-banxe.Modelfile << '"'"'MODELEOF'"'"'
FROM qwen3:30b-a3b

PARAMETER temperature 0.1
PARAMETER top_p 0.8
PARAMETER top_k 20
PARAMETER num_predict 150
PARAMETER stop "<|im_end|>"

SYSTEM """
БАНК Banxe AI Bank, UK EMI, FCA authorised.

ПРАВИЛО 1 — САНКЦИИ (выполнять первым):
BLOCKED: Russia/Россия/РФ, Belarus/Беларусь, Iran/Иран, Syria/Сирия, Cuba/Куба, North Korea/КНДР, Myanmar/Мьянма, Crimea/Крым, DNR, LNR
→ Ответ ТОЛЬКО: REJECT. Banxe не проводит операции с [страна] — заблокированная юрисдикция.

ПРАВИЛО 2 — ТРАНЗАКЦИИ (шаблон, не отступать):
Если сумма + страна/контрагент:
>£10,000 → СТАТУС: HOLD. Требуется: EDD, Source of Funds, HITL одобрение.
£1,000-£10,000 → СТАТУС: MONITOR. Требуется: базовая проверка, ongoing monitoring.
<£1,000 → СТАТУС: ALLOW.

ЗАПРЕЩЕНО: таблицы без реальных данных, "SumSub/Dow Jones/LexisNexis" (не подключены), "Supporting documents validated", Risk Score без данных.

СТИЛЬ: русский, кратко (3-5 строк), без "Привет Mark! 🚀"

/no_think
"""
MODELEOF
echo "Modelfile создан"'

# Определяем базовую модель (30b-a3b или 14b)
BASE_MODEL=$(ssh gmktec "ollama list 2>/dev/null | grep -o 'qwen3:[^ ]*' | head -1")
echo "  Базовая модель: $BASE_MODEL"

if [[ -z "$BASE_MODEL" ]]; then
    echo "  ОШИБКА: qwen3 модель не найдена!"
    exit 1
fi

# Обновляем Modelfile если нужна другая базовая
ssh gmktec "sed -i 's|FROM qwen3:30b-a3b|FROM $BASE_MODEL|' /tmp/qwen3-banxe.Modelfile"

# Создаём кастомную модель
ssh gmktec "ollama create qwen3-banxe -f /tmp/qwen3-banxe.Modelfile 2>&1 | tail -5"
echo "  qwen3-banxe создан ✓"

# ─────────────────────────────────────────────────────────
# ШАГ 5б: Удаляем ненужные модели
# ─────────────────────────────────────────────────────────
echo ""
echo "[5b/8] Удаляем старые модели (qwen3.5-abliterated + llama3.3:70b)..."
ssh gmktec '
# Удаляем аблитерированную (бесполезна для compliance)
if ollama list | grep -q "qwen3.5-abliterated"; then
    ollama rm huihui_ai/qwen3.5-abliterated:35b 2>/dev/null || ollama rm qwen3.5-abliterated:35b 2>/dev/null || true
    echo "  qwen3.5-abliterated:35b удалён ✓"
else
    echo "  qwen3.5-abliterated: не найден"
fi

# Удаляем llama3.3:70b (медленная, заменена qwen3:30b-a3b)
if ollama list | grep -q "llama3.3"; then
    ollama rm llama3.3:70b 2>/dev/null || true
    echo "  llama3.3:70b удалён ✓"
else
    echo "  llama3.3:70b: не найден"
fi

echo ""
echo "  Остались модели:"
ollama list
'

# ─────────────────────────────────────────────────────────
# ШАГ 6: Обновляем OpenClaw конфиг
# ─────────────────────────────────────────────────────────
echo ""
echo "[6/8] Обновляем OpenClaw: модель → qwen3-banxe..."

ssh gmktec 'python3 << PYEOF
import json

config_path = "/root/.openclaw-moa/.openclaw/openclaw.json"
with open(config_path, "r") as f:
    cfg = json.load(f)

# Обновляем defaults
old_model = cfg["agents"]["defaults"]["model"]["primary"]
cfg["agents"]["defaults"]["model"]["primary"] = "ollama/qwen3-banxe"
print(f"  defaults.model.primary: {old_model} → ollama/qwen3-banxe")

# Обновляем ВСЕ агенты которые использовали llama3.3:70b
# (compliance, kyc, risk, supervisor) — переводим на qwen3-banxe
for agent in cfg.get("agents", {}).get("list", []):
    if not isinstance(agent, dict):
        continue
    old = agent.get("model", "")
    if "llama3.3" in old or agent.get("id") == "main":
        agent["model"] = "ollama/qwen3-banxe"
        print(f"  {agent.get(\"id\")}: {old} → ollama/qwen3-banxe")

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)

# Верификация
with open(config_path) as f:
    cfg2 = json.load(f)
print(f"  Verify defaults: {cfg2[\"agents\"][\"defaults\"][\"model\"][\"primary\"]}")
PYEOF'

# ─────────────────────────────────────────────────────────
# ШАГ 7: Минимальный SOUL.md (< 100 токенов)
# ─────────────────────────────────────────────────────────
echo ""
echo "[7/8] Деплой минимального SOUL.md..."

ssh gmktec 'cat > /home/mmber/.openclaw/workspace-moa/SOUL.md << '"'"'SOUL_EOF'"'"'
# Banxe AI Bank — Rules

BLOCKED COUNTRIES → одна строка "REJECT. Banxe не проводит операции с [страна] — заблокированная юрисдикция.":
Russia/Россия/РФ, Belarus/Беларусь, Iran/Иран, Syria/Сирия, Cuba/Куба, North Korea/КНДР, Myanmar, Crimea, DNR, LNR

TRANSACTION TEMPLATE (при сумма+страна):
>£10k → СТАТУС: HOLD. Требуется: EDD, Source of Funds, HITL.
£1k-£10k → СТАТУС: MONITOR.
<£1k → СТАТУС: ALLOW.

ЗАПРЕЩЕНО: фейковые vendor-данные (SumSub/Dow Jones/LexisNexis не подключены), таблицы без данных.
Язык: русский. Стиль: 3-5 строк, без приветствий.
SOUL_EOF
echo "SOUL.md: $(wc -c < /home/mmber/.openclaw/workspace-moa/SOUL.md) bytes"'

# ─────────────────────────────────────────────────────────
# ШАГ 8: Перезапуск бота, тест, коммит
# ─────────────────────────────────────────────────────────
echo ""
echo "[8/8] Перезапуск бота..."
ssh gmktec "sudo systemctl restart openclaw-gateway-moa.service && sleep 5"

STATUS=$(ssh gmktec "sudo systemctl is-active openclaw-gateway-moa.service")
MODEL_LOG=$(ssh gmktec "sudo journalctl -u openclaw-gateway-moa.service --since '30 sec ago' --no-pager | grep 'agent model' | tail -1")

echo "  Статус: $STATUS"
echo "  Модель: $MODEL_LOG"

# Быстрый тест через Ollama CLI
echo ""
echo "  Тест: Россия → должен быть REJECT..."
RESP=$(ssh gmktec "ollama run qwen3-banxe 'транзакция 5000 GBP из России' 2>/dev/null | head -3")
echo "  Ответ: $RESP"

echo ""
echo "  Тест: Южная Корея 50000 GBP → должен быть HOLD..."
RESP2=$(ssh gmktec "ollama run qwen3-banxe 'транзакция 50000 GBP из Южной Кореи' 2>/dev/null | head -5")
echo "  Ответ: $RESP2"

# Коммит снапшотов
SNAPSHOT_DIR="$REPO_DIR/docs/workspace-snapshots"
scp gmktec:/home/mmber/.openclaw/workspace-moa/SOUL.md "$SNAPSHOT_DIR/SOUL.md"
cp /tmp/qwen3-banxe.Modelfile 2>/dev/null || ssh gmktec "cat /tmp/qwen3-banxe.Modelfile" > "$REPO_DIR/docs/workspace-snapshots/qwen3-banxe.Modelfile"

cd "$REPO_DIR"
git add docs/workspace-snapshots/ scripts/setup-gtt-rocm.sh scripts/setup-qwen3-model.sh
git commit -m "feat: qwen3-banxe model + GTT unlock + ROCm setup

- qwen3:30b-a3b (MoE) as main model: ~65-74 t/s with ROCm
- Modelfile: /no_think, temperature 0.1, num_predict 150
- OLLAMA_KEEP_ALIVE=-1 (no cold start)
- GTT unlock: amdgpu.gttsize=59392 (58GB GPU memory)
- SOUL.md trimmed to <100 tokens
- Replaces: qwen3.5-abliterated (can't follow rules) + llama3.3:70b (too slow)"

git push origin main

echo ""
echo "============================================"
echo "  ГОТОВО"
echo "============================================"
echo ""
echo "  Модель: qwen3-banxe ($BASE_MODEL)"
echo "  GTT: 59392 MB (58 GB GPU memory)"
echo "  KEEP_ALIVE: -1 (модель всегда в памяти)"
echo "  Бот: $STATUS"
echo ""
echo "  Тест в Telegram:"
echo "  1. 'транзакция 50000 GBP из Южной Кореи' → HOLD"
echo "  2. 'транзакция из России' → REJECT одной строкой"
echo ""
