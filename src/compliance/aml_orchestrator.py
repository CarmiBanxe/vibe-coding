#!/usr/bin/env python3
"""
AML Orchestrator — the "Collective LexisNexis"

Single entry point that aggregates signals from all three AML layers:
  - tx_monitor      → deterministic transaction rules (velocity, structuring, jurisdiction)
  - sanctions_check → entity watchlist screening (Watchman OFAC/UN/EU/UK)
  - crypto_aml      → crypto wallet risk (OFAC address, mixer, darknet, ...)

All layers produce list[RiskSignal]. This orchestrator:
  1. Runs all applicable layers (async where possible)
  2. Caps composite score at 100
  3. Maps score to decision using thresholds from compliance_validator (Layer 1)
  4. Builds AMLResult with full audit payload

Decision thresholds (source of truth: compliance_validator.py):
  APPROVE   score <  40
  HOLD      40 <= score < 70   → EDD required
  REJECT    70 <= score < 85   → transaction blocked
  SAR       score >= 85        → MLRO notified, SAR obligation

Hard overrides (always REJECT regardless of score):
  - Any HARD_BLOCK_JURISDICTION signal (Category A)
  - Any SANCTIONS_CONFIRMED signal (OFAC exact match)
  - Any CRYPTO_SANCTIONS signal

Usage:
    from compliance.aml_orchestrator import assess
    result: AMLResult = await assess(tx, subject, wallet)
"""
from __future__ import annotations

import asyncio
from typing import Optional

from compliance.models import (
    TransactionInput,
    SanctionsSubject,
    WalletScreeningInput,
    RiskSignal,
    AMLResult,
)
from compliance.verification.compliance_validator import (
    _THRESHOLD_SAR,
    _THRESHOLD_REJECT,
    _THRESHOLD_HOLD,
)

# ── Import the three AML layers ───────────────────────────────────────────────
from compliance.tx_monitor      import score_transaction
from compliance.sanctions_check import screen_entity
from compliance.crypto_aml      import analyse_chain

__all__ = ["assess"]

# Rules that always force REJECT regardless of composite score
_HARD_OVERRIDE_RULES = frozenset({
    "HARD_BLOCK_JURISDICTION",      # tx_monitor — Category A jurisdiction
    "SUBJECT_JURISDICTION_A",       # sanctions_check — Category A jurisdiction
    "SANCTIONS_CONFIRMED",          # sanctions_check — OFAC exact match
    "CRYPTO_SANCTIONS",             # crypto_aml — OFAC sanctioned address
})


# ── Core orchestration ────────────────────────────────────────────────────────

async def assess(
    tx:      Optional[TransactionInput]      = None,
    subject: Optional[SanctionsSubject]      = None,
    wallet:  Optional[WalletScreeningInput]  = None,
) -> AMLResult:
    """
    Run all applicable AML layers and return a single AMLResult.

    Any combination of inputs is valid:
      - tx only       → transaction monitoring (velocity, structuring, jurisdiction)
      - subject only  → entity screening (sanctions, PEP, jurisdiction)
      - wallet only   → crypto wallet screening (OFAC address, mixer, ...)
      - all three     → full stack (typical for crypto payments)
    """
    all_signals: list[RiskSignal] = []
    meta: dict = {}

    # ── Layer 1: Transaction monitoring (async, with Redis velocity) ───────────
    if tx is not None:
        tx_signals, tx_meta = await score_transaction(tx)
        all_signals.extend(tx_signals)
        meta.update(tx_meta)

    # ── Layer 2: Entity screening (sync, wrapped in executor) ─────────────────
    if subject is not None:
        loop = asyncio.get_event_loop()
        sanctions_signals = await loop.run_in_executor(None, screen_entity, subject)
        all_signals.extend(sanctions_signals)

    # ── Layer 3: Crypto wallet screening (sync, wrapped in executor) ───────────
    if wallet is not None:
        loop = asyncio.get_event_loop()
        crypto_signals = await loop.run_in_executor(None, analyse_chain, wallet)
        all_signals.extend(crypto_signals)

    # ── Score aggregation ─────────────────────────────────────────────────────
    raw_score    = sum(s.score for s in all_signals)
    score        = min(raw_score, 100)
    requires_edd = any(s.requires_edd  for s in all_signals)
    requires_mlro= any(s.requires_mlro for s in all_signals)

    # ── Hard override check ───────────────────────────────────────────────────
    triggered_rules  = {s.rule for s in all_signals}
    hard_override_hit= bool(triggered_rules & _HARD_OVERRIDE_RULES)
    sanctions_hit    = any(s.rule in ("SANCTIONS_CONFIRMED", "SANCTIONS_PROBABLE",
                                      "SUBJECT_JURISDICTION_A")
                           for s in all_signals)
    hard_block_hit   = any(s.rule in ("HARD_BLOCK_JURISDICTION",
                                      "SUBJECT_JURISDICTION_A",
                                      "CRYPTO_SANCTIONS")
                           for s in all_signals)
    crypto_risk      = any(s.source == "crypto_aml" for s in all_signals)

    # ── Decision mapping ──────────────────────────────────────────────────────
    # Hard override → always REJECT (may also trigger SAR if score ≥ threshold)
    if hard_override_hit:
        # If score is already in SAR territory, honour SAR
        decision = "SAR" if score >= _THRESHOLD_SAR else "REJECT"
    else:
        decision = ("SAR"    if score >= _THRESHOLD_SAR    else
                    "REJECT" if score >= _THRESHOLD_REJECT else
                    "HOLD"   if score >= _THRESHOLD_HOLD   else "APPROVE")

    # ── Build audit payload ───────────────────────────────────────────────────
    audit_payload = {
        "rules_triggered":  sorted(triggered_rules),
        "signal_count":     len(all_signals),
        "raw_score":        raw_score,
        "hard_override":    hard_override_hit,
        **meta,
    }

    return AMLResult(
        score=score,
        decision=decision,
        signals=all_signals,
        requires_edd=requires_edd,
        requires_mlro_review=requires_mlro,
        hard_block_hit=hard_block_hit,
        sanctions_hit=sanctions_hit,
        crypto_risk=crypto_risk,
        audit_payload=audit_payload,
    )


