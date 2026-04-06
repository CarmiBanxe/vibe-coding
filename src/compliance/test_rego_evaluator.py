#!/usr/bin/env python3
"""
test_rego_evaluator.py — Unit tests for G-19 Rego Evaluator.

Tests:
  T-01  evaluate() returns [] for valid compliant input (allow=True)
  T-02  I-22: Level 2 write to policy layer → BLOCKED violation
  T-03  I-22: Level 0 (MLRO) write to policy layer → allowed
  T-04  I-22: Level 1 write to non-policy path → allowed
  T-05  I-21: Level 2 write to SOUL.md → BLOCKED violation
  T-06  I-21: Level 3 write to AGENTS.md → BLOCKED violation
  T-07  I-21: Level 1 (Orchestrator) write to SOUL.md → allowed
  T-08  I-21: Level 3 git_push to developer-core → BLOCKED violation
  T-09  I-21: Level 3 git_push to vibe-coding → allowed
  T-10  I-23: Transaction action without emergency_stop_checked → BLOCKED
  T-11  I-23: Transaction action with emergency_stop_checked=True → allowed
  T-12  I-23: Non-transaction action without emergency_stop_checked → allowed
  T-13  I-25: Decision > £10k without explanation_bundle_present → BLOCKED
  T-14  I-25: Decision > £10k with explanation_bundle_present=True → allowed
  T-15  I-25: Decision <= £10k without explanation_bundle_present → allowed
  T-16  GOVERNANCE: submit_sar without mlro_approved → BLOCKED
  T-17  GOVERNANCE: submit_sar with mlro_approved=True → allowed
  T-18  Multiple violations in one evaluate() call
  T-19  PolicyViolation fields: invariant, rule, message, severity, blocked
  T-20  is_allowed() = True when evaluate() is empty
  T-21  is_allowed() = False when violations present
  T-22  evaluate_dict() accepts plain dict
  T-23  input_from_banxe_result() builds correct PolicyInput
  T-24  banxe_assess() integrates rego_evaluator (no violations on valid flow)
  T-25  banxe_assess() raises RuntimeError on I-25 violation

Invariant coverage:
  I-21 (T-05, T-06, T-07, T-08, T-09)
  I-22 (T-02, T-03, T-04)
  I-23 (T-10, T-11, T-12)
  I-25 (T-13, T-14, T-15, T-25)
"""
from __future__ import annotations

import asyncio
import sys
import os
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

BASE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.dirname(BASE)
sys.path.insert(0, SRC)
sys.path.insert(0, BASE)

from compliance.utils.rego_evaluator import (
    PolicyInput,
    PolicyViolation,
    evaluate,
    evaluate_dict,
    is_allowed,
    input_from_banxe_result,
)


def run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


# ── Helpers ───────────────────────────────────────────────────────────────────

def _inp(**kwargs) -> PolicyInput:
    """Build a PolicyInput with safe defaults + overrides."""
    defaults = dict(
        agent_level               = 1,
        agent_id                  = "test_agent",
        action                    = "approve_transaction",
        target_path               = "",
        target_repo               = "",
        mlro_approved             = False,
        amount_gbp                = 500.0,
        explanation_bundle_present = True,
        emergency_stop_checked    = True,
        decision                  = "APPROVE",
    )
    defaults.update(kwargs)
    return PolicyInput(**defaults)


# ═══════════════════════════════════════════════════════════════════════════════
# T-01  Valid compliant input → allow
# ═══════════════════════════════════════════════════════════════════════════════

def test_t01_valid_input_no_violations():
    """Compliant input with all fields satisfied → evaluate() returns []."""
    inp = _inp()
    assert evaluate(inp) == []
    assert is_allowed(inp) is True


# ═══════════════════════════════════════════════════════════════════════════════
# T-02  I-22: Level 2 write to policy layer → BLOCKED
# ═══════════════════════════════════════════════════════════════════════════════

