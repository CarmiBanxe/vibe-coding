# COMPLIANCE_ARCH.md — AML/KYC Compliance Invariants Contract

**Repository:** `~/developer/compliance/` (reference implementation)  
**Downstream project:** `/home/mmber/vibe-coding/src/compliance/`  
**Version:** 1.0 | 2026-04-03  
**Authority:** FCA MLR 2017, OFAC, Jube AGPLv3

---

## Purpose

This document defines **immutable invariants** for the Banxe AI Bank AML/KYC compliance stack.

### Change protocol

Any change to these invariants requires:

1. Explicit user approval (CEO/CTIO or MLRO)
2. Regression test on known cases
3. Documentation update
4. Audit trail entry

**Silent changes are forbidden.**

---

## Invariants

### 1. Canonical Key Structure

```
Primary key: (jurisdiction_code, registration_number)
```

**Why:** Companies House alone is insufficient for international entities.

**Never use:** `company_number` as standalone identifier.

**Examples:**
```python
# CORRECT
{"jurisdiction_code": "GB", "registration_number": "12345678"}

# WRONG
{"company_number": "12345678"}  # Missing jurisdiction
```

---

### 2. OFAC RSS Status

```
OFAC RSS feed: DEAD since 31 January 2025
```

**Source:** HTML scrape only (`https://sanctionssearch.ofac.treas.gov/`)

**Implementation:** `compliance/sanctions_check.py` uses BeautifulSoup parser.

**Never attempt:** RSS feed parsing, API calls to dead endpoints.

---

### 3. Watchman Match Threshold

```
minMatch: 0.80 (Jaro-Winkler similarity)
```

**Source:** Moov Watchman integration

**Calibration:**
- Below 0.80: Too many false positives
- Above 0.80: Risk of false negatives
- Exactly 0.80: Balanced for FCA expectations

**Change requires:** MLRO approval + regression test on 100+ known cases.

---

### 4. ClickHouse Audit Retention

```
TTL: 5 YEAR (from transaction date)
```

**Legal basis:** FCA Money Laundering Regulations 2017

**Requirement:** Records retained for minimum 5 years after business relationship ends.

**Implementation:**
```sql
CREATE TABLE audit_trail (
    ...
) ENGINE = MergeTree()
ORDER BY (entity_id, timestamp)
TTL event_date + INTERVAL 5 YEAR;
```

**Never reduce:** Legal minimum, not technical preference.

---

### 5. Jube License Boundary

```
License: AGPLv3 (internal use only)
```

**Restriction:** Cannot expose Jube TM engine via public API without commercial license.

**Current status:** Internal compliance checks only (port 5001, localhost).

**If public API needed:** Purchase commercial license or implement alternative.

---

### 6. GUIYON Exclusion

```
GUIYON (port 18794): Categorically excluded from Banxe AI Bank
```

**Reason:** Separate entity, different business purpose.

**Never:**
- Import GUIYON code into Banxe compliance stack
- Share database connections
- Reuse authentication tokens
- Cross-contaminate audit trails

**Violation:** Corporate veil piercing risk.

---

## Decision Thresholds

### Risk Scoring

| Composite Score | Decision | Action | SAR Required |
|-----------------|----------|--------|--------------|
| ≥ 70 | REJECT | Block transaction | Yes (if >85) |
| 40–69 | HOLD | Enhanced due diligence | Case-by-case |
| < 40 | APPROVE | Pass | No |

### Sanctions Hit

```
sanctions_hit = true → REJECT (always)
```

**Regardless of composite score.**

**SAR:** Mandatory if sanctions match confirmed.

### Auto-SAR Threshold

```
composite_score ≥ 85 OR sanctions_hit = true → SAR auto-filed
```

**Human review:** Still required before submission to NCA.

---

## Source Weights (Read-Only Reference)

| Source | Weight | Category |
|--------|--------|----------|
| OFAC SDN | 40% | Sanctions |
| EU Consolidated | 30% | Sanctions |
| UK HMT | 30% | Sanctions |
| PEP Database | 20% | Adverse media |
| adverse_media | 15% | Negative news |
| Crypto AML | 10% | Blockchain analysis |
| Velocity checks | 5% | Behavioral |

**Total can exceed 100%** — categories are additive, not normalized.

**Never change weights** without recalibration study.

---

## Regulatory Sources

### Primary legislation

- Money Laundering Regulations 2017 (UK)
- Proceeds of Crime Act 2002 (POCA)
- Terrorism Act 2000
- Sanctions and Anti-Money Laundering Act 2018 (SAMLA)

### Guidance

- FCA Financial Crime Guide (latest)
- Joint Money Laundering Steering Group (JMLSG) guidance
- National Risk Assessment (NRA) 2024

### Sanctions lists

- OFAC SDN (US) — HTML scrape only
- EU Consolidated List
- UK HMT Consolidated List
- UN Security Council Resolutions

---

## Implementation Files

