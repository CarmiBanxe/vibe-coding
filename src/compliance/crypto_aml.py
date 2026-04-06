#!/usr/bin/env python3
"""
Crypto AML — Layer 2 (Wallet & Chain Screening)

Screens crypto wallets against:
  PRIMARY:   Moov Watchman OFAC address list (localhost:8084, urllib — no httpx)
  HEURISTIC: Caller-supplied risk_flags + transaction value scoring

Decision vocabulary (aligned with compliance_validator thresholds):
  CRYPTO_SANCTIONS    score=100  → auto-REJECT, MLRO (OFAC exact address match)
  CRYPTO_CRITICAL     score=90   → SAR/REJECT (darknet, ransomware, terrorism, ...)
  CRYPTO_HIGH_RISK    score=70   → REJECT (mixer, tumbler, scam, fraud)
  CRYPTO_ELEVATED     score=40   → HOLD / EDD (rapid_in_out, suspicious flags)
  CRYPTO_HIGH_VALUE   score=20   → additional monitoring (>£50k)

Returns list[RiskSignal] for aggregation by aml_orchestrator.
"""
from __future__ import annotations

import json
import re
import urllib.request
import urllib.parse
from typing import Optional

from compliance.models import WalletScreeningInput, RiskSignal
from compliance.verification.compliance_validator import (
    _THRESHOLD_SAR,
    _THRESHOLD_REJECT,
    _THRESHOLD_HOLD,
)

WATCHMAN_URL     = "http://127.0.0.1:8084"
WATCHMAN_TIMEOUT = 5    # seconds

# ── Address format validators (stdlib re — no eth-utils dependency) ───────────
_ETH_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
_BTC_RE = re.compile(r"^(1|3|bc1)[a-zA-HJ-NP-Z0-9]{25,62}$")

# ── Risk flag taxonomy ────────────────────────────────────────────────────────
# score=90: automatic SAR/REJECT territory
_CRITICAL_FLAGS = frozenset({
    "darknet", "ransomware", "terrorism", "child_abuse",
    "stolen_funds", "sanctions",
})
# score=70: REJECT territory
_HIGH_RISK_FLAGS = frozenset({
    "mixer", "tumbler", "scam", "fraud",
})
# score=40: HOLD / EDD territory
_ELEVATED_FLAGS = frozenset({
    "rapid_in_out", "layering", "pep_linked", "suspicious",
})

_CRYPTO_HIGH_VALUE_GBP = 50_000  # threshold for high-value crypto monitoring signal

__all__ = ["analyse_chain"]


# ── Watchman OFAC address lookup (urllib, sync) ───────────────────────────────

def _watchman_address_search(address: str) -> Optional[dict]:
    """
    Exact-match search against OFAC SDN crypto address list via Watchman.
    Returns hit dict or None.
    """
    try:
        params = urllib.parse.urlencode({
            "name": address,
            "limit": 3,
            "minMatch": "0.95",  # near-exact for addresses
        })
        url = f"{WATCHMAN_URL}/v2/search?{params}"
        with urllib.request.urlopen(url, timeout=WATCHMAN_TIMEOUT) as resp:
            data = json.loads(resp.read())
            entities = data.get("entities") or []
            if entities:
                e = entities[0]
                return {
                    "name_match": e.get("name", address),
                    "list_name":  e.get("sourceList", ""),
                    "score":      float(e.get("matchScore", 1.0)),
                }
            return None
    except Exception:
        return None


# ── Address format validation ─────────────────────────────────────────────────

def _validate_address(wallet: WalletScreeningInput) -> Optional[RiskSignal]:
    """Return a signal if the address format is invalid for the declared chain."""
    chain = wallet.chain.lower()
    addr  = wallet.address
    if chain in ("eth", "erc20", "usdt", "usdc", "tron") and not _ETH_RE.match(addr):
        return RiskSignal(
            source="crypto_aml",
            rule="INVALID_ADDRESS_FORMAT",
            score=20,
            reason=f"Address '{addr[:20]}...' does not match expected {chain.upper()} format.",
        )
    if chain == "btc" and not _BTC_RE.match(addr):
        return RiskSignal(
            source="crypto_aml",
            rule="INVALID_ADDRESS_FORMAT",
            score=20,
            reason=f"Address '{addr[:20]}...' does not match expected BTC format.",
        )
    return None


