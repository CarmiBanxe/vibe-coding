# CLAUDE.md — Инструкции для Claude Code

## Проект
Banxe AI Bank — EMI, FCA authorised. Платформа на OpenClaw + Telegram боты + Ollama.

## Репозиторий
https://github.com/CarmiBanxe/vibe-coding

## Ключевые файлы (ПРОЧИТАЙ ПЕРВЫМИ)
1. `docs/MEMORY.md` — долгосрочная память проекта, текущий статус, все решения
2. `docs/SYSTEM-STATE.md` — актуальное состояние сервера GMKtec (автогенерируется каждые 5 мин)
3. `docs/VERIFICATION-CANON.md` — правила верификации кода (Semgrep, CodeRabbit, Snyk, CodeQL)
4. `docs/OPENCLAW-REFERENCE.md` — ревизия OpenClaw по 146-страничному руководству (893 строк)
5. `docs/SOUL-PROTECTION.md` — архитектура защиты SOUL.md (chattr+i + soul-protected + SOUL GUARD)

## Архитектура
- **Legion Pro 5** (i7-14700HX, 16GB) — ТЕРМИНАЛ, WSL2 Ubuntu 24.04
- **GMKtec EVO-X2** (AMD Ryzen AI MAX+ 395, 128GB RAM) — AI МОЗГ
  - SSH: `ssh gmktec` с Legion (порт 2222, алиас настроен)
  - Ollama 0.18.3, порт 11434, модель: `huihui_ai/glm-4.7-flash-abliterated`
  - OpenClaw Gateway на порту 18789 (@mycarmi_moa_bot)
  - ClickHouse на порту 9000 (БД banxe, 6 таблиц)
  - PII Proxy (Presidio) на порту 8089
  - Deep Search на порту 8088
  - n8n на порту 5678
  - nginx 443/80 (Web UI, self-signed SSL)
  - OpenClaw Gateway на порту 18791 (CTIO бот Олега)
  - OpenClaw Gateway на порту 18793 (@mycarmibot)
  - OpenClaw Gateway на порту 18795 (НЕИЗВЕСТЕН — требует идентификации)

## Люди
- **CEO**: Moriel Carmi (Mark), Telegram: @bereg2022, ID: 508602494
- **CTIO**: Олег, Telegram: @p314pm, Linux user: ctio на GMKtec
  - Права CTIO = ПОЛНЫЕ, конгруэнтные CEO (sudo NOPASSWD)

## Пользователи GMKtec
| User | Назначение |
|------|-------------|
| root | Админ, запуск gateway |
| banxe | Основной пользователь |
| ctio | Олег (полные права, sudo NOPASSWD) |
| openclaw | Системный (миграция отложена) |
> Пароли хранятся в .env на GMKtec — НЕ в репозитории.

## ИЗОЛЯЦИЯ ПРОЕКТА (Canon)

- Этот терминал = только этот проект = только этот репозиторий.
- Не читать, не цитировать, не заимствовать контекст, файлы, решения из GUIYON, MetaClaw или любого другого проекта.
- Любой перенос контента между проектами — только по явной команде пользователя с указанием обоих проектов.

## COMPLIANCE STACK (Aider: прочитай перед src/compliance/)

- Canonical docs: `src/compliance/COMPLIANCE_ARCH.md`
- **5 инвариантов** (OFAC RSS = dead since 31.01.2025, Watchman minMatch=0.80, ClickHouse TTL 5Y, Jube AGPLv3 internal-only, GUIYON Canon)
- **Decision thresholds:** REJECT ≥ 70, HOLD ≥ 40, SAR auto ≥ 85 или sanctions_hit
- Тесты: `test_phase15.py` (39/39 pytest), `test_suite.py` (18 pass, 2 warn)
- Pending keys: `COMPANIES_HOUSE_API_KEY`, `OPENCORPORATES_API_KEY` → `/data/banxe/.env`

## КАНОН (обязательные правила)

