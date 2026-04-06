#!/usr/bin/env python3
"""
policy_drift_check.py — G-08 Policy Drift Detection

Tracks SHA-256 checksums of critical policy files and detects drift.

Usage:
    python3 validators/policy_drift_check.py             # verify (default)
    python3 validators/policy_drift_check.py --verify    # verify checksums
    python3 validators/policy_drift_check.py --update    # update baseline
    python3 validators/policy_drift_check.py --show      # print current hashes

Exit codes:
    0 — no drift (or --update succeeded)
    1 — drift detected (files changed from baseline)
    2 — baseline file missing (run --update first)

Policy files tracked (relative to vibe-coding repo root):
    - docs/SOUL.md                                (CLASS_B governance)
    - AGENTS.md                                   (orchestration rules)
    - src/compliance/compliance_config.yaml       (thresholds, CLASS_C)
    - src/compliance/policies/banxe_compliance.rego  (OPA rules, CLASS_C)
    - ../banxe-architecture/INVARIANTS.md         (system invariants)
"""
from __future__ import annotations

import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────────────
_VALIDATORS_DIR = Path(__file__).parent
_VIBE_ROOT      = _VALIDATORS_DIR.parent.parent.parent   # vibe-coding/
_ARCH_ROOT      = _VIBE_ROOT.parent / "banxe-architecture"
_BASELINE_FILE  = _VALIDATORS_DIR / "policy_checksums.json"

# ── Tracked policy files ───────────────────────────────────────────────────────
_POLICY_FILES: dict[str, Path] = {
    "docs/SOUL.md":                              _VIBE_ROOT / "docs" / "SOUL.md",
    "AGENTS.md":                                 _VIBE_ROOT / "AGENTS.md",
    "src/compliance/compliance_config.yaml":     _VIBE_ROOT / "src" / "compliance" / "compliance_config.yaml",
    "src/compliance/policies/banxe_compliance.rego": _VIBE_ROOT / "src" / "compliance" / "policies" / "banxe_compliance.rego",
    "banxe-architecture/INVARIANTS.md":          _ARCH_ROOT / "INVARIANTS.md",
}


def _sha256(path: Path) -> str | None:
    """Return hex SHA-256 of file, or None if file doesn't exist."""
    if not path.exists():
        return None
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def _load_baseline() -> dict:
    if not _BASELINE_FILE.exists():
        return {}
    return json.loads(_BASELINE_FILE.read_text())


def _save_baseline(data: dict) -> None:
    _VALIDATORS_DIR.mkdir(parents=True, exist_ok=True)
    _BASELINE_FILE.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def compute_current() -> dict[str, str | None]:
    """Compute current checksums for all tracked files."""
    return {key: _sha256(path) for key, path in _POLICY_FILES.items()}


def cmd_update() -> int:
    """Update baseline with current file hashes."""
    current = compute_current()
    baseline = {
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "checksums": {k: v for k, v in current.items() if v is not None},
        "missing": [k for k, v in current.items() if v is None],
    }
    _save_baseline(baseline)

    print("[policy-drift] Baseline updated:")
    for key, chk in baseline["checksums"].items():
        print(f"  ✓  {key}  ({chk[:16]}...)")
    if baseline["missing"]:
        print("[policy-drift] Files not found (skipped):")
        for key in baseline["missing"]:
            print(f"  ⚠  {key}")
    return 0


def cmd_verify() -> int:
    """Verify current files against baseline. Returns 1 on drift."""
    raw = _load_baseline()
    if not raw or "checksums" not in raw:
        print("[policy-drift] ERROR: No baseline found. Run --update first.", file=sys.stderr)
        return 2

    baseline_checksums: dict[str, str] = raw["checksums"]
    baseline_time: str = raw.get("updated_at", "unknown")
    current = compute_current()

    drifted: list[tuple[str, str, str | None, str | None]] = []  # key, status, expected, actual
    new_files: list[str] = []

    for key, current_hash in current.items():
        if key not in baseline_checksums:
            if current_hash is not None:
                new_files.append(key)
            continue
        expected = baseline_checksums[key]
        if current_hash is None:
            drifted.append((key, "DELETED", expected, None))
        elif current_hash != expected:
            drifted.append((key, "MODIFIED", expected, current_hash))

    # Files in baseline but not in _POLICY_FILES (shouldn't happen, but guard)
    for key in baseline_checksums:
        if key not in current:
            drifted.append((key, "UNTRACKED", baseline_checksums[key], None))

    # ── Report ─────────────────────────────────────────────────────────────────
    if not drifted and not new_files:
        print(f"[policy-drift] OK — all {len(baseline_checksums)} policy files match baseline ({baseline_time})")
        return 0

    print(f"[policy-drift] DRIFT DETECTED — baseline: {baseline_time}")
    print()

    for key, status, expected, actual in drifted:
        if status == "DELETED":
            print(f"  DELETED   {key}")
            print(f"            expected: {expected[:16]}...")
        elif status == "MODIFIED":
            print(f"  MODIFIED  {key}")
            print(f"            baseline: {expected[:16]}...")
            print(f"            current:  {actual[:16]}...")  # type: ignore[index]
        else:
            print(f"  {status}  {key}")

    for key in new_files:
        print(f"  NEW       {key}  (not in baseline — run --update to track)")

    print()
    print("[policy-drift] Remediation:")
    print("  • If change was authorised: python3 validators/policy_drift_check.py --update")
    print("  • If change was unexpected: git diff HEAD -- <file> and investigate")
    print("  • CLASS_B files (SOUL.md, openclaw.json): require DEVELOPER|CTIO|CEO approval")
    print("  • CLASS_C files (compliance_config.yaml, *.rego): require MLRO|CEO approval")

    return 1


def cmd_show() -> int:
    """Print current checksums without comparing to baseline."""
    current = compute_current()
    print("[policy-drift] Current checksums:")
    for key, chk in current.items():
        if chk:
            print(f"  {chk[:16]}...  {key}")
        else:
            print(f"  {'<missing>':20s}  {key}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]

    if "--update" in args:
        return cmd_update()
    elif "--show" in args:
        return cmd_show()
    else:
        return cmd_verify()


if __name__ == "__main__":
    sys.exit(main())