# ── __main__ smoke tests ──────────────────────────────────────────────────────

if __name__ == "__main__":

    async def _run_smoke_tests():
        sep = "=" * 60
        print(f"\n{sep}")
        print("  aml_orchestrator.py — smoke tests")
        print(f"  Thresholds: SAR>={_THRESHOLD_SAR}, "
              f"REJECT>={_THRESHOLD_REJECT}, HOLD>={_THRESHOLD_HOLD}")
        print(sep)

        scenarios = [
            # ── (label, expected_decision, tx, subject, wallet) ──────────────
            (
                "APPROVE — clean UK domestic",
                "APPROVE",
                TransactionInput("GB", "DE", 500.0, currency="GBP"),
                None, None,
            ),
            (
                "HOLD — single-tx above reporting threshold",
                "HOLD",
                TransactionInput("GB", "GB", 12_000.0, currency="GBP"),
                None, None,
            ),
            (
                "REJECT — Category A hard block (RU)",
                "REJECT",
                TransactionInput("RU", "GB", 200.0, currency="GBP"),
                None, None,
            ),
            (
                "SAR — high-risk jurisdiction + large amount",
                "SAR",
                TransactionInput("SY", "GB", 20_000.0, currency="GBP"),
                None, None,
            ),
            (
                "REJECT — sanctions confirmed (entity screen)",
                "REJECT",
                None,
                SanctionsSubject("Vladimir Putin", entity_type="person", jurisdiction="RU"),
                None,
            ),
            (
                "REJECT — crypto mixer flag",
                "REJECT",
                TransactionInput("GB", "GB", 5_000.0, currency="GBP", is_crypto=True),
                None,
                WalletScreeningInput(
                    address="0xAbc1234567890abcdef1234567890abcdef123456",
                    chain="eth",
                    risk_flags=["mixer"],
                    tx_value_usd=6_000,
                ),
            ),
            (
                "HOLD — PEP in Cat B jurisdiction (entity only)",
                "HOLD",
                None,
                SanctionsSubject("Ahmad Hassan", entity_type="person", jurisdiction="SY"),
                None,
            ),
        ]

        passed = failed = 0
        for label, expected, tx, subject, wallet in scenarios:
            result = await assess(tx=tx, subject=subject, wallet=wallet)
            ok = result.decision == expected
            mark = "OK" if ok else "FAIL"
            if ok:
                passed += 1
            else:
                failed += 1
            print(f"\n  {mark} [{label}]")
            print(f"     decision={result.decision} (expected={expected})  "
                  f"score={result.score}  "
                  f"edd={result.requires_edd}  mlro={result.requires_mlro_review}  "
                  f"hard_block={result.hard_block_hit}")
            for sig in result.signals:
                print(f"     [{sig.score:+d}] {sig.source}/{sig.rule}: "
                      f"{sig.reason[:70]}")

        print(f"\n{sep}")
        print(f"  Results: {passed} passed, {failed} failed")
        print(f"{sep}\n")

    asyncio.run(_run_smoke_tests())
