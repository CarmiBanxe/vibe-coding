"""
projections.py — G-17 CQRS Read Models.

Three projections rebuilt from the DecisionEvent stream:

  RiskSummaryView     — per-customer aggregate (last decision, counts, trend)
  DailyStatsView      — per-date aggregate (volume, rates, channels)
  CustomerRiskView    — full per-customer event history for MLRO review

All projections are pure Python dataclasses — no storage, no external calls.
The Projector (projector.py) owns a dict of each type and updates them
as events are applied (projector.apply(event)).

CQRS design:
  Write path:  banxe_assess() → EventStore.append() → AuditPort (I-24)
  Read path:   EventStore.replay_into(Projector) → these projections

FCA audit use cases answered by each projection:
  RiskSummaryView   "What is customer X's current risk profile?"
  DailyStatsView    "How many SARs were filed on 2026-04-05?"
  CustomerRiskView  "Show full decision history for customer X (MLRO review)"
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from compliance.utils.decision_event_log import DecisionEvent


# ── Decision ordering for trend analysis ─────────────────────────────────────
_DECISION_WEIGHT: dict[str, int] = {
    "APPROVE": 0,
    "HOLD":    1,
    "REJECT":  2,
    "SAR":     3,
}


def _trend(last_decisions: list[str]) -> str:
    """
    Compute risk trend from a list of decisions in chronological order.
    Requires at least 3 decisions; otherwise returns "STABLE".

    Trend:
      ESCALATING     — last weight > first weight (risk increasing)
      DE-ESCALATING  — last weight < first weight (risk decreasing)
      STABLE         — no clear direction
    """
    if len(last_decisions) < 3:
        return "STABLE"
    weights = [_DECISION_WEIGHT.get(d, 0) for d in last_decisions[-3:]]
    if weights[-1] > weights[0]:
        return "ESCALATING"
    if weights[-1] < weights[0]:
        return "DE-ESCALATING"
    return "STABLE"


# ── RiskSummaryView ───────────────────────────────────────────────────────────

@dataclass
class RiskSummaryView:
    """
    Per-customer aggregate risk summary.

    Rebuilt from the customer:{id} event stream.
    Updated incrementally by Projector.apply(event).

    Fields:
        customer_id         Customer aggregate root ID.
        last_decision       Most recent decision outcome.
        last_case_id        case_id of the most recent decision.
        last_occurred_at    ISO-8601 timestamp of last event.
        total_decisions     Total events in this customer's stream.
        approve_count       Count of APPROVE decisions.
        hold_count          Count of HOLD decisions.
        reject_count        Count of REJECT decisions.
        sar_count           Count of SAR decisions.
        sanctions_hits      Cumulative sanctions_hit events.
        hard_block_hits     Cumulative hard_block_hit events.
        requires_mlro_count Events where requires_mlro_review=True.
        risk_score_avg      Running average composite score.
        channels_seen       Distinct payment channels used.
        risk_trend          ESCALATING | DE-ESCALATING | STABLE
    """
    customer_id:          str
    last_decision:        str        = ""
    last_case_id:         str        = ""
    last_occurred_at:     str        = ""
    total_decisions:      int        = 0
    approve_count:        int        = 0
    hold_count:           int        = 0
    reject_count:         int        = 0
    sar_count:            int        = 0
    sanctions_hits:       int        = 0
    hard_block_hits:      int        = 0
    requires_mlro_count:  int        = 0
    # Running average helpers (not exposed in to_dict to keep it clean)
    _score_total:         int        = field(default=0, repr=False)
    risk_score_avg:       float      = 0.0
    channels_seen:        list[str]  = field(default_factory=list)
    _decision_history:    list[str]  = field(default_factory=list, repr=False)
    risk_trend:           str        = "STABLE"

    def apply(self, event: "DecisionEvent") -> None:
        """Update this view with a new event (in-place mutation)."""
        self.total_decisions  += 1
        self.last_decision     = event.decision
        self.last_case_id      = event.case_id
        self.last_occurred_at  = event.occurred_at

        # Decision counts
        d = event.decision
        if d == "APPROVE":
            self.approve_count += 1
        elif d == "HOLD":
            self.hold_count += 1
        elif d == "REJECT":
            self.reject_count += 1
        elif d == "SAR":
            self.sar_count += 1

        # Risk flags
        if event.sanctions_hit:
            self.sanctions_hits += 1
        if event.hard_block_hit:
            self.hard_block_hits += 1
        if event.requires_mlro_review:
            self.requires_mlro_count += 1

        # Running average score
        self._score_total += event.composite_score
        self.risk_score_avg = round(self._score_total / self.total_decisions, 2)

        # Channels
        if event.channel and event.channel not in self.channels_seen:
            self.channels_seen.append(event.channel)

        # Trend (last 10 decisions)
        self._decision_history.append(event.decision)
        if len(self._decision_history) > 10:
            self._decision_history = self._decision_history[-10:]
        self.risk_trend = _trend(self._decision_history)

    def to_dict(self) -> dict:
        return {
            "customer_id":         self.customer_id,
            "last_decision":       self.last_decision,
            "last_case_id":        self.last_case_id,
            "last_occurred_at":    self.last_occurred_at,
            "total_decisions":     self.total_decisions,
            "approve_count":       self.approve_count,
            "hold_count":          self.hold_count,
            "reject_count":        self.reject_count,
            "sar_count":           self.sar_count,
            "sanctions_hits":      self.sanctions_hits,
            "hard_block_hits":     self.hard_block_hits,
            "requires_mlro_count": self.requires_mlro_count,
            "risk_score_avg":      self.risk_score_avg,
            "channels_seen":       list(self.channels_seen),
            "risk_trend":          self.risk_trend,
        }


# ── DailyStatsView ────────────────────────────────────────────────────────────

@dataclass
class DailyStatsView:
    """
    Per-date aggregate statistics.

    Rebuilt from the global event stream, partitioned by date (YYYY-MM-DD).

    Fields:
        date            YYYY-MM-DD.
        total           Total decisions on this date.
        approve         APPROVE count.
        hold            HOLD count.
        reject          REJECT count.
        sar             SAR count.
        avg_score       Average composite score.
        reject_rate     (reject + sar) / total  — key FCA monitoring KPI.
        channels        Decision count per channel.
        policy_versions Distinct policy versions seen.
    """
    date:             str
    total:            int             = 0
    approve:          int             = 0
    hold:             int             = 0
    reject:           int             = 0
    sar:              int             = 0
    _score_total:     int             = field(default=0, repr=False)
    avg_score:        float           = 0.0
    reject_rate:      float           = 0.0
    channels:         dict[str, int]  = field(default_factory=dict)
    policy_versions:  list[str]       = field(default_factory=list)

    def apply(self, event: "DecisionEvent") -> None:
        """Update this daily view with a new event."""
        self.total += 1
        d = event.decision
        if d == "APPROVE":
            self.approve += 1
        elif d == "HOLD":
            self.hold += 1
        elif d == "REJECT":
            self.reject += 1
        elif d == "SAR":
            self.sar += 1

        self._score_total += event.composite_score
        self.avg_score    = round(self._score_total / self.total, 2)
        self.reject_rate  = round((self.reject + self.sar) / self.total, 4)

        if event.channel:
            self.channels[event.channel] = self.channels.get(event.channel, 0) + 1

        if event.policy_version and event.policy_version not in self.policy_versions:
            self.policy_versions.append(event.policy_version)

    def to_dict(self) -> dict:
        return {
            "date":            self.date,
            "total":           self.total,
            "approve":         self.approve,
            "hold":            self.hold,
            "reject":          self.reject,
            "sar":             self.sar,
            "avg_score":       self.avg_score,
            "reject_rate":     self.reject_rate,
            "channels":        dict(self.channels),
            "policy_versions": list(self.policy_versions),
        }


# ── CustomerRiskView ──────────────────────────────────────────────────────────

@dataclass
class CustomerRiskView:
    """
    Full per-customer event history for MLRO review.

    Stores all events in chronological order.
    Provides derived fields for FCA reporting without re-scanning events.

    Fields:
        customer_id         Aggregate root.
        events              All DecisionEvents in chronological order.
        first_seen          occurred_at of the first event.
        last_seen           occurred_at of the most recent event.
        risk_trend          ESCALATING | DE-ESCALATING | STABLE
        high_risk_events    Events where decision is REJECT or SAR.
    """
    customer_id:      str
    events:           list["DecisionEvent"] = field(default_factory=list)
    first_seen:       str                   = ""
    last_seen:        str                   = ""
    risk_trend:       str                   = "STABLE"
    _decision_hist:   list[str]             = field(default_factory=list, repr=False)

    def apply(self, event: "DecisionEvent") -> None:
        """Append event to history (chronological order maintained by replay)."""
        self.events.append(event)
        if not self.first_seen:
            self.first_seen = event.occurred_at
        self.last_seen = event.occurred_at
        self._decision_hist.append(event.decision)
        if len(self._decision_hist) > 10:
            self._decision_hist = self._decision_hist[-10:]
        self.risk_trend = _trend(self._decision_hist)

    @property
    def high_risk_events(self) -> list["DecisionEvent"]:
        """Events where decision is REJECT or SAR — for MLRO escalation list."""
        return [e for e in self.events if e.decision in ("REJECT", "SAR")]

    @property
    def event_count(self) -> int:
        return len(self.events)

    def to_dict(self) -> dict:
        return {
            "customer_id":       self.customer_id,
            "event_count":       self.event_count,
            "first_seen":        self.first_seen,
            "last_seen":         self.last_seen,
            "risk_trend":        self.risk_trend,
            "high_risk_count":   len(self.high_risk_events),
            "events":            [e.to_dict() for e in self.events],
        }
