# HITL Dashboard — Technical Specification

**Status:** SPEC — pending implementation  
**Priority:** Next technical sprint (after Sprint 9)  
**Version:** 1.0 | 2026-04-06

---

## Назначение

Human-In-The-Loop Dashboard — центральный интерфейс для CEO и CTIO.

Позволяет:
- Просматривать очередь решений, ожидающих человеческого одобрения
- Одобрять / отклонять / эскалировать AI-решения
- Видеть статистику агентов (accuracy, drift, false positive rate)
- FCA audit trail — каждое решение с объяснением и подписью

---

## Архитектура

```
┌─────────────────────────────────────────────────┐
│            HITL Dashboard (React/Next.js)        │
│  Порт: :5100 (предлагаемый)                     │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐   │
│  │ Queue    │  │ Stats    │  │ Audit Trail  │   │
│  │ /approve │  │ /agents  │  │ /audit       │   │
│  └──────────┘  └──────────┘  └──────────────┘   │
└─────────────────────────────────────────────────┘
         │              │              │
         ▼              ▼              ▼
   FastAPI :8093   ClickHouse     OpenClaw bots
   (compliance)    banxe.audit    (18789/91/93)
                   _trail
```

---

## Функциональные требования

### 1. Queue (очередь HITL решений)

| Поле | Тип | Описание |
|------|-----|----------|
| `decision_id` | UUID | Уникальный ID решения |
| `risk_level` | MEDIUM / HIGH | Уровень риска |
| `agent` | string | Какой агент создал запрос |
| `summary` | string | Краткое описание (1-2 строки) |
| `explanation` | ExplanationBundle | XAI объяснение (EU AI Act Art.13) |
| `created_at` | timestamp | Время создания |
| `deadline` | timestamp | Deadline для ответа (SLA) |
| `actions` | approve / reject / escalate | Кнопки действия |

**Фильтры:** по risk_level, по агенту, по дате, по статусу

### 2. Agent Stats

| Метрика | Источник | Порог алерта |
|---------|---------|--------------|
| Accuracy | promptfoo eval results | < 85% |
| Drift | Evidently AI | > 0.15 |
| False positive rate | ClickHouse audit_trail | > 10% |
| Avg response time | ClickHouse | > 5s |
| HITL escalation rate | ClickHouse | > 20% |

### 3. Audit Trail

- Все решения из `banxe.audit_trail` ClickHouse
- Фильтрация: по агенту, дате, юрисдикции, решению
- Экспорт: CSV / JSON для FCA
- Каждая запись: `decision_id`, `agent`, `input`, `output`, `explanation`, `human_reviewer`, `timestamp`

---

## Технический стек

| Компонент | Выбор | Обоснование |
|---|---|---|
| Frontend | React + Vite (как Marble) | Уже установлен, команда знает |
| Backend | Расширение FastAPI :8093 | Уже работает, избегаем новый порт |
| БД | ClickHouse banxe.hitl_queue | FCA audit compliance, TTL 5Y |
| Auth | Firebase emulator (как Marble) | Уже деплоен на :4000 |
| WebSocket | для live queue updates | react-query + WS endpoint |

---

## API endpoints (расширение :8093)

```
GET  /hitl/queue               — активные HITL решения
GET  /hitl/queue/{id}          — детали решения
POST /hitl/queue/{id}/approve  — одобрить
POST /hitl/queue/{id}/reject   — отклонить
POST /hitl/queue/{id}/escalate — эскалировать
GET  /hitl/stats               — статистика агентов
GET  /hitl/audit               — audit trail (с фильтрами)
WS   /hitl/stream              — live updates очереди
```

---

## ClickHouse схема (новая таблица)

```sql
CREATE TABLE banxe.hitl_queue (
    decision_id       UUID,
    risk_level        Enum8('LOW'=0, 'MEDIUM'=1, 'HIGH'=2),
    agent             String,
    summary           String,
    explanation_json  String,   -- ExplanationBundle JSON
    created_at        DateTime,
    deadline          DateTime,
    status            Enum8('pending'=0, 'approved'=1, 'rejected'=2, 'escalated'=3),
    reviewed_by       String,   -- email reviewer
    reviewed_at       DateTime,
    review_note       String
) ENGINE = MergeTree()
ORDER BY (created_at, risk_level)
TTL created_at + INTERVAL 5 YEAR;
```

---

## Telegram интеграция (MVP)

До реализации полного дашборда — уведомления через OpenClaw бот:

```
🔴 HIGH RISK — HITL Required
Agent: compliance-checker
Decision: KYC onboarding — Mark Johnson, UK
Risk score: 72/100
Summary: PEP match detected (confidence 0.76)
→ /approve_7f3a | /reject_7f3a | /details_7f3a
```

Кнопки InlineKeyboard → webhook → POST /hitl/queue/{id}/approve

---

## MVP Definition (минимальный sprint)

1. ClickHouse таблица `hitl_queue`
2. FastAPI endpoints GET /hitl/queue + POST /hitl/{id}/{action}
3. Telegram bot команды: `/hitl`, `/approve`, `/reject`
4. Интеграция с compliance/api.py — MEDIUM/HIGH решения → hitl_queue
5. Простой React view (можно начать с Marble component library)

**НЕ в MVP:** full dashboard, WebSocket, agent stats, export

---

## HITL SLA (FCA требования)

| Risk level | SLA | Действие при просрочке |
|---|---|---|
| MEDIUM | 4 часа | Auto-escalate to CTIO |
| HIGH | 1 час | Auto-escalate to CEO + CTIO |
| Sanctions hit | Немедленно | Block + auto-SAR |

---

## Связанные файлы

- `src/compliance/api.py` — добавить hitl_queue интеграцию
- `docs/MEMORY.md` — HITL checkpoint правила
- `banxe-architecture/INVARIANTS.md` — Invariant #7 (HITL)
- `docs/GAP-6-AUTORESEARCH.md` — autoresearch → HITL оптимизация thresholds
