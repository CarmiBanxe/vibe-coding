# ADR 0002 — 3-layer Collective LexisNexis architecture

**Status:** Accepted  
**Date:** 2026-04-05  
**Deciders:** Moriel Carmi (CEO), Олег (CTIO)

---

## Context

LexisNexis Risk Solutions covers 6 points of the customer lifecycle in a single integrated
platform: onboarding (KYC/KYB), transaction monitoring, sanctions/PEP screening,
adverse media, case management, and SAR generation.

Building a modular open-source equivalent requires architectural decisions about:
1. How to decompose responsibilities across modules
2. How to maintain a single source of truth for compliance thresholds and jurisdiction lists
3. How to aggregate signals from multiple independent engines into one decision
4. Where BANXE-specific concerns (case management, audit trail, customer profile) live

The first version of the stack had a monolithic `tx_monitor.py` that duplicated jurisdiction
lists and thresholds inline, used `httpx` (async HTTP client as dependency), and embedded
FINOS OpenAML and `finsanctions` library dependencies — making it fragile and hard to test.

---

## Decision

Adopt a **3-layer architecture**:

### Layer 1 — Policy (developer-core, read-only)
`compliance/verification/compliance_validator.py`  
Source of truth for:
- `_HARD_BLOCK_JURISDICTIONS` — Category A (REJECT)
- `_HIGH_RISK_JURISDICTIONS` — Category B (EDD/HOLD)
- `_THRESHOLD_SAR = 85`, `_THRESHOLD_REJECT = 70`, `_THRESHOLD_HOLD = 40`
- `_FORBIDDEN_PATTERNS` — guardrails for verification agents

All other modules *import* from here. No duplication of thresholds or jurisdiction lists.

### Layer 2 — AML Engines (vibe-coding/src/compliance/)
Three independent signal producers, each taking typed input and returning `list[RiskSignal]`:
- `tx_monitor.score_transaction(tx: TransactionInput)`
- `sanctions_check.screen_entity(subject: SanctionsSubject)`
- `crypto_aml.analyse_chain(wallet: WalletScreeningInput)`

**Key constraint:** stdlib only for HTTP (no `httpx`). All external calls use `urllib.request`.
This removes runtime dependencies that complicate deployment and testing.

Generic aggregator: `aml_orchestrator.assess(tx, subject, wallet) → AMLResult`

### Layer 3 — BANXE Runtime (vibe-coding/src/compliance/)
`banxe_aml_orchestrator.banxe_assess(transaction, customer, counterparty, wallet, channel)`

Adds BANXE-specific concerns:
- `CustomerProfile` context (PEP, risk rating, prior SARs, KYC status)
- Channel-aware baseline scoring (crypto, cash, SWIFT)
- Signal-priority decision engine:
  - **P1 Hard override**: Category A / confirmed sanctions → always REJECT/SAR
  - **P2 Score floor**: Category B / PEP / incomplete KYC → minimum HOLD
  - **P3 Standard thresholds**: composite score → APPROVE/HOLD/REJECT/SAR
- `case_id` (UUID4) for Marble MLRO queue
- `policy_version` for audit traceability
- `BanxeAMLResult.to_audit_dict()` for ClickHouse insert

### Shared data contracts
`models.py` — all dataclasses shared across layers:
`TransactionInput`, `SanctionsSubject`, `WalletScreeningInput`, `CustomerProfile`,
`RiskSignal`, `AMLResult`

---

## Consequences

**Positive:**
- Single source of truth: thresholds and jurisdictions live in one place, imported everywhere
- Testable in isolation: each Layer 2 engine can be unit-tested without the full stack
- No runtime external dependencies for core scoring logic (stdlib-only engines)
- Clear ownership: developer-core owns policy, vibe-coding owns BANXE runtime
- Signal-priority decision avoids the "score summation loophole" where multiple small
  signals could sum past a threshold without any individual hard-block rule firing

**Negative / Risks:**
- Two orchestrator files (`aml_orchestrator.py` + `banxe_aml_orchestrator.py`) requires
  callers to know which one to use — mitigated by `__all__` exports and clear naming
- `api.py` backward-compat wrappers (`check_sanctions`, `check_wallet`) add surface area —
  scheduled for removal after api.py is fully migrated to `banxe_assess()`
- `CustomerProfile` is currently populated manually; in production it should come from
  the KYC database (SumSub webhook → PostgreSQL → CustomerProfile constructor)

---

## Review

This decision should be revisited when:
1. `api.py` is fully migrated to `banxe_assess()` (backward-compat wrappers removed)
2. `CustomerProfile` is auto-populated from PostgreSQL KYC store
3. Layer 4 (LLM-as-judge for UNCERTAIN verdicts) is implemented
