#!/usr/bin/env python3
"""
il_gate.py — G-21 Hook 5 (PreToolUse): Instruction Ledger Gate.

Blocks Edit/Write/Bash when >3 IN_PROGRESS/VERIFY IL entries lack Proof.

Invariant: I-28 (Instruction Ledger Discipline)
Trigger:   PreToolUse (Edit | Write | Bash)
Exit:       0 = allow, 2 = block
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

_IL_PATH = Path.home() / "banxe-architecture" / "INSTRUCTION-LEDGER.md"
_MAX_OPEN = 3


def _count_open(text: str) -> int:
    count = 0
    for line in text.splitlines():
        if "IN_PROGRESS" in line and "DONE" not in line:
            count += 1
        elif "VERIFY" in line and "DONE" not in line and "Proof" not in line:
            count += 1
    return count


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        sys.exit(0)

    tool_name = data.get("tool_name", "")
    if not any(t in tool_name for t in ("Edit", "Write", "Bash")):
        sys.exit(0)

    if not _IL_PATH.exists():
        sys.exit(0)

    text = _IL_PATH.read_text(encoding="utf-8")
    open_count = _count_open(text)

    if open_count > _MAX_OPEN:
        print(
            f"⛔ IL-GATE [I-28]: {open_count} незавершённых инструкций (лимит: {_MAX_OPEN}).\n"
            f"Завершите текущие IL-записи перед новой работой.\n"
            f"Статус: bash ~/banxe-architecture/scripts/il-check.sh",
            file=sys.stderr,
        )
        sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
