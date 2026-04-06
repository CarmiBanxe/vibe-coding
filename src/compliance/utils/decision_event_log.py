"""
decision_event_log.py — G-01 Decision Event Log.

Implements AuditPort with two adapters:
  PostgresEventLogAdapter  — asyncpg → banxe_compliance.decision_events
  InMemoryAuditAdapter     — in-memory list, for tests and dev

PostgreSQL schema enforces I-24 at the DB level:
  REVOKE UPDATE, DELETE ON decision_events FROM banxe_app_role;

See: compliance/decision_events.sql (migration)

Usage (production):
    from compliance.utils.decision_event_log import (
        DecisionEvent, PostgresEventLogAdapter
    )
    log = PostgresEventLogAdapter()
    event_id = await log.append_event(DecisionEvent.from_aml_result(result))

Usage (tests / fallback):
    from compliance.utils.decision_event_log import InMemoryAuditAdapter
    log = InMemoryAuditAdapter()

Closes: GAP-REGISTER G-01
Invariants: I-24 (append-only), I-25 (ExplanationBundle — future field)
"""
from __future__ import annotations

import json
import logging
import uuid
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Any

from compliance.ports.audit_port import AuditPort

log = logging.getLogger(__name__)

_PG_DSN = "postgresql://banxe:banxe_secure_2026@127.0.0.1:5432/banxe_compliance"
_SCHEMA  = "banxe_compliance"
_TABLE   = "decision_events"


# ── Domain event ─────────────────────────────────────────────────────────────

@dataclass
class DecisionEvent:
    """
    Immutable record of one compliance decision.
    Primary unit of the Decision Event Log (G-01).

    event_id is set once and never mutated — I-24.
    """
    # Identity
    event_id:         str = field(default_factory=lambda: str(uuid.uuid4()))
    event_type:       str = "AML_DECISION"
    occurred_at:      str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    # Core decision
    case_id:          str = ""
    decision:         str = ""   # APPROVE | HOLD | REJECT | SAR
    composite_score:  int = 0
    decision_reason:  str = ""   # threshold | hard_override | high_risk_floor

    # Context
    tx_id:            str | None = None
    channel:          str = ""
    customer_id:      str | None = None

    # Routing flags
    requires_edd:         bool = False
    requires_mlro_review: bool = False
    hard_block_hit:       bool = False
    sanctions_hit:        bool = False
    crypto_risk:          bool = False

    # Policy provenance (FCA audit trail requirement)
    policy_version:       str = ""
    policy_jurisdiction:  str = "UK"
    policy_regulator:     str = "FCA"
    policy_framework:     str = "MLR 2017"

    # Signals
    signals_count:    int        = 0
    rules_triggered:  list[str]  = field(default_factory=list)
    signals_json:     list[dict] = field(default_factory=list)

    # Raw context payload (JSON)
    audit_payload:    dict = field(default_factory=dict)

    @classmethod
    def from_aml_result(cls, result: Any) -> "DecisionEvent":
        """
        Build a DecisionEvent from a BanxeAMLResult instance.
        Type-annotated as Any to avoid circular import.
        """
        tx_id = None
        if result.audit_payload:
            tx_id = result.audit_payload.get("tx_id")

        rules = sorted({s.rule for s in result.signals})
        signals_dicts = [
            {"source": s.source, "rule": s.rule,
             "score": s.score, "reason": s.reason[:200]}
            for s in result.signals
        ]

        return cls(
            case_id          = result.case_id,
            decision         = result.decision,
            composite_score  = result.score,
            decision_reason  = result.decision_reason,
            tx_id            = tx_id,
            channel          = result.channel,
            customer_id      = result.audit_payload.get("customer_id"),
            requires_edd         = result.requires_edd,
            requires_mlro_review = result.requires_mlro_review,
            hard_block_hit       = result.hard_block_hit,
            sanctions_hit        = result.sanctions_hit,
            crypto_risk          = result.crypto_risk,
            policy_version      = result.policy_version,
            policy_jurisdiction = result.policy_scope.get("policy_jurisdiction", "UK"),
            policy_regulator    = result.policy_scope.get("policy_regulator", "FCA"),
            policy_framework    = result.policy_scope.get("policy_framework", "MLR 2017"),
            signals_count    = len(result.signals),
            rules_triggered  = rules,
            signals_json     = signals_dicts,
            audit_payload    = result.audit_payload,
        )

    def to_dict(self) -> dict:
        d = asdict(self)
        # Ensure JSON-serialisable
        d["rules_triggered"] = list(d["rules_triggered"])
        return d


