#!/usr/bin/env python3
"""
validate_contexts.py — G-18 Bounded Context Import Validator

Scans Python files in src/compliance/ and detects imports that violate
the bounded context rules defined in contexts/registry.py.

Violations reported:
    BC-FORBIDDEN  Module in CTX-X imports from a module in CTX-Y where Y is
                  in X's forbidden_dependencies list.

Usage:
    python3 validators/validate_contexts.py          # check all files
    python3 validators/validate_contexts.py --strict # exit 1 on any violation

Exit codes:
    0 — no violations (or violations are warnings only)
    1 — violations found (--strict mode)
    2 — config/import error
"""
from __future__ import annotations

import ast
import sys
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────────────
_VALIDATORS_DIR = Path(__file__).parent
_VIBE_ROOT      = _VALIDATORS_DIR.parent.parent.parent
_SRC_DIR        = _VIBE_ROOT / "src"

if str(_SRC_DIR) not in sys.path:
    sys.path.insert(0, str(_SRC_DIR))

from compliance.contexts.registry import CONTEXTS, ContextId, context_for_module


def _module_from_path(path: Path) -> str | None:
    """Convert a file path to a compliance-relative module path."""
    compliance_root = _SRC_DIR / "compliance"
    try:
        rel = path.relative_to(compliance_root)
    except ValueError:
        return None
    parts = list(rel.with_suffix("").parts)
    return ".".join(parts)


def _context_of_path(path: Path) -> ContextId | None:
    """Return the ContextId that owns the given file, or None."""
    module_path = _module_from_path(path)
    if module_path is None:
        return None
    ctx = context_for_module(module_path)
    return ctx.id if ctx else None


def _extract_imports(path: Path) -> list[str]:
    """Return list of top-level compliance module imports from a Python file."""
    try:
        tree = ast.parse(path.read_text())
    except SyntaxError:
        return []

    imports: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if "compliance" in alias.name:
                    # normalise to submodule path
                    parts = alias.name.split(".")
                    if parts[0] == "compliance" and len(parts) > 1:
                        imports.append(".".join(parts[1:]))
        elif isinstance(node, ast.ImportFrom):
            if node.module and "compliance" in node.module:
                parts = node.module.split(".")
                if parts[0] == "compliance" and len(parts) > 1:
                    imports.append(".".join(parts[1:]))
    return imports


def _context_of_import(import_path: str) -> ContextId | None:
    """Return the ContextId that owns an imported module path."""
    ctx = context_for_module(import_path)
    return ctx.id if ctx else None


def scan_file(path: Path) -> list[tuple[str, str, str, str]]:
    """
    Scan a file for BC violations.
    Returns list of (file_path, from_ctx, to_ctx, import_path).
    """
    violations = []
    from_ctx_id = _context_of_path(path)
    if from_ctx_id is None:
        return violations

    from_ctx = CONTEXTS[from_ctx_id]
    imports = _extract_imports(path)

    for imp in imports:
        to_ctx_id = _context_of_import(imp)
        if to_ctx_id is None:
            continue  # unknown module — not a registered context
        if to_ctx_id == from_ctx_id:
            continue  # same context — OK

        if to_ctx_id in from_ctx.forbidden_dependencies:
            violations.append((
                str(path.relative_to(_VIBE_ROOT)),
                from_ctx_id.value,
                to_ctx_id.value,
                imp,
            ))

    return violations


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    strict = "--strict" in args

    compliance_root = _SRC_DIR / "compliance"
    if not compliance_root.exists():
        print(f"[ctx-validator] ERROR: {compliance_root} not found", file=sys.stderr)
        return 2

    py_files = [
        p for p in compliance_root.rglob("*.py")
        if "__pycache__" not in str(p)
        and not p.name.startswith("test_")
    ]

    all_violations: list[tuple[str, str, str, str]] = []
    for path in sorted(py_files):
        violations = scan_file(path)
        all_violations.extend(violations)

    if not all_violations:
        print(f"[ctx-validator] OK — {len(py_files)} files scanned, no BC violations")
        return 0

    print(f"[ctx-validator] BC violations found ({len(all_violations)}):")
    for file_path, from_ctx, to_ctx, imp in all_violations:
        print(f"  BC-FORBIDDEN  {file_path}")
        print(f"               {from_ctx} imports from {to_ctx} (forbidden)")
        print(f"               import: {imp}")

    print()
    print("[ctx-validator] Remediation:")
    print("  • Introduce an Anti-Corruption Layer (ACL) or Port interface")
    print("  • Move the dependency to an allowed context")
    print("  • See banxe-architecture/domain/context-map.yaml for allowed_dependencies")

    if strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
