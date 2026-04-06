# VERIFICATION-CANON.md
# Канон верификации кода — Banxe AI Bank

> **Последнее обновление:** 2026-03-29  
> **Автор:** ctio (Олег)  
> **Статус:** ОБЯЗАТЕЛЕН к исполнению

---

## 1. ПОЗИЦИЯ

Banxe — это EMI под надзором FCA. Это не стартап-эксперимент, где можно разобраться постфактум. Здесь:

- **Деньги клиентов** — любой баг в платёжной логике = прямой финансовый ущерб
- **Регуляторные обязательства** — FCA требует audit trail, контроля изменений, evidence of testing
- **AI-генерируемый код** — бот пишет скрипты через Ollama; если нет верификации, в прод идёт непроверенный код

Верификация — это не «хорошая практика». Это инфраструктурный элемент, без которого работа бота с кодовой базой недопустима.

**Правило**: код, написанный AI без независимой проверки, не существует для проекта. Он существует только после прохождения верификации.

---

## 2. ПРИНЦИПЫ

### 2.1 ИИ проверяет ИИ

Бот (OpenClaw, порт 18789/18793) генерирует код через Ollama (11434). Тот же бот **не может** быть верификатором своего же кода — конфликт интересов на уровне архитектуры.

Верификаторы — отдельные инструменты с независимой логикой:
- **Semgrep** — статические правила, детерминированные, не зависят от LLM
- **CodeRabbit** — отдельная AI-модель, не Ollama, не тот же контекст
- **CodeQL** — семантический анализ на уровне GitHub, полностью независим

Схема:
```
Ollama (генератор) → код → Semgrep + Snyk + CodeRabbit (верификаторы) → прод
```

Бот узнаёт о результатах верификации через MEMORY.md и ctio-watcher — но **не управляет** процессом верификации.

### 2.2 Детерминизм + AI

Одного AI-ревью недостаточно — AI может пропустить то, что пропустил при генерации. Одних статических правил недостаточно — они не понимают контекст.

Связка:
- **Semgrep** → детерминированные правила (секреты, SQL-инъекции, небезопасные паттерны)
- **CodeRabbit** → понимание бизнес-логики, архитектурные проблемы
- **CodeQL** → семантический анализ потоков данных, сложные уязвимости

### 2.3 Тесты как дискриминатор

Для финтеха тест — это не покрытие ради метрики. Тест — это доказательство для FCA, что функция работает как заявлено.

Приоритеты тестирования:
1. **KYC** — верификация документов, пороги проверки
2. **AML** — правила мониторинга транзакций, триггеры
3. **Payments** — расчёты, лимиты, маршрутизация
4. **Auth/Access** — разграничение прав root/banxe/ctio

Тесты генерирует Qodo/Aider для критичных функций, но **проверяет и принимает** человек (ctio).

---

## 3. АРХИТЕКТУРА ВЕРИФИКАЦИИ

