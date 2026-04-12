#!/usr/bin/env python3
"""
Transaction Monitor — Layer 2 (Behavioural Monitoring)

Orchestration layer that applies deterministic AML rules to transactions
and produces a composite risk score + decision.

Decision thresholds are imported from compliance_validator (Layer 1, source-of-truth):
  _THRESHOLD_SAR    = 85   → SAR obligation + auto-file trigger
  _THRESHOLD_REJECT = 70   → REJECT transaction
  _THRESHOLD_HOLD   = 40   → HOLD + EDD required (below = APPROVE)

Jurisdiction lists are imported from compliance_validator (Layer 1, source-of-truth):
  _HARD_BLOCK_JURISDICTIONS  → Category A: sanctions (RU, BY, IR, KP, ...)
                                Rule: immediate REJECT, score=100, MLRO notified
  _HIGH_RISK_JURISDICTIONS   → Category B: EDD (SY, IQ, LB, YE, ...)
                                Rule: score += 35, EDD mandatory, HOLD unless clear

Jube TM (AGPLv3, port 5001) handles the ML/probabilistic layer; this module
handles only deterministic rule-based monitoring.

sanctions_check and crypto_aml are called by aml_orchestrator, not directly here.
"""
from __future__ import annotations

import asyncio
import time
from typing import Optional

# ── Shared datamodel (models.py) ──────────────────────────────────────────────
from compliance.models import TransactionInput, RiskSignal

# ── Source-of-truth imports from Layer 1 (compliance_validator) ──────────────
from compliance.verification.compliance_validator import (
    _HARD_BLOCK_JURISDICTIONS,
    _HIGH_RISK_JURISDICTIONS,
    _THRESHOLD_SAR,
    _THRESHOLD_REJECT,
    _THRESHOLD_HOLD,
)
from compliance.utils.config_loader import get_mlr_reporting_threshold_gbp

# Redis for velocity counters (optional — graceful fallback if unavailable)
try:
    import redis.asyncio as aioredis
    REDIS_AVAILABLE = True
except ImportError:
    REDIS_AVAILABLE = False

REDIS_URL = "redis://127.0.0.1:6379"

# ── Module-level constants (NOT jurisdiction or threshold policy) ─────────────
# These are operational parameters for rule windows, NOT compliance thresholds.
# Compliance thresholds are imported above from compliance_validator.

_MLR_REPORTING_THRESHOLD_GBP = get_mlr_reporting_threshold_gbp()  # from compliance_config.yaml
_STRUCTURING_WINDOW_SEC      = 86_400   # 24h structuring detection window
_STRUCTURING_MIN_TX          = 3        # min transactions to trigger structuring flag
_VELOCITY_WINDOW_SEC         = 86_400   # 24h velocity window
_VELOCITY_24H_LIMIT_GBP      = 25_000   # cumulative 24h flag threshold
_ROUND_AMOUNT_MIN_GBP        = 5_000    # minimum amount to check for round-number pattern
_RAPID_IN_OUT_WINDOW_SEC     = 3_600    # 1h layering detection window

# FX rates (approximate, for scoring only — not for settlement)
_FX_RATES = {"GBP": 1.0, "EUR": 0.86, "USD": 0.79, "USDT": 0.79, "ETH": 2500.0}

__all__ = ["score_transaction"]


# ── Redis velocity helpers ────────────────────────────────────────────────────

async def _get_redis() -> Optional[object]:
    if not REDIS_AVAILABLE:
        return None
    try:
        r = aioredis.from_url(REDIS_URL, decode_responses=True)
        await r.ping()
        return r
    except Exception:
        return None


async def _add_velocity(r, account: str, amount: float, window: int) -> float:
    if not r:
        return amount
    now = time.time()
    key = f"banxe:velocity:{account}"
    tx_id = f"{now}:{amount}"
    try:
        pipe = r.pipeline()
        await pipe.zadd(key, {tx_id: now})
        await pipe.zremrangebyscore(key, 0, now - window)
        await pipe.execute()
        members = await r.zrange(key, 0, -1)
        total = sum(float(m.split(":")[1]) for m in members if ":" in m)
        await r.expire(key, window + 3600)
        return total
    except Exception:
        return amount


async def _get_recent_tx_count(r, account: str, window: int) -> int:
    if not r:
        return 1
    now = time.time()
    key = f"banxe:velocity:{account}"
    try:
        return await r.zcount(key, now - window, now)
    except Exception:
        return 1


# ── Scoring rules ─────────────────────────────────────────────────────────────

