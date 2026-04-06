# Banxe Compliance Stack — Architecture Reference

**Version:** Phase 16 (05.04.2026)  
**Canonical repo:** `github.com/CarmiBanxe/vibe-coding` → `src/compliance/`  
**Runtime:** `/data/banxe/compliance/` on GMKtec (192.168.0.72)  
**API:** FastAPI `:8093` | **Service:** `banxe-api.service`

---

## AML Block Architecture (3-layer runtime)

```
┌─────────────────────────────────────────────────────────────────────┐
│  LAYER 1 — Policy / Regulatory  (developer-core, source-of-truth)  │
│  compliance_validator.py                                            │
│  _HARD_BLOCK_JURISDICTIONS | _HIGH_RISK_JURISDICTIONS               │
│  _THRESHOLD_SAR=85 | _THRESHOLD_REJECT=70 | _THRESHOLD_HOLD=40     │
│  _FORBIDDEN_PATTERNS  (verification agent guardrails)               │
└───────────────────────────┬─────────────────────────────────────────┘
                            │ imported by ↓
┌───────────────────────────▼─────────────────────────────────────────┐
│  LAYER 2 — AML Engines  (vibe-coding/src/compliance/)               │
│                                                                     │
│  tx_monitor.py          → transaction behaviour signals             │
│  sanctions_check.py     → entity/name watchlist (Watchman + fuzzy)  │
│  crypto_aml.py          → crypto wallet risk (OFAC, mixer, flags)   │
│  aml_orchestrator.py    → generic aggregator (Layer 2 only)         │
│                                                                     │
│  All engines produce list[RiskSignal] (models.py contract)          │
└───────────────────────────┬─────────────────────────────────────────┘
                            │ aggregated + enriched by ↓
┌───────────────────────────▼─────────────────────────────────────────┐
│  LAYER 3 — BANXE AML Block Runtime                                  │
│  banxe_aml_orchestrator.py                                          │
│                                                                     │
│  banxe_assess(transaction, customer, counterparty, wallet, channel) │
│  → BanxeAMLResult                                                   │
│  → decision: APPROVE / HOLD / REJECT / SAR                          │
│  → case_id  (UUID → Marble MLRO queue)                              │
│  → policy_version  (developer-core provenance)                      │
│  → audit_payload   (→ ClickHouse audit_trail)                       │
│                                                                     │
│  Priority engine (signal-first, not pure summation):                │
│  P1 hard-block / sanctions_confirmed → always REJECT (or SAR)       │
│  P2 high-risk jurisdiction or PEP   → score floor = HOLD (40)       │
│  P3 standard threshold-based decision from composite score          │
└─────────────────────────────────────────────────────────────────────┘
```

### Directory layout

```
developer-core/
└── compliance/
    └── verification/
        ├── compliance_validator.py   ← LAYER 1 (policy owner: developer-core)
        ├── orchestrator.py           ← verification consensus (3-agent)
        ├── compliance_agent.py
        ├── policy_agent.py
        └── workflow_agent.py

vibe-coding/src/compliance/
├── models.py                         ← shared data contracts
│   TransactionInput, SanctionsSubject, WalletScreeningInput,
│   CustomerProfile, RiskSignal, AMLResult
│
├── tx_monitor.py                     ← LAYER 2: transaction signals (9 rules)
├── sanctions_check.py                ← LAYER 2: entity watchlist screening
├── crypto_aml.py                     ← LAYER 2: crypto wallet risk
├── aml_orchestrator.py               ← LAYER 2: generic aggregator
│
└── banxe_aml_orchestrator.py         ← LAYER 3: BANXE runtime entry point
    banxe_assess(transaction, customer, counterparty, wallet, channel)
    → BanxeAMLResult (decision, case_id, policy_version, audit_payload)
```

### Example flow

```python
from compliance.banxe_aml_orchestrator import banxe_assess
from compliance.models import TransactionInput, CustomerProfile, SanctionsSubject

result = await banxe_assess(
    transaction  = TransactionInput("GB", "DE", 12_000.0, currency="GBP"),
    customer     = CustomerProfile("CUST-042", is_pep=True, prior_sars=1),
    counterparty = SanctionsSubject("Hans Müller", jurisdiction="DE"),
    channel      = "bank_transfer",
)

# result.decision            → "SAR"
# result.score               → 95
# result.case_id             → "a3f7c2e1-..."   (→ Marble MLRO queue)
# result.policy_version      → "developer-core@2026-04-05"
# result.requires_mlro_review→ True
# result.to_api_response()   → flat dict for BANXE API response
# result.to_audit_dict()     → flat dict for ClickHouse insert
```