```
┌─────────────────────────────────────────────────────────────┐
│                     GMKtec EVO-X2                           │
│                                                             │
│  Разработка / генерация кода (Ollama + бот)                │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────────┐                                        │
│  │   УРОВЕНЬ 1     │  При каждом изменении файла            │
│  │   Semgrep       │  (мгновенно, локально)                 │
│  └────────┬────────┘                                        │
│           │ pass                                            │
│           ▼                                                 │
│  ┌─────────────────┐                                        │
│  │   УРОВЕНЬ 2     │  Pre-commit hook перед git push        │
│  │  Semgrep + Snyk │  (секунды, блокирует пуш)              │
│  └────────┬────────┘                                        │
│           │ pass                                            │
└───────────┼─────────────────────────────────────────────────┘
            │ git push → GitHub
            ▼
┌─────────────────────────────────────────────────────────────┐
│                       GitHub                                │
│                                                             │
│  ┌─────────────────────────────────────┐                   │
│  │           УРОВЕНЬ 3                 │                   │
│  │  CodeRabbit (AI review on PR)       │                   │
│  │  CodeQL (semantic analysis)         │                   │
│  │  → результаты → MEMORY.md бота      │                   │
│  └─────────────────────────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

### Уровень 1 — Мгновенная проверка (локально, GMKtec)

**Когда:** при сохранении/изменении любого скрипта  
**Инструмент:** Semgrep  
**Время:** < 5 секунд  
**Блокирует:** нет (предупреждение)  

Что проверяется:
- Хардкод секретов (ключи API, пароли, токены)
- Небезопасные паттерны bash (eval, unquoted vars)
- Прямые SQL-запросы без параметризации (ClickHouse на 9000)
- Небезопасный HTTP вместо HTTPS
- Отладочный код (console.log с чувствительными данными)

### Уровень 2 — Pre-commit (GMKtec перед пушем)

**Когда:** git commit  
**Инструменты:** Semgrep + Snyk  
**Время:** 10–30 секунд  
**Блокирует:** да, если найдены критичные проблемы  

Что проверяется дополнительно:
- Snyk: уязвимости в зависимостях (npm/pip пакеты)
- Semgrep расширенные правила: финтех-специфичные паттерны
- Проверка secrets в staged-файлах

### Уровень 3 — PR-проверка (GitHub)

**Когда:** открытие/обновление Pull Request  
**Инструменты:** CodeRabbit + CodeQL  
**Время:** 2–5 минут  
**Блокирует:** merge до получения апрува  

Что проверяется:
- **CodeRabbit:** логика, архитектура, соответствие бизнес-требованиям, безопасность
- **CodeQL:** семантика потоков данных, инъекции, path traversal, deserialization
- Результаты автоматически записываются в MEMORY.md через ctio-watcher

---

## 4. УСТАНОВКА

### setup-verification.sh

Единый скрипт устанавливает всё верификационное окружение на GMKtec. Запускается однократно (или при смене окружения).

```bash
#!/bin/bash
# setup-verification.sh
# Устанавливает верификационное окружение для Banxe AI Bank
# Запускать на GMKtec от root или ctio с sudo

set -euo pipefail

REPO_DIR="/home/banxe/vibe-coding"
LOG_FILE="/var/log/banxe/setup-verification.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        echo "Нужны права sudo. Запусти от root или ctio."
        exit 1
    fi
}

# ─── Semgrep ───────────────────────────────────────────────────────────────
install_semgrep() {
    log "Устанавливаю Semgrep..."
    pip3 install semgrep --quiet
    semgrep --version
    
    # Создаём конфиг для проекта
    mkdir -p "$REPO_DIR/.semgrep"
    cat > "$REPO_DIR/.semgrep/banxe-rules.yml" << 'SEMGREP_RULES'
rules:
  - id: banxe-hardcoded-secret
    patterns:
      - pattern: |
          $KEY = "..."
    message: "Возможный хардкод секрета в переменной $KEY"
    languages: [javascript, python, bash]
    severity: ERROR
    metadata:
      category: security
      
  - id: banxe-no-http-in-fintech
    pattern: |
      http://...
    message: "HTTP недопустим — используй HTTPS"
    languages: [javascript, python, bash]
    severity: ERROR
    
  - id: banxe-clickhouse-injection
    patterns:
      - pattern: |
          "SELECT ... " + $VAR
      - pattern: |
          `SELECT ... ${$VAR}`
    message: "Возможная SQL-инъекция в ClickHouse запросе"
    languages: [javascript, python]
    severity: ERROR
    
  - id: banxe-unsafe-eval
    pattern: eval($X)
    message: "eval() недопустим в продакшн коде"
    languages: [javascript]
    severity: ERROR
SEMGREP_RULES
    log "Semgrep установлен, правила созданы в .semgrep/banxe-rules.yml"
}

# ─── Snyk ──────────────────────────────────────────────────────────────────
install_snyk() {
    log "Устанавливаю Snyk..."
    npm install -g snyk --quiet
    snyk --version
    log "Snyk установлен. Авторизуй через: snyk auth"
    log "Или установи SNYK_TOKEN в /etc/banxe/secrets.env"
}

# ─── CodeRabbit CLI ────────────────────────────────────────────────────────
install_coderabbit() {
    log "Устанавливаю CodeRabbit CLI..."
    npm install -g coderabbit-cli --quiet
    log "CodeRabbit CLI установлен"
    log "Добавь CODERABBIT_API_KEY в /etc/banxe/secrets.env"
}

