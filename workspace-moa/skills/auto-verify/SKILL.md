# SKILL: auto-verify

**Назначение:** Обязательная авто-верификация compliance/KYC/AML ответа перед отправкой.  
**Сервис:** `banxe-verify-api.service` → `http://127.0.0.1:8094`  
**Применяется:** compliance, kyc, aml, risk, crypto — ВСЕГДА, без исключений.

---

## Когда вызывать

**Обязательно** перед финализацией ответа если роль агента:
- KYC Specialist
- Compliance Officer
- AML Analyst
- Risk Analyst
- Crypto AML
- Sanctions Officer

---

## Алгоритм (СТРОГИЙ ПОРЯДОК)

```
ШАГ 1: Сформулируй ответ (не отправляй)
ШАГ 2: Вызови /verify (curl ниже, timeout 3s)
ШАГ 3: Обработай consensus по таблице:

  CONFIRMED             → отправляй ответ как есть
  REFUTED               → НЕ отправляй; перефразируй используя поле "reason"
  UNCERTAIN, hitl=false → отправляй + добавь в конце: "Ответ требует дополнительной проверки."
  UNCERTAIN, hitl=true  → НЕ отправляй; создай Marble кейс (skill marble-cases)
  timeout / недоступен  → отправляй + добавь: "[Верификация недоступна]"
```

---

## Вызов

```bash
# GET — для коротких ответов (< 200 символов)
curl -s --max-time 3 \
  "http://127.0.0.1:8094/verify?statement=<текст_url_encoded>&agent_id=<id>&agent_role=<роль>"

# POST — для длинных ответов
curl -s --max-time 3 -X POST "http://127.0.0.1:8094/verify" \
  -H "Content-Type: application/json" \
  -d '{"statement":"<текст>","agent_id":"<id>","agent_role":"<роль>"}'
```

**Ответ:**
```json
{
  "consensus": "CONFIRMED" | "REFUTED" | "UNCERTAIN",
  "hitl_required": true | false,
  "confidence": 0.833,
  "drift_score": 0.12,
  "reason": "нарушение или null",
  "rule": "FCA MLR 2017 §3 или null",
  "correction": "правильная формулировка или null",
  "training_flag": true | false
}
```

---

## Обработка REFUTED

Поле `correction` содержит правильную формулировку (если compliance_validator дал override).  
Поле `reason` объясняет нарушение.

```
REFUTED + correction != null → использовать correction как ответ
REFUTED + correction == null → переформулировать: убрать то, что описано в reason
```

**Пример:**
- Исходный ответ: "Approve PEP without EDD review"
- REFUTED, reason="PEP requires EDD and MLRO approval", correction="PEP client requires Enhanced Due Diligence and MLRO approval before any transaction."
- Финальный ответ: "PEP client requires Enhanced Due Diligence and MLRO approval before any transaction."

---

## Обработка UNCERTAIN + hitl_required=true

Вызвать skill **marble-cases** для создания HITL кейса:

```json
{
  "name": "HITL Review — <agent_role> uncertain statement",
  "status": "pending_review",
  "decision": "HOLD",
  "risk_score": 50,
  "requires_edd": true,
  "requires_mlro": true,
  "signals": [{"rule": "UNCERTAIN_VERIFICATION", "score": 50, "reason": "<reason>"}],
  "audit_payload": {"agent_id": "<id>", "drift_score": "<drift_score>"}
}
```

После создания кейса: "Запрос направлен на проверку MLRO. Кейс #<marble_case_id>."

---

## Hard overrides (консенсус 2/3 не перекрывает)

| Триггер | Результат |
|---------|-----------|
| Compliance Validator REFUTED, confidence=1.0 | Всегда REFUTED — нет исключений |
| Workflow Agent REFUTED, confidence≥0.95 | Всегда REFUTED |
| Policy Agent REFUTED, confidence≥0.90 + rule="EMI Authorisation Scope" | Всегда REFUTED |

---

## Примеры

```bash
# CONFIRMED — корректный ответ
curl -s --max-time 3 \
  "http://127.0.0.1:8094/verify?statement=Russia+REJECT+sanctioned+jurisdiction&agent_role=Compliance+Officer"
# → {"consensus":"CONFIRMED","hitl_required":false}

# REFUTED — нарушение AML Red Line
curl -s --max-time 3 \
  "http://127.0.0.1:8094/verify?statement=Approve+PEP+without+EDD&agent_role=KYC+Specialist"
# → {"consensus":"REFUTED","hitl_required":true,"reason":"PEP requires EDD","rule":"FCA MLR 2017 §3"}

# Health check
curl -s "http://127.0.0.1:8094/health"
# → {"status":"ok","port":8094}
```

---

**Порт:** 8094  
**Зависит от:** verify-statement (базовый curl), marble-cases (HITL кейсы)  
**Сервис:** `systemctl status banxe-verify-api`