# ── PostgresEventLogAdapter ───────────────────────────────────────────────────

class PostgresEventLogAdapter(AuditPort):
    """
    Primary production adapter — asyncpg → banxe_compliance.decision_events.

    The PostgreSQL table is configured with:
      REVOKE UPDATE, DELETE ON decision_events FROM banxe_app_role;
    which enforces I-24 at the database level, not just the application level.

    Fail-safe: any DB error is logged but never propagated to the caller.
    The decision has already been made and communicated — a log failure
    must not cause a 500 response or data loss of the decision itself.
    """

    def __init__(self, dsn: str = _PG_DSN) -> None:
        self._dsn = dsn

    async def append_event(self, event: DecisionEvent) -> str:
        """
        INSERT into decision_events. Returns event_id.
        Silently ignores duplicate event_id (ON CONFLICT DO NOTHING).
        Logs errors but never raises — fail-safe design.
        """
        try:
            import asyncpg
            conn = await asyncpg.connect(self._dsn, timeout=5)
            try:
                await conn.execute(
                    f"""
                    INSERT INTO {_SCHEMA}.{_TABLE} (
                        event_id, event_type, occurred_at,
                        case_id, decision, composite_score, decision_reason,
                        tx_id, channel, customer_id,
                        requires_edd, requires_mlro_review,
                        hard_block_hit, sanctions_hit, crypto_risk,
                        policy_version, policy_jurisdiction,
                        policy_regulator, policy_framework,
                        signals_count, rules_triggered,
                        signals_json, audit_payload
                    ) VALUES (
                        $1, $2, $3,
                        $4, $5, $6, $7,
                        $8, $9, $10,
                        $11, $12,
                        $13, $14, $15,
                        $16, $17,
                        $18, $19,
                        $20, $21,
                        $22, $23
                    )
                    ON CONFLICT (event_id) DO NOTHING
                    """,
                    event.event_id, event.event_type,
                    datetime.fromisoformat(event.occurred_at),
                    event.case_id, event.decision, event.composite_score,
                    event.decision_reason,
                    event.tx_id, event.channel, event.customer_id,
                    event.requires_edd, event.requires_mlro_review,
                    event.hard_block_hit, event.sanctions_hit, event.crypto_risk,
                    event.policy_version, event.policy_jurisdiction,
                    event.policy_regulator, event.policy_framework,
                    event.signals_count, event.rules_triggered,
                    json.dumps(event.signals_json, ensure_ascii=False),
                    json.dumps(event.audit_payload, ensure_ascii=False),
                )
            finally:
                await conn.close()
        except Exception as e:
            log.error(
                "decision_event_log: failed to append event_id=%s case_id=%s: %s",
                event.event_id, event.case_id, e,
            )
        return event.event_id

    async def query_events(
        self,
        case_id: str | None = None,
        customer_id: str | None = None,
        limit: int = 100,
    ) -> list[DecisionEvent]:
        """
        Read events from decision_events table.
        Used by replay_decision.py for FCA audit replay (G-01).
        """
        where_clauses: list[str] = []
        params: list[Any] = []

        if case_id:
            params.append(case_id)
            where_clauses.append(f"case_id = ${len(params)}")
        if customer_id:
            params.append(customer_id)
            where_clauses.append(f"customer_id = ${len(params)}")

        where = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""
        params.append(limit)
        sql = f"""
            SELECT event_id, event_type, occurred_at,
                   case_id, decision, composite_score, decision_reason,
                   tx_id, channel, customer_id,
                   requires_edd, requires_mlro_review,
                   hard_block_hit, sanctions_hit, crypto_risk,
                   policy_version, policy_jurisdiction,
                   policy_regulator, policy_framework,
                   signals_count, rules_triggered,
                   signals_json, audit_payload
            FROM {_SCHEMA}.{_TABLE}
            {where}
            ORDER BY occurred_at ASC
            LIMIT ${len(params)}
        """
        try:
            import asyncpg
            conn = await asyncpg.connect(self._dsn, timeout=5)
            try:
                rows = await conn.fetch(sql, *params)
            finally:
                await conn.close()
        except Exception as e:
            log.error("decision_event_log: query failed: %s", e)
            return []

        events = []
        for row in rows:
            events.append(DecisionEvent(
                event_id        = str(row["event_id"]),
                event_type      = row["event_type"],
                occurred_at     = row["occurred_at"].isoformat(),
                case_id         = str(row["case_id"]),
                decision        = row["decision"],
                composite_score = row["composite_score"],
                decision_reason = row["decision_reason"],
                tx_id           = row["tx_id"],
                channel         = row["channel"] or "",
                customer_id     = row["customer_id"],
                requires_edd         = row["requires_edd"],
                requires_mlro_review = row["requires_mlro_review"],
                hard_block_hit       = row["hard_block_hit"],
                sanctions_hit        = row["sanctions_hit"],
                crypto_risk          = row["crypto_risk"],
                policy_version      = row["policy_version"] or "",
                policy_jurisdiction = row["policy_jurisdiction"] or "UK",
                policy_regulator    = row["policy_regulator"] or "FCA",
                policy_framework    = row["policy_framework"] or "MLR 2017",
                signals_count    = row["signals_count"],
                rules_triggered  = list(row["rules_triggered"] or []),
                signals_json     = json.loads(row["signals_json"] or "[]"),
                audit_payload    = json.loads(row["audit_payload"] or "{}"),
            ))
        return events