# ── Public API ────────────────────────────────────────────────────────────────

def analyse_chain(wallet: WalletScreeningInput) -> list[RiskSignal]:
    """
    Screen a crypto wallet / transaction for AML risk.

    Rule order:
      1. Watchman OFAC exact address match → score=100, MLRO, short-circuit
      2. Critical risk flags (darknet, ransomware, ...) → score=90
      3. High-risk flags (mixer, tumbler, scam, ...) → score=70
      4. Elevated flags (rapid_in_out, layering, ...) → score=40
      5. High transaction value (>£50k) → score=20
      6. Address format validation → score=20

    Returns list[RiskSignal] for aggregation by aml_orchestrator.
    """
    signals: list[RiskSignal] = []
    flags   = {f.lower() for f in wallet.risk_flags}

    # ── Rule 1: OFAC sanctioned address ──────────────────────────────────────
    hit = _watchman_address_search(wallet.address)
    if hit:
        signals.append(RiskSignal(
            source="crypto_aml",
            rule="CRYPTO_SANCTIONS",
            score=100,
            reason=(f"OFAC sanctioned crypto address: '{hit['name_match']}' "
                    f"({hit['list_name']}, match={hit['score']:.0%}). "
                    "MLRO notification mandatory."),
            authority="OFAC SDN / SAMLA 2018",
            requires_edd=True,
            requires_mlro=True,
        ))
        return signals  # short-circuit — no further analysis needed

    # ── Rule 2: Critical risk flags ───────────────────────────────────────────
    critical_hits = flags & _CRITICAL_FLAGS
    if critical_hits:
        signals.append(RiskSignal(
            source="crypto_aml",
            rule="CRYPTO_CRITICAL",
            score=90,
            reason=(f"Critical risk category: {sorted(critical_hits)}. "
                    "MLRO review and SAR assessment mandatory."),
            authority="JMLSG Part II §8 — virtual assets",
            requires_edd=True,
            requires_mlro=True,
        ))

    # ── Rule 3: High-risk flags ───────────────────────────────────────────────
    high_hits = flags & _HIGH_RISK_FLAGS
    if high_hits:
        signals.append(RiskSignal(
            source="crypto_aml",
            rule="CRYPTO_HIGH_RISK",
            score=70,
            reason=(f"High-risk mixing/fraud category: {sorted(high_hits)}. "
                    "Transaction should be blocked pending investigation."),
            authority="FATF Recommendation 15 — virtual assets",
            requires_edd=True,
        ))

    # ── Rule 4: Elevated flags (layering / rapid in-out) ─────────────────────
    elevated_hits = flags & _ELEVATED_FLAGS
    if elevated_hits:
        signals.append(RiskSignal(
            source="crypto_aml",
            rule="CRYPTO_ELEVATED",
            score=40,
            reason=(f"Elevated risk indicators: {sorted(elevated_hits)}. "
                    "EDD required before processing."),
            authority="JMLSG Part I §6.12",
            requires_edd=True,
        ))

    # ── Rule 5: High transaction value ───────────────────────────────────────
    if wallet.tx_value_usd > 0:
        # Rough USD→GBP conversion (0.79 from _FX_RATES in tx_monitor)
        value_gbp = wallet.tx_value_usd * 0.79
        if value_gbp >= _CRYPTO_HIGH_VALUE_GBP:
            signals.append(RiskSignal(
                source="crypto_aml",
                rule="CRYPTO_HIGH_VALUE",
                score=20,
                reason=(f"High-value crypto transaction: "
                        f"~£{value_gbp:,.0f} (${wallet.tx_value_usd:,.0f}). "
                        "Enhanced monitoring applied."),
                authority="MLR 2017 §7",
            ))

    # ── Rule 6: Address format anomaly ───────────────────────────────────────
    fmt_signal = _validate_address(wallet)
    if fmt_signal:
        signals.append(fmt_signal)

    return signals


