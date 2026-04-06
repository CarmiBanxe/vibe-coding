#!/usr/bin/env python3
"""
test_decision_event_log.py — Unit tests for G-01 Decision Event Log.

Tests:
  T-01  DecisionEvent.from_aml_result() builds correct fields
  T-02  InMemoryAuditAdapter: append returns event_id
  T-03  InMemoryAuditAdapter: query by case_id
  T-04  InMemoryAuditAdapter: query by customer_id
  T-05  InMemoryAuditAdapter: idempotent (duplicate event_id silently ignored)
  T-06  InMemoryAuditAdapter: I-24 — no update/delete methods exposed
  T-07  PostgresEventLogAdapter: DB error → logs warning, returns event_id (fail-safe)
  T-08  PostgresEventLogAdapter: idempotent ON CONFLICT DO NOTHING
  T-09  get_decision_log() returns PostgresEventLogAdapter by default
  T-10  set_decision_log() injects InMemoryAuditAdapter
  T-11  banxe_assess() calls decision log (integration point)
  T-12  DecisionEvent.to_dict() is JSON-serialisable
  T-13  AuditPort ABC: cannot instantiate directly
  T-14  query with no filters returns all events
  T-15  query limit is respected

Invariant coverage:
  I-24: No update_event / delete_event on AuditPort (T-06, T-13)
"""
from __future__ import annotations

import asyncio
import sys
import os
import json
import uuid
from dataclasses import dataclass, field
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

BASE = os.path.dirname(os.path.abspath(__file__))   # src/compliance/
SRC  = os.path.dirname(BASE)                         # src/
sys.path.insert(0, SRC)   # enables: from compliance.ports.audit_port import ...
sys.path.insert(0, BASE)  # enables: from models import ...  (legacy direct imports)

from compliance.ports.audit_port import AuditPort
from compliance.utils.decision_event_log import (
    DecisionEvent,
    InMemoryAuditAdapter,
    PostgresEventLogAdapter,
    get_decision_log,
    set_decision_log,
)


def run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


# ── Helpers ───────────────────────────────────────────────────────────────────

def _make_event(
    case_id: str = "",
    decision: str = "APPROVE",
    score: int = 10,
    customer_id: str | None = None,
    tx_id: str | None = None,
) -> DecisionEvent:
    return DecisionEvent(
        case_id          = case_id or str(uuid.uuid4()),
        decision         = decision,
        composite_score  = score,
        decision_reason  = "threshold",
        tx_id            = tx_id,
        channel          = "bank_transfer",
        customer_id      = customer_id,
        requires_edd         = False,
        requires_mlro_review = False,
        hard_block_hit       = False,
        sanctions_hit        = False,
        crypto_risk          = False,
        policy_version       = "developer-core@2026-04-05",
        signals_count    = 0,
        rules_triggered  = [],
        signals_json     = [],
        audit_payload    = {},
    )


def _make_mock_aml_result(
    decision="HOLD",
    score=55,
    case_id=None,
    customer_id="C-001",
    channel="bank_transfer",
    sanctions_hit=False,
    hard_block_hit=False,
    crypto_risk=False,
    requires_edd=True,
    requires_mlro=False,
):
    """Build a minimal BanxeAMLResult-like object for testing."""
    # Minimal RiskSignal mock
    sig = MagicMock()
    sig.source = "tx_monitor"
    sig.rule   = "FPS_STRUCTURING"
    sig.score  = 55
    sig.reason = "Test reason"

    result = MagicMock()
    result.decision        = decision
    result.score           = score
    result.case_id         = case_id or str(uuid.uuid4())
    result.decision_reason = "threshold"
    result.channel         = channel
    result.requires_edd         = requires_edd
    result.requires_mlro_review = requires_mlro
    result.hard_block_hit       = hard_block_hit
    result.sanctions_hit        = sanctions_hit
    result.crypto_risk          = crypto_risk
    result.policy_version = "developer-core@2026-04-05"
    result.policy_scope   = {
        "policy_jurisdiction": "UK",
        "policy_regulator":    "FCA",
        "policy_framework":    "MLR 2017",
    }
    result.signals       = [sig]
    result.audit_payload = {"customer_id": customer_id, "tx_id": "TX-001"}
    return result


# ═══════════════════════════════════════════════════════════════════════════════
# T-01  DecisionEvent.from_aml_result
# ═══════════════════════════════════════════════════════════════════════════════

def test_t01_from_aml_result_fields():
    """from_aml_result() maps all BanxeAMLResult fields correctly."""
    mock_result = _make_mock_aml_result(
        decision="HOLD", score=55, customer_id="C-001",
        requires_edd=True, sanctions_hit=False,
    )
    event = DecisionEvent.from_aml_result(mock_result)

    assert event.decision        == "HOLD"
    assert event.composite_score == 55
    assert event.customer_id     == "C-001"
    assert event.tx_id           == "TX-001"
    assert event.requires_edd    is True
    assert event.sanctions_hit   is False
    assert event.policy_version  == "developer-core@2026-04-05"
    assert event.policy_jurisdiction == "UK"
    assert event.policy_regulator    == "FCA"
    assert event.signals_count   == 1
    assert "FPS_STRUCTURING" in event.rules_triggered
    assert event.case_id == mock_result.case_id
    assert event.event_type == "AML_DECISION"
    assert event.occurred_at is not None


