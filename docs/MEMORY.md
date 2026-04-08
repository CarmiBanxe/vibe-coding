# MEMORY.md — Banxe AI Bank

> Последнее обновление: 2026-04-06. Sprint 10 in progress: G-03 Emergency Stop (17/17 tests ✅), G-02 ExplanationBundle £10k auto-trigger ✅, G-16 Hexagonal Ports (COMPLETE, 30 tests). Code deployed to GMKtec.

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
| LiteLLM proxy | 4000 | active (OpenAI-compat router → Ollama) |
| Jube TM | 5001 | active |
| Marble API | 5002 | active |
| Marble UI | 5003 | active |
| MiroFish UI | 3001 | active (3000 reserved by workflow-service) |
| MiroFish API | 5004 | active (5001 reserved by jube.webapi) |

## Ollama модели (актуально 2026-04-03)

- **qwen3-banxe-v2** — ГЛАВНАЯ МОДЕЛЬ (main/supervisor/kyc/compliance/risk/crypto). Создана из qwen3:30b-a3b с пустым think-блоком для подавления reasoning.
- glm-4.7-flash-abliterated — client-service/operations/it-devops
- gpt-oss-derestricted:20b — analytics/finance
- УДАЛЕНЫ: qwen3.5-abliterated:35b (no tools), llama3.3:70b (медленный)
- Thinking подавлено: пустой `<think></think>` в Modelfile template (НЕ через params)
- OLLAMA_KEEP_ALIVE=-1 (модель всегда в памяти, нет cold start)

## Боты

- @mycarmi_moa_bot → порт 18789, конфиг /root/.openclaw-moa/.openclaw/openclaw.json
- Workspace moa: /home/mmber/.openclaw/workspace-moa/
- @mycarmibot → порт 18793 (не трогать)

## ClickHouse

- БД: banxe, 6 таблиц
- KYC webhook: POST /webhook/kyc-onboard
- AML webhook: POST /webhook/aml-check

## Cron (GMKtec)

- memory-autosync-watcher.sh (docs/MEMORY.md → workspace, каждые 5 мин + **SOUL GUARD**)
- ctio-watcher.sh v2 (сервер → SYSTEM-STATE.md → GitHub)
- watchdog-watcher.sh (каждые 15 мин)
- backup-clickhouse.sh (каждые 6 ч)

## SOUL.md Protection (IMPLEMENTED 2026-04-04)

- **Проблема**: OpenClaw перезаписывал `/root/.openclaw-moa/workspace-moa/SOUL.md` при рестарте
- **Canonical source**: `/home/mmber/.openclaw-moa/soul-protected/SOUL.md` (user-owned, writable by mmber)
- **Защита Уровень 1**: `chattr +i` на обоих workspace SOUL.md (root + mmber)
- **Защита Уровень 2**: SOUL GUARD в memory-autosync-watcher.sh — hash-check + авторестор каждые 5 мин
- **Управление**: `scripts/protect-soul.sh` (deploy / update / unlock / status)
- **Обновить SOUL.md**: `git pull && bash scripts/protect-soul.sh update /data/vibe-coding/docs/SOUL.md`
- **Полный runbook**: `docs/SOUL-PROTECTION.md`

## Санкционная политика Banxe (UK FCA EMI, 2026)

### Категория A — HARD BLOCK (REJECT одной строкой)
Россия/РФ, Беларусь, Иран, КНДР/Северная Корея, Куба, Мьянма, Афганистан, Венесуэла (гос.), Крым, ДНР, ЛНР

### Категория B — EDD/HOLD (Extended Due Diligence)
Сирия (⚠️ снята с BLOCK июль 2025 — санкции Assad частично сняты), Ирак, Ливан, Йемен, Гаити, Мали, Буркина-Фасо, Нигер, Судан, Ливия, Сомали, ДР Конго, ЦАР, Зимбабве, Никарагуа, Южный Судан

### НЕ заблокированы (стандартный AML)
Южная Корея, ОАЭ, Япония, Израиль, Турция, Индия, Бразилия, Мексика, США, EU (все), UK

### Шаблон ответа (СТРОГО — не отклоняться)

**ФОРМАТ ОТВЕТА — только это, ничего лишнего:**
[Страна/транзакция] → [СТАТУС]: [одна строка причины]

**Примеры правильных ответов:**
- Россия → REJECT: заблокированная юрисдикция.
- Сирия → HOLD: EDD-юрисдикция, усиленная проверка.
- Южная Корея £50,000 → HOLD: сумма >£10k, EDD обязателен.
- Южная Корея £500 → ALLOW: низкий риск, стандартный AML.

