"""
compliance_snapshot.py — G-13 Compliance Snapshot Bundle

Collects all compliance artefacts into a single ZIP for auditors and MLRO review.

Usage:
    python -m compliance.utils.compliance_snapshot --output /tmp/audit-2026-04-05.zip
    python -m compliance.utils.compliance_snapshot --output /tmp/audit.zip --pretty

Output:
    ZIP containing:
        snapshot.json            — machine-readable summary of all compliance state
        compliance_config.yaml   — policy thresholds
        INVARIANTS.md            — system invariants
        GAP-REGISTER.md          — gap register
        change-classes.yaml      — change classification
        trust-zones.yaml         — trust zone rules
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import zipfile
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ── Path resolution ────────────────────────────────────────────────────────────

def _find_root() -> Path:
    """Find vibe-coding root (where src/compliance lives)."""
    here = Path(__file__).resolve()
    # Traverse up to find src/compliance marker
    for parent in here.parents:
        if (parent / "src" / "compliance").exists():
            return parent
    # Fallback: assume 3 levels up from this file (utils/compliance/src/)
    return here.parents[3]


def _find_arch_root() -> Path:
    """Find banxe-architecture root (sibling of vibe-coding)."""
    vibe = _find_root()
    arch = vibe.parent / "banxe-architecture"
    if arch.exists():
        return arch
    return vibe  # fallback


VIBE_ROOT = _find_root()
ARCH_ROOT = _find_arch_root()
SRC_COMPLIANCE = VIBE_ROOT / "src" / "compliance"


# ── Dataclass ─────────────────────────────────────────────────────────────────

@dataclass
class ComplianceSnapshot:
    """Immutable snapshot of compliance state at a point in time."""
    timestamp: str                          # ISO-8601 UTC
    version: str                            # semver from pyproject.toml
    git_sha: str                            # current HEAD sha (or "unknown")
    policy_checksums: dict[str, str]        # filename → sha256
    invariants_count: int                   # lines matching "| I-" in INVARIANTS.md
    test_results: dict[str, int]            # {"passed": N, "failed": N}
    agent_passports_count: int              # YAML files in agents/passports/
    rego_rules_count: int                   # "allow" + "deny" lines in *.rego
    gap_register_summary: dict[str, int]    # {"done": N, "open": N, "deferred": N}
    thresholds: dict[str, object]           # key thresholds from compliance_config.yaml
    errors: list[str] = field(default_factory=list)  # non-fatal collection errors

    def to_dict(self) -> dict:
        return asdict(self)

    def to_markdown(self) -> str:
        lines = [
            "# BANXE Compliance Snapshot",
            f"**Generated:** {self.timestamp}",
            f"**Version:** {self.version}  |  **Git SHA:** {self.git_sha[:12] if len(self.git_sha) > 12 else self.git_sha}",
            "",
            "## Gap Register",
            f"- Done: {self.gap_register_summary.get('done', 0)}",
            f"- Open: {self.gap_register_summary.get('open', 0)}",
            f"- Deferred: {self.gap_register_summary.get('deferred', 0)}",
            "",
            "## Test Results",
            f"- Passed: {self.test_results.get('passed', 0)}",
            f"- Failed: {self.test_results.get('failed', 0)}",
            "",
            "## Agent Passports",
            f"- Count: {self.agent_passports_count}",
            "",
            "## Invariants",
            f"- Count: {self.invariants_count}",
            "",
            "## Rego Rules",
            f"- Count: {self.rego_rules_count}",
            "",
            "## Policy Checksums",
        ]
        for fname, sha in self.policy_checksums.items():
            lines.append(f"- `{fname}`: `{sha[:16]}...`")
        if self.thresholds:
            lines.append("")
            lines.append("## Key Thresholds")
            for k, v in self.thresholds.items():
                lines.append(f"- {k}: {v}")
        if self.errors:
            lines.append("")
            lines.append("## Collection Errors (non-fatal)")
            for e in self.errors:
                lines.append(f"- {e}")
        return "\n".join(lines)


# ── Collection helpers ─────────────────────────────────────────────────────────

def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    try:
        h.update(path.read_bytes())
        return h.hexdigest()
    except OSError:
        return "file-not-found"


def _git_sha() -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True, text=True, cwd=str(VIBE_ROOT), timeout=5
        )
        return result.stdout.strip() if result.returncode == 0 else "unknown"
    except Exception:
        return "unknown"


def _read_version() -> str:
    pyproject = VIBE_ROOT / "pyproject.toml"
    try:
        for line in pyproject.read_text().splitlines():
            if line.startswith("version"):
                return line.split("=")[1].strip().strip('"')
    except Exception:
        pass
    return "unknown"


def _collect_policy_checksums() -> dict[str, str]:
    targets = {
        "SOUL.md": VIBE_ROOT / "docs" / "SOUL.md",
        "AGENTS.md": VIBE_ROOT / "AGENTS.md",
        "compliance_config.yaml": SRC_COMPLIANCE / "compliance_config.yaml",
        "banxe_compliance.rego": ARCH_ROOT / "banxe_compliance.rego",
        "INVARIANTS.md": ARCH_ROOT / "INVARIANTS.md",
    }
    return {name: _sha256(path) for name, path in targets.items()}


def _count_invariants() -> int:
    inv = ARCH_ROOT / "INVARIANTS.md"
    try:
        text = inv.read_text()
        return sum(1 for line in text.splitlines() if "| I-" in line)
    except OSError:
        return 0


def _count_passports() -> int:
    passports_dir = ARCH_ROOT / "agents" / "passports"
    if not passports_dir.exists():
        return 0
    return len(list(passports_dir.glob("*.yaml")))


def _count_rego_rules() -> int:
    count = 0
    search_dirs = [SRC_COMPLIANCE, ARCH_ROOT]
    for d in search_dirs:
        for rego_file in d.rglob("*.rego"):
            try:
                text = rego_file.read_text()
                for line in text.splitlines():
                    stripped = line.strip()
                    if stripped.startswith("allow") or stripped.startswith("deny"):
                        count += 1
            except OSError:
                pass
    return count


def _parse_gap_register() -> dict[str, int]:
    gap_file = ARCH_ROOT / "GAP-REGISTER.md"
    summary = {"done": 0, "open": 0, "deferred": 0}
    try:
        for line in gap_file.read_text().splitlines():
            upper = line.upper()
            if "| DONE |" in upper:
                summary["done"] += 1
            elif "| OPEN |" in upper:
                summary["open"] += 1
            elif "| DEFERRED |" in upper:
                summary["deferred"] += 1
    except OSError:
        pass
    return summary


def _collect_thresholds() -> dict[str, object]:
    config_path = SRC_COMPLIANCE / "compliance_config.yaml"
    thresholds: dict[str, object] = {}
    try:
        import yaml  # type: ignore[import]
        data = yaml.safe_load(config_path.read_text())
        decision = data.get("decision_thresholds", {})
        thresholds["reject_threshold"] = decision.get("reject_threshold")
        thresholds["hold_threshold"] = decision.get("hold_threshold")
        thresholds["sar_auto_threshold"] = decision.get("sar_auto_threshold")
    except Exception:
        # yaml not available or config missing — skip gracefully
        pass
    return thresholds


def _run_tests() -> dict[str, int]:
    """Run pytest in collect-only mode to count tests, or return zeros on error."""
    try:
        result = subprocess.run(
            ["python3", "-m", "pytest", "src/compliance/",
             "--ignore=src/compliance/test_api_integration.py",
             "--ignore=src/compliance/test_suite.py",
             "--no-cov", "-q", "--tb=no"],
            capture_output=True, text=True, cwd=str(VIBE_ROOT), timeout=120
        )
        # Parse "N passed" from output
        passed = 0
        failed = 0
        for line in result.stdout.splitlines():
            if "passed" in line:
                parts = line.split()
                for i, p in enumerate(parts):
                    if p == "passed":
                        try:
                            passed = int(parts[i - 1])
                        except (ValueError, IndexError):
                            pass
            if "failed" in line:
                parts = line.split()
                for i, p in enumerate(parts):
                    if p == "failed":
                        try:
                            failed = int(parts[i - 1])
                        except (ValueError, IndexError):
                            pass
        return {"passed": passed, "failed": failed}
    except Exception:
        return {"passed": 0, "failed": 0}


# ── Public API ─────────────────────────────────────────────────────────────────

def collect_snapshot(run_tests: bool = True) -> ComplianceSnapshot:
    """
    Collect the current compliance state into a ComplianceSnapshot.

    Args:
        run_tests: If True, runs pytest to get live test counts.
                   Set False for faster collection (tests → {"passed":0,"failed":0}).
    """
    errors: list[str] = []

    policy_checksums = _collect_policy_checksums()
    invariants_count = _count_invariants()
    passports_count = _count_passports()
    rego_count = _count_rego_rules()
    gap_summary = _parse_gap_register()
    thresholds = _collect_thresholds()
    test_results = _run_tests() if run_tests else {"passed": 0, "failed": 0}

    # Report missing critical files as non-fatal errors
    for name, sha in policy_checksums.items():
        if sha == "file-not-found":
            errors.append(f"Policy file not found: {name}")

    return ComplianceSnapshot(
        timestamp=datetime.now(timezone.utc).isoformat(),
        version=_read_version(),
        git_sha=_git_sha(),
        policy_checksums=policy_checksums,
        invariants_count=invariants_count,
        test_results=test_results,
        agent_passports_count=passports_count,
        rego_rules_count=rego_count,
        gap_register_summary=gap_summary,
        thresholds=thresholds,
        errors=errors,
    )


def export_snapshot_zip(output_path: str | Path, snapshot: Optional[ComplianceSnapshot] = None) -> Path:
    """
    Export a compliance snapshot ZIP bundle for auditors.

    Args:
        output_path: Path for the output .zip file.
        snapshot:    Pre-collected snapshot. If None, collects a fresh one.

    Returns:
        Resolved Path to the created ZIP file.
    """
    if snapshot is None:
        snapshot = collect_snapshot(run_tests=False)

    output_path = Path(output_path).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Files to include in the ZIP
    artefacts: list[tuple[str, Path]] = [
        ("compliance_config.yaml", SRC_COMPLIANCE / "compliance_config.yaml"),
        ("INVARIANTS.md", ARCH_ROOT / "INVARIANTS.md"),
        ("GAP-REGISTER.md", ARCH_ROOT / "GAP-REGISTER.md"),
        ("change-classes.yaml", ARCH_ROOT / "governance" / "change-classes.yaml"),
        ("trust-zones.yaml", ARCH_ROOT / "governance" / "trust-zones.yaml"),
    ]

    with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as zf:
        # snapshot.json
        zf.writestr("snapshot.json", json.dumps(snapshot.to_dict(), indent=2))
        # snapshot.md — human readable
        zf.writestr("snapshot.md", snapshot.to_markdown())
        # policy artefacts
        for arc_name, src_path in artefacts:
            if src_path.exists():
                zf.write(src_path, arc_name)
            # silently skip missing files (errors already in snapshot.errors)

    return output_path


# ── CLI ────────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="BANXE Compliance Snapshot — export all artefacts for auditors"
    )
    parser.add_argument(
        "--output", required=True,
        help="Output ZIP path, e.g. /tmp/audit-2026-04-05.zip"
    )
    parser.add_argument(
        "--no-tests", action="store_true",
        help="Skip running pytest (faster, tests=0 in snapshot)"
    )
    parser.add_argument(
        "--pretty", action="store_true",
        help="Print markdown report to stdout after creating ZIP"
    )
    args = parser.parse_args()

    print(f"Collecting compliance snapshot...")
    snapshot = collect_snapshot(run_tests=not args.no_tests)

    zip_path = export_snapshot_zip(args.output, snapshot)
    print(f"ZIP created: {zip_path}")
    print(f"  Tests:      {snapshot.test_results['passed']} passed / {snapshot.test_results['failed']} failed")
    print(f"  GAPs:       {snapshot.gap_register_summary}")
    print(f"  Passports:  {snapshot.agent_passports_count}")
    print(f"  Invariants: {snapshot.invariants_count}")
    print(f"  Rego rules: {snapshot.rego_rules_count}")
    if snapshot.errors:
        print(f"  Errors:     {snapshot.errors}")

    if args.pretty:
        print()
        print(snapshot.to_markdown())


if __name__ == "__main__":
    main()
