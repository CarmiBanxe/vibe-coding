"""
opa_sidecar.py — G-14 OPA Sidecar Pilot

Runtime pre-decision enforcement layer wrapping rego_evaluator.py.
Enforces 3 critical rules before any agent decision reaches the output port.

Rules enforced:
    RULE-01 (I-22): Level-2/3 agents cannot write to policy layer
    RULE-02 (I-23): Emergency stop must be checked before any decision
    RULE-03 (I-25): ExplanationBundle required for decisions > £10K threshold

Design:
    Fail-closed: if evaluator raises → DENY + log error (never silently allow)
    All evaluations logged via StructuredLogger (audit trail, I-24)

Integration point:
    Called from banxe_aml_orchestrator before _layer2_assess():

        sidecar = OPASidecar()
        decision = sidecar.evaluate_pre_decision(
            agent_id="banxe_aml_orchestrator",
            action="approve_transaction",
            context={"level": 1, "amount_gbp": 15000, "emergency_stop_checked": True,
                     "explanation_bundle_present": True},
        )
        if not decision.allowed:
            raise PolicyDecision blocked ...

Closes: GAP-REGISTER G-14
Invariants: I-22, I-23, I-25
Authority: FINOS AIGF v2.0, FCA SS1/23, EU AI Act Art. 14
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from compliance.utils.rego_evaluator import (
    PolicyInput,
    PolicyViolation,
    evaluate,
)


# ── Decision types ─────────────────────────────────────────────────────────────

class Outcome:
    ALLOW = "ALLOW"
    DENY = "DENY"
    ESCALATE = "ESCALATE"


@dataclass(frozen=True)
class PolicyDecision:
    """
    Result of a pre-decision sidecar evaluation.

    Fields:
        allowed           — True only when outcome is ALLOW
        outcome           — ALLOW | DENY | ESCALATE
        rule_id           — identifier of the fired rule (or "none" for allow)
        reason            — human-readable explanation
        escalation_target — who to escalate to (MLRO | CEO | CTIO) or None
        violations        — raw PolicyViolation list from rego_evaluator
    """
    allowed: bool
    outcome: str
    rule_id: str
    reason: str
    escalation_target: str | None = None
    violations: tuple[PolicyViolation, ...] = field(default_factory=tuple)

    @classmethod
    def allow(cls) -> "PolicyDecision":
        return cls(
            allowed=True,
            outcome=Outcome.ALLOW,
            rule_id="none",
            reason="All pre-decision rules passed",
        )

    @classmethod
    def deny(cls, rule_id: str, reason: str, violations: list[PolicyViolation] | None = None) -> "PolicyDecision":
        return cls(
            allowed=False,
            outcome=Outcome.DENY,
            rule_id=rule_id,
            reason=reason,
            escalation_target=None,
            violations=tuple(violations or []),
        )

    @classmethod
    def escalate(cls, rule_id: str, reason: str, target: str, violations: list[PolicyViolation] | None = None) -> "PolicyDecision":
        return cls(
            allowed=False,
            outcome=Outcome.ESCALATE,
            rule_id=rule_id,
            reason=reason,
            escalation_target=target,
            violations=tuple(violations or []),
        )


# ── Sidecar ────────────────────────────────────────────────────────────────────

class OPASidecar:
    """
    Pre-decision enforcement sidecar.

    Wraps rego_evaluator.evaluate() and maps violations to PolicyDecision objects.
    Always fail-closed: exceptions produce DENY, never silent allow.

    Usage:
        sidecar = OPASidecar()
        decision = sidecar.evaluate_pre_decision("my_agent", "approve_transaction", context)
        if not decision.allowed:
            raise RuntimeError(decision.reason)
    """

    # Escalation policy per invariant
    _ESCALATION_TARGETS: dict[str, str] = {
        "I-22": "CTIO",        # Policy layer write — CTIO owns architecture
        "I-23": "MLRO",        # Emergency stop — MLRO owns operational risk
        "I-25": "MLRO",        # High-value explanation — MLRO owns XAI obligation
        "GOVERNANCE": "CEO",   # SAR / governance — CEO final authority
    }

    def __init__(self) -> None:
        self._logger = self._build_logger()

    @staticmethod
    def _build_logger():
        """Return StructuredLogger if available, else noop."""
        try:
            from compliance.utils.structured_logger import StructuredLogger
            return StructuredLogger("opa_sidecar")
        except Exception:
            return None

    def _log(self, event_type: str, payload: dict) -> None:
        if self._logger is not None:
            try:
                self._logger.event(event_type=event_type, payload=payload)
            except Exception:
                pass  # never let logging break enforcement

    def evaluate_pre_decision(
        self,
        agent_id: str,
        action: str,
        context: dict[str, Any],
    ) -> PolicyDecision:
        """
        Evaluate all 3 critical rules before an agent decision.

        Args:
            agent_id: Identifier of the agent requesting the action.
            action:   Action being requested (approve_transaction, write_file, …).
            context:  Dict with PolicyInput fields: level, amount_gbp,
                      emergency_stop_checked, explanation_bundle_present,
                      target_path, target_repo, mlro_approved, decision.

        Returns:
            PolicyDecision — always returns, never raises.
            If internal error → DENY (fail-closed).
        """
        try:
            inp = self._build_input(agent_id, action, context)
            violations = evaluate(inp)

            if not violations:
                decision = PolicyDecision.allow()
            else:
                decision = self._map_violations(violations)

            self._log("OPA_SIDECAR_EVALUATED", {
                "agent_id": agent_id,
                "action": action,
                "outcome": decision.outcome,
                "rule_id": decision.rule_id,
                "violations_count": len(violations),
            })
            return decision

        except Exception as exc:
            # Fail-closed: any unexpected error becomes DENY
            error_decision = PolicyDecision.deny(
                rule_id="SIDECAR_ERROR",
                reason=f"OPASidecar internal error: {type(exc).__name__}: {exc}",
            )
            self._log("OPA_SIDECAR_ERROR", {
                "agent_id": agent_id,
                "action": action,
                "error": str(exc),
                "error_type": type(exc).__name__,
            })
            return error_decision

    @staticmethod
    def _build_input(agent_id: str, action: str, context: dict) -> PolicyInput:
        """Build PolicyInput from the context dict, with safe defaults."""
        return PolicyInput(
            agent_level=context.get("level", 2),
            agent_id=agent_id,
            action=action,
            target_path=context.get("target_path", ""),
            target_repo=context.get("target_repo", ""),
            mlro_approved=context.get("mlro_approved", False),
            amount_gbp=context.get("amount_gbp", 0.0),
            explanation_bundle_present=context.get("explanation_bundle_present", False),
            emergency_stop_checked=context.get("emergency_stop_checked", False),
            decision=context.get("decision", ""),
        )

    def _map_violations(self, violations: list[PolicyViolation]) -> PolicyDecision:
        """
        Map a list of violations to a single PolicyDecision.
        Priority: DENY > ESCALATE (first blocked violation wins).
        """
        for v in violations:
            if v.blocked:
                # Determine if this needs escalation (I-25, GOVERNANCE) or straight DENY
                target = self._ESCALATION_TARGETS.get(v.invariant)
                if v.invariant in ("I-25", "GOVERNANCE"):
                    return PolicyDecision.escalate(
                        rule_id=v.rule,
                        reason=v.message,
                        target=target or "MLRO",
                        violations=violations,
                    )
                return PolicyDecision.deny(
                    rule_id=v.rule,
                    reason=v.message,
                    violations=violations,
                )
        # All violations are non-blocking warnings — allow
        return PolicyDecision.allow()


# ── Module-level convenience function ─────────────────────────────────────────

_SIDECAR: OPASidecar | None = None


def get_sidecar() -> OPASidecar:
    """Return process-wide OPASidecar singleton."""
    global _SIDECAR
    if _SIDECAR is None:
        _SIDECAR = OPASidecar()
    return _SIDECAR
