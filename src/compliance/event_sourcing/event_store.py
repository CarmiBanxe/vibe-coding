"""
event_store.py — G-17 Event Sourcing: EventStore write side.

Wraps AuditPort to add Event Sourcing semantics:
  - Formal stream identity (StreamId)
  - Sequence position tracking (per-stream monotonic counter)
  - replay_into(projector) — rebuild projections from the full event log

Design principles:
  1. EventStore is NOT a new storage layer — it delegates all writes and
     reads to the injected AuditPort (I-24 enforced there).
  2. EventStore adds only stream addressing and replay orchestration —
     no business logic.
  3. Sequence numbers are maintained in-process by the EventStore
     instance (monotonically increasing per stream).  Restart resets the
     counter; the canonical ordering for replay comes from AuditPort
     (occurred_at).
  4. Fail-open: EventStore errors never suppress the underlying
     AuditPort result.

CQRS boundary:
  Write path:  banxe_assess() → EventStore.append() → AuditPort.append_event()
  Read path:   EventStore.load_stream() → AuditPort.query_events()
               → Projector.apply_batch() → ReadModel projections

Invariant I-24 (append-only) is enforced by AuditPort — EventStore
inherits this guarantee without duplicating the constraint.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from compliance.ports.audit_port import AuditPort

if TYPE_CHECKING:
    from compliance.utils.decision_event_log import DecisionEvent
    from compliance.event_sourcing.projector import Projector


# ── StreamId ──────────────────────────────────────────────────────────────────

class StreamId:
    """
    Factory for Event Sourcing stream identifiers.

    Streams:
      customer:{id}     — all decisions for one customer aggregate
      case:{id}         — events for a single compliance case
      channel:{name}    — decisions by payment channel
      all               — global stream (full event log)

    Usage:
        sid = StreamId.for_customer("cust-001")
        # → "customer:cust-001"
        StreamId.parse("customer:cust-001")
        # → ("customer", "cust-001")
    """

    ALL = "all"

    @staticmethod
    def for_customer(customer_id: str) -> str:
        return f"customer:{customer_id}"

    @staticmethod
    def for_case(case_id: str) -> str:
        return f"case:{case_id}"

    @staticmethod
    def for_channel(channel: str) -> str:
        return f"channel:{channel}"

    @staticmethod
    def parse(stream_id: str) -> tuple[str, str | None]:
        """
        Parse a stream_id into (stream_type, stream_value).

        Examples:
            "customer:cust-001"  → ("customer", "cust-001")
            "case:abc-123"       → ("case", "abc-123")
            "all"                → ("all", None)
        """
        if stream_id == StreamId.ALL:
            return ("all", None)
        parts = stream_id.split(":", 1)
        if len(parts) == 2:
            return (parts[0], parts[1])
        return ("unknown", stream_id)

    @staticmethod
    def is_valid(stream_id: str) -> bool:
        if stream_id == StreamId.ALL:
            return True
        return bool(re.match(r"^(customer|case|channel):.+$", stream_id))


# ── SequenceRecord ────────────────────────────────────────────────────────────

@dataclass
class AppendResult:
    """
    Result of EventStore.append().

    Attributes:
        event_id        UUID from DecisionEvent.
        stream_id       The stream this event was appended to.
        sequence_number Monotonic position within the stream (1-based,
                        in-process only — resets on restart).
        audit_port_id   event_id returned by AuditPort (should match).
    """
    event_id:        str
    stream_id:       str
    sequence_number: int
    audit_port_id:   str


# ── EventStore ────────────────────────────────────────────────────────────────

class EventStore:
    """
    Write-side Event Sourcing abstraction for BANXE compliance decisions.

    Wraps AuditPort (I-24 append-only) and adds:
      - Stream identity (StreamId)
      - Per-stream sequence numbers (monotonic, in-process)
      - replay_into(Projector) — full event log replay for read model rebuild

    Construction:
        store = EventStore(audit_port=InMemoryAuditAdapter())
        store = EventStore(audit_port=PostgresEventLogAdapter())

    Append:
        result = await store.append(event)
        # → AppendResult(event_id, stream_id, sequence_number, audit_port_id)

    Load stream:
        events = await store.load_stream(StreamId.for_customer("cust-001"))

    Replay into projector:
        projector = Projector()
        count = await store.replay_into(projector)
    """

    def __init__(self, audit_port: AuditPort) -> None:
        self._audit                          = audit_port
        # Per-stream sequence counters (in-process, not persisted)
        self._sequences: dict[str, int]      = {}

    # ── Write side ────────────────────────────────────────────────────────────

    async def append(
        self,
        event: "DecisionEvent",
        stream_id: str | None = None,
    ) -> AppendResult:
        """
        Append a DecisionEvent to the store.

        If stream_id is not given, it is derived from the event's customer_id
        (if present) or falls back to StreamId.ALL.

        Delegates persistence to AuditPort — never raises on connectivity errors
        (inherits AuditPort fail-safe guarantee).
        """
        if stream_id is None:
            if event.customer_id:
                stream_id = StreamId.for_customer(event.customer_id)
            else:
                stream_id = StreamId.ALL

        # Increment per-stream sequence counter
        self._sequences[stream_id] = self._sequences.get(stream_id, 0) + 1
        seq = self._sequences[stream_id]

        # Also bump global stream counter
        self._sequences[StreamId.ALL] = self._sequences.get(StreamId.ALL, 0) + 1

        audit_id = await self._audit.append_event(event)

        return AppendResult(
            event_id        = event.event_id,
            stream_id       = stream_id,
            sequence_number = seq,
            audit_port_id   = audit_id,
        )

    # ── Read side ─────────────────────────────────────────────────────────────

    async def load_stream(
        self,
        stream_id: str,
        limit: int = 1000,
    ) -> list["DecisionEvent"]:
        """
        Load events for the given stream from AuditPort.

        Stream routing:
          "customer:X"  → query_events(customer_id=X)
          "case:X"      → query_events(case_id=X)
          "all"         → query_events() — full log
          "channel:X"   → query_events() filtered post-fetch by channel
        """
        stream_type, stream_value = StreamId.parse(stream_id)

        if stream_type == "customer":
            return await self._audit.query_events(
                customer_id=stream_value, limit=limit
            )
        if stream_type == "case":
            return await self._audit.query_events(
                case_id=stream_value, limit=limit
            )
        if stream_type == "channel":
            all_events = await self._audit.query_events(limit=limit)
            return [e for e in all_events if e.channel == stream_value]
        if stream_type == "all":
            return await self._audit.query_events(limit=limit)

        # Unknown stream type — return empty (safe default)
        return []

    async def replay_into(self, projector: "Projector") -> int:
        """
        Replay the full event log into a Projector to rebuild all read models.

        Returns the number of events replayed.

        This is the CQRS projection rebuild operation — used when:
          - Projector is first created (cold start)
          - A read model needs to be rebuilt after schema change
          - FCA audit replay (point-in-time reconstruction)
        """
        events = await self._audit.query_events(limit=100_000)
        for event in events:
            projector.apply(event)
        return len(events)

    # ── Diagnostics ───────────────────────────────────────────────────────────

    def sequence_for(self, stream_id: str) -> int:
        """Return current sequence number for a stream (0 if no events yet)."""
        return self._sequences.get(stream_id, 0)

    def total_appended(self) -> int:
        """Total events appended in this EventStore instance's lifetime."""
        return self._sequences.get(StreamId.ALL, 0)
