# API Reference

Auto-generated reference documentation for `src/compliance/` modules.

All AML engines follow the same contract: they accept typed dataclass inputs from
`models.py` and return `list[RiskSignal]` for aggregation by the orchestrators.

---

## Module Map

```
compliance/
├── models.py                  ← data contracts (input/output types)
├── tx_monitor.py              ← transaction behaviour signals
├── sanctions_check.py         ← entity watchlist screening
├── crypto_aml.py              ← crypto wallet risk
├── aml_orchestrator.py        ← generic aggregator → AMLResult
└── banxe_aml_orchestrator.py  ← BANXE runtime → BanxeAMLResult
```

---

## Data Contracts (`models.py`)

| Class | Purpose |
|-------|---------|
| `TransactionInput` | Payment event (jurisdiction, amount, velocity) |
| `SanctionsSubject` | Entity to screen against watchlists |
| `WalletScreeningInput` | Crypto address + risk flags |
| `CustomerProfile` | KYC status, PEP flag, prior SAR count |
| `RiskSignal` | Single triggered rule (source, rule, score, reason) |
| `AMLResult` | Aggregated result from `aml_orchestrator` |

---

## Signal Rules Reference

### tx_monitor rules

| Rule | Score | Trigger |
|------|-------|---------|
| `HARD_BLOCK_JURISDICTION` | 100 | Category A jurisdiction |
| `HIGH_RISK_JURISDICTION` | +35 | Category B jurisdiction |
| `SINGLE_TX_THRESHOLD` | +30 | Amount ≥ £10,000 |
| `VELOCITY_24H` | +40 | 24h cumulative ≥ £25,000 |
| `POTENTIAL_STRUCTURING` | +60 | 3+ txs near threshold in 24h |
| `ROUND_AMOUNT` | +15 | Round amount ≥ £5,000 |
| `RAPID_IN_OUT` | +50 | Credit→debit < 1h |
| `CRYPTO_FLAG` | +20 | `is_crypto = True` |
| `FLAG_*` | +10 | Caller-supplied flags |

### sanctions_check rules

| Rule | Score | Trigger |
|------|-------|---------|
| `SANCTIONS_CONFIRMED` | 100 | Watchman match ≥ 95% |
| `SANCTIONS_PROBABLE` | 70 | Watchman match 80–95% |
| `SUBJECT_JURISDICTION_A` | 100 | Category A jurisdiction |
| `SUBJECT_JURISDICTION_B` | +35 | Category B jurisdiction |

### crypto_aml rules

| Rule | Score | Trigger |
|------|-------|---------|
| `CRYPTO_SANCTIONS` | 100 | OFAC address exact match |
| `CRYPTO_CRITICAL` | 90 | darknet/ransomware/terrorism flags |
| `CRYPTO_HIGH_RISK` | 70 | mixer/tumbler/scam/fraud flags |
| `CRYPTO_ELEVATED` | 40 | rapid_in_out/layering flags |
| `CRYPTO_HIGH_VALUE` | 20 | Transaction > £50,000 |

### banxe_aml_orchestrator customer rules

| Rule | Score | Trigger |
|------|-------|---------|
| `CUSTOMER_KYC_INCOMPLETE` | 40 | KYC status ≠ verified |
| `CUSTOMER_PEP` | 35 | `is_pep = True` |
| `CUSTOMER_HIGH_RISK_RATING` | 25 | risk_rating = "high" |
| `CUSTOMER_UNACCEPTABLE_RISK` | 70 | risk_rating = "unacceptable" |
| `CUSTOMER_PRIOR_SAR` | +15 per SAR (max 30) | prior_sars > 0 |
| `CUSTOMER_JURISDICTION_A` | 100 | Nationality/residence in Category A |
| `CUSTOMER_JURISDICTION_B` | +35 | Nationality/residence in Category B |
| `CUSTOMER_NEW_ACCOUNT` | +10 | Account age < 30 days |
