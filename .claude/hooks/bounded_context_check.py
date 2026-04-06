#!/usr/bin/env python3
"""
bounded_context_check.py — G-21 Hook 3: PostToolUse bounded context guard.

After any Edit/Write to a .py file, checks for cross-context import violations
and other architectural boundary breaches defined in G-18.

Trigger:  PostToolUse → matcher: "Edit|Write"
Exit:     always 0 (warn-only)
Output:   violation messages to stdout

Boundary rules enforced:
  BC-01  agents/ must not import engine modules directly — use Ports
  BC-02  event_sourcing/ must not import from banxe_aml_orchestrator
  BC-03  governance/ must not import from agents/ (cross-cutting concern)
  BC-04  test files must not import production Postgres adapters
  BC-05  New non-port module importing from 3+ compliance sub-packages (fan-out)
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path


# ── Boundary rules ────────────────────────────────────────────────────────────

@property
def _violations_placeholder() -> None: ...  # kept for IDE


_RULES: list[tuple[str, str, str, str]] = [
    # (rule_id, file_pattern, bad_import_pattern, message)
    (
        "BC-01",
        r"compliance/agents/",
        r"^from compliance\.(tx_monitor|sanctions_check|crypto_aml|aml_orchestrator)\b",
        "agents/ layer must use Port interfaces, not direct engine imports. "
        "Use compliance.ports.* instead.",
    ),
    (
        "BC-02",
        r"compliance/event_sourcing/",
        r"^from compliance\.banxe_aml_orchestrator\b",
        "event_sourcing/ must not import from the orchestrator — "
        "depends on DecisionEvent (utils/decision_event_log) only.",
    ),
    (
        "BC-03",
        r"compliance/governance/",
        r"^from compliance\.agents\.",
        "governance/ is a cross-cutting concern and must not import "
        "from agents/ — import from ports/ only.",
    ),
    (
        "BC-04",
        r"test_",
        r"^from compliance\.utils\.decision_event_log import PostgresEventLogAdapter",
        "Test files must use InMemoryAuditAdapter, not PostgresEventLogAdapter. "
        "Postgres in tests = slow + requires live DB.",
    ),
]

# ── Fan-out detector ──────────────────────────────────────────────────────────
# Warn if a non-ports, non-test file imports from >= 3 distinct compliance sub-packages
_FAN_OUT_EXEMPT = re.compile(
    r"test_|conftest|__init__|ports/|adapters/"
)
_FAN_OUT_IMPORT = re.compile(
    r"^from compliance\.(\w+)", re.MULTILINE
)
_FAN_OUT_THRESHOLD = 4


def _check_fan_out(file_path: str, content: str) -> str | None:
    if _FAN_OUT_EXEMPT.search(file_path):
        return None
    packages = set(_FAN_OUT_IMPORT.findall(content))
    packages -= {"models", "utils", "ports"}   # common utility imports — OK
    if len(packages) >= _FAN_OUT_THRESHOLD:
        return (
            f"BC-05  High fan-out: '{Path(file_path).name}' imports from "
            f"{len(packages)} compliance sub-packages ({', '.join(sorted(packages))}). "
            f"Consider using a Port or a higher-level facade."
        )
    return None


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        sys.exit(0)

    tool_input = data.get("tool_input", {})
    file_path  = tool_input.get("file_path", "")

    if not file_path or not file_path.endswith(".py"):
        sys.exit(0)

    try:
        content = Path(file_path).read_text()
    except (IOError, OSError):
        sys.exit(0)

    violations: list[str] = []

    # ── Rule-based checks ─────────────────────────────────────────────────────
    for rule_id, file_pattern, import_pattern, message in _RULES:
        if not re.search(file_pattern, file_path):
            continue
        matches = re.findall(import_pattern, content, re.MULTILINE)
        if matches:
            violations.append(
                f"  [{rule_id}] {message}\n"
                f"    Found in {Path(file_path).name}: {matches[0]}"
            )

    # ── Fan-out check ─────────────────────────────────────────────────────────
    fan_out = _check_fan_out(file_path, content)
    if fan_out:
        violations.append(f"  [{fan_out}]")

    # ── Emit ──────────────────────────────────────────────────────────────────
    if violations:
        print(
            f"[G-21/bounded-context] {len(violations)} architectural warning(s) "
            f"in {Path(file_path).name}:"
        )
        for v in violations:
            print(v)
        print(f"  → See banxe-architecture/GAP-REGISTER.md G-18 for context map.")

    sys.exit(0)


if __name__ == "__main__":
    main()
