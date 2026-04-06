#!/bin/bash
###############################################################################
# sync-memory-to-bot.sh — Синхронизация MEMORY.md с ботом (канон)
# Запускать на LEGION после каждого значимого действия:
#   cd ~/vibe-coding && bash scripts/sync-memory-to-bot.sh
###############################################################################

OPENCLAW_WORKSPACE="/home/mmber/.openclaw-moa/workspace-moa"

echo "=========================================="
echo "  КАНОН: Синхронизация MEMORY.md с ботом"
echo "=========================================="

# Обновляем MEMORY.md
cat > "$OPENCLAW_WORKSPACE/MEMORY.md" << 'MEMORY_EOF'
# MEMORY — MyCarmi MoA Bot
> Последнее обновление: 28.03.2026 12:51 CET
> Обновлено после: Фаза 1 — GMKtec production-ready

## Кто я
Я — CTIO проекта Banxe AI Bank.
CEO — Moriel Carmi (Mark Fr., @bereg2022, ID: 508602494).
Платформа: OpenClaw, Telegram-бот @mycarmi_moa_bot.

## О Марке (CEO)
- Имя: Moriel Carmi (Mark Fr.)
- Email: moriel@banxe.com
- Telegram: @bereg2022 (ID: 508602494)
- Локация: Франция (Europe/Paris)
- Стиль: единые скрипты ("канон"), подробные объяснения как для новичка
- Подписки: Claude Max ($200), Perplexity Max ($200), ChatGPT Pro, Gemini Pro, X Pro
- Ни одна подписка НЕ даёт API доступа

## Проект Banxe AI Bank
- Компания: Banxe UK Ltd (EMI, FCA authorised)
- Архитектура: 2 слоя — CTIO+CEO / агенты-сотрудники
- Прогресс: ~35% (Фаза 1 завершена)

## ТЕКУЩЕЕ СОСТОЯНИЕ ИНФРАСТРУКТУРЫ (28.03.2026)

### Legion Pro 5 (HUB/Monitor) — mark-legion
- Intel i7-14700HX, 16GB RAM, WSL2 Ubuntu 24.04
- OpenClaw Gateway moa: ACTIVE, порт 18790, v2026.3.24
- LiteLLM: ACTIVE, порт 8080, v1.82.0, 12 моделей
- banxe-dashboard: auto-restart (нужна починка)
- Диск: 918GB свободно из 1TB
- RAM: 14GB свободно из 15GB
- SSH ключ к GMKtec настроен (без пароля)

### GMKtec EVO-X2 (AI Compute Brain) — ОБНОВЛЕНО ПОСЛЕ ФАЗЫ 1
- AMD Ryzen AI MAX+ 395, 16C/32T, 128GB RAM (32GB системе, 96GB GPU)
- GPU: AMD Radeon 8060S, 96GB VRAM, 27°C
- ОС: Ubuntu 24.04.4 LTS (bare metal, kernel 6.17.0-19-generic)
- IP: 192.168.0.72 (ethernet), 192.168.0.117 (wifi)
- SSH: порт 2222, root (ключ + пароль mmber), banxe/mmber2025!

#### Диски GMKtec
- nvme1n1 (Crucial 1TB): Linux система, 685GB свободно, ext4
- nvme0n1 (YMTC 2TB): Windows + данные, 1.5TB свободно, NTFS → /mnt/windows
- Структура данных на 2TB: /mnt/windows/banxe-data/{ollama-models,clickhouse,backups,logs}

#### Сервисы GMKtec (ВСЕ ACTIVE)
- Ollama 0.18.3: порт 11434, 4 модели (98GB), OLLAMA_KEEP_ALIVE=5m
- ClickHouse 26.3.2: база banxe, 6 таблиц, data на 2TB
- OpenClaw 2026.3.24: установлен, конфиг скопирован, Gateway создан (не запущен)
- SSH: порт 2222, fail2ban
- XRDP: порт 3389
- JupyterLab: порт 8888 (/root/train/)

#### Ollama модели (GMKtec)
1. llama3.3:70b — 42GB, Q4_K_M
2. qwen3.5-abliterated:35b — 23GB, Q4_K_M (АКТИВНА в GPU, 27GB)
3. glm-4.7-flash-abliterated — 18GB
4. gpt-oss-derestricted:20b — 15GB

