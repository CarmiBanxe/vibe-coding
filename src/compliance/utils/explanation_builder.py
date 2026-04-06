"""
explanation_builder.py — G-02 ExplanationBundle (FCA SS1/23, I-25).

Implements deterministic, rule-based XAI for the BANXE AML decision engine.
No ML required — explanations are derived directly from RiskSignal metadata.

Invariant I-25:
  ExplanationBundle REQUIRED for decisions on transactions >= £10,000.
  Until G-02 was implemented, the field was null with method="pending".
  Now: always built, always non-null for any decision.

Authority:
  FCA SS1/23  — supervisory statement on AI explainability
  UK GDPR Art. 22 — right to explanation for automated decisions
  FCA PS7/24  — consumer duty, fair treatment
  EU AI Act Art. 13 — transparency requirements for high-risk AI systems

Spec: banxe-architecture/domain/replay-and-logging-spec.md §3
Closes: GAP-REGISTER G-02
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Optional

from compliance.utils.config_loader import (
    get_threshold_sar,
    get_threshold_reject,
    get_threshold_hold,
)

# EU AI Act Art. 13 — system identifier for model traceability
_MODEL_VERSION = "banxe-aml-v1"

# Hard-block rule identifiers (for narrative detection)
_HARD_OVERRIDE_RULES = frozenset({
    "HARD_BLOCK_JURISDICTION",
    "SUBJECT_JURISDICTION_A",
    "CUSTOMER_JURISDICTION_A",
    "SANCTIONS_CONFIRMED",
    "CRYPTO_SANCTIONS",
    "CUSTOMER_UNACCEPTABLE_RISK",
})


# ── CounterfactualExplanation ─────────────────────────────────────────────────

@dataclass
class CounterfactualExplanation:
    """
    «What would have changed if...» — deterministic counterfactual.

    Generated from threshold parameters, not from ML model internals.
    This makes it verifiable and reproducible for FCA audit replay (G-01).
    """
    decision_was:      str   # e.g. "HOLD"
    decision_would_be: str   # e.g. "APPROVE"
    condition:         str   # e.g. "if composite score < 40"
    nearest_threshold: str   # e.g. "hold_threshold: 40"


# ── ExplanationBundle ─────────────────────────────────────────────────────────

@dataclass
class ExplanationBundle:
    """
    Human-readable, auditable explanation of one AML decision.

    Required for decisions on transactions >= £10,000 (I-25).
    Built deterministically from RiskSignal metadata — no ML required.

    top_factors: list of (rule_id, contribution_pct, direction) tuples
      - rule_id:          machine-readable rule identifier (e.g. "FPS_STRUCTURING")
      - contribution_pct: signal.score / 100  (fraction of max possible score 100)
      - direction:        "↑" (risk-increasing — all signals increase risk by design)

    Spec: banxe-architecture/domain/replay-and-logging-spec.md §3
    """
    # Identity
    explanation_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    case_id:        str = ""
    generated_at:   str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    model_version:  str = _MODEL_VERSION

    # Core fields (spec)
    decision:        str                                = ""
    top_factors:     list[tuple[str, float, str]]       = field(default_factory=list)
    narrative:       str                                = ""
    confidence:      float                              = 0.95   # deterministic → 0.95
    method:          str                                = "rule-based"
    counterfactual:  Optional[CounterfactualExplanation] = None

    # ── Factory ───────────────────────────────────────────────────────────────

    @classmethod
    def from_banxe_result(
        cls,
        result: Any,
        *,
        amount_gbp: float = 0.0,
        top_n: int = 5,
    ) -> "ExplanationBundle":
        """
        Build ExplanationBundle from a BanxeAMLResult.

        Parameters:
            result     — BanxeAMLResult (typed as Any to avoid circular import)
            amount_gbp — transaction amount in GBP (for counterfactual context)
            top_n      — max number of signals to include in top_factors (default 5)

        Returns:
            ExplanationBundle with top_factors sorted by score contribution desc.
        """
        signals_sorted = sorted(result.signals, key=lambda s: s.score, reverse=True)
        top_signals    = signals_sorted[:top_n]

        # (rule_id, contribution_pct, direction)
        top_factors = [
            (s.rule, round(s.score / 100, 4), "↑")
            for s in top_signals
        ]

        narrative    = _build_narrative(result, signals_sorted)
        counterfact  = _build_counterfactual(result, amount_gbp)

        return cls(
            case_id        = result.case_id,
            decision       = result.decision,
            top_factors    = top_factors,
            narrative      = narrative,
            confidence     = 0.95,
            method         = "rule-based",
            counterfactual = counterfact,
        )

    # ── Serialisation ─────────────────────────────────────────────────────────

    def to_dict(self) -> dict:
        """
        JSON-serialisable dict. Converts tuples → lists for JSON compat.
        Used by DecisionEvent.audit_payload and API responses.
        """
        return {
            "explanation_id": self.explanation_id,
            "case_id":        self.case_id,
            "generated_at":   self.generated_at,
            "model_version":  self.model_version,
            "decision":       self.decision,
            "top_factors":    [list(f) for f in self.top_factors],
            "narrative":      self.narrative,
            "confidence":     self.confidence,
            "method":         self.method,
            "counterfactual": {
                "decision_was":      self.counterfactual.decision_was,
                "decision_would_be": self.counterfactual.decision_would_be,
                "condition":         self.counterfactual.condition,
                "nearest_threshold": self.counterfactual.nearest_threshold,
            } if self.counterfactual else None,
        }


# ── Internal builders ─────────────────────────────────────────────────────────

def _top_factor_sentence(signals: list) -> str:
    """One-sentence summary of the single highest-score signal."""
    if not signals:
        return "No material risk signals detected."
    top = signals[0]
    reason_short = top.reason[:120].rstrip(".")
    return f"Primary factor: [{top.rule}] — {reason_short}."


def _build_narrative(result: Any, signals_sorted: list) -> str:
    """
    Deterministic MLRO-readable narrative.
    Decision + score + primary signal → one paragraph (~2-4 sentences).
    """
    decision        = result.decision
    score           = result.score
    decision_reason = getattr(result, "decision_reason", "threshold")
    top_sentence    = _top_factor_sentence(signals_sorted)

    # P1: Hard-override narrative
    if decision_reason == "hard_override":
        hard_rule = next(
            (s.rule for s in signals_sorted if s.rule in _HARD_OVERRIDE_RULES),
            signals_sorted[0].rule if signals_sorted else "UNKNOWN_RULE",
        )
        return (
            f"Hard-block rule [{hard_rule}] triggered an immediate {decision} "
            f"(composite score: {score}/100), overriding threshold-based assessment. "
            f"{top_sentence} "
            f"This override is non-discretionary per SAMLA 2018 / UK HMT Consolidated List."
        )

    # P2: SAR
    if decision == "SAR":
        return (
            f"Suspicious Activity Report (SAR) required. "
            f"Composite score: {score}/100 meets or exceeds the SAR threshold ({get_threshold_sar()}). "
            f"{top_sentence} "
            f"MLRO must assess and file with NCA if appropriate (POCA 2002 §330). "
            f"Reporting window: within 7 days of suspicion arising."
        )

    # P3: REJECT
    if decision == "REJECT":
        return (
            f"Transaction blocked. "
            f"Composite score: {score}/100 meets or exceeds the reject threshold ({get_threshold_reject()}). "
            f"{top_sentence} "
            f"Customer notification required per MLR 2017 §21(3)."
        )

    # P4: HOLD
    if decision == "HOLD":
        if decision_reason == "high_risk_floor":
            return (
                f"Transaction held — high-risk floor applied. "
                f"Although composite score ({score}/100) may be below the reject threshold, "
                f"a high-risk indicator mandates minimum HOLD per FCA EDD policy. "
                f"{top_sentence} EDD must be completed before processing."
            )
        return (
            f"Transaction held for Enhanced Due Diligence (EDD). "
            f"Composite score: {score}/100 meets or exceeds the hold threshold ({get_threshold_hold()}). "
            f"{top_sentence} EDD required before processing."
        )

    # APPROVE
    n = len(signals_sorted)
    return (
        f"Transaction approved. "
        f"Composite score: {score}/100 is below the hold threshold ({get_threshold_hold()}). "
        f"{n} signal(s) evaluated; risk within acceptable parameters."
    )


def _build_counterfactual(
    result: Any,
    amount_gbp: float,
) -> Optional[CounterfactualExplanation]:
    """
    Deterministic counterfactual: «what would change the decision».

    Generated from threshold arithmetic — not from ML gradient.
    Not generated for APPROVE (already at best outcome).
    """
    decision = result.decision
    score    = result.score

    if decision == "APPROVE":
        return None  # already at most favourable outcome

    if decision == "SAR":
        thr = get_threshold_sar()
        gap = max(score - thr, 0)
        return CounterfactualExplanation(
            decision_was      = "SAR",
            decision_would_be = "REJECT",
            condition         = f"if composite score dropped by ≥{gap} to below {thr}",
            nearest_threshold = f"sar_threshold: {thr}",
        )

    if decision == "REJECT":
        thr = get_threshold_reject()
        gap = max(score - thr, 0)
        return CounterfactualExplanation(
            decision_was      = "REJECT",
            decision_would_be = "HOLD",
            condition         = f"if composite score dropped by ≥{gap} to below {thr}",
            nearest_threshold = f"reject_threshold: {thr}",
        )

    # HOLD
    thr = get_threshold_hold()
    gap = max(score - thr, 0)
    return CounterfactualExplanation(
        decision_was      = "HOLD",
        decision_would_be = "APPROVE",
        condition         = f"if composite score dropped by ≥{gap} to below {thr}",
        nearest_threshold = f"hold_threshold: {thr}",
    )
