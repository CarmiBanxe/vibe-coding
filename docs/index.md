# Banxe AI Bank — Technical Documentation

**Banxe AI Bank** is a UK FCA-authorised EMI building an open-source AML/KYC compliance stack
as a cost-effective alternative to commercial solutions like LexisNexis Risk Solutions (~$100K+/year).

---

## Architecture Overview

The compliance stack is organised in three layers:

```
Layer 1 — Policy (developer-core)
  compliance_validator.py — jurisdiction lists, thresholds, forbidden patterns

Layer 2 — AML Engines (src/compliance/)
  tx_monitor.py      — transaction behaviour: velocity, structuring, jurisdiction
  sanctions_check.py — entity/name watchlist screening
  crypto_aml.py      — crypto wallet risk heuristics
  aml_orchestrator.py— generic signal aggregator

Layer 3 — BANXE Runtime
  banxe_aml_orchestrator.py — case_id, policy_version, priority decision engine
```

For the full architecture reference, see [COMPLIANCE_ARCH.md](COMPLIANCE_ARCH.md).

---

## Quick Start

```python
from compliance.models import TransactionInput, CustomerProfile
from compliance.banxe_aml_orchestrator import banxe_assess

result = await banxe_assess(
    transaction = TransactionInput("GB", "DE", 5_000.0, currency="GBP"),
    customer    = CustomerProfile("CUST-001", risk_rating="standard"),
    channel     = "bank_transfer",
)

print(result.decision)       # APPROVE / HOLD / REJECT / SAR
print(result.case_id)        # UUID for MLRO queue
print(result.policy_version) # "developer-core@2026-04-05"
```

---

## Decision Thresholds

| Score | Decision | Action |
|-------|----------|--------|
| ≥ 85  | **SAR**    | MLRO notified, SAR obligation, transaction blocked |
| 70–84 | **REJECT** | Transaction blocked |
| 40–69 | **HOLD**   | EDD required |
| < 40  | **APPROVE**| Pass |
| Hard block or sanctions hit | **REJECT/SAR** | Regardless of score |

---

## Modules

| Module | Role | Returns |
|--------|------|---------|
| [`models`](reference/models.md) | Shared data contracts | — |
| [`tx_monitor`](reference/tx_monitor.md) | Transaction behaviour | `list[RiskSignal]` |
| [`sanctions_check`](reference/sanctions_check.md) | Watchlist screening | `list[RiskSignal]` |
| [`crypto_aml`](reference/crypto_aml.md) | Crypto wallet risk | `list[RiskSignal]` |
| [`aml_orchestrator`](reference/aml_orchestrator.md) | Generic aggregator | `AMLResult` |
| [`banxe_aml_orchestrator`](reference/banxe_aml_orchestrator.md) | BANXE runtime | `BanxeAMLResult` |

---

## Infrastructure

- **GMKtec EVO-X2** (AMD Ryzen AI MAX+ 395, 128GB RAM) — AI brain
- **Moov Watchman** `:8084` — OFAC/UN/EU/UK sanctions lists
- **Jube TM** `:5001` — ML-layer transaction monitoring (AGPLv3)
- **Marble** `:5002/5003` — MLRO case management (Apache 2.0)
- **ClickHouse** `:9000` — FCA audit trail (5-year TTL)

---

## Design Decisions

See [ADR index](adr/index.md) for architectural decision records.