# ═══════════════════════════════════════════════════════════════════════════════
# T-02  InMemoryAuditAdapter: append returns event_id
# ═══════════════════════════════════════════════════════════════════════════════

def test_t02_inmemory_append_returns_event_id():
    """append_event returns the event's event_id."""
    store = InMemoryAuditAdapter()
    event = _make_event(decision="APPROVE", score=5)
    returned_id = run(store.append_event(event))
    assert returned_id == event.event_id
    assert len(store.all_events()) == 1


# ═══════════════════════════════════════════════════════════════════════════════
# T-03  InMemoryAuditAdapter: query by case_id
# ═══════════════════════════════════════════════════════════════════════════════

def test_t03_inmemory_query_by_case_id():
    """query_events filters by case_id correctly."""
    store = InMemoryAuditAdapter()
    case_a = str(uuid.uuid4())
    case_b = str(uuid.uuid4())

    run(store.append_event(_make_event(case_id=case_a, decision="HOLD")))
    run(store.append_event(_make_event(case_id=case_a, decision="REJECT")))
    run(store.append_event(_make_event(case_id=case_b, decision="APPROVE")))

    results = run(store.query_events(case_id=case_a))
    assert len(results) == 2
    assert all(e.case_id == case_a for e in results)

    results_b = run(store.query_events(case_id=case_b))
    assert len(results_b) == 1
    assert results_b[0].decision == "APPROVE"


# ═══════════════════════════════════════════════════════════════════════════════
# T-04  InMemoryAuditAdapter: query by customer_id
# ═══════════════════════════════════════════════════════════════════════════════

def test_t04_inmemory_query_by_customer_id():
    """query_events filters by customer_id correctly."""
    store = InMemoryAuditAdapter()
    run(store.append_event(_make_event(customer_id="C-Alice", decision="HOLD")))
    run(store.append_event(_make_event(customer_id="C-Bob",   decision="APPROVE")))
    run(store.append_event(_make_event(customer_id="C-Alice", decision="SAR")))

    results = run(store.query_events(customer_id="C-Alice"))
    assert len(results) == 2
    decisions = {e.decision for e in results}
    assert decisions == {"HOLD", "SAR"}


# ═══════════════════════════════════════════════════════════════════════════════
# T-05  InMemoryAuditAdapter: idempotent duplicate event_id
# ═══════════════════════════════════════════════════════════════════════════════

def test_t05_inmemory_idempotent():
    """Duplicate event_id is silently ignored — append is idempotent."""
    store = InMemoryAuditAdapter()
    event = _make_event(decision="REJECT", score=75)
    run(store.append_event(event))
    run(store.append_event(event))   # same event_id → must not duplicate
    run(store.append_event(event))

    assert len(store.all_events()) == 1


# ═══════════════════════════════════════════════════════════════════════════════
# T-06  I-24: AuditPort has no update or delete methods
# ═══════════════════════════════════════════════════════════════════════════════

def test_t06_i24_no_update_delete_on_port():
    """
    I-24: AuditPort (and all adapters) must NOT expose update_event or delete_event.
    These methods are intentionally absent. If any adapter adds them, it violates I-24.
    """
    store = InMemoryAuditAdapter()
    assert not hasattr(AuditPort, "update_event"),  "I-24 violated: AuditPort.update_event must not exist"
    assert not hasattr(AuditPort, "delete_event"),  "I-24 violated: AuditPort.delete_event must not exist"
    assert not hasattr(store, "update_event"),      "I-24 violated: InMemoryAuditAdapter.update_event must not exist"
    assert not hasattr(store, "delete_event"),      "I-24 violated: InMemoryAuditAdapter.delete_event must not exist"
    pg = PostgresEventLogAdapter()
    assert not hasattr(pg, "update_event"),         "I-24 violated: PostgresEventLogAdapter.update_event must not exist"
    assert not hasattr(pg, "delete_event"),         "I-24 violated: PostgresEventLogAdapter.delete_event must not exist"


# ═══════════════════════════════════════════════════════════════════════════════
# T-07  PostgresEventLogAdapter: DB error → fail-safe, returns event_id
# ═══════════════════════════════════════════════════════════════════════════════

def test_t07_postgres_adapter_fail_safe():
    """
    If asyncpg raises (DB unreachable), append_event logs the error but
    NEVER propagates it — fail-safe. Returns event_id regardless.
    """
    adapter = PostgresEventLogAdapter(dsn="postgresql://invalid:5432/none")
    event   = _make_event(decision="REJECT", score=80)

    # Should not raise even though DB is unavailable
    returned_id = run(adapter.append_event(event))
    assert returned_id == event.event_id


# ═══════════════════════════════════════════════════════════════════════════════
# T-08  PostgresEventLogAdapter: mocked DB — ON CONFLICT DO NOTHING
# ═══════════════════════════════════════════════════════════════════════════════