**ЗАПРЕЩЕНО в ответах:**
- Эмодзи любые (флаги стран, галочки, ракеты и т.д.)
- Таблицы
- Разделители (───)
- Вопросы в конце ("Готовы ли вы...?")
- Упоминание ClickHouse, SumSub, LexisNexis, Dow Jones (не подключены)
- Обращение "Привет, Mark!" — отвечать сразу по существу

**ВАЖНО:** Категория B (Сирия, Ирак, Ливан и др.) = HOLD, НЕ REJECT.

## Задачи

- DONE: Security hardening, GTT unlock (59392MB), ROCm, qwen3:30b-a3b, Sanctions policy, Verification env, SOUL.md deployment (chattr +i + soul-protected + SOUL GUARD в autosync)
- DONE (2026-04-05): GAP 1 auto-verify skill, GAP 2 HITL bridge, GAP 3 promptfoo cron
- DONE (2026-04-05): GAP 4 scenarios bank + feedback_loop.py + train-agent.sh --deploy (полный автоматический pipeline)
- DONE (2026-04-05): GAP 5 drift monitoring cron (6ч) + deploy-gap5-drift-monitor.sh
- DONE (2026-04-05): banxe-architecture репо (локально) + publish-architecture-repo.sh
- DONE (2026-04-05): verify-statement/SKILL.md добавлен в deploy-gap1-auto-verify.sh [2/5]
- DONE (2026-04-05): policy_scope: dict[str, str] → VerificationResult (developer-core 53770fc) + ConsensusResult → JSONL corpus
- DONE (2026-04-05): policy_scope propagated → AMLResult + BanxeAMLResult → ClickHouse audit_trail (policy_jurisdiction/regulator/framework) (vibe-coding 4760b7d)
- DONE (2026-04-05): train-agent.sh --force safety gate — BLOCKED если accuracy<85% или drift>0.15 (ADR-003) (45bb5ef)
- DONE (2026-04-05): banxe-architecture опубликован → https://github.com/CarmiBanxe/banxe-architecture (6a4da41)
- DONE (2026-04-05): GAP 5 deploy → задеплоен, status=no_corpus (ожидает первого train-agent.sh)
- DONE (2026-04-05): scenario_registry engines bindings — case_orchestrator SCN-001 + ML sanctions SCN-002 (38637ec)
- DONE (2026-04-05): sanctions_check.py ADR-009 routing — Yente :8086 primary → Watchman :8084 fallback → local fuzzy (119c357)
- DONE (2026-04-05): emergency_stop.py + api.py — EU AI Act Art.14 stop button (d5c1007), syntax OK
- [DONE, Sprint 3] Stop button endpoint — G-03 DONE: EmergencyPort, emergency_stop.py, API, Marble panel
- [DONE, Sprint 2] ExplanationBundle runtime (XAI, EU AI Act + FCA PS7/24) — G-02 DONE
- [DONE, Sprint 2] compliance_config.yaml externalization (12-Factor Factor III) — G-07 DONE
- [DONE, Sprint 4] Bounded Context context.yaml (import boundaries, DDD) — G-18 DONE
- PENDING: CTIO бот (ждём token от Олега), Vendor API (ждём вендоров)
- PENDING: GAP 7 OpenRLHF pipeline, GAP 8 TinyTroupe/AMLSim — не блокирующие
- DONE (2026-04-06): GAP 6 autoresearch — docs/GAP-6-AUTORESEARCH.md (config fix: LiteLLM :4000, qwen3-30b)
- DONE (2026-04-06): HITL Dashboard spec — docs/HITL-DASHBOARD-SPEC.md (MVP: hitl_queue CH + FastAPI + Telegram)
- DONE (2026-04-06): CarmiBanxe/collaboration — заархивирован на GitHub
- DONE (2026-04-06 Sprint 10): G-03 Emergency Stop — test_emergency_stop.py 17/17 тестов (T-01..T-17): fail-open, dual-write, lifecycle, I-23, I-24 ✅
- DONE (2026-04-06 Sprint 10): G-16 Hexagonal Ports — 4 порта (EmergencyPort/PolicyPort/DecisionPort/AuditPort) + 30 тестов — COMPLETE (инвентаризация)
- DONE (2026-04-06 Sprint 10): G-02 ExplanationBundle auto-trigger — api.py transaction_check: if amount_gbp >= 10_000 → ExplanationBundle.from_banxe_result() (I-25, FCA SS1/23)
- DONE (2026-04-06 Sprint 10): scripts/deploy-sprint10-g02-g03.sh — деплой G-02+G-03 на GMKtec (git pull ✅)
- ✅ think:false ПРОВЕРЕНО (2026-04-05): OpenClaw передаёт только num_ctx+streaming в params.
  Thinking подавлено через пустой <think></think> в Modelfile + thinkingDefault:"off" в openclaw.json.
  Действие не требуется — механизм работает корректно.

## Compliance Stack (src/compliance/)

