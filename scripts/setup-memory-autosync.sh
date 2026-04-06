#!/bin/bash
###############################################################################
# setup-memory-autosync.sh — Автоматическая синхронизация MEMORY.md
#
# Запускать на LEGION (ОДИН РАЗ):
#   cd ~/vibe-coding && git pull && bash scripts/setup-memory-autosync.sh
#
# Что делает:
#   1. СЕЙЧАС: записывает полный актуальный MEMORY.md на GMKtec
#   2. НАВСЕГДА: ставит cron на GMKtec который каждые 5 минут:
#      - делает git pull из vibe-coding репо
#      - если MEMORY.md изменился — копирует во все workspace ботов
#      - перезапускает gateway только при реальных изменениях
#   3. После этого: достаточно просто пушить MEMORY.md в GitHub,
#      GMKtec подхватит сам. Без участия человека.
###############################################################################

echo "=========================================="
echo "  АВТОСИНК MEMORY.md — установка"
echo "=========================================="

###############################################################################
# ШАГ 1: Пишем актуальный MEMORY.md прямо в репо (docs/MEMORY.md)
#         Это будет единственный source of truth
###############################################################################
echo "[1/3] Создаю docs/MEMORY.md в репозитории (source of truth)..."

mkdir -p /home/user/workspace/vibe-coding/docs

cat > /home/user/workspace/vibe-coding/docs/MEMORY.md << 'MEMORY_EOF'
# MEMORY — Banxe AI Bank
> Последнее обновление: 29.03.2026 16:35 CET
> Обновлено после: Полная синхронизация — все фазы 1-4 + автосинк

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
- 29.03: АВТОСИНК MEMORY.md из GitHub (cron каждые 5 мин)

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

echo "  ✓ docs/MEMORY.md создан в репозитории"

###############################################################################
# ШАГ 2: Отправляем всё на GMKtec — и MEMORY.md, и автосинк скрипт
###############################################################################
echo ""
echo "[2/3] Настраиваю GMKtec..."

ssh gmktec 'bash -s' << 'REMOTE_END'

###########################################################################
# A) Клонируем/обновляем репо на GMKtec
###########################################################################
echo "  Настраиваю git репо на GMKtec..."

if [ -d "/data/vibe-coding/.git" ]; then
    cd /data/vibe-coding && git pull --ff-only 2>/dev/null
    echo "  ✓ Репо обновлён: /data/vibe-coding"
else
    cd /data && git clone https://github.com/CarmiBanxe/vibe-coding.git 2>/dev/null
    echo "  ✓ Репо клонирован: /data/vibe-coding"
fi

###########################################################################
# B) Создаём скрипт-watcher который cron будет запускать каждые 5 минут
###########################################################################
echo "  Создаю watcher-скрипт..."

cat > /data/vibe-coding/memory-autosync-watcher.sh << 'WATCHER'
#!/bin/bash
###############################################################################
# memory-autosync-watcher.sh — запускается cron каждые 5 минут
# Делает git pull, и если docs/MEMORY.md изменился — обновляет все workspace
###############################################################################

REPO_DIR="/data/vibe-coding"
MEMORY_SRC="$REPO_DIR/docs/MEMORY.md"
HASH_FILE="/data/logs/memory-last-hash.txt"
LOG_FILE="/data/logs/memory-sync.log"

mkdir -p /data/logs

# git pull
cd "$REPO_DIR"
git pull --ff-only >> "$LOG_FILE" 2>&1

# Проверяем есть ли MEMORY.md
if [ ! -f "$MEMORY_SRC" ]; then
    echo "$(date): MEMORY.md не найден в репо" >> "$LOG_FILE"
    exit 0
fi

# Считаем хэш
NEW_HASH=$(md5sum "$MEMORY_SRC" | awk '{print $1}')
OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null)

# Если не изменился — выходим тихо
if [ "$NEW_HASH" == "$OLD_HASH" ]; then
    exit 0
fi

# MEMORY.md ИЗМЕНИЛСЯ — обновляем всё
echo "$(date): MEMORY.md изменился ($OLD_HASH → $NEW_HASH), синхронизирую..." >> "$LOG_FILE"

# Сохраняем новый хэш
echo "$NEW_HASH" > "$HASH_FILE"

# Копируем во все workspace ботов
TARGETS=(
    "/home/mmber/.openclaw/workspace-moa"
    "/root/.openclaw-moa/workspace-moa"
    "/root/.openclaw-moa/.openclaw/workspace"
    "/root/.openclaw-moa/.openclaw/workspace-moa"
)