def test_t08_postgres_adapter_mocked_insert():
    """PostgresEventLogAdapter calls asyncpg.execute with correct SQL."""
    mock_conn = AsyncMock()
    mock_conn.execute = AsyncMock(return_value=None)
    mock_conn.close   = AsyncMock(return_value=None)

    mock_asyncpg = MagicMock()
    mock_asyncpg.connect = AsyncMock(return_value=mock_conn)

    event   = _make_event(decision="SAR", score=90, customer_id="C-999")
    adapter = PostgresEventLogAdapter()

    with patch.dict("sys.modules", {"asyncpg": mock_asyncpg}):
        returned_id = run(adapter.append_event(event))

    assert returned_id == event.event_id
    mock_conn.execute.assert_called_once()
    sql_called = mock_conn.execute.call_args[0][0]
    assert "ON CONFLICT (event_id) DO NOTHING" in sql_called
    assert "decision_events" in sql_called


# ═══════════════════════════════════════════════════════════════════════════════
# T-09  get_decision_log() default adapter
# ═══════════════════════════════════════════════════════════════════════════════

def test_t09_get_decision_log_default():
    """get_decision_log() returns PostgresEventLogAdapter by default."""
    import compliance.utils.decision_event_log as del_module
    del_module._DEFAULT_LOG = None   # reset
    log = get_decision_log()
    assert isinstance(log, PostgresEventLogAdapter)
    del_module._DEFAULT_LOG = None   # cleanup


# ═══════════════════════════════════════════════════════════════════════════════
# T-10  set_decision_log() injection
# ═══════════════════════════════════════════════════════════════════════════════

def test_t10_set_decision_log_injection():
    """set_decision_log() overrides with InMemoryAuditAdapter."""
    import compliance.utils.decision_event_log as del_module
    mem = InMemoryAuditAdapter()
    set_decision_log(mem)
    assert get_decision_log() is mem
    del_module._DEFAULT_LOG = None   # cleanup


# ═══════════════════════════════════════════════════════════════════════════════
# T-11  banxe_assess() calls decision log
# ═══════════════════════════════════════════════════════════════════════════════

def test_t11_banxe_assess_calls_decision_log():
    """
    banxe_assess() calls get_decision_log().append_event() after each decision.
    Uses InMemoryAuditAdapter so no Postgres required.
    """
    import compliance.utils.decision_event_log as del_module
    mem = InMemoryAuditAdapter()
    set_decision_log(mem)

    # Mock the Layer 2 orchestrator (heavy deps)
    from compliance.models import AMLResult
    mock_layer2 = AMLResult(
        decision="APPROVE",
        score=0,
        signals=[],
        requires_edd=False,
        requires_mlro_review=False,
    )

    with patch("compliance.banxe_aml_orchestrator._layer2_assess",
               new=AsyncMock(return_value=mock_layer2)):
        import compliance.banxe_aml_orchestrator as orch
        result = run(orch.banxe_assess())

    assert len(mem.all_events()) == 1
    logged = mem.all_events()[0]
    assert logged.decision  == "APPROVE"
    assert logged.case_id   == result.case_id
    assert logged.event_type == "AML_DECISION"

    del_module._DEFAULT_LOG = None   # cleanup


# ═══════════════════════════════════════════════════════════════════════════════
# T-12  DecisionEvent.to_dict() is JSON-serialisable
# ═══════════════════════════════════════════════════════════════════════════════

def test_t12_to_dict_json_serialisable():
    """to_dict() output must be JSON-serialisable (required for ClickHouse + Postgres JSONB)."""
    event = _make_event(decision="SAR", score=90, customer_id="C-XYZ", tx_id="TX-999")
    d = event.to_dict()
    serialised = json.dumps(d)   # must not raise
    assert "SAR" in serialised
    assert "TX-999" in serialised


# ═══════════════════════════════════════════════════════════════════════════════
# T-13  AuditPort ABC cannot be instantiated directly
# ═══════════════════════════════════════════════════════════════════════════════

def test_t13_audit_port_is_abstract():
    """AuditPort is an ABC — cannot instantiate directly (enforces design contract)."""
    with pytest.raises(TypeError):
        AuditPort()   # type: ignore[abstract]


# ═══════════════════════════════════════════════════════════════════════════════
# T-14  query with no filters returns all events
# ═══════════════════════════════════════════════════════════════════════════════

def test_t14_query_no_filters_returns_all():
    """query_events() with no filters returns all events."""
    store = InMemoryAuditAdapter()
    for decision in ("APPROVE", "HOLD", "REJECT"):
        run(store.append_event(_make_event(decision=decision)))

    all_results = run(store.query_events())
    assert len(all_results) == 3


# ═══════════════════════════════════════════════════════════════════════════════
# T-15  query limit is respected
# ═══════════════════════════════════════════════════════════════════════════════

def test_t15_query_limit():
    """query_events(limit=N) returns at most N events."""
    store = InMemoryAuditAdapter()
    for _ in range(10):
        run(store.append_event(_make_event()))

    limited = run(store.query_events(limit=3))
    assert len(limited) == 3
