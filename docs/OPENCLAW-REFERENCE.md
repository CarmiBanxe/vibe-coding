# OPENCLAW-REFERENCE — Ревизия конфигурации

> Создан: 29.03.2026  
> Источник: Полное прочтение «Explain OpenClaw — Полное руководство» (146 стр., февраль 2026, перевод centminmod/explain-openclaw)  
> Задача: сравнение нашей текущей конфигурации с рекомендациями руководства

---

## 1. ОБЗОР РУКОВОДСТВА

### Что это за документ

«Explain OpenClaw — Полное руководство» — перевод репозитория `centminmod/explain-openclaw`, февраль 2026. Представляет собой неофициальный технический разбор OpenClaw: архитектура, развёртывание, безопасность, оптимизации. Составлен по исходному коду и официальной документации https://docs.openclaw.ai.

### Версия продукта

OpenClaw (ранее Moltbot / Clawdbot). Актуальная версия Node.js рекомендуемая в руководстве: **22.12.0+** (с патчами безопасности). Порт по умолчанию: **18789**.

### Ключевые разделы руководства (с номерами страниц)

| Раздел | Страницы |
|--------|----------|
| Что такое OpenClaw? (архитектура, компоненты) | 7–21 |
| Глоссарий | 12–15 |
| Архитектура и карта репозитория | 16–27 |
| Развёртывание: Standalone Mac mini | 28–34 |
| Развёртывание: Изолированный VPS | 35–66 |
| Развёртывание: Cloudflare Moltworker (serverless) | 67–78 |
| Развёртывание: Docker Model Runner (локальный ИИ) | 79–89 |
| Модель угроз | 90–97 |
| Чек-лист усиления безопасности (высокая приватность) | 98–105 |
| Пример конфигурации высокой приватности | 106–112 |
| Обнаружение запросов OpenClaw | 113–129 |
| Оптимизации: обзор | 130–131 |
| Moltbook (ИИ-соцсеть) | 132–138 |
| Освещение в медиа / Lex Fridman | 139–146 |

---

## 2. РЕВИЗИЯ НАШЕЙ КОНФИГУРАЦИИ

### 2.1 Архитектура и развёртывание

**Наша конфигурация:**
- GMKtec EVO-X2, Ubuntu 24.04 bare metal, AMD Ryzen AI MAX+ 395, 128GB RAM
- OpenClaw установлен глобально через npm (`/usr/lib/node_modules/openclaw`), Node.js 22
- Запускается как системные `systemd`-сервисы (`/etc/systemd/system/`)
- Три Gateway-экземпляра: порты 18789, 18791, 18793 (четвёртый на 18795 — по SYSTEM-STATE)

**Рекомендации руководства (стр. 37–38):**

Руководство не рассматривает bare metal отдельно — ближайший сценарий «Изолированный VPS». Ключевые требования совпадают:
- Запуск под **выделенным пользователем без прав root** (у нас: `root` — ❌)
- Gateway **только на loopback** (у нас: `gateway.mode=local` — ✅)
- Использование systemd-сервисов — ✅

**Оценка:** Тип развёртывания (bare metal с GPU) — оптимален для локальных моделей. Главная проблема — запуск от root.

---

### 2.2 Gateway конфигурация

**Наша конфигурация:**
- `gateway.mode=local` (loopback-only) — ✅ соответствует рекомендации
- Порты: 18789 (MOA бот), 18791 (CTIO), 18793 (mycarmibot), 18795 (не идентифицирован)
- Привязка к `127.0.0.1` (localhost only) — ✅

**Рекомендации руководства:**

Стр. 30, 38, 99: `gateway.bind: "loopback"` — **самый безопасный паттерн** по умолчанию. Наше `gateway.mode=local` соответствует этому.

Стр. 62 (раздел 17): Рекомендуемый `openclaw.json` для продакшена:
```json
{
  "gateway": {
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": "<GENERATE_WITH_OPENSSL>"
    },
    "trustedProxies": [],
    "controlUi": {
      "dangerouslyDisableDeviceAuth": false
    }
  }
}
```

**Расхождения:**
| Параметр | У нас | Рекомендация | Критичность |
|----------|-------|--------------|-------------|
| `gateway.bind` | `local` (loopback) | `"loopback"` | ✅ ОК |
| `gateway.auth.mode` | не настроен | `"token"` | ⚠️ важно |
| `gateway.trustedProxies` | не настроен | `[]` или IP прокси | ℹ️ если нет прокси — пусто |
| `gateway.controlUi.dangerouslyDisableDeviceAuth` | неизвестно | `false` | ⚠️ важно |

---

### 2.3 Каналы (Telegram)

