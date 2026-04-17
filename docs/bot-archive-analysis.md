# Анализ архива Telegram-бота MyCarmi MoA
> Полный анализ переписки между Mark Fr. (Moriel Carmi) и ботом MyCarmi MoA на платформе OpenClaw  
> Период: 04.03.2026 — 20.03.2026  
> Всего строк в архиве: 18 675

---

## 1. АРХИТЕКТУРА СИСТЕМЫ

### Железо

#### Lenovo Legion Pro 5 16IRX9 (основная рабочая машина)
- **Процессор:** Intel i7-14700HX, 28 потоков
- **RAM:** 16 GB
- **GPU:** NVIDIA (не проброшен в WSL2)
- **Диск:** 1 TB SSD (917 GB свободно)
- **ОС:** Windows + WSL2 Ubuntu 24.04
- **Пользователь WSL2:** `mmber`
- **Роль:** Управляющая машина (HUB/Monitor), Telegram-клиент, Legion Gateway
- **Хостнейм:** `mark-legion`
- **IP:** localhost / 192.168.137.1 (gateway для WSL2)

#### GMKtec NucBox EVO-X2 (AI-сервер)
- **Процессор:** AMD Ryzen AI MAX+ 395 — 16C/32T, до 5.1GHz, 80MB cache
- **RAM:** 128 GB LPDDR5X-8000 (unified memory)
- **GPU:** AMD Radeon 8060S (RDNA 3.5, 40 CU) — 96 GB VRAM (настроено через BIOS)
- **NPU:** XDNA 2, 126 TOPS
- **Диск 1:** YMTC 2 TB NVMe
- **Диск 2:** Crucial 1 TB NVMe (добавлен)
- **Суммарное хранилище:** 2.8 TB
- **ОС:** Windows 11 + WSL2 Ubuntu 24.04
- **Пользователь Windows:** `GMK tec` (пароль: `2313`)
- **Пользователь WSL2:** `mmber` (пароль: `mmber2026`)
- **IP (локальная сеть):** 192.168.137.2 (через ICS) / 192.168.0.117 (реальный)
- **IP WSL2:** динамический (172.28.216.216 на момент настройки)
- **Роль:** AI Compute Brain — Ollama, ClickHouse, OpenClaw (планируется перенести)

#### Сетевая топология
```
Internet
    ↓
Legion (DMZ / API Proxy) — 192.168.137.1
    ↓ (SSH tunnel / LiteLLM)
GMKtec (Core Server) — 192.168.137.2
    ├── Ollama (port 11434)
    └── ClickHouse (port 9000 / 8123, WSL2)
```

---

### Программное обеспечение

#### OpenClaw
- **Версия установленная:** 2026.3.2 → 2026.3.13 (обновление)
- **Платформа:** Node.js, запускается в WSL2 на Legion
- **Профили:**
  - `default` → `.openclaw` (порт 18789) — оригинальный профиль с Banxe проектом
  - `moa` → `.openclaw-moa` (порт 18790) — основной рабочий профиль
- **Сервисы systemd:**
  - `openclaw-gateway.service` (default)
  - `openclaw-gateway-moa.service` (moa)
- **Конфиг:** `~/.openclaw-moa/openclaw.json`
- **Workspace:** `/home/mmber/.openclaw/workspace-moa`

#### LiteLLM (прокси-роутер)
- **Версия:** 1.82.0
- **Установка:** через `pipx`
- **Порт:** 8080
- **Конфиг:** `~/litellm-config.yaml`
- **Сервис:** `~/.config/systemd/user/litellm.service`
- **Функция:** единый OpenAI-совместимый эндпоинт, маршрутизирует к разным моделям

#### Ollama (локальные модели)
- **Версия:** 0.18.0 → 0.18.1
- **Хост:** GMKtec EVO-X2 (Windows)
- **Порт:** 11434
- **Доступ с Legion:** `http://192.168.137.2:11434`
- **Настройка keep-alive:** `OLLAMA_KEEP_ALIVE=5m` (через Windows env variable)

#### ClickHouse (база данных)
- **Версия:** 26.3.1.837
- **Установка:** нативная (без Docker, из-за проблем с GPG key в WSL2)
- **Хост:** GMKtec WSL2
- **Порты:** 9000 (native), 8123 (HTTP)
- **База:** `banxe`
- **Доступ:** через SSH tunnel (`ssh gmk-wsl 'clickhouse-client ...'`)

#### SSH конфигурация (Legion → GMKtec)
- **Windows SSH:** `ssh -i ~/.ssh/gmktec_key "GMK tec@192.168.0.117"` ✅
- **WSL2 SSH:** `ssh -i ~/.ssh/gmktec_key -p 2222 mmber@192.168.0.117` ✅ (нестабильно)
- **Port forwarding:** Windows:2222 → WSL2:2222
- **Алиасы в `.bashrc`:** `gmk-wsl`, `gmk-win`
- **SSH ключ Legion:** `~/.ssh/gmktec_key` (ED25519, создан `mmber@mark-legion`)

---

### Текущая рабочая конфигурация vs сломанные состояния

