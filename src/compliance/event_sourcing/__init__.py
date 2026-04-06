"""
event_sourcing — G-17 Event Sourcing + CQRS read models.

Write side:
    EventStore   — wraps AuditPort, adds stream identity + replay
    StreamId     — stream address factory
    AppendResult — result of EventStore.append()

Read side (CQRS projections):
    Projector           — applies events to projections
    RiskSummaryView     — per-customer aggregate risk state
    DailyStatsView      — per-date aggregate statistics
    CustomerRiskView    — full per-customer event history (MLRO review)
"""
from compliance.event_sourcing.event_store   import AppendResult, EventStore, StreamId
from compliance.event_sourcing.projections   import (
    CustomerRiskView,
    DailyStatsView,
    RiskSummaryView,
)
from compliance.event_sourcing.projector     import Projector

__all__ = [
    # Write side
    "EventStore",
    "StreamId",
    "AppendResult",
    # Read side
    "Projector",
    "RiskSummaryView",
    "DailyStatsView",
    "CustomerRiskView",
]