| File | Purpose | Invariant coverage |
|------|---------|-------------------|
| `api.py` | REST API endpoints | Thresholds, SAR logic |
| `sanctions_check.py` | OFAC/PEP screening | minMatch, source weights |
| `audit_trail.py` | ClickHouse logging | TTL, schema |
| `tx_monitor.py` | Transaction monitoring | Risk scoring |
| `crypto_aml.py` | Crypto AML | Blockchain analysis |
| `test_suite.py` | Test harness | All (regression) |

---

## Testing Requirements

### Before any production change

1. **Unit tests** — individual function correctness
2. **Integration tests** — end-to-end flow
3. **Regression tests** — known cases still pass
4. **Threshold tests** — boundary conditions correct
5. **Audit tests** — all actions logged

### Known test cases (must pass)

| Case ID | Input | Expected Score | Decision |
|---------|-------|----------------|----------|
| TC001 | Clean GB company | <40 | APPROVE |
| TC002 | OFAC SDN match | ≥70 + sanctions_hit | REJECT + SAR |
| TC003 | PEP hit only | 40-69 | HOLD |
| TC004 | Adverse media only | 15-40 | APPROVE (low risk) |
| TC005 | Multiple sources | ≥85 | REJECT + auto-SAR |

---

## Rollback Procedure

If a compliance change causes issues:

1. **Immediate:** Revert to previous git commit
2. **Short-term:** Restore from backup
3. **Medium-term:** Fix in staging, re-test
4. **Long-term:** Update this contract if invariant was wrong

### Audit trail requirement

All rollbacks logged with:
- Timestamp
- Reason
- Author
- Approver (MLRO)

---

## People and Authority

| Role | Person | Approval scope |
|------|--------|----------------|
| CEO/CTIO | Moriel Carmi | All technical changes |
| MLRO | (TBD) | Threshold/weight changes |
| Head of Compliance | (TBD) | Policy changes |
| Developer | Any | Implementation (no invariant changes) |

---

## Version History

| Version | Date | Change | Approved By |
|---------|------|--------|-------------|
| 1.0 | 2026-04-03 | Initial invariants contract | Moriel Carmi |

---

## Related Documents

- `docs/MEMORY.md` — Project memory (operational notes)
- `docs/SYSTEM-STATE.md` — Server state tracking
- `AGENTS.md` — Agent instructions (this repo + downstream)
- `.qoder/context.md` — Qoder execution contract

---

## Quick Reference Card

```
═══════════════════════════════════════
  COMPLIANCE INVARIANTS — QUICK REF
═══════════════════════════════════════

1. Key: (jurisdiction_code, registration_number)
2. OFAC RSS: DEAD → HTML scrape only
3. minMatch: 0.80 (Jaro-Winkler)
4. TTL: 5 YEAR (ClickHouse)
5. Jube: AGPLv3 internal only
6. GUIYON: EXCLUDED

Thresholds:
  ≥70 → REJECT
  40-69 → HOLD
  <40 → APPROVE
  sanctions_hit → REJECT (always)

Auto-SAR: ≥85 OR sanctions_hit
═══════════════════════════════════════
```


## Jurisdiction Classification (Updated 2026-04-05)

**Authority:** OFAC, UK OFSI, EU Sanctions, FATF, EU AML High-Risk List, Banxe internal policy
**Change protocol:** Same as all invariants (§Change protocol above)

### Regulatory Layers (all apply simultaneously for UK EMI)

| Priority | Authority | Scope |
|----------|-----------|-------|
| 1 | OFAC (USA) | USD correspondence + secondary sanctions |
| 2 | UK OFSI / UK Sanctions List | Mandatory for UK EMI (OFSI Consolidated → UK Sanctions List since 28.01.2026) |
| 3 | EU Sanctions | EUR settlements + EU operations |
| 4 | FATF / EU AML High-Risk List | EDD requirement (not auto-block) |

**Critical distinction:** FATF Grey List ≠ transaction ban. It requires EDD, not automatic blocking.

### Category A: HARD BLOCK (Restricted — all regulators)

Transactions **unconditionally prohibited**. Code ref: `_HARD_BLOCK_JURISDICTIONS` in `compliance_validator.py`

| Code | Country/Region | OFAC | EU | UK | FATF | Banxe |
|------|---------------|------|----|----|------|-------|
| RU | Russia | Sectoral | Sanctions + AML HR (29.01.2026) | Yes | No | Restricted |
| BY | Belarus | Sectoral | Yes | Yes | — | Restricted |
| IR | Iran | Full embargo | Yes | Yes | Blacklist | Restricted |
| KP | North Korea (DPRK) | Full embargo | Yes | Yes | Blacklist | Restricted |
| CU | Cuba | Full embargo | — | Yes | — | Restricted |
| MM | Myanmar | Targeted | Yes | Yes | Enhanced | Restricted |
| AF | Afghanistan | Targeted | — | Yes | — | Restricted |
| VE | Venezuela | Gov. blocked | Yes | Yes | Greylist | Restricted |
| CRIMEA | Crimea | Regional embargo | Yes | Yes | — | (Russia) |
| DNR | Donetsk | Regional embargo | Yes | Yes | — | (Russia) |
| LNR | Luhansk | Regional embargo | Yes | Yes | — | (Russia) |

