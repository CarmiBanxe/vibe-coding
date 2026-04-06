#!/bin/bash
###############################################################################
# sync-memory-full-29mar.sh — ПОЛНАЯ синхронизация MEMORY.md со ВСЕМИ
# изменениями 28-29 марта 2026
#
# Запускать на LEGION:
#   cd ~/vibe-coding && git pull && bash scripts/sync-memory-full-29mar.sh
#
# Что делает:
#   1. Записывает АКТУАЛЬНЫЙ MEMORY.md на GMKtec (SSH)
#   2. Копирует во ВСЕ workspace ботов (MoA, mycarmibot, CTIO)
#   3. Перезапускает оба gateway чтобы боты подхватили
###############################################################################

echo "=========================================="
echo "  КАНОН: Полная синхронизация MEMORY.md"
echo "  Все изменения 28-29 марта 2026"
echo "=========================================="

ssh gmktec 'bash -s' << 'REMOTE_END'

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

###############################################################################
# MEMORY.md — полная версия
###############################################################################
read -r -d '' MEMORY_CONTENT << 'MEMORY_EOF'
# MEMORY — Banxe AI Bank
> Последнее обновление: 29.03.2026 16:35 CET
> Обновлено после: Полная синхронизация — все фазы 1-4

## Кто я
Я — CTIO проекта Banxe AI Bank.
CEO — Moriel Carmi (Mark Fr., @bereg2022, Telegram ID: 508602494).
Платформа: OpenClaw, Telegram-боты.

## О Марке (CEO)
- Имя: Moriel Carmi (Mark Fr.)
- Email: moriel@banxe.com, carmi@banxe.com
- Telegram: @bereg2022 (ID: 508602494)
- Локация: Франция (Europe/Paris)
- Стиль: единые скрипты ("канон"), подробные объяснения как для новичка
- Подписки: Claude Max ($200), Perplexity Max ($200), ChatGPT Pro, Gemini Pro, X Pro
- Ни одна подписка НЕ даёт API доступа

## CTIO Олег
- Telegram: @p314pm (ID: 66549310283)
- Linux user: ctio на GMKtec
- SSH: ssh -p 2222 ctio@90.116.185.11 (пароль: banxe)
- Права: FULL — конгруэнтные CEO (sudo NOPASSWD)
- OpenClaw профиль: /home/ctio/.openclaw-ctio (порт 18791)
- Скрипт установки: /home/ctio/install-my-bot.sh
- ClickHouse: FULL ACCESS (ctio_agent)
- Статус: ожидаем создание бота через @BotFather

## Проект Banxe AI Bank
- Компания: Banxe UK Ltd (EMI, FCA authorised)
- Архитектура: GMKtec = МОЗГ (все агенты), Legion = ТЕРМИНАЛ
- Прогресс: ~50% (Фазы 1-4 завершены)
- Security Score: ~6/10 (было 2/10)

---

## ТЕКУЩЕЕ СОСТОЯНИЕ ИНФРАСТРУКТУРЫ (29.03.2026)

### Legion Pro 5 (ТЕРМИНАЛ) — mark-legion
- Intel i7-14700HX, 16GB RAM, WSL2 Ubuntu 24.04
- LiteLLM: ACTIVE, порт 8080, v1.82.0
- Deep Search: ACTIVE, порт 8088 (проксирует на GMKtec)
- OpenClaw Gateway moa: ОСТАНОВЛЕН (перенесён на GMKtec)
- SSH ключ к GMKtec настроен (без пароля), алиас: ssh gmktec
- Playwright + Chromium: /home/mmber/playwright-env/

### GMKtec EVO-X2 (AI COMPUTE BRAIN) — banxe-NucBox-EVO-X2
- AMD Ryzen AI MAX+ 395, 16C/32T, 128GB RAM (32GB системе, 96GB GPU)
- GPU: AMD Radeon 8060S, 96GB VRAM
- ОС: Ubuntu 24.04.4 LTS bare metal (kernel 6.17.0-19-generic)
- IP: 192.168.0.72 (ethernet)
- Внешний IP: 90.116.185.11
- SSH: порт 2222
- Пользователи: root, banxe, ctio (Олег)

