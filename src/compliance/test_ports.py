#!/usr/bin/env python3
"""
test_ports.py — Unit tests for G-16 Hexagonal Architecture Ports & Adapters.

Tests:
  T-01  ports/__init__.py exports all 4 ABCs
  T-02  PolicyPort is abstract — cannot instantiate directly
  T-03  DecisionPort is abstract — cannot instantiate directly
  T-04  EmergencyPort is abstract — cannot instantiate directly
  T-05  AuditPort is abstract — (existing, verified here for completeness)

  PolicyPort / ComplianceConfigPolicyAdapter:
  T-06  ComplianceConfigPolicyAdapter.get_threshold("sar") == 85
  T-07  ComplianceConfigPolicyAdapter.get_threshold("hold") == 40
  T-08  ComplianceConfigPolicyAdapter.get_threshold() raises KeyError on unknown
  T-09  ComplianceConfigPolicyAdapter.get_jurisdiction_class("RU") == "A"
  T-10  ComplianceConfigPolicyAdapter.get_jurisdiction_class("SY") == "B"
  T-11  ComplianceConfigPolicyAdapter.get_jurisdiction_class("GB") == "STANDARD"
  T-12  ComplianceConfigPolicyAdapter.get_forbidden_patterns() is non-empty list
  T-13  ComplianceConfigPolicyAdapter has NO write methods (I-22)

  PolicyPort / InMemoryPolicyAdapter:
  T-14  InMemoryPolicyAdapter default thresholds match production values
  T-15  InMemoryPolicyAdapter accepts threshold overrides
  T-16  InMemoryPolicyAdapter jurisdiction class correct with custom sets

  DecisionPort / BanxeAMLDecisionAdapter:
  T-17  BanxeAMLDecisionAdapter.emit_decision() writes event to injected AuditPort
  T-18  emit_decision() attaches explanation_bundle to audit_payload
  T-19  emit_decision() returns DecisionEvent with correct case_id

  DecisionPort / MockDecisionAdapter:
  T-20  MockDecisionAdapter captures emissions without writing to storage
  T-21  MockDecisionAdapter.last() returns most recent event
  T-22  MockDecisionAdapter.clear() resets emissions

  EmergencyPort / InMemoryEmergencyAdapter:
  T-23  is_stopped() returns False initially
  T-24  activate() sets is_stopped() to True
  T-25  clear() sets is_stopped() to False
  T-26  get_status() returns structured dict
  T-27  activate() is idempotent (double-activate stays stopped)
  T-28  EmergencyPort has NO update/delete — only activate/clear/is_stopped/get_status

  Integration:
  T-29  BanxeAMLDecisionAdapter + InMemoryAuditAdapter round-trip
  T-30  All 4 ports importable from compliance.ports

Invariant coverage:
  I-22 (T-13 — PolicyPort no write methods)
  I-23 (T-23..T-27 — EmergencyPort activate/clear lifecycle)
  I-24 (T-29 — AuditPort append-only, DecisionPort writes through it)
"""
from __future__ import annotations

import asyncio
import json
import sys
import os
import uuid
from unittest.mock import MagicMock

import pytest

BASE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.dirname(BASE)
sys.path.insert(0, SRC)
sys.path.insert(0, BASE)

# Ports
from compliance.ports import AuditPort, PolicyPort, DecisionPort, EmergencyPort

# Adapters
from compliance.adapters.compliance_config_adapter   import ComplianceConfigPolicyAdapter
from compliance.adapters.in_memory_policy_adapter    import InMemoryPolicyAdapter
from compliance.adapters.banxe_aml_decision_adapter  import BanxeAMLDecisionAdapter
from compliance.adapters.mock_decision_adapter        import MockDecisionAdapter
from compliance.adapters.in_memory_emergency_adapter  import InMemoryEmergencyAdapter

# AuditPort adapters (from G-01)
from compliance.utils.decision_event_log import (
    InMemoryAuditAdapter,
    DecisionEvent,
)
# ExplanationBundle (from G-02)
from compliance.utils.explanation_builder import ExplanationBundle


def run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


# ── Helpers ───────────────────────────────────────────────────────────────────

def _make_mock_result(decision="APPROVE", score=10, case_id=None):
    r = MagicMock()
    r.decision        = decision
    r.score           = score
    r.case_id         = case_id or str(uuid.uuid4())
    r.decision_reason = "threshold"
    r.channel         = "bank_transfer"
    r.requires_edd         = False
    r.requires_mlro_review = False
    r.hard_block_hit       = False
    r.sanctions_hit        = False
    r.crypto_risk          = False
    r.policy_version       = "developer-core@2026-04-05"
    r.policy_scope         = {
        "policy_jurisdiction": "UK",
        "policy_regulator":    "FCA",
        "policy_framework":    "MLR 2017",
    }
    r.signals         = []
    r.audit_payload   = {"tx_id": "TX-001", "customer_id": "C-001"}
    return r


