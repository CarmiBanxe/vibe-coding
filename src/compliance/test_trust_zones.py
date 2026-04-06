"""
test_trust_zones.py — G-11 Trust Zone Tests

T-01  trust-zones.yaml exists and is valid YAML
T-02  trust-zones.yaml has exactly 3 zones (RED, AMBER, GREEN)
T-03  zone_for_path: SOUL.md → RED
T-04  zone_for_path: compliance_config.yaml → RED
T-05  zone_for_path: banxe_compliance.rego → RED
T-06  zone_for_path: banxe_aml_orchestrator.py → AMBER
T-07  zone_for_path: sanctions_check.py → AMBER
T-08  zone_for_path: ports/audit_port.py → AMBER
T-09  zone_for_path: emergency_stop.py → GREEN
T-10  zone_for_path: test_phase15.py → GREEN
T-11  zone_for_path: unknown_file.xyz → None
T-12  RED zone has ai_generation_policy = FORBIDDEN
T-13  AMBER zone has ai_generation_policy = CLAUDE_CODE_ONLY
T-14  GREEN zone has ai_generation_policy = PERMITTED
T-15  RED zone requires approval
T-16  GREEN zone does not require approval
T-17  CONTRIBUTING.md exists in banxe-architecture
T-18  CONTRIBUTING.md has RED/AMBER/GREEN sections
T-19  validate_trust_zones.py exits 0 (no unclassified violations)
T-20  zone_for_path_detail returns reason string for RED files
T-21  RED zone has MLRO or CEO in approver roles
T-22  trust_level: RED < AMBER < GREEN (by numeric value)
T-23  all zones have at least one path pattern
T-24  validate_trust_zones --zone RED lists 14 patterns
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest
import yaml

_VIBE_ROOT  = Path(__file__).parent.parent.parent
_ARCH_ROOT  = _VIBE_ROOT.parent / "banxe-architecture"
_TZ_YAML    = _ARCH_ROOT / "governance" / "trust-zones.yaml"
_CONTRIB    = _ARCH_ROOT / "CONTRIBUTING.md"
_VALIDATOR  = _VIBE_ROOT / "src" / "compliance" / "validators" / "validate_trust_zones.py"

if str(_VIBE_ROOT / "src") not in sys.path:
    sys.path.insert(0, str(_VIBE_ROOT / "src"))

from compliance.validators.validate_trust_zones import zone_for_path, zone_for_path_detail


def _load_tz():
    return yaml.safe_load(_TZ_YAML.read_text())


def _run(*args: str) -> tuple[int, str]:
    r = subprocess.run(
        [sys.executable, str(_VALIDATOR)] + list(args),
        capture_output=True, text=True, cwd=str(_VIBE_ROOT),
    )
    return r.returncode, r.stdout + r.stderr


# ── T-01: file exists and valid YAML ──────────────────────────────────────────

def test_T01_trust_zones_yaml_exists_and_valid():
    assert _TZ_YAML.exists(), f"Missing: {_TZ_YAML}"
    data = _load_tz()
    assert isinstance(data, dict)
    assert "zones" in data


# ── T-02: exactly 3 zones ─────────────────────────────────────────────────────

def test_T02_three_zones():
    data = _load_tz()
    ids = [z["id"] for z in data["zones"]]
    assert set(ids) == {"RED", "AMBER", "GREEN"}
    assert len(ids) == 3


# ── T-03..T-11: zone_for_path ─────────────────────────────────────────────────

@pytest.mark.parametrize("path,expected", [
    ("docs/SOUL.md",                                           "RED"),
    ("workspace-moa/SOUL.md",                                  "RED"),
    ("src/compliance/compliance_config.yaml",                  "RED"),
    ("src/compliance/policies/banxe_compliance.rego",          "RED"),
    ("governance/change-classes.yaml",                         "RED"),
    ("src/compliance/banxe_aml_orchestrator.py",               "AMBER"),
    ("src/compliance/sanctions_check.py",                      "AMBER"),
    ("src/compliance/ports/audit_port.py",                     "AMBER"),
    ("src/compliance/emergency_stop.py",                       "GREEN"),
    ("src/compliance/test_phase15.py",                         "GREEN"),
    ("some_unknown_file.xyz",                                  None),
])
def test_T03_to_T11_zone_assignment(path, expected):
    data = _load_tz()
    result = zone_for_path(path, data)
    assert result == expected, f"zone_for_path({path!r}) = {result!r}, expected {expected!r}"


# ── T-12..T-14: AI generation policies ───────────────────────────────────────

def test_T12_red_ai_policy_forbidden():
    data = _load_tz()
    red = next(z for z in data["zones"] if z["id"] == "RED")
    assert red["ai_generation_policy"] == "FORBIDDEN"


def test_T13_amber_ai_policy_claude_code():
    data = _load_tz()
    amber = next(z for z in data["zones"] if z["id"] == "AMBER")
    assert amber["ai_generation_policy"] == "CLAUDE_CODE_ONLY"


def test_T14_green_ai_policy_permitted():
    data = _load_tz()
    green = next(z for z in data["zones"] if z["id"] == "GREEN")
    assert green["ai_generation_policy"] == "PERMITTED"


# ── T-15..T-16: approval requirements ────────────────────────────────────────

def test_T15_red_requires_approval():
    data = _load_tz()
    red = next(z for z in data["zones"] if z["id"] == "RED")
    assert red["approval"]["required"] is True


def test_T16_green_does_not_require_approval():
    data = _load_tz()
    green = next(z for z in data["zones"] if z["id"] == "GREEN")
    assert green["approval"]["required"] is False


# ── T-17..T-18: CONTRIBUTING.md ───────────────────────────────────────────────

def test_T17_contributing_md_exists():
    assert _CONTRIB.exists(), f"Missing: {_CONTRIB}"


def test_T18_contributing_md_has_zone_sections():
    text = _CONTRIB.read_text()
    assert "Zone RED" in text
    assert "Zone AMBER" in text
    assert "Zone GREEN" in text


# ── T-19: validator exits 0 ───────────────────────────────────────────────────

def test_T19_validator_exits_0():
    rc, out = _run()
    assert rc == 0, f"Validator failed:\n{out}"


# ── T-20: zone_for_path_detail returns reason ─────────────────────────────────

def test_T20_detail_returns_reason_for_red():
    data = _load_tz()
    zone, reason = zone_for_path_detail("docs/SOUL.md", data)
    assert zone == "RED"
    assert reason and len(reason) > 5


# ── T-21: RED has MLRO or CEO approver ───────────────────────────────────────

def test_T21_red_approvers_include_mlro_or_ceo():
    data = _load_tz()
    red = next(z for z in data["zones"] if z["id"] == "RED")
    roles = red["approval"]["roles"]
    assert "MLRO" in roles or "CEO" in roles


# ── T-22: trust_level ordering ───────────────────────────────────────────────

def test_T22_trust_levels_ordered():
    data = _load_tz()
    levels = {z["id"]: z["trust_level"] for z in data["zones"]}
    assert levels["RED"] < levels["AMBER"] < levels["GREEN"]


# ── T-23: all zones have paths ───────────────────────────────────────────────

@pytest.mark.parametrize("zone_id", ["RED", "AMBER", "GREEN"])
def test_T23_all_zones_have_paths(zone_id):
    data = _load_tz()
    zone = next(z for z in data["zones"] if z["id"] == zone_id)
    assert len(zone["paths"]) >= 1


# ── T-24: RED has 14 patterns ────────────────────────────────────────────────

def test_T24_red_has_correct_pattern_count():
    rc, out = _run("--zone", "RED")
    assert rc == 0
    # Count lines starting with "  **" or "  src"
    pattern_lines = [l for l in out.splitlines() if l.strip().startswith(("**/", "src/"))]
    assert len(pattern_lines) == 14, f"Expected 14 RED patterns, got {len(pattern_lines)}\n{out}"