| Компонент | Рабочее состояние | Сломанные состояния |
|-----------|-------------------|---------------------|
| OpenClaw Gateway (moa) | PID 16746, port 18790 | 8 крашей 1 марта из-за `context window too small (4096)` |
| LiteLLM | PID 308/9658, port 8080 | Ключи теряются при перезапуске без env vars; порт 8080 занят старым процессом |
| Ollama (GMKtec) | 4 модели, 101 GB | Llama 70B не грузилась пока не обновили BIOS (iGPU=96GB) и AMD драйвер |
| ClickHouse | Запущен в WSL2 GMKtec | Не слушает сетевой интерфейс (только localhost); HTTP порт 8123 закрыт снаружи |
| SSH к GMKtec WSL2 | Порт 2222, ключ работает | Пароль `2313` не работал (нужен был `mmber2026`); SSH на порту 22 не слушал |
| Telegram бот | @mycarmi_moa_bot | Конфликт двух instance (20.03.2026 12:26–12:41) |

---

## 2. API КЛЮЧИ И ПРОВАЙДЕРЫ

### Anthropic (Claude)
- **API Ключ:** `sk-ant-***MASKED***`
- **Тип:** `oat01` = Organization API Token
- **Статус:** Рабочий (работал на протяжении всего архива)
- **Источник:** Найден в `~/.openclaw/agents/main/agent/auth-profiles.json` (принадлежит аккаунту Moriel Carmi)
- **Модели:** claude-opus-4-6, claude-sonnet-4-5, claude-sonnet-4-6
- **Хранение:** `~/.banxe-secrets` (с chmod 600), LiteLLM config через `os.environ/ANTHROPIC_API_KEY`

### Google (Gemini)
- **API Ключ:** `AIza***MASKED***`
- **Статус:** ⚠️ Бесплатный tier исчерпан (9 марта 2026 — `limit: 0`)
- **Модели:** gemini-2.0-flash
- **Решение:** Заменён на Groq Llama 4 Maverick

### Groq
- **API Ключ:** `gsk_***MASKED***`
- **Статус:** ✅ Рабочий, бесплатный tier
- **Модели:** llama-3.3-70b-versatile, kimi-k2 (moonshotai), llama-4-scout-17b-16e, llama-4-maverick-17b-128e
- **Лимит:** Rate limit при одновременных запросах (5+ агентов)
- **Ограничение:** Max 5 sub-agents одновременно (hardcoded в OpenClaw)

### Ollama (локальные модели на GMKtec)
- **Статус:** ✅ Рабочий, бесплатный
- **Endpoint:** `http://192.168.137.2:11434`
- **Модели установленные:**
  - `Llama 3.3 70B` (39.6 GB, Q4_K_M) — 9.5–47 tok/s
  - `Qwen 3.5 35B abliterated` (22.2 GB, Q4_K_M) — 37 tok/s
  - `GLM-4.7-Flash abliterated` (17.5 GB, Q4_K_M) — быстрый
  - `GPT-OSS 20B derestricted` (14.7 GB, Q4_K_M)
- **Суммарно:** 101.6 GB

### Подписки (не дают API доступа)
| Сервис | Цена/мес | API | Вывод |
|--------|----------|-----|-------|
| Claude Max | $200 | ❌ Отдельно | API не входит в подписку |
| ChatGPT Pro | неизвестно | ❌ Отдельно | API не входит в подписку |
| Perplexity Max | $200 | ❌ Отдельно | API не входит в подписку (подтверждено официально) |
| Gemini Pro | неизвестно | ⚠️ Отдельно (Google AI Studio) | — |
| KIMI | неизвестно | ✅ Доступен через Groq бесплатно | — |

### Лимиты бесплатных уровней
- **Groq:** Rate limit при одновременных запросах; Kimi K2 часто возвращает пустые ответы
- **Gemini Free:** Квота исчерпывается при нагрузочном тестировании
- **Ollama:** Без лимитов, но ограничен контекстом (8k для Llama 70B при 96GB GPU — проблема KV-cache)

---

## 3. ХРОНОЛОГИЯ ЗАДАЧ

### 04.03.2026 — День 1
- **10:45** — Первое сообщение. Обсуждение идеи оркестрации ИИ
- **11:49** — Обновление OpenClaw (`npm install -g openclaw`), версия 2026.3.2
- **11:50** — `openclaw gateway install --force` — синхронизация токена
- **12:04** — Установка LiteLLM через pipx (версия 1.82.0)
- **12:12** — Запуск LiteLLM с Claude + Gemini, **СТАТУС: ✅ выполнено**
- **12:28** — Добавление Groq (ключ `gsk_...`), 5 моделей в прокси
- **12:54** — Обсуждение GMKtec EVO-X2 и модели Huihui-Qwen3.5-35B-abliterated
- **13:05** — **Задача: BANXE AI Bank** — начало проектирования AI-банка
- **13:05–17:56** — Проектирование архитектуры, создание 6 агентов-сотрудников, Orchestration Engine, HITL Dashboard

**Ключевые решения дня:**
- Подписки не дают API доступа — нужны отдельные ключи
- Groq — лучший бесплатный вариант
- HITL (Human-in-the-Loop) как обязательная часть архитектуры
- Claude для Compliance (нельзя Kimi K2 — китайская юрисдикция, риск GDPR/FCA)

---

### 04.03.2026 вечер — BANXE MoA тест (ошибки)
- **18:01–20:39** — Попытка запустить MoA ревизию проекта с 4 моделями параллельно
- **Проблема:** MoA агент теряет ключи (`No API key found for provider "anthropic"`) из-за другого auth store в `~/.openclaw-moa-home`
- **20:39** — Частичный результат ревизии: 21 критический пункт (C1–C6, I1–I9, N1–N6)
- **Статус:** ⚠️ Частично — ревизия выполнена, но с ошибками

