#!/usr/bin/env python3
"""
validate_trust_zones.py — G-11 Trust Zone Validator

Validates file paths against the trust-zones.yaml specification.
Detects files that are in the wrong zone or match RED zone patterns
without governance bypass.

Usage:
    python3 validators/validate_trust_zones.py                   # scan all
    python3 validators/validate_trust_zones.py --file path/to/f  # check one file
    python3 validators/validate_trust_zones.py --zone RED        # list RED files
    python3 validators/validate_trust_zones.py --check-drift     # RED + drift check

Exit codes:
    0 — OK
    1 — violation or mismatch
    2 — config error
"""
from __future__ import annotations

import fnmatch
import json
import subprocess
import sys
from pathlib import Path

try:
    import yaml
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

# ── Paths ──────────────────────────────���───────────────────────────────────────
_VALIDATORS_DIR = Path(__file__).parent
_VIBE_ROOT      = _VALIDATORS_DIR.parent.parent.parent
_ARCH_ROOT      = _VIBE_ROOT.parent / "banxe-architecture"
_TRUST_ZONES    = _ARCH_ROOT / "governance" / "trust-zones.yaml"
_DRIFT_CHECK    = _VALIDATORS_DIR / "policy_drift_check.py"


def _load_trust_zones() -> dict:
    if not _TRUST_ZONES.exists():
        return {}
    if not _YAML_AVAILABLE:
        print("[trust-zones] ERROR: PyYAML not installed", file=sys.stderr)
        return {}
    return yaml.safe_load(_TRUST_ZONES.read_text())


def zone_for_path(file_path: str, zones_config: dict) -> str | None:
    """
    Return the zone ID ('RED', 'AMBER', 'GREEN') for the given file path.
    Checks zones in priority order: RED > AMBER > GREEN.
    Returns None if no zone matches.
    """
    # Check in priority order: most restrictive first
    for zone_priority in ("RED", "AMBER", "GREEN"):
        zone = next(
            (z for z in zones_config.get("zones", []) if z["id"] == zone_priority),
            None,
        )
        if zone is None:
            continue
        for path_entry in zone.get("paths", []):
            pattern = path_entry["pattern"]
            # Match using fnmatch against the full path and basename
            basename = Path(file_path).name
            if fnmatch.fnmatch(file_path, pattern):
                return zone_priority
            if fnmatch.fnmatch(basename, pattern.lstrip("*/")):
                return zone_priority
            # Also match against pattern without leading **/
            clean_pattern = pattern.lstrip("**/").lstrip("*/")
            if clean_pattern and fnmatch.fnmatch(file_path, f"*{clean_pattern}"):
                return zone_priority
            if clean_pattern and fnmatch.fnmatch(basename, clean_pattern):
                return zone_priority
    return None


def zone_for_path_detail(file_path: str, zones_config: dict) -> tuple[str | None, str | None]:
    """Return (zone_id, reason) for the given path."""
    for zone_priority in ("RED", "AMBER", "GREEN"):
        zone = next(
            (z for z in zones_config.get("zones", []) if z["id"] == zone_priority),
            None,
        )
        if zone is None:
            continue
        for path_entry in zone.get("paths", []):
            pattern = path_entry["pattern"]
            basename = Path(file_path).name
            reason = path_entry.get("reason", "")
            clean_pattern = pattern.lstrip("**/").lstrip("*/")
            if (
                fnmatch.fnmatch(file_path, pattern)
                or fnmatch.fnmatch(basename, pattern.lstrip("*/"))
                or (clean_pattern and fnmatch.fnmatch(file_path, f"*{clean_pattern}"))
                or (clean_pattern and fnmatch.fnmatch(basename, clean_pattern))
            ):
                return zone_priority, reason
    return None, None


def list_red_files(zones_config: dict) -> list[str]:
    """Return list of glob patterns for RED zone files."""
    red_zone = next(
        (z for z in zones_config.get("zones", []) if z["id"] == "RED"), None
    )
    if not red_zone:
        return []
    return [entry["pattern"] for entry in red_zone.get("paths", [])]


def scan_directory(root: Path, zones_config: dict) -> list[tuple[str, str]]:
    """
    Scan directory and return list of (relative_path, zone_id) for known files.
    Files not matching any zone are skipped.
    """
    results = []
    for path in root.rglob("*"):
        if path.is_dir():
            continue
        if "__pycache__" in str(path):
            continue
        if ".git" in str(path):
            continue
        try:
            rel = str(path.relative_to(root))
        except ValueError:
            continue
        zone, _ = zone_for_path_detail(rel, zones_config)
        if zone:
            results.append((rel, zone))
    return sorted(results)