#### Диски GMKtec (WINDOWS УНИЧТОЖЕН)
- nvme1n1 (Crucial 1TB): Linux система, 681GB свободно, ext4
- nvme0n1 (YMTC 2TB): /data, 1.7TB свободно, ext4
- Структура /data: backups/, clickhouse/, logs/, metaclaw/

#### СЕРВИСЫ GMKtec (ВСЕ ACTIVE на 29.03.2026)
| Сервис | Порт | Описание |
|--------|------|----------|
| @mycarmi_moa_bot Gateway | 18789 | Основной бот Banxe AI Bank |
| @mycarmibot Gateway | 18793 | Чистый универсальный бот (отделён от Banxe) |
| Ollama 0.18.3 | 11434 | 4 модели (98GB) |
| ClickHouse 26.3.2 | 9000 | БД banxe, 6 таблиц, данные на /data |
| PII Proxy (Presidio) | 8089 | Анонимизация для облачных API (GDPR) |
| Deep Search v4 | 8088 | DuckDuckGo + Wikipedia (User-Agent: BanxeBot/1.0) |
| n8n | 5678 | Автоматизация workflows (carmi@banxe.com) |
| fail2ban | — | Защита SSH |
| XRDP | 3389 | Удалённый рабочий стол |

#### Ollama модели (GMKtec)
1. llama3.3:70b — 42GB, Q4_K_M
2. huihui_ai/qwen3.5-abliterated:35b — 23GB, Q4_K_M (АКТИВНА)
3. glm-4.7-flash-abliterated — 18GB
4. gpt-oss-derestricted:20b — 15GB

#### ClickHouse таблицы (база banxe)
- transactions, aml_alerts, kyc_events, accounts, audit_trail, agent_metrics

### Роутер Livebox 5 (Orange France)
- Внешний IP: 90.116.185.11
- NAT/PAT: порт 2222 → GMKtec:2222 TCP
- SSH извне: ssh -p 2222 root@90.116.185.11

---

## КОНФИГУРАЦИЯ БОТОВ

### @mycarmi_moa_bot (основной)
- Gateway порт: 18789 на GMKtec
- Конфиг: /root/.openclaw-moa/.openclaw/openclaw.json
- Workspace: /home/mmber/.openclaw/workspace-moa + /root/.openclaw-moa/workspace-moa
- gateway.mode: local (ОБЯЗАТЕЛЬНО)
- Модель: ollama/huihui_ai/qwen3.5-abliterated:35b (DIRECT, без LiteLLM)
- Provider: baseUrl http://localhost:11434, api: ollama
- Параметры: num_ctx: 32768, streaming: false (КРИТИЧНО)
- dmPolicy: allowlist, allowFrom: [508602494]

### @mycarmibot (универсальный)
- Gateway порт: 18793 на GMKtec
- Конфиг: в отдельном профиле, отделён от Banxe
- Та же модель и параметры

### CTIO бот (Олег)
- Профиль: /home/ctio/.openclaw-ctio (порт 18791)
- Статус: ожидаем создание бота через @BotFather

---

## МОИ ИНСТРУМЕНТЫ ДЛЯ ПОИСКА

### Brave Search API
- Ключ: REDACTED_BRAVE_API_KEY
- Настроен во ВСЕХ конфигах ботов
- Использование: могу искать в интернете через Brave Search
- Лимит: 2000 запросов/месяц (бесплатный план)

### Deep Search v4
- Порт: 8088 на GMKtec
- Движки: DuckDuckGo + Wikipedia
- User-Agent: BanxeBot/1.0 (КРИТИЧНО — без него 403)
- Использование: локальный поиск без лимитов

### Как искать информацию
Когда пользователь просит найти информацию:
1. Используй Brave Search API для веб-поиска
2. Используй Deep Search для дополнительных результатов
3. Комбинируй результаты для полного ответа

---

## БЕЗОПАСНОСТЬ
- PII Proxy (Presidio): порт 8089 — анонимизация персональных данных перед отправкой в облачные API
- fail2ban: защита SSH от брутфорса
- fscrypt: шифрование at rest (настроено)
- Backup: ClickHouse каждые 6ч, OpenClaw ежедневно 3:00 → /data/backups/
- Security Score: ~6/10 (было 2/10)

---