def test_t02_i22_l2_policy_layer_write():
    """I-22: Level 2 agent writing to developer-core/compliance/ is BLOCKED."""
    inp = _inp(
        agent_level = 2,
        action      = "write_file",
        target_path = "developer-core/compliance/validator.py",
    )
    violations = evaluate(inp)
    assert len(violations) == 1
    v = violations[0]
    assert v.invariant == "I-22"
    assert v.blocked is True
    assert "I-22" in v.message
    assert "level 2" in v.message.lower()


# ═══════════════════════════════════════════════════════════════════════════════
# T-03  I-22: Level 0 (MLRO) write → allowed
# ═══════════════════════════════════════════════════════════════════════════════

def test_t03_i22_mlro_write_allowed():
    """I-22 does not fire for Level 0 (MLRO has unrestricted access)."""
    inp = _inp(
        agent_level = 0,
        action      = "write_file",
        target_path = "developer-core/compliance/validator.py",
    )
    assert evaluate(inp) == []


# ═══════════════════════════════════════════════════════════════════════════════
# T-04  I-22: Write to non-policy path → allowed
# ═══════════════════════════════════════════════════════════════════════════════

def test_t04_i22_non_policy_path_allowed():
    """I-22 does not fire for writes to non-policy paths."""
    inp = _inp(
        agent_level = 2,
        action      = "write_file",
        target_path = "src/compliance/utils/my_helper.py",  # NOT a policy path
    )
    assert evaluate(inp) == []


# ═══════════════════════════════════════════════════════════════════════════════
# T-05  I-21: Level 2 write to SOUL.md → BLOCKED
# ═══════════════════════════════════════════════════════════════════════════════

def test_t05_i21_l2_soul_write():
    """I-21: Level 2 agent cannot write to SOUL.md."""
    inp = _inp(
        agent_level = 2,
        action      = "write_file",
        target_path = "/root/.openclaw-moa/workspace/SOUL.md",
    )
    violations = evaluate(inp)
    assert any(v.invariant == "I-21" for v in violations)
    v21 = next(v for v in violations if v.invariant == "I-21")
    assert v21.blocked is True
    assert "SOUL.md" in v21.message


# ═══════════════════════════════════════════════════════════════════════════════
# T-06  I-21: Level 3 write to AGENTS.md → BLOCKED
# ═══════════════════════════════════════════════════════════════════════════════

def test_t06_i21_feedback_agents_write():
    """I-21: Feedback Agent (level 3) cannot write to AGENTS.md."""
    inp = _inp(
        agent_level = 3,
        action      = "write_file",
        target_path = "workspace/AGENTS.md",
    )
    violations = evaluate(inp)
    assert any(v.invariant == "I-21" for v in violations)


# ═══════════════════════════════════════════════════════════════════════════════
# T-07  I-21: Level 1 (Orchestrator) write to SOUL.md → allowed
# ═══════════════════════════════════════════════════════════════════════════════

def test_t07_i21_orchestrator_soul_allowed():
    """I-21 only fires for level 2/3. Level 1 is not restricted by this rule."""
    inp = _inp(
        agent_level = 1,
        action      = "write_file",
        target_path = "/some/path/SOUL.md",
    )
    i21_violations = [v for v in evaluate(inp) if v.invariant == "I-21"]
    assert i21_violations == []


# ═══════════════════════════════════════════════════════════════════════════════
# T-08  I-21: Level 3 git_push to developer-core → BLOCKED
# ═══════════════════════════════════════════════════════════════════════════════

def test_t08_i21_feedback_push_devcore():
    """I-21: Feedback Agent cannot git_push to developer-core repo."""
    inp = _inp(
        agent_level = 3,
        action      = "git_push",
        target_repo = "CarmiBanxe/developer-core",
    )
    violations = evaluate(inp)
    assert any(v.invariant == "I-21" and "DEVCORE" in v.rule for v in violations)


