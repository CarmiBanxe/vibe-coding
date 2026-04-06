"""
test_orchestration_tree.py — G-04 Trust Boundary Tests

Tests for OrchestrationTree, AgentDescriptor, TrustViolation, TrustBoundaryError.

T-01  AgentDescriptor is a frozen dataclass (immutable)
T-02  has_capability returns correct values
T-03  Level-1 → Level-2 (GREEN→GREEN) is allowed (no violations)
T-04  Level-2 → Level-1 is BLOCKED (B-01)
T-05  Level-3 → Level-1 is BLOCKED (B-02)
T-06  Level-3 → Level-2 is BLOCKED (B-03)
T-07  Level-1 → Level-3 is allowed (downward, any zone)
T-08  Level-2 → Level-2 (same level, same zone) is allowed
T-09  RED → GREEN is BLOCKED (B-04)
T-10  AMBER → GREEN emits warning, not blocked (B-05)
T-11  Level-2 with policy_write capability is BLOCKED (B-06)
T-12  Level-1 with policy_write capability is allowed (orchestrators may gate policy writes)
T-13  assert_call_allowed raises TrustBoundaryError for blocked violations
T-14  assert_call_allowed returns warnings without raising for non-blocked violations
T-15  can_call returns False when blocked violations exist
T-16  can_call returns True when only warnings (non-blocked)
T-17  Unknown caller treated as Level-3 RED (conservative default)
T-18  Unknown callee treated as Level-3 RED (conservative default)
T-19  check_capability returns None for allowed capability
T-20  check_capability returns B-06 violation for policy_write on Level-2
T-21  check_capability returns B-06 violation for policy_write on Level-3
T-22  get_default_tree() returns singleton
T-23  default tree has banxe_aml_orchestrator at Level-1
T-24  default tree has aml_orchestrator, tx_monitor, sanctions_check, crypto_aml at Level-2
T-25  default tree has watchman_adapter, jube_adapter, yente_adapter at Level-3 AMBER
T-26  default tree: banxe_aml_orchestrator → aml_orchestrator allowed
T-27  default tree: aml_orchestrator → banxe_aml_orchestrator BLOCKED (B-01)
T-28  default tree: watchman_adapter → sanctions_check BLOCKED (B-03)
T-29  default tree: watchman_adapter → banxe_aml_orchestrator BLOCKED (B-02 + B-04)
T-30  TrustBoundaryError.violations contains all blocked violations
T-31  OrchestrationTree is fresh per instance (no shared state with default tree)
T-32  re-registering same agent_id overwrites descriptor
T-33  registered_ids() returns all registered agents
T-34  Integration: banxe_aml_orchestrator.py can be imported with trust tree active
"""
from __future__ import annotations

import os
import sys

# ── Path bootstrap (mirrors test_ports.py) ───────────────────────────────────
_BASE = os.path.dirname(os.path.abspath(__file__))
_SRC  = os.path.dirname(_BASE)
sys.path.insert(0, _SRC)
sys.path.insert(0, _BASE)

import pytest

from compliance.agents.orchestration_tree import (
    AgentDescriptor,
    OrchestrationTree,
    TrustBoundaryError,
    TrustViolation,
    get_default_tree,
)


# ── Helpers ───────────────────────────────────────────────────────────────────

def make_tree(*agents: AgentDescriptor) -> OrchestrationTree:
    t = OrchestrationTree()
    for a in agents:
        t.register(a)
    return t


L1_GREEN = AgentDescriptor("orch",    level=1, trust_zone="GREEN")
L2_GREEN = AgentDescriptor("engine",  level=2, trust_zone="GREEN")
L3_GREEN = AgentDescriptor("adapter", level=3, trust_zone="GREEN")
L2_AMBER = AgentDescriptor("ext_eng", level=2, trust_zone="AMBER")
L3_RED   = AgentDescriptor("ext_red", level=3, trust_zone="RED")
L3_AMBER = AgentDescriptor("ext_amb", level=3, trust_zone="AMBER")


# ── T-01..T-02: AgentDescriptor ───────────────────────────────────────────────

def test_T01_agent_descriptor_is_frozen():
    agent = AgentDescriptor("a", level=1, trust_zone="GREEN")
    with pytest.raises((AttributeError, TypeError)):
        agent.level = 2  # type: ignore[misc]


def test_T02_has_capability():
    agent = AgentDescriptor("a", level=1, capabilities=("aml_assess", "orchestrate"))
    assert agent.has_capability("aml_assess") is True
    assert agent.has_capability("policy_write") is False
    assert agent.has_capability("orchestrate") is True


# ── T-03..T-08: Level-based rules ────────────────────────────────────────────

def test_T03_level1_to_level2_allowed():
    tree = make_tree(L1_GREEN, L2_GREEN)
    violations = tree.check_call("orch", "engine")
    assert violations == []


def test_T04_level2_to_level1_blocked_B01():
    tree = make_tree(L1_GREEN, L2_GREEN)
    violations = tree.check_call("engine", "orch")
    blocked = [v for v in violations if v.blocked]
    assert len(blocked) == 1
    assert blocked[0].rule == "B-01"