### 1. Скрипты — СТРОГО
- Каждое действие на сервере оформляется как ЕДИНЫЙ bash-скрипт в `scripts/`
- Скрипт должен быть самодостаточным: один файл делает всё (диагностика + действие + проверка + обновление MEMORY.md)
- НИКОГДА не давать пользователю отдельные команды для ручного выполнения. Без исключений.
- Пользователь запускает ТОЛЬКО: `cd ~/vibe-coding && git pull && bash scripts/SCRIPTNAME.sh`
- Скрипты запускаются на Legion, SSH в GMKtec внутри скрипта
- Git push автоматический внутри скрипта — пользователь НЕ делает git-команды вручную
- **Claude Code**: ты можешь сам запускать команды в терминале, НО результат всегда сохраняй как готовый скрипт в `scripts/`, чтобы его можно было повторить. Если пользователь просит что-то сделать на сервере — сначала создай скрипт, закоммить, запушь, потом выполни.

### 2. MEMORY.md — автообновление
- После КАЖДОГО значимого действия (диагностика, фикс, установка, стратегия) — обновить `docs/MEMORY.md` и запушить в GitHub
- Cron на GMKtec синхронизирует MEMORY.md в workspace бота каждые 5 минут
- Не переписывать MEMORY.md с нуля — только кумулятивное редактирование (добавлять/обновлять секции)

### 3. SYSTEM-STATE.md — сигнализация
- Любое удаление/установка инструментов автоматически отражается в `docs/SYSTEM-STATE.md`
- CTIO Watcher (cron */5) сканирует сервер → обновляет SYSTEM-STATE.md → пушит в GitHub
- Бот читает этот файл при каждом ответе

### 4. Верификация кода
- Уровень 1 (мгновенно): Semgrep при изменении файла
- Уровень 2 (pre-commit): Semgrep + Snyk + секреты
- Уровень 3 (PR): CodeRabbit AI + CodeQL + Qodo тесты
- KYC/AML/Payments — тесты обязательны
- Результаты верификации записываются в MEMORY.md

### 5. Безопасность
- `dangerouslyDisableDeviceAuth: false` (ВСЕГДА)
- `gateway.auth.token` настроен
- `discovery.mdns.mode: "off"`
- Immutable files (chattr +i) на критических файлах (watchers, systemd, semgrep)
- Security Score: 8/10
- PII Proxy (Presidio) на порту 8089 для GDPR анонимизации

### 6. Стиль работы
- **АВТОНОМНОСТЬ**: не задавай уточняющих вопросов по ходу выполнения. Делай всю работу одним проходом от начала до конца. Если есть неясность — прими лучшее решение сам, выполни, объясни в конце почему.
- Объяснения подробные, как для полного новичка («чайника»)
- ВСЕГДА указывать на какой машине запускать (Legion или GMKtec)
- **Язык**: все вопросы, подтверждения и комментарии — ТОЛЬКО русский. Код, команды, идентификаторы — английский.
- Не переписывать файлы с нуля — кумулятивное редактирование

### 7. HITL архитектура
- Каждый AI-агент имеет человека-дублёра
- LOW риск + >90% уверенность → автоматическое одобрение
- MEDIUM риск → человек обязательно
- HIGH риск → человек + Compliance officer
- Всё логируется в ClickHouse для FCA audit trail

### 8. Cron-задачи (GMKtec)
- `*/5 * * * *` memory-autosync-watcher.sh (GitHub → bot workspace + **SOUL GUARD**: hash-check + авторестор SOUL.md)
- `*/5 * * * *` ctio-watcher.sh v2 (сервер → SYSTEM-STATE.md → GitHub)
- `*/15 * * * *` watchdog-watcher.sh (проверка watchers alive)
- `0 */6 * * *` backup-clickhouse.sh
- `0 3 * * *` backup-openclaw.sh