# ── Backward-compat wrapper (api.py uses this name) ──────────────────────────

async def check_wallet(address: str, chain: str = "eth",
                       risk_flags: list[str] | None = None,
                       tx_value_usd: float = 0.0) -> dict:
    """
    Legacy dict-return wrapper for api.py callers.
    New code: use analyse_chain(WalletScreeningInput(...)) directly.
    """
    wallet = WalletScreeningInput(
        address=address,
        chain=chain,
        risk_flags=risk_flags or [],
        tx_value_usd=tx_value_usd,
    )
    signals = analyse_chain(wallet)
    score    = min(sum(s.score for s in signals), 100)
    decision = ("BLOCK" if score >= _THRESHOLD_REJECT else
                "HOLD"  if score >= _THRESHOLD_HOLD   else "APPROVE")
    return {
        "address":        address,
        "chain":          chain,
        "sanctioned":     any(s.rule == "CRYPTO_SANCTIONS" for s in signals),
        "risk_score":     score,
        "risk_level":     ("CRITICAL" if score >= 90 else
                           "HIGH"     if score >= _THRESHOLD_REJECT else
                           "MEDIUM"   if score >= _THRESHOLD_HOLD   else "LOW"),
        "risk_factors":   [s.reason for s in signals],
        "decision":       decision,
        "sources_checked": ["watchman_ofac", "heuristic"],
        "cluster_info":   {"rules": sorted(s.rule for s in signals)},
    }


# ── __main__ smoke tests ──────────────────────────────────────────────────────

if __name__ == "__main__":
    from compliance.verification.compliance_validator import (
        _THRESHOLD_SAR, _THRESHOLD_REJECT, _THRESHOLD_HOLD
    )

    tests = [
        ("REJECT (OFAC Tornado Cash)",
         WalletScreeningInput(
             address="0x8589427373D6D84E98730D7795D8f6f8731FDA16",
             chain="eth",
         )),
        ("REJECT (mixer flag)",
         WalletScreeningInput(
             address="0xAbc1234567890abcdef1234567890abcdef123456",
             chain="eth",
             risk_flags=["mixer"],
             tx_value_usd=5_000,
         )),
        ("SAR territory (darknet + high value)",
         WalletScreeningInput(
             address="0xAbc1234567890abcdef1234567890abcdef123457",
             chain="eth",
             risk_flags=["darknet", "rapid_in_out"],
             tx_value_usd=80_000,
         )),
        ("APPROVE (clean ETH)",
         WalletScreeningInput(
             address="0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
             chain="eth",
             tx_value_usd=1_000,
         )),
        ("HOLD (elevated flag)",
         WalletScreeningInput(
             address="1A1zP1eP5QGefi2DMPTfTL5SLmv7Divf Na",
             chain="btc",
             risk_flags=["pep_linked"],
             tx_value_usd=20_000,
         )),
    ]

    sep = "=" * 60
    print(f"\n{sep}")
    print("  crypto_aml.py — smoke tests")
    print(f"  Thresholds: SAR>={_THRESHOLD_SAR}, "
          f"REJECT>={_THRESHOLD_REJECT}, HOLD>={_THRESHOLD_HOLD}")
    print(sep)

    for label, wallet in tests:
        sigs  = analyse_chain(wallet)
        score = min(sum(s.score for s in sigs), 100)
        decision = ("SAR"     if score >= _THRESHOLD_SAR    else
                    "REJECT"  if score >= _THRESHOLD_REJECT else
                    "HOLD"    if score >= _THRESHOLD_HOLD   else "APPROVE")
        ok = "OK" if decision.split()[0] in label else "?"
        print(f"\n  {ok} [{label}]")
        print(f"     address={wallet.address[:20]}...  score={score}  decision={decision}")
        for s in sigs:
            print(f"     [{s.score:+d}] {s.rule}: {s.reason[:80]}")

    print(f"\n{sep}\n")