Исходный код AML/KYC стека теперь в репозитории vibe-coding: `src/compliance/`
Задеплоен на GMKtec: `/data/banxe/compliance/`
Локальная копия (collaboration): `/home/mmber/collaboration/compliance/` — более не основная

| Файл | Назначение |
|------|-----------|
| api.py | FastAPI :8093 — 15 endpoints |
| audit_trail.py | ClickHouse logging, TTL 5 лет |
| crypto_aml.py | FINOS OpenAML + Watchman OFAC |
| dashboard.py | CEO Dashboard, ClickHouse analytics |
| sanctions_check.py | Watchman + finsanctions |
| test_suite.py | 20 тестов, 18 pass, 2 warn |
| tx_monitor.py | 6 правил + Redis velocity |



### Banxe Screener API (порт 8085)
- Watchman: http://localhost:8085/screen?q=entity_name
- sanctioned + pep + risk_level + matches
- Sources: Moov Watchman (OFAC/UN/EU/UK) + Wikidata SPARQL (PEP, CC0)

### Moov Watchman (порт 8084, Apache 2.0)
- Binary: /usr/local/bin/banxe-watchman
- Data: /data/banxe/watchman/
- Lists: OFAC SDN, UN, EU, UK OFSI, US CSL, FinCEN 311

### OpenClaw Skill
- workspace-moa/skills/banxe-screener/SKILL.md
- Agents вызывают: curl http://localhost:8085/screen?q=ИМЯ

### Phase 2a — Jube TM (2026-04-03)
- deploy-phase2-jube.sh: PostgreSQL 17 + Redis Stack + Jube WebAPI + Jube Jobs
- Jube source: /data/banxe/jube-src (AGPLv3, internal only)
- Порты: Jube API→5001, PG→15432 (internal), Redis→16379 (internal)
- OpenClaw skill: workspace-moa/skills/jube-aml/SKILL.md
- Интеграция: Jube callback → Screener /screen для обогащения кейсов

### Phase 2b — Marble Case Management (2026-04-03 DEPLOYED)
- deploy-phase2-marble.sh: marble-backend (Go) + marble-frontend (React) + PostgreSQL 17 + Firebase emulator
- Marble source: /data/banxe/marble-src (Apache 2.0)
- Порты: Marble API→5002, Marble UI→5003, PG→15433 (internal), Firebase→9099/4000
- Compose: /data/banxe/marble-src/docker-compose.marble.yml
- Organisation: Banxe (created)
- Admin user: mark@banxe.com (created)
- Auth: Firebase emulator (local mode, no cloud Firebase needed)
- OpenClaw skill: workspace-moa/skills/marble-cases/SKILL.md ✅ DONE (2026-04-05)
- MLRO рабочий стол: http://[gmktec]:5003

### Полный стек (после деплоя Phase 2)
```
Screener  :8085 → Watchman :8084          Phase 1
Jube TM   :5001 → SAR detection           Phase 2a
Marble    :5002 → Case management UI      Phase 2b
ClickHouse:9000 → FCA audit trail         always
```

### Phase 3 (следующий): PassportEye (MRZ) + DeepFace (liveness) — KYC documents

## Обучающий стек (Перекрёстная верификация агентов)

> Установлено: 2026-04-04

### Инструменты (GMKtec) — установлено 2026-04-04
| Инструмент | Версия | Расположение |
|---|---|---|
| Promptfoo | 0.121.3 | глобальный бинарь + npx |
| DeepEval | 3.9.5 | системный pip |
| LangGraph | 1.1.6 | системный pip |
| TinyTroupe | 0.0.1 | системный pip (--break-system-packages) |
| AMLSim | git | /opt/AMLSim |
| AMLGentex | git | /opt/AMLGentex |
| Evidently AI | 0.7.21 | системный pip |
| OpenRLHF | **0.9.10** | /root/.venvs/openrlhf (активация: source /root/.venvs/openrlhf/bin/activate) |
| flash-attn | 2.8.3 | в venv openrlhf (legacy mode — нет CUDA модуля) |

### GPU на GMKtec
- AMD Ryzen AI MAX+ 395 → **ROCm доступен**
- torch 2.11.0+cu130 (CUDA build, CUDA=False) — для ROCm нужна ROCm-сборка torch
- flash-attn установлен но работает без CUDA (legacy attention mode) — приемлемо для верификации
- Полноценный RLHF с GPU acceleration → Legion RTX 4070 (setup-openrlhf-legion.sh)

### Данные и корпус
- /data/banxe-training/ — обучающий корпус (5 категорий A-E)
- ClickHouse: banxe.verification_corpus — лог всех верификаций