---

### 04.03.2026 — MoA ревизия — критические находки
- **C1:** Kimi K2 нарушает UK GDPR (китайская юрисдикция) → заменён на Claude Sonnet
- **C2:** `~/.banxe-secrets` не подходит для продакшена → нужен Vault
- **C3:** Нет персистентной БД и audit log (FCA требует 5 лет) → создана схема PostgreSQL
- **C4:** Нет DPIA
- **C5:** Нет mTLS между агентами
- **C6:** Нет FCA SS1/23 Model Risk Framework
- **Статус:** ✅ C1 и C3 выполнены; C2, C4, C5, C6 — незавершены

---

### 09.03.2026 — Восстановление системы
- **14:16** — Марк пишет "привет" после 5 дней тишины
- **Проблема:** Gateway был остановлен после крашей 1 марта
- **14:18** — Gateway перезапущен как systemd-сервис
- **Обнаружено:** 5 профилей OpenClaw (`.openclaw`, `.openclaw-moa`, `.openclaw-new`, `.openclaw-dev`, `.openclaw-moa-home`)
- **18:16–19:12** — Конфигурация профилей, удаление лишних, перенос ключей
- **19:06** — Созданы 7 агентов в moa профиле (Main, Supervisor, Operations, Compliance, KYC, FX, Analytics)
- **Статус:** ✅ Выполнено

---

### 09.03.2026 — Совет Моделей (первый тест)
- **18:55** — Mark предлагает "Совет Моделей" — все запросы обрабатываются всеми AI одновременно
- **Проблема 1:** Gemini — квота исчерпана (0 лимит)
- **Проблема 2:** Kimi K2 — rate limit
- **Проблема 3:** Sub-agent лимит 5 (hardcoded в OpenClaw)
- **Проблема 4:** Telegram conflict — два профиля используют один бот-токен
- **Результат:** 3 из 5 моделей работают (Claude Sonnet 4.5, Llama 3.3 70B, Llama 4 Scout)
- **Статус:** ⚠️ Частично

---

### 10.03.2026 — Архитектурное решение 2 слоев
- Марк принимает архитектуру: **Слой 1** = CTIO (стратегия с Марком) + **Слой 2** = агенты-сотрудники
- **CTIO = бот** (Claude Opus), Марк = CEO/Owner
- Принята конфигурация со сценариями и внутренними связями

---

### 14.03.2026 — GMKtec подключение и миграция
- **13:03** — Обнаружено: GMKtec уже имеет Ollama (порт 11434) с Qwen 3.5 35B (47 tok/s!)
- **13:08** — Установка SSH на GMKtec Windows
- **13:47** — SSH настроен, ключ добавлен
- **13:50** — Обнаружены характеристики GMKtec: 128GB RAM, 96GB GPU (unified memory)
- **14:02–14:12** — Обсуждение лучших моделей для загрузки
- **14:35** — Рекомендации Perplexity по "Совету моделей" (5 моделей)
- **16:14** — BIOS настройка iGPU=96GB (перезагрузка)
- **15:03.2026 15:01** — После обновления AMD драйвера 26.2.2: Ollama видит 96GB VRAM
- **Статус:** ✅ GMKtec полностью настроен

---

### 15.03.2026 — Полный перенос на GMKtec
- **09:00** — WSL2 установлен на GMKtec (Ubuntu 24.04)
- **15:30** — OpenClaw 2026.3.13 установлен на GMKtec WSL2
- **15:30–15:55** — Загрузка 4 моделей на GMKtec:
  - GLM-4.7-Flash (18.8 GB)
  - GPT-OSS 20B (15.8 GB)
  - Llama 3.3 70B (42.5 GB)
  - Qwen 3.5 35B (уже был)
- **15:54–16:00** — Создание 10 агентов Banxe (финальная структура)
- **16:00–16:32** — Настройка HITL Dashboard, автозапуск всех сервисов
- **0:32 (16 марта)** — Telegram бот восстановлен (ID 508602494 добавлен в whitelist)
- **Статус:** ✅ Полностью

---

### 16.03.2026 — Тестирование workflows
- **0:34** — Тест трёх агентов параллельно
- **0:40** — Определён Workflow 01: Client Onboarding
- **0:43–1:08** — End-to-end тест: Alice Johnson (CL-001) + John Smith (CL-002)
- **1:08** — Оба клиента онбордированы:
  - Alice: ACTIVE (21 мин), лимиты £5k/£20k
  - John: ACTIVE_WITH_CONDITIONS (24 мин), EDD deadline 15 апреля
- **1:15** — Workflow 02: Outbound Payment создан
- **1:17–1:25** — 5 payment сценариев протестированы
- **2:00–2:12** — Полный анализ проекта: 30% готово, 70% критичных интеграций впереди
- **Статус:** ✅ Выполнено

---

### 17.03.2026 — Оптимизация производительности
- Создан `fast_checks.py` (IBAN validation, balance check, limits) — 1400-5000x быстрее sub-agents
- Operations агент переключён с Llama 70B на GLM-4.7-Flash (2-3x быстрее)
- SSH к GMKtec WSL2 настроен через port forwarding (порт 2222)
- **Статус:** ✅ Выполнено

---

