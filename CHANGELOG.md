# Changelog

All notable changes to Banxe AI Bank compliance stack are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning: [Semantic Versioning](https://semver.org/).

---

## [0.16.0] — 2026-04-05

### Added
- `models.py` — shared data contracts: `TransactionInput`, `SanctionsSubject`,
  `WalletScreeningInput`, `CustomerProfile`, `RiskSignal`, `AMLResult`
- `aml_orchestrator.py` — generic Layer 2 aggregator: `assess(tx, subject, wallet) → AMLResult`
- `banxe_aml_orchestrator.py` — Layer 3 BANXE runtime: `banxe_assess()` with `case_id`,
  `policy_version`, signal-priority decision engine (hard overrides + score floor)
- `CustomerProfile` dataclass: PEP status, risk rating, prior SAR count, KYC status
- `BanxeAMLResult.to_api_response()` and `.to_audit_dict()` for ClickHouse insert
- Backward-compat wrappers `check_sanctions()` and `check_wallet()` in refactored modules
- 3-layer AML block architecture documented in `COMPLIANCE_ARCH.md` Phase 16

### Changed
- `sanctions_check.py` — removed `httpx` dependency (→ stdlib `urllib`), removed
  `finsanctions` dependency (→ `difflib.SequenceMatcher`), input now `SanctionsSubject`,
  output now `list[RiskSignal]`
- `crypto_aml.py` — removed `httpx` and FINOS OpenAML dependency, pure heuristic
  scoring + Watchman stdlib, output now `list[RiskSignal]`
- `tx_monitor.py` — clean dict-access in smoke tests, removed dead `MonitoringResult` stub,
  removed duplicate local imports from `check_transaction()` body
- `api.py` — mapped `TransactionRequest` → `TransactionInput`, added missing `await`,
  fixed `tx["from"]` → `req.from_name`
- `COMPLIANCE_ARCH.md` — Phase 15 → 16, corrected threshold table (SAR ≥ 85 separate
  from REJECT ≥ 70), Layer 5 rewritten with full 3-layer ASCII diagram

### Fixed
- Smoke test Cat A (RU) expectation `REJECT` → `SAR` (score=100 ≥ SAR threshold=85)
- `api.py` runtime broken: `check_sanctions`, `check_wallet` were renamed in refactor

---

## [0.15.0] — 2026-04-03

### Added
- Phase 15: Collective LexisNexis unified compliance stack
- `verify_api.py` — HTTP wrapper for verification orchestrator (port 8094)
- `verify-statement` OpenClaw skill — agents call `/verify` before sending AML responses
- Verification pipeline: `compliance_agent` + `policy_agent` + `workflow_agent` + orchestrator
- Hard overrides: REFUTED confidence=1.0 for `without EDD`, PEP bypass patterns
- Training CI: `training-quality-report.yml` (deepeval + evidently, weekly)
- Adversarial sim cron: `/etc/cron.d/banxe-adversarial` (Sunday 02:00 on GMKtec)
- `backup-clickhouse-training.sh` — D-decisions export for training corpus
- SOUL.md protection: `chattr +i` + soul-protected canonical source + SOUL GUARD

### Changed
- `compliance_validator.py` — added 5 PEP/EDD forbidden patterns to fix false-positive:
  "Approve PEP without EDD" was CONFIRMED, now REFUTED confidence=1.0

### Fixed
- Verify API port conflict: 8091 (HITL Dashboard) → 8092 (Guiyon bridge) → 8094

---

## [0.14.0] — 2026-04-01

### Added
- Security hardening: `gateway.auth.token`, `configWrites:false`, mDNS off
- Verification environment: Semgrep (8 rules) + Snyk + pre-commit + CodeQL
- `check-tools-integrity.sh` — integrity verification for critical tools
- `banxe-verification-tests.yml` — LangGraph cross-verification CI (5 categories A-E)
- Sanctions policy: HARD REJECT (Category A) + EDD (Category B) in AGENTS.md

### Changed
- OpenClaw upgraded to 2026.3.24
- Model switched to `qwen3-banxe-v2` (qwen3:30b-a3b, thinking suppressed via empty `<think>`)

---

## [0.13.0] — 2026-04-02

### Added
- Phase 2a: Jube TM (AGPLv3, port 5001) — ML/probabilistic transaction monitoring
- Phase 2b: Marble case management (Apache 2.0, ports 5002/5003) — MLRO workbench
- Banxe Screener API (port 8085): Watchman + Wikidata SPARQL PEP
- Moov Watchman (port 8084, Apache 2.0): OFAC SDN, UN, EU, UK OFSI, FinCEN 311

---

## [0.1.0] — 2026-03-28

### Added
- Initial Banxe AI Bank compliance stack
- FastAPI gateway (port 8090) with 9 AML/KYC endpoints
- ClickHouse audit trail (5-year TTL, FCA MLR 2017)
- KYC via SumSub webhook integration