### Promptfoo eval cron (GAP 3, 2026-04-05)
- Script: `scripts/run-promptfoo-eval.sh` → `/data/vibe-coding/scripts/run-promptfoo-eval.sh`
- Cron: `/etc/cron.d/banxe-promptfoo-eval` — воскресенье 04:00 UTC (после adversarial sim 02:00)
- Model: `ollama:chat:qwen3-banxe-v2` (заменено с qwen3:8b)
- Config: `~/developer/compliance/training/promptfoo.yaml`
- Results: `~/developer/compliance/training/results/kyc-specialist-results.json`
- Alert: Telegram → 508602494 если fail_rate > 20%
- Деплой: `bash scripts/deploy-gap3-promptfoo.sh`

### autoresearch (karpathy-style)
- Роль: вспомогательный контур R&D, НЕ продовый
- Оптимизирует: системные инструкции верификаторов, scoring, thresholds
- Установлен: /opt/AutoResearchClaw/

## Training Data Pipeline (ACTIVE 2026-04-04)

- Workflow: `.github/workflows/extract-training-data.yml`
- Целевое репо: `CarmiBanxe/banxe-training-data`
- Секрет `TRAINING_DATA_TOKEN` установлен ✅ (fine-grained PAT от CarmiBanxe)
- Corpus: A-compliance / B-architecture / C-scenarios / D-decisions / E-feedback
- Триггер: push в main, кроме `auto: SYSTEM-STATE`
- D-decisions экспорт: `scripts/backup-clickhouse-training.sh` — запускать ежемесячно на GMKtec
- Adversarial sim: `scripts/run-adversarial-sim.sh` — cron на GMKtec, воскресенье 02:00
  → экспортирует `banxe.audit_trail` → `docs/training-exports/decisions-YYYY-MM.jsonl`
  → workflow подберёт при следующем push
# workflow verified 2026-04-04T21:11:15Z

## BANXE AI Stack v2.0 (Sprint 9, 2026-04-06)

### Архитектура (Four-Partner Swarm)

| # | Партнёр | Роль | Точка входа |
|---|---------|------|-------------|
| 1 | **Claude Code** | Архитектор, ревьюер, оркестратор | `claude` |
| 2 | **Ruflo** | Оркестратор multi-step потоков | `ruflo/start-ruflo.sh` |
| 3 | **Aider CLI** | Единственный code executor | `scripts/aider-banxe.sh` |
| 4 | **MiroFish** | Симулятор поведения/регуляции | `:3001` (UI) / `:5004/health` (API) |

- **LiteLLM :4000** — model routing infrastructure (не партнёр). Маршруты: qwen3-30b, qwen3-banxe, glm-4-flash, gpt-oss-20b
- **Qoder CLI** — УДАЛЁН полностью. Aider CLI — замена. `.qoder/` директория удалена из всех репо.

### Ключевые артефакты (developer-core → все репо)

| Файл | Назначение |
|---|---|
| `ruflo/config.yaml` | Ruflo: модели, партнёры, OpenClaw боты, Telegram alerts |
| `ruflo/start-ruflo.sh` | Stack health check (LiteLLM + Ollama + OpenClaw + MiroFish + Aider) |
| `scripts/aider-banxe.sh` | Aider via LiteLLM: `--fast` / `--full` / `--banxe` / `--unrestricted` |
| `scripts/parallel-verify.sh` | 3-модельная верификация: 2/3 consensus → PASS |
| `scripts/start_banxe_stack.sh` | Master startup check всего стека |
| `docs/COLLAB.md` v4.0 | Collaboration contract: Four-Partner Swarm, CANON layer, safe exec rules |
| `docs/subagent-patterns.md` | Named patterns: RIV / MFR / CA / PDG / MED |

### MiroFish (задеплоен на GMKtec 2026-04-06)

- Docker compose: `/root/developer/mirofish/docker-compose.yml`
- Image: `ghcr.io/666ghj/mirofish:latest`
- Порты: `3001:3000` (UI) / `5004:5001` (API)
- Health: `curl http://localhost:5004/health` → `{"service":"MiroFish Backend","status":"ok"}`
- Рестарт: `ssh gmktec 'cd /root/developer/mirofish && docker compose up -d'`

### CANON System (Sprint 7–8, ~/developer/canon/)

- `CORE.md` — 13 секций: preflight, epistemic accuracy, anti-hallucination, KA-01..KA-10
- `DEV.md`, `DECISION.md`, `FR_MODULE.md` (French legal, v3.1-banxe)
- Иерархия: **CANON → CLAUDE.md → AGENTS.md → COLLAB.md**
- Preflight: `bash scripts/canon_preflight.sh`

## banxe-emi-stack — Financial Analytics P0 (2026-04-06)

