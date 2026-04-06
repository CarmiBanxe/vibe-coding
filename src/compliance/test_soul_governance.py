"""
test_soul_governance.py — G-05 Governance Gate Tests

Tests for change_classes.yaml + GovernanceGate + GovernanceError.

T-01  change_classes.yaml loads without error
T-02  CLASS_A, B, C sections all present with required keys
T-03  SOUL.md classifies as CLASS_B
T-04  openclaw.json classifies as CLASS_B
T-05  compliance_config.yaml classifies as CLASS_C
T-06  banxe_compliance.rego classifies as CLASS_C
T-07  AGENTS.md classifies as CLASS_A
T-08  compliance_validator.py classifies as CLASS_A
T-09  Unknown file defaults to CLASS_B (fail-safe)
T-10  CLASS_A change is auto-approved without approver
T-11  CLASS_A decision has approver_id="auto"
T-12  CLASS_B without approver → GovernanceError raised
T-13  GovernanceError carries correct target_file and change_class
T-14  GovernanceError carries required_roles list
T-15  CLASS_B with valid approver + role → APPROVED
T-16  CLASS_B decision recorded in governance log
T-17  CLASS_B with wrong role → GovernanceError (REJECTED)
T-18  CLASS_C without approver → GovernanceError
T-19  CLASS_C with DEVELOPER role (not in C roles) → GovernanceError
T-20  CLASS_C with MLRO role → APPROVED
T-21  CLASS_C with CEO role → APPROVED
T-22  GovernanceDecision.to_dict() returns serialisable dict
T-23  GovernanceDecision.to_json() is valid JSON
T-24  Governance log is append-only (multiple decisions accumulate)
T-25  read_log() returns list of GovernanceDecision
T-26  dry_run=True does NOT write to log
T-27  BLOCKED decision is still recorded in log (audit trail)
T-28  REJECTED decision (wrong role) is recorded in log
T-29  ChangeRequest.to_dict() includes all fields
T-30  Governance log survives concurrent appends (two decisions)
T-31  SOUL.md path variants all classify as CLASS_B
T-32  Precedence: C beats B (compliance_config.yaml not reclassified by ** pattern)
T-33  Missing reason on CLASS_B does not block (reason is optional in data model)
T-34  GovernanceGate with custom config_path works
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import uuid
from pathlib import Path

import pytest

# ── Path bootstrap ─────────────────────────────────────────────────────────────
_BASE = os.path.dirname(os.path.abspath(__file__))
_SRC  = os.path.dirname(_BASE)
sys.path.insert(0, _SRC)
sys.path.insert(0, _BASE)

from compliance.governance.soul_governance import (
    ChangeRequest,
    GovernanceDecision,
    GovernanceError,
    GovernanceGate,
    _classify_target,
    _load_config,
)

# ── Config path ────────────────────────────────────────────────────────────────
_CONFIG = Path(_BASE) / "governance" / "change_classes.yaml"


def _gate(tmp_log: Path | None = None, dry_run: bool = False) -> GovernanceGate:
    """Helper: GovernanceGate with real config but temp log (test isolation)."""
    return GovernanceGate(
        config_path = _CONFIG,
        log_path    = tmp_log or Path(tempfile.mktemp(suffix=".jsonl")),
        dry_run     = dry_run,
    )


def _req(
    target:   str            = "docs/SOUL.md",
    approver: str | None     = None,
    role:     str | None     = None,
    reason:   str            = "",
    proposed: str            = "test",
) -> ChangeRequest:
    return ChangeRequest(
        target_file   = target,
        change_type   = "test_update",
        proposed_by   = proposed,
        approver_id   = approver,
        approver_role = role,
        reason        = reason,
    )


# ── T-01..T-02: Config loading ────────────────────────────────────────────────

def test_T01_config_loads():
    cfg = _load_config(_CONFIG)
    assert isinstance(cfg, dict)
    assert "change_classes" in cfg


def test_T02_all_classes_present():
    cfg = _load_config(_CONFIG)
    classes = cfg["change_classes"]
    for cls in ("A", "B", "C"):
        assert cls in classes, f"Missing class {cls}"
        assert "target_patterns" in classes[cls]
        assert "requires_approver" in classes[cls]


# ── T-03..T-09: Classification ────────────────────────────────────────────────

@pytest.mark.parametrize("path", [
    "docs/SOUL.md",
    "workspace-moa/SOUL.md",
    "soul-protected/SOUL.md",
    "SOUL.md",
])
def test_T03_soul_md_is_class_B(path):
    cfg = _load_config(_CONFIG)
    assert _classify_target(path, cfg) == "B"


@pytest.mark.parametrize("path", [
    "agents/workspace-moa/openclaw.json",
    "openclaw.json",
    ".openclaw/openclaw.json",
])
def test_T04_openclaw_json_is_class_B(path):
    cfg = _load_config(_CONFIG)
    assert _classify_target(path, cfg) == "B"


@pytest.mark.parametrize("path", [
    "src/compliance/compliance_config.yaml",
    "developer/compliance/verification/compliance_validator.py",
])
def test_T05_compliance_config_is_class_C(path):
    cfg = _load_config(_CONFIG)
    assert _classify_target(path, cfg) == "C"


def test_T06_rego_is_class_C():
    cfg = _load_config(_CONFIG)
    assert _classify_target("src/compliance/policies/banxe_compliance.rego", cfg) == "C"


def test_T07_agents_md_is_class_A():
    cfg = _load_config(_CONFIG)
    assert _classify_target("agents/workspace-moa/AGENTS.md", cfg) == "A"


def test_T08_compliance_validator_developer_is_class_C():
    cfg = _load_config(_CONFIG)
    cls = _classify_target("developer/compliance/verification/compliance_validator.py", cfg)
    assert cls == "C"


def test_T09_unknown_file_defaults_class_B():
    cfg = _load_config(_CONFIG)
    assert _classify_target("some/totally/unknown/file.xyz", cfg) == "B"


# ── T-10..T-11: CLASS_A auto-approve ─────────────────────────────────────────

def test_T10_class_A_auto_approved():
    gate     = _gate(dry_run=True)
    decision = gate.evaluate(_req(target="agents/workspace-moa/AGENTS.md"))
    assert decision.decision == "APPROVED"


def test_T11_class_A_approver_is_auto():
    gate     = _gate(dry_run=True)
    decision = gate.evaluate(_req(target="agents/workspace-moa/AGENTS.md"))
    assert decision.approver_id == "auto"
    assert decision.change_class == "A"


# ── T-12..T-14: CLASS_B blocked without approver ─────────────────────────────

def test_T12_class_B_no_approver_raises():
    gate = _gate(dry_run=True)
    with pytest.raises(GovernanceError):
        gate.evaluate(_req(target="docs/SOUL.md"))


def test_T13_governance_error_carries_target_and_class():
    gate = _gate(dry_run=True)
    with pytest.raises(GovernanceError) as exc:
        gate.evaluate(_req(target="docs/SOUL.md"))
    assert exc.value.target_file  == "docs/SOUL.md"
    assert exc.value.change_class == "B"


def test_T14_governance_error_carries_required_roles():
    gate = _gate(dry_run=True)
    with pytest.raises(GovernanceError) as exc:
        gate.evaluate(_req(target="docs/SOUL.md"))
    roles = [r.upper() for r in exc.value.required_roles]
    assert "DEVELOPER" in roles
    assert "CTIO" in roles


# ── T-15..T-16: CLASS_B approved ─────────────────────────────────────────────

def test_T15_class_B_valid_approver_approved():
    gate     = _gate(dry_run=True)
    decision = gate.evaluate(_req(
        target   = "docs/SOUL.md",
        approver = "mark-001",
        role     = "DEVELOPER",
        reason   = "quarterly update",
    ))
    assert decision.decision    == "APPROVED"
    assert decision.approver_id == "mark-001"


def test_T16_class_B_approval_written_to_log():
    with tempfile.TemporaryDirectory() as tmp:
        log_path = Path(tmp) / "gov.jsonl"
        gate     = GovernanceGate(config_path=_CONFIG, log_path=log_path)
        gate.evaluate(_req(
            target   = "docs/SOUL.md",
            approver = "mark-001",
            role     = "DEVELOPER",
        ))
        assert log_path.exists()
        lines = log_path.read_text().strip().splitlines()
        assert len(lines) == 1
        d = json.loads(lines[0])
        assert d["decision"] == "APPROVED"
        assert d["change_class"] == "B"


# ── T-17: Wrong role ──────────────────────────────────────────────────────────

def test_T17_class_B_wrong_role_raises():
    gate = _gate(dry_run=True)
    with pytest.raises(GovernanceError) as exc:
        gate.evaluate(_req(
            target   = "docs/SOUL.md",
            approver = "some-agent",
            role     = "AGENT",          # not in CLASS_B roles
        ))
    assert exc.value.change_class == "B"


# ── T-18..T-21: CLASS_C ───────────────────────────────────────────────────────

def test_T18_class_C_no_approver_raises():
    gate = _gate(dry_run=True)
    with pytest.raises(GovernanceError) as exc:
        gate.evaluate(_req(target="src/compliance/compliance_config.yaml"))
    assert exc.value.change_class == "C"


def test_T19_class_C_developer_role_blocked():
    gate = _gate(dry_run=True)
    with pytest.raises(GovernanceError):
        gate.evaluate(_req(
            target   = "src/compliance/compliance_config.yaml",
            approver = "mark-001",
            role     = "DEVELOPER",      # not in CLASS_C roles
        ))


def test_T20_class_C_mlro_approved():
    gate     = _gate(dry_run=True)
    decision = gate.evaluate(_req(
        target   = "src/compliance/compliance_config.yaml",
        approver = "mlro-001",
        role     = "MLRO",
        reason   = "threshold update",
    ))
    assert decision.decision == "APPROVED"
    assert decision.change_class == "C"


def test_T21_class_C_ceo_approved():
    gate     = _gate(dry_run=True)
    decision = gate.evaluate(_req(
        target   = "src/compliance/compliance_config.yaml",
        approver = "ceo-001",
        role     = "CEO",
        reason   = "regulatory change",
    ))
    assert decision.decision == "APPROVED"


# ── T-22..T-23: Serialisation ────────────────────────────────────────────────

def test_T22_decision_to_dict():
    gate     = _gate(dry_run=True)
    decision = gate.evaluate(_req(
        target   = "docs/SOUL.md",
        approver = "mark-001",
        role     = "DEVELOPER",
    ))
    d = decision.to_dict()
    assert isinstance(d, dict)
    assert d["decision"]     == "APPROVED"
    assert d["change_class"] == "B"
    assert "timestamp" in d
    assert "request_id" in d


def test_T23_decision_to_json():
    gate     = _gate(dry_run=True)
    decision = gate.evaluate(_req(
        target   = "docs/SOUL.md",
        approver = "mark-001",
        role     = "DEVELOPER",
    ))
    parsed = json.loads(decision.to_json())
    assert parsed["decision"] == "APPROVED"


# ── T-24..T-26: Log behaviour ─────────────────────────────────────────────────

def test_T24_log_is_append_only():
    with tempfile.TemporaryDirectory() as tmp:
        log_path = Path(tmp) / "gov.jsonl"
        gate     = GovernanceGate(config_path=_CONFIG, log_path=log_path)
        # First: CLASS_A
        gate.evaluate(_req(target="agents/workspace-moa/AGENTS.md"))
        # Second: CLASS_B
        gate.evaluate(_req(target="docs/SOUL.md", approver="m", role="DEVELOPER"))
        lines = log_path.read_text().strip().splitlines()
        assert len(lines) == 2


def test_T25_read_log_returns_decisions():
    with tempfile.TemporaryDirectory() as tmp:
        log_path = Path(tmp) / "gov.jsonl"
        gate     = GovernanceGate(config_path=_CONFIG, log_path=log_path)
        gate.evaluate(_req(target="agents/workspace-moa/AGENTS.md"))
        gate.evaluate(_req(target="docs/SOUL.md", approver="m", role="DEVELOPER"))
        entries = gate.read_log()
        assert len(entries) == 2
        assert all(isinstance(e, GovernanceDecision) for e in entries)


def test_T26_dry_run_does_not_write_log():
    with tempfile.TemporaryDirectory() as tmp:
        log_path = Path(tmp) / "gov.jsonl"
        gate     = GovernanceGate(config_path=_CONFIG, log_path=log_path, dry_run=True)
        gate.evaluate(_req(target="agents/workspace-moa/AGENTS.md"))
        assert not log_path.exists()


# ── T-27..T-28: Blocked decisions recorded ───────────────────────────────────

def test_T27_blocked_decision_recorded_in_log():
    with tempfile.TemporaryDirectory() as tmp:
        log_path = Path(tmp) / "gov.jsonl"
        gate     = GovernanceGate(config_path=_CONFIG, log_path=log_path)
        with pytest.raises(GovernanceError):
            gate.evaluate(_req(target="docs/SOUL.md"))  # no approver
        lines = log_path.read_text().strip().splitlines()
        assert len(lines) == 1
        d = json.loads(lines[0])
        assert d["decision"] == "BLOCKED"


def test_T28_rejected_decision_recorded_in_log():
    with tempfile.TemporaryDirectory() as tmp:
        log_path = Path(tmp) / "gov.jsonl"
        gate     = GovernanceGate(config_path=_CONFIG, log_path=log_path)
        with pytest.raises(GovernanceError):
            gate.evaluate(_req(
                target   = "docs/SOUL.md",
                approver = "bad-agent",
                role     = "AGENT",  # wrong role
            ))
        lines = log_path.read_text().strip().splitlines()
        assert len(lines) == 1
        d = json.loads(lines[0])
        assert d["decision"] == "REJECTED"


# ── T-29..T-30: ChangeRequest ────────────────────────────────────────────────

def test_T29_change_request_to_dict():
    req = _req(target="docs/SOUL.md", approver="x", role="CTIO", reason="test")
    d   = req.to_dict()
    assert d["target_file"]   == "docs/SOUL.md"
    assert d["approver_id"]   == "x"
    assert d["approver_role"] == "CTIO"
    assert d["reason"]        == "test"
    assert "request_id" in d
    assert "timestamp" in d


def test_T30_log_two_decisions_sequential():
    with tempfile.TemporaryDirectory() as tmp:
        log_path = Path(tmp) / "gov.jsonl"
        gate = GovernanceGate(config_path=_CONFIG, log_path=log_path)
        for _ in range(2):
            gate.evaluate(_req(target="docs/SOUL.md", approver="m", role="DEVELOPER"))
        lines = log_path.read_text().strip().splitlines()
        assert len(lines) == 2
        assert all(json.loads(l)["decision"] == "APPROVED" for l in lines)


# ── T-31..T-34: Edge cases ────────────────────────────────────────────────────

@pytest.mark.parametrize("path", [
    "docs/SOUL.md",
    "/docs/SOUL.md",
    "./docs/SOUL.md",
    "workspace/SOUL.md",
    "SOUL.md",
])
def test_T31_soul_path_variants_class_B(path):
    cfg = _load_config(_CONFIG)
    assert _classify_target(path, cfg) == "B"


def test_T32_compliance_config_beats_wildcard():
    """C > B: compliance_config.yaml should be CLASS_C even though ** globs match B."""
    cfg = _load_config(_CONFIG)
    cls = _classify_target("src/compliance/compliance_config.yaml", cfg)
    assert cls == "C"


def test_T33_missing_reason_does_not_block_class_B():
    """Reason is optional in the data model — gate doesn't require it."""
    gate     = _gate(dry_run=True)
    decision = gate.evaluate(_req(
        target   = "docs/SOUL.md",
        approver = "mark-001",
        role     = "DEVELOPER",
        reason   = "",             # empty reason — should still approve
    ))
    assert decision.decision == "APPROVED"


def test_T34_custom_config_path():
    """GovernanceGate accepts explicit config_path."""
    gate = GovernanceGate(config_path=_CONFIG, dry_run=True)
    assert gate.classify("docs/SOUL.md") == "B"
    assert gate.classify("src/compliance/compliance_config.yaml") == "C"
    assert gate.classify("agents/workspace-moa/AGENTS.md") == "A"