# ── InMemoryAuditAdapter ──────────────────────────────────────────────────────

class InMemoryAuditAdapter(AuditPort):
    """
    In-memory adapter for tests and local development.
    No database required. Events lost on restart — not for production.
    """

    def __init__(self) -> None:
        self._events: list[DecisionEvent] = []

    async def append_event(self, event: DecisionEvent) -> str:
        # Idempotent: ignore duplicate event_id
        if not any(e.event_id == event.event_id for e in self._events):
            self._events.append(event)
        return event.event_id

    async def query_events(
        self,
        case_id: str | None = None,
        customer_id: str | None = None,
        limit: int = 100,
    ) -> list[DecisionEvent]:
        results = self._events
        if case_id:
            results = [e for e in results if e.case_id == case_id]
        if customer_id:
            results = [e for e in results if e.customer_id == customer_id]
        return results[:limit]

    def all_events(self) -> list[DecisionEvent]:
        """Test helper — returns all events in insertion order."""
        return list(self._events)

    def clear(self) -> None:
        """Test helper — reset store."""
        self._events.clear()


# ── Module-level default adapter (injectable) ────────────────────────────────

_DEFAULT_LOG: AuditPort | None = None


def get_decision_log() -> AuditPort:
    """
    Returns the configured decision log adapter.
    Default: PostgresEventLogAdapter (production).
    Override in tests: set_decision_log(InMemoryAuditAdapter()).
    """
    global _DEFAULT_LOG
    if _DEFAULT_LOG is None:
        _DEFAULT_LOG = PostgresEventLogAdapter()
    return _DEFAULT_LOG


def set_decision_log(adapter: AuditPort) -> None:
    """Inject a different adapter (test/dev override)."""
    global _DEFAULT_LOG
    _DEFAULT_LOG = adapter