# ═══════════════════════════════════════════════════════════════════════════════
# T-09  I-21: Level 3 git_push to vibe-coding → allowed
# ═══════════════════════════════════════════════════════════════════════════════

def test_t09_i21_feedback_push_vibe_allowed():
    """I-21 push rule does not fire for non-developer-core repos."""
    inp = _inp(
        agent_level = 3,
        action      = "git_push",
        target_repo = "CarmiBanxe/vibe-coding",
    )
    i21_violations = [v for v in evaluate(inp) if v.invariant == "I-21"]
    assert i21_violations == []


# ═══════════════════════════════════════════════════════════════════════════════
# T-10  I-23: Transaction without emergency_stop_checked → BLOCKED
# ═══════════════════════════════════════════════════════════════════════════════

def test_t10_i23_no_emergency_stop_check():
    """I-23: Any transaction action without emergency_stop_checked=True is BLOCKED."""
    for action in ("approve_transaction", "hold_transaction", "reject_transaction", "file_sar"):
        inp = _inp(action=action, emergency_stop_checked=False)
        violations = evaluate(inp)
        i23 = [v for v in violations if v.invariant == "I-23"]
        assert i23, f"I-23 should fire for action={action}"
        assert i23[0].blocked is True


# ═══════════════════════════════════════════════════════════════════════════════
# T-11  I-23: Transaction with emergency_stop_checked=True → allowed
# ═══════════════════════════════════════════════════════════════════════════════

def test_t11_i23_stop_checked_allowed():
    """I-23 does not fire when emergency_stop_checked=True."""
    inp = _inp(
        action                 = "reject_transaction",
        emergency_stop_checked = True,
    )
    i23_violations = [v for v in evaluate(inp) if v.invariant == "I-23"]
    assert i23_violations == []


# ═══════════════════════════════════════════════════════════════════════════════
# T-12  I-23: Non-transaction action → I-23 does not fire
# ═══════════════════════════════════════════════════════════════════════════════

def test_t12_i23_non_tx_action_not_fired():
    """I-23 only fires for transaction actions, not for write_file etc."""
    inp = _inp(
        action                 = "write_file",
        target_path            = "/tmp/some_output.json",
        emergency_stop_checked = False,   # would fire for tx actions, not for write_file
        agent_level            = 2,
    )
    i23_violations = [v for v in evaluate(inp) if v.invariant == "I-23"]
    assert i23_violations == []


# ═══════════════════════════════════════════════════════════════════════════════
# T-13  I-25: Decision > £10k without explanation_bundle → BLOCKED
# ═══════════════════════════════════════════════════════════════════════════════

def test_t13_i25_no_explanation_high_value():
    """I-25: Transaction > £10,000 without ExplanationBundle is BLOCKED."""
    inp = _inp(
        action                    = "hold_transaction",
        amount_gbp                = 15_000.0,
        explanation_bundle_present = False,
    )
    violations = evaluate(inp)
    i25 = [v for v in violations if v.invariant == "I-25"]
    assert i25, "I-25 should fire for £15,000 without explanation bundle"
    assert i25[0].blocked is True
    assert "£15,000" in i25[0].message


# ═══════════════════════════════════════════════════════════════════════════════
# T-14  I-25: Decision > £10k WITH explanation_bundle → allowed
# ═══════════════════════════════════════════════════════════════════════════════

def test_t14_i25_with_explanation_allowed():
    """I-25 does not fire when explanation_bundle_present=True."""
    inp = _inp(
        action                    = "reject_transaction",
        amount_gbp                = 50_000.0,
        explanation_bundle_present = True,
    )
    i25_violations = [v for v in evaluate(inp) if v.invariant == "I-25"]
    assert i25_violations == []


# ═══════════════════════════════════════════════════════════════════════════════
# T-15  I-25: Decision <= £10k without explanation_bundle → allowed
# ═══════════════════════════════════════════════════════════════════════════════

