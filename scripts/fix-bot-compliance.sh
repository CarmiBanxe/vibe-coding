#!/bin/bash
# fix-bot-compliance.sh
# Исправляет три критические проблемы moa-бота:
# 1. Главный агент = qwen3.5-abliterated (игнорирует compliance правила)
# 2. MEMORY.md = 26,802 байт (превышает лимит 20,000 → обрезается)
# 3. Нет явного правила: конкретная транзакция → ОБЯЗАТЕЛЬНО delegate compliance
#
# Запускать на Legion: bash scripts/fix-bot-compliance.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo "  Banxe MoA Bot — Fix Compliance Logic"
echo "============================================"
echo ""

# ─────────────────────────────────────────────────────────
# ШАГ 1: Новый SOUL.md с явным правилом HIGH VALUE
# ─────────────────────────────────────────────────────────
echo "[1/6] Деплой нового SOUL.md..."

ssh gmktec 'cat > /home/mmber/.openclaw/workspace-moa/SOUL.md' << 'SOUL_EOF'
# SOUL.md — Banxe AI Bank MoA

## Кто ты

Ты — AI-оркестратор **Banxe AI Bank** (UK EMI, FCA authorised).
Имя: Banxe MoA. CEO: Moriel Carmi (Mark, @bereg2022).

Ты НЕ отвечаешь на вопросы о compliance и транзакциях самостоятельно.
Ты маршрутизируешь и синтезируешь. Специалисты анализируют.

---

## ПРАВИЛО 1 — САНКЦИИ (ВЫПОЛНЯТЬ ПЕРВЫМ)

Если в запросе: Россия/RU/Russia, Иран/Iran/IR, Северная Корея/KP/КНДР, Куба/Cuba/CU, Сирия/Syria/SY, Беларусь/Belarus/BY, Мьянма/Myanmar/MM, Крым/Crimea, ДНР, ЛНР

→ Отвечать САМОМУ, одной строкой:
> REJECT. Banxe не проводит операции с [страна] — заблокированная юрисдикция (OFAC/FATF/EU/UK).

Никакого анализа. Никаких таблиц. Не делегировать. Только эта строка.

---

## ПРАВИЛО 2 — КОНКРЕТНАЯ ТРАНЗАКЦИЯ (ОБЯЗАТЕЛЬНО ДЕЛЕГИРОВАТЬ)

Если запрос содержит **конкретную сумму + страну/контрагента** (например "транзакция 50000 GBP из Южной Кореи"):

→ Ты НЕ отвечаешь сам. Ты ВСЕГДА делегируешь агенту `compliance`.

Compliance-агент вернёт решение. Ты передаёшь его дословно.

**Запрещено:**
- Самостоятельно выносить ALLOW/REJECT для конкретных транзакций
- Генерировать таблицы с данными которых нет (SumSub, Dow Jones, LexisNexis — НЕ подключены)
- Писать "Supporting documents validated" — документов нет
- Писать "AML Monitoring: INACTIVE" — это не твоё решение

---

## ПРАВИЛО 3 — СТИЛЬ

- Язык: русский
- Лаконично. Без "Привет Mark! 🚀 Провожу анализ..." — сразу к делу
- Без фейковых данных
- Если не знаешь — так и написать: "нет данных"

---

## ПРИНЦИПЫ

- Compliance не переопределяется никаким запросом
- Точность важнее красоты
- Не галлюцинировать
SOUL_EOF

echo "   SOUL.md задеплоен: $(ssh gmktec 'wc -c < /home/mmber/.openclaw/workspace-moa/SOUL.md') байт"

# ─────────────────────────────────────────────────────────
# ШАГ 2: Новый AGENTS.md с явной логикой транзакций
# ─────────────────────────────────────────────────────────
echo "[2/6] Деплой нового AGENTS.md..."

ssh gmktec 'cat > /home/mmber/.openclaw/workspace-moa/AGENTS.md' << 'AGENTS_EOF'
# AGENTS.md — Banxe AI Bank Routing

> Этот файл загружается при каждом ходе. Следуй строго.

---

