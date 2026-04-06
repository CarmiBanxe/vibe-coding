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
