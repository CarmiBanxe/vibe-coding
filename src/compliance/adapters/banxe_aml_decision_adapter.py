"""
BanxeAMLDecisionAdapter — DecisionPort for the production BANXE AML engine.

Converts BanxeAMLResult → DecisionEvent and writes to AuditPort (G-01).
Attaches ExplanationBundle.to_dict() to DecisionEvent.audit_payload (G-02).

Data flow:
  banxe_assess() → BanxeAMLResult
       ↓ emit_decision()
  DecisionEvent.from_aml_result()
       + explanation_bundle serialised into audit_payload
       ↓ AuditPort.append_event()
  Postgres / InMemory / ClickHouse
"""
from __future__ import annotations

from typing import Any

from compliance.ports.audit_port   import AuditPort
from compliance.ports.decision_port import DecisionPort
from compliance.utils.decision_event_log import DecisionEvent


class BanxeAMLDecisionAdapter(DecisionPort):
    """
    Production DecisionPort — writes to an injected AuditPort.

    Injecting AuditPort (not importing directly) keeps DecisionPort
    decoupled from the specific storage backend.

    Usage:
        adapter = BanxeAMLDecisionAdapter(audit_port=PostgresEventLogAdapter())
        event = await adapter.emit_decision(result, explanation)
    """

    def __init__(self, audit_port: AuditPort) -> None:
        self._audit = audit_port

    async def emit_decision(
        self,
        result: Any,
        explanation: Any | None,
    ) -> DecisionEvent:
        """
        Build a DecisionEvent from BanxeAMLResult, attach explanation,
        write to AuditPort, and return the immutable audit record.
        """
        event = DecisionEvent.from_aml_result(result)

        # Attach ExplanationBundle to audit_payload (G-02 + I-25)
        if explanation is not None:
            event.audit_payload["explanation_bundle"] = explanation.to_dict()

        await self._audit.append_event(event)
        return event