**Наша конфигурация:**
- `channels.telegram` настроен
- `dmPolicy: allowlist`, `allowFrom: [508602494]` — ✅
- Предупреждение: `Unrecognized key "type"` в секции каналов (не критично, бот работает)
- Исторически был баг: `channels` как массив вместо объекта

**Рекомендации руководства:**

Стр. 108–110 (пример конфигурации высокой приватности):
```json
"channels": [{
  "type": "telegram",
  "enabled": true,
  "dmPolicy": "allowlist",
  "allowFrom": ["your-user-id"],
  "groupPolicy": {
    "requireMention": true,
    "allowedGroups": ["your-approved-group-id"]
  },
  "configWrites": false
}]
```

**Расхождения:**
| Параметр | У нас | Рекомендация | Критичность |
|----------|-------|--------------|-------------|
| `dmPolicy` | `allowlist` | `allowlist` или `pairing` | ✅ ОК |
| `allowFrom` | `[508602494]` | конкретные ID | ✅ ОК |
| `groupPolicy.requireMention` | не задан | `true` | ⚠️ важно если в группах |
| `configWrites` | не задан | `false` | ⚠️ важно |
| Unrecognized key "type" | присутствует | не должно быть | ℹ️ некритично |

> **Важно (стр. 91):** Руководство предупреждает: белые списки (`allowlist`) — **настоящая граница безопасности** в мессенджер-ботах. У нас настроено правильно.

> **Важно (стр. 103–104, раздел 13):** `configWrites: false` должен быть задан явно. Инструмент `gateway` в OpenClaw НЕ имеет проверок разрешений при изменении конфига — это главный риск самопроизвольного изменения настроек ИИ.

---

### 2.4 Агенты и модели

**Наша конфигурация:**
- Модель: `ollama/huihui_ai/qwen3.5-abliterated:35b`
- Провайдер: прямой Ollama (`http://localhost:11434`), не через LiteLLM
- Параметры: `num_ctx=16384` (в задаче) / `num_ctx=32768` (в MEMORY.md), `num_predict=2048`, `streaming=false`, `temperature=0.5`
- Tools: `profile`, `sessions`, `agentToAgent`
- System prompt: инструкция читать `MEMORY.md` и `SYSTEM-STATE.md`

**Рекомендации руководства:**

Стр. 10, 97 (профили инструментов):
```
minimal    — только session_status
coding     — файловая система, среда выполнения, сессии, память
messaging  — обмен сообщениями, управление сессиями
full       — все инструменты (без ограничений)
```

Стр. 108: Для безопасной конфигурации: `"tools": { "profile": "minimal" }`.

Стр. 100 (раздел 7): «Начните с отключённых или минимальных инструментов. Добавляйте одну категорию за раз.»

Стр. 103–104 (раздел 13): **КРИТИЧНО** — инструмент `gateway` должен быть ЗАПРЕЩЁН:
```bash
openclaw config set tools.deny '["gateway"]'
# или
openclaw config set tools.profile coding
```

Стр. 94–95: файлы рабочего пространства `.md` (MEMORY.md, SYSTEM-STATE.md и др.) загружаются при каждом ходе агента через `loadWorkspaceBootstrapFiles()` и вводятся напрямую в системный промпт как **доверенный контекст** (без маркеров `<<<EXTERNAL_UNTRUSTED_CONTENT>>>`). Каждый файл усекается до 20 000 символов.

**Расхождения:**
| Параметр | У нас | Рекомендация | Критичность |
|----------|-------|--------------|-------------|
| Tools profile | `profile, sessions, agentToAgent` (кастомный) | `minimal` или явный список | ⚠️ важно |
| `tools.deny ["gateway"]` | не задан | задать явно | 🔴 критично |
| `configWrites: false` | не задан | `false` | 🔴 критично |
| `commands.config: false` | не задан | `false` | ⚠️ важно |
| `streaming` | `false` | рекомендуется для Ollama | ✅ ОК |
| `num_ctx` | 16384 / 32768 (расхождение!) | зависит от задачи | ⚠️ нужно унифицировать |
| MEMORY.md в workspace | ✅ | загружается как доверенный контекст | ✅ ОК (риск инъекции — управляем) |

---

### 2.5 Безопасность

**Наша текущая конфигурация:**
- Gateway на loopback — ✅
- `dmPolicy: allowlist` с конкретными ID — ✅
- fail2ban — ✅ (в SYSTEM-STATE)
- unattended-upgrades — ✅ (в SYSTEM-STATE)
- `fscrypt` (шифрование at rest) — ✅
- PII Proxy (Presidio) — ✅ (порт 8089)
- Запуск от **root** — ❌ нарушение рекомендации

**Критические расхождения с руководством:**

