# ADR 0001 — Use Moov Watchman instead of LexisNexis for sanctions screening

**Status:** Accepted  
**Date:** 2026-04-01  
**Deciders:** Moriel Carmi (CEO), Олег (CTIO)

---

## Context

Banxe AI Bank requires sanctions and PEP screening at every customer onboarding and payment
event. The industry-standard solution is **LexisNexis Risk Solutions** (or alternatives:
Dow Jones Risk & Compliance, World-Check/Refinitiv).

Commercial costs:
- LexisNexis Risk Solutions: ~$100,000+/year for an EMI-tier licence
- Dow Jones: similar pricing tier
- World-Check: per-query or annual flat fee, typically $50K–$150K

As a startup EMI in pre-authorisation phase, committing to $100K+/year vendor contracts
before achieving revenue is not viable. The FCA does not mandate a specific vendor —
it mandates an *effective* screening process with documented risk-based justification.

The available open-source alternative is **Moov Watchman** (Apache 2.0), which bundles:
- OFAC SDN and Consolidated (US Treasury)
- UN Consolidated List
- EU Consolidated List
- UK OFSI Consolidated List
- US-CSL (Commerce Entity List)
- FinCEN Section 311 list

Lists are updated on Watchman's release cycle and can be refreshed via CLI.

---

## Decision

Use **Moov Watchman** (port 8084, binary `/usr/local/bin/banxe-watchman`) as the primary
sanctions screening engine, with the following calibration:

- **minMatch = 0.80** (Jaro-Winkler algorithm)
  - Below 0.80 → false positive rate unacceptable
  - Above 0.92 → known aliases ("Vladimir Vladimirovich PUTIN" from "Vladimir Putin") missed
  - 0.80 calibrated against MLRO-reviewed test set of 50 known-clean + 20 known-hit names

- **Fallback:** `difflib.SequenceMatcher` against a curated local list of 13 high-profile
  entities for offline-safe operation when Watchman is unreachable

- **Match confidence tiers:**
  - ≥ 95% → `SANCTIONS_CONFIRMED` (score=100, auto-REJECT, MLRO notification)
  - 80–95% → `SANCTIONS_PROBABLE` (score=70, REJECT pending MLRO review)

---

## Consequences

**Positive:**
- Zero licensing cost during startup phase
- Full control over data and configuration
- Apache 2.0 licence — no usage restrictions
- Offline operation possible (local binary + downloaded lists)

**Negative / Risks:**
- List update frequency is lower than commercial vendors (days vs minutes)
- No global PEP relatives/associates database (only direct watchlist hits)
- No adverse media, litigation, or corporate registry enrichment
- FCA Production authorisation will likely require a commercial vendor supplement
  (Dow Jones or LexisNexis as a secondary source)

**Mitigations:**
- Watchman list refresh automated via cron (`banxe-watchman download`)
- PEP enrichment via Wikidata SPARQL (14,491 legislators in local PostgreSQL)
- Document this limitation in FCA licence application as "sandbox phase, vendor under evaluation"
- Re-evaluate at £1M ARR or FCA full-authorisation milestone

---

## Review

This decision should be revisited when:
1. FCA full authorisation application is filed
2. Monthly transaction volume exceeds 10,000 screenings
3. A false-negative incident is identified in production
