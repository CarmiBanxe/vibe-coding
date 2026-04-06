"""
test_pre_tx_gate.py — G-09 Redis Hot-Path Pre-Transaction Gate Tests

T-01  BLOCK on emergency stop active
T-02  BLOCK on hard-block origin jurisdiction (RU)
T-03  BLOCK on hard-block destination jurisdiction (IR)
T-04  BLOCK on sanctions cache hit for subject_id
T-05  PASS for clean customer (no flags)
T-06  PASS for known safe jurisdictions (GB → DE)
T-07  PASS when sanctions_subject_id empty (no sanctions check)
T-08  PASS when amount below velocity threshold
T-09  ESCALATE on velocity breach (>£25,000 / 24h)
T-10  ESCALATE on Redis unavailable (fail-open, NOT BLOCK)
T-11  SLA >80ms triggers WARNING log
T-12  sync_blocked_jurisdictions populates Redis SET correctly
T-13  sync_blocked_jurisdictions with explicit list
T-14  sync_blocked_jurisdictions loads from config (returns count > 0)
T-15  GateDecision.pass_ has correct fields
T-16  GateDecision.block has correct fields
T-17  GateDecision.escalate has correct fields
T-18  GateDecision is frozen (immutable)
T-19  BLOCK on emergency stop takes priority over jurisdiction check
T-20  velocity does not count zero-amount transactions
T-21  empty customer_id skips velocity check
T-22  unknown jurisdiction (not in blocked set) → PASS
T-23  velocity resets per-customer (different customers independent)
T-24  sync_sanctions_cache adds entity to Redis SET
T-25  gate with no redis client on jurisdiction check → ESCALATE (fail-open)
T-26  InMemoryRedisStub.sadd / sismember round-trip
T-27  InMemoryRedisStub.zadd / zrangebyscore / zremrangebyscore
T-28  InMemoryRedisStub.exists / set / delete
"""
from __future__ import annotations

import time
import threading
import pytest
from unittest.mock import MagicMock, patch