| Пункт | Стр. | У нас | Рекомендация | Критичность |
|-------|------|-------|--------------|-------------|
| Запуск не от root | 38 | root | выделенный пользователь | 🔴 критично |
| `gateway.auth.mode: "token"` | 42, 62 | не настроен | обязателен | 🔴 критично |
| `OPENCLAW_GATEWAY_TOKEN` | 62 | не известен | openssl rand -hex 32 | 🔴 критично |
| `browser.evaluateEnabled: false` | 62 | не задан | `false` | ⚠️ важно |
| `plugins.enabled: false` | 62 | не известен | `false` если не используется | ⚠️ важно |
| `logging.redactSensitive: "tools"` | 62 | не задан | `"tools"` | ⚠️ важно |
| `discovery.mdns.mode: "off"` | 45, 103 | не задан | `"off"` на VPS/сервере | ⚠️ важно |
| `tools.deny ["gateway"]` | 103 | не задан | обязателен | 🔴 критично |
| `configWrites: false` | 104 | не задан | `false` | 🔴 критично |
| MemoryMax systemd | 46–47 | не задан | `1G` (для VPS) / выше для bare metal | ⚠️ важно |
| CPUQuota systemd | 46–47 | не задан | `80%` | ⚠️ важно |
| `NoNewPrivileges=true` systemd | 46–47 | не задан | обязателен | ⚠️ важно |
| `ProtectSystem=strict` systemd | 46–47 | не задан | желательно | ℹ️ |
| Права ~/.openclaw 700 | 34, 47 | не проверено | `chmod 700` | ⚠️ важно |
| Ротация токенов шлюза | 63–64 | нет | ежемесячный cron | ℹ️ желательно |

---

### 2.6 Systemd сервисы

**Наша конфигурация:**
- `openclaw-gateway-moa.service` (порт 18789)
- `openclaw-gateway-mycarmibot.service` (порт 18793)
- Тип: системные сервисы в `/etc/systemd/system/`

**Рекомендации руководства (стр. 45–47, раздел 10):**

Полный рекомендуемый шаблон `/etc/systemd/system/openclaw-gateway.service`:
```ini
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.openclaw/bin/openclaw gateway --foreground
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production

# Resource limits
MemoryMax=1G         # для VPS; для GMKtec можно 8G или больше
CPUQuota=80%

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.openclaw

[Install]
WantedBy=default.target
```

**Расхождения с нашими сервисами:**
| Параметр | У нас | Рекомендация | Критичность |
|----------|-------|--------------|-------------|
| `MemoryMax` | отсутствует | задать (8–16G для GMKtec) | ⚠️ важно |
| `CPUQuota` | отсутствует | `80%` | ⚠️ важно |
| `NoNewPrivileges=true` | отсутствует | обязательно | ⚠️ важно |
| `ProtectSystem=strict` | отсутствует | желательно | ℹ️ |
| `Restart=on-failure` | неизвестно | `on-failure` + `RestartSec=5` | ⚠️ важно |
| `NODE_ENV=production` | неизвестно | установить | ℹ️ |

> **Примечание:** Руководство описывает *пользовательские* systemd-сервисы (`~/.config/systemd/user/`). Мы используем *системные* сервисы (`/etc/systemd/system/`) от root — это нестандартно, но работает. Нужно добавить ограничения ресурсов.

---

### 2.7 Workspace и файлы состояния

**Наша конфигурация:**
- `MEMORY.md` + `SYSTEM-STATE.md` копируются автоматически каждые 5 минут (cron)
- System prompt: инструкция читать эти файлы при каждом ответе
- Файлы находятся в workspace-директории бота

**Рекомендации руководства (стр. 94–96, раздел 7 модели угроз):**

OpenClaw загружает **9 именованных файлов** рабочего пространства `.md` при каждом ходе агента:
- `AGENTS.md`, `SOUL.md`, `TOOLS.md`, `IDENTITY.md`, `USER.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`, `MEMORY.md`, `memory.md`
- Каждый усекается до **20 000 символов**
- Они вводятся напрямую в системный промпт как **доверенный контекст**

**Риск:** Любой процесс или пользователь с доступом на запись в workspace может внедрить персистентную инъекцию промптов, которая **выглядит как доверенные системные инструкции** (встроенный сканер навыков проверяет только JS/TS — `.md` не сканируются).

**Рекомендация руководства (стр. 96, 103–104):**
```bash
# Периодическая проверка на скрытые HTML-комментарии
grep -rn "<!--" /path/to/workspace/

# Проверка на инъекции
grep -rniE "(ignore previous|system override|you are now|execute the following|curl.*base64)" /path/to/workspace/*.md
```

