---
name: Banxe AI Bank — Финальная структура (FCA 3LoD, v02.04.2026)
description: Финальная структура 13 AI-агентов + Human Staff. Два режима: Sandbox и Production. Roadmap к FCA авторизации. Утверждена 02.04.2026.
type: project
---

# Banxe AI Bank — Финальная структура (02.04.2026)

## Концепция: два режима одной структуры

```
SANDBOX MODE (сейчас)       →     PRODUCTION MODE (к подаче в FCA)
Марк + Олег + AI-агенты           + MLRO + Head of Compliance + внешний DPO
Отладка технологий                Полная FCA-авторизация
```

---

## Human Staff

| Роль | SMF | Кто | Режим |
|------|-----|-----|-------|
| CEO | SMF1/SMF3 | Moriel Carmi (Марк) | ✅ Sandbox + Production |
| Tech Lead / CTO | — | Олег | ✅ Sandbox + Production |
| MLRO | SMF17 | TBD — UK-резидент, крипто-опыт | 🔄 Нанять до подачи FCA |
| Head of Compliance + надзор GDPR | SMF16 | TBD — UK-резидент | 🔄 Нанять до подачи FCA |
| DPO | — | Внешний аутсорс | 🔄 Подключить до подачи FCA |
| Internal Auditor | — | Внешний аудитор | 🔄 Подключить до подачи FCA |

**Конфиги OpenClaw:**
- `/root/.openclaw-moa/.openclaw/openclaw.json` (port 18789, Марк)
- `/home/ctio/.openclaw-ctio/.openclaw/openclaw.json` (port 18791, Олег)

---

## LINE 1 — Operations (AI выполняет полностью)

| id | Агент | Модель | Human-дублёр |
|----|-------|--------|-------------|
| main | 🧠 CTIO | qwen3:30b-a3b | Олег |
| supervisor | 🏦 Supervisor | qwen3:30b-a3b | Марк — governance sign-off |
| kyc | 📋 KYC/CDD Officer | qwen3:30b-a3b | Олег — tech escalation |
| client-service | 💬 Client Relations | glm-4.7-flash | SMF16 — DISP escalation |
| operations | ⚡ Payments Operations | glm-4.7-flash | Олег — tech escalation |
| crypto | 🪙 Crypto Officer | qwen3:30b-a3b | SMF17 — crypto AML decisions |
| it-devops | 🔧 IT/DevOps | glm-4.7-flash | Олег |

## LINE 2 — Control (AI готовит → человек подписывает)

| id | Агент | Модель | Human-дублёр |
|----|-------|--------|-------------|
| mlro | 🛡️ MLRO Agent | qwen3:30b-a3b | SMF17 — SAR submission → NCA (≤24ч) |
| compliance | 📜 Compliance Officer | qwen3:30b-a3b | SMF16 — FCA уведомления |
| risk | ⚠️ Risk Manager | qwen3:30b-a3b | SMF17 — EDD/risk sign-off |
| dpo | 🔒 DPO Agent | qwen3:30b-a3b | Внешний DPO — ICO/UK GDPR |

## LINE 3 — Assurance (независимый)

| id | Агент | Модель | Human-дублёр |
|----|-------|--------|-------------|
| internal-audit | 🔍 Internal Audit | gpt-oss-derestricted | Внешний аудитор — НЕ CEO |

## SUPPORT

| id | Агент | Модель | Human-дублёр |
|----|-------|--------|-------------|
| finance | 💰 Finance/Safeguarding | gpt-oss-derestricted | Марк — Board approval |

---

## Правила взаимодействия AI → Human (неизменны)

| AI делает | Human обязан |
|-----------|-------------|
| MLRO Agent генерирует черновик SAR | SMF17 проверяет и подаёт в NCA (≤24ч) — POCA 2002 |
| Compliance Agent готовит FCA-уведомление | SMF16 подписывает — SYSC 6.1 |
| Risk Agent готовит решение по EDD | SMF17 sign-off — SYSC 7 |
| DPO Agent мониторит PII / DSAR | Внешний DPO подтверждает — UK GDPR Art.37 |
| Internal Audit формирует отчёт | Внешний аудитор верифицирует; Марк хранит 5 лет — SYSC 6.2 |
| Finance Agent сверяет DSA | Марк — Board approval — PSR 2017 Reg.23 |

---

## Roadmap: Sandbox → FCA Production

```
СЕЙЧАС (Sandbox)
├── Марк + Олег
├── 13 AI-агентов отлаживаются
├── Технологический стек строится
├── Документация готовится (RBP, AML Policy, BCP, Wind-Down Plan)
└── DSA-соглашение с UK банком прорабатывается

ШАГ 1 — за 3 месяца до подачи FCA
├── Нанять MLRO (SMF17) — UK-резидент, крипто-опыт
├── Нанять Head of Compliance (SMF16) — UK-резидент
├── Подключить внешнего DPO
└── Подключить внешнего Internal Auditor

ШАГ 2 — подача в FCA
├── Long Form A для Марка (SMF1), MLRO (SMF17), SMF16
├── Schedule 1 EMR 2011 — полный пакет документов
├── Отдельно: MLR crypto registration
└── €350,000 начального капитала подтверждены

ШАГ 3 — авторизация (3–6 месяцев)
└── FCA review → авторизация → операционный старт
```

---

## Критические правила (FCA compliance)

1. MLRO Agent → черновик SAR → MLRO (человек) → NCA (max 24ч, POCA 2002)
2. CEO НЕ дублирует Internal Audit — нарушение 3LoD независимости
3. DPO — внешний аутсорс (не SMF16, во избежание конфликта интересов)
4. SAR tipping off запрещён — уголовная ответственность по POCA 2002
5. Все PII через Presidio proxy до LLM — GDPR Art.32

## Правовые основания

- MLR 2017 Reg.21(1)(a) — MLRO обязателен (SMF17)
- SYSC 6.1 — Compliance Officer обязателен (SMF16)
- SYSC 6.2 — Internal Audit
- SYSC 7 — Risk Management
- PSR 2017 Reg.23 — Safeguarding
- UK GDPR Art.37 — DPO
- POCA 2002 — SAR workflow
- FCA CP22/20 — Crypto
- EMR 2011 Schedule 1 — полный пакет для авторизации
- €350,000 — минимальный начальный капитал EMI

**Why:** FCA требует именно эту структуру для UK EMI authorisation. Sandbox позволяет отлаживать технологии до найма регуляторных специалистов.
**How to apply:** При изменении агентов — сверяться с этой структурой. Не удалять ни одного Line 2/3 агента без согласования. DPO — всегда внешний, не SMF16.