### 19.03.2026 — Инфраструктура и безопасность
- **07:16** — Аудит AutoResearchClaw и MetaClaw (решено не устанавливать сейчас)
- **08:51–09:43** — Karpathy Loop patterns: eval suite, PROGRAM.md, git baseline
- **09:01–09:27** — ClickHouse установлен нативно (без Docker)
  - База: `banxe`, 6 таблиц, 3 views, 1 materialized view
  - Тестовые данные: 7 транзакций, 2 AML алерта, 9 KYC событий
  - Crontab: 3x в день (9:00, 15:00, 21:00)
- **13:53** — **Задача: Иерархическая Memory** — архитектура с ACL
- **14:42** — **БОЕВОЙ РЕЖИМ:** deploy hierarchical memory
  - 5 пользователей ClickHouse созданы
  - 6 новых таблиц: `shared_memory_*`, `agent_escalations`
  - Тест изоляции пройден (compliance blocked from management ✅)
- **15:06–15:15** — Тест escalation workflow, populate shared memory (36 строк)
- **17:52** — Диагностика: все 4 модели работают, LiteLLM работает
- **18:37** — Mark описывает target архитектуру: GMKtec = brain, Legion = monitor
- **18:39–18:44** — Попытка миграции Gateway на GMKtec (SSH tunnel)
- **20:17–20:24** — **Аудит безопасности:** Score 2/10 — критические уязвимости
- **Статус:** ⚠️ Частично (ClickHouse, иерархическая память — готово; миграция Gateway — незавершена)

---

### 20.03.2026 (последний день в архиве)
- **14:31** — Статус системы: Legion Gateway работает, GMKtec Gateway не работает
- **17:20** — Последнее сообщение: "Ты в доступе?"
- Миграция не завершена, система работает в режиме Legion HUB

---

## 4. MEMORY БОТА

### Файлы памяти (OpenClaw workspace-moa)

**`MEMORY.md`** — основной файл долгосрочной памяти:
- Кто такой Марк: Moriel Carmi, CEO & Founder, Banxe UK Ltd
- Проект: AI-powered EMI bank на платформе Banxe
- Архитектура: GMKtec = Brain, Legion = HUB/Monitor
- SSH конфигурация, пароли, IP-адреса
- Roadmap Q1 2026
- Известные баги и TODO
- ⚠️ MEMORY.md превысил лимит 20,000 символов (23,137 символов на 19.03.2026)

**`memory/2026-03-04.md`** — детальный лог первого дня

**`memory/2026-03-19.md`** — лог сессии 19.03.2026 (8.6KB)

**`NEXT-SESSION.md`** — quick start для следующей сессии

**`PROGRAM.md`** — цели оптимизации (Karpathy Loop):
```
Goal: Minimize response time for payment validation workflows
Current baseline: 41 seconds (Alice £500 UK transfer)
Success metric:
- fast_checks.py benchmark: IBAN + limits + balance < 2 seconds
- Full payment scenario: < 20 seconds
```

### MetaClaw Skills (Personal Memory)
Файлы в `~/.metaclaw/skills/`:
1. `iban_validation_uk.json`
2. `balance_check_fast.json`
3. `sanctions_auto_block_iran.json`
4. `structuring_pattern_detection.json`
5. `edd_required_triggers.json`
6. `index.json`

Структура по ролям (создана 19.03.2026):
```
~/.metaclaw/skills/
├── ceo/
├── ctio/
├── compliance/
├── kyc/
├── payments/
├── analytics/
└── shared/
```

### Ключевые записи в памяти (факты о пользователе)
- **Имя:** Moriel Carmi (Mark Fr. в Telegram)
- **Роль:** CEO & Founder, CTIO
- **Email:** moriel@banxe.com
- **Telegram ID:** 508602494
- **Telegram:** @bereg2022
- **Проект:** Banxe UK Ltd (EMI, FCA authorised)
- **Местоположение:** Франция (timezone Europe/Paris)
- **Контакты вендоров:** sales@dowjones.com, sales@lexisnexis.com, sales@sumsub.com

---

## 5. ПРОБЛЕМЫ И РЕШЕНИЯ

### P1: OpenClaw — ошибка модуля `tool-loop-detection`
- **Когда:** 04.03.2026 10:45
- **Симптом:** Все инструменты выдают ошибку, бот не может пользоваться браузером и файлами
- **Решение:** `npm install -g openclaw` + `openclaw gateway install --force`
- **Результат:** ✅ Исправлено

### P2: YAML конфигурация LiteLLM теряет отступы при копировании через Telegram
- **Когда:** 04.03.2026 12:11
- **Симптом:** `yaml.parser.ParserError: expected <block end>, but found '-'`
- **Решение:** Бот записывает файл напрямую через инструменты, не через Telegram copy-paste
- **Результат:** ✅ Исправлено

### P3: Port 8080 занят старым процессом LiteLLM
- **Когда:** 04.03.2026 12:30
- **Симптом:** `ERROR: [Errno 98] address already in use`
- **Решение:** `fuser -k 8080/tcp && systemctl --user restart litellm`
- **Результат:** ✅ Исправлено

### P4: LiteLLM теряет API ключи при перезапуске
- **Когда:** 04.03.2026 18:12
- **Симптом:** Модели возвращают ошибку авторизации после рестарта сервиса
- **Причина:** LiteLLM стартует как отдельный процесс и не видит env vars из shell
- **Решение:** `environment_variables` в конфиге самого LiteLLM (не через export)
- **Результат:** ✅ Исправлено