**Расхождения:**
| Пункт | У нас | Рекомендация | Критичность |
|-------|-------|--------------|-------------|
| Автокопирование MEMORY.md | ✅ каждые 5 мин | ОК | ✅ |
| Права на workspace | не проверено | ограничить запись от других пользователей | ⚠️ важно |
| Периодический аудит `.md` файлов | не настроен | добавить в cron | ⚠️ важно |
| Ограничение `workspaceAccess` | не задано | `"ro"` или `"none"` для агентов без необходимости записи | ℹ️ |

---

### 2.8 Резервное копирование

**Наша конфигурация (из MEMORY.md):**
- OpenClaw backup ежедневно в 3:00 → `/data/backups/`
- ClickHouse каждые 6 часов

**Рекомендации руководства (стр. 34, 47–48, раздел 10a):**

```bash
# Резервная копия без транскриптов сессий (рекомендуется)
tar czf openclaw-backup-$(date +%Y%m%d).tar.gz \
  --exclude='.openclaw/sessions' \
  --exclude='.openclaw/workspace' \
  -C ~/ .openclaw/

# Еженедельно через cron (каждое воскресенье в 2:00)
echo "0 2 * * 0 root tar czf /data/backups/openclaw-backup-$(date +%Y%m%d).tar.gz ..." | sudo tee -a /etc/crontab
```

> Хранить в **зашифрованном** месте — резервная копия содержит API-ключи и токены в открытом виде.

**Расхождения:**
| Пункт | У нас | Рекомендация | Критичность |
|-------|-------|--------------|-------------|
| Ежедневный backup | ✅ | еженедельно минимум | ✅ |
| Шифрование архива | не известно | LUKS или зашифрованный volume | ⚠️ |
| Исключение sessions/ из backup | не известно | рекомендуется | ℹ️ |
| `chmod 600 ~/.openclaw/openclaw.json` после restore | не проверено | обязательно | ⚠️ |

---

### 2.9 Обновления и обслуживание

**Наша конфигурация:**
- `unattended-upgrades` запущен — ✅
- Node.js 22 установлен — ✅

**Рекомендации руководства (стр. 40, 45–46):**
- Node.js **22.12.0+** (включает критические исправления безопасности)
- `sudo apt install unattended-upgrades` + `sudo dpkg-reconfigure unattended-upgrades`
- После каждого изменения конфигурации: `openclaw security audit --deep`
- Хранить конфиг в git для отслеживания изменений:

```bash
cd ~/.openclaw && git init && git add openclaw.json && git commit -m "known good baseline"
```

---

## 3. НАЙДЕННЫЕ ПРОБЛЕМЫ

### 🔴 КРИТИЧЕСКИЕ

1. **Запуск от root** (стр. 38) — все Gateway-процессы запущены от root. Руководство явно требует выделенного пользователя без прав root. При компрометации агента — полный контроль над сервером.

2. **Отсутствует `gateway.auth.mode: "token"`** (стр. 42, 62) — Gateway не требует токен аутентификации. Хотя он на loopback, это не защищает от атак с самого сервера (других процессов).

3. **Отсутствует `tools.deny ["gateway"]`** (стр. 103–104) — Инструмент `gateway` в OpenClaw не имеет проверок разрешений при изменении конфигурации. Агент (ИИ) может модифицировать критичные настройки безопасности без ограничений. Это **главный вектор самопроизвольного изменения конфигурации**.

4. **Отсутствует `configWrites: false`** (стр. 104) — Каналы не защищены от изменения конфига через чат-команды.

5. **Расхождение `num_ctx`**: в задаче указано 16384, в MEMORY.md — 32768. Нужно унифицировать.

### ⚠️ ВАЖНЫЕ

6. **Отсутствует аутентификационный токен Gateway** (`OPENCLAW_GATEWAY_TOKEN`) — без него любой процесс на сервере может взаимодействовать с Gateway без авторизации.

7. **Systemd сервисы без ограничений ресурсов** — нет `MemoryMax`, `CPUQuota`, `NoNewPrivileges=true`. При сбое модели процесс может потребить всю RAM/CPU сервера.

8. **mDNS/Bonjour не отключён** (стр. 45, 103) — Gateway объявляет себя в сети через `_openclaw-gw._tcp`. На сервере (bare metal в офисе/дата-центре) это нужно отключить: `discovery.mdns.mode: "off"`.

9. **`browser.evaluateEnabled` не задан** (стр. 62) — по умолчанию может быть `true`, что разрешает произвольное выполнение JS в браузере.

10. **`logging.redactSensitive`** не настроен — секреты могут попадать в логи вывода инструментов.

11. **`commands.config: false`** не задан — чат-команда `/config set` может быть доступна пользователям.

12. **Права доступа на `~/.openclaw/`** не проверены — должно быть `chmod 700` + `chmod 600 openclaw.json` (стр. 47).