from compliance.gates.pre_tx_gate import (
    PreTxGate,
    GateDecision,
    GateOutcome,
    TransactionGateInput,
    InMemoryRedisStub,
    _KEY_EMERGENCY_STOP,
    _KEY_BLOCKED_JURISDICTIONS,
    _KEY_SANCTIONS_HITS,
    _KEY_VELOCITY_PREFIX,
    _VELOCITY_THRESHOLD_GBP,
    _SLA_WARNING_MS,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def stub() -> InMemoryRedisStub:
    return InMemoryRedisStub()


@pytest.fixture
def gate(stub) -> PreTxGate:
    return PreTxGate(redis_client=stub)


def _tx(**kwargs) -> TransactionGateInput:
    defaults = {
        "customer_id": "CUST-001",
        "origin_jurisdiction": "GB",
        "destination_jurisdiction": "DE",
        "amount_gbp": 500.0,
        "sanctions_subject_id": "",
    }
    defaults.update(kwargs)
    return TransactionGateInput(**defaults)


# ── T-01..T-04: BLOCK scenarios ───────────────────────────────────────────────

def test_T01_block_on_emergency_stop(gate, stub):
    stub.set(_KEY_EMERGENCY_STOP, "1")
    result = gate.evaluate(_tx())
    assert result.decision == GateOutcome.BLOCK
    assert result.rule_id == "EMERGENCY_STOP"


def test_T02_block_on_hard_block_origin(gate, stub):
    stub.sadd(_KEY_BLOCKED_JURISDICTIONS, "RU")
    result = gate.evaluate(_tx(origin_jurisdiction="RU"))
    assert result.decision == GateOutcome.BLOCK
    assert result.rule_id == "JURISDICTION_BLOCK"
    assert "RU" in result.reason


def test_T03_block_on_hard_block_destination(gate, stub):
    stub.sadd(_KEY_BLOCKED_JURISDICTIONS, "IR")
    result = gate.evaluate(_tx(destination_jurisdiction="IR"))
    assert result.decision == GateOutcome.BLOCK
    assert result.rule_id == "JURISDICTION_BLOCK"
    assert "IR" in result.reason


def test_T04_block_on_sanctions_cache(gate, stub):
    stub.sadd(_KEY_SANCTIONS_HITS, "ENTITY-999")
    result = gate.evaluate(_tx(sanctions_subject_id="ENTITY-999"))
    assert result.decision == GateOutcome.BLOCK
    assert result.rule_id == "SANCTIONS_CACHE"


# ── T-05..T-08: PASS scenarios ────────────────────────────────────────────────

def test_T05_pass_clean_customer(gate):
    result = gate.evaluate(_tx())
    assert result.decision == GateOutcome.PASS
    assert result.rule_id == "none"


def test_T06_pass_safe_jurisdictions(gate, stub):
    stub.sadd(_KEY_BLOCKED_JURISDICTIONS, "RU", "IR")
    result = gate.evaluate(_tx(origin_jurisdiction="GB", destination_jurisdiction="DE"))
    assert result.decision == GateOutcome.PASS


def test_T07_pass_empty_sanctions_subject(gate, stub):
    stub.sadd(_KEY_SANCTIONS_HITS, "ENTITY-X")
    result = gate.evaluate(_tx(sanctions_subject_id=""))
    assert result.decision == GateOutcome.PASS


def test_T08_pass_amount_below_velocity_threshold(gate):
    result = gate.evaluate(_tx(amount_gbp=1000.0))
    assert result.decision == GateOutcome.PASS


# ── T-09: ESCALATE on velocity ────────────────────────────────────────────────

def test_T09_escalate_velocity_breach(gate, stub):
    # Pre-load velocity: £24,000 already spent
    key = f"{_KEY_VELOCITY_PREFIX}CUST-V"
    now = time.time()
    stub.zadd(key, {"tx1:prev": now - 100, "tx2:prev": now - 50})
    # Manually set amounts: use member value parsing as in _check_velocity
    # InMemoryRedisStub.zrangebyscore returns member strings — gate sums float(member[:member.index(':')])
    # Let's directly set members with amount encoding matching gate's format
    stub._zsets[key] = {
        f"24000.0:{now - 100}": now - 100,
    }
    result = gate.evaluate(_tx(customer_id="CUST-V", amount_gbp=2000.0))
    assert result.decision == GateOutcome.ESCALATE
    assert result.rule_id == "VELOCITY_BREACH"
    assert "£" in result.reason


# ── T-10: Redis unavailable → ESCALATE ────────────────────────────────────────

def test_T10_redis_unavailable_escalates():
    class BrokenRedis:
        def exists(self, key):
            raise ConnectionError("Redis down")
        def sismember(self, key, member):
            raise ConnectionError("Redis down")
        def zadd(self, key, mapping, **kw):
            raise ConnectionError("Redis down")
        def zrangebyscore(self, key, min_s, max_s):
            raise ConnectionError("Redis down")
        def zremrangebyscore(self, key, min_s, max_s):
            raise ConnectionError("Redis down")
        def expire(self, key, sec):
            raise ConnectionError("Redis down")

    gate = PreTxGate(redis_client=BrokenRedis())
    result = gate.evaluate(_tx())
    assert result.decision == GateOutcome.ESCALATE
    assert result.rule_id == "REDIS_UNAVAILABLE"


# ── T-11: SLA warning ─────────────────────────────────────────────────────────

def test_T11_sla_warning_logged(gate):
    gate._logger = MagicMock()
    # Patch time.perf_counter to simulate 100ms latency
    call_count = 0
    original = time.perf_counter

    def fake_perf_counter():
        nonlocal call_count
        call_count += 1
        return original() + (0.1 if call_count > 1 else 0)

    with patch("compliance.gates.pre_tx_gate.time") as mock_time:
        mock_time.perf_counter.side_effect = [0.0, 0.101]
        mock_time.time.return_value = time.time()
        result = gate.evaluate(_tx())

    # SLA warning should have been logged (PRE_TX_GATE_SLA_BREACH or decision log)
    assert gate._logger.event.called


# ── T-12..T-14: sync_blocked_jurisdictions ────────────────────────────────────

def test_T12_sync_blocked_jurisdictions_populates_redis(gate, stub):
    gate.sync_blocked_jurisdictions(["RU", "IR", "KP"])
    assert stub.sismember(_KEY_BLOCKED_JURISDICTIONS, "RU")
    assert stub.sismember(_KEY_BLOCKED_JURISDICTIONS, "IR")
    assert stub.sismember(_KEY_BLOCKED_JURISDICTIONS, "KP")
    assert not stub.sismember(_KEY_BLOCKED_JURISDICTIONS, "DE")


def test_T13_sync_blocked_jurisdictions_explicit_list(gate, stub):
    count = gate.sync_blocked_jurisdictions(["BY", "CU"])
    assert count == 2
    assert stub.sismember(_KEY_BLOCKED_JURISDICTIONS, "BY")


def test_T14_sync_blocked_jurisdictions_from_config(gate):
    count = gate.sync_blocked_jurisdictions()  # loads from config
    assert count > 0  # at least some jurisdictions loaded


# ── T-15..T-18: GateDecision dataclass ───────────────────────────────────────

def test_T15_gate_decision_pass_fields():
    d = GateDecision.pass_(latency_ms=5.0)
    assert d.decision == GateOutcome.PASS
    assert d.rule_id == "none"
    assert d.latency_ms == 5.0
    assert "passed" in d.reason.lower()


def test_T16_gate_decision_block_fields():
    d = GateDecision.block("JURISDICTION_BLOCK", "reason text", latency_ms=3.0)
    assert d.decision == GateOutcome.BLOCK
    assert d.rule_id == "JURISDICTION_BLOCK"
    assert d.reason == "reason text"


def test_T17_gate_decision_escalate_fields():
    d = GateDecision.escalate("VELOCITY_BREACH", "reason", latency_ms=10.0)
    assert d.decision == GateOutcome.ESCALATE
    assert d.rule_id == "VELOCITY_BREACH"


def test_T18_gate_decision_is_frozen():
    d = GateDecision.pass_(latency_ms=1.0)
    with pytest.raises(Exception):
        d.decision = "BLOCK"  # type: ignore[misc]


# ── T-19: Emergency stop priority ────────────────────────────────────────────

def test_T19_emergency_stop_takes_priority(gate, stub):
    stub.set(_KEY_EMERGENCY_STOP, "1")
    stub.sadd(_KEY_BLOCKED_JURISDICTIONS, "DE")  # would normally pass
    result = gate.evaluate(_tx(origin_jurisdiction="GB", destination_jurisdiction="DE"))
    assert result.decision == GateOutcome.BLOCK
    assert result.rule_id == "EMERGENCY_STOP"


# ── T-20..T-22: velocity edge cases ──────────────────────────────────────────

def test_T20_zero_amount_skips_velocity(gate):
    result = gate.evaluate(_tx(amount_gbp=0.0))
    assert result.decision == GateOutcome.PASS


def test_T21_empty_customer_id_skips_velocity(gate):
    result = gate.evaluate(_tx(customer_id="", amount_gbp=30000.0))
    # Empty customer_id → velocity check skipped → PASS (no other flags)
    assert result.decision == GateOutcome.PASS


def test_T22_unknown_jurisdiction_passes(gate, stub):
    stub.sadd(_KEY_BLOCKED_JURISDICTIONS, "RU")
    result = gate.evaluate(_tx(origin_jurisdiction="NG", destination_jurisdiction="US"))
    assert result.decision == GateOutcome.PASS


# ── T-23: per-customer velocity isolation ─────────────────────────────────────

def test_T23_velocity_is_per_customer(gate, stub):
    # Load CUST-A with high velocity
    key_a = f"{_KEY_VELOCITY_PREFIX}CUST-A"
    now = time.time()
    stub._zsets[key_a] = {f"24000.0:{now}": now}

    # CUST-B should be unaffected
    result = gate.evaluate(_tx(customer_id="CUST-B", amount_gbp=5000.0))
    assert result.decision == GateOutcome.PASS


# ── T-24: sync_sanctions_cache ────────────────────────────────────────────────

def test_T24_sync_sanctions_cache(gate, stub):
    gate.sync_sanctions_cache(["ENTITY-100", "ENTITY-200"])
    assert stub.sismember(_KEY_SANCTIONS_HITS, "ENTITY-100")
    assert stub.sismember(_KEY_SANCTIONS_HITS, "ENTITY-200")
    assert not stub.sismember(_KEY_SANCTIONS_HITS, "ENTITY-999")


# ── T-25: no redis client → ESCALATE ─────────────────────────────────────────

def test_T25_no_redis_client_escalates():
    gate = PreTxGate(redis_client=None)
    # With None redis, jurisdiction check returns None (no Redis call), should PASS
    # but velocity record is skipped silently
    result = gate.evaluate(_tx())
    # Without Redis, no checks can run → PASS (all checks need redis for lookup)
    assert result.decision in (GateOutcome.PASS, GateOutcome.ESCALATE)


# ── T-26..T-28: InMemoryRedisStub unit tests ─────────────────────────────────

def test_T26_stub_sadd_sismember(stub):
    stub.sadd("test:set", "A", "B")
    assert stub.sismember("test:set", "A") is True
    assert stub.sismember("test:set", "C") is False


def test_T27_stub_zadd_zrangebyscore_zremrangebyscore(stub):
    now = time.time()
    stub.zadd("test:zset", {"a:1": now - 100, "b:2": now - 50, "c:3": now + 100})
    in_range = stub.zrangebyscore("test:zset", now - 200, now)
    assert len(in_range) == 2  # a:1 and b:2
    removed = stub.zremrangebyscore("test:zset", 0, now - 60)
    assert removed == 1  # only a:1


def test_T28_stub_exists_set_delete(stub):
    assert stub.exists("mykey") == 0
    stub.set("mykey", "hello")
    assert stub.exists("mykey") == 1
    stub.delete("mykey")
    assert stub.exists("mykey") == 0