# ─── Pre-commit hooks ──────────────────────────────────────────────────────
setup_precommit() {
    log "Настраиваю pre-commit hooks..."
    pip3 install pre-commit --quiet
    
    cat > "$REPO_DIR/.pre-commit-config.yaml" << 'PRECOMMIT'
repos:
  - repo: local
    hooks:
      - id: semgrep-banxe
        name: Semgrep — Banxe правила
        entry: semgrep --config .semgrep/banxe-rules.yml --error
        language: system
        types: [file]
        pass_filenames: true
        
      - id: semgrep-secrets
        name: Semgrep — сканирование секретов
        entry: semgrep --config "p/secrets" --error
        language: system
        types: [file]
        pass_filenames: true

      - id: snyk-audit
        name: Snyk — проверка зависимостей
        entry: bash -c 'cd "$REPO_DIR" && snyk test --severity-threshold=high'
        language: system
        pass_filenames: false
        stages: [commit]
PRECOMMIT

    cd "$REPO_DIR" && pre-commit install
    log "Pre-commit hooks установлены"
}

# ─── GitHub Actions ────────────────────────────────────────────────────────
setup_github_actions() {
    log "Создаю GitHub Actions workflows..."
    mkdir -p "$REPO_DIR/.github/workflows"

    # CodeQL
    cat > "$REPO_DIR/.github/workflows/codeql.yml" << 'CODEQL'
name: CodeQL Analysis

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  analyze:
    name: Analyze
    runs-on: ubuntu-latest
    permissions:
      actions: read
      contents: read
      security-events: write

    strategy:
      fail-fast: false
      matrix:
        language: [javascript, python]

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Initialize CodeQL
        uses: github/codeql-action/init@v3
        with:
          languages: ${{ matrix.language }}
          queries: security-extended

      - name: Autobuild
        uses: github/codeql-action/autobuild@v3

      - name: Perform CodeQL Analysis
        uses: github/codeql-action/analyze@v3
        with:
          category: "/language:${{ matrix.language }}"
CODEQL

    # CodeRabbit конфиг
    cat > "$REPO_DIR/.coderabbit.yaml" << 'CODERABBIT'
language: ru
reviews:
  profile: assertive
  request_changes_workflow: true
  high_level_summary: true
  poem: false
  review_status: true
  collapse_walkthrough: false
  auto_review:
    enabled: true
    drafts: false
  path_filters:
    - "!**/*.lock"
    - "!**/node_modules/**"
  path_instructions:
    - path: "**/*.js"
      instructions: |
        Это финтех проект (EMI, FCA). Проверь:
        - Нет хардкод секретов и ключей
        - Все финансовые расчёты используют Decimal, не float
        - Валидация всех входящих данных от внешних систем
        - Логирование без PII в открытом виде
    - path: "**/kyc/**"
      instructions: |
        KYC-модуль: особое внимание к обработке персональных данных,
        соответствию GDPR, правилам верификации документов
    - path: "**/aml/**"
      instructions: |
        AML-модуль: проверь корректность пороговых значений,
        логику репортинга, отсутствие обходных путей
    - path: "**/*.sh"
      instructions: |
        Bash-скрипт: проверь set -euo pipefail, кавычки вокруг переменных,
        отсутствие eval(), безопасность sudo-вызовов
chat:
  auto_reply: true
CODERABBIT

    log "GitHub Actions workflows созданы"
}

# ─── Semgrep финтех-правила ────────────────────────────────────────────────
setup_fintech_rules() {
    log "Добавляю финтех-специфичные правила Semgrep..."
    
    cat >> "$REPO_DIR/.semgrep/banxe-rules.yml" << 'FINTECH_RULES'

  - id: banxe-float-money
    patterns:
      - pattern: $AMOUNT = $X * $Y
      - pattern: parseFloat($AMOUNT)
    message: |
      Финансовые расчёты через float недопустимы.
      Используй Decimal (Python) или специализированные библиотеки.
    languages: [javascript, python]
    severity: ERROR

  - id: banxe-log-pii
    patterns:
      - pattern: console.log(..., $PAN, ...)
      - pattern: console.log(..., $IBAN, ...)
      - pattern: logger.info(..., $CARD, ...)
    message: "Возможна утечка PII в логах — проверь вручную"
    languages: [javascript]
    severity: WARNING

  - id: banxe-no-plain-password
    patterns:
      - pattern: password = $X
      - pattern: passwd = $X
      - pattern: secret = $X
    message: "Не храни пароли/секреты в переменных с предсказуемыми именами"
    languages: [javascript, python, bash]
    severity: WARNING
FINTECH_RULES
    log "Финтех-правила добавлены"
}