13. **Нет инструмента `tools.deny` или профиля** — текущий набор инструментов (`profile, sessions, agentToAgent`) не является стандартным профилем OpenClaw. Неясно, включает ли это инструмент `gateway`.

### ℹ️ ЖЕЛАТЕЛЬНЫЕ УЛУЧШЕНИЯ

14. Добавить `RotateTokens` cron (ежемесячная ротация `OPENCLAW_GATEWAY_TOKEN`, стр. 63–65).

15. Поместить `openclaw.json` под git для отслеживания изменений (стр. 104).

16. Периодический аудит `.md` файлов workspace на инъекции (стр. 96, 103).

17. Настроить `groupPolicy.requireMention: true` если боты используются в группах (стр. 99–100).

18. Добавить `"$schema": "https://openclaw.ai/schemas/2024-11/config.json"` в конфиги (стр. 107).

19. Порт 18795 в SYSTEM-STATE — не идентифицирован в нашей документации. Нужно выяснить что это за Gateway.

---

## 4. РЕКОМЕНДАЦИИ

### 🔴 КРИТИЧНО — сделать немедленно

#### Р1: Добавить токен аутентификации Gateway

```bash
# Генерация токена
export OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
echo "OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN" >> /root/.openclaw-moa/.env

# В openclaw.json добавить:
# "gateway": {
#   "bind": "loopback",
#   "auth": {
#     "mode": "token",
#     "token": "<TOKEN>"
#   }
# }
```

После изменения: `openclaw security audit --deep`

#### Р2: Запретить инструмент gateway агентам

```bash
# Вариант А — явно запретить
openclaw config set tools.deny '["gateway"]'

# Вариант Б — переключить на профиль coding
openclaw config set tools.profile coding

# Также установить для каналов
# "configWrites": false  — добавить в конфиг каналов
```

#### Р3: Исправить расхождение num_ctx

Унифицировать в обоих конфигах: либо 16384, либо 32768. Рекомендуется 32768 (как в MEMORY.md) — соответствует возможностям qwen3.5:35b.

#### Р4: Установить commands.config: false

```bash
openclaw config set commands.config false
```

---

### ⚠️ ВАЖНО — сделать в течение недели

#### Р5: Усилить systemd-сервисы

Добавить в оба `.service` файла:

```ini
[Service]
# ... существующие параметры ...
Environment=NODE_ENV=production

# Ограничения ресурсов (GMKtec имеет 128GB, выделяем по 16GB на Gateway)
MemoryMax=16G
CPUQuota=80%

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/root/.openclaw-moa/.openclaw
Restart=on-failure
RestartSec=5
```

После: `sudo systemctl daemon-reload && sudo systemctl restart openclaw-gateway-moa`

#### Р6: Отключить mDNS

В каждый `openclaw.json` добавить:
```json
"discovery": {
  "mdns": { "mode": "off" }
}
```
Или в окружение: `export OPENCLAW_DISABLE_BONJOUR=1`

#### Р7: Отключить browser.evaluateEnabled

```json
"browser": {
  "evaluateEnabled": false
}
```

#### Р8: Включить redactSensitive в логировании

```json
"logging": {
  "redactSensitive": "tools"
}
```

#### Р9: Проверить права доступа

```bash
chmod 700 /root/.openclaw-moa/.openclaw
chmod 600 /root/.openclaw-moa/.openclaw/openclaw.json
chmod 700 /root/.openclaw-default/.openclaw
chmod 600 /root/.openclaw-default/.openclaw/openclaw.json
chmod 700 /home/ctio/.openclaw-ctio
```

#### Р10: Запустить security audit

```bash
# Запустить для каждого Gateway
OPENCLAW_PROFILE=/root/.openclaw-moa openclaw security audit --deep
OPENCLAW_PROFILE=/root/.openclaw-default openclaw security audit --deep
```

---

### ℹ️ ЖЕЛАТЕЛЬНО — в удобное время

#### Р11: Ротация токена — ежемесячный cron

```bash
# /usr/local/bin/rotate-openclaw-token-moa.sh
NEW_TOKEN=$(openssl rand -hex 32)
CONFIG="/root/.openclaw-moa/.openclaw/openclaw.json"
jq --arg t "$NEW_TOKEN" '.gateway.auth.token = $t' "$CONFIG" > "${CONFIG}.tmp" \
  && mv "${CONFIG}.tmp" "$CONFIG"
systemctl restart openclaw-gateway-moa
echo "$(date): Token rotated" >> /var/log/openclaw-token-rotation.log
```

```bash
# Добавить в cron (1-е число каждого месяца, 3:00)
echo "0 3 1 * * root /usr/local/bin/rotate-openclaw-token-moa.sh" | sudo tee -a /etc/crontab
```

