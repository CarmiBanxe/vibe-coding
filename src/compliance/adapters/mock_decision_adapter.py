"""
MockDecisionAdapter — DecisionPort for tests.

Captures all emit_decision() calls without writing to any storage.
Provides assertions helpers for test verification.
"""
from __future__ import annotations

from typing import Any

from compliance.ports.decision_port import DecisionPort
from compliance.utils.decision_event_log import DecisionEvent


class MockDecisionAdapter(DecisionPort):
    """
    In-memory DecisionPort for tests.
    Stores all emitted decisions; never writes to Postgres, Redis, or any store.

    Usage:
        adapter = MockDecisionAdapter()
        event = await adapter.emit_decision(result, explanation)
        assert len(adapter.emissions) == 1
        assert adapter.emissions[0].decision == "APPROVE"
    """

    def __init__(self) -> None:
        self.emissions: list[DecisionEvent] = []

    async def emit_decision(
        self,
        result: Any,
        explanation: Any | None,
    ) -> DecisionEvent:
        event = DecisionEvent.from_aml_result(result)
        if explanation is not None:
            event.audit_payload["explanation_bundle"] = explanation.to_dict()
        self.emissions.append(event)
        return event

    def last(self) -> DecisionEvent | None:
        """Return the most recently emitted event, or None."""
        return self.emissions[-1] if self.emissions else None

    def clear(self) -> None:
        """Reset captured emissions."""
        self.emissions.clear()