### Signal-priority decision vs pure summation

| Situation | Pure summation result | Priority result |
|-----------|----------------------|-----------------|
| Cat B jurisdiction, amount £200 | APPROVE (score 35 < 40) | **HOLD** (floor applied) |
| PEP customer, clean transaction £500 | APPROVE (score 35 < 40) | **HOLD** (PEP floor) |
| Unacceptable risk rating, small tx | APPROVE (score 70?) | **REJECT** (hard override) |
| Cat A jurisdiction, low score | depends on signals | **REJECT** (always) |

---

## Invariants (never change without review)

1. **Canonical key for companies:** `(jurisdiction_code, registration_number)` — never use `company_number` alone; collisions across jurisdictions.
2. **OFAC has no RSS feed** since 31 January 2025. Source: `OFAC-RecentActions` HTML scraper only (`ofac.treasury.gov/recent-actions`).
3. **Watchman minMatch = 0.80** (Jaro-Winkler). Below 0.80 → false positives. Above 0.92 → misses known aliases.
4. **ClickHouse TTL = 5 YEAR** — FCA MLR 2017 retention requirement. Do not reduce.
5. **AGPLv3 (Jube):** internal use only. Any external exposure requires AGPL compliance review.
6. **GUIYON (port 18794)** — categorically excluded from Banxe. No shared services, no cross-routing.

---

## Stack layers

### Layer 1 — Sanctions & PEP
| Component | Tool | Source |
|-----------|------|--------|
| `sanctions_check.py` | Moov Watchman `:8084` (Apache 2.0) | OFAC SDN, UK CSL, EU CSL, UN CSL, FinCEN 311 |
| `pep_check.py` | PostgreSQL `pep_legislators` (14,491 records) → Wikidata SPARQL fallback | EveryPolitician CC0 + curated seed |

**PEP lookup pattern:** PostgreSQL first (~5ms) → Wikidata 2-step if no hit (Search API for QID → SPARQL by QID, ~1.5s total).

### Layer 2 — Adverse Media & Regulatory Feeds
| Source | Type | `source_weight` |
|--------|------|-----------------|
| FCA Enforcement RSS | regulator/uk | 1.00 |
| OFAC Recent Actions (HTML scrape) | regulator/us | 0.95 |
| EBA News RSS | regulator/eu | 0.85 |
| EUR-Lex AML RSS | eu_law | 0.75 |
| Google News RSS | news | 0.55 |

**Scoring formula:**
```
final_score = source_weight × 0.45
            + entity_match_weight × 0.35
            + topic_weight × 0.20
```

**Entity match weights:** exact name = 1.00 · alias/previous_name = 0.80 · partial = 0.45–0.70 · no match = 0.00  
**Regulatory boost:** `is_regulatory=True` → contribution × 1.4 to aggregate `risk_score`  
**Noise floor:** articles with `final_score < 0.10` are discarded.

### Layer 3 — KYB / UBO
| Component | Source | Auth |
|-----------|--------|------|
| `CompaniesHouseClient` | Companies House Public Data API | Basic auth (API key as username) |
| `OpenCorporatesClient` | OpenCorporates REST API v0.4 | `api_token` query param |

**Merge priority:** Companies House is primary (authoritative for UK). OpenCorporates enriches `previous_names` and `officers` for non-UK or missing data.

**Officer/UBO screening:** all active officers and non-ceased beneficial owners are screened against Watchman + PEP on every `check_company()` call. A single SANCTIONS or PEP hit on any active person → `kyb_decision = REJECT`.

**Pending keys (as of 03.04.2026):**
- `COMPANIES_HOUSE_API_KEY` → `/data/banxe/.env` (requested 03.04.2026, ~2 working days)
- `OPENCORPORATES_API_KEY` → register at `opencorporates.com/api_accounts/new` (free open-data tier)