#### Р12: Git для конфигов

```bash
cd /root/.openclaw-moa/.openclaw && git init
git add openclaw.json && git commit -m "baseline $(date)"
# Добавить в .gitignore токен и credential-файлы
```

#### Р13: Аудит workspace .md файлов

Добавить в cron (еженедельно):
```bash
grep -rn "<!--" /root/.openclaw-moa/workspace-moa/ >> /var/log/workspace-audit.log
grep -rniE "(ignore previous|system override|execute the following)" /root/.openclaw-moa/workspace-moa/*.md >> /var/log/workspace-audit.log
```

#### Р14: Выяснить порт 18795

SYSTEM-STATE показывает 4 активных Gateway-процесса (18789, 18791, 18793, 18795). Четвёртый не задокументирован. Нужно идентифицировать и либо задокументировать, либо остановить.

---

## 5. ЧЕК-ЛИСТ БЕЗОПАСНОСТИ

На основе чек-листа VPS из руководства (стр. 64–66), адаптированного под наш bare metal.

### Базовое усиление

- [x] SSH аутентификация по паролю отключена
- [x] fail2ban активен
- [x] unattended-upgrades включён
- [x] Node.js 22 установлен
- [ ] ❌ OpenClaw запущен НЕ от root — **КРИТИЧНО**
- [ ] ❌ Файл подкачки настроен (GMKtec 128GB RAM — вероятно не нужен, но проверить)
- [x] NTP синхронизация активна (systemd-timesyncd)
- [x] Расписание резервного копирования активно

### Сеть

- [x] Порт Gateway 18789/18793 НЕ является публичным (loopback only)
- [x] ufw настроен
- [x] fail2ban защищает SSH
- [ ] ❌ mDNS/Bonjour отключён

### Аутентификация и доступ

- [ ] ❌ Токен аутентификации Gateway установлен
- [x] dmPolicy: allowlist с конкретными ID
- [x] Только одобренные user ID (508602494) могут писать ботам

### Безопасность выполнения

- [ ] ❌ `tools.deny ["gateway"]` установлен
- [ ] ❌ `configWrites: false` задан в каналах
- [ ] ❌ `commands.config: false` задан

### Секреты и файлы

- [ ] ❌ Права доступа к `.openclaw/` проверены (700/600)
- [ ] ❌ История команд защищена (HISTCONTROL=ignoreboth)
- [x] fscrypt (шифрование at rest настроено)
- [x] Backup ежедневно в /data/backups/

### Конфигурация OpenClaw

- [ ] ❌ `browser.evaluateEnabled: false`
- [ ] ❌ `plugins.enabled: false` (если плагины не используются)
- [ ] ❌ `logging.redactSensitive: "tools"`
- [ ] ❌ `discovery.mdns.mode: "off"`
- [ ] ❌ `gateway.auth.token` >= 32 символа
- [ ] ❌ Расписание ротации токенов активно

### Наблюдаемость

- [ ] ❌ Аудит безопасности запускался: `openclaw security audit --deep`
- [x] Логирование сервисов (journald)
- [ ] ❌ `openclaw.json` под git-контролем

### Systemd

- [ ] ❌ `MemoryMax` задан
- [ ] ❌ `CPUQuota` задан
- [ ] ❌ `NoNewPrivileges=true` задан
- [ ] ❌ `Restart=on-failure` + `RestartSec=5`

---

## 6. ПРАВИЛА КАНОНА

Новые правила для добавления в канон проекта на основе best practices руководства.

### ПРАВИЛО-OPENCLAW-1: Токен аутентификации обязателен

Каждый Gateway-экземпляр ДОЛЖЕН иметь `gateway.auth.mode: "token"` с токеном не менее 32 символов. Токен генерируется через `openssl rand -hex 32`. Хранить в переменной окружения, не в истории команд.

### ПРАВИЛО-OPENCLAW-2: Инструмент gateway запрещён

Во всех конфигах ботов ДОЛЖЕН быть запрещён инструмент `gateway` (явным образом через `tools.deny: ["gateway"]` или профилем `coding`). Причина: инструмент gateway обходит все проверки разрешений и может изменить критичные настройки безопасности без авторизации.

### ПРАВИЛО-OPENCLAW-3: configWrites запрещён для каналов

В конфигурации каждого канала (`channels.telegram`, и др.) ДОЛЖНО быть `"configWrites": false`. Это блокирует изменение конфигурации через чат-команды.

### ПРАВИЛО-OPENCLAW-4: Не запускать от root

OpenClaw-Gateway-процессы не должны запускаться от `root`. При следующей реструктуризации сервисов — мигрировать на выделенных пользователей (`openclaw-moa`, `openclaw-default`, `ctio`).