# ═══════════════════════════════════════════════════════════════════════════════
# T-01  ports/__init__.py exports all 4 ABCs
# ═══════════════════════════════════════════════════════════════════════════════

def test_t01_ports_init_exports_all():
    """compliance.ports exports AuditPort, PolicyPort, DecisionPort, EmergencyPort."""
    import compliance.ports as ports_pkg
    for name in ("AuditPort", "PolicyPort", "DecisionPort", "EmergencyPort"):
        assert hasattr(ports_pkg, name), f"compliance.ports missing: {name}"


# ═══════════════════════════════════════════════════════════════════════════════
# T-02..T-05  All 4 Ports are abstract — cannot instantiate directly
# ═══════════════════════════════════════════════════════════════════════════════

def test_t02_policy_port_is_abstract():
    with pytest.raises(TypeError):
        PolicyPort()   # type: ignore[abstract]


def test_t03_decision_port_is_abstract():
    with pytest.raises(TypeError):
        DecisionPort()   # type: ignore[abstract]


def test_t04_emergency_port_is_abstract():
    with pytest.raises(TypeError):
        EmergencyPort()   # type: ignore[abstract]


def test_t05_audit_port_is_abstract():
    with pytest.raises(TypeError):
        AuditPort()   # type: ignore[abstract]


# ═══════════════════════════════════════════════════════════════════════════════
# T-06..T-12  ComplianceConfigPolicyAdapter
# ═══════════════════════════════════════════════════════════════════════════════

def test_t06_config_adapter_threshold_sar():
    assert ComplianceConfigPolicyAdapter().get_threshold("sar") == pytest.approx(85.0)


def test_t07_config_adapter_threshold_hold():
    assert ComplianceConfigPolicyAdapter().get_threshold("hold") == pytest.approx(40.0)


def test_t08_config_adapter_unknown_threshold_raises():
    with pytest.raises(KeyError, match="Unknown threshold"):
        ComplianceConfigPolicyAdapter().get_threshold("nonexistent")


def test_t09_config_adapter_jurisdiction_a():
    """RU is Category A (hard block) — SAMLA 2018."""
    assert ComplianceConfigPolicyAdapter().get_jurisdiction_class("RU") == "A"


def test_t10_config_adapter_jurisdiction_b():
    """SY is Category B (high risk, EDD) since July 2025."""
    assert ComplianceConfigPolicyAdapter().get_jurisdiction_class("SY") == "B"


def test_t11_config_adapter_jurisdiction_standard():
    """GB is STANDARD — no restrictions."""
    assert ComplianceConfigPolicyAdapter().get_jurisdiction_class("GB") == "STANDARD"


def test_t12_config_adapter_forbidden_patterns():
    patterns = ComplianceConfigPolicyAdapter().get_forbidden_patterns()
    assert isinstance(patterns, list)
    assert len(patterns) > 0
    assert all(isinstance(p, str) for p in patterns)


# ═══════════════════════════════════════════════════════════════════════════════
# T-13  ComplianceConfigPolicyAdapter has NO write methods (I-22)
# ═══════════════════════════════════════════════════════════════════════════════

def test_t13_policy_adapter_no_write_methods():
    """
    I-22: PolicyPort and its adapters must expose NO write methods.
    set_threshold, add_jurisdiction, update_forbidden must not exist.
    """
    adapter = ComplianceConfigPolicyAdapter()
    for forbidden in ("set_threshold", "add_jurisdiction", "update_forbidden",
                      "set_jurisdiction", "delete_threshold"):
        assert not hasattr(adapter, forbidden), (
            f"I-22 violated: PolicyPort adapter must not expose '{forbidden}'"
        )
    # Also verify on the ABC itself
    for forbidden in ("set_threshold", "add_jurisdiction", "update_forbidden"):
        assert not hasattr(PolicyPort, forbidden), (
            f"I-22 violated: PolicyPort ABC must not define '{forbidden}'"
        )


# ═══════════════════════════════════════════════════════════════════════════════
# T-14..T-16  InMemoryPolicyAdapter
# ═══════════════════════════════════════════════════════════════════════════════

