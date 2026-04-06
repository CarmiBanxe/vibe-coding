# CANON — Операционная система правил

**Версия:** 1.0 (2026-04-06)  
**Репозиторий:** `developer-core/canon/`  
**Основа:** CORE_CANON v5.1.8a (адаптировано под WSL + Claude Code)

---

## Что такое CANON

CANON — это набор правил, протоколов и профилей, управляющих поведением AI-агентов
во всех проектах CarmiBanxe. Он определяет: как AI взаимодействует с пользователем,
как агенты коллаборируют, как принимаются решения, и что нельзя делать никогда.

---

## Структура

```
canon/
├── CANON.md           ← этот файл: индекс + маршрутизатор
├── modules/
│   ├── CORE.md        ← Ядро (всегда активно)
│   ├── DOC.md         ← Документный профиль
│   ├── LEGAL.md       ← Юридический профиль (off для dev-проектов)
│   ├── DECISION.md    ← Модуль принятия решений
│   ├── DEV.md         ← BANXE-специфичный (on для dev-проектов)
│   └── FR_MODULE.md   ← Французское право (надстройка над LEGAL)
└── rules/
    ├── DIALOGUE.md        ← КАНОН 2 + КАНОН 7
    ├── COLLABORATION.md   ← КАНОН 1 + КАНОН 9
    ├── AUTOMATION.md      ← КАНОН 3 + КАНОН 4 + КАНОН 10
    ├── REPORTING.md       ← КАНОН 5 + КАНОН 6
    └── VERIFICATION.md    ← КАНОН 8
```

---

## МАРШРУТИЗАЦИЯ ПРОФИЛЕЙ

### Профиль BANXE / DEV (по умолчанию для этого терминала)

**Активен когда:** проект = `vibe-coding`, `developer-core`, `banxe-architecture`, `banxe-*`

| Модуль | Статус |
|--------|--------|
| CORE   | ✅ ACTIVE |
| DOC    | ✅ ACTIVE |
| DEV    | ✅ ACTIVE (primary) |
| DECISION | ✅ ACTIVE |
| LEGAL  | ❌ OFF |
| FR_MODULE | ❌ OFF |

**Правила активного профиля:**
- Все compliance-операции через GAP-REGISTER + INVARIANTS
- Тесты — baseline 747, регрессии недопустимы
- Governance gates: CLASS_A авто, CLASS_B/C/D → человек
- change-classes.yaml как единый источник approval rules
- Один терминал = один проект (CANON 9)

---

### Профиль LEGAL

**Активен когда:** проект = `guiyon`, `ss1`, задача содержит юридическую тематику
(ключевые слова: право, суд, норма, статья, кодекс, FR, нотариус, иск, договор)

| Модуль | Статус |
|--------|--------|
| CORE   | ✅ ACTIVE |
| DOC    | ✅ ACTIVE |
| LEGAL  | ✅ ACTIVE (primary) |
| DECISION | ✅ ACTIVE |
| FR_MODULE | ✅ ACTIVE (если французское право) |
| DEV    | ❌ OFF |

**Правила активного профиля:**
- Все правовые ответы со ссылкой на статьи
- FR_MODULE активируется автоматически при французских правовых вопросах
- Консультационный канон: КАНОН 7 (предлагаю → пользователь одобряет)
- Не давать юридических советов как окончательных — только анализ

---

### Профиль MIXED (переключение внутри сессии)

**Активен когда:** пользователь переключается с dev-задачи на юридический вопрос
(или наоборот) в рамках одной сессии

| Модуль | Статус |
|--------|--------|
| CORE   | ✅ ACTIVE |
| DOC    | ✅ ACTIVE |
| DEV    | ✅ ACTIVE (primary context = BANXE) |
| LEGAL  | ✅ ACTIVE (overlay) |
| DECISION | ✅ ACTIVE |
| FR_MODULE | условно ACTIVE |

**Правило переключения:**
```
ЕСЛИ текущий контекст = DEV И пользователь задаёт юридический вопрос:
    → активировать LEGAL как overlay
    → сохранить DEV-контекст
    → ответить с юридической точностью
    → после ответа вернуться в DEV-режим
```

---

## Активация через скрипт

```bash
# Проверить текущий профиль
bash ~/developer/canon/scripts/check-canon.sh

# Активировать профиль вручную
bash ~/developer/canon/scripts/activate-profile.sh banxe
bash ~/developer/canon/scripts/activate-profile.sh legal
bash ~/developer/canon/scripts/activate-profile.sh mixed
```

---

## Ссылки на правила

- Диалог и подтверждения: [rules/DIALOGUE.md](rules/DIALOGUE.md) — КАНОН 2, 7
- Коллаборация агентов: [rules/COLLABORATION.md](rules/COLLABORATION.md) — КАНОН 1, 9
- Автоматизация и git: [rules/AUTOMATION.md](rules/AUTOMATION.md) — КАНОН 3, 4, 10
- Отчётность и объяснения: [rules/REPORTING.md](rules/REPORTING.md) — КАНОН 5, 6
- Верификация (5-step): [rules/VERIFICATION.md](rules/VERIFICATION.md) — КАНОН 8

---

## Версионирование

| Версия | Дата | Изменения |
|--------|------|-----------|
| 1.0 | 2026-04-06 | Первая структурированная версия, адаптировано под WSL/Claude Code |
