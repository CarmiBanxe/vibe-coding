"""
test_event_sourcing.py — G-17 Event Sourcing + CQRS Tests

T-01  event_sourcing package exports all public symbols
T-02  StreamId.for_customer builds correct stream_id
T-03  StreamId.for_case builds correct stream_id
T-04  StreamId.for_channel builds correct stream_id
T-05  StreamId.parse decomposes customer stream_id
T-06  StreamId.parse decomposes "all"
T-07  StreamId.is_valid accepts known prefixes and rejects unknown
T-08  EventStore.append returns AppendResult with correct fields
T-09  EventStore.append auto-derives customer stream when customer_id present
T-10  EventStore.append falls back to StreamId.ALL when no customer_id
T-11  EventStore sequence_for increments per stream
T-12  EventStore total_appended counts all appends (global counter)
T-13  EventStore.load_stream("customer:X") returns only that customer's events
T-14  EventStore.load_stream("case:X") returns only that case's events
T-15  EventStore.load_stream("all") returns all events
T-16  EventStore.load_stream("channel:X") filters by channel
T-17  EventStore.load_stream unknown type returns empty list
T-18  EventStore.replay_into feeds all events to Projector, returns count
T-19  Projector.apply returns True for new event
T-20  Projector.apply returns False for duplicate event_id (idempotency)
T-21  Projector.apply updates RiskSummaryView for customer
T-22  Projector.apply updates DailyStatsView for date
T-23  Projector.apply updates CustomerRiskView for customer
T-24  Projector.apply ignores customer-scoped projections for events without customer_id
T-25  RiskSummaryView counts decisions correctly (approve/hold/reject/sar)
T-26  RiskSummaryView risk_score_avg is running average
T-27  RiskSummaryView channels_seen deduplicates channels
T-28  RiskSummaryView sanctions_hits + hard_block_hits counted
T-29  RiskSummaryView risk_trend=ESCALATING after APPROVE→APPROVE→SAR
T-30  RiskSummaryView risk_trend=DE-ESCALATING after SAR→REJECT→APPROVE
T-31  RiskSummaryView risk_trend=STABLE when fewer than 3 decisions
T-32  DailyStatsView reject_rate = (reject+sar)/total
T-33  DailyStatsView channels dict accumulates correctly
T-34  DailyStatsView policy_versions deduplicates
T-35  CustomerRiskView.high_risk_events returns only REJECT+SAR
T-36  CustomerRiskView.event_count matches applied events
T-37  Projector.escalating_customers returns correct subset
T-38  Projector.customers_with_sar returns customers with sar_count > 0
T-39  Projector.customers_requiring_mlro filters correctly
T-40  Projector.snapshot returns diagnostic dict with expected keys
T-41  Full round-trip: EventStore.append → replay_into → projections consistent
T-42  Projector.reset clears all projections and counter
T-43  Projector.apply_batch returns count of applied events
T-44  EventStore.replay_into on empty store returns 0
T-45  RiskSummaryView.to_dict is JSON-serialisable
T-46  DailyStatsView.to_dict is JSON-serialisable
T-47  CustomerRiskView.to_dict includes events list
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import uuid
from datetime import datetime, timezone

import pytest

# ── Path bootstrap ─────────────────────────────────────────────────────────────
_BASE = os.path.dirname(os.path.abspath(__file__))
_SRC  = os.path.dirname(_BASE)
sys.path.insert(0, _SRC)
sys.path.insert(0, _BASE)

from compliance.event_sourcing import (
    AppendResult,
    CustomerRiskView,
    DailyStatsView,
    EventStore,
    Projector,
    RiskSummaryView,
    StreamId,
)
from compliance.event_sourcing.event_store import StreamId
from compliance.utils.decision_event_log import DecisionEvent, InMemoryAuditAdapter


# ── Helpers ───────────────────────────────────────────────────────────────────

def _event(
    decision:    str        = "APPROVE",
    score:       int        = 20,
    customer_id: str | None = "cust-001",
    case_id:     str | None = None,
    channel:     str        = "bank_transfer",
    occurred_at: str | None = None,
    sanctions:   bool       = False,
    hard_block:  bool       = False,
    mlro:        bool       = False,
    policy_ver:  str        = "dev@2026-04-05",
) -> DecisionEvent:
    return DecisionEvent(
        event_id         = str(uuid.uuid4()),
        decision         = decision,
        composite_score  = score,
        customer_id      = customer_id,
        case_id          = case_id or str(uuid.uuid4()),
        channel          = channel,
        occurred_at      = occurred_at or datetime.now(timezone.utc).isoformat(),
        sanctions_hit    = sanctions,
        hard_block_hit   = hard_block,
        requires_mlro_review = mlro,
        policy_version   = policy_ver,
    )


def _store() -> tuple[EventStore, InMemoryAuditAdapter]:
    audit = InMemoryAuditAdapter()
    store = EventStore(audit_port=audit)
    return store, audit


# ── T-01: Package exports ─────────────────────────────────────────��───────────

def test_T01_package_exports():
    from compliance import event_sourcing as es
    for name in ("EventStore", "StreamId", "AppendResult",
                 "Projector", "RiskSummaryView", "DailyStatsView", "CustomerRiskView"):
        assert hasattr(es, name), f"Missing export: {name}"


# ── T-02..T-07: StreamId ──────────────────────────────────────────────────────

def test_T02_stream_id_for_customer():
    assert StreamId.for_customer("cust-001") == "customer:cust-001"


def test_T03_stream_id_for_case():
    assert StreamId.for_case("case-abc") == "case:case-abc"


def test_T04_stream_id_for_channel():
    assert StreamId.for_channel("crypto") == "channel:crypto"


def test_T05_stream_id_parse_customer():
    stype, sval = StreamId.parse("customer:cust-001")
    assert stype == "customer"
    assert sval  == "cust-001"


def test_T06_stream_id_parse_all():
    stype, sval = StreamId.parse("all")
    assert stype == "all"
    assert sval  is None


def test_T07_stream_id_is_valid():
    assert StreamId.is_valid("customer:x") is True
    assert StreamId.is_valid("case:y") is True
    assert StreamId.is_valid("channel:crypto") is True
    assert StreamId.is_valid("all") is True
    assert StreamId.is_valid("unknown") is False
    assert StreamId.is_valid("foo:bar") is False


# ── T-08..T-12: EventStore.append ─────────────────────────────────────────────

@pytest.mark.asyncio
async def test_T08_append_returns_append_result():
    store, _ = _store()
    e   = _event()
    res = await store.append(e)
    assert isinstance(res, AppendResult)
    assert res.event_id   == e.event_id
    assert res.stream_id  == StreamId.for_customer("cust-001")
    assert res.sequence_number == 1


@pytest.mark.asyncio
async def test_T09_append_derives_customer_stream():
    store, _ = _store()
    e   = _event(customer_id="alice")
    res = await store.append(e)
    assert res.stream_id == "customer:alice"


@pytest.mark.asyncio
async def test_T10_append_falls_back_to_all():
    store, _ = _store()
    e   = _event(customer_id=None)
    res = await store.append(e)
    assert res.stream_id == StreamId.ALL


@pytest.mark.asyncio
async def test_T11_sequence_increments_per_stream():
    store, _ = _store()
    for _ in range(3):
        await store.append(_event(customer_id="alice"))
    assert store.sequence_for("customer:alice") == 3
    assert store.sequence_for("customer:bob")   == 0


@pytest.mark.asyncio
async def test_T12_total_appended():
    store, _ = _store()
    await store.append(_event(customer_id="a"))
    await store.append(_event(customer_id="b"))
    await store.append(_event(customer_id="a"))
    assert store.total_appended() == 3


# ── T-13..T-17: EventStore.load_stream ───────────────────────────────────────

@pytest.mark.asyncio
async def test_T13_load_stream_customer():
    store, _ = _store()
    await store.append(_event(customer_id="alice"))
    await store.append(_event(customer_id="alice"))
    await store.append(_event(customer_id="bob"))
    events = await store.load_stream(StreamId.for_customer("alice"))
    assert len(events) == 2
    assert all(e.customer_id == "alice" for e in events)


@pytest.mark.asyncio
async def test_T14_load_stream_case():
    store, _ = _store()
    case_id = str(uuid.uuid4())
    await store.append(_event(case_id=case_id, customer_id="x"))
    await store.append(_event(customer_id="x"))          # different case
    events = await store.load_stream(StreamId.for_case(case_id))
    assert len(events) == 1
    assert events[0].case_id == case_id


@pytest.mark.asyncio
async def test_T15_load_stream_all():
    store, _ = _store()
    for _ in range(5):
        await store.append(_event())
    events = await store.load_stream(StreamId.ALL)
    assert len(events) == 5


@pytest.mark.asyncio
async def test_T16_load_stream_channel():
    store, _ = _store()
    await store.append(_event(channel="crypto"))
    await store.append(_event(channel="bank_transfer"))
    await store.append(_event(channel="crypto"))
    events = await store.load_stream(StreamId.for_channel("crypto"))
    assert len(events) == 2
    assert all(e.channel == "crypto" for e in events)


@pytest.mark.asyncio
async def test_T17_load_stream_unknown_type_empty():
    store, _ = _store()
    await store.append(_event())
    events = await store.load_stream("unknown:xyz")
    assert events == []


# ── T-18: replay_into ─────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_T18_replay_into_feeds_projector():
    store, _ = _store()
    for _ in range(4):
        await store.append(_event())
    proj  = Projector()
    count = await store.replay_into(proj)
    assert count == 4
    assert proj.total_applied == 4


# ── T-19..T-24: Projector.apply ───────────────────────────────────────────────

def test_T19_apply_returns_true_for_new():
    proj = Projector()
    assert proj.apply(_event()) is True


def test_T20_apply_returns_false_for_duplicate():
    proj = Projector()
    e    = _event()
    proj.apply(e)
    assert proj.apply(e) is False
    assert proj.total_applied == 1


def test_T21_apply_updates_risk_summary():
    proj = Projector()
    proj.apply(_event(customer_id="alice", decision="REJECT", score=75))
    summary = proj.get_risk_summary("alice")
    assert summary is not None
    assert summary.last_decision   == "REJECT"
    assert summary.total_decisions == 1
    assert summary.reject_count    == 1


def test_T22_apply_updates_daily_stats():
    proj = Projector()
    e    = _event(occurred_at="2026-04-05T10:00:00+00:00")
    proj.apply(e)
    stats = proj.get_daily_stats("2026-04-05")
    assert stats is not None
    assert stats.total == 1


def test_T23_apply_updates_customer_view():
    proj = Projector()
    proj.apply(_event(customer_id="alice"))
    view = proj.get_customer_view("alice")
    assert view is not None
    assert view.event_count == 1


def test_T24_no_customer_id_skips_customer_projections():
    proj = Projector()
    proj.apply(_event(customer_id=None, occurred_at="2026-04-05T12:00:00+00:00"))
    assert proj.get_risk_summary("None") is None
    assert proj.customer_count == 0
    # Daily stats still updated
    assert proj.get_daily_stats("2026-04-05") is not None


# ── T-25..T-31: RiskSummaryView ───────────────────────────────────────────────

def test_T25_risk_summary_decision_counts():
    proj = Projector()
    for d in ("APPROVE", "APPROVE", "HOLD", "REJECT", "SAR"):
        proj.apply(_event(customer_id="alice", decision=d))
    s = proj.get_risk_summary("alice")
    assert s.approve_count == 2
    assert s.hold_count    == 1
    assert s.reject_count  == 1
    assert s.sar_count     == 1


def test_T26_risk_summary_avg_score():
    proj = Projector()
    for score in (10, 20, 30):
        proj.apply(_event(customer_id="alice", score=score))
    s = proj.get_risk_summary("alice")
    assert s.risk_score_avg == 20.0


def test_T27_risk_summary_channels_deduped():
    proj = Projector()
    proj.apply(_event(customer_id="alice", channel="crypto"))
    proj.apply(_event(customer_id="alice", channel="crypto"))
    proj.apply(_event(customer_id="alice", channel="bank_transfer"))
    s = proj.get_risk_summary("alice")
    assert sorted(s.channels_seen) == ["bank_transfer", "crypto"]


def test_T28_risk_summary_flags():
    proj = Projector()
    proj.apply(_event(customer_id="alice", sanctions=True, hard_block=True, mlro=True))
    s = proj.get_risk_summary("alice")
    assert s.sanctions_hits      == 1
    assert s.hard_block_hits     == 1
    assert s.requires_mlro_count == 1


def test_T29_risk_trend_escalating():
    proj = Projector()
    for d in ("APPROVE", "APPROVE", "SAR"):
        proj.apply(_event(customer_id="alice", decision=d))
    s = proj.get_risk_summary("alice")
    assert s.risk_trend == "ESCALATING"


def test_T30_risk_trend_de_escalating():
    proj = Projector()
    for d in ("SAR", "REJECT", "APPROVE"):
        proj.apply(_event(customer_id="alice", decision=d))
    s = proj.get_risk_summary("alice")
    assert s.risk_trend == "DE-ESCALATING"


def test_T31_risk_trend_stable_less_than_3():
    proj = Projector()
    proj.apply(_event(customer_id="alice", decision="APPROVE"))
    s = proj.get_risk_summary("alice")
    assert s.risk_trend == "STABLE"


# ── T-32..T-34: DailyStatsView ───────────────────────────────────────────────

def test_T32_daily_stats_reject_rate():
    proj = Projector()
    date = "2026-04-05T10:00:00+00:00"
    proj.apply(_event(decision="APPROVE", occurred_at=date, customer_id="a"))
    proj.apply(_event(decision="REJECT",  occurred_at=date, customer_id="b"))
    proj.apply(_event(decision="SAR",     occurred_at=date, customer_id="c"))
    stats = proj.get_daily_stats("2026-04-05")
    # reject_rate = (1 REJECT + 1 SAR) / 3 total
    assert abs(stats.reject_rate - round(2/3, 4)) < 0.001


def test_T33_daily_stats_channels():
    proj  = Projector()
    date  = "2026-04-05T10:00:00+00:00"
    proj.apply(_event(channel="crypto",        occurred_at=date))
    proj.apply(_event(channel="bank_transfer", occurred_at=date))
    proj.apply(_event(channel="crypto",        occurred_at=date))
    stats = proj.get_daily_stats("2026-04-05")
    assert stats.channels["crypto"]        == 2
    assert stats.channels["bank_transfer"] == 1


def test_T34_daily_stats_policy_versions_deduped():
    proj = Projector()
    date = "2026-04-05T10:00:00+00:00"
    proj.apply(_event(policy_ver="v1", occurred_at=date))
    proj.apply(_event(policy_ver="v1", occurred_at=date))
    proj.apply(_event(policy_ver="v2", occurred_at=date))
    stats = proj.get_daily_stats("2026-04-05")
    assert sorted(stats.policy_versions) == ["v1", "v2"]


# ── T-35..T-36: CustomerRiskView ──────────────────────────────────────────────

def test_T35_customer_view_high_risk_events():
    proj = Projector()
    proj.apply(_event(customer_id="alice", decision="APPROVE"))
    proj.apply(_event(customer_id="alice", decision="REJECT"))
    proj.apply(_event(customer_id="alice", decision="SAR"))
    view = proj.get_customer_view("alice")
    assert len(view.high_risk_events) == 2


def test_T36_customer_view_event_count():
    proj = Projector()
    for _ in range(5):
        proj.apply(_event(customer_id="alice"))
    view = proj.get_customer_view("alice")
    assert view.event_count == 5


# ── T-37..T-40: Projector aggregates ─────────────────────────────────────────

def test_T37_escalating_customers():
    proj = Projector()
    for d in ("APPROVE", "APPROVE", "SAR"):
        proj.apply(_event(customer_id="alice", decision=d))
    for d in ("SAR", "REJECT", "APPROVE"):
        proj.apply(_event(customer_id="bob", decision=d))
    escalating = [v.customer_id for v in proj.escalating_customers()]
    assert "alice" in escalating
    assert "bob"   not in escalating


def test_T38_customers_with_sar():
    proj = Projector()
    proj.apply(_event(customer_id="alice", decision="SAR"))
    proj.apply(_event(customer_id="bob",   decision="APPROVE"))
    sar_customers = [v.customer_id for v in proj.customers_with_sar()]
    assert "alice" in sar_customers
    assert "bob"   not in sar_customers


def test_T39_customers_requiring_mlro():
    proj = Projector()
    proj.apply(_event(customer_id="alice", mlro=True))
    proj.apply(_event(customer_id="bob",   mlro=False))
    mlro_customers = [v.customer_id for v in proj.customers_requiring_mlro()]
    assert "alice" in mlro_customers
    assert "bob"   not in mlro_customers


def test_T40_snapshot_keys():
    proj = Projector()
    proj.apply(_event(customer_id="alice", decision="SAR", mlro=True))
    snap = proj.snapshot()
    for key in ("total_applied", "customer_count", "date_count",
                "escalating_count", "sar_count", "mlro_queue_size"):
        assert key in snap, f"Missing snapshot key: {key}"
    assert snap["total_applied"]  == 1
    assert snap["customer_count"] == 1
    assert snap["sar_count"]      == 1


# ── T-41..T-44: Integration + Edge cases ─────────────────────────────────────

@pytest.mark.asyncio
async def test_T41_full_round_trip():
    """EventStore.append → replay_into → projections consistent."""
    store, _ = _store()
    e1 = _event(customer_id="alice", decision="APPROVE", score=20,
                occurred_at="2026-04-05T09:00:00+00:00")
    e2 = _event(customer_id="alice", decision="REJECT",  score=75,
                occurred_at="2026-04-05T10:00:00+00:00")
    e3 = _event(customer_id="bob",   decision="HOLD",    score=45,
                occurred_at="2026-04-05T11:00:00+00:00")

    for e in (e1, e2, e3):
        await store.append(e)

    proj  = Projector()
    count = await store.replay_into(proj)

    assert count == 3
    assert proj.total_applied == 3

    alice = proj.get_risk_summary("alice")
    assert alice.total_decisions == 2
    assert alice.approve_count   == 1
    assert alice.reject_count    == 1

    bob = proj.get_risk_summary("bob")
    assert bob.hold_count == 1

    daily = proj.get_daily_stats("2026-04-05")
    assert daily.total == 3


def test_T42_projector_reset():
    proj = Projector()
    proj.apply(_event(customer_id="alice"))
    proj.reset()
    assert proj.total_applied  == 0
    assert proj.customer_count == 0
    assert proj.date_count     == 0
    assert proj.get_risk_summary("alice") is None


def test_T43_apply_batch_returns_count():
    proj   = Projector()
    events = [_event() for _ in range(5)]
    count  = proj.apply_batch(events)
    assert count == 5
    # Replay same batch — all duplicates
    dup_count = proj.apply_batch(events)
    assert dup_count == 0


@pytest.mark.asyncio
async def test_T44_replay_empty_store_returns_zero():
    store, _ = _store()
    proj  = Projector()
    count = await store.replay_into(proj)
    assert count == 0
    assert proj.total_applied == 0


# ── T-45..T-47: Serialisation ─────────────────────────────────────────────────

def test_T45_risk_summary_to_dict_json_serialisable():
    proj = Projector()
    proj.apply(_event(customer_id="alice", decision="REJECT", score=80))
    d = proj.get_risk_summary("alice").to_dict()
    assert json.dumps(d)   # must not raise


def test_T46_daily_stats_to_dict_json_serialisable():
    proj = Projector()
    proj.apply(_event(occurred_at="2026-04-05T10:00:00+00:00"))
    d = proj.get_daily_stats("2026-04-05").to_dict()
    assert json.dumps(d)   # must not raise


def test_T47_customer_view_to_dict_includes_events():
    proj = Projector()
    proj.apply(_event(customer_id="alice"))
    d = proj.get_customer_view("alice").to_dict()
    assert "events" in d
    assert len(d["events"]) == 1
    assert json.dumps(d)   # must not raise
