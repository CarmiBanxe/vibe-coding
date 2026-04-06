#!/usr/bin/env python3
"""
policy_guard.py — G-21 Hook 1: PreToolUse policy layer guard.

Blocks Edit/Write tool calls targeting CLASS_B or CLASS_C files
(as defined in change_classes.yaml) and directs the operator to the
appropriate governance path.

Trigger:  PreToolUse → matcher: "Edit|Write"
Exit:
  0  — allowed, no output
  2  — blocked (non-zero), reason printed to stdout (shown to Claude)

Bypass:
  Set GOVERNANCE_BYPASS=1 in environment to skip this hook.
  Only for: protect-soul.sh internal calls, emergency procedures.
"""
from __future__ import annotations

import json
import os
import re
import sys


# ── CLASS_B — requires DEVELOPER|CTIO|CEO approval ───────────────────────────
_CLASS_B: list[tuple[str, str]] = [
    (r"SOUL\.md$",         "SOUL.md — core agent identity"),
    (r"SOUL-[^/]+\.md$",   "SOUL variant — core agent identity"),
    (r"IDENTITY\.md$",     "IDENTITY.md — agent self-description"),
    (r"BOOTSTRAP\.md$",    "BOOTSTRAP.md — agent startup config"),
    (r"openclaw\.json$",   "openclaw.json — gateway config"),
]

# ── CLASS_C — requires MLRO|CEO approval ─────────────────────────────────────
_CLASS_C: list[tuple[str, str]] = [
    (r"compliance_config\.yaml$", "compliance_config.yaml — AML thresholds (I-21)"),
    (r"banxe_compliance\.rego$",  "banxe_compliance.rego — OPA policy (I-22)"),
    (r"[^/]+\.rego$",             ".rego policy file"),
]


def _match(file_path: str, patterns: list[tuple[str, str]]) -> str | None:
    """Return description of first matching pattern, or None."""
    for pattern, description in patterns:
        if re.search(pattern, file_path):
            return description
    return None


def main() -> None:
    # Bypass for emergency / protect-soul.sh internal use
    if os.environ.get("GOVERNANCE_BYPASS") == "1":
        sys.exit(0)

    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        sys.exit(0)  # malformed input — allow (fail-open)

    tool_input = data.get("tool_input", {})
    file_path  = tool_input.get("file_path", "")

    if not file_path:
        sys.exit(0)

    # ── CLASS_C check (most restrictive) ─────────────────────────────────────
    desc = _match(file_path, _CLASS_C)
    if desc:
        print(f"[G-05/CLASS_C] BLOCKED: Direct edit of '{file_path}' is not allowed.")
        print(f"  File: {desc}")
        print(f"  CLASS_C changes require MLRO or CEO approval.")
        print(f"")
        print(f"  Governance path:")
        print(f"    python3 src/compliance/governance/soul_governance.py check \\")
        print(f"        --target '{file_path}' \\")
        print(f"        --approver <mlro-id> --role MLRO --reason '<justification>'")
        sys.exit(2)

    # ── CLASS_B check ─────────────────────────────────────────────────────────
    desc = _match(file_path, _CLASS_B)
    if desc:
        print(f"[G-05/CLASS_B] BLOCKED: Direct edit of '{file_path}' is not allowed.")
        print(f"  File: {desc}")
        print(f"  CLASS_B changes require DEVELOPER, CTIO, or CEO approval.")
        print(f"")
        print(f"  Governance path:")
        print(f"    bash scripts/protect-soul.sh update '{file_path}' \\")
        print(f"        --approver <your-id> --role DEVELOPER --reason '<justification>'")
        print(f"")
        print(f"  Or call the governance gate directly:")
        print(f"    python3 src/compliance/governance/soul_governance.py check \\")
        print(f"        --target '{file_path}' \\")
        print(f"        --approver <your-id> --role DEVELOPER --reason '<justification>'")
        sys.exit(2)

    # Allowed
    sys.exit(0)


if __name__ == "__main__":
    main()