- **Репо:** `CarmiBanxe/banxe-emi-stack` (private) → https://github.com/CarmiBanxe/banxe-emi-stack
- **Локально:** `/home/mmber/banxe-emi-stack/` — ОТДЕЛЬНЫЙ терминал, не смешивать с vibe-coding
- **Назначение:** FCA CASS 15 / PS25/12 P0 — deadline 7 May 2026
- **IL:** IL-009 VERIFY (banxe-architecture commit 70d48ea)
- **Commit:** ab81ecc — 24 файла, 1385 строк

### P0 компоненты (committed ab81ecc)

| Компонент | Путь | Статус |
|-----------|------|--------|
| Midaz async client | `services/ledger/midaz_client.py` | ✅ |
| ReconciliationEngine | `services/recon/reconciliation_engine.py` | ✅ (mirror vibe-coding 3f7060f) |
| StatementFetcher (CSV) | `services/recon/statement_fetcher.py` | ✅ |
| CAMT.053 parser wrapper | `services/recon/bankstatement_parser.py` | ✅ (Phase 2 адаптер) |
| FIN060 PDF generator | `services/reporting/fin060_generator.py` | ✅ (WeasyPrint) |
| dbt staging model | `dbt/models/staging/stg_ledger_transactions.sql` | ✅ |
| dbt safeguarding mart | `dbt/models/marts/safeguarding/safeguarding_daily.sql` | ✅ |
| dbt FIN060 mart | `dbt/models/marts/fin060/fin060_monthly.sql` | ✅ |
| Docker recon stack | `docker/docker-compose.recon.yml` | ✅ |
| Docker reporting stack | `docker/docker-compose.reporting.yml` | ✅ |
| Daily recon cron | `scripts/daily-recon.sh` (07:00 UTC Mon-Fri) | ✅ |
| Monthly FCA return | `scripts/monthly-fca-return.sh` | ✅ |
| Audit export | `scripts/audit-export.sh` | ✅ |
| ReconcAgent spec | `.claude/agents/reconciliation-agent.md` | ✅ |
| ReportingAgent spec | `.claude/agents/reporting-agent.md` | ✅ |

### Midaz account IDs (ADR-013)
```
ORG_ID:              019d6301-32d7-70a1-bc77-0a05379ee510
LEDGER_ID:           019d632f-519e-7865-8a30-3c33991bba9c
client_funds:        019d6332-da7f-752f-b9fd-fa1c6fc777ec
operational:         019d6332-f274-709a-b3a7-983bc8745886
RECON_THRESHOLD_GBP: 1.00
```

### P1 pending (не в skeleton)
- n8n workflow JSON (live n8n instance required)
- pgAudit init SQL (`docker/postgres/pgaudit.sql`)
- adorsys PSD2 gateway (CAMT.053 auto-pull, Phase 2)

## Architecture Repository (2026-04-05)

