#!/usr/bin/env python3
"""
quality_gate_hook.py — PreToolUse hook: intercept git commit → run quality-gate.sh
IL-016 | Developer Plane | banxe-ai-bank

Fires when Claude Code attempts a Bash tool call.
If the command is a git commit → run quality-gate.sh first.
If quality gate FAILS → block the commit with a clear message.
If not a commit → pass through (exit 0).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys


def main() -> None:
    try:
        hook_input = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        sys.exit(0)  # malformed input → pass through

    tool_name = hook_input.get("tool_name", "")
    tool_input = hook_input.get("tool_input", {})

    # Only intercept Bash tool calls
    if tool_name != "Bash":
        sys.exit(0)

    command = tool_input.get("command", "")

    # Only intercept git commit commands
    if "git commit" not in command:
        sys.exit(0)

    # Find repo root: first try to extract from the command (cd /some/path && git commit)
    repo_root = _find_repo_root_from_command(command) or _find_repo_root()

    # Only enforce the gate for Product Plane repos (banxe-emi-stack).
    # Developer Plane (vibe-coding) has pre-existing issues tracked separately —
    # blocking its infra commits would create a chicken-and-egg loop.
    PRODUCT_PLANE_REPOS = {"banxe-emi-stack"}
    repo_name = os.path.basename(repo_root)
    if repo_name not in PRODUCT_PLANE_REPOS:
        sys.exit(0)

    gate_script = os.path.join(repo_root, "scripts", "quality-gate.sh")

    if not os.path.isfile(gate_script):
        # quality-gate.sh not found → warn but don't block
        _output_warning(f"quality-gate.sh not found at {gate_script} — skipping gate check")
        sys.exit(0)

    # Run quality gate
    result = subprocess.run(
        ["bash", gate_script, "--fast"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        timeout=120,
    )

    if result.returncode != 0:
        # Block the commit
        output = {
            "decision": "block",
            "reason": (
                "❌ QUALITY GATE FAILED — commit blocked.\n\n"
                f"{result.stdout}\n"
                "Fix all issues above, then retry git commit."
            ),
        }
        print(json.dumps(output))
        sys.exit(0)

    # Gate passed → allow
    sys.exit(0)


def _find_repo_root_from_command(command: str) -> str | None:
    """
    Extract the working directory from a shell command like:
      cd /home/mmber/banxe-emi-stack && git add ... && git commit ...
    Returns the path if found and it contains .git/, else None.
    """
    import re
    # Match: cd /some/path (possibly followed by && or ;)
    matches = re.findall(r'(?:^|\n|&&|;)\s*cd\s+([^\s;&|]+)', command)
    for path in reversed(matches):
        # Expand ~ if present
        path = os.path.expanduser(path)
        if os.path.isdir(os.path.join(path, ".git")):
            return path
        # Walk up from this path
        candidate = _walk_to_git_root(path)
        if candidate:
            return candidate
    return None


def _find_repo_root() -> str:
    """Walk up from CWD to find git root (contains .git/)."""
    return _walk_to_git_root(os.getcwd()) or os.getcwd()


def _walk_to_git_root(start: str) -> str | None:
    """Walk up from start to find a directory containing .git/."""
    path = start
    for _ in range(8):
        if os.path.isdir(os.path.join(path, ".git")):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            break
        path = parent
    return None


def _output_warning(msg: str) -> None:
    """Output a non-blocking warning message."""
    output = {"decision": "approve", "reason": f"⚠️ {msg}"}
    print(json.dumps(output))


if __name__ == "__main__":
    main()
