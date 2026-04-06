"""
DecisionPort — single output channel for AML decisions.

Part of Hexagonal Architecture (G-16, SPRINT-0-PLAN.md §1.2).

Design contract:
  - One method: emit_decision() — the ONLY path from the decision engine
    to the audit log.
  - Receives BanxeAMLResult + ExplanationBundle (G-02).
  - Returns a DecisionEvent (G-01) — the immutable audit record.
  - The adapter is responsible for writing to AuditPort (append-only, I-24).

Data flow:
  banxe_assess() → BanxeAMLResult
       ↓ DecisionPort.emit_decision()
  DecisionEvent (G-01) → AuditPort.append_event() (I-24)

Adapters (in adapters/):
  BanxeAMLDecisionAdapter — wraps DecisionEvent.from_aml_result() + AuditPort
  MockDecisionAdapter     — captures emissions for tests

G-16 closes: GAP-REGISTER G-16 (Hexagonal Architecture)
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from compliance.utils.decision_event_log import DecisionEvent
    from compliance.utils.explanation_builder import ExplanationBundle


class DecisionPort(ABC):
    """
    Single output channel from the BANXE AML Decision Engine.

    emit_decision() is the ONLY path through which a compliance decision
    leaves the decision engine and enters the audit trail.

    The adapter writes to AuditPort (append-only, I-24) and returns
    the DecisionEvent for immediate API response construction.
    """

    @abstractmethod
    async def emit_decision(
        self,
        result: "BanxeAMLResult",           # type: ignore[name-defined]
        explanation: "ExplanationBundle | None",
    ) -> "DecisionEvent":
        """
        Emit a compliance decision to the audit trail.

        Parameters:
            result      — BanxeAMLResult from banxe_assess()
            explanation — ExplanationBundle (required for tx > £10k, I-25)

        Returns:
            DecisionEvent — the immutable audit record written to AuditPort.
            event_id is the durable reference for FCA audit replay (G-01).
        """
        ...