# ─── Статус ────────────────────────────────────────────────────────────────
print_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  СТАТУС ВЕРИФИКАЦИОННОГО ОКРУЖЕНИЯ — Banxe AI Bank"
    echo "═══════════════════════════════════════════════════════"
    
    check_tool() {
        if command -v "$1" &>/dev/null; then
            echo "  ✓ $1 — $(command -v "$1")"
        else
            echo "  ✗ $1 — НЕ УСТАНОВЛЕН"
        fi
    }
    
    check_tool semgrep
    check_tool snyk
    check_tool coderabbit
    check_tool pre-commit
    
    echo ""
    echo "  Конфиги:"
    [ -f "$REPO_DIR/.semgrep/banxe-rules.yml" ]     && echo "  ✓ .semgrep/banxe-rules.yml" || echo "  ✗ .semgrep/banxe-rules.yml"
    [ -f "$REPO_DIR/.pre-commit-config.yaml" ]       && echo "  ✓ .pre-commit-config.yaml"  || echo "  ✗ .pre-commit-config.yaml"
    [ -f "$REPO_DIR/.github/workflows/codeql.yml" ]  && echo "  ✓ .github/workflows/codeql.yml" || echo "  ✗ codeql.yml"
    [ -f "$REPO_DIR/.coderabbit.yaml" ]              && echo "  ✓ .coderabbit.yaml" || echo "  ✗ .coderabbit.yaml"
    
    echo ""
    echo "  Следующие шаги:"
    echo "  1. snyk auth                     ← авторизация Snyk"
    echo "  2. Добавить CODERABBIT_API_KEY    ← в /etc/banxe/secrets.env"
    echo "  3. Включить CodeRabbit в GitHub   ← github.com/marketplace/coderabbit"
    echo "  4. git add . && git commit        ← протестировать pre-commit"
    echo "═══════════════════════════════════════════════════════"
}

# ─── Main ──────────────────────────────────────────────────────────────────
main() {
    check_root
    mkdir -p "$(dirname "$LOG_FILE")"
    
    log "=== Начало установки верификационного окружения ==="
    
    install_semgrep
    install_snyk
    install_coderabbit
    setup_precommit
    setup_github_actions
    setup_fintech_rules
    
    log "=== Установка завершена ==="
    print_status
}

main "$@"
```

---

## 5. КАНОН — Новые правила

Следующие правила добавляются в общий канон проекта и обязательны для всех участников (root, banxe, ctio) и для бота.

### 5.1 Правило: каждый скрипт проверяется Semgrep перед пушем

```bash
# Проверка одного скрипта
semgrep --config .semgrep/banxe-rules.yml --config "p/secrets" <файл>

# Проверка всего репозитория
semgrep --config .semgrep/banxe-rules.yml --config "p/secrets" .

# Критичные результаты (ERROR) блокируют пуш автоматически через pre-commit
```

**Исключений нет.** Если скрипт срочный — исправь проблему, не обходи проверку.

### 5.2 Правило: каждый PR проверяется CodeRabbit автоматически

- CodeRabbit комментирует PR автоматически при открытии
- Merge в `main` невозможен без апрува CodeRabbit (настраивается в Branch Protection Rules)
- Комментарии CodeRabbit = технический долг, который нужно закрыть или обоснованно отклонить

### 5.3 Правило: секреты сканируются при каждом коммите

Pre-commit hook запускает `semgrep --config "p/secrets"` на staged-файлах.

Если Semgrep нашёл потенциальный секрет:
1. Убедись, что это не ложное срабатывание
2. Если реальный секрет — **немедленно** ротируй его, даже если коммит не прошёл
3. Добавь в `.semgrepignore` только после подтверждения ложного срабатывания

### 5.4 Правило: тесты для критичных функций

Области обязательного тестирования:

| Область | Инструмент | Минимальное покрытие |
|---------|-----------|---------------------|
| KYC — верификация документов | Qodo + ручные тесты | Все ветви логики |
| AML — мониторинг транзакций | Qodo + ручные тесты | Все пороговые значения |
| Payments — расчёты и маршрутизация | Qodo + ручные тесты | Граничные случаи |
| Auth — разграничение прав | Ручные тесты | Все роли (root/banxe/ctio) |

Генерация тестов:
```bash
# Qodo для JS
qodo generate --path src/kyc/verifier.js

