---
name: Collective LexisNexis — Open-Source Compliance Stack
description: 100% бесплатный стек из 19 OSS-инструментов. 10/10 агентов. FastAPI :8093 работает (ADR-012: port conflict с GUIYON, I-18 resolved). KYB pending API key (03.04.2026).
type: project
---

# Collective LexisNexis — Banxe AI Bank

Развёрнут: 02-03.04.2026. Сервер: GMKtec (192.168.0.72).

## Финальный статус: 10/10 агентов ✅

| # | Агент | Модуль | Сервис | Статус |
|---|-------|--------|--------|--------|
| 1 | MLRO Agent | tx_monitor.py + sar_generator.py | Jube :5001 (healthy) | ✅ |
| 2 | KYC Agent | doc_verify.py (PassportEye+DeepFace) | venv | ✅ |
| 3 | Sanctions Agent | sanctions_check.py | Watchman :8084 | ✅ |
| 4 | PEP Agent | pep_check.py | PostgreSQL 14,491 записей + Wikidata | ✅ |
| 5 | Adverse Media Agent | adverse_media.py | RSS + keywords | ✅ |
| 6 | Risk Agent | sar_generator.py + risk_matrix.json | venv | ✅ |
| 7 | KYB/UBO Agent | kyb_check.py | Companies House API | ✅ ⚠️ pending key |
| 8 | Crypto AML Agent | crypto_aml.py | FINOS OpenAML + Watchman | ✅ |
| 9 | Operations Agent | tx_monitor.py | Redis :6379 | ✅ |
| 10 | CEO/Orchestrator | api.py + dashboard.py | FastAPI :8093 + ClickHouse :8123 | ✅ |

## Companies House API key — статус

**Запрос отправлен:** 03.04.2026
**Канал:** GOV.UK One Login Support Team → carmi@banxe.com
**Срок ответа:** 2 рабочих дня
**Действие когда получим:** задать `COMPANIES_HOUSE_API_KEY=<key>` в `/data/banxe/.env`

До получения ключа: kyb_check.py возвращает `{"status": "pending", "kyb_decision": "HOLD"}` — не падает, остальные 9 агентов работают полностью.

## Файлы (/data/banxe/compliance/)

| Файл | Назначение |
|------|-----------|
| screener.py | Главный оркестратор |
| sanctions_check.py | Watchman + finsanctions |
| pep_check.py | PostgreSQL (14.5K) + Wikidata 2-step |
| adverse_media.py | Google News RSS + keyword scoring |
| doc_verify.py | PassportEye MRZ + DeepFace |
| kyb_check.py | Companies House UK (pending key) |
| crypto_aml.py | FINOS OpenAML + Watchman OFAC |
| tx_monitor.py | 6 правил + Redis velocity (jube_lite) |
| sar_generator.py | SAR/STR narrative + JSON |
| audit_trail.py | ClickHouse logging, TTL 5 лет |
| api.py | FastAPI :8093 — 15 endpoints |
| dashboard.py | CEO Dashboard, ClickHouse analytics |
| test_suite.py | 20 тестов, 18 pass, 2 warn |

## API Endpoints (FastAPI :8093)

```
POST /api/v1/screen/person      — Sanctions+PEP+AMI
POST /api/v1/screen/company     — KYB+UBO
POST /api/v1/screen/wallet      — Crypto AML
POST /api/v1/transaction/check  — TM rules
GET  /api/v1/report/{id}
GET  /api/v1/history/{entity}
GET  /api/v1/stats
GET  /api/v1/health
GET  /api/v1/dashboard/overview
GET  /api/v1/dashboard/daily
GET  /api/v1/dashboard/sar-queue
GET  /api/v1/dashboard/risk-heatmap
```

## Тест: Vladimir Putin
```json
{"decision": "REJECT", "sanctions_hit": true, "pep_hit": true,
 "sanctions_lists": ["us_ofac", "uk_csl", "eu_csl"],
 "composite_score": 140, "sar_required": true}
```

## PEP PostgreSQL (14,491 записей)
Загружены: US, UK, FR, DE, RU, CN, IR, KP, SY, UA + 98 ключевых лидеров
Источник: EveryPolitician + curated seed data
Таблица: `banxe_compliance.pep_legislators`
Поиск: PostgreSQL first (~5ms) → Wikidata fallback

## Watchman config
Path: /data/banxe/watchman/config.yml
Lists: us_ofac_sdn, us_ofac_cons, us_csl, us_fincen_311, uk_csl, eu_csl, un_csl
minMatch: 0.80 (Jaro-Winkler)

## Docker services
- jube.webapi :5001 ✅ healthy
- postgres :5432 ✅
- redis :6379 ✅
- clickhouse :8123 ✅ (9 таблиц в banxe DB)

**Why:** 100% OSS стек заменяет LexisNexis ($50K+/год) для sandbox + production.
**How to apply:** screener.py — точка входа. API :8093 — интерфейс для агентов OpenClaw.
Когда придёт Companies House key → добавить в /data/banxe/.env → KYB 100%.