### P5: 8 крашей OpenClaw 1 марта — `context window too small (4096)`
- **Когда:** 01.03.2026
- **Симптом:** Бот постоянно перезапускается, теряет память
- **Причина:** Неправильно настроенная модель с маленьким контекстом
- **Результат:** ❌ Данные потеряны (workspace был чистым)
- **Урок:** Перед рестартом обязательно сохранять память в файлы

### P6: Два профиля OpenClaw — путаница с агентами
- **Когда:** 09.03.2026
- **Симптом:** Агенты Banxe не видны, `agents: (none)`
- **Причина:** Работа в профиле `moa` вместо `default` где создавались агенты
- **Решение:** Обнаружен `default` профиль, перенос файлов, настройка правильного профиля
- **Результат:** ✅ Исправлено

### P7: Gateway moa использует порт 18789 вместо 18790
- **Когда:** 09.03.2026 18:41
- **Симптом:** Dashboard недоступен (`ERR_CONNECTION_REFUSED`)
- **Причина:** Конфиг указывает 18790, но systemd service запускает на 18789
- **Решение:** Согласование конфига и сервиса
- **Результат:** ✅ Исправлено

### P8: Gemini квота исчерпана
- **Когда:** 09.03.2026 19:09
- **Симптом:** `limit: 0` — Gemini возвращает пустые ответы
- **Решение:** Замена на Groq Llama 4 Maverick
- **Результат:** ✅ Исправлено

### P9: Llama 70B не грузится в GPU (только 4GB VRAM)
- **Когда:** 15.03.2026 10:02
- **Симптом:** `cudaMalloc failed: out of memory` или `exit status 2`
- **Причина:** BIOS настроен на Auto (4-8GB для iGPU), нужно 96GB
- **Решение:** BIOS → GFX Configuration → UMA_SPECIFIED → 96GB + AMD драйвер 26.2.2
- **Результат:** ✅ Исправлено (Llama 70B работает при ctx=8192)

### P10: WSL2 зависает при запуске (96GB под GPU)
- **Когда:** 15.03.2026 15:26
- **Симптом:** `wsl -l -v` зависает, WSL не запускается
- **Причина:** 96GB под GPU оставляет мало RAM для Hyper-V/WSL2
- **Решение:** `.wslconfig` с `memory=20GB swap=8GB processors=12`
- **Результат:** ✅ Исправлено

### P11: DNS не работает в GMKtec WSL2
- **Когда:** 19.03.2026 09:19
- **Симптом:** `apt update` не может разрешить адреса
- **Решение:** Прописать DNS вручную в `/etc/resolv.conf`
- **Результат:** ✅ Исправлено

### P12: Docker GPG ключ не импортируется в WSL2
- **Когда:** 19.03.2026 09:19
- **Симптом:** Установка Docker зависает/не работает
- **Решение:** Установить ClickHouse нативно (без Docker)
- **Результат:** ✅ ClickHouse установлен нативно

### P13: SSH к GMKtec WSL2 нестабилен
- **Когда:** 19.03.2026
- **Симптом:** Connection reset, SSH работает только через port forwarding (Windows:2222 → WSL2:2222)
- **Причина:** Сложная конфигурация NAT/WSL2
- **Решение:** Port forwarding через Windows + SSH ключ (`mmber2026` пароль)
- **Статус:** ⚠️ Нестабильно

### P14: agent_escalations — нельзя UPDATE status (в ORDER BY ключе)
- **Когда:** 19.03.2026 15:07
- **Симптом:** Нельзя обновить статус эскалации через UPDATE
- **Обходное решение:** Создание новой записи с суффиксом `-RESOLVED`
- **Долгосрочный fix:** Использовать ReplacingMergeTree или убрать `status` из ORDER BY
- **Статус:** ⚠️ Обходное решение

### P15: Telegram конфликт двух instance
- **Когда:** 20.03.2026 12:26–12:41
- **Причина:** Legion Gateway и GMKtec Gateway используют один бот-токен
- **Решение:** Остановить один из instance
- **Статус:** ⚠️ Решается вручную при каждом тесте

### P16: ClickHouse недоступен с Legion (порты 8123/9000)
- **Когда:** 19-20.03.2026
- **Причина:** ClickHouse слушает только localhost в WSL2; WSL2 IP динамический
- **Решение:** Все запросы через SSH: `ssh gmk-wsl 'clickhouse-client --query "..."'`
- **Статус:** ✅ Рабочее решение (но неудобное)

---

## 6. ОРКЕСТРАЦИЯ / MoA

### Описание архитектуры

**"Совет Моделей"** (Mixture of Agents):
- Mark → Telegram → OpenClaw Gateway (Legion) → Main Agent (Claude Opus) → параллельно 6-9 sub-agents → синтез → ответ

**Механизм:** OpenClaw `sessions_spawn()` с параллельным запуском sub-agents

### Финальная структура агентов (10 агентов)

