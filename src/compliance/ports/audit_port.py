"""
AuditPort — append-only compliance event store interface.

Part of Hexagonal Architecture (G-16, SPRINT-0-PLAN.md §1.3).

Design contract:
  - append_event() is the ONLY write operation — by design.
  - NO update_event() method — intentionally absent (I-24).
  - NO delete_event() method — intentionally absent (I-24).
  - query_events() is read-only — CQRS read side.

Invariant I-24: Decision Event Log = append-only, без UPDATE/DELETE.
Обоснование: DORA Art. 14(2), FCA MLR 2017 record-keeping.

Adapters (in utils/decision_event_log.py):
  PostgresEventLogAdapter  — primary production store (G-01)
  InMemoryAuditAdapter     — tests / fallback
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from compliance.utils.decision_event_log import DecisionEvent


class AuditPort(ABC):
    """
    Append-only interface for compliance decision events.

    Invariant I-24 is enforced at the design level:
    there is deliberately no update_event() or delete_event() method.
    Any adapter that adds such methods violates I-24 and must be rejected.
    """

    @abstractmethod
    async def append_event(self, event: "DecisionEvent") -> str:
        """
        Persist a compliance decision event. Returns the event_id.

        Must be idempotent on event_id (duplicate inserts silently ignored).
        Must never raise on connectivity errors — log and return event_id.
        """
        ...

    @abstractmethod
    async def query_events(
        self,
        case_id: str | None = None,
        customer_id: str | None = None,
        limit: int = 100,
    ) -> list["DecisionEvent"]:
        """
        Read-only query. Returns events matching the filters.
        Used by replay_decision.py (G-01 replay capability).
        """
        ...

    # ── Intentionally absent (I-24) ──────────────────────────────────────────
    # async def update_event(...)  — FORBIDDEN
    # async def delete_event(...)  — FORBIDDEN
