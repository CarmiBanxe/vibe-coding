---
name: Project Snapshot — 02.04.2026
description: Полный срез проекта Banxe AI Bank на вечер 02.04.2026. Инфраструктура, агенты, что сделано за сессию, что остаётся.
type: project
---

# Banxe AI Bank — Срез 02.04.2026 (вечер)

## Общий прогресс: ~63%

## Команда
- **Марк** (Moriel Carmi, @bereg2022, ID: 508602494) — CEO/CTIO, главный
- **Олег** (ID: 66549310283) — реальный человек, CTIO-дублёр. Полные права через Telegram-бот (port 18791) и SSH (user=ctio). Его действия на сервере → автообучение AI-агентов пассивно, без его ведома. Это легально при наличии оговорки в контракте (UK GDPR).

## Инфраструктура GMKtec EVO-X2

- AMD Ryzen AI MAX+ 395, 128 GB RAM (30 GB доступно системе)
- GPU: Radeon 8060S, **ROCm установлен** ✅
- **GTT: 59392 MB (58 GB) разблокирован** ✅ (GRUB параметры применены)
- ОС: Ubuntu 24.04, kernel 6.17.0-19-generic
- SSH: порт 2222 (root, ctio, mmber), внешний: 90.116.185.11:2222
- IP: 192.168.0.72 (eth), 192.168.0.117 (wifi)

## Ollama (GMKtec, /data/ollama-models)

| Модель | Размер | Роль |
|--------|--------|------|
| qwen3-banxe:latest | 18 GB | Кастомная (Modelfile с SOUL-правилами) |
| qwen3:30b-a3b | 18 GB | Главная модель бота (MoE, ~65 t/s с ROCm) |
| glm-4.7-flash-abliterated | 18 GB | Dev/тесты (самая быстрая) |
| gpt-oss-derestricted:20b | 15 GB | Эксперименты |

**Удалены:** llama3.3:70b, qwen3.5-abliterated:35b

Ollama config (`/etc/systemd/system/ollama.service.d/override.conf`):
- `OLLAMA_KEEP_ALIVE=-1` (модели никогда не выгружаются)
- `OLLAMA_MAX_LOADED_MODELS=2` (макс 2 модели в памяти = ~36 GB < 58 GB GTT)
- `OLLAMA_HOST=0.0.0.0`, `OLLAMA_MODELS=/data/ollama-models`

## OpenClaw Gateways (GMKtec)

| Сервис | Порт | Статус | Конфиг |
|--------|------|--------|--------|
| openclaw-gateway-moa | 18789 | ✅ ACTIVE | root, OPENCLAW_HOME=/root/.openclaw-moa |
| openclaw-gateway-ctio (Олег) | 18791 | ✅ ACTIVE (починен сегодня) | ctio, OPENCLAW_HOME=/home/ctio/.openclaw-ctio |
| openclaw-gateway-guiyon | 18794 | ✅ ACTIVE | GUIYON инстанс |

### Что было починено в openclaw-gateway-ctio (02.04.2026):
1. `HOME=/home/ctio` → `HOME=/home/ctio/.openclaw-ctio` в systemd-сервисе
2. `ExecStart=/usr/bin/npx openclaw` → `ExecStart=/usr/bin/openclaw` (npx не мог читать /root/.npm)
3. Создана директория `/home/ctio/.openclaw-ctio/.openclaw/` + перенесён туда openclaw.json (OpenClaw ищет конфиг по `$OPENCLAW_HOME/.openclaw/openclaw.json`)
4. Модели в openclaw.json обновлены: llama3.3:70b и qwen3.5-abliterated:35b → qwen3:30b-a3b (6 агентов)
5. Добавлены `controlUi` и `trustedProxies` в gateway секцию (как в рабочем moa)

### Текущая ошибка Олега (остаток):
`401: Unauthorized` от Telegram — bot token невалидный. **Нужен новый токен из @BotFather.**
Когда Олег создаст бот → вставить токен в `/home/ctio/.openclaw-ctio/.openclaw/openclaw.json` → `channels.telegram.botToken`

### ВАЖНО: структура конфига OpenClaw (2026.3.28)
OpenClaw ВСЕГДА ищет конфиг по: `$OPENCLAW_HOME/.openclaw/openclaw.json`
НЕ по `$OPENCLAW_HOME/openclaw.json` (это legacy/backup)

## 10 AI-агентов (openclaw-gateway-ctio конфиг)

| Агент | Модель |
|-------|--------|
| main (CTIO) | ollama/qwen3:30b-a3b |
| supervisor | ollama/qwen3:30b-a3b |
| kyc | ollama/qwen3:30b-a3b |
| client-service | ollama/glm-4.7-flash-abliterated |
| compliance | ollama/qwen3:30b-a3b |
| operations | ollama/glm-4.7-flash-abliterated |
| crypto | ollama/qwen3:30b-a3b |
| analytics | ollama/gpt-oss-derestricted:20b |
| risk | ollama/qwen3:30b-a3b |
| it-devops | ollama/glm-4.7-flash-abliterated |

## Python Pre-Filter (создан сегодня)

`/usr/local/bin/banxe-prefilter.py` — детерминированная блокировка до LLM:
- Категория A → BLOCK (Россия, Иран, КНДР, Куба, Беларусь, Мьянма, Афганистан, Венесуэла, Крым/ДНР/ЛНР)
- Категория B → HOLD (Сирия, Ирак, Ливан, Йемен, Гаити, Мали, Ливия, Сомали)
- Категория C → PASS с EDD

**Известный баг:** regex для "Беларусь" (кириллица) — возвращает PASS вместо BLOCK. Belarus (латиница) работает. **Нужно починить.**

## Что работает ✅

- ClickHouse: база banxe, 6 таблиц
- SSH GMKtec ↔ Legion (без пароля)
- Eval suite + Karpathy Loop (nightly)
- MetaClaw POC (склонирован)
- HITL-архитектура (10 агентов + дублёры, логирование в ClickHouse для FCA)
- Action Analyzer (cron каждые 2 мин)
- n8n: AML Transaction Monitor + KYC Onboarding
- CTIO Watcher: автопуш docs/MEMORY.md на GitHub каждые 5 мин
- SOUL.md защищён soul-guard.conf (chattr +i) — только для moa
- GTT 58 GB + ROCm
- Sanctions list (памяти Claude Code + SOUL.md бота)
- Python pre-filter (кроме бага Беларусь-кириллица)
- openclaw-gateway-ctio — работает (кроме Telegram token)

## Что не сделано ❌ (приоритеты)

1. **Telegram token для Олега** — нужен новый из @BotFather → вставить в конфиг
2. **Беларусь regex** в pre-filter — починить кириллический паттерн
3. **Vendor emails** не отправлены (Dow Jones, LexisNexis, Sumsub) — главный блокер Compliance
4. **Pipeline: ctio auditd → ClickHouse → обучение агентов** — не построен
5. **MetaClaw** — полная установка не завершена
6. **Alice £500 workflow** — реальный замер не проведён
7. **PII Proxy (Presidio)** — GDPR Art.32, риск €20M штраф
8. **Шифрование at rest** — GDPR Art.32
9. **ClickHouse backup** — не настроен

**Why:** FCA UK EMI. Vendor sandbox = блокер реального AML/KYC. Олег = источник training data.
**How to apply:** Приоритет 1 — token Олега. Приоритет 2 — vendor emails. Приоритет 3 — auditd pipeline.