| # | Агент | Модель | Где | Роль |
|---|-------|--------|-----|------|
| 1 | 🧠 CTIO (Main) | Claude Opus 4 | ☁️ API | Стратегия, работа с Марком |
| 2 | 🏦 Supervisor | Claude Sonnet 4.5 | ☁️ API | Оркестрация, маршрутизация |
| 3 | 📋 KYC/KYB | Claude Sonnet 4.5 | ☁️ API | Onboarding, SumSub, санкции |
| 4 | 💬 Client Service | GLM-4.7-Flash | 🏠 GMKtec | 24/7 поддержка, FAQ, FX |
| 5 | 🛡️ Compliance | Claude Sonnet 4.5 | ☁️ API | AML, SAR, FCA |
| 6 | ⚡ Operations | Llama 3.3 70B | 🏠 GMKtec | Reconciliation, OCR, SWIFT |
| 7 | 🪙 Crypto | Qwen 3.5 35B | 🏠 GMKtec | On-chain, DeFi, wallets |
| 8 | 📊 Analytics | GPT-OSS 20B | 🏠 GMKtec | OLAP, ClickHouse, CEO chat |
| 9 | ⚠️ Risk Manager | Llama 3.3 70B | 🏠 GMKtec | Скоринг, фрод, лимиты |
| 10 | 🔧 IT/DevOps | GLM-4.7-Flash | 🏠 GMKtec | Инфра, CI/CD, мониторинг |

### LiteLLM алиасы для агентов Banxe
```yaml
banxe/supervisor   → anthropic/claude-sonnet-4-6
banxe/compliance   → anthropic/claude-sonnet-4-6  # (было Kimi K2 → заменено)
banxe/kyc          → groq/llama-4-scout-17b
banxe/operations   → groq/llama-3.3-70b
banxe/fx           → gemini/gemini-2.0-flash
```

### Реализованные компоненты

**Слой 1 (CTIO/CEO):**
- Main Agent (Claude Opus) — стратегия, работа с Марком напрямую
- Все ключевые решения, эскалации от Слоя 2

**Слой 2 (Операционный банк):**
- Supervisor → оркестрация потоков
- 9 специализированных агентов
- Автономное взаимодействие между агентами + эскалация через Supervisor

**Файлы:**
- `agents/supervisor.md`, `agents/operations.md`, `agents/compliance.md`, etc.
- `orchestrator.py` — Python-сервис оркестрации
- `banxe-dashboard.service` — HITL Dashboard (порт 8090)

### Что реализовано vs что запланировано

| Компонент | Статус | Примечание |
|-----------|--------|------------|
| 6 системных промптов агентов | ✅ Реализовано | |
| LiteLLM routing (8 моделей) | ✅ Реализовано | |
| Orchestration Engine (Python) | ✅ Реализовано | |
| HITL Dashboard (Web) | ✅ Реализовано | порт 8090 |
| PII Anonymizer | ✅ Реализовано | |
| Document Sanitizer (prompt injection) | ✅ Реализовано | |
| Database + Audit Log | ✅ Реализовано | ClickHouse |
| Structured JSON schemas (Pydantic) | ✅ Реализовано | |
| BANXE API интеграция | 🔜 Запланировано | Geniusto |
| Analytics Agent (EVO-X2) | ✅ Реализовано | Qwen 35B |
| Karpathy Loop (авт. оптимизация) | ✅ POC | Не полный цикл |
| MetaClaw daemon | ⚠️ Частично | Установлен, не запущен |

---

## 7. НЕЗАВЕРШЁННЫЕ ЗАДАЧИ

### Критические (блокируют production)

1. **PII Proxy** (неделя 3-4 roadmap)
   - Угроза: €20M штраф при нарушении GDPR/FCA
   - Технология: Presidio + tokenizer + audit trail
   - Статус: ❌ Не начато

2. **BANXE API интеграции** (неделя 5-6)
   - Geniusto (core banking, SEPA/SWIFT)
   - SumSub (KYC)
   - Dow Jones / LexisNexis (AML, sanctions)
   - Статус: ❌ Sandbox credentials запрошены через email (drafts готовы)

3. **Миграция OpenClaw/LiteLLM на GMKtec**
   - Gateway остался на Legion — данные проходят через laptop
   - FCA риск: клиентские данные не изолированы
   - Статус: ⚠️ Начата, не завершена

4. **Backup ClickHouse данных**
   - При потере GMKtec → потеря ВСЕХ клиентских данных
   - Статус: ❌ Нет автоматического backup

5. **Шифрование данных at rest**
   - SQLite на Legion — plain text
   - ClickHouse — статус неизвестен
   - Статус: ❌ GDPR Art. 32 нарушение

### Важные (неделя 7-8)

6. **n8n автоматизация**
   - Document flow, KYC renewal, reconciliation, SumSub
   - Статус: ❌ Не начато

7. **HITL interface** (Jira/Notion)
   - Интерфейс для живых дублёров
   - Статус: ❌ Только web dashboard на localhost

8. **MetaClaw daemon**
   - Установлен, но interactive wizard не пройден
   - Нужно: `metaclaw setup` + `metaclaw start --mode skills_only --daemon`
   - Статус: ⚠️ 50%

9. **Observability** (Lunari.ai)
   - Мониторинг агентов, datasets, evaluations
   - Статус: ❌ Не начато

### Желательные

10. **Второй GMKtec (hot standby)**
    - Стоимость: ~£1000-1500
    - Защита от SPOF

11. **Odoo CRM**
    - 360° view клиентов
    - Статус: ❌ Не начато

12. **ClickHouse Data Lake**
    - Полный analytics
    - Статус: ✅ Начато (базовая схема готова)

13. **Telegram боты-сотрудники**
    - @banxe_compliance_bot — Compliance Officer (AML/SAR only)
    - @banxe_payments_bot — Payment Operations (SEPA/SWIFT only)
    - @banxe_kyc_bot — KYC Analyst (SumSub/Dow Jones only)
    - Статус: ❌ Зарегистрированы в планах, не созданы

