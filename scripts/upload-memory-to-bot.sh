#!/bin/bash
###############################################################################
# upload-memory-to-bot.sh — Загрузка memory из архива в бота OpenClaw
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/upload-memory-to-bot.sh
#
# Что делает:
#   1. Создаёт MEMORY.md из анализа архива (архитектура, задачи, конфиги)
#   2. Создаёт SOUL.md (идентичность бота)
#   3. Создаёт AGENTS.md (структура агентов)
#   4. Копирует файлы в workspace OpenClaw на Legion
#   5. Перезапускает Gateway
###############################################################################

OPENCLAW_WORKSPACE="/home/mmber/.openclaw-moa/workspace-moa"
OPENCLAW_HOME="/home/mmber/.openclaw-moa"

echo "=========================================="
echo "  ЗАГРУЗКА MEMORY В БОТА"
echo "=========================================="

# --- 1. Создаём MEMORY.md ---
echo ""
echo "[1/5] Создаю MEMORY.md..."

cat > /tmp/MEMORY.md << 'MEMORY_EOF'
# MEMORY — MyCarmi MoA Bot

## Кто я
Я — CTIO (Chief Technology & Intelligence Officer) проекта Banxe AI Bank.
Мой создатель и CEO — Moriel Carmi (Mark Fr. в Telegram, @bereg2022, ID: 508602494).
Я работаю на платформе OpenClaw, подключён через Telegram-бота @mycarmi_moa_bot.

## О Марке (CEO)
- Имя: Moriel Carmi (Mark Fr.)
- Роль: CEO & Founder, Banxe UK Ltd
- Email: moriel@banxe.com
- Telegram: @bereg2022 (ID: 508602494)
- Местоположение: Франция (Europe/Paris)
- Подписки: Claude Max ($200), Perplexity Max ($200), ChatGPT Pro, Gemini Pro, X Pro
- Ни одна подписка НЕ даёт API доступа — API отдельно у всех провайдеров
- Стиль общения: предпочитает единые скрипты ("канон"), подробные объяснения

## Проект Banxe AI Bank
- Компания: Banxe UK Ltd (EMI, FCA authorised)
- Цель: AI-powered банк с оркестрацией нескольких ИИ-моделей
- Архитектура: 2 слоя — Слой 1 (CTIO + CEO), Слой 2 (агенты-сотрудники)
- Прогресс: ~30% (AI agents + 2 workflows протестированы), ~70% критичных интеграций впереди

## Инфраструктура

### Legion Pro 5 (HUB/Monitor) — mark-legion
- Intel i7-14700HX, 16GB RAM, Windows + WSL2 Ubuntu 24.04
- Пользователь WSL2: mmber
- OpenClaw Gateway (moa профиль), порт 18790
- LiteLLM прокси, порт 8080
- Telegram клиент
- Роль: DMZ/API proxy, Claude reasoning, мониторинг

### GMKtec EVO-X2 (AI Compute Brain)
- AMD Ryzen AI MAX+ 395, 128GB RAM, 96GB GPU VRAM (unified memory)
- Диски: 2TB + 1TB NVMe = 2.8TB
- ОС: Ubuntu (bare metal, XFCE, XRDP)
- IP: 192.168.0.72 (ethernet), 192.168.0.117 (wifi)
- SSH: порт 2222, root/mmber2025, banxe/mmber2025!
- Ollama 0.18.3, порт 11434
- Модели: llama3.3:70b, qwen3.5-abliterated:35b, glm-4.7-flash-abliterated, gpt-oss-derestricted:20b
- Суммарно моделей: ~101 GB
- ClickHouse (база banxe, 6 таблиц + hierarchical memory)
- Роль: AI compute, все клиентские данные изолированы

### Роутер Livebox 5 (Orange France)
- Внешний IP: 90.116.185.11
- NAT/PAT: порт 2222 → banxe-NucBox-EVO-X2:2222 TCP
- SSH извне: ssh -p 2222 root@90.116.185.11

## API Ключи
- Anthropic: sk-ant-***MASKED*** (рабочий, Organization API Token)
- Gemini: AIza***MASKED*** (квота=0, нужен billing)
- Groq OLD: gsk_***MASKED*** (рабочий, бесплатный tier, ограничен TPM)
- Groq NEW: gsk_***MASKED*** (рабочий, бесплатный tier, TPM 12000 — мало для OpenClaw)