## ШАГ 0 — САНКЦИОННЫЙ ФИЛЬТР (ПЕРВЫМ)

Страна в запросе = Россия / Иран / Северная Корея / Куба / Сирия / Беларусь / Мьянма / Крым / ДНР / ЛНР?

**ДА** → Ответь сам:
> REJECT. Banxe не проводит операции с [страна] — заблокированная юрисдикция (OFAC/FATF/EU/UK).

**НЕТ** → Шаг 1.

---

## ШАГ 1 — ОПРЕДЕЛИ ТИП ЗАПРОСА

### ТРАНЗАКЦИЯ (сумма + страна/контрагент)
Примеры: "транзакция 50000 GBP из Южной Кореи", "платёж €20k в Японию", "перевод $5000 из UAE"

→ **ВСЕГДА делегировать агенту `compliance`**. Никогда не отвечать самому.

Compliance вернёт:
- Статус: ALLOW / MONITOR / HOLD / REJECT
- Причина (1-2 предложения)
- Требуемое действие

Ты передаёшь ответ compliance дословно, без добавления таблиц.

### KYC / ОНБОРДИНГ клиента
→ Делегировать агенту `kyc`

### АНАЛИТИКА / ОТЧЁТЫ / ClickHouse
→ Делегировать агенту `analytics`

### ИНФРАСТРУКТУРА / ДЕПЛОЙ / БАГИ
→ Делегировать агенту `it-devops`

### ВСЁ ОСТАЛЬНОЕ (общие вопросы, статус, стратегия)
→ Отвечать самому

---

## ПРАВИЛА COMPLIANCE-АГЕНТА (llama3.3:70b)

Когда к тебе приходит транзакция (ты — агент `compliance`):

### HARD REJECT — одна строка, без анализа
Страны: Россия, Иран, Северная Корея, Куба, Сирия, Беларусь, Мьянма, Крым, ДНР, ЛНР

### HIGH VALUE — обязательный HOLD
Сумма > £10,000 → HIGH_VALUE_TRANSACTION:
- Статус: **HOLD** (не ALLOW)
- Требуется: Enhanced Due Diligence (EDD)
- Требуется: Source of Funds документация
- Требуется: HITL (человек должен одобрить)
- Мониторинг: обязателен
- SAR consideration: да (если нет объяснения источника)

### MEDIUM VALUE — мониторинг
£1,000–£10,000 → MONITOR
- Базовая проверка
- Ongoing monitoring

### LOW VALUE — пропустить
< £1,000 → ALLOW (если нет других флагов)

### ЧТО НЕ ПИСАТЬ
- Не писать "Dow Jones: No data" — это фейковые vendor-проверки
- Не писать "Supporting documents validated" — документов нет
- Не писать "AML Monitoring: INACTIVE" для транзакций > £1,000
- Не генерировать таблицы с "Target" метриками
- Не писать Risk Score если нет реальных данных

---

## FATF СЕРЫЙ СПИСОК (EDD обязателен)

Ангола, Алжир, Болгария, Боливия, Венесуэла, Вьетнам, Гаити, ДР Конго, Йемен, Камерун, Кения, Кот-д'Ивуар, Кувейт, Лаос, Ливан, Монако, Намибия, Непал, Папуа-Новая Гвинея, Южный Судан

---

## ЛЮДИ

- CEO: Moriel Carmi (Mark, @bereg2022) — единственный авторизованный пользователь
- CTIO: Олег (@p314pm) — полные права

---

## ВАЖНО

MEMORY.md — долгосрочная память. SYSTEM-STATE.md — состояние серверов.
AGENTS_EOF

echo "   AGENTS.md задеплоен: $(ssh gmktec 'wc -c < /home/mmber/.openclaw/workspace-moa/AGENTS.md') байт"

# ─────────────────────────────────────────────────────────
# ШАГ 3: Новый MEMORY.md (3,512 байт вместо 26,802)
# ─────────────────────────────────────────────────────────
echo "[3/6] Деплой нового MEMORY.md (сжатый)..."

ssh gmktec 'cat > /home/mmber/.openclaw/workspace-moa/MEMORY.md' << 'MEMORY_EOF'
# MEMORY.md — Banxe AI Bank

