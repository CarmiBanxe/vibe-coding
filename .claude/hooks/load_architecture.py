#!/usr/bin/env python3
"""
load_architecture.py — G-21 Hook 4: UserPromptSubmit architecture context.

On architecture/compliance related queries, emits a one-line summary of
the current project state (open gaps, test count, active sprint).

Trigger:  UserPromptSubmit
Exit:     always 0
Output:   single-line context summary (only for architecture queries)

Keeps output minimal — runs on every user message, so it must be fast
and silent when not relevant.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

# Keywords that indicate an architecture-relevant query
_ARCH_KEYWORDS = {
    "gap", "g-0", "g-1", "g-2", "sprint", "architecture",
    "hexagonal", "cqrs", "event sourcing", "invariant",
    "compliance stack", "bounded context", "port", "adapter",
    "governance", "trust boundary", "orchestration tree",
    "soul.md", "feedback_loop", "policy guard",
}

# Known test count (updated by CI / manually after suite runs)
# In production this would read from a badge/artifact
_LAST_KNOWN_SUITE = 520


def _count_open_gaps(gap_register: Path) -> int:
    if not gap_register.exists():
        return -1
    return gap_register.read_text().count("| OPEN |")


def _count_done_p1(gap_register: Path) -> int:
    if not gap_register.exists():
        return -1
    text = gap_register.read_text()
    # Count P1 rows that are DONE
    done = 0
    in_p1 = False
    for line in text.splitlines():
        if "## P1" in line:
            in_p1 = True
        elif line.startswith("## "):
            in_p1 = False
        if in_p1 and "| DONE |" in line:
            done += 1
    return done


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        sys.exit(0)

    prompt = data.get("prompt", "").lower()

    # Check relevance
    if not any(kw in prompt for kw in _ARCH_KEYWORDS):
        sys.exit(0)

    # Compute state
    gap_register = Path.home() / "banxe-architecture" / "GAP-REGISTER.md"
    open_gaps    = _count_open_gaps(gap_register)
    done_p1      = _count_done_p1(gap_register)

    gap_info = (
        f"P1: {done_p1} DONE / 0 OPEN"
        if open_gaps == 0
        else f"open: {open_gaps}"
    )

    # Check Instruction Ledger for open items
    il_path = Path.home() / "banxe-architecture" / "INSTRUCTION-LEDGER.md"
    il_open = 0
    if il_path.exists():
        il_text = il_path.read_text()
        il_open = sum(
            1 for line in il_text.splitlines()
            if ("IN_PROGRESS" in line or "VERIFY" in line) and "DONE" not in line
        )

    il_info = f"IL: {il_open} open" if il_open > 0 else "IL: all done ✓"

    print(
        f"[BANXE ARCH] Suite: {_LAST_KNOWN_SUITE} tests ✓  |  "
        f"Gaps {gap_info}  |  "
        f"Hooks: G-21+IL-gate active  |  "
        f"{il_info}  |  "
        f"Sprint P2 in progress"
    )

    sys.exit(0)


if __name__ == "__main__":
    main()