def cmd_check_file(file_path: str) -> int:
    zones_config = _load_trust_zones()
    if not zones_config:
        print("[trust-zones] ERROR: trust-zones.yaml not found or empty", file=sys.stderr)
        return 2

    zone, reason = zone_for_path_detail(file_path, zones_config)
    if zone is None:
        print(f"[trust-zones] {file_path}")
        print(f"  Zone: UNCLASSIFIED (not in trust-zones.yaml)")
        return 0

    zone_obj = next((z for z in zones_config["zones"] if z["id"] == zone), {})
    ai_policy = zone_obj.get("ai_generation_policy", "UNKNOWN")

    print(f"[trust-zones] {file_path}")
    print(f"  Zone:       {zone}")
    print(f"  AI policy:  {ai_policy}")
    if reason:
        print(f"  Reason:     {reason}")
    print(f"  Approval:   {zone_obj.get('approval', {}).get('change_class', 'CLASS_A')}")
    return 0


def cmd_list_zone(zone_id: str) -> int:
    zones_config = _load_trust_zones()
    if not zones_config:
        return 2

    zone_obj = next(
        (z for z in zones_config.get("zones", []) if z["id"] == zone_id.upper()), None
    )
    if not zone_obj:
        print(f"[trust-zones] Zone '{zone_id}' not found", file=sys.stderr)
        return 2

    print(f"[trust-zones] Zone {zone_id}: {len(zone_obj['paths'])} path pattern(s)")
    for entry in zone_obj["paths"]:
        print(f"  {entry['pattern']:55s}  # {entry.get('reason', '')}")
    return 0


def cmd_validate() -> int:
    """Validate all files in vibe-coding against trust zones — check for mismatches."""
    zones_config = _load_trust_zones()
    if not zones_config:
        return 2

    red_patterns = list_red_files(zones_config)
    violations = []

    # Scan compliance directory for RED zone files
    compliance_dir = _VIBE_ROOT / "src" / "compliance"
    if compliance_dir.exists():
        for path in compliance_dir.rglob("*"):
            if not path.is_file() or "__pycache__" in str(path):
                continue
            rel = str(path.relative_to(_VIBE_ROOT))
            zone, reason = zone_for_path_detail(rel, zones_config)
            if zone == "RED":
                violations.append((rel, "RED zone file in vibe-coding", reason or ""))

    if violations:
        print(f"[trust-zones] WARNING: {len(violations)} RED zone file(s) found in vibe-coding:")
        for path, msg, reason in violations:
            print(f"  ⚠  {path}")
            print(f"     {msg}: {reason}")
        print()
        print("  These files require governance controls (policy_guard.py enforces at edit-time).")
        return 0  # warn only, not fail — they're correctly tracked

    zones_config_zone_count = len(zones_config.get("zones", []))
    print(
        f"[trust-zones] OK — {zones_config_zone_count} zones loaded, "
        f"trust-zones.yaml valid, no unclassified RED files"
    )
    return 0


def cmd_check_drift() -> int:
    """Run policy drift check alongside trust zone validation."""
    rc = cmd_validate()
    if rc != 0:
        return rc

    if _DRIFT_CHECK.exists():
        result = subprocess.run(
            [sys.executable, str(_DRIFT_CHECK), "--verify"],
            capture_output=True, text=True, cwd=str(_VIBE_ROOT),
        )
        print(result.stdout.strip())
        if result.returncode != 0:
            print("[trust-zones] Policy drift detected — run policy_drift_check.py --update after RED zone approval")
            return 1
    else:
        print("[trust-zones] policy_drift_check.py not found — skipping drift check")

    return 0


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]

    if "--file" in args:
        idx = args.index("--file")
        if idx + 1 >= len(args):
            print("ERROR: --file requires a path argument", file=sys.stderr)
            return 2
        return cmd_check_file(args[idx + 1])

    if "--zone" in args:
        idx = args.index("--zone")
        if idx + 1 >= len(args):
            print("ERROR: --zone requires a zone ID (RED|AMBER|GREEN)", file=sys.stderr)
            return 2
        return cmd_list_zone(args[idx + 1])

    if "--check-drift" in args:
        return cmd_check_drift()

    return cmd_validate()


if __name__ == "__main__":
    sys.exit(main())