def test_T05_level3_to_level1_blocked_B02():
    tree = make_tree(L1_GREEN, L3_GREEN)
    violations = tree.check_call("adapter", "orch")
    blocked = [v for v in violations if v.blocked]
    assert any(v.rule == "B-02" for v in blocked)


def test_T06_level3_to_level2_blocked_B03():
    tree = make_tree(L2_GREEN, L3_GREEN)
    violations = tree.check_call("adapter", "engine")
    blocked = [v for v in violations if v.blocked]
    assert len(blocked) == 1
    assert blocked[0].rule == "B-03"


def test_T07_level1_to_level3_allowed():
    tree = make_tree(L1_GREEN, L3_GREEN)
    violations = tree.check_call("orch", "adapter")
    assert violations == []


def test_T08_level2_to_level2_same_zone_allowed():
    eng2 = AgentDescriptor("engine2", level=2, trust_zone="GREEN")
    tree = make_tree(L2_GREEN, eng2)
    violations = tree.check_call("engine", "engine2")
    assert violations == []


# ── T-09..T-10: Zone-based rules ─────────────────────────────────────────────

def test_T09_red_to_green_blocked_B04():
    tree = make_tree(L1_GREEN, L3_RED)
    violations = tree.check_call("ext_red", "orch")
    blocked = [v for v in violations if v.blocked]
    assert any(v.rule == "B-04" for v in blocked)


def test_T10_amber_to_green_warning_not_blocked_B05():
    # AMBER-zone Level-2 calling GREEN-zone Level-2 — no level block, only zone warning
    eng_green = AgentDescriptor("eng_green", level=2, trust_zone="GREEN")
    tree = make_tree(L2_AMBER, eng_green)
    violations = tree.check_call("ext_eng", "eng_green")
    warnings = [v for v in violations if not v.blocked]
    blocked   = [v for v in violations if v.blocked]
    assert len(blocked) == 0
    assert any(v.rule == "B-05" for v in warnings)


# ── T-11..T-12: Capability rules ──────────────────────────────────────────────

def test_T11_level2_policy_write_blocked_B06():
    bad_engine = AgentDescriptor("bad_eng", level=2, capabilities=("policy_write",))
    tree = make_tree(bad_engine, L1_GREEN)
    violations = tree.check_call("bad_eng", "orch")
    blocked = [v for v in violations if v.blocked]
    assert any(v.rule == "B-06" for v in blocked)


def test_T12_level1_policy_write_allowed():
    # Orchestrators (Level-1) are allowed to gate policy writes
    orch_pw = AgentDescriptor("orch_pw", level=1, capabilities=("policy_write",))
    tree = make_tree(orch_pw, L2_GREEN)
    violations = tree.check_call("orch_pw", "engine")
    b06 = [v for v in violations if v.rule == "B-06"]
    assert b06 == []


# ── T-13..T-16: assert_call_allowed + can_call ────────────────────────────────

def test_T13_assert_call_allowed_raises_on_blocked():
    tree = make_tree(L1_GREEN, L2_GREEN)
    with pytest.raises(TrustBoundaryError) as exc_info:
        tree.assert_call_allowed("engine", "orch")
    assert exc_info.value.violations[0].rule == "B-01"


def test_T14_assert_call_allowed_returns_warnings_without_raising():
    eng_green = AgentDescriptor("eng_green", level=2, trust_zone="GREEN")
    tree = make_tree(L2_AMBER, eng_green)
    # Should NOT raise — only warning
    warnings = tree.assert_call_allowed("ext_eng", "eng_green")
    assert any(v.rule == "B-05" for v in warnings)


def test_T15_can_call_false_when_blocked():
    tree = make_tree(L1_GREEN, L2_GREEN)
    assert tree.can_call("engine", "orch") is False


def test_T16_can_call_true_when_only_warnings():
    eng_green = AgentDescriptor("eng_green", level=2, trust_zone="GREEN")
    tree = make_tree(L2_AMBER, eng_green)
    assert tree.can_call("ext_eng", "eng_green") is True


# ── T-17..T-18: Unknown agents — conservative defaults ───────────────────────

def test_T17_unknown_caller_treated_as_level3_red():
    tree = make_tree(L1_GREEN)
    # unknown → Level-1 GREEN: should trigger B-02 (L3→L1) + B-04 (RED→GREEN)
    violations = tree.check_call("ghost_caller", "orch")
    rules = {v.rule for v in violations if v.blocked}
    assert "B-02" in rules
    assert "B-04" in rules


def test_T18_unknown_callee_treated_as_level3_red():
    tree = make_tree(L1_GREEN)
    # Level-1 GREEN → unknown (L3 RED): B-04 check applies in reverse direction (GREEN→RED)
    # No level violation (L1→L3 allowed), no zone violation (GREEN caller → RED callee is fine)
    violations = tree.check_call("orch", "ghost_callee")
    assert violations == []