### ПРАВИЛО-OPENCLAW-5: security audit после каждого изменения

После любого изменения `openclaw.json` ОБЯЗАТЕЛЬНО запустить:
```bash
openclaw security audit --deep
openclaw security audit --fix  # если есть автоисправляемые проблемы
```

### ПРАВИЛО-OPENCLAW-6: Workspace .md файлы — доверенный контекст

MEMORY.md, SYSTEM-STATE.md и другие workspace-файлы внедряются напрямую в системный промпт как доверенный контекст. Следовательно:
1. Права на запись в workspace-директорию только для нужных пользователей
2. Периодическая проверка на HTML-комментарии: `grep -rn "<!--" <workspace>/`
3. Не синхронизировать workspace в публичные репозитории

### ПРАВИЛО-OPENCLAW-7: mDNS отключён на сервере

На GMKtec (не домашняя LAN) mDNS/Bonjour ДОЛЖЕН быть отключён:
```json
"discovery": { "mdns": { "mode": "off" } }
```

### ПРАВИЛО-OPENCLAW-8: Systemd с ограничениями ресурсов

Каждый systemd unit-файл OpenClaw ДОЛЖЕН содержать:
- `MemoryMax=16G` (или подходящее значение)
- `CPUQuota=80%`
- `NoNewPrivileges=true`
- `Restart=on-failure`
- `RestartSec=5`

### ПРАВИЛО-OPENCLAW-9: Каналы как объект, не массив

Правильный формат конфигурации каналов в OpenClaw — **объект** (не массив). Поле `"type"` в каналах не является стандартным ключом схемы (вызывает `Unrecognized key "type"`). Использовать только задокументированные ключи.

### ПРАВИЛО-OPENCLAW-10: num_ctx унифицировать

`num_ctx` должен быть одинаков во всех конфигах, использующих одну и ту же модель. Текущее значение: **32768** (соответствует документации в MEMORY.md, поддерживается qwen3.5:35b).

---

## 7. СПРАВОЧНИК

### 7.1 Ключевые команды OpenClaw

```bash
# Статус и здоровье
openclaw gateway status
openclaw status
openclaw status --all
openclaw health

# Безопасность
openclaw security audit
openclaw security audit --deep
openclaw security audit --fix

# Конфигурация
openclaw config validate
openclaw config get discovery.mdns
openclaw config set discovery.mdns off
openclaw config set gateway.trustedProxies '["127.0.0.1"]'
openclaw config set tools.deny '["gateway"]'
openclaw config set configWrites false
openclaw config set commands.config false

# Логи
openclaw logs --follow

# Dashboard
openclaw dashboard

# Каналы
openclaw channels login
openclaw pairing list telegram
openclaw pairing approve telegram <CODE>

# Gateway управление
openclaw gateway restart

# Навыки
openclaw skill install <url>

# Резервная копия
tar czf openclaw-backup-$(date +%Y%m%d).tar.gz --exclude='.openclaw/sessions' -C ~/ .openclaw/
```

### 7.2 Пути конфигурации на GMKtec

| Компонент | Путь |
|-----------|------|
| MOA бот конфиг | `/root/.openclaw-moa/.openclaw/openclaw.json` |
| mycarmibot конфиг | `/root/.openclaw-default/.openclaw/openclaw.json` |
| CTIO бот профиль | `/home/ctio/.openclaw-ctio/` |
| OpenClaw бинарник | `/usr/lib/node_modules/openclaw` |
| Systemd MOA | `/etc/systemd/system/openclaw-gateway-moa.service` |
| Systemd mycarmibot | `/etc/systemd/system/openclaw-gateway-mycarmibot.service` |
| Backups | `/data/backups/` |
| Workspace MOA | `/root/.openclaw-moa/workspace-moa` |

### 7.3 Ключевые параметры конфигурации