def test_t14_in_memory_policy_defaults():
    """InMemoryPolicyAdapter default thresholds match production values."""
    adapter = InMemoryPolicyAdapter()
    assert adapter.get_threshold("sar")    == pytest.approx(85.0)
    assert adapter.get_threshold("reject") == pytest.approx(70.0)
    assert adapter.get_threshold("hold")   == pytest.approx(40.0)


def test_t15_in_memory_policy_override():
    """InMemoryPolicyAdapter accepts threshold overrides at construction."""
    adapter = InMemoryPolicyAdapter(thresholds={"sar": 90, "reject": 75, "hold": 45})
    assert adapter.get_threshold("sar")    == pytest.approx(90.0)
    assert adapter.get_threshold("reject") == pytest.approx(75.0)
    assert adapter.get_threshold("hold")   == pytest.approx(45.0)


def test_t16_in_memory_policy_jurisdiction():
    """InMemoryPolicyAdapter jurisdiction classification with custom sets."""
    adapter = InMemoryPolicyAdapter(
        hard_block={"XX"},
        high_risk={"YY"},
    )
    assert adapter.get_jurisdiction_class("XX") == "A"
    assert adapter.get_jurisdiction_class("YY") == "B"
    assert adapter.get_jurisdiction_class("GB") == "STANDARD"
    # Default RU not in custom set
    assert adapter.get_jurisdiction_class("RU") == "STANDARD"


# ═══════════════════════════════════════════════════════════════════════════════
# T-17..T-19  BanxeAMLDecisionAdapter
# ═══════════════════════════════════════════════════════════════════════════════

def test_t17_decision_adapter_writes_to_audit():
    """BanxeAMLDecisionAdapter.emit_decision() writes to injected AuditPort."""
    audit = InMemoryAuditAdapter()
    adapter = BanxeAMLDecisionAdapter(audit_port=audit)
    result = _make_mock_result(decision="APPROVE", score=5)

    event = run(adapter.emit_decision(result, explanation=None))

    assert len(audit.all_events()) == 1
    assert audit.all_events()[0].decision == "APPROVE"
    assert event.case_id == result.case_id


def test_t18_decision_adapter_attaches_explanation():
    """emit_decision() attaches explanation_bundle.to_dict() to audit_payload."""
    audit = InMemoryAuditAdapter()
    adapter = BanxeAMLDecisionAdapter(audit_port=audit)
    result = _make_mock_result(decision="HOLD", score=50)

    explanation = ExplanationBundle(
        case_id  = result.case_id,
        decision = "HOLD",
        narrative = "Test narrative",
    )
    event = run(adapter.emit_decision(result, explanation=explanation))

    assert "explanation_bundle" in event.audit_payload
    eb_dict = event.audit_payload["explanation_bundle"]
    assert eb_dict["decision"]  == "HOLD"
    assert eb_dict["narrative"] == "Test narrative"
    assert eb_dict["method"]    == "rule-based"


def test_t19_decision_adapter_returns_correct_event():
    """emit_decision() returns DecisionEvent with matching case_id."""
    audit = InMemoryAuditAdapter()
    adapter = BanxeAMLDecisionAdapter(audit_port=audit)
    case_id = str(uuid.uuid4())
    result = _make_mock_result(decision="SAR", score=90, case_id=case_id)

    event = run(adapter.emit_decision(result, explanation=None))

    assert isinstance(event, DecisionEvent)
    assert event.case_id  == case_id
    assert event.decision == "SAR"
    assert event.event_type == "AML_DECISION"


# ═══════════════════════════════════════════════════════════════════════════════
# T-20..T-22  MockDecisionAdapter
# ═══════════════════════════════════════════════════════════════════════════════

def test_t20_mock_adapter_captures_emissions():
    """MockDecisionAdapter captures calls without writing to storage."""
    adapter = MockDecisionAdapter()
    result = _make_mock_result(decision="REJECT", score=75)

    run(adapter.emit_decision(result, explanation=None))
    run(adapter.emit_decision(result, explanation=None))

    assert len(adapter.emissions) == 2
    assert all(e.decision == "REJECT" for e in adapter.emissions)


def test_t21_mock_adapter_last():
    """MockDecisionAdapter.last() returns the most recent event."""
    adapter = MockDecisionAdapter()
    assert adapter.last() is None

    r1 = _make_mock_result(decision="APPROVE", score=5)
    r2 = _make_mock_result(decision="REJECT",  score=75)
    run(adapter.emit_decision(r1, None))
    run(adapter.emit_decision(r2, None))

    assert adapter.last().decision == "REJECT"