14. **Отправить vendor emails**
    - Dow Jones: sales@dowjones.com
    - LexisNexis: sales@lexisnexis.com
    - SumSub: sales@sumsub.com
    - Email drafts готовы в `docs/email-*.md`
    - Нужно заполнить: телефон (+33 6 XX XX XX XX) и UK registered office address

15. **mTLS между агентами**
    - C5 из MoA ревизии
    - Статус: ❌

16. **FCA SS1/23 Model Risk Framework**
    - C6 из MoA ревизии
    - Статус: ❌

### Особые задачи (будущее железо)

17. **Huihui-Qwen3.5-35B-A3B-abliterated на EVO-X2**
    - Модель уже установлена (Qwen 3.5 35B abliterated)
    - Analytics Agent = on-premise приватная обработка PII
    - Статус: ✅ Реализовано (другая квантизация)

---

## 8. ЦЕННЫЕ КОНФИГУРАЦИИ

### litellm-config.yaml (финальная рабочая версия)
```yaml
model_list:
  - model_name: anthropic/claude-sonnet-4-6
    litellm_params:
      model: claude-sonnet-4-6
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: gemini/gemini-2.0-flash
    litellm_params:
      model: gemini/gemini-2.0-flash
      api_key: os.environ/GOOGLE_API_KEY

  - model_name: groq/llama-3.3-70b
    litellm_params:
      model: groq/llama-3.3-70b-versatile
      api_key: os.environ/GROQ_API_KEY

  - model_name: groq/llama-4-scout
    litellm_params:
      model: groq/meta-llama/llama-4-scout-17b-16e-instruct
      api_key: os.environ/GROQ_API_KEY

  - model_name: ollama/llama3.3-70b
    litellm_params:
      model: ollama/llama3.3:70b
      api_base: http://192.168.137.2:11434

  - model_name: ollama/qwen3.5-35b
    litellm_params:
      model: ollama/huihui_ai/qwen3.5-abliterated:35b
      api_base: http://192.168.137.2:11434

  - model_name: ollama/glm-flash
    litellm_params:
      model: ollama/huihui_ai/glm-4.7-flash-abliterated
      api_base: http://192.168.137.2:11434

  - model_name: ollama/gpt-oss-20b
    litellm_params:
      model: ollama/gurubot/gpt-oss-derestricted:20b
      api_base: http://192.168.137.2:11434

  # Banxe aliases
  - model_name: banxe/supervisor
    litellm_params:
      model: anthropic/claude-sonnet-4-6
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: banxe/compliance
    litellm_params:
      model: anthropic/claude-sonnet-4-6
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: banxe/kyc
    litellm_params:
      model: groq/meta-llama/llama-4-scout-17b-16e-instruct
      api_key: os.environ/GROQ_API_KEY

  - model_name: banxe/operations
    litellm_params:
      model: groq/llama-3.3-70b-versatile
      api_key: os.environ/GROQ_API_KEY

  - model_name: banxe/fx
    litellm_params:
      model: gemini/gemini-2.0-flash
      api_key: os.environ/GOOGLE_API_KEY

general_settings:
  master_key: SANITIZED_LOCAL_KEY

litellm_settings:
  drop_params: true
```

### ~/.banxe-secrets (шаблон)
```bash
export ANTHROPIC_API_KEY="sk-ant-oat01-..."
export GOOGLE_API_KEY="AIza..."
export GROQ_API_KEY="gsk_..."
```
Права: `chmod 600 ~/.banxe-secrets`

### .wslconfig (Legion) — оптимальная конфигурация
```ini
[wsl2]
memory=20GB
swap=8GB
processors=12
```

### Ollama systemd service для GMKtec WSL2
```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_KEEP_ALIVE=5m"
```

### /etc/wsl.conf (GMKtec) — автозапуск SSH
```ini
[boot]
command = "service ssh start"
```

### SSH port forwarding (GMKtec Windows → WSL2)
```powershell
netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=2222 connectaddress=172.28.216.216
```

### Алиасы в ~/.bashrc (Legion)
```bash
alias gmk-wsl='ssh -i ~/.ssh/gmktec_key -p 2222 mmber@192.168.0.117'
alias gmk-win='ssh -i ~/.ssh/gmktec_key "GMK tec@192.168.0.117"'
```

### Команды которые работают

**Проверка моделей LiteLLM:**
```bash
curl http://localhost:8080/v1/models -H "Authorization: Bearer SANITIZED_LOCAL_KEY" | python3 -m json.tool
```

**Проверка Ollama на GMKtec:**
```bash
curl http://192.168.137.2:11434/api/tags
```

**ClickHouse через SSH:**
```bash
ssh gmk-wsl 'clickhouse-client --query "SELECT * FROM banxe.v_recent_transactions"'
```

**Перезапуск LiteLLM:**
```bash
systemctl --user restart litellm
```

**Статус всех сервисов:**
```bash
systemctl --user status litellm openclaw-gateway-moa
```

**Освободить порт 8080:**
```bash
fuser -k 8080/tcp
```

### Критические параметры (num_ctx и streaming)

**Проблема KV-cache для Llama 70B:**
- По умолчанию Ollama выделяет 262k context → ~80GB KV-cache → не влезает в 96GB VRAM
- **Решение:** Ограничить контекст до 8192 токенов (веса 39.5GB + KV-cache 2.5GB = 42GB)