def test_t15_i25_low_value_no_explanation_allowed():
    """I-25 does not fire for transactions at or below £10,000."""
    inp = _inp(
        action                    = "approve_transaction",
        amount_gbp                = 500.0,
        explanation_bundle_present = False,
    )
    i25_violations = [v for v in evaluate(inp) if v.invariant == "I-25"]
    assert i25_violations == []


# ═══════════════════════════════════════════════════════════════════════════════
# T-16  GOVERNANCE: submit_sar without mlro_approved → BLOCKED
# ═══════════════════════════════════════════════════════════════════════════════

def test_t16_governance_sar_submit_no_mlro():
    """SAR NCA submission without mlro_approved is BLOCKED."""
    inp = _inp(action="submit_sar", mlro_approved=False)
    violations = evaluate(inp)
    gov = [v for v in violations if v.invariant == "GOVERNANCE"]
    assert gov, "GOVERNANCE rule must fire for submit_sar without mlro_approved"
    assert gov[0].blocked is True


# ═══════════════════════════════════════════════════════════════════════════════
# T-17  GOVERNANCE: submit_sar with mlro_approved=True → allowed
# ═══════════════════════════════════════════════════════════════════════════════

def test_t17_governance_sar_submit_with_mlro_allowed():
    """SAR NCA submission with mlro_approved=True is allowed."""
    inp = _inp(action="submit_sar", mlro_approved=True)
    gov_violations = [v for v in evaluate(inp) if v.invariant == "GOVERNANCE"]
    assert gov_violations == []


# ═══════════════════════════════════════════════════════════════════════════════
# T-18  Multiple violations in one call
# ═══════════════════════════════════════════════════════════════════════════════

def test_t18_multiple_violations():
    """evaluate() can return multiple violations if multiple rules fire."""
    # I-23 + I-25 both fire: no stop check + no explanation on high-value tx
    inp = _inp(
        action                    = "reject_transaction",
        amount_gbp                = 20_000.0,
        explanation_bundle_present = False,
        emergency_stop_checked    = False,
    )
    violations = evaluate(inp)
    invariants = {v.invariant for v in violations}
    assert "I-23" in invariants
    assert "I-25" in invariants
    assert len(violations) >= 2


# ═══════════════════════════════════════════════════════════════════════════════
# T-19  PolicyViolation fields
# ═══════════════════════════════════════════════════════════════════════════════

def test_t19_policy_violation_fields():
    """PolicyViolation has invariant, rule, message, severity, blocked."""
    inp = _inp(
        agent_level            = 2,
        action                 = "write_file",
        target_path            = "developer-core/compliance/foo.py",
    )
    violations = evaluate(inp)
    assert violations
    v = violations[0]
    assert isinstance(v.invariant, str) and v.invariant
    assert isinstance(v.rule,      str) and v.rule
    assert isinstance(v.message,   str) and v.message
    assert v.severity in ("CRITICAL", "ERROR", "WARNING")
    assert isinstance(v.blocked, bool)


# ═══════════════════════════════════════════════════════════════════════════════
# T-20  is_allowed() = True when no violations
# ═══════════════════════════════════════════════════════════════════════════════

def test_t20_is_allowed_true():
    """is_allowed() returns True when evaluate() returns []."""
    assert is_allowed(_inp()) is True


# ═══════════════════════════════════════════════════════════════════════════════
# T-21  is_allowed() = False when violations present
# ═══════════════════════════════════════════════════════════════════════════════

def test_t21_is_allowed_false():
    """is_allowed() returns False when evaluate() returns violations."""
    inp = _inp(
        agent_level            = 2,
        action                 = "write_file",
        target_path            = "developer-core/compliance/foo.py",
    )
    assert is_allowed(inp) is False


# ═══════════════════════════════════════════════════════════════════════════════
# T-22  evaluate_dict() accepts plain dict
# ═══════════════════════════════════════════════════════════════════════════════

