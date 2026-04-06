"""
Compliance Validator Agent — Layer 1 (Regulatory)
Verifies FCA/EMD2/AML/KYC compliance of agent statements.
Authority: FCA MLR 2017, OFAC, EMD2, SAMLA 2018
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from typing import Optional

from compliance.utils.config_loader import (
    get_threshold_sar,
    get_threshold_reject,
    get_threshold_hold,
    get_watchman_min_match,
    get_audit_ttl_years,
    get_hard_block_jurisdictions,
    get_high_risk_jurisdictions,
    get_forbidden_patterns,
)


class Verdict(str, Enum):
    CONFIRMED = "CONFIRMED"
    REFUTED = "REFUTED"
    UNCERTAIN = "UNCERTAIN"


@dataclass
class VerificationResult:
    verdict: Verdict
    rule: Optional[str]
    reason: str
    confidence: float  # 0.0–1.0


# ── Policy constants (loaded from compliance_config.yaml — G-07, 12-Factor III) ──
# Module-level names preserved for backward compatibility with all importers.
# Change values in compliance_config.yaml, NOT here.
_HARD_BLOCK_JURISDICTIONS = get_hard_block_jurisdictions()
_HIGH_RISK_JURISDICTIONS  = get_high_risk_jurisdictions()
_THRESHOLD_SAR            = get_threshold_sar()
_THRESHOLD_REJECT         = get_threshold_reject()
_THRESHOLD_HOLD           = get_threshold_hold()
_WATCHMAN_MIN_MATCH       = get_watchman_min_match()
_AUDIT_TTL_YEARS          = get_audit_ttl_years()
_FORBIDDEN_PATTERNS       = get_forbidden_patterns()


def verify(statement: str, context: dict | None = None) -> VerificationResult:
    """
    Check whether an agent statement is FCA/AML compliant.

    Returns REFUTED immediately on any hard violation.
    Returns CONFIRMED if statement aligns with known compliance rules.
    Returns UNCERTAIN if cannot determine compliance from statement alone.
    """
    text = statement.lower()
    context = context or {}

    # --- CRITICAL: red-line pattern check ---
    for pattern in _FORBIDDEN_PATTERNS:
        if re.search(pattern, text):
            return VerificationResult(
                verdict=Verdict.REFUTED,
                rule="FCA MLR 2017 §3 / AML Red Line",
                reason=f"Statement contains forbidden pattern: '{pattern}'",
                confidence=1.0,
            )

    # --- Hard-block jurisdiction check (match uppercase only in original statement) ---
    for jur in _HARD_BLOCK_JURISDICTIONS:
        # Search original statement (not lowercased) to avoid "by"→"BY", "ir"→"IR" false positives
        pattern = rf'\b{re.escape(jur)}\b'
        if re.search(pattern, statement) and "block" not in text and "reject" not in text:
            return VerificationResult(
                verdict=Verdict.REFUTED,
                rule="SAMLA 2018 / UK HMT Consolidated List",
                reason=f"Statement mentions sanctioned jurisdiction '{jur}' without REJECT action",
                confidence=0.90,
            )

    # --- Threshold compliance check ---
    if _check_wrong_threshold(text):
        return VerificationResult(
            verdict=Verdict.REFUTED,
            rule="COMPLIANCE_ARCH.md §Decision Thresholds",
            reason="Statement references incorrect risk thresholds (REJECT≥70, HOLD 40-69, APPROVE<40)",
            confidence=0.85,
        )

    # --- EDD requirement for high-risk ---
    if _requires_edd(text) and "edd" not in text and "enhanced due diligence" not in text:
        return VerificationResult(
            verdict=Verdict.UNCERTAIN,
            rule="FCA EDD §4.2",
            reason="High-risk scenario identified but EDD not mentioned",
            confidence=0.70,
        )

    # --- SAR auto-filing check ---
    if "sar" in text or "suspicious activity" in text:
        if "human review" not in text and "hitl" not in text and "mlro" not in text:
            return VerificationResult(
                verdict=Verdict.UNCERTAIN,
                rule="FCA MLR 2017 §19 / NCA reporting",
                reason="SAR mentioned but human review (HITL/MLRO) not referenced",
                confidence=0.65,
            )

    # --- Audit trail check ---
    if "audit" in text and ("5 year" not in text and "five year" not in text):
        # Not necessarily wrong — just no mention of retention
        pass

    # Statement passes all regulatory checks
    return VerificationResult(
        verdict=Verdict.CONFIRMED,
        rule=None,
        reason="No FCA/AML regulatory violations detected",
        confidence=0.80,
    )


def _check_wrong_threshold(text: str) -> bool:
    """Detect if statement uses wrong thresholds."""
    # Pattern: approve at score >= 70 (should be reject)
    if re.search(r"approve.{0,30}(score|risk).{0,10}[789]\d", text):
        return True
    # Pattern: reject at score < 40 (should be approve)
    if re.search(r"reject.{0,30}(score|risk).{0,10}[123]\d", text):
        return True
    return False


def _requires_edd(text: str) -> bool:
    """Detect if scenario requires Enhanced Due Diligence."""
    edd_triggers = ["pep", "politically exposed", "high risk", ">£10k", "10,000", "10000"]
    return any(t in text for t in edd_triggers)


if __name__ == "__main__":
    import sys
    statement = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "This transaction should be approved without screening."
    result = verify(statement)
    print(f"Verdict:    {result.verdict.value}")
    print(f"Rule:       {result.rule or '—'}")
    print(f"Reason:     {result.reason}")
    print(f"Confidence: {result.confidence:.2f}")