async def score_transaction(tx: TransactionInput) -> tuple[list[RiskSignal], dict]:
    """
    Apply deterministic transaction monitoring rules.
    Returns (signals, meta) where meta carries velocity data for audit.

    Rule order:
      1. Category A (hard-block) jurisdiction  → score=100, short-circuit
      2. Category B (high-risk) jurisdiction   → score += 35, EDD required
      3. Single-tx MLR reporting threshold     → score += 30
      4. 24h velocity (cumulative)             → score += 40
      5. Structuring (split payments)          → score += 60
      6. Round amount (smurfing indicator)     → score += 15
      7. Rapid in-out (layering)               → score += 50
      8. Crypto flag                           → score += 20 (crypto_aml handles detail)
      9. Caller-supplied flags                 → score += 10 each
    """
    signals: list[RiskSignal] = []

    origin = (tx.origin_jurisdiction or "").upper()
    dest   = (tx.destination_jurisdiction or "").upper()
    affected = {j for j in (origin, dest) if j}

    # ── Rule 1: Category A ────────────────────────────────────────────────────
    hard_hits = affected & _HARD_BLOCK_JURISDICTIONS
    if hard_hits:
        signals.append(RiskSignal(
            source="tx_monitor", rule="HARD_BLOCK_JURISDICTION", score=100,
            reason=f"Category A (HARD BLOCK): {hard_hits} — SAMLA 2018 / UK HMT. MLRO notified.",
            authority="SAMLA 2018 / UK HMT Consolidated List",
            requires_edd=True, requires_mlro=True,
        ))
        r = await _get_redis()
        velocity = await _add_velocity(r, tx.sender_account, tx.amount_gbp, _VELOCITY_WINDOW_SEC)
        tx_count = await _get_recent_tx_count(r, tx.sender_account, _VELOCITY_WINDOW_SEC)
        if r: await r.aclose()
        return signals, {"velocity_24h_gbp": round(velocity, 2), "tx_count_24h": tx_count, "hard_block": True}

    # ── Rule 2: Category B ────────────────────────────────────────────────────
    high_hits = affected & _HIGH_RISK_JURISDICTIONS
    if high_hits:
        signals.append(RiskSignal(
            source="tx_monitor", rule="HIGH_RISK_JURISDICTION", score=35,
            reason=f"Category B (HIGH RISK): {high_hits} — EDD mandatory (FCA EDD §4.2).",
            authority="FCA EDD §4.2", requires_edd=True,
        ))

    # ── Rule 3: Single-tx threshold ──────────────────────────────────────────
    if tx.amount_gbp >= _MLR_REPORTING_THRESHOLD_GBP:
        signals.append(RiskSignal(
            source="tx_monitor", rule="SINGLE_TX_THRESHOLD", score=30,
            reason=f"£{tx.amount_gbp:,.0f} >= £{_MLR_REPORTING_THRESHOLD_GBP:,} MLR 2017 reporting threshold.",
            authority="MLR 2017",
        ))

    # ── Rules 4+5: Velocity & structuring ────────────────────────────────────
    r = await _get_redis()
    velocity_total = await _add_velocity(r, tx.sender_account, tx.amount_gbp, _VELOCITY_WINDOW_SEC)
    tx_count = await _get_recent_tx_count(r, tx.sender_account, _STRUCTURING_WINDOW_SEC)

    if velocity_total >= _VELOCITY_24H_LIMIT_GBP:
        signals.append(RiskSignal(
            source="tx_monitor", rule="VELOCITY_24H", score=40,
            reason=f"24h cumulative £{velocity_total:,.0f} >= £{_VELOCITY_24H_LIMIT_GBP:,}.",
            authority="MLR 2017 §7 — ongoing monitoring",
        ))

    structuring_lower = _MLR_REPORTING_THRESHOLD_GBP * 0.80
    if (structuring_lower <= tx.amount_gbp < _MLR_REPORTING_THRESHOLD_GBP
            and tx_count >= _STRUCTURING_MIN_TX):
        signals.append(RiskSignal(
            source="tx_monitor", rule="POTENTIAL_STRUCTURING", score=60,
            reason=f"£{tx.amount_gbp:,.0f} just below threshold, {tx_count} txs in 24h — structuring indicator.",
            authority="POCA 2002 §327-329", requires_mlro=True,
        ))

    # ── Rule 6: Round amount ──────────────────────────────────────────────────
    if tx.amount_gbp >= _ROUND_AMOUNT_MIN_GBP and tx.amount_gbp == round(tx.amount_gbp, -3):
        signals.append(RiskSignal(
            source="tx_monitor", rule="ROUND_AMOUNT", score=15,
            reason=f"Round amount £{tx.amount_gbp:,.0f} — smurfing indicator.",
        ))

    # ── Rule 7: Rapid in-out (layering) ──────────────────────────────────────
    if r:
        try:
            last_credit = await r.get(f"banxe:last_credit:{tx.sender_account}")
            if last_credit and tx.amount_gbp >= 1000:
                elapsed = time.time() - float(last_credit)
                if elapsed < _RAPID_IN_OUT_WINDOW_SEC:
                    signals.append(RiskSignal(
                        source="tx_monitor", rule="RAPID_IN_OUT", score=50,
                        reason=f"Funds credited {elapsed:.0f}s ago, immediately re-sent — layering indicator.",
                        authority="JMLSG Part I §6.12", requires_mlro=True,
                    ))
            await r.setex(f"banxe:last_debit:{tx.sender_account}", _VELOCITY_WINDOW_SEC, str(time.time()))
        except Exception:
            pass

    # ── Rule 8: Crypto flag ───────────────────────────────────────────────────
    if tx.is_crypto:
        signals.append(RiskSignal(
            source="tx_monitor", rule="CRYPTO_FLAG", score=20,
            reason="Crypto transaction — elevated monitoring. Routed to crypto_aml for chain analysis.",
        ))

    # ── Rule 9: Caller flags ──────────────────────────────────────────────────
    for flag in tx.flags:
        signals.append(RiskSignal(
            source="tx_monitor", rule=f"FLAG_{flag.upper()}", score=10,
            reason=f"Caller-supplied flag: '{flag}'.",
        ))

    if r: await r.aclose()
    return signals, {"velocity_24h_gbp": round(velocity_total, 2), "tx_count_24h": tx_count, "hard_block": False}


