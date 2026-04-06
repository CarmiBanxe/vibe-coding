"""
InMemoryEmergencyAdapter — EmergencyPort for tests and local development.

Pure in-memory implementation — no Redis, no filesystem.
State is lost on process restart (not for production).

Implements the same activate / clear / is_stopped contract as
emergency_stop.py, through the EmergencyPort interface.
"""
from __future__ import annotations

from datetime import datetime, timezone

from compliance.ports.emergency_port import EmergencyPort


class InMemoryEmergencyAdapter(EmergencyPort):
    """
    In-memory EmergencyPort for tests and local dev.

    Usage:
        adapter = InMemoryEmergencyAdapter()
        assert await adapter.is_stopped() is False
        await adapter.activate("operator-001", "test stop")
        assert await adapter.is_stopped() is True
        await adapter.clear("mlro-001", "test resume")
        assert await adapter.is_stopped() is False
    """

    def __init__(self) -> None:
        self._active:       bool        = False
        self._operator_id:  str | None  = None
        self._reason:       str | None  = None
        self._activated_at: str | None  = None
        self._cleared_at:   str | None  = None

    async def is_stopped(self) -> bool:
        """Returns True if emergency stop is currently active."""
        return self._active

    async def activate(self, operator_id: str, reason: str) -> dict:
        """Activate emergency stop. Idempotent if already active."""
        now = datetime.now(timezone.utc).isoformat()
        self._active       = True
        self._operator_id  = operator_id
        self._reason       = reason
        self._activated_at = now
        self._cleared_at   = None
        return {
            "status":       "SUSPENDED",
            "operator_id":  operator_id,
            "reason":       reason,
            "activated_at": now,
        }

    async def clear(self, mlro_id: str, reason: str) -> dict:
        """Clear (resume) emergency stop. Requires MLRO authority."""
        now = datetime.now(timezone.utc).isoformat()
        self._active       = False
        self._cleared_at   = now
        return {
            "status":     "RUNNING",
            "mlro_id":    mlro_id,
            "reason":     reason,
            "cleared_at": now,
        }

    async def get_status(self) -> dict:
        """Return current stop state."""
        return {
            "active":       self._active,
            "activated_at": self._activated_at,
            "operator_id":  self._operator_id,
            "reason":       self._reason,
        }

    # Test helper
    def reset(self) -> None:
        """Reset all state — for test teardown."""
        self.__init__()