def test_t22_evaluate_dict():
    """evaluate_dict() accepts a plain dict and returns same result as evaluate()."""
    d = {
        "agent_level":               2,
        "agent_id":                  "test",
        "action":                    "write_file",
        "target_path":               "developer-core/compliance/x.py",
        "emergency_stop_checked":    True,
        "explanation_bundle_present": True,
    }
    violations = evaluate_dict(d)
    assert any(v.invariant == "I-22" for v in violations)


# ═══════════════════════════════════════════════════════════════════════════════
# T-23  input_from_banxe_result() builds correct PolicyInput
# ═══════════════════════════════════════════════════════════════════════════════

def test_t23_input_from_banxe_result():
    """input_from_banxe_result() maps BanxeAMLResult fields to PolicyInput."""
    from compliance.utils.explanation_builder import ExplanationBundle

    result = MagicMock()
    result.decision    = "HOLD"
    result.explanation = ExplanationBundle()   # non-None

    inp = input_from_banxe_result(
        result,
        amount_gbp             = 25_000.0,
        emergency_stop_checked = True,
        agent_id               = "banxe_aml_orchestrator",
    )
    assert inp.action                    == "hold_transaction"
    assert inp.amount_gbp                == 25_000.0
    assert inp.explanation_bundle_present is True
    assert inp.emergency_stop_checked    is True
    assert inp.agent_id                  == "banxe_aml_orchestrator"
    assert inp.agent_level               == 1


# ═══════════════════════════════════════════════════════════════════════════════
# T-24  banxe_assess() integration — no violations on valid flow
# ═══════════════════════════════════════════════════════════════════════════════

def test_t24_banxe_assess_no_policy_violations():
    """
    banxe_assess() with a standard transaction must not trigger any policy violations.
    The rego_evaluator fires after result is built; with explanation present and
    emergency_stop_checked=True, all invariants are satisfied.
    """
    from compliance.models import AMLResult, TransactionInput, CustomerProfile

    mock_layer2 = AMLResult(
        decision="APPROVE",
        score=10,
        signals=[],
        requires_edd=False,
        requires_mlro_review=False,
    )

    with patch("compliance.banxe_aml_orchestrator._layer2_assess",
               new=AsyncMock(return_value=mock_layer2)):
        import compliance.banxe_aml_orchestrator as orch
        # No RuntimeError should be raised
        result = run(orch.banxe_assess(
            transaction=TransactionInput("GB", "DE", 500.0),
            customer=CustomerProfile("CUST-001"),
        ))

    assert result.decision == "APPROVE"
    assert result.explanation is not None


# ═══════════════════════════════════════════════════════════════════════════════
# T-25  banxe_assess() raises on I-25 violation (code bug)
# ═══════════════════════════════════════════════════════════════════════════════

def test_t25_banxe_assess_raises_on_i25_violation():
    """
    If explanation is None on a high-value transaction, banxe_assess() raises RuntimeError.
    This tests the I-25 fail-closed contract — missing explanation = code bug.
    """
    from compliance.models import AMLResult, TransactionInput, CustomerProfile

    mock_layer2 = AMLResult(
        decision="HOLD",
        score=50,
        signals=[],
        requires_edd=True,
        requires_mlro_review=False,
    )

    with patch("compliance.banxe_aml_orchestrator._layer2_assess",
               new=AsyncMock(return_value=mock_layer2)):
        with patch("compliance.banxe_aml_orchestrator.ExplanationBundle") as mock_eb:
            # Make the ExplanationBundle factory return None (simulates builder failure)
            mock_eb.from_banxe_result.return_value = None

            import compliance.banxe_aml_orchestrator as orch

            with pytest.raises(RuntimeError, match="I-25 VIOLATION"):
                run(orch.banxe_assess(
                    transaction=TransactionInput("GB", "DE", 15_000.0),
                    customer=CustomerProfile("CUST-I25"),
                ))
