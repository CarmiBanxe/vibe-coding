"""
test_bounded_contexts.py — G-18 Bounded Context Tests

T-01  CONTEXTS registry has exactly 5 entries
T-02  all ContextId values are CTX-01..CTX-05
T-03  context_for_module returns correct context for known modules
T-04  context_for_module returns None for unknown module
T-05  allowed_imports: CTX-01 → CTX-02 allowed (conformist)
T-06  allowed_imports: CTX-02 → CTX-01 forbidden
T-07  allowed_imports: CTX-01 → CTX-04 forbidden
T-08  allowed_imports: CTX-04 → CTX-03 allowed (read projections)
T-09  allowed_imports: CTX-03 → CTX-01 forbidden
T-10  validate_contexts.py exits 0 (no violations in current codebase)
T-11  all contexts have at least one module
T-12  all contexts have non-empty name and description
T-13  trust_zone is GREEN, AMBER, or RED for all contexts
T-14  RED contexts have no allowed_dependencies (most isolated)
T-15  CTX-01 (core domain) has highest allowed_dependencies count
T-16  context_for_module: banxe_aml_orchestrator → CTX-01
T-17  context_for_module: governance.soul_governance → CTX-02
T-18  context_for_module: event_sourcing.event_store → CTX-03
T-19  context_for_module: emergency_stop → CTX-04
T-20  context_for_module: agents.orchestration_tree → CTX-05
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_VIBE_ROOT = Path(__file__).parent.parent.parent
if str(_VIBE_ROOT / "src") not in sys.path:
    sys.path.insert(0, str(_VIBE_ROOT / "src"))

from compliance.contexts.registry import (
    CONTEXTS, ContextId, BoundedContext,
    context_for_module, allowed_imports,
)

_VALIDATOR = _VIBE_ROOT / "src" / "compliance" / "validators" / "validate_contexts.py"


# ── T-01: 5 contexts ─────────────────────────────────────────────────────────

def test_T01_five_contexts():
    assert len(CONTEXTS) == 5


# ── T-02: CTX-01..CTX-05 ─────────────────────────────────────────────────────

def test_T02_context_ids():
    ids = {ctx.id.value for ctx in CONTEXTS.values()}
    assert ids == {"CTX-01", "CTX-02", "CTX-03", "CTX-04", "CTX-05"}


# ── T-03: known module lookup ─────────────────────────────────────────────────

@pytest.mark.parametrize("module,expected_ctx", [
    ("banxe_aml_orchestrator",       ContextId.COMPLIANCE),
    ("governance.soul_governance",   ContextId.POLICY),
    ("event_sourcing.event_store",   ContextId.AUDIT),
    ("emergency_stop",               ContextId.OPERATIONS),
    ("agents.orchestration_tree",    ContextId.AGENT_TRUST),
])
def test_T03_context_for_known_module(module, expected_ctx):
    ctx = context_for_module(module)
    assert ctx is not None
    assert ctx.id == expected_ctx


# ── T-04: unknown module ──────────────────────────────────────────────────────

def test_T04_context_for_unknown_module():
    assert context_for_module("some.random.module") is None


# ── T-05..T-09: allowed_imports rules ────────────────────────────────────────

def test_T05_ctx01_can_import_ctx02():
    assert allowed_imports(ContextId.COMPLIANCE, ContextId.POLICY) is True


def test_T06_ctx02_cannot_import_ctx01():
    assert allowed_imports(ContextId.POLICY, ContextId.COMPLIANCE) is False


def test_T07_ctx01_cannot_import_ctx04():
    assert allowed_imports(ContextId.COMPLIANCE, ContextId.OPERATIONS) is False


def test_T08_ctx04_can_import_ctx03():
    assert allowed_imports(ContextId.OPERATIONS, ContextId.AUDIT) is True


def test_T09_ctx03_cannot_import_ctx01():
    assert allowed_imports(ContextId.AUDIT, ContextId.COMPLIANCE) is False


# ── T-10: no violations in codebase ──────────────────────────────────────────

def test_T10_no_bc_violations_in_codebase():
    r = subprocess.run(
        [sys.executable, str(_VALIDATOR)],
        capture_output=True, text=True, cwd=str(_VIBE_ROOT),
    )
    assert r.returncode == 0, f"BC violations found:\n{r.stdout}"


# ── T-11: all contexts have modules ──────────────────────────────────────────

@pytest.mark.parametrize("ctx", CONTEXTS.values(), ids=[c.id.value for c in CONTEXTS.values()])
def test_T11_context_has_modules(ctx):
    assert len(ctx.modules) >= 1, f"{ctx.id}: no modules declared"


# ── T-12: name and description non-empty ────────────────────────────────────

@pytest.mark.parametrize("ctx", CONTEXTS.values(), ids=[c.id.value for c in CONTEXTS.values()])
def test_T12_context_has_name_and_description(ctx):
    assert len(ctx.name) > 3
    assert len(ctx.description) > 10


# ── T-13: trust_zone valid ───────────────────────────────────────────────────

@pytest.mark.parametrize("ctx", CONTEXTS.values(), ids=[c.id.value for c in CONTEXTS.values()])
def test_T13_trust_zone_valid(ctx):
    assert ctx.trust_zone in ("GREEN", "AMBER", "RED")


# ── T-14: RED contexts have no allowed_dependencies ─────────────────────────

@pytest.mark.parametrize("ctx", CONTEXTS.values(), ids=[c.id.value for c in CONTEXTS.values()])
def test_T14_red_contexts_have_no_allowed_deps(ctx):
    if ctx.trust_zone == "RED":
        assert len(ctx.allowed_dependencies) == 0, (
            f"{ctx.id} (RED) should have no allowed_dependencies — "
            f"found: {ctx.allowed_dependencies}"
        )


# ── T-15: CTX-01 has most allowed deps ───────────────────────────────────────

def test_T15_ctx01_has_most_allowed_deps():
    ctx01_deps = len(CONTEXTS[ContextId.COMPLIANCE].allowed_dependencies)
    for ctx_id, ctx in CONTEXTS.items():
        if ctx_id != ContextId.COMPLIANCE:
            assert ctx01_deps >= len(ctx.allowed_dependencies), (
                f"CTX-01 should have >= allowed_dependencies vs {ctx_id}"
            )


# ── T-16..T-20: specific module lookups ──────────────────────────────────────

def test_T16_banxe_aml_orchestrator_is_ctx01():
    assert context_for_module("banxe_aml_orchestrator").id == ContextId.COMPLIANCE


def test_T17_soul_governance_is_ctx02():
    assert context_for_module("governance.soul_governance").id == ContextId.POLICY


def test_T18_event_store_is_ctx03():
    assert context_for_module("event_sourcing.event_store").id == ContextId.AUDIT


def test_T19_emergency_stop_is_ctx04():
    assert context_for_module("emergency_stop").id == ContextId.OPERATIONS


def test_T20_orchestration_tree_is_ctx05():
    assert context_for_module("agents.orchestration_tree").id == ContextId.AGENT_TRUST
