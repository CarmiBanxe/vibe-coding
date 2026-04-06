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