### Layer 4 — Legal Exposure / EDD
| Component | Source | Access |
|-----------|--------|--------|
| `search_eurlex()` | EUR-Lex CELLAR SPARQL + REST search | Free, no key |
| `search_bailii()` | BAILII website search | Free, no key |

**Trigger:** called only when `composite_score >= 40` (`requires_edd = True`). Adds up to +20 boost to composite score.

### Layer 5 — AML Stack ("Collective LexisNexis")

**Shared datamodel:** `models.py` — `TransactionInput`, `SanctionsSubject`, `WalletScreeningInput`, `RiskSignal`, `AMLResult`

**Entry point:** `aml_orchestrator.assess(tx, subject, wallet) → AMLResult`
All three modules produce `list[RiskSignal]`; the orchestrator aggregates into a single `AMLResult`.

#### `tx_monitor.py` — 9 deterministic rules + Redis velocity (sorted sets, 24h TTL)

| Rule | Threshold | Score |
|------|-----------|-------|
| `HARD_BLOCK_JURISDICTION` | Category A (RU/BY/IR/KP/...) | 100, short-circuit |
| `HIGH_RISK_JURISDICTION` | Category B (SY/IQ/LB/...) | +35 |
| `SINGLE_TX_THRESHOLD` | ≥ £10,000 (MLR 2017) | +30 |
| `VELOCITY_24H` | cumulative ≥ £25,000 | +40 |
| `POTENTIAL_STRUCTURING` | 3+ txs × £8,000–9,999 in 24h | +60 |
| `ROUND_AMOUNT` | round ≥ £5,000 | +15 |
| `RAPID_IN_OUT` | credit→debit < 1h, ≥ £1,000 | +50 |
| `CRYPTO_FLAG` | is_crypto = True | +20 |
| `FLAG_*` | caller-supplied flags | +10 each |

#### `sanctions_check.py` — entity watchlist screening (stdlib urllib, no httpx)

| Rule | Source | Score |
|------|--------|-------|
| `SANCTIONS_CONFIRMED` | Watchman match ≥ 95% | 100 |
| `SANCTIONS_PROBABLE` | Watchman match 80–95% | 70 |
| `SUBJECT_JURISDICTION_A` | Category A jurisdiction | 100, short-circuit |
| `SUBJECT_JURISDICTION_B` | Category B jurisdiction | +35 |

Fallback: `difflib.SequenceMatcher` against curated local list (stdlib, offline-safe).

#### `crypto_aml.py` — wallet screening (stdlib urllib, no httpx, no FINOS dependency)

| Rule | Trigger | Score |
|------|---------|-------|
| `CRYPTO_SANCTIONS` | Watchman OFAC address exact match | 100, short-circuit |
| `CRYPTO_CRITICAL` | darknet/ransomware/terrorism/... flags | 90 |
| `CRYPTO_HIGH_RISK` | mixer/tumbler/scam/fraud flags | 70 |
| `CRYPTO_ELEVATED` | rapid_in_out/layering/pep_linked flags | 40 |
| `CRYPTO_HIGH_VALUE` | tx value > £50,000 | 20 |

Jube TM (AGPLv3, `:5001`) handles the probabilistic ML layer. The above modules handle deterministic rules only.

---

## Decision thresholds (source of truth: `compliance_validator.py`)

| Score | Decision | Action |
|-------|----------|--------|
| ≥ 85 | SAR | MLRO notified, SAR obligation, transaction blocked |
| 70–84 | REJECT | Transaction blocked |
| 40–69 | HOLD | EDD required |
| < 40 | APPROVE | Pass |
| hard_block or sanctions_hit | REJECT/SAR | Regardless of score |

**Hard override rules** (always force REJECT/SAR regardless of composite score):
`HARD_BLOCK_JURISDICTION`, `SUBJECT_JURISDICTION_A`, `SANCTIONS_CONFIRMED`, `CRYPTO_SANCTIONS`

**SAR auto-threshold:** `composite_score >= 85` OR `sanctions_hit = true` → SAR draft generated by `sar_generator.py`.

---

## Database schema

| DB | Table | Purpose |
|----|-------|---------|
| ClickHouse `banxe` | `compliance_screenings` | All screening results, TTL 5Y |
| ClickHouse `banxe` | `mv_daily_stats` (MV) | CEO dashboard daily aggregates |
| ClickHouse `banxe` | `mv_sar_queue` (MV) | SAR queue management |
| PostgreSQL `banxe_compliance` | `pep_legislators` | 14,491 PEP records |
| PostgreSQL `banxe_compliance` | `kyb_entities` + 8 tables | Unified KYB storage |

