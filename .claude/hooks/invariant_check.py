#!/usr/bin/env python3
"""
invariant_check.py — G-21 Hook 2: PostToolUse invariant enforcement.

After any Edit/Write to compliance/ or developer/ files:
  1. Validates critical invariants (I-22, I-24, I-25) via inline Python checks
  2. Runs Semgrep if available (degrades gracefully when not installed)
  3. Warns (does NOT block — PostToolUse) on violations

Trigger:  PostToolUse → matcher: "Edit|Write"
Exit:     always 0 (warn-only, never blocks)
Output:   violation messages to stdout (shown to Claude as warnings)
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path


# ── Files that trigger the check ─────────────────────────────────────────────
_COMPLIANCE_PATTERNS = [
    r"src/compliance/",
    r"developer/compliance/",
    r"src/compliance/.*\.py$",
]

# ── Inline invariant rules (no Semgrep required) ─────────────────────────────
# Each rule: (invariant_id, description, pattern_to_find_in_content, file_filter)
_INVARIANT_RULES: list[tuple[str, str, str, str]] = [
    (
        "I-22",
        "PolicyPort write violation: AuditPort/PolicyPort must be append-only",
        r"(update_event|delete_event|update_policy|write_policy)\s*\(",
        r"\.py$",
    ),
    (
        "I-24",
        "Mutable audit record: DecisionEvent fields reassigned after creation",
        r"event\.(event_id|occurred_at)\s*=",
        r"\.py$",
    ),
    (
        "I-25",
        "ExplanationBundle bypass: result.explanation set to None explicitly",
        r"result\.explanation\s*=\s*None",
        r"banxe_aml_orchestrator\.py$",
    ),
    (
        "I-21",
        "Hardcoded threshold: numeric threshold value instead of config_loader",
        r"score\s*>=\s*(85|70|40)\b(?!.*get_threshold)",
        r"banxe_aml_orchestrator\.py$",
    ),
]


def _check_invariants(file_path: str, content: str) -> list[str]:
    """Run inline invariant rules against file content. Returns violation messages."""
    violations: list[str] = []
    for inv_id, desc, pattern, file_filter in _INVARIANT_RULES:
        if not re.search(file_filter, file_path):
            continue
        matches = list(re.finditer(pattern, content, re.MULTILINE))
        for m in matches:
            line_no = content[: m.start()].count("\n") + 1
            violations.append(
                f"  [{inv_id}] {desc}\n"
                f"    {file_path}:{line_no}: {m.group(0)[:80]}"
            )
    return violations


def _run_semgrep(file_path: str, rules_path: str) -> list[str]:
    """Run Semgrep if available. Returns list of violation strings."""
    try:
        result = subprocess.run(
            ["semgrep", "--config", rules_path, "--quiet", "--json", file_path],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return []
        # Parse JSON output
        try:
            data = json.loads(result.stdout)
            findings = data.get("results", [])
            return [
                f"  [semgrep/{f.get('check_id','?')}] {f.get('extra', {}).get('message','')}\n"
                f"    {f.get('path','')}:{f.get('start', {}).get('line','?')}"
                for f in findings[:5]  # cap at 5
            ]
        except json.JSONDecodeError:
            pass
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return []


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        sys.exit(0)

    tool_input = data.get("tool_input", {})
    file_path  = tool_input.get("file_path", "")

    if not file_path:
        sys.exit(0)

    # Only check compliance files
    if not any(re.search(p, file_path) for p in _COMPLIANCE_PATTERNS):
        sys.exit(0)

    violations: list[str] = []

    # ── 1. Read file content ──────────────────────────────────────────────────
    try:
        content = Path(file_path).read_text()
    except (IOError, OSError):
        sys.exit(0)  # file gone or unreadable — skip

    # ── 2. Inline invariant checks ────────────────────────────────────────────
    violations.extend(_check_invariants(file_path, content))

    # ── 3. Semgrep (optional) ─────────────────────────────────────────────────
    vibe_root  = Path(file_path).parents[
        file_path.replace("\\", "/").count("/") - 1
    ]
    rules_path = ".semgrep/banxe-rules.yml"
    if Path(rules_path).exists():
        violations.extend(_run_semgrep(file_path, rules_path))

    # ── 4. Emit warnings ─────────────────────────────────────────────────────
    if violations:
        print(f"[G-21/invariant-check] {len(violations)} potential violation(s) in {Path(file_path).name}:")
        for v in violations:
            print(v)
        print(f"  → Review before committing.")

    # PostToolUse: always exit 0 (warn, don't block)
    sys.exit(0)


if __name__ == "__main__":
    main()