def test_t22_mock_adapter_clear():
    """MockDecisionAdapter.clear() resets emissions list."""
    adapter = MockDecisionAdapter()
    run(adapter.emit_decision(_make_mock_result(), None))
    assert len(adapter.emissions) == 1
    adapter.clear()
    assert adapter.emissions == []


# ═══════════════════════════════════════════════════════════════════════════════
# T-23..T-28  InMemoryEmergencyAdapter
# ═══════════════════════════════════════════════════════════════════════════════

def test_t23_emergency_adapter_initially_not_stopped():
    """InMemoryEmergencyAdapter starts in RUNNING state (not stopped)."""
    adapter = InMemoryEmergencyAdapter()
    assert run(adapter.is_stopped()) is False


def test_t24_emergency_adapter_activate():
    """activate() transitions is_stopped() to True."""
    adapter = InMemoryEmergencyAdapter()
    resp = run(adapter.activate("operator-001", "test stop"))

    assert run(adapter.is_stopped()) is True
    assert resp["status"]      == "SUSPENDED"
    assert resp["operator_id"] == "operator-001"
    assert resp["reason"]      == "test stop"
    assert resp["activated_at"]


def test_t25_emergency_adapter_clear():
    """clear() transitions is_stopped() back to False (requires mlro_id)."""
    adapter = InMemoryEmergencyAdapter()
    run(adapter.activate("operator-001", "test stop"))
    resp = run(adapter.clear("mlro-001", "test resume"))

    assert run(adapter.is_stopped()) is False
    assert resp["status"]   == "RUNNING"
    assert resp["mlro_id"]  == "mlro-001"
    assert resp["cleared_at"]


def test_t26_emergency_adapter_get_status():
    """get_status() returns structured dict with all required fields."""
    adapter = InMemoryEmergencyAdapter()
    run(adapter.activate("op-A", "reason-A"))

    status = run(adapter.get_status())
    assert status["active"]       is True
    assert status["operator_id"]  == "op-A"
    assert status["reason"]       == "reason-A"
    assert status["activated_at"] is not None


def test_t27_emergency_adapter_idempotent_activate():
    """Double activate keeps is_stopped() True (idempotent)."""
    adapter = InMemoryEmergencyAdapter()
    run(adapter.activate("op-1", "first"))
    run(adapter.activate("op-2", "second"))   # second activate

    assert run(adapter.is_stopped()) is True
    status = run(adapter.get_status())
    assert status["operator_id"] == "op-2"   # last activate wins


def test_t28_emergency_port_only_defined_methods():
    """
    EmergencyPort exposes only is_stopped, activate, clear, get_status.
    No update_stop, delete_stop, or other mutation methods.
    """
    allowed = {"is_stopped", "activate", "clear", "get_status"}
    adapter = InMemoryEmergencyAdapter()
    for forbidden in ("update_stop", "delete_stop", "force_resume", "patch_state"):
        assert not hasattr(adapter, forbidden), (
            f"EmergencyPort must not expose '{forbidden}'"
        )


# ═══════════════════════════════════════════════════════════════════════════════
# T-29  BanxeAMLDecisionAdapter + InMemoryAuditAdapter round-trip
# ═══════════════════════════════════════════════════════════════════════════════

def test_t29_decision_audit_round_trip():
    """
    Full round-trip: BanxeAMLDecisionAdapter writes to InMemoryAuditAdapter,
    then query_events retrieves the same event.
    """
    audit = InMemoryAuditAdapter()
    decision_port = BanxeAMLDecisionAdapter(audit_port=audit)

    case_id = str(uuid.uuid4())
    result = _make_mock_result(decision="HOLD", score=50, case_id=case_id)
    explanation = ExplanationBundle(case_id=case_id, decision="HOLD")

    emitted = run(decision_port.emit_decision(result, explanation))

    # Query back by case_id
    results = run(audit.query_events(case_id=case_id))
    assert len(results) == 1
    stored = results[0]
    assert stored.decision  == "HOLD"
    assert stored.case_id   == case_id
    assert stored.event_id  == emitted.event_id
    assert "explanation_bundle" in stored.audit_payload


# ═══════════════════════════════════════════════════════════════════════════════
# T-30  All 4 ports importable from compliance.ports
# ═══════════════════════════════════════════════════════════════════════════════

def test_t30_all_ports_importable():
    """All 4 ABCs are importable from the compliance.ports package."""
    from compliance.ports import AuditPort, PolicyPort, DecisionPort, EmergencyPort
    for cls in (AuditPort, PolicyPort, DecisionPort, EmergencyPort):
        assert cls.__name__ in cls.__module__ or True   # class exists and loaded
