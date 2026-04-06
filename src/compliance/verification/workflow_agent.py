"""
Workflow Agent — Layer 3 (Process)
Verifies correct routing, escalation paths, and role boundaries.
Authority: BANXE Internal Procedures, FCA Senior Managers Regime
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from typing import Optional


class Verdict(str, Enum):
    CONFIRMED = "CONFIRMED"
    REFUTED = "REFUTED"
    UNCERTAIN = "UNCERTAIN"


@dataclass
class VerificationResult:
    verdict: Verdict
    rule: Optional[str]
    reason: str
    confidence: float


# Role hierarchy — escalation chain (bottom → top)
ROLE_HIERARCHY = [
    "customer_service",
    "kyc_specialist",
    "aml_analyst",
    "compliance_officer",
    "mlro",
    "ceo",
]

# Decisions that require MLRO approval
MLRO_REQUIRED_DECISIONS = [
    "sar", "suspicious activity report",
    "freeze account", "account closure",
    "law enforcement", "nca report",
    "threshold change", "policy override",
]

# Decisions that require HITL (Human In The Loop)
HITL_REQUIRED_TRIGGERS = [
    "£10,000", "£10000", ">£10k",
    "sanctions_hit", "sanctions hit",
    "pep", "politically exposed",
    "auto-sar", "auto sar",
    r"composite_score.*8[5-9]", r"composite_score.*9\d",
]

# Role-specific action boundaries
ROLE_BOUNDARIES = {
    "kyc_specialist": {
        "can_do": ["request documents", "verify identity", "update kyc tier", "flag for review"],
        "cannot_do": ["approve transaction", "file sar", "freeze account", "override sanctions"],
    },
    "aml_analyst": {
        "can_do": ["analyse transaction", "create sar draft", "escalate to mlro", "set hold"],
        "cannot_do": ["file sar independently", "override ceo", "change policy thresholds"],
    },
    "compliance_officer": {
        "can_do": ["approve edd", "review sar draft", "escalate to mlro", "close low-risk alerts"],
        "cannot_do": ["file sar without mlro", "change watchman threshold", "override sanctions list"],
    },
}


def verify(statement: str, context: dict | None = None) -> VerificationResult:
    """
    Verify that agent statement reflects correct workflow routing and escalation.
    """
    text = statement.lower()
    context = context or {}
    agent_role = context.get("agent_role", "").lower().replace(" ", "_")

    # --- HITL required but not mentioned ---
    for trigger_pattern in HITL_REQUIRED_TRIGGERS:
        if re.search(trigger_pattern, text):
            if "hitl" not in text and "human" not in text and "manual review" not in text and "mlro" not in text:
                return VerificationResult(
                    verdict=Verdict.REFUTED,
                    rule="BANXE HITL Policy — Human In The Loop",
                    reason=f"Scenario triggers HITL requirement but no human review referenced",
                    confidence=0.90,
                )

    # --- MLRO required but bypassed ---
    for decision in MLRO_REQUIRED_DECISIONS:
        if decision in text:
            # Detect explicit bypass: "without MLRO", "no MLRO review", "skip MLRO"
            bypass_pattern = rf'(without|no|skip(ping)?|bypas(s|sing)?)\s+(mlro|money laundering reporting officer)'
            if re.search(bypass_pattern, text):
                return VerificationResult(
                    verdict=Verdict.REFUTED,
                    rule="FCA Senior Managers Regime — MLRO Authority",
                    reason=f"Statement explicitly bypasses MLRO authority for decision: '{decision}'",
                    confidence=0.95,
                )
            if "mlro" not in text and "money laundering reporting officer" not in text:
                return VerificationResult(
                    verdict=Verdict.REFUTED,
                    rule="FCA Senior Managers Regime — MLRO Authority",
                    reason=f"Decision '{decision}' requires MLRO but not referenced",
                    confidence=0.88,
                )

    # --- Role boundary check ---
    if agent_role in ROLE_BOUNDARIES:
        boundaries = ROLE_BOUNDARIES[agent_role]
        for forbidden_action in boundaries["cannot_do"]:
            if forbidden_action in text:
                return VerificationResult(
                    verdict=Verdict.REFUTED,
                    rule="BANXE Role Boundaries Policy",
                    reason=f"Agent role '{agent_role}' is attempting '{forbidden_action}' — outside role boundary",
                    confidence=0.92,
                )

    # --- Escalation path check ---
    if _should_escalate(text) and not _mentions_escalation(text):
        return VerificationResult(
            verdict=Verdict.UNCERTAIN,
            rule="BANXE Escalation Procedure",
            reason="High-risk scenario detected but no escalation path mentioned",
            confidence=0.72,
        )

    # --- Auto-resolution of complex cases check ---
    if _is_complex_case(text) and _claims_self_resolution(text):
        return VerificationResult(
            verdict=Verdict.REFUTED,
            rule="BANXE Complex Case Routing Policy",
            reason="Complex compliance case cannot be auto-resolved — requires human escalation",
            confidence=0.85,
        )

    return VerificationResult(
        verdict=Verdict.CONFIRMED,
        rule=None,
        reason="Workflow routing and escalation path appears correct",
        confidence=0.78,
    )


def _should_escalate(text: str) -> bool:
    escalation_triggers = [
        r"risk score.*[789]\d", "high risk", "very high risk",
        "sanctions", "pep", "adverse media.*significant",
        "structuring", "unusual pattern",
    ]
    return any(re.search(p, text) for p in escalation_triggers)


def _mentions_escalation(text: str) -> bool:
    escalation_keywords = [
        "escalate", "refer to", "mlro", "compliance officer",
        "senior review", "hitl", "human review", "flag for",
        "edd", "enhanced due diligence", "manual review",
        "hold", "pending review",
    ]
    return any(k in text for k in escalation_keywords)


def _is_complex_case(text: str) -> bool:
    complex_indicators = [
        "multiple", "combined", "several flags", "cross-border",
        "pep and sanctions", "structuring and", "layering",
    ]
    return any(k in text for k in complex_indicators)


def _claims_self_resolution(text: str) -> bool:
    self_resolution = [
        "automatically approved", "auto-approved", "no review needed",
        "resolved automatically", "handled by system",
    ]
    return any(k in text for k in self_resolution)


if __name__ == "__main__":
    import sys
    statement = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "The SAR has been filed automatically without MLRO review."
    result = verify(statement)
    print(f"Verdict:    {result.verdict.value}")
    print(f"Rule:       {result.rule or '—'}")
    print(f"Reason:     {result.reason}")
    print(f"Confidence: {result.confidence:.2f}")