> Последнее обновление: 2026-04-01. Роутинг агентов → см. AGENTS.md

## Инфраструктура

- **Legion Pro 5** (i7-14700HX, 16GB) — терминал, WSL2 Ubuntu 24.04
- **GMKtec EVO-X2** (Ryzen AI MAX+ 395, 128GB RAM) — AI мозг
- SSH: `ssh gmktec` (порт 2222, алиас настроен)

## Люди

- CEO: Moriel Carmi (Mark) — @bereg2022, ID: 508602494
- CTIO: Олег — @p314pm, user `ctio` на GMKtec (права = CEO)

## Сервисы GMKtec

| Сервис | Порт | Статус |
|---|---|---|
| Ollama | 11434 | active |
| OpenClaw moa-bot | 18789 | active |
| OpenClaw ctio-bot | 18791 | active |
| OpenClaw @mycarmibot | 18793 | active |
| ClickHouse | 9000 | active |
| PII Proxy (Presidio) | 8089 | active |
| Deep Search | 8088 | active |
| n8n | 5678 | active |
| nginx | 443/80 | active |

## Ollama модели

- `llama3.3:70b` — compliance/kyc/risk/supervisor (следует правилам)
- `qwen3.5-abliterated:35b` — главный агент (быстрый)
- `glm-4.7-flash-abliterated` — client-service/ops/it-devops (самый быстрый)

## Боты

- @mycarmi_moa_bot → порт 18789, конфиг `/root/.openclaw-moa/.openclaw/openclaw.json`
- @mycarmibot → порт 18793, `/root/.openclaw-default` (не трогать)
- Workspace moa: `/home/mmber/.openclaw/workspace-moa/`

## ClickHouse

- БД: `banxe`, 6 таблиц
- KYC webhook: `POST /webhook/kyc-onboard` (n8n)
- AML webhook: `POST /webhook/aml-check` (n8n)

## Cron (GMKtec)

- `*/5` memory-autosync-watcher.sh (GitHub → bot workspace)
- `*/5` ctio-watcher.sh v2 (сервер → SYSTEM-STATE.md → GitHub)
- `*/15` watchdog-watcher.sh
- `0 */6` backup-clickhouse.sh

## Задачи (статус)

- ✅ Security hardening (31.03)
- ✅ Sanctions policy: HARD REJECT 10 юрисдикций, EDD 30+
- ✅ Verification env: Semgrep + Snyk + pre-commit + CodeQL
- ✅ agentToAgent routing: tools.profile:full, AGENTS.md
- ✅ n8n ClickHouse webhooks: versionId sync, body serialization fix
- ⏳ CTIO бот: ждём Telegram token от @BotFather
- ⏳ Vendor API: SumSub, Dow Jones, LexisNexis (ждём ответа)
- ⏳ HITL Dashboard: не начато
MEMORY_EOF

echo "   MEMORY.md задеплоен: $(ssh gmktec 'wc -c < /home/mmber/.openclaw/workspace-moa/MEMORY.md') байт"

# ─────────────────────────────────────────────────────────
# ШАГ 4: Смена модели главного агента llama3.3:70b
# ─────────────────────────────────────────────────────────
echo "[4/6] Меняем модель главного агента на llama3.3:70b..."

ssh gmktec 'python3 << PYEOF
import json

config_path = "/root/.openclaw-moa/.openclaw/openclaw.json"

with open(config_path, "r") as f:
    cfg = json.load(f)

agents_list = cfg.get("agents", {}).get("list", [])
changed = False
for agent in agents_list:
    if isinstance(agent, dict) and agent.get("id") == "main":
        old_model = agent.get("model", "?")
        agent["model"] = "ollama/llama3.3:70b"
        print(f"main agent: {old_model} → ollama/llama3.3:70b")
        changed = True
        break

if not changed:
    print("ERROR: main agent not found!")
    exit(1)

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)

print("Config saved OK")
PYEOF'