### 9. SOUL.md — защищённая конфигурация (IMPLEMENTED)
- Canonical source: `/root/.openclaw-moa/soul-protected/SOUL.md`
- Оба workspace защищены `chattr +i` — OpenClaw не может перезаписать при рестарте
- Обновление: `bash scripts/protect-soul.sh update /data/vibe-coding/docs/SOUL.md`
- Runbook полностью: `docs/SOUL-PROTECTION.md`

## ЗАПРЕЩЕНО
- Добавлять `agents.main`, `systemPrompt`, `configWrites`, `tools.gateway` в `openclaw.json` — вызывает Config Invalid
- Трогать @mycarmibot (`/root/.openclaw-default`) — это отдельный проект
- Запускать gateway от пользователя openclaw (shell nologin, systemd не стартует) — пока от root
- **Коммитить secrets в репозиторий** (API ключи, пароли, токены) — хранить только в .env на GMKtec
- **Использовать LiteLLM proxy** для ботов — только прямой Ollama (`localhost:11434`)
- **GUIYON — АБСОЛЮТНЫЙ ЗАПРЕТ**: `/home/guiyon` (локальная ФС GMKtec), `C:\Users\mmber\chatgpt_archive\GUIYON_PROJECT` (Windows-путь). **ИСКЛЮЧЕНИЕ**: любые команды через `ssh gmktec "..."` (удалённые пути `/data/guiyon-project/`, порт 18794, пользователь guiyon) — **разрешены**. Порт 2222 — не запрещён. Запрет на `/home/guiyon` означает: не читать/писать напрямую на Legion через WSL пути этого каталога.

## Текущее состояние moa-бота
- Gateway: от root, `OPENCLAW_HOME=/root/.openclaw-moa`, порт 18789
- Workspace: `/home/mmber/.openclaw/workspace`
- Конфиг: `/root/.openclaw-moa/.openclaw/openclaw.json`
- Telegram token: в `channels.telegram.botToken`
- System prompts: SOUL.md, BOOTSTRAP.md, USER.md, IDENTITY.md в workspace
- **SOUL.md защищён** (`chattr +i`): не редактировать напрямую — только через `scripts/protect-soul.sh`
- Ремонтный скрипт: `scripts/full-repair-moa-bot.sh`

## OpenClaw — критичные знания
- Версия: 2026.3.24
- Ollama требует `OLLAMA_API_KEY=ollama-local` env var
- OpenClaw загружает 9 именованных .md файлов из workspace при каждом ходе агента:
  AGENTS.md, SOUL.md, TOOLS.md, IDENTITY.md, USER.md, HEARTBEAT.md, BOOTSTRAP.md, MEMORY.md, memory.md
  Каждый усекается до 20 000 символов
- НЕ поддерживает: `agents.defaults.systemPrompt`, `agents.defaults.params`, `agents.defaults.tools`, корневые `provider`, `systemPrompt`, `configWrites`

## Следующие задачи (приоритет)
1. Обучение бота от действий Олега (HITL feedback loop → MetaClaw skills)
2. Бот для Олега через @BotFather (порт 18791 уже активен)
3. n8n workflows, API интеграции (ожидаем ответы вендоров)
4. Миграция gateway на пользователя openclaw (нужно сменить shell с nologin на /bin/bash)

## Закрытые задачи (01.04.2026)
- ✅ OpenClaw security hardening — gateway.auth.token, configWrites:false, tools.deny:gateway, mDNS:off, MemoryMax=8G, CPUQuota=200% (выполнено 31.03)
- ✅ Порт 18795 — идентифицирован как несуществующий, запись удалена из CLAUDE.md
- ✅ agentToAgent роутинг — tools.profile:full, agents.defaults.model:qwen3.5:35b, AGENTS.md с routing правилами
- ✅ Санкционная политика — HARD REJECT (10 юрисдикций) + EDD (30+) в AGENTS.md, MEMORY.md, docs/SANCTIONS_POLICY.md
- ✅ Верификационное окружение — Semgrep (8 правил) + Snyk + pre-commit + CodeQL + check-tools-integrity.sh (01.04)
