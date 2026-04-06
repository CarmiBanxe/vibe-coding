"""
registry.py — Bounded Context Registry (G-18)

Defines the 5 bounded contexts for BANXE compliance stack.
Each context declares its modules, ports, allowed/forbidden dependencies,
and trust zone. Used by validate_contexts.py for CI enforcement.

Cross-referenced with: banxe-architecture/domain/context-map.yaml
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Literal


class ContextId(str, Enum):
    COMPLIANCE      = "CTX-01"
    POLICY          = "CTX-02"
    AUDIT           = "CTX-03"
    OPERATIONS      = "CTX-04"
    AGENT_TRUST     = "CTX-05"


@dataclass(frozen=True)
class BoundedContext:
    id:          ContextId
    name:        str
    type:        Literal["core_domain", "supporting_domain", "generic_subdomain"]
    trust_zone:  Literal["GREEN", "AMBER", "RED"]
    description: str
    # Python module paths (relative to src/compliance/)
    modules:              tuple[str, ...]
    test_modules:         tuple[str, ...]
    # Context IDs this context is allowed to import from
    allowed_dependencies: tuple[ContextId, ...]
    # Context IDs this context must NEVER import from
    forbidden_dependencies: tuple[ContextId, ...]
    # Port interfaces (for documentation)
    ports_provided:  tuple[str, ...] = field(default_factory=tuple)
    ports_consumed:  tuple[str, ...] = field(default_factory=tuple)


# ── CTX-01: Compliance / Decision Engine ──────────────────────────────────────
CTX_COMPLIANCE = BoundedContext(
    id=ContextId.COMPLIANCE,
    name="Compliance / Decision Engine",
    type="core_domain",
    trust_zone="AMBER",
    description=(
        "Orchestrates all risk-scoring sub-agents and produces BanxeAMLResult. "
        "Enforces I-21..I-25. All P1 invariants live here."
    ),
    modules=(
        "banxe_aml_orchestrator",
        "aml_orchestrator",
        "tx_monitor",
        "sanctions_check",
        "crypto_aml",
        "pep_check",
        "adverse_media",
        "kyb_check",
        "doc_verify",
        "legal_databases",
        "models",
        # structured_logger is a shared kernel — used primarily by Decision Engine
        # CTX-04 may also use it via the same package path (shared infrastructure)
        "utils.structured_logger",
    ),
    test_modules=(
        "test_phase15",
        "test_explanation_bundle",
        "test_orchestration_tree",
    ),
    allowed_dependencies=(ContextId.POLICY, ContextId.AUDIT, ContextId.AGENT_TRUST),
    forbidden_dependencies=(ContextId.OPERATIONS,),
    ports_provided=("DecisionPort",),
    ports_consumed=("PolicyPort", "AuditPort", "EmergencyPort"),
)

# ── CTX-02: Policy Context ─────────────────────────────────────────────────────
CTX_POLICY = BoundedContext(
    id=ContextId.POLICY,
    name="Policy Context",
    type="supporting_domain",
    trust_zone="RED",
    description=(
        "Source of truth for thresholds, rules, change classes. "
        "CLASS_C governance: changes require MLRO|CEO approval."
    ),
    modules=(
        "governance.soul_governance",
        "governance.change_classes",
        "utils.config_loader",
        "utils.rego_evaluator",
        # config file: compliance_config.yaml
        # rego file: policies/banxe_compliance.rego
    ),
    test_modules=(
        "test_config_loader",
        "test_rego_evaluator",
        "test_soul_governance",
    ),
    allowed_dependencies=(),
    forbidden_dependencies=(
        ContextId.COMPLIANCE,
        ContextId.AUDIT,
        ContextId.OPERATIONS,
        ContextId.AGENT_TRUST,
    ),
    ports_provided=("PolicyPort",),
    ports_consumed=(),
)

# ── CTX-03: Audit Context ──────────────────────────────────────────────────────
CTX_AUDIT = BoundedContext(
    id=ContextId.AUDIT,
    name="Audit Context",
    type="supporting_domain",
    trust_zone="RED",
    description=(
        "Immutable event store. CQRS read models for MLRO review and FCA audit. "
        "Append-only enforced at DB level (I-24)."
    ),
    modules=(
        "event_sourcing.event_store",
        "event_sourcing.projections",
        "event_sourcing.projector",
        "utils.decision_event_log",
        "audit_trail",
    ),
    test_modules=(
        "test_decision_event_log",
        "test_event_sourcing",
    ),
    allowed_dependencies=(),
    forbidden_dependencies=(
        ContextId.COMPLIANCE,
        ContextId.POLICY,
        ContextId.OPERATIONS,
        ContextId.AGENT_TRUST,
    ),
    ports_provided=("AuditPort",),
    ports_consumed=(),
)

# ── CTX-04: Operations Context ─────────────────────────────────────────────────
CTX_OPERATIONS = BoundedContext(
    id=ContextId.OPERATIONS,
    name="Operations Context",
    type="supporting_domain",
    trust_zone="GREEN",
    description=(
        "Circuit-breakers, admin dashboard, REST API, structured logging, "
        "deployment tooling. Never writes to Audit context."
    ),
    modules=(
        "emergency_stop",
        "api",
        "dashboard",
        "verify_api",
        # utils.structured_logger is a shared kernel owned by CTX-01
        # CTX-04 may consume it without violating boundaries (cross-cutting concern)
    ),
    test_modules=(
        "test_emergency_stop",
        "test_api_integration",
    ),
    allowed_dependencies=(ContextId.AUDIT,),
    forbidden_dependencies=(ContextId.POLICY,),
    ports_provided=("EmergencyPort",),
    ports_consumed=("EmergencyPort",),
)

# ── CTX-05: Agent Trust Context ────────────────────────────────────────────────
CTX_AGENT_TRUST = BoundedContext(
    id=ContextId.AGENT_TRUST,
    name="Agent Trust Context",
    type="generic_subdomain",
    trust_zone="AMBER",
    description=(
        "Orchestration tree, trust boundary rules, agent descriptors (B-01..B-06). "
        "Enforces I-22 (no policy_write for L2/L3). Called by CTX-01 before delegation."
    ),
    modules=(
        "agents.orchestration_tree",
    ),
    test_modules=(
        "test_orchestration_tree",
    ),
    allowed_dependencies=(ContextId.COMPLIANCE,),
    forbidden_dependencies=(ContextId.POLICY, ContextId.AUDIT, ContextId.OPERATIONS),
    ports_provided=("TrustBoundaryPort",),
    ports_consumed=(),
)


# ── Canonical registry ─────────────────────────────────────────────────────────
CONTEXTS: dict[ContextId, BoundedContext] = {
    ContextId.COMPLIANCE:   CTX_COMPLIANCE,
    ContextId.POLICY:       CTX_POLICY,
    ContextId.AUDIT:        CTX_AUDIT,
    ContextId.OPERATIONS:   CTX_OPERATIONS,
    ContextId.AGENT_TRUST:  CTX_AGENT_TRUST,
}


def context_for_module(module_path: str) -> BoundedContext | None:
    """Return the BoundedContext that owns the given module path, or None."""
    for ctx in CONTEXTS.values():
        if module_path in ctx.modules or module_path in ctx.test_modules:
            return ctx
    return None


def allowed_imports(from_ctx: ContextId, to_ctx: ContextId) -> bool:
    """Return True if from_ctx is allowed to import from to_ctx."""
    ctx = CONTEXTS[from_ctx]
    if to_ctx in ctx.forbidden_dependencies:
        return False
    # Shared ports/adapters are always allowed (ports/ and adapters/ are shared kernel)
    return True