- Репо: `CarmiBanxe/banxe-architecture` (приватный, **ОПУБЛИКОВАН 2026-04-05** → https://github.com/CarmiBanxe/banxe-architecture)
- Назначение: единственный источник истины для архитектурных решений
- Все проекты ОБЯЗАНЫ соответствовать
- Структура: INVARIANTS.md (20 инвариантов), PRIVILEGE-MODEL.md, COMPLIANCE-ARCH.md, COMPOSABLE-ARCH.md (6 контуров), SANCTIONS-POLICY.md, STACK-LAYERS.md, SOUL-TEMPLATE.md, SERVICE-MAP.md, DEFERRED-PROJECTS.md, README.md
- ADR-004: Jube AGPLv3 boundary (internal only)
- ADR-005: Marble ELv2 boundary (internal only)
- ADR-006: EvidenceBundle dataclass (SAR evidence pack, FCA MLR 2017 §20)
- ADR-008: Jurisdiction label — `_POLICY_JURISDICTION/REGULATOR/FRAMEWORK` prefix (не путать с origin/residence/counterparty)
- ADR-009: OpenSanctions/Yente — MIT, Phase 3, порт :8086, Watchman → fallback
- ADR-010: AMLTRIX taxonomy — Apache 2.0, scenario_registry.yaml как version pin
- ADR-011: Reference vs Dependency (Jube/Tazama/AMLTRIX = reference; Marble/Watchman/Yente = replaceable; validators+feedback_loop = core)
- Проверка проекта: `bash validators/check-compliance.sh ~/vibe-coding`
- Публикация: `bash scripts/publish-architecture-repo.sh` (после `gh auth login`)

## Архитектурные ограничения (Canon 2026-04-05)

### Модель привилегий — КАНОН
- **РАЗРАБОТЧИК** (developer/CTIO): изменяет SOUL.md, SKILL.md, AGENTS.md, openclaw.json, запускает train-agent.sh, promptfoo eval, adversarial sim, feedback_loop.py --apply, изменяет thresholds/forbidden_patterns
- **ОПЕРАТОР-ДУБЛЁР** (MLRO): видит алерты, принимает HITL-решения в Telegram и Marble UI, управляет кейсами — НЕ может менять поведение агента

### Терминалы оператора
- Терминал 1: Telegram `@mycarmi_moa_bot` — алерты + HITL + compliance справки
- Терминал 2: **Marble UI (:5003)** — РЕКОМЕНДОВАН для MLRO (case queue, SAR review, audit trail)
- n8n (:5678) — developer-only, не для оператора
- OpenClaw :18789 — дублирует Telegram, не нужен как второй терминал

### Telegram-бот — НЕ банковское приложение (ADR-002)
Текущий бот = терминал оператора. Клиентский бот (платежи, KYC, баланс) = ОТДЕЛЬНЫЙ проект, отложен.

### Отложенные проекты
Telegram-бот (клиентский), Web-app Banxe, мобильное приложение — отдельные инсталляции, не делать сейчас. Зафиксированы в `banxe-architecture/DEFERRED-PROJECTS.md`.

## GAP 5: Drift Monitoring (2026-04-05)

- Script: `scripts/run-drift-monitor.sh` → `/data/vibe-coding/scripts/run-drift-monitor.sh`
- Cron: `/etc/cron.d/banxe-drift-monitor` — каждые 6 часов (`0 */6 * * *`)
- Метрики: composite_drift = avg_drift×0.4 + refuted_rate×0.4 + flag_rate×0.2
- Evidently AI: используется если доступен, иначе heuristic
- Alert threshold: 0.15 → Telegram → 508602494
- Отчёты: `/data/banxe/promptfoo/compliance/training/drift-reports/`
- latest: `drift_latest.json`
- Деплой: `bash scripts/deploy-gap5-drift-monitor.sh`

## Auto-Deploy Pipeline (--deploy, 2026-04-05)

`train-agent.sh --deploy` теперь **полностью автоматический**:

```
Шаг [1/4] прогон сценариев → corpus JSONL
Шаг [2/4] метрики + report
Шаг [3/4] feedback_loop.py --apply:
           compliance_validator.py → developer-core git push
           SOUL.md + AGENTS.md    → vibe-coding git push
Шаг [4/4] check-compliance.sh → если PASS:
           ssh gmktec git pull
           protect-soul.sh update (SOUL.md chattr+i)
           cp AGENTS.md → оба workspace
           → "AUTO-DEPLOY: SOUL.md + AGENTS.md → GMKtec OK"
           если FAIL → BLOCKED, exit 1
```

- AGENTS.md canonical: `vibe-coding/agents/workspace-moa/AGENTS.md`
- apply_agents_patches() пишет в локальный файл (раньше только print)
- commit_vibe_changes(): коммитит SOUL.md + AGENTS.md в vibe-coding
- Validator: `~/banxe-architecture/validators/check-compliance.sh`

## Agent Training System (GAP 4, 2026-04-05)

### Сценарный банк (developer-core)
- `~/developer/compliance/training/scenarios/` — 160+ сценариев для 5 ролей
  - kyc_specialist.json: 50 сценариев (A:20, B:10, C:10, D:5, E:5)
  - aml_analyst.json: 40 сценариев (A:15, B:10, C:8, D:4, E:3)
  - compliance_officer.json: 30 сценариев (A:10, B:6, C:8, D:3, E:3)
  - risk_manager.json: 20 сценариев (A:8, B:4, C:4, D:2, E:2)
  - crypto_aml.json: 20 сценариев (A:10, B:4, C:6, D:2, E:2)
- Категории: A=жёсткие правила, B=граничные кейсы, C=красные линии, D=роутинг, E=неопределённость
- `expected_consensus` = compliance ground truth (не текущее поведение верификатора)

### Feedback Loop
- `~/developer/compliance/training/feedback_loop.py`
- Читает corpus_*.jsonl REFUTED записи, генерирует патчи:
  - forbidden_pattern → вставляет regex в `_FORBIDDEN_PATTERNS` в compliance_validator.py
  - soul_update → добавляет правило в SOUL.md под "СТРОГО ЗАПРЕЩЕНО"
  - agents_update → информационно (применять вручную на GMKtec)
- Режимы: `--report` (только показать) / `--apply` (применить + git push)
- Дедупликация: пропускает уже присутствующие паттерны/правила

### Скрипты (vibe-coding)
- `scripts/train-agent.sh` — запуск обучения из терминала
  - `bash scripts/train-agent.sh --agent kyc-specialist-v2 [--rounds N] [--categories A,B,C] [--feedback] [--deploy]`
  - Верификация локально на Legion (не нужен SSH), репорт по категориям
  - Сохраняет: data/training-results/<agent>_<ts>.json + corpus JSONL
- `scripts/apply-feedback.sh` — standalone обёртка для feedback_loop.py
  - `bash scripts/apply-feedback.sh [--report|--apply] [--since YYYY-MM-DD] [--agent <id>]`

### Corpus
- Legion: `~/developer/compliance/training/corpus/corpus_<agent>_<ts>.jsonl`
- Структура: interaction_id, agent_id, statement, expected_consensus, consensus, correction_source, drift_score, training_flag

## HITL Bridge (2026-04-05)

- Script: `scripts/hitl-bridge.sh` → задеплоен на GMKtec: `/data/vibe-coding/scripts/hitl-bridge.sh`
- Вызывается: `~/developer/compliance/training/verification_graph.py` `node_hitl_interrupt`
- Marble: POST http://localhost:5002/api/cases → создаёт HOLD кейс
- Telegram: Bot API → 508602494 (CEO) + TELEGRAM_RECIPIENTS из /data/banxe/.env
- Env: `TELEGRAM_BOT_TOKEN` или `MOA_BOT_TOKEN` в /data/banxe/.env
- Graceful degradation: если Marble недоступен → только Telegram; если оба недоступны → exit 1
- Лог: /data/logs/hitl-bridge.log
- Вывод: `marble_case_id=<id>` (читается verification_graph.py → передаётся в ConsensusResult)

## Developer Core (~/developer → main, 2026-04-05)

- Репо: `CarmiBanxe/developer-core`, локально: `~/developer`
- Ветка: `master` → `main` (переименована, master удалена)
- ss1 добавлен в sync-targets (sync-to-project.sh + PROJECT-REGISTRY.csv)
- collaboration → developer-core: слияние завершено (commit 27bf885)
- PENDING (user browser action): архивировать `CarmiBanxe/collaboration` → Settings → Danger Zone → Archive
- Замена CodeQL: `banxe-verification-tests.yml` (LangGraph cross-verification network, 5 категорий A-E)
- Training CI: `training-quality-report.yml` (deepeval + evidently, еженедельно пн 03:00 UTC)
- BUG FIX 2026-04-05: `without EDD` / `PEP without` добавлены в forbidden patterns compliance_validator
  (было: "Approve PEP without EDD" → CONFIRMED; стало: → REFUTED confidence 1.0)
- Verify API: `banxe-verify-api.service` → порт 8094 (8091=HITL, 8092=Guiyon bridge)
  Skills: verify-statement + auto-verify (GAP 1, 2026-04-05) + marble-cases
  SOUL.md: ШАГ 3 авто-верификация добавлен (2026-04-05)
  AGENTS.md: Auto-Verify Rule (MANDATORY) добавлен (deploy-gap1-auto-verify.sh)
  HITL Bridge: scripts/hitl-bridge.sh → Marble :5002 + Telegram (GAP 2, 2026-04-05)
  Promptfoo cron: /etc/cron.d/banxe-promptfoo-eval — воскресенье 04:00 (GAP 3, 2026-04-05)
  Cron adversarial sim: /etc/cron.d/banxe-adversarial (вс 02:00)

## Архитектурный аудит v3 (2026-04-05)

Проведён глубокий аудит по 10+ классическим принципам + OpenClaw/multi-agent специфика + FINOS AIGF v2.0.
Полный реестр: `banxe-architecture/GAP-REGISTER.md` (22 пробела: P1×7, P2×11, P3×4).
Sprint 0 план: `banxe-architecture/SPRINT-0-PLAN.md` (Ports, Bounded Contexts, Hooks, AIGF mapping).

### Оценки по принципам (обновлено 2026-04-06)
| Принцип | Оценка | Статус |
|---|---|---|
| AI-Native / Deterministic Bridge | 9/10 | G-02 + G-12 + G-14 DONE |
| Policy-as-Code | 10/10 | G-19 OPA/Rego DONE |
| CQRS + Event Sourcing | 9/10 | G-01 + G-17 DONE |
| HITL / EU AI Act Art.14 | 9/10 | G-03 DONE (emergency_stop + api + panel) |
| DDD / Bounded Contexts | 8/10 | G-06 + G-18 DONE |
| Microservices / SoC | 6/10 | Process-level isolation только у Yente |
| 12-Factor | 9/10 | G-07 + G-20 DONE |
| XAI | 7/10 | G-02 DONE (ExplanationBundle) |
| Multi-agent trust | 9/10 | G-04 + G-05 + G-10 + G-11 DONE |

### Новые инварианты (I-21..I-25)
Добавлены в `banxe-architecture/INVARIANTS.md`:
- I-21: feedback_loop.py НИКОГДА не auto-патчит SOUL.md/AGENTS.md
- I-22: Level-2 агент не пишет в policy layer
- I-23: Emergency stop проверяется ДО любого автоматического решения
- I-24: Decision Event Log = append-only (G-01, ещё не реализован)
- I-25: ExplanationBundle обязателен для решений > £10K (G-02, ещё не реализован)

### Governance документы созданы
- `banxe-architecture/GAP-REGISTER.md` — реестр 15 пробелов + спринт-план
- `banxe-architecture/governance/change-classes.yaml` — Class A/B/C/D с approval gates
  - CLASS_B_SOUL_AGENTS: feedback_loop can_apply=NEVER, unanimous MLRO+CTO required

### Sprint план (обновлено 2026-04-06)
- Sprint 0–7: ALL DONE (22/22 GAP, 663 tests, CANON system deployed)
- Sprint 8 (текущий): MEMORY.md sync + CANON hooks integration
- Pending: Phase 3 KYC (PassportEye + DeepFace), CTIO бот, GAP-REGISTER пересмотр 2026-07-01

### Новые gaps из v3 (G-16..G-22)
- G-16 (P1): Hexagonal Architecture — нет Ports & Adapters
- G-17 (P1): Event Sourcing — нет domain events для решений
- G-18 (P2): DDD — плоская структура, нет 5 bounded contexts
- G-19 (P2): Controls-as-code (OPA/Rego) вместо bash-скрипта
- G-20 (P2): 12-Factor — нет release pipeline + structured logging
- G-21 (P2): Нет зонирования AI-генерации в Claude Code hooks
- G-22 (P3): FINOS AIGF v2.0 mapping — PARTIAL (таблица в SPRINT-0-PLAN.md)

## CANON System (Sprint 7, 2026-04-06)

- Расположение: `canon/` (видимая директория) в developer-core, vibe-coding, banxe-architecture
- Структура: `canon/CANON.md` (index), `canon/modules/` (6 модулей), `canon/rules/`, `canon/scripts/`
- Модули: CORE.md (12 разделов, 234 строки), FR_MODULE.md (16 разделов, 400 строк), DEV.md, DOC.md, LEGAL.md, DECISION.md
- Профили: DEV (без юридических блоков) — основной для BANXE; LEGAL+FR (с FR_MODULE) — для юридических проектов (guiyon, ss1)
- Источник: CORE_CANON v5.1.8a + FR_MODULE v17 из Google Drive CHATGPT_CANON
- Коммиты: developer-core@25c2d37, vibe-coding@70ef5dd, banxe-architecture@4f2e8ac

## Policy Provenance (2026-04-05)

Единый контракт `policy_scope: dict[str, str]` на весь стек — ключи с `policy_` prefix:

```
compliance_validator.py (_POLICY_JURISDICTION/REGULATOR/FRAMEWORK)
  → VerificationResult.policy_scope {"jurisdiction","regulator","framework"}
  → ConsensusResult.policy_scope = cv.policy_scope → JSONL corpus (developer-core 53770fc)

banxe_aml_orchestrator.py (POLICY_JURISDICTION/REGULATOR/FRAMEWORK)
  → AMLResult.policy_scope {"policy_jurisdiction","policy_regulator","policy_framework"}
  → BanxeAMLResult.policy_scope → to_audit_dict() → **self.policy_scope
  → ClickHouse audit_trail: policy_jurisdiction="UK", policy_regulator="FCA", policy_framework="MLR 2017" (vibe-coding 4760b7d)
```

- Ключи в AML слое с `policy_` prefix чтобы не конфликтовать с origin_jurisdiction, residence_jurisdiction
- Ключи в verification слое без prefix — для читаемости JSONL corpus
- При multi-jurisdiction (EU/UAE): только поменять значение dict, нулевой рефакторинг (ADR-008)

## Keycloak IAM — BT-011 UNBLOCKED (2026-04-08)

- Keycloak 26.2.5 задеплоен на GMKtec порт **8180** (`docker run --network host`)
- PostgreSQL для Keycloak: контейнер keycloak-db, порт **5433**, БД `keycloak`
- Realm: `banxe` | Roles: CEO / MLRO / CCO / OPERATOR / AGENT / AUDITOR / READONLY
- Clients: `banxe-backend` (Resource Owner PW Grant), `banxe-agents`
- User: `mark` (Moriel Carmi) → роль CEO
- **Legion достигает GMKtec:8180 напрямую** — `KEYCLOAK_URL=http://gmktec:8180` работает
- `IAM_ADAPTER=keycloak` → `KeycloakAdapter` live; `IAM_ADAPTER=mock` (default) → тесты
- Admin console: `http://gmktec:8180/admin`
- `KeycloakAdapter`: `banxe-emi-stack/services/iam/mock_iam_adapter.py` (commit b226c56)
- FA-14 → ✅ DEPLOYED | IL-039 DONE | banxe-architecture commit 29d27be
- SMS OTP (Twilio) всё ещё ожидает → BT-010