#### ClickHouse таблицы (база banxe)
- transactions, aml_alerts, kyc_events, accounts, audit_trail, agent_metrics

### Роутер Livebox 5 (Orange France)
- Внешний IP: 90.116.185.11
- NAT/PAT: порт 2222 → GMKtec:2222 TCP
- SSH извне: ssh -p 2222 root@90.116.185.11

## Текущая рабочая конфигурация бота
- Модель: ollama/huihui_ai/qwen3.5-abliterated:35b (DIRECT, без LiteLLM)
- Provider: baseUrl http://localhost:11434, api: ollama
- Параметры: num_ctx: 32768, streaming: false (КРИТИЧНО)
- tools.profile: "full", sessions.visibility: "all"
- dmPolicy: allowlist, allowFrom: [508602494]

## КРИТИЧЕСКИЕ ПАРАМЕТРЫ (НЕ ЗАБЫВАТЬ)
- contextWindow НЕ допускается в agents.defaults.models — только params
- streaming: false ОБЯЗАТЕЛЬНО (иначе 2-мин timeout)
- num_ctx: 32768 ОБЯЗАТЕЛЬНО (дефолт 8192 < минимум 16000)
- LiteLLM proxy вызывает raw JSON — обход: прямой Ollama

## Агенты Banxe (10 штук)
1. 🧠 CTIO — Claude Opus 4 — стратегия
2. 🏦 Supervisor — Claude Sonnet 4.5 — оркестрация
3. 📋 KYC/KYB — Claude Sonnet 4.5 — onboarding
4. 💬 Client Service — GLM-4.7-Flash — поддержка 24/7
5. 🛡️ Compliance — Claude Sonnet 4.5 — AML/SAR/FCA
6. ⚡ Operations — Llama 3.3 70B — reconciliation
7. 🪙 Crypto — Qwen 3.5 35B — DeFi
8. 📊 Analytics — GPT-OSS 20B — OLAP
9. ⚠️ Risk Manager — Llama 3.3 70B — скоринг
10. 🔧 IT/DevOps — GLM-4.7-Flash — инфра

## ПЛАН ДВИЖЕНИЯ

### ✅ Выполнено
- Фаза 1: GMKtec production-ready (28.03.2026)
  - Node.js 22, OpenClaw, ClickHouse, 2TB data структура
  - SSH без пароля Legion→GMKtec
  - Конфиг и MEMORY скопированы

### 🔜 Следующие шаги
- Переключить Gateway с Legion на GMKtec
- Фаза 2: форматирование 2TB в ext4 (после копирования нужного с Windows)
- Фаза 3: ликвидация Windows
- Фаза 4: MetaClaw + самообучение

### Незавершённые задачи (приоритет)
1. PII Proxy (Presidio) — €20M штраф GDPR
2. API интеграции (Geniusto, SumSub, Dow Jones)
3. Backup ClickHouse
4. Шифрование at rest (GDPR Art. 32)
5. n8n автоматизация
6. HITL interface
7. Observability (Lunari.ai)

## Аудит безопасности: Score 2/10 → цель 7/10
- Миграция Gateway на GMKtec поднимет до ~4/10
- PII Proxy поднимет до ~6/10
- Шифрование + backup поднимет до ~7/10

## История обновлений
- 27.03.2026: Бот починен (qwen3.5:35b, streaming:false, num_ctx:32768)
- 27.03.2026: SSH наружу настроен (порт 2222, NAT/PAT)
- 27.03.2026: Firefox и XFCE починены на GMKtec
- 28.03.2026: Полная диагностика Legion + GMKtec
- 28.03.2026: Фаза 1 завершена — GMKtec production-ready
- 28.03.2026: SSH без пароля настроен
MEMORY_EOF

echo "  ✓ MEMORY.md обновлён ($OPENCLAW_WORKSPACE/MEMORY.md)"

# Перезапускаем Gateway чтобы бот подхватил новый MEMORY
systemctl --user restart openclaw-gateway-moa 2>/dev/null
sleep 3

if systemctl --user is-active openclaw-gateway-moa &>/dev/null; then
    echo "  ✓ Gateway перезапущен — бот подхватит MEMORY.md"
else
    echo "  ⚠ Gateway не перезапустился"
fi

echo ""
echo "=========================================="
echo "  КАНОН ВЫПОЛНЕН"
echo "=========================================="
