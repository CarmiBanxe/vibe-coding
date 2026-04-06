# SKILL: marble-cases

**Назначение:** Создание и управление AML/KYC кейсами в Marble Case Management.  
**Сервис:** Marble API → `http://localhost:5002`  
**UI:** Marble UI → `http://[gmktec]:5003` (рабочий стол MLRO)  
**Лицензия:** Apache 2.0

---

## Когда использовать

Создавать кейс в Marble когда:
- AML-решение = **HOLD** → кейс для EDD рассмотрения
- AML-решение = **REJECT** → кейс для фиксации и аудита
- AML-решение = **SAR** → кейс SAR + уведомление MLRO
- `requires_mlro_review: true` → MLRO обязательно рассматривает

---

## Вызов — создать кейс

```bash
# Создать AML кейс (POST /api/cases)
curl -s -X POST "http://localhost:5002/api/cases" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MARBLE_API_KEY" \
  -d '{
    "name": "AML Review — <entity_name>",
    "status": "pending_review",
    "decision": "<HOLD|REJECT|SAR>",
    "risk_score": <score>,
    "requires_edd": <true|false>,
    "requires_mlro": <true|false>,
    "signals": [{"rule": "...", "score": ..., "reason": "..."}],
    "audit_payload": {"case_id": "<uuid>", "policy_version": "..."}
  }'

# Ответ:
# {"id": "<marble_case_id>", "status": "created", "url": "/cases/<id>"}
```

## Вызов — получить кейс

```bash
curl -s "http://localhost:5002/api/cases/<case_id>" \
  -H "Authorization: Bearer $MARBLE_API_KEY"
```

## Вызов — обновить статус

```bash
curl -s -X PATCH "http://localhost:5002/api/cases/<case_id>" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MARBLE_API_KEY" \
  -d '{"status": "reviewed", "reviewer_note": "EDD completed, approved"}'
```

---

## Правило для агентов

```
После получения BanxeAMLResult с decision=HOLD/REJECT/SAR:
  1. Возьми case_id из result.case_id (UUID)
  2. Вызови Marble API для создания кейса (curl выше)
  3. Сохрани marble_case_id → передай в ClickHouse audit log
  4. Если requires_mlro_review=true → уведомить MLRO: "Кейс <id> требует проверки"
  5. SAR → дополнительно: "SAR-кейс <id> создан, MLRO уведомлён"
```

---

## Связь с AML стеком

```
banxe_aml_orchestrator.banxe_assess()
  → BanxeAMLResult.case_id      (UUID, генерируется в Python)
  → BanxeAMLResult.decision     (APPROVE/HOLD/REJECT/SAR)
  → BanxeAMLResult.to_audit_dict() → ClickHouse audit_trail

Marble case_id ≠ BanxeAMLResult.case_id:
  - BanxeAMLResult.case_id  → внутренний UUID Python (для audit trail)
  - marble_case_id           → ID в Marble UI (для MLRO workbench)
  Оба хранятся в ClickHouse: banxe.audit_trail.case_id + marble_case_id
```

---

## Примеры

```bash
# Health check Marble API
curl -s "http://localhost:5002/health"
# → {"status": "ok"}

# Health check Marble UI
curl -s "http://[gmktec]:5003"
# → HTML (Marble React UI)
```

---

## Инфраструктура

| Компонент | Порт | Статус |
|-----------|------|--------|
| Marble API (Go backend) | 5002 | active |
| Marble UI (React) | 5003 | active |
| PostgreSQL (Marble DB) | 15433 | internal |
| Firebase emulator | 9099/4000 | active |

**Compose:** `/data/banxe/marble-src/docker-compose.marble.yml`  
**Admin:** mark@banxe.com  
**MLRO Dashboard:** `http://[gmktec]:5003`  
**Деплой:** Phase 2b — `deploy-phase2-marble.sh`
