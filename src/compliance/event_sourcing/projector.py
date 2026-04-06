"""
projector.py — G-17 CQRS Projector.

Projector is the CQRS read-side engine that:
  1. Consumes a stream of DecisionEvents (via apply(event) or apply_batch)
  2. Maintains three read model projections:
       _risk_summaries    dict[customer_id, RiskSummaryView]
       _daily_stats       dict[date, DailyStatsView]
       _customer_views    dict[customer_id, CustomerRiskView]
  3. Answers read queries without touching the write side (EventStore/AuditPort)

Typical lifecycle:
  1. Cold start:
       projector = Projector()
       await event_store.replay_into(projector)   # rebuild all projections

  2. Live update (after banxe_assess):
       projector.apply(event)                     # incremental update

  3. Read query:
       view = projector.get_risk_summary("cust-001")
       stats = projector.get_daily_stats("2026-04-05")
       history = projector.get_customer_view("cust-001")

Idempotency:
  Projector tracks applied event_ids.  Replaying the same event twice
  (e.g. during a partial replay after restart) is a no-op.  This ensures
  projections are exactly-once consistent even if replay_into() is called
  multiple times.

Isolation:
  Projector holds no external state.  It can be created fresh and rebuilt
  entirely from the event log — this is the key Event Sourcing guarantee.
"""
from __future__ import annotations

from typing import TYPE_CHECKING

from compliance.event_sourcing.projections import (
    CustomerRiskView,
    DailyStatsView,
    RiskSummaryView,
)

if TYPE_CHECKING:
    from compliance.utils.decision_event_log import DecisionEvent


def _date_from_iso(occurred_at: str) -> str:
    """Extract YYYY-MM-DD from an ISO-8601 timestamp."""
    return occurred_at[:10] if occurred_at else "unknown"


class Projector:
    """
    CQRS Projector — maintains three read model projections.

    Thread-safety: not thread-safe.  In a single-process async environment
    (asyncio), this is fine.  For multi-process deployments, each process
    builds its own Projector from the event log on startup.
    """

    def __init__(self) -> None:
        self._risk_summaries:  dict[str, RiskSummaryView]    = {}
        self._daily_stats:     dict[str, DailyStatsView]     = {}
        self._customer_views:  dict[str, CustomerRiskView]   = {}
        self._applied_ids:     set[str]                      = set()
        self._total_applied:   int                           = 0

    # ── Write (projection update) ──────────────────────────────────────────────

    def apply(self, event: "DecisionEvent") -> bool:
        """
        Apply a single event to all projections.

        Returns True if the event was applied, False if it was a duplicate
        (already applied — idempotency guard).

        Events without a customer_id update DailyStatsView only (anonymous
        transactions still contribute to daily aggregate stats).
        """
        if event.event_id in self._applied_ids:
            return False

        self._applied_ids.add(event.event_id)
        self._total_applied += 1

        # ── DailyStatsView (all events, keyed by date) ───────────��────────────
        date = _date_from_iso(event.occurred_at)
        if date not in self._daily_stats:
            self._daily_stats[date] = DailyStatsView(date=date)
        self._daily_stats[date].apply(event)

        # ── Customer-scoped projections (only if customer_id known) ───────────
        cid = event.customer_id
        if cid:
            # RiskSummaryView
            if cid not in self._risk_summaries:
                self._risk_summaries[cid] = RiskSummaryView(customer_id=cid)
            self._risk_summaries[cid].apply(event)

            # CustomerRiskView
            if cid not in self._customer_views:
                self._customer_views[cid] = CustomerRiskView(customer_id=cid)
            self._customer_views[cid].apply(event)

        return True

    def apply_batch(self, events: list["DecisionEvent"]) -> int:
        """
        Apply a list of events in order.
        Returns the number of events actually applied (duplicates skipped).
        """
        return sum(1 for e in events if self.apply(e))

    # ── Read queries ──────────────────────────────────────────────────────────

    def get_risk_summary(self, customer_id: str) -> RiskSummaryView | None:
        """Return the current RiskSummaryView for a customer, or None."""
        return self._risk_summaries.get(customer_id)

    def get_daily_stats(self, date: str) -> DailyStatsView | None:
        """Return DailyStatsView for a date (YYYY-MM-DD), or None."""
        return self._daily_stats.get(date)

    def get_customer_view(self, customer_id: str) -> CustomerRiskView | None:
        """Return full CustomerRiskView for MLRO review, or None."""
        return self._customer_views.get(customer_id)

    def all_risk_summaries(self) -> list[RiskSummaryView]:
        """Return all RiskSummaryViews sorted by customer_id."""
        return sorted(self._risk_summaries.values(), key=lambda v: v.customer_id)

    def all_daily_stats(self) -> list[DailyStatsView]:
        """Return all DailyStatsViews sorted by date ascending."""
        return sorted(self._daily_stats.values(), key=lambda v: v.date)

    def escalating_customers(self) -> list[RiskSummaryView]:
        """
        Return customers with ESCALATING risk trend.
        Priority queue for MLRO review.
        """
        return [
            v for v in self._risk_summaries.values()
            if v.risk_trend == "ESCALATING"
        ]

    def customers_with_sar(self) -> list[RiskSummaryView]:
        """Return customers with at least one SAR decision."""
        return [v for v in self._risk_summaries.values() if v.sar_count > 0]

    def customers_requiring_mlro(self) -> list[RiskSummaryView]:
        """Return customers with at least one requires_mlro_review event."""
        return [
            v for v in self._risk_summaries.values()
            if v.requires_mlro_count > 0
        ]

    # ── Diagnostics ─────────────────────────���─────────────────────────────────

    @property
    def total_applied(self) -> int:
        """Total events applied (duplicates excluded)."""
        return self._total_applied

    @property
    def customer_count(self) -> int:
        """Number of distinct customers in the projections."""
        return len(self._risk_summaries)

    @property
    def date_count(self) -> int:
        """Number of distinct dates in the daily stats projection."""
        return len(self._daily_stats)

    def snapshot(self) -> dict:
        """
        Return a diagnostic snapshot of projection state.
        Used in health checks and FCA audit reporting.
        """
        return {
            "total_applied":    self._total_applied,
            "customer_count":   self.customer_count,
            "date_count":       self.date_count,
            "escalating_count": len(self.escalating_customers()),
            "sar_count":        sum(v.sar_count for v in self._risk_summaries.values()),
            "mlro_queue_size":  len(self.customers_requiring_mlro()),
        }

    def reset(self) -> None:
        """
        Clear all projections and applied-ids set.
        Used to force a full rebuild from the event log.
        """
        self._risk_summaries.clear()
        self._daily_stats.clear()
        self._customer_views.clear()
        self._applied_ids.clear()
        self._total_applied = 0
