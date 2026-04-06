# DEV — Модуль разработчика BANXE

**Профиль:** DEV (активен для BANXE / developer-core проектов)  
**Репозитории:** vibe-coding, developer-core, banxe-architecture  
**Статус:** PRIMARY для текущего терминала

---

## 1. Архитектурные ориентиры

### Единые источники истины

| Артефакт | Где находится | Назначение |
|----------|---------------|------------|
| Инварианты | `banxe-architecture/INVARIANTS.md` | I-01..I-25 — неизменяемые правила системы |
| GAP-REGISTER | `banxe-architecture/GAP-REGISTER.md` | Реестр архитектурных пробелов (v7, 22/22 addressed) |
| Compliance thresholds | `src/compliance/compliance_config.yaml` | Пороги решений (не хардкодить в Python) |
| Change classes | `banxe-architecture/governance/change-classes.yaml` | CLASS_A/B/C/D — кто и как одобряет |
| Trust zones | `banxe-architecture/governance/trust-zones.yaml` | RED/AMBER/GREEN зоны |
| Agent passports | `banxe-architecture/agents/passports/*.yaml` | 9 паспортов агентов (KPMG AIGF) |
| Test baseline | 747 тестов (2026-04-06) | Не допускать регрессии |

---

## 2. Инварианты (критические)

Не нарушать никогда. Каждый инвариант защищён hooks:

| ID | Правило | Enforcement |
|----|---------|-------------|
| I-21 | Агент не изменяет SOUL.md/AGENTS.md без GOVERNANCE_BYPASS | policy_guard.py |
| I-22 | PolicyPort только read — нет write-методов | bounded_context_check.py |
| I-23 | Emergency stop проверяется до каждого решения | invariant_check.py |
| I-24 | Audit log append-only (PostgreSQL REVOKE UPDATE/DELETE) | DB-level |
| I-25 | ExplanationBundle обязателен для решений > £10K | invariant_check.py |

---

## 3. Orchestration Tree — доверие между агентами

Правила из `agents/orchestration_tree.py`:

```
B-01: Level-2 не может обращаться к Level-1 напрямую (BLOCKED)
B-02: Level-3 не может обращаться к Level-1 (BLOCKED)
B-03: Level-3 → Level-2 BLOCKED (только через Ports)
B-04: RED zone → GREEN zone BLOCKED
B-05: AMBER → GREEN = WARNING
B-06: policy_write для Level-2/3 BLOCKED (→ I-22)
```

Уровни агентов:
- **Level-1**: banxe_aml_orchestrator (оркестратор)
- **Level-2**: aml_orchestrator, sanctions_check, tx_monitor, crypto_aml
- **Level-3**: watchman_adapter, jube_adapter, yente_adapter, clickhouse_writer

---

## 4. Compliance Decision Stack

```
PreTxGate (G-09)              ← Redis, <80ms, fail-open
    ↓ PASS/ESCALATE
OPASidecar (G-14)             ← I-22/I-23/I-25 enforcement, fail-closed
    ↓ ALLOW
banxe_aml_orchestrator        ← Level-1, Layer-1+2 assessment
    ↓
DecisionPort → AuditPort      ← Ports & Adapters (G-16)
    ↓
PostgreSQL decision_events    ← Append-only (I-24)
```

---

## 5. Governance Gates

### CLASS_A — автоматически (DEVELOPER → CI)
- Код, тесты, утилиты, документация
- Requires: CI pass

### CLASS_B — человек обязателен (MLRO + CEO)
- SOUL.md, AGENTS.md, IDENTITY.md, openclaw.json
- GOVERNANCE_BYPASS=1 + approver name

### CLASS_C — MLRO (compliance config)
- compliance_config.yaml, *.rego, change-classes.yaml
- GOVERNANCE_BYPASS=1 + MLRO approval

### CLASS_D — CEO + CTIO (архитектура)
- ADR-*.md, INVARIANTS.md, GAP-REGISTER.md, schemas/*.json
- Оба должны одобрить

---

## 6. Стандарты разработки

### Тесты
- Каждая новая функция → ≥ 20 тестов (паттерн T-01..T-NN)
- Тесты в `test_*.py` рядом с кодом
- Baseline 747 — не допускать регрессии: `pytest --no-cov -q`
- TTL-тесты: `time.sleep(1.1)` для проверки TTL=1s

### Коммиты
```
feat(scope): краткое описание — N tests

Детали реализации.
Closes: G-XX (ссылка на GAP)

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

### Импорты
- `from compliance.xxx import yyy` (всегда через полный путь)
- Нет relative imports в production code
- `pythonpath = ["src"]` в pyproject.toml

### Fail-open vs fail-closed
- Pre-tx gate (Redis) → **fail-open** (ESCALATE) — не блокировать бизнес
- OPA Sidecar → **fail-closed** (DENY) — безопасность важнее
- Vault fallback → **fail-open** (InMemory) — не блокировать auth

---

## 7. Инфраструктура GMKtec

| Сервис | Порт | Назначение |
|--------|------|------------|
| Redis | 6379 | Pre-tx gate, velocity tracking, blocked jurisdictions |
| ClickHouse | 9000 | Audit trail, analytics |
| PostgreSQL | 5432 | decision_events (Docker PG17) |
| FastAPI | 8090 | Compliance REST API |
| Watchman | 8084 | Sanctions screening (OSS) |
| Jube | 5001 | Crypto AML |
| Ollama | 11434 | LLM (qwen3.5-abliterated:35b) |

SSH алиас: `gmktec` (Legion → GMKtec, порт 2222)

---

## 8. Запрещено в dev-контексте

- Хардкодить compliance thresholds в Python (→ compliance_config.yaml)
- Создавать Level-3 агентов с EMIT_DECISION/APPEND_AUDIT scope (ZSP-01)
- Модифицировать decision_events (только INSERT — I-24)
- Байпасить pre-commit hooks без явного разрешения
- Деплоить напрямую на GMKtec без скрипта в `scripts/`