# Aider для Python
aider --test --file src/aml/monitor.py
```

Тесты, сгенерированные AI, **проверяются ctio** перед коммитом.

### 5.5 Правило: результаты верификации пишутся в MEMORY.md бота

Каждый значимый результат верификации фиксируется:

```markdown
## Верификация [дата]
- Инструмент: Semgrep / CodeRabbit / CodeQL
- Файл/PR: <ссылка>
- Найдено: <краткое описание>
- Статус: исправлено / принято / отклонено (ложное срабатывание)
- Действие: <что было сделано>
```

Бот использует MEMORY.md для:
- Понимания паттернов ошибок в своём коде
- Избегания повторения тех же проблем при генерации
- Формирования контекста для Compliance-агента

---

## 6. ИНТЕГРАЦИЯ С БОТОМ

### 6.1 ctio-watcher и отчёты верификации

ctio-watcher отслеживает директорию с отчётами верификации и публикует события:

```
/home/banxe/vibe-coding/reports/verification/
├── semgrep-YYYY-MM-DD.json
├── snyk-YYYY-MM-DD.json
└── coderabbit-pr-<N>.json
```

Конфигурация watcher для верификации:
```bash
# Добавить в конфиг ctio-watcher
WATCH_PATHS="/home/banxe/vibe-coding/reports/verification"
ON_CHANGE="node /home/banxe/vibe-coding/scripts/process-verification-report.js"
```

Скрипт `process-verification-report.js` парсит отчёт и:
1. Формирует краткое summary
2. Добавляет запись в MEMORY.md
3. Если severity=CRITICAL → отправляет уведомление ctio через бота

### 6.2 Обучение бота на найденных уязвимостях

Когда верификация находит проблему в коде, сгенерированном ботом:

```
[Найдена проблема] → [ctio помечает как "от бота"] → [запись в MEMORY.md]
     ↓
[Бот читает MEMORY.md при следующей сессии]
     ↓
[Системный промпт обновляется: "не повторяй паттерн X"]
```

Файл паттернов ошибок бота:
```
/home/banxe/vibe-coding/docs/BOT-ERROR-PATTERNS.md
```

Обновляется вручную ctio при накоплении 3+ однотипных ошибок.

### 6.3 Compliance-агент и аудит

Агент Compliance (n8n на 5678) использует результаты верификации для:

**Автоматически:**
- Агрегация статистики по типам находок
- Построение timeline: когда появилась уязвимость, когда исправлена
- Генерация отчёта по требованию FCA

**Workflow в n8n:**
```
Webhook (новый отчёт верификации)
  → Parse JSON
  → Фильтр по severity
  → Обновить ClickHouse (9000) таблицу banxe_compliance.verification_log
  → Если CRITICAL → уведомить ctio
  → Обновить MEMORY.md
```

**Таблица ClickHouse для аудита:**
```sql
CREATE TABLE banxe_compliance.verification_log (
    ts          DateTime DEFAULT now(),
    tool        String,          -- semgrep / snyk / coderabbit / codeql
    severity    String,          -- INFO / WARNING / ERROR / CRITICAL
    file        String,
    rule_id     String,
    message     String,
    pr_number   Nullable(UInt32),
    resolved    UInt8 DEFAULT 0,
    resolved_by String DEFAULT ''
) ENGINE = MergeTree()
ORDER BY (ts, severity);
```

Этот лог — доказательная база для FCA, что все изменения проходили контроль.

---

## БЫСТРЫЙ СТАРТ

```bash
# 1. Установить всё на GMKtec
ssh banxe@gmktec "bash /home/banxe/vibe-coding/scripts/setup-verification.sh"

# 2. Авторизовать Snyk
ssh banxe@gmktec "snyk auth"

# 3. Включить CodeRabbit в репозитории
# → github.com/marketplace/coderabbit → Install → CarmiBanxe/vibe-coding

# 4. Настроить Branch Protection для main
# → GitHub → Settings → Branches → main → Require PR reviews: CodeRabbit

# 5. Проверить первый коммит
ssh banxe@gmktec "cd /home/banxe/vibe-coding && git add . && git commit -m 'test: verification setup'"
```

---

*VERIFICATION-CANON.md — часть общего канона Banxe AI Bank. Не обходить, не отключать без согласования с ctio.*