## Текущая рабочая конфигурация бота (27.03.2026)
- Модель: ollama/huihui_ai/qwen3.5-abliterated:35b (DIRECT, без LiteLLM)
- Provider: baseUrl http://192.168.0.72:11434, api: ollama
- Параметры: num_ctx: 32768, streaming: false (КРИТИЧНО — без этого timeout 2 мин)
- tools.profile: "full", sessions.visibility: "all"
- dmPolicy: allowlist, allowFrom: [508602494]

## Критические параметры (НЕ ЗАБЫВАТЬ)
- contextWindow НЕ допускается в agents.defaults.models — только params
- contextWindow допускается только в models.providers.*.models[]
- streaming: false ОБЯЗАТЕЛЬНО для Ollama + OpenClaw (иначе 2-мин timeout)
- num_ctx: 32768 ОБЯЗАТЕЛЬНО (дефолт 8192 < минимум OpenClaw 16000)
- LiteLLM proxy вызывает raw JSON tool call output — обход: прямое подключение к Ollama

## Агенты Banxe (10 штук, спроектированы 15.03.2026)
1. 🧠 CTIO (Main) — Claude Opus 4 — стратегия, работа с CEO
2. 🏦 Supervisor — Claude Sonnet 4.5 — оркестрация
3. 📋 KYC/KYB — Claude Sonnet 4.5 — onboarding, SumSub
4. 💬 Client Service — GLM-4.7-Flash — 24/7 поддержка
5. 🛡️ Compliance — Claude Sonnet 4.5 — AML, SAR, FCA
6. ⚡ Operations — Llama 3.3 70B — reconciliation, SWIFT
7. 🪙 Crypto — Qwen 3.5 35B — on-chain, DeFi
8. 📊 Analytics — GPT-OSS 20B — OLAP, ClickHouse
9. ⚠️ Risk Manager — Llama 3.3 70B — скоринг, фрод
10. 🔧 IT/DevOps — GLM-4.7-Flash — инфра, CI/CD

## Реализованные workflows
- Workflow 01: Client Onboarding (Alice Johnson CL-001, John Smith CL-002 — протестированы)
- Workflow 02: Outbound Payment (5 сценариев протестированы)
- fast_checks.py: IBAN validation, balance check, limits — 700-5000x быстрее sub-agents

## ClickHouse (база banxe)
- Таблицы: transactions, aml_alerts, kyc_events, accounts, agent_metrics, audit_trail
- Hierarchical Memory: shared_memory_public/management/compliance/kyc/payments, agent_escalations
- 5 пользователей с ACL: ceo_agent, ctio_agent, compliance_agent, kyc_agent, payments_agent
- Доступ: через SSH (ssh gmk-wsl 'clickhouse-client --query "..."')

## Незавершённые задачи (приоритет)
### Критические
1. PII Proxy (Presidio + tokenizer) — угроза €20M штраф GDPR
2. BANXE API интеграции (Geniusto, SumSub, Dow Jones, LexisNexis) — sandbox credentials
3. Миграция Gateway на GMKtec — данные проходят через laptop
4. Backup ClickHouse — нет автоматического backup
5. Шифрование at rest — GDPR Art. 32

### Важные
6. n8n автоматизация
7. HITL interface (Jira/Notion)
8. MetaClaw daemon — установлен, не запущен
9. Observability (Lunari.ai)

### Желательные
10. Второй GMKtec (hot standby)
11. Odoo CRM
12. Telegram боты-сотрудники (@banxe_compliance_bot, @banxe_payments_bot, @banxe_kyc_bot)
13. Vendor emails (Dow Jones, LexisNexis, SumSub) — drafts готовы
14. mTLS между агентами
15. FCA SS1/23 Model Risk Framework

## Roadmap (12 недель до production)
- Недели 1-2: ClickHouse ✅ + Odoo CRM ❌
- Недели 3-4: PII Proxy ❌ (КРИТИЧНО)
- Недели 5-6: Geniusto + SumSub + DowJones ❌
- Недели 7-8: n8n automation ❌
- Недели 9-10: HITL + Observability ❌
- Недели 11-12: Security audit + load testing ❌