### Category B: HIGH RISK (EDD mandatory)

Countries in FATF greylist and/or EU AML High-Risk List. Code ref: `_HIGH_RISK_JURISDICTIONS` in `compliance_validator.py`

| Code | Country | EU AML HR | FATF Grey | Notes |
|------|---------|-----------|-----------|-------|
| SY | Syria | Yes (since 2016) | Yes | OFAC comprehensive sanctions LIFTED 01.07.2025; SDN entries remain for Assad circle |
| IQ | Iraq | — | — | EU targeted sanctions; Banxe High |
| LB | Lebanon | Yes (05.08.2025) | Yes | EU targeted sanctions |
| YE | Yemen | — | Yes | Conflict program |
| HT | Haiti | Yes (13.03.2022) | Yes | — |
| ML | Mali | Yes (13.03.2022) | — | Conflict program |
| DZ | Algeria | Yes (05.08.2025) | Yes | NEW 2025 |
| AO | Angola | Yes (05.08.2025) | Yes | NEW 2025 |
| BO | Bolivia | Yes (29.01.2026) | Yes | NEW 2026 |
| VG | British Virgin Islands | Yes (29.01.2026) | Yes (06.2025) | NEW 2025-2026 |
| CM | Cameroon | Yes (18.10.2023) | Yes | — |
| CI | Cote d'Ivoire | Yes (05.08.2025) | Yes | — |
| CD | DR Congo | Yes (16.03.2023) | Yes | Conflict program |
| KE | Kenya | Yes (05.08.2025) | Yes | NEW 2024 |
| LA | Laos | Yes (05.08.2025) | Yes | — |
| MC | Monaco | Yes (05.08.2025) | Yes | NEW 2024 |
| NA | Namibia | Yes (05.08.2025) | Yes | NEW 2024 |
| NP | Nepal | Yes (05.08.2025) | Yes | NEW 2025 |
| SS | South Sudan | Yes (13.03.2022) | Yes | Conflict program |
| TT | Trinidad and Tobago | Yes (06.03.2018) | — | — |
| VU | Vanuatu | Yes (23.09.2016) | — | — |
| BG | Bulgaria | — | Yes | FATF only (2024) |
| VN | Vietnam | — | Yes | FATF only |

### Category C: ELEVATED RISK (operator discretion)

Not formally sanctioned but restricted by payment networks and peer EMIs (Revolut, MultiPass):

AM (Armenia), AZ (Azerbaijan), GE (Georgia), KZ (Kazakhstan), KG (Kyrgyzstan),
TJ (Tajikistan), UZ (Uzbekistan), TR (Turkey), AE (UAE), IL (Israel),
RS (Serbia), CN (China), HK (Hong Kong), PK (Pakistan), TH (Thailand)

### Key Changes 2025-2026

#### Lifted (access expanded)
- **Syria** — OFAC comprehensive sanctions lifted 01.07.2025 (EO 14312); EU/UK also lifted most restrictions. Targeted SDN entries remain (Assad circle, ISIS/AQ, Iran proxies)
- Burkina Faso, Mozambique, Nigeria, South Africa — removed from FATF greylist (October 2025)
- Burkina Faso, Mali, Mozambique, Nigeria, South Africa, Tanzania — removed from EU AML HR (December 2025)

#### Added (restrictions tightened)
- **Russia** → EU AML High-Risk List (29.01.2026) — autonomous EU decision, NOT FATF-driven
- Bolivia → EU AML HR + FATF greylist (01.2026)
- British Virgin Islands → EU AML HR + FATF greylist (06.2025 / 01.2026)
- Nepal → FATF greylist (2025)

### Syria — Special Status

Syria requires special handling post-July 2025:
- **NOT** auto-blocked (OFAC comprehensive lifted)
- **HOLD + manual SDN check** required
- Remaining sanctions: Assad regime, human rights violators, ISIS/Al-Qaeda, Iran proxies
- EU AML High-Risk status may persist independently
- Banxe internal policy still lists Syria as Restricted — **policy update pending**

### Source Weights for Sanctions Screening

(moved from above for completeness — weights unchanged)

| Source | Weight | Category |
|--------|--------|----------|
| OFAC SDN | 40% | Sanctions |
| EU Consolidated | 30% | Sanctions |
| UK HMT / UK Sanctions List | 30% | Sanctions |
| PEP Database | 20% | Adverse media |
| adverse_media | 15% | Negative news |
| Crypto AML | 10% | Blockchain analysis |
| Velocity checks | 5% | Behavioral |

### Implementation Note

The `compliance_validator.py` must be updated to reflect Category B expansion.
Current code has minimal `_HIGH_RISK_JURISDICTIONS = {SY, IQ, LB, YE, HT, ML}`.
Full list from this section should be synchronized.