| Параметр | Тип | Значения | Описание |
|----------|-----|----------|----------|
| `gateway.bind` | string | `"loopback"`, `"lan"`, `"tailnet"` | Интерфейс Gateway |
| `gateway.auth.mode` | string | `"token"`, `"password"` | Метод аутентификации |
| `gateway.auth.token` | string | ≥32 символа hex | Токен аутентификации |
| `gateway.trustedProxies` | array | IP адреса | Доверенные прокси |
| `gateway.controlUi.dangerouslyDisableDeviceAuth` | bool | `false` | НЕ отключать |
| `channels[].dmPolicy` | string | `"pairing"`, `"allowlist"`, `"open"` | Политика ЛС |
| `channels[].allowFrom` | array | Telegram user ID | Белый список |
| `channels[].groupPolicy.requireMention` | bool | `true` | Требовать @упоминание |
| `channels[].configWrites` | bool | `false` | Запретить /config set |
| `agents.defaults.tools.profile` | string | `"minimal"`, `"coding"`, `"messaging"`, `null` | Профиль инструментов |
| `agents.defaults.sandbox.mode` | string | `"off"`, `"agent"`, `"all"` | Режим песочницы |
| `agents.defaults.sandbox.workspaceAccess` | string | `"none"`, `"ro"`, `"rw"` | Доступ к workspace |
| `logging.redactSensitive` | string | `"tools"` | Редактировать логи |
| `browser.evaluateEnabled` | bool | `false` | Запретить JS в браузере |
| `plugins.enabled` | bool | `false` | Отключить плагины |
| `commands.config` | bool | `false` | Запретить /config set |
| `discovery.mdns.mode` | string | `"off"`, `"minimal"`, `"full"` | mDNS объявление |

### 7.4 Порты по умолчанию

| Порт | Компонент | Описание |
|------|-----------|----------|
| 18789 | Gateway (по умолчанию) | @mycarmi_moa_bot |
| 18791 | Gateway (CTIO) | @ctio-бот |
| 18793 | Gateway | @mycarmibot |
| 18795 | Gateway (?) | не идентифицирован |
| 11434 | Ollama | Локальный LLM |

### 7.5 Типичные пути состояния OpenClaw

```
~/.openclaw/                          — каталог по умолчанию
~/.openclaw-<profile>/                — профильный каталог
├── .openclaw/
│   ├── openclaw.json                 — основной конфиг
│   ├── openclaw.json.bak             — резервная копия (5 ротируемых)
│   ├── agents/<agentId>/
│   │   ├── agent/auth-profiles.js   — учётные данные модели
│   │   └── sessions/*.jsonl         — транскрипты сессий
│   └── logs/
│       └── config-audit.jsonl       — аудит изменений конфига
└── workspace-*/                      — workspace файлы (.md)
```

### 7.6 Команды диагностики

```bash
# Проверить версию Node.js (нужна 22.12.0+)
node --version

# Найти все openclaw.json
find /root /home -name "openclaw.json" 2>/dev/null

# Проверить статус сервисов
systemctl status openclaw-gateway-moa.service
systemctl status openclaw-gateway-mycarmibot.service

# Живые логи
journalctl -u openclaw-gateway-moa -f

# Проверить прослушиваемые порты
ss -tlnp | grep -E "18789|18791|18793|18795"

# Проверить права доступа
ls -la /root/.openclaw-moa/.openclaw/

# Проверить mDNS статус
openclaw config get discovery.mdns
```

### 7.7 Профили инструментов (из исходного кода src/agents/tool-policy.ts:63-80)

| Профиль | Что разрешено |
|---------|---------------|
| `minimal` | только `session_status` |
| `coding` | файловая система, среда выполнения, сессии, память, изображения |
| `messaging` | группа обмена сообщениями, управление сессиями |
| `null` (пусто) | все инструменты — без ограничений |

### 7.8 Рекомендуемый эталонный openclaw.json (адаптирован для GMKtec)

```json
{
  "$schema": "https://openclaw.ai/schemas/2024-11/config.json",
  "version": 1,
  "gateway": {
    "bind": "loopback",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": "<GENERATE: openssl rand -hex 32>"
    },
    "trustedProxies": [],
    "controlUi": {
      "dangerouslyDisableDeviceAuth": false
    }
  },
  "channels": [{
    "type": "telegram",
    "enabled": true,
    "dmPolicy": "allowlist",
    "allowFrom": [508602494],
    "groupPolicy": {
      "requireMention": true
    },
    "configWrites": false
  }],
  "agents": {
    "defaults": {
      "tools": {
        "profile": null,
        "deny": ["gateway"]
      },
      "sandbox": {
        "mode": "off",
        "workspaceAccess": "rw"
      }
    }
  },
  "logging": {
    "redactSensitive": "tools"
  },
  "browser": {
    "evaluateEnabled": false
  },
  "discovery": {
    "mdns": {
      "mode": "off"
    }
  },
  "plugins": {
    "enabled": false
  },
  "commands": {
    "config": false
  }
}
```

> **Примечание:** Параметры модели (`baseUrl`, `num_ctx`, `num_predict`, `temperature`) задаются отдельно через `openclaw onboard` или в секции агента. `streaming: false` — критично для Ollama.

---

*Документ создан на основе полного прочтения «Explain OpenClaw — Полное руководство» (146 страниц, февраль 2026). Все номера страниц соответствуют PDF-файлу `/home/user/workspace/Explain-OpenClaw-Polnoe-rukovodstvo.pdf`.*