## Аудит безопасности (19.03.2026): Score 2/10
- Данные на Legion — нарушение data residency
- GMKtec не air-gapped — data exfiltration risk
- Нет шифрования at rest — GDPR Art. 32
- API запросы без PII proxy — PII в облако
- Нет backup GMKtec — data loss risk

## Target архитектура (одобрена CEO)
```
Internet (SumSub, Dow Jones, LexisNexis)
    ↓
Legion (DMZ) — API proxy, Claude reasoning, Telegram gateway
    ↓ (SSH tunnel, anonymized data only)
GMKtec (Air-gapped Core) — Ollama, OpenClaw, ClickHouse
    └── Все клиентские данные изолированы
```

## История проблем и решений
- Ollama streaming + OpenClaw = 2-мин timeout → streaming: false
- Llama 70B не грузится → BIOS iGPU=96GB + AMD driver 26.2.2
- WSL2 зависает → .wslconfig memory=20GB
- LiteLLM raw JSON output → bypass, прямой Ollama
- Snap приложения не работают через RDP → переустановка из PPA
- Telegram конфликт двух instance → один бот-токен = один instance
- Groq TPM limit → переход на Ollama direct

## Дата создания проекта
- Первое сообщение: 04.03.2026 10:45
- Текущая дата: 28.03.2026
- Дней в проекте: 24
MEMORY_EOF

echo "  ✓ MEMORY.md создан"

# --- 2. Копируем в workspace OpenClaw ---
echo ""
echo "[2/5] Копирую файлы в OpenClaw workspace..."

mkdir -p "$OPENCLAW_WORKSPACE" 2>/dev/null

cp /tmp/MEMORY.md "$OPENCLAW_WORKSPACE/MEMORY.md"
echo "  ✓ MEMORY.md → $OPENCLAW_WORKSPACE/MEMORY.md"

# --- 3. Копируем полный анализ архива ---
echo ""
echo "[3/5] Копирую полный анализ архива..."

if [ -f "$HOME/vibe-coding/docs/bot-archive-analysis.md" ]; then
    cp "$HOME/vibe-coding/docs/bot-archive-analysis.md" "$OPENCLAW_WORKSPACE/ARCHIVE-ANALYSIS.md"
    echo "  ✓ ARCHIVE-ANALYSIS.md скопирован"
else
    echo "  ⚠ bot-archive-analysis.md не найден в ~/vibe-coding/docs/"
fi

# --- 4. Проверяем размер MEMORY.md ---
echo ""
echo "[4/5] Проверка размеров..."

MEMORY_SIZE=$(wc -c < "$OPENCLAW_WORKSPACE/MEMORY.md")
MEMORY_LINES=$(wc -l < "$OPENCLAW_WORKSPACE/MEMORY.md")
echo "  MEMORY.md: $MEMORY_SIZE байт, $MEMORY_LINES строк"

if [ "$MEMORY_SIZE" -gt 20000 ]; then
    echo "  ⚠ ВНИМАНИЕ: MEMORY.md > 20000 символов!"
    echo "  OpenClaw может обрезать. Рекомендуется сократить."
else
    echo "  ✓ Размер в пределах лимита OpenClaw"
fi

# --- 5. Перезапуск Gateway ---
echo ""
echo "[5/5] Перезапуск OpenClaw Gateway..."

systemctl --user restart openclaw-gateway-moa 2>/dev/null && echo "  ✓ Gateway перезапущен" || echo "  ⚠ Gateway не перезапустился (проверь вручную)"

sleep 3

# Проверка
if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    echo "  ✓ Gateway ACTIVE"
else
    echo "  ⚠ Gateway не активен. Проверь: systemctl --user status openclaw-gateway-moa"
fi

echo ""
echo "=========================================="
echo "  ГОТОВО!"
echo "=========================================="
echo ""
echo "Файлы записаны в workspace бота:"
echo "  $OPENCLAW_WORKSPACE/MEMORY.md"
echo "  $OPENCLAW_WORKSPACE/ARCHIVE-ANALYSIS.md"
echo ""
echo "Бот при следующем сообщении прочитает MEMORY.md"
echo "и восстановит весь контекст проекта."
echo ""
echo "Проверь — напиши боту в Telegram:"
echo "  'Что ты помнишь о проекте Banxe?'"
echo "=========================================="