**OLLAMA_KEEP_ALIVE:**
- Без этой переменной модели выгружаются после каждого запроса → cold start каждый раз
- **Решение:** `OLLAMA_KEEP_ALIVE=5m` через Windows system env variable

**Vulkan для Ollama (рекомендация Perplexity):**
```powershell
setx OLLAMA_GPU_DRIVER "vulkan" /M
```
Ожидаемый прирост: +14-20% на Strix Halo

### ClickHouse схема (ключевые таблицы)

**База:** `banxe`

**Старые таблицы:**
- `transactions` — финансовые транзакции
- `aml_alerts` — AML события
- `kyc_events` — KYC события
- `accounts` — аккаунты клиентов
- `agent_metrics` — метрики агентов (eval suite)
- `audit_trail` — аудит всех действий

**Новые таблицы (Hierarchical Memory):**
- `shared_memory_public` — общедоступные данные (FCA license, лимиты, правила)
- `shared_memory_management` — стратегия, бюджет (только CEO/CTIO)
- `shared_memory_compliance` — AML паттерны, SAR шаблоны (только Compliance)
- `shared_memory_kyc` — шаблоны документов (только KYC)
- `shared_memory_payments` — SEPA/SWIFT шаблоны (только Payments)
- `agent_escalations` — таблица эскалаций между уровнями

**Пользователи ClickHouse (ACL):**
```
ceo_agent (banxe_ceo_secure_2026) — полный доступ
ctio_agent (banxe_ctio_2026) — management + technical
compliance_agent (banxe_compliance_2026) — AML/KYC + escalations
kyc_agent (banxe_kyc_2026) — KYC + escalations
payments_agent (banxe_payments_2026) — transactions/payments + escalations
```

### fast_checks.py
**Расположение:** `~/.openclaw-moa/functions/fast_checks.py`
**Функции:** `validate_iban`, `check_balance`, `check_limits`
**Производительность:** < 20ms (vs 14-50s для sub-agents) = ускорение 700-5000x

### Git baseline (Karpathy Loop)
**Репозиторий:** `~/.openclaw/workspace-moa` (git init 19.03.2026)
**Коммиты:**
```
ef24954 Hierarchical Memory Deployment final
b71dff6 Escalation workflow test
6ae5dd3 Hierarchical Memory — SQL deployed
b7aef43 Hierarchical Memory Architecture Package
9403002 Session 2026-03-19 final
0b24a5e MetaClaw demo
3b08c72 Karpathy Loop #1
52fe056 Baseline
```

---

## ПРИЛОЖЕНИЕ: Аудит безопасности (19.03.2026)

### Результаты (Security Score: 2/10)

| # | Проблема | Severity | FCA Risk |
|---|----------|----------|----------|
| 1 | Данные на Legion (main.sqlite) | 🔴 CRITICAL | Нарушение data residency |
| 2 | GMKtec имеет интернет (не air-gapped) | 🔴 CRITICAL | Data exfiltration |
| 3 | SSH к GMKtec ненадёжен | 🔴 CRITICAL | Cannot manage server |
| 4 | API запросы с Legion (без PII proxy) | 🔴 CRITICAL | PII в облако |
| 5 | ClickHouse недоступен с Legion | 🔴 CRITICAL | Cannot audit |
| 6 | Нет шифрования at rest | 🟠 HIGH | GDPR Art. 32 |
| 7 | Нет backup GMKtec | 🔴 CRITICAL | Data loss |

### Target архитектура (одобрена Марком)

**"Толстый сервер / тонкий клиент" для AI:**
```
Internet (SumSub, Dow Jones, LexisNexis)
    ↓
Legion (DMZ) — только API proxy, Claude для reasoning, Telegram gateway
    ↓ (SSH tunnel / API, anonymized data only)
GMKtec (Air-gapped Core) — Ollama, OpenClaw Gateway, ClickHouse
    └── Все клиентские данные изолированы
```

**Преимущества:**
- Клиентские данные никогда не покидают GMKtec
- Каждый оператор-дублер подключается через свой PC (как Legion)
- Claude на Legion = reasoning без доступа к raw данным
- FCA готовность: "Air-gapped core"

**Статус миграции:** ⚠️ Не завершена (19-20.03.2026)

---

## ПРИЛОЖЕНИЕ: Roadmap проекта

### 12 недель до production

| Неделя | Приоритет | Задачи | Статус |
|--------|-----------|--------|--------|
| 1–2 | 🔴 | ClickHouse + Odoo CRM | ClickHouse ✅, Odoo ❌ |
| 3–4 | 🔴🔴🔴 | PII Proxy (Presidio + tokenizer + audit) | ❌ |
| 5–6 | 🔴 | Geniusto + SumSub + Dow Jones/LexisNexis | ❌ |
| 7–8 | 🟡 | n8n automation | ❌ |
| 9–10 | 🟡 | HITL (Jira) + Observability (Lunari.ai) | ❌ |
| 11–12 | 🟢 | Security audit + load testing + A/B testing | ❌ |

**Текущий прогресс:** ~30% (AI agents + 2 workflows протестированы)  
**До production:** ~70% (критичные интеграции)

---

*Документ составлен автоматически на основе 18 675 строк переписки*  
*Дата архива: 04.03.2026 – 20.03.2026*  
*Дата анализа: 28.03.2026*
