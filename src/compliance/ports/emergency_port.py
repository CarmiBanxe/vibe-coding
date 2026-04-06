"""
EmergencyPort — EU AI Act Art. 14 human oversight emergency stop interface.

Part of Hexagonal Architecture (G-16, SPRINT-0-PLAN.md §1.4).

Design contract:
  - is_stopped()  — checked BEFORE every automated decision (I-23).
  - activate()    — operator-triggered stop (requires operator_id + reason).
  - clear()       — MLRO-triggered resume (requires mlro_id + reason).
  - All state changes are logged as compliance events (G-20).

Adapters (in adapters/):
  RedisEmergencyAdapter      — primary store (emergency_stop.py Redis path)
  FileEmergencyAdapter       — filesystem fallback (emergency_stop.py file path)
  InMemoryEmergencyAdapter   — for tests and local dev (no infra required)

Invariant I-23: is_stopped() MUST be checked before any automated decision.
Authority: EU AI Act Art. 14(4)(e), GAP-REGISTER G-03.
"""
from __future__ import annotations

from abc import ABC, abstractmethod


class EmergencyPort(ABC):
    """
    Human oversight emergency stop channel.

    is_stopped() is the fast-path read called on every screening request.
    activate() and clear() are human-triggered writes (operator → MLRO).

    Invariant I-23: any adapter must expose is_stopped().
    The API layer calls it via Depends(require_not_stopped) — if it returns True,
    the endpoint returns HTTP 503 immediately without running the ML/rule engine.
    """

    @abstractmethod
    async def is_stopped(self) -> bool:
        """
        Return True if emergency stop is currently active.

        Must never raise — fail-open on infrastructure errors (per I-23 design:
        a Redis/file outage must not block compliance screening).
        """
        ...

    @abstractmethod
    async def activate(self, operator_id: str, reason: str) -> dict:
        """
        Activate emergency stop.

        Parameters:
            operator_id — identity of the authorised operator
            reason      — mandatory free-text reason (FCA audit trail)

        Returns:
            dict with keys: status, operator_id, reason, activated_at
        """
        ...

    @abstractmethod
    async def clear(self, mlro_id: str, reason: str) -> dict:
        """
        Clear (resume) emergency stop. Requires MLRO authority.

        Parameters:
            mlro_id — MLRO identity (senior authority, FCA requirement)
            reason  — mandatory free-text reason

        Returns:
            dict with keys: status, mlro_id, reason, cleared_at
        """
        ...

    @abstractmethod
    async def get_status(self) -> dict:
        """
        Return current stop state as a serialisable dict.

        Returns:
            {"active": bool, "activated_at": str|None, "operator_id": str|None,
             "reason": str|None}
        """
        ...