## MetaClaw
- Установлен: /opt/metaclaw-env/
- Skills: /data/metaclaw/skills/
  - compliance/sanctions_check.json — проверка санкционных списков
  - kyc/edd_triggers.json — триггеры расширенной проверки
  - shared/iban_validation.json — валидация IBAN
- Режим: skills_only (без GPU, накопление навыков)
- Статус: установлен, активация в процессе

---

## API КЛЮЧИ
- Brave Search: REDACTED_BRAVE_API_KEY
- Anthropic: sk-ant-oat01-AUfg... (в .env)
- Groq: gsk_6Bd2iv9pg...
- Gemini: AIzaSyCa7ab... (квота=0)

---

## АГЕНТЫ BANXE (10 штук)
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

---

## VENDOR КОНТАКТЫ (emails отправлены 29.03.2026)
- SumSub (sales@sumsub.com) — KYC/KYB sandbox
- Dow Jones (sales@dowjones.com) — Sanctions/PEP screening
- LexisNexis (sales@lexisnexis.com) — WorldCompliance
- Geniusto (sales@geniusto.com) — Core banking SEPA/SWIFT

---

## КРИТИЧЕСКИЕ ПАРАМЕТРЫ (НЕ ЗАБЫВАТЬ)
- contextWindow НЕ допускается в agents.defaults.models — только params
- streaming: false ОБЯЗАТЕЛЬНО (иначе 2-мин timeout)
- num_ctx: 32768 ОБЯЗАТЕЛЬНО (дефолт 8192 < минимум 16000)
- LiteLLM proxy вызывает raw JSON — обход: прямой Ollama
- gateway.mode=local ОБЯЗАТЕЛЬНО в конфиге
- Systemd fix: sed -i 's|/.openclaw-moa/.openclaw-moa|/.openclaw-moa|g' (баг двойного пути)
- Deep Search User-Agent: BanxeBot/1.0 (без него 403)

---

## n8n — Автоматизация
- Порт: 5678 на GMKtec
- Аккаунт: carmi@banxe.com / Banxe2026
- N8N_SECURE_COOKIE=false (для HTTP доступа)
- Доступ: http://192.168.0.72:5678

---

## ПЛАН ДВИЖЕНИЯ

### ✅ Выполнено
- 27.03: Бот починен (qwen3.5:35b, streaming:false, num_ctx:32768)
- 27.03: SSH наружу (порт 2222, NAT/PAT)
- 27.03: Firefox/XFCE починены на GMKtec
- 28.03: Фаза 1 — GMKtec production-ready (Node22, OpenClaw, ClickHouse)
- 28.03: SSH без пароля Legion→GMKtec
- 28.03: Gateway перенесён с Legion на GMKtec
- 28.03: Фаза 2 — Windows уничтожен, 2TB→ext4 /data
- 28.03: Фаза 3 — Backup cron, fscrypt, PII Proxy (Presidio)
- 29.03: Фаза 4 — n8n, MetaClaw установлен, vendor emails отправлены
- 29.03: @mycarmibot отделён от Banxe (порт 18793)
- 29.03: CTIO Олег — пользователь создан, README отправлен
- 29.03: Deep Search v4 починен (User-Agent: BanxeBot/1.0)
- 29.03: Brave Search API настроен во всех ботах

### 🔜 Следующие шаги
- MetaClaw: полная активация (daemon)
- Олег: подключение бота (ждём @BotFather)
- n8n: настройка первых workflows (KYC, мониторинг)
- API интеграции: SumSub, Dow Jones, LexisNexis, Geniusto (ждём ответы)
- HITL interface
- Observability (Lunari.ai)
- Security Score: 6/10 → 7/10+

### Незавершённые задачи
1. API интеграции (ждём ответы вендоров)
2. n8n workflows
3. HITL interface
4. Observability
5. RL-режим MetaClaw (после стабилизации)
MEMORY_EOF

###############################################################################
# Записываем во ВСЕ workspace ботов
###############################################################################
echo "[1/4] Записываю MEMORY.md во все workspace..."

TARGETS=(
    "/home/mmber/.openclaw/workspace-moa"
    "/root/.openclaw-moa/workspace-moa"
    "/root/.openclaw-moa/.openclaw/workspace"
    "/root/.openclaw-moa/.openclaw/workspace-moa"
)