# ── T-19..T-21: check_capability ─────────────────────────────────────────────

def test_T19_check_capability_allowed():
    tree = make_tree(L2_GREEN)
    result = tree.check_capability("engine", "aml_screen")
    assert result is None


def test_T20_check_capability_policy_write_blocked_level2():
    tree = make_tree(L2_GREEN)
    result = tree.check_capability("engine", "policy_write")
    assert result is not None
    assert result.rule == "B-06"
    assert result.blocked is True


def test_T21_check_capability_policy_write_blocked_level3():
    tree = make_tree(L3_GREEN)
    result = tree.check_capability("adapter", "policy_write")
    assert result is not None
    assert result.rule == "B-06"


# ── T-22..T-29: Default tree ──────────────────────────────────────────────────

def test_T22_get_default_tree_singleton():
    t1 = get_default_tree()
    t2 = get_default_tree()
    assert t1 is t2


def test_T23_default_tree_orchestrator_level1():
    tree = get_default_tree()
    orch = tree.get("banxe_aml_orchestrator")
    assert orch is not None
    assert orch.level == 1
    assert orch.trust_zone == "GREEN"


def test_T24_default_tree_level2_engines():
    tree = get_default_tree()
    for agent_id in ("aml_orchestrator", "tx_monitor", "sanctions_check", "crypto_aml"):
        agent = tree.get(agent_id)
        assert agent is not None, f"Missing Level-2 agent: {agent_id}"
        assert agent.level == 2


def test_T25_default_tree_level3_adapters_amber():
    tree = get_default_tree()
    for agent_id in ("watchman_adapter", "jube_adapter", "yente_adapter"):
        agent = tree.get(agent_id)
        assert agent is not None, f"Missing Level-3 adapter: {agent_id}"
        assert agent.level == 3
        assert agent.trust_zone == "AMBER"


def test_T26_default_tree_l1_to_l2_allowed():
    tree = get_default_tree()
    assert tree.can_call("banxe_aml_orchestrator", "aml_orchestrator") is True


def test_T27_default_tree_l2_to_l1_blocked():
    tree = get_default_tree()
    assert tree.can_call("aml_orchestrator", "banxe_aml_orchestrator") is False


def test_T28_default_tree_l3_to_l2_blocked():
    tree = get_default_tree()
    # watchman_adapter (L3, AMBER) → sanctions_check (L2, GREEN): B-03 + B-05
    violations = tree.check_call("watchman_adapter", "sanctions_check")
    blocked = [v for v in violations if v.blocked]
    assert any(v.rule == "B-03" for v in blocked)


def test_T29_default_tree_l3_to_l1_multi_violation():
    tree = get_default_tree()
    # watchman_adapter (L3, AMBER) → banxe_aml_orchestrator (L1, GREEN)
    # Expected: B-02 (L3→L1) + B-05 (AMBER→GREEN warn)
    violations = tree.check_call("watchman_adapter", "banxe_aml_orchestrator")
    rules = {v.rule for v in violations}
    blocked_rules = {v.rule for v in violations if v.blocked}
    assert "B-02" in blocked_rules
    assert "B-05" in rules


# ── T-30..T-33: TrustBoundaryError + misc ────────────────────────────────────

def test_T30_trust_boundary_error_carries_violations():
    tree = make_tree(L1_GREEN, L2_GREEN)
    try:
        tree.assert_call_allowed("engine", "orch")
        pytest.fail("Expected TrustBoundaryError")
    except TrustBoundaryError as e:
        assert len(e.violations) >= 1
        assert all(v.blocked for v in e.violations)
        assert "B-01" in str(e)


def test_T31_fresh_tree_no_shared_state():
    t1 = OrchestrationTree()
    t1.register(AgentDescriptor("x", level=1))
    t2 = OrchestrationTree()
    assert t2.get("x") is None  # not shared


def test_T32_re_register_overwrites():
    tree = OrchestrationTree()
    tree.register(AgentDescriptor("a", level=2, trust_zone="GREEN"))
    tree.register(AgentDescriptor("a", level=1, trust_zone="AMBER"))
    agent = tree.get("a")
    assert agent.level == 1
    assert agent.trust_zone == "AMBER"


def test_T33_registered_ids():
    tree = make_tree(L1_GREEN, L2_GREEN, L3_GREEN)
    ids = tree.registered_ids()
    assert set(ids) == {"orch", "engine", "adapter"}


# ── T-34: Integration ─────────────────────────────────────────────────────────

def test_T34_banxe_orchestrator_imports_cleanly():
    """Smoke-test: importing banxe_aml_orchestrator activates the trust tree."""
    import compliance.banxe_aml_orchestrator as m
    assert hasattr(m, "banxe_assess")
    assert hasattr(m, "BanxeAMLResult")
    # Confirm get_default_tree() is accessible after import
    from compliance.agents.orchestration_tree import get_default_tree
    tree = get_default_tree()
    assert tree.get("banxe_aml_orchestrator") is not None