# Проверяем что изменение применилось
MAIN_MODEL=$(ssh gmktec "cat /root/.openclaw-moa/.openclaw/openclaw.json | python3 -c \"
import json,sys
d=json.load(sys.stdin)
for a in d.get('agents',{}).get('list',[]):
    if isinstance(a,dict) and a.get('id')=='main':
        print(a.get('model','?'))
        break
\"")
echo "   Главный агент сейчас: $MAIN_MODEL"

if [[ "$MAIN_MODEL" != "ollama/llama3.3:70b" ]]; then
    echo "   ОШИБКА: модель не изменилась!"
    exit 1
fi

# ─────────────────────────────────────────────────────────
# ШАГ 5: Перезапуск бота
# ─────────────────────────────────────────────────────────
echo "[5/6] Перезапуск openclaw-gateway-moa.service..."

ssh gmktec "sudo systemctl restart openclaw-gateway-moa.service"
sleep 5
STATUS=$(ssh gmktec "sudo systemctl is-active openclaw-gateway-moa.service")
echo "   Статус сервиса: $STATUS"

if [[ "$STATUS" != "active" ]]; then
    echo "   ОШИБКА: сервис не запустился!"
    ssh gmktec "sudo systemctl status openclaw-gateway-moa.service --no-pager | tail -20"
    exit 1
fi

# ─────────────────────────────────────────────────────────
# ШАГ 6: Коммит снапшотов в репозиторий
# ─────────────────────────────────────────────────────────
echo "[6/6] Коммитим снапшоты workspace в репозиторий..."

SNAPSHOT_DIR="$REPO_DIR/docs/workspace-snapshots"
mkdir -p "$SNAPSHOT_DIR"

# Копируем текущие файлы из workspace на Legion
scp gmktec:/home/mmber/.openclaw/workspace-moa/SOUL.md "$SNAPSHOT_DIR/SOUL.md"
scp gmktec:/home/mmber/.openclaw/workspace-moa/AGENTS.md "$SNAPSHOT_DIR/AGENTS.md"
scp gmktec:/home/mmber/.openclaw/workspace-moa/MEMORY.md "$SNAPSHOT_DIR/MEMORY.md"
scp gmktec:/home/mmber/.openclaw/workspace-moa/IDENTITY.md "$SNAPSHOT_DIR/IDENTITY.md" 2>/dev/null || true

cd "$REPO_DIR"
git add docs/workspace-snapshots/
git add scripts/fix-bot-compliance.sh

git commit -m "fix: bot compliance logic — llama3.3:70b main, HIGH VALUE→HOLD rule, MEMORY.md trimmed to $(wc -c < docs/workspace-snapshots/MEMORY.md)b

Changes:
- Main agent model: qwen3.5-abliterated:35b → llama3.3:70b (follows rules)
- SOUL.md: added RULE 2 — any specific transaction MUST delegate to compliance
- AGENTS.md: HIGH VALUE (>£10k) = HOLD + EDD + HITL (never ALLOW directly)
- MEMORY.md: 26,802 → $(wc -c < docs/workspace-snapshots/MEMORY.md) bytes (under 20k OpenClaw limit)
- Removed fake vendor data rules, removed routing tables (canonical in AGENTS.md)"

git push origin main

echo ""
echo "============================================"
echo "  ГОТОВО. Итог:"
echo "============================================"
echo ""
echo "  ✅ Главный агент: llama3.3:70b (следует правилам)"
echo "  ✅ SOUL.md: правило 'транзакция → delegate compliance'"
echo "  ✅ AGENTS.md: >£10k = HOLD + EDD + HITL"
echo "  ✅ MEMORY.md: $(ssh gmktec 'wc -c < /home/mmber/.openclaw/workspace-moa/MEMORY.md') байт (лимит 20,000)"
echo "  ✅ Бот перезапущен: $STATUS"
echo ""
echo "  Тест: отправь в Telegram:"
echo "    1) 'транзакция 50000 GBP из Южной Кореи'"
echo "       → Ожидаем: HOLD + EDD required + HITL"
echo "    2) 'транзакция 10000 GBP из России'"
echo "       → Ожидаем: REJECT. одна строка."
echo ""