---

## API endpoints (FastAPI `:8093`)

```
POST /api/v1/screen/person      Sanctions + PEP + AMI [+ EDD if score ≥ 40]
POST /api/v1/screen/company     KYB + UBO sanctions/PEP
POST /api/v1/screen/wallet      Crypto AML (Watchman OFAC + heuristic flags)
POST /api/v1/transaction/check  TM rules (deterministic + Redis velocity)
GET  /api/v1/legal/{entity}     EUR-Lex + BAILII standalone EDD
GET  /api/v1/report/{id}        Retrieve screening report JSON
GET  /api/v1/history/{entity}   ClickHouse screening history
GET  /api/v1/stats              Aggregate compliance statistics
GET  /api/v1/health             Service health (Watchman/Jube/PG/Redis/ClickHouse)
GET  /api/v1/dashboard/overview CEO dashboard overview
GET  /api/v1/dashboard/daily    Daily volumes (last N days)
GET  /api/v1/dashboard/sar-queue SAR queue + reviewer sign-off
POST /api/v1/dashboard/sar-queue/review Mark SAR as reviewed
GET  /api/v1/dashboard/risk-heatmap Top risk entities + decision breakdown
GET  /api/v1/dashboard/agent-activity Screening breakdown by entity_type
```

---

## Infrastructure (GMKtec 192.168.0.72)

| Service | Port | License | Status |
|---------|------|---------|--------|
| FastAPI `banxe-api.service` | 8090 | — | ✅ |
| Moov Watchman | 8084 | Apache 2.0 | ✅ |
| Jube TM | 5001 | AGPLv3 | ✅ healthy |
| PostgreSQL | 5432 | PostgreSQL | ✅ |
| Redis | 6379 | BSD | ✅ |
| ClickHouse | 8123 | Apache 2.0 | ✅ |
| Ballerine | 3000/5137/5200/5201 | MIT | ✅ |

**venv:** `/data/banxe/compliance-env/`  
**Config:** `/data/banxe/.env` (COMPANIES_HOUSE_API_KEY, OPENCORPORATES_API_KEY, DB creds)  
**Logs:** `/data/banxe/data/logs/{timestamp}_{slug}.json`

---

## Test suite

```bash
# Phase 1–13 integration (custom asyncio runner)
cd /data/banxe/compliance
sudo -u banxe /data/banxe/compliance-env/bin/python3 test_suite.py

# Phase 15 unit tests (pytest, no network)
sudo -u banxe /data/banxe/compliance-env/bin/python3 -m pytest test_phase15.py -v
```

Current baseline: `test_suite.py` → 18 pass, 2 warn (KYB pending keys), 0 fail.  
`test_phase15.py` → 39/39 pass.

---

## Calibration log

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Watchman minMatch | 0.80 | Catches "Vladimir Vladimirovich PUTIN" from "Vladimir Putin"; no FP on "Emmanuel Macron" |
| EDD threshold | composite ≥ 40 | Below REJECT (70), above low-risk; triggers legal + enhanced checks |
| SAR auto | composite ≥ 85 OR sanctions_hit | Conservative; MLRO reviews all queued SARs |
| Regulatory AMI boost | ×1.4 | Regulator enforcement > news; calibration subject to MLRO review |
| Legal score boost cap | +20 | Prevents legal layer from dominating composite without sanctions hit |

---

## What this stack does NOT cover (commercial gap)

| Gap | Commercial equivalent | Why not OSS |
|-----|-----------------------|-------------|
| Global PEP with relatives/associates | World-Check, Dow Jones, AML Watcher | Proprietary compiled datasets |
| Document fraud detection (liveness, deepfake) | Sumsub, Jumio | Closed ML models |
| Global address verification | Loqate, Melissa | Licensed geo-data |
| Real-time crypto tx graph | Chainalysis, TRM Labs | Proprietary chain analytics |

These gaps are acceptable for sandbox phase. Production FCA authorisation will require vendor contracts (Dow Jones / LexisNexis / Sumsub — emails pending).
