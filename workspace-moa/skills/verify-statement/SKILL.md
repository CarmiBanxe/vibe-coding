# SKILL: verify-statement

**Назначение:** Верификация compliance-ответа перед отправкой.  
**Сервис:** `banxe-verify-api.service` → `http://127.0.0.1:8094`  
**Архитектура:** 3 rule-based агента (Compliance Validator + Policy Agent + Workflow Agent) → консенсус 2/3

---

## Вызов

```bash
curl -s "http://127.0.0.1:8094/verify?statement=<текст_ответа>&agent_id=<id>&agent_role=<роль>"
```

**Параметры:**
- `statement` — текст ответа агента (URL-encoded)
- `agent_id` — идентификатор агента (например: `kyc-specialist-v1`)
- `agent_role` — роль (KYC Specialist / Compliance Officer / AML Analyst)

**Ответ:**
```json
{
  "consensus": "CONFIRMED" | "REFUTED" | "UNCERTAIN",
  "hitl_required": true | false,
  "confidence": 0.833,
  "drift_score": 0.333,
  "reason": "описание нарушения или null",
  "rule": "FCA MLR 2017 §3 / AML Red Line или null",
  "training_flag": true | false
}
```

---

## Правило для агентов

```
Перед финализацией compliance-ответа:
  1. Сформулируй ответ
  2. Вызови /verify (curl выше)
  3. REFUTED  → не отправляй, перефразируй по полю "reason"
  4. UNCERTAIN → добавь "требует HITL/проверки" или уточни
  5. hitl_required=true → всегда эскалируй на человека
```

---

## Примеры

```bash
# Правильный ответ — должен вернуть CONFIRMED
curl -s "http://127.0.0.1:8094/verify?statement=PEP+client+requires+EDD+and+HITL+manual+review&agent_role=KYC+Specialist"
# → {"consensus":"CONFIRMED","hitl_required":false,"confidence":0.827,...}

# Нарушение — должен вернуть REFUTED
curl -s "http://127.0.0.1:8094/verify?statement=Approve+PEP+without+EDD&agent_role=KYC+Specialist"
# → {"consensus":"REFUTED","hitl_required":true,"reason":"without EDD pattern","rule":"FCA MLR 2017 §3",...}

# Health check
curl -s "http://127.0.0.1:8094/health"
# → {"status":"ok","port":8094}
```

---

## Hard overrides (нельзя обойти 2/3 голосованием)

| Условие | Результат |
|---------|-----------|
| Compliance Validator REFUTED confidence=1.0 | Всегда REFUTED |
| Workflow Agent REFUTED confidence≥0.95 | Всегда REFUTED |
| Policy Agent REFUTED confidence≥0.90 + rule="EMI Authorisation Scope" | Всегда REFUTED |

---

**Порт:** 8094  
**Сервис:** `systemctl status banxe-verify-api`  
**Деплой:** `bash scripts/deploy-verify-api.sh`  
**Код:** `src/compliance/verify_api.py` + `src/compliance/verification/orchestrator.py`