for DIR in "${TARGETS[@]}"; do
    if [ -d "$DIR" ] || mkdir -p "$DIR" 2>/dev/null; then
        cp "$MEMORY_SRC" "$DIR/MEMORY.md"
        echo "$(date):   → $DIR/MEMORY.md" >> "$LOG_FILE"
    fi
done

# @mycarmibot workspace
for DIR in /root/.openclaw-mycarmibot/workspace* /home/mmber/.openclaw-mycarmibot/workspace*; do
    if [ -d "$DIR" ]; then
        cp "$MEMORY_SRC" "$DIR/MEMORY.md"
        echo "$(date):   → $DIR/MEMORY.md (mycarmibot)" >> "$LOG_FILE"
    fi
done

# CTIO workspace
if [ -d "/home/ctio/.openclaw-ctio" ]; then
    mkdir -p /home/ctio/.openclaw-ctio/workspace 2>/dev/null
    cp "$MEMORY_SRC" /home/ctio/.openclaw-ctio/workspace/MEMORY.md
    chown ctio:ctio /home/ctio/.openclaw-ctio/workspace/MEMORY.md
    echo "$(date):   → CTIO workspace" >> "$LOG_FILE"
fi

# Перезапускаем gateway (мягко — kill + systemd)
echo "$(date):   Перезапуск gateway..." >> "$LOG_FILE"

systemctl restart openclaw-gateway-moa 2>/dev/null
sleep 2
systemctl restart openclaw-gateway-mycarmibot 2>/dev/null

# Если systemd не сработал — проверяем по процессам
if ! pgrep -f "18789" &>/dev/null; then
    echo "$(date):   ⚠ MoA gateway не запустился через systemd" >> "$LOG_FILE"
fi
if ! pgrep -f "18793" &>/dev/null; then
    echo "$(date):   ⚠ mycarmibot gateway не запустился через systemd" >> "$LOG_FILE"
fi

echo "$(date): ✓ Синхронизация завершена" >> "$LOG_FILE"
WATCHER

chmod +x /data/vibe-coding/memory-autosync-watcher.sh
echo "  ✓ Watcher создан: /data/vibe-coding/memory-autosync-watcher.sh"

###########################################################################
# C) Ставим cron — каждые 5 минут
###########################################################################
echo "  Настраиваю cron..."

# Удаляем старые записи memory-sync из cron (если были)
crontab -l 2>/dev/null | grep -v "memory-autosync-watcher" | crontab -

# Добавляем новый cron
(crontab -l 2>/dev/null; echo "*/5 * * * * /bin/bash /data/vibe-coding/memory-autosync-watcher.sh") | crontab -

echo "  ✓ Cron установлен: */5 * * * * memory-autosync-watcher.sh"

# Показываем crontab
echo ""
echo "  Текущий crontab:"
crontab -l | grep -v "^#" | grep -v "^$" | while read line; do
    echo "    $line"
done

###########################################################################
# D) Первый запуск — сейчас синхронизируем MEMORY.md
###########################################################################
echo ""
echo "  Первый запуск watcher..."
/bin/bash /data/vibe-coding/memory-autosync-watcher.sh

echo ""
echo "  Проверяю результат..."
for DIR in "/home/mmber/.openclaw/workspace-moa" "/root/.openclaw-moa/workspace-moa"; do
    if [ -f "$DIR/MEMORY.md" ]; then
        LINES=$(wc -l < "$DIR/MEMORY.md")
        HEAD=$(head -2 "$DIR/MEMORY.md" | tail -1)
        echo "  ✓ $DIR/MEMORY.md — $LINES строк"
        echo "    $HEAD"
    fi
done

echo ""
echo "  Активные gateway:"
ps aux | grep -E "openclaw.*(gateway|18789|18793)" | grep -v grep | awk '{print "    PID "$2": "$11" "$12" "$13}' | head -5

echo ""
echo "  Последние записи лога:"
tail -5 /data/logs/memory-sync.log 2>/dev/null

REMOTE_END

###############################################################################
# ШАГ 3: Коммитим docs/MEMORY.md в GitHub
###############################################################################
echo ""
echo "[3/3] Коммичу docs/MEMORY.md в GitHub..."
echo "  (это source of truth — watcher на GMKtec будет тянуть отсюда)"
