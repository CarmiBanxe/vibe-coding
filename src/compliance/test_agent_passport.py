"""
test_agent_passport.py — G-12 Agent Passport Tests

T-01  validate_agent_passport exits 0 for all 9 valid passports
T-02  each passport file name matches its agent_id field
T-03  all passports have required fields: agent_id, name, version, level, trust_zone, capabilities, ports, bounded_context, invariants, governance
T-04  level-2/3 agents do not declare policy_write capability (I-22/B-06)
T-05  all invariant references match I-NN pattern
T-06  all aigf_risks references match AIGF-X-NN pattern
T-07  trust_zone is one of GREEN, AMBER, RED
T-08  bounded_context is one of CTX-01..CTX-05
T-09  governance.change_class is one of CLASS_A, CLASS_B, CLASS_C
T-10  governance.owner is non-empty string
T-11  version follows semver pattern X.Y.Z
T-12  validator rejects missing required field
T-13  validator rejects agent_id mismatch with filename
T-14  validator rejects Level-2 with policy_write capability (I-22)
T-15  validator rejects RED trust_zone in CTX-04 (B-04)
T-16  schema file exists and is valid JSON
T-17  schema has required properties listed
T-18  all 9 passports have at least one invariant
T-19  all 9 passports have at least one capability
T-20  Level-1 agents are in CTX-01 or CTX-05
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest
import yaml

_VIBE_ROOT    = Path(__file__).parent.parent.parent
_ARCH_ROOT    = _VIBE_ROOT.parent / "banxe-architecture"
_PASSPORTS    = sorted((_ARCH_ROOT / "agents" / "passports").glob("*.yaml"))
_SCHEMA_FILE  = _ARCH_ROOT / "schemas" / "agent_passport.schema.json"
_VALIDATOR    = _VIBE_ROOT / "src" / "compliance" / "validators" / "validate_agent_passport.py"

if str(_VIBE_ROOT / "src") not in sys.path:
    sys.path.insert(0, str(_VIBE_ROOT / "src"))


def _load(path: Path) -> dict:
    return yaml.safe_load(path.read_text())


def _run_validator(*args: str) -> tuple[int, str]:
    r = subprocess.run(
        [sys.executable, str(_VALIDATOR)] + list(args),
        capture_output=True, text=True, cwd=str(_VIBE_ROOT),
    )
    return r.returncode, r.stdout + r.stderr


# ── T-01: all 9 passports valid ───────────────────────────────────────────────

def test_T01_all_passports_valid():
    assert len(_PASSPORTS) == 9, f"Expected 9 passports, found {len(_PASSPORTS)}"
    rc, out = _run_validator()
    assert rc == 0, f"Validator failed:\n{out}"
    assert "OK — all 9" in out


# ── T-02: filename matches agent_id ──────────────────────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T02_filename_matches_agent_id(path):
    p = _load(path)
    assert p["agent_id"] == path.stem, (
        f"{path.name}: agent_id='{p['agent_id']}' ≠ filename stem '{path.stem}'"
    )


# ── T-03: required fields ─────────────────────────────────────────────────────

_REQUIRED = ("agent_id", "name", "version", "level", "trust_zone",
             "capabilities", "ports", "bounded_context", "invariants", "governance")

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T03_required_fields_present(path):
    p = _load(path)
    for field in _REQUIRED:
        assert field in p, f"{path.name}: missing required field '{field}'"


# ── T-04: no policy_write for Level-2/3 (I-22/B-06) ─────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T04_no_policy_write_for_level_2_3(path):
    p = _load(path)
    if p.get("level", 1) in (2, 3):
        assert "policy_write" not in p.get("capabilities", []), (
            f"{path.name}: Level-{p['level']} agent declares forbidden 'policy_write'"
        )


# ── T-05: invariant pattern ───────────────────────────────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T05_invariant_references_valid(path):
    p = _load(path)
    for inv in p.get("invariants", []):
        assert re.match(r"^I-\d+$", inv), (
            f"{path.name}: invalid invariant reference '{inv}' (expected I-NN)"
        )


# ── T-06: AIGF risk pattern ───────────────────────────────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T06_aigf_risks_valid_pattern(path):
    p = _load(path)
    for risk in p.get("aigf_risks", []):
        assert re.match(r"^AIGF-[A-Z]+-\d+$", risk), (
            f"{path.name}: invalid aigf_risk '{risk}' (expected AIGF-X-NN)"
        )


# ── T-07: trust_zone values ───────────────────────────────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T07_trust_zone_valid(path):
    p = _load(path)
    assert p["trust_zone"] in ("GREEN", "AMBER", "RED"), (
        f"{path.name}: invalid trust_zone '{p['trust_zone']}'"
    )


# ── T-08: bounded_context values ──────────────────────────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T08_bounded_context_valid(path):
    p = _load(path)
    assert p["bounded_context"] in ("CTX-01", "CTX-02", "CTX-03", "CTX-04", "CTX-05"), (
        f"{path.name}: invalid bounded_context '{p['bounded_context']}'"
    )


# ── T-09: governance.change_class ────────────────────────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T09_governance_change_class_valid(path):
    p = _load(path)
    gov = p.get("governance", {})
    assert gov.get("change_class") in ("CLASS_A", "CLASS_B", "CLASS_C"), (
        f"{path.name}: invalid governance.change_class '{gov.get('change_class')}'"
    )


# ── T-10: governance.owner non-empty ─────────────────────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T10_governance_owner_nonempty(path):
    p = _load(path)
    owner = p.get("governance", {}).get("owner", "")
    assert owner and len(owner) > 2, (
        f"{path.name}: governance.owner is empty or too short"
    )


# ── T-11: version semver ─────────────────────────────────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T11_version_semver(path):
    p = _load(path)
    assert re.match(r"^\d+\.\d+\.\d+$", p.get("version", "")), (
        f"{path.name}: version '{p.get('version')}' is not semver X.Y.Z"
    )


# ── T-12: validator rejects missing field ─────────────────────────────────────

def test_T12_validator_rejects_missing_required_field(tmp_path):
    from compliance.validators.validate_agent_passport import validate_passport, load_schema
    passport_file = tmp_path / "bad_agent.yaml"
    # Missing: version, level, trust_zone, capabilities, ports, bounded_context, invariants, governance
    bad = {"agent_id": "bad_agent", "name": "Bad Agent"}
    passport_file.write_text(yaml.dump(bad))
    schema = load_schema() or {}
    ok, errors = validate_passport(passport_file, schema)
    assert not ok
    assert len(errors) > 0


# ── T-13: validator rejects agent_id mismatch ────────────────────────────────

def test_T13_validator_rejects_agent_id_mismatch(tmp_path):
    from compliance.validators.validate_agent_passport import validate_passport
    passport_file = tmp_path / "correct_name.yaml"
    passport_data = {
        "agent_id": "wrong_name",
        "name": "Test Agent",
        "version": "1.0.0",
        "level": 2,
        "trust_zone": "AMBER",
        "bounded_context": "CTX-01",
        "capabilities": ["risk_assessment"],
        "ports": {"inbound": [], "outbound": []},
        "invariants": ["I-24"],
        "governance": {"change_class": "CLASS_B", "owner": "Test Team"},
    }
    passport_file.write_text(yaml.dump(passport_data))
    ok, errors = validate_passport(passport_file, {})
    assert not ok
    assert any("mismatch" in e for e in errors)


# ── T-14: Level-2 with policy_write is rejected ───────────────────────────────

def test_T14_validator_rejects_policy_write_for_level2(tmp_path):
    from compliance.validators.validate_agent_passport import validate_passport
    passport_file = tmp_path / "bad_agent.yaml"
    passport_data = {
        "agent_id": "bad_agent",
        "name": "Bad Agent",
        "version": "1.0.0",
        "level": 2,
        "trust_zone": "AMBER",
        "bounded_context": "CTX-01",
        "capabilities": ["risk_assessment", "policy_write"],
        "ports": {},
        "invariants": ["I-22"],
        "governance": {"change_class": "CLASS_B", "owner": "Team"},
    }
    passport_file.write_text(yaml.dump(passport_data))
    ok, errors = validate_passport(passport_file, {})
    assert not ok
    assert any("policy_write" in e for e in errors)


# ── T-15: RED in CTX-04 is rejected ──────────────────────────────────────────

def test_T15_validator_rejects_red_in_ctx04(tmp_path):
    from compliance.validators.validate_agent_passport import validate_passport
    passport_file = tmp_path / "ops_agent.yaml"
    passport_data = {
        "agent_id": "ops_agent",
        "name": "Ops Agent",
        "version": "1.0.0",
        "level": 3,
        "trust_zone": "RED",
        "bounded_context": "CTX-04",
        "capabilities": ["event_write"],
        "ports": {},
        "invariants": ["I-24"],
        "governance": {"change_class": "CLASS_A", "owner": "Platform"},
    }
    passport_file.write_text(yaml.dump(passport_data))
    ok, errors = validate_passport(passport_file, {})
    assert not ok
    assert any("RED" in e and "CTX-04" in e for e in errors)


# ── T-16: schema file valid JSON ─────────────────────────────────────────────

def test_T16_schema_file_valid_json():
    assert _SCHEMA_FILE.exists(), f"Schema file missing: {_SCHEMA_FILE}"
    schema = json.loads(_SCHEMA_FILE.read_text())
    assert isinstance(schema, dict)
    assert "$schema" in schema


# ── T-17: schema has required properties ─────────────────────────────────────

def test_T17_schema_has_required_properties():
    schema = json.loads(_SCHEMA_FILE.read_text())
    required = schema.get("required", [])
    for field in ("agent_id", "level", "trust_zone", "capabilities", "governance"):
        assert field in required, f"Schema missing required field: '{field}'"


# ── T-18: every passport has at least one invariant ──────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T18_at_least_one_invariant(path):
    p = _load(path)
    assert len(p.get("invariants", [])) >= 1, (
        f"{path.name}: must declare at least one invariant"
    )


# ── T-19: every passport has at least one capability ─────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T19_at_least_one_capability(path):
    p = _load(path)
    assert len(p.get("capabilities", [])) >= 1, (
        f"{path.name}: must declare at least one capability"
    )


# ── T-20: Level-1 agents in CTX-01 or CTX-05 ─────────────────────────────────

@pytest.mark.parametrize("path", _PASSPORTS, ids=[p.stem for p in _PASSPORTS])
def test_T20_level1_in_correct_context(path):
    p = _load(path)
    if p.get("level") == 1:
        assert p.get("bounded_context") in ("CTX-01", "CTX-05"), (
            f"{path.name}: Level-1 agent should be in CTX-01 or CTX-05, "
            f"found {p.get('bounded_context')}"
        )
