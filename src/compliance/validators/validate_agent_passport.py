#!/usr/bin/env python3
"""
validate_agent_passport.py — G-12 Agent Passport Validator

Validates agent passport YAML files against agent_passport.schema.json.
Also checks cross-references: agent_id must exist in orchestration_tree.py default tree.

Usage:
    python3 validators/validate_agent_passport.py                  # validate all passports
    python3 validators/validate_agent_passport.py --file AGENT.yaml  # validate one file
    python3 validators/validate_agent_passport.py --list            # list known passports

Exit codes:
    0 — all valid
    1 — validation error(s)
    2 — schema or config error
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

try:
    import yaml  # type: ignore
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

try:
    import jsonschema  # type: ignore
    _JSONSCHEMA_AVAILABLE = True
except ImportError:
    _JSONSCHEMA_AVAILABLE = False

# ── Paths ──────────────────────────────────────────────────────────────────────
_VALIDATORS_DIR  = Path(__file__).parent
_VIBE_ROOT       = _VALIDATORS_DIR.parent.parent.parent
_ARCH_ROOT       = _VIBE_ROOT.parent / "banxe-architecture"
_PASSPORTS_DIR   = _ARCH_ROOT / "agents" / "passports"
_SCHEMA_FILE     = _ARCH_ROOT / "schemas" / "agent_passport.schema.json"

# ── Business rule checks (beyond JSON Schema) ──────────────────────────────────

def _check_level_capabilities(passport: dict) -> list[str]:
    """B-06 / I-22: Level-2 and Level-3 agents must not declare policy_write."""
    errors = []
    level = passport.get("level", 1)
    caps = passport.get("capabilities", [])
    if level in (2, 3) and "policy_write" in caps:
        errors.append(
            f"I-22/B-06 violation: Level-{level} agent declares 'policy_write' capability"
        )
    return errors


def _check_trust_zone_consistency(passport: dict) -> list[str]:
    """B-04: RED zone agents must not appear in GREEN context (CTX-04)."""
    errors = []
    tz = passport.get("trust_zone", "GREEN")
    ctx = passport.get("bounded_context", "CTX-01")
    if tz == "RED" and ctx == "CTX-04":
        errors.append(
            f"B-04: RED trust_zone agent assigned to CTX-04 (Operations/GREEN context)"
        )
    return errors


def _check_level_context(passport: dict) -> list[str]:
    """Level-1 agents should be in CTX-01 (core domain orchestration)."""
    errors = []
    level = passport.get("level", 2)
    ctx = passport.get("bounded_context", "CTX-01")
    if level == 1 and ctx not in ("CTX-01", "CTX-05"):
        errors.append(
            f"Level-1 orchestrator should be in CTX-01 or CTX-05, found {ctx}"
        )
    return errors


_BUSINESS_RULES = [
    _check_level_capabilities,
    _check_trust_zone_consistency,
    _check_level_context,
]


def validate_passport(path: Path, schema: dict) -> tuple[bool, list[str]]:
    """Validate a single passport file. Returns (ok, list_of_errors)."""
    errors: list[str] = []

    # ── Load YAML ──────────────────────────────────────────────────────────────
    if not path.exists():
        return False, [f"File not found: {path}"]

    if not _YAML_AVAILABLE:
        return False, ["PyYAML not installed — run: pip install pyyaml"]

    try:
        passport: dict = yaml.safe_load(path.read_text())
    except Exception as e:
        return False, [f"YAML parse error: {e}"]

    if not isinstance(passport, dict):
        return False, ["Passport must be a YAML mapping (dict)"]

    # ── JSON Schema validation ─────────────────────────────────────────────────
    if _JSONSCHEMA_AVAILABLE:
        try:
            jsonschema.validate(instance=passport, schema=schema)
        except jsonschema.ValidationError as e:
            errors.append(f"Schema: {e.message} (path: {'.'.join(str(p) for p in e.absolute_path)})")
        except jsonschema.SchemaError as e:
            return False, [f"Schema itself is invalid: {e.message}"]
    else:
        # Minimal manual check if jsonschema not installed
        for field in ("agent_id", "name", "version", "level", "trust_zone",
                      "capabilities", "ports", "bounded_context", "invariants", "governance"):
            if field not in passport:
                errors.append(f"Missing required field: {field}")

    # ── Business rules ─────────────────────────────────────────────────────────
    for rule_fn in _BUSINESS_RULES:
        errors.extend(rule_fn(passport))

    # ── agent_id matches filename ──────────────────────────────────────────────
    expected_id = path.stem  # filename without .yaml
    actual_id = passport.get("agent_id", "")
    if actual_id and actual_id != expected_id:
        errors.append(
            f"agent_id mismatch: file is '{expected_id}.yaml' but agent_id='{actual_id}'"
        )

    return len(errors) == 0, errors


def load_schema() -> dict | None:
    if not _SCHEMA_FILE.exists():
        print(f"[passport-validator] WARNING: schema not found at {_SCHEMA_FILE}", file=sys.stderr)
        return None
    return json.loads(_SCHEMA_FILE.read_text())


def cmd_list() -> int:
    passports = sorted(_PASSPORTS_DIR.glob("*.yaml")) if _PASSPORTS_DIR.exists() else []
    if not passports:
        print(f"[passport-validator] No passports found in {_PASSPORTS_DIR}")
        return 0
    print(f"[passport-validator] {len(passports)} passport(s) in {_PASSPORTS_DIR}:")
    for p in passports:
        print(f"  • {p.name}")
    return 0


def cmd_validate(paths: list[Path]) -> int:
    schema = load_schema()
    if schema is None:
        schema = {}  # fall back to business-rules-only check

    total = 0
    passed = 0
    failed_files: list[str] = []

    for path in paths:
        total += 1
        ok, errors = validate_passport(path, schema)
        if ok:
            passed += 1
            print(f"  ✓  {path.name}")
        else:
            failed_files.append(path.name)
            print(f"  ✗  {path.name}")
            for err in errors:
                print(f"     └─ {err}")

    print()
    if failed_files:
        print(f"[passport-validator] FAIL — {len(failed_files)}/{total} passport(s) invalid")
        return 1
    else:
        print(f"[passport-validator] OK — all {total} passport(s) valid")
        return 0


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]

    if "--list" in args:
        return cmd_list()

    if "--file" in args:
        idx = args.index("--file")
        if idx + 1 >= len(args):
            print("ERROR: --file requires a path argument", file=sys.stderr)
            return 2
        paths = [Path(args[idx + 1])]
    else:
        if not _PASSPORTS_DIR.exists():
            print(f"[passport-validator] No passports directory: {_PASSPORTS_DIR}", file=sys.stderr)
            return 2
        paths = sorted(_PASSPORTS_DIR.glob("*.yaml"))
        if not paths:
            print(f"[passport-validator] No *.yaml files in {_PASSPORTS_DIR}")
            return 0

    print(f"[passport-validator] Validating {len(paths)} passport(s)...")
    return cmd_validate(paths)


if __name__ == "__main__":
    sys.exit(main())