# Backwards-compatible alias used by existing callers
async def check_transaction(tx) -> dict:
    """Legacy wrapper — use aml_orchestrator.assess() for new code.

    Accepts either a TransactionInput dataclass or a legacy dict with keys:
      from, to, amount, currency, tx_type, jurisdiction
    """
    if isinstance(tx, dict):
        tx = TransactionInput(
            origin_jurisdiction=(tx.get("jurisdiction") or "GB").upper(),
            destination_jurisdiction=(tx.get("to_jurisdiction") or tx.get("jurisdiction") or "GB").upper(),
            amount_gbp=float(tx.get("amount", 0)),
            currency=tx.get("currency", "GBP"),
        )
    signals, meta = await score_transaction(tx)
    score = min(sum(s.score for s in signals), 100)
    decision = ("SAR" if score >= _THRESHOLD_SAR else
                "REJECT" if score >= _THRESHOLD_REJECT else
                "HOLD" if score >= _THRESHOLD_HOLD else "APPROVE")
    return {
        "flagged": score >= _THRESHOLD_HOLD,
        "risk_score": score,
        "recommended_action": decision,
        "rules_triggered": [{"rule": s.rule, "detail": s.reason, "score": s.score} for s in signals],
        **meta,
    }



# ── TODO stubs for future modules ────────────────────────────────────────────
# These will become real imports when the modules are implemented.
# Uncomment and adjust when sanctions_check.py and crypto_aml.py are created.

# from compliance.sanctions_check import screen_entity        # TODO
# from compliance.crypto_aml import analyse_chain             # TODO


# ── __main__ smoke tests ──────────────────────────────────────────────────────

if __name__ == "__main__":
    async def _run_smoke_tests():
        sep = "=" * 60
        tests = [
            ("APPROVE",
             TransactionInput("GB", "DE", 500.0, currency="GBP")),
            ("HOLD",
             TransactionInput("GB", "GB", 12_000.0, currency="GBP")),
            ("REJECT / SAR (high-risk jurisdiction)",
             TransactionInput("SY", "GB", 15_000.0, currency="GBP")),
            ("REJECT (Category A — hard block)",
             TransactionInput("RU", "GB", 100.0, currency="GBP")),
            ("HOLD (structuring hint + round amount)",
             TransactionInput("GB", "GB", 9_000.0, currency="GBP",
                              sender_account="ACC001",
                              flags=["structuring_hint"])),
        ]

        print(f"\n{sep}")
        print("  tx_monitor.py — smoke tests")
        print(f"  Thresholds: SAR>={_THRESHOLD_SAR}, "
              f"REJECT>={_THRESHOLD_REJECT}, HOLD>={_THRESHOLD_HOLD}")
        print(sep)

        for label, tx in tests:
            result = await check_transaction(tx)
            decision = result["recommended_action"]
            verdict = "OK" if decision.split()[0] in label else "?"
            print(f"\n{verdict} [{label}]")
            edd  = any(s["rule"] in ("HIGH_RISK_JURISDICTION", "HARD_BLOCK_JURISDICTION")
                       for s in result["rules_triggered"])
            mlro = any(s["rule"] in ("HARD_BLOCK_JURISDICTION", "POTENTIAL_STRUCTURING",
                                     "RAPID_IN_OUT")
                       for s in result["rules_triggered"])
            print(f"   decision={decision}  score={result['risk_score']}  "
                  f"edd={edd}  mlro={mlro}")
            for s in result["rules_triggered"]:
                print(f"   • [{s['score']:+d}] {s['rule']}: {s['detail']}")

        print(f"\n{sep}")

    asyncio.run(_run_smoke_tests())