COUNT=0
for DIR in "${TARGETS[@]}"; do
    if [ -d "$DIR" ] || mkdir -p "$DIR" 2>/dev/null; then
        echo "$MEMORY_CONTENT" > "$DIR/MEMORY.md"
        echo "  ✓ $DIR/MEMORY.md"
        COUNT=$((COUNT+1))
    else
        echo "  ✗ $DIR — не существует"
    fi
done

# @mycarmibot workspace (если есть отдельный)
for DIR in /root/.openclaw-mycarmibot/workspace* /home/mmber/.openclaw-mycarmibot/workspace*; do
    if [ -d "$DIR" ]; then
        echo "$MEMORY_CONTENT" > "$DIR/MEMORY.md"
        echo "  ✓ $DIR/MEMORY.md (mycarmibot)"
        COUNT=$((COUNT+1))
    fi
done

# CTIO workspace
if [ -d "/home/ctio/.openclaw-ctio" ]; then
    mkdir -p /home/ctio/.openclaw-ctio/workspace 2>/dev/null
    echo "$MEMORY_CONTENT" > /home/ctio/.openclaw-ctio/workspace/MEMORY.md
    chown ctio:ctio /home/ctio/.openclaw-ctio/workspace/MEMORY.md
    echo "  ✓ /home/ctio/.openclaw-ctio/workspace/MEMORY.md (CTIO)"
    COUNT=$((COUNT+1))
fi

echo "  Записано в $COUNT workspace"

###############################################################################
# Перезапускаем Gateway чтобы боты подхватили MEMORY.md
###############################################################################
echo ""
echo "[2/4] Перезапускаю @mycarmi_moa_bot gateway..."
# Находим PID
MOA_PID=$(pgrep -f "openclaw.*18789" 2>/dev/null || pgrep -f "openclaw-moa" 2>/dev/null)
if [ -n "$MOA_PID" ]; then
    kill "$MOA_PID" 2>/dev/null
    sleep 2
fi
# Запускаем через systemd или напрямую
systemctl restart openclaw-gateway-moa 2>/dev/null
sleep 3
if pgrep -f "18789" &>/dev/null; then
    echo "  ✓ @mycarmi_moa_bot gateway ACTIVE (порт 18789)"
else
    echo "  ⚠ Gateway не запустился автоматически — может потребоваться ручной запуск"
    echo "    Команда: cd /root/.openclaw-moa && npx openclaw gateway --port 18789 &"
fi

echo ""
echo "[3/4] Перезапускаю @mycarmibot gateway..."
CARMI_PID=$(pgrep -f "openclaw.*18793" 2>/dev/null)
if [ -n "$CARMI_PID" ]; then
    kill "$CARMI_PID" 2>/dev/null
    sleep 2
fi
systemctl restart openclaw-gateway-mycarmibot 2>/dev/null
sleep 3
if pgrep -f "18793" &>/dev/null; then
    echo "  ✓ @mycarmibot gateway ACTIVE (порт 18793)"
else
    echo "  ⚠ Gateway не запустился автоматически"
    echo "    Команда: cd /root/.openclaw-mycarmibot && npx openclaw gateway --port 18793 &"
fi

###############################################################################
# Проверка
###############################################################################
echo ""
echo "[4/4] Проверка..."
echo "  MEMORY.md размер:"
for DIR in "${TARGETS[@]}"; do
    if [ -f "$DIR/MEMORY.md" ]; then
        SIZE=$(wc -l < "$DIR/MEMORY.md")
        echo "    $DIR/MEMORY.md — $SIZE строк"
    fi
done

echo ""
echo "  Активные gateway:"
ps aux | grep -E "openclaw.*(gateway|18789|18793)" | grep -v grep | awk '{print "    PID "$2": "$11" "$12" "$13}'

REMOTE_END

echo ""
echo "=========================================="
echo "  КАНОН ВЫПОЛНЕН — MEMORY.md синхронизирован"
echo "  Бот теперь знает ВСЁ о текущем состоянии"
echo "=========================================="
echo ""
echo "ПРОВЕРКА: напиши боту в Telegram:"
echo '  "Какие у тебя инструменты для поиска?"'
echo '  "Найди информацию о FCA"'
