"""
OrchestrationTree — G-04 Trust Boundaries between Agents.

Implements the Orchestration Trust Model for the BANXE multi-agent
compliance stack.  Every agent-to-agent call is validated against the
registered descriptors before execution.

── Trust Levels ──────────────────────────────────────────────────────────
  Level 1  ORCHESTRATOR   top-level decision orchestrators
                          (banxe_aml_orchestrator)
  Level 2  SCREENING      domain screening engines
                          (tx_monitor, sanctions_check, crypto_aml, aml_orchestrator)
  Level 3  ADAPTER        external adapters — minimum privilege, port-only
                          (watchman, jube, yente, clickhouse_writer)

── Trust Zones ───────────────────────────────────────────────────────────
  GREEN   internal, fully trusted
  AMBER   internal, partially trusted  (audited + logged)
  RED     external, untrusted          (sandboxed, port-gated)

── Boundary Rules ────────────────────────────────────────────────────────
  B-01  Level-2 → Level-1  BLOCKED   upward call = lateral privilege escalation
  B-02  Level-3 → Level-1  BLOCKED
  B-03  Level-3 → Level-2  BLOCKED   adapters must call through Ports, not engines
  B-04  RED    → GREEN     BLOCKED   untrusted cannot directly access trusted zone
  B-05  AMBER  → GREEN     WARN      allowed but audited (logged, not blocked)
  B-06  any    → policy_write  BLOCKED for Level-2/3 (I-22 PolicyPort read-only)

── Design principle ──────────────────────────────────────────────────────
  Enforcement is additive — the PolicyPort ABC already makes I-22 a
  structural guarantee (no write methods exist).  OrchestrationTree adds
  a runtime layer that catches mis-wired call graphs before they reach
  the Port layer.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

TrustZone  = Literal["GREEN", "AMBER", "RED"]
AgentLevel = Literal[1, 2, 3]


# ── Descriptors ───────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class AgentDescriptor:
    """
    Immutable description of one agent in the orchestration tree.

    Attributes:
        agent_id     Unique identifier used as caller/callee key.
        level        1 = orchestrator, 2 = screening engine, 3 = external adapter.
        capabilities List of capability tokens this agent declares.
                     Capability "policy_write" is forbidden for Level 2/3 (I-22).
        trust_zone   Operational trust zone: GREEN / AMBER / RED.
    """
    agent_id:     str
    level:        AgentLevel
    capabilities: tuple[str, ...]  = field(default_factory=tuple)
    trust_zone:   TrustZone        = "GREEN"

    def has_capability(self, cap: str) -> bool:
        return cap in self.capabilities


@dataclass
class TrustViolation:
    """
    Records a single trust boundary violation.

    Attributes:
        caller_id  Agent that initiated the call.
        callee_id  Agent that was targeted.
        rule       Violation rule code (B-01 … B-06).
        message    Human-readable explanation.
        blocked    True = call must be aborted; False = warning only.
    """
    caller_id: str
    callee_id: str
    rule:      str
    message:   str
    blocked:   bool = True


class TrustBoundaryError(RuntimeError):
    """
    Raised when a blocked TrustViolation is detected and the caller
    invoked assert_call_allowed() or a method that enforces hard-block.
    """
    def __init__(self, violations: list[TrustViolation]) -> None:
        self.violations = violations
        rules = ", ".join(v.rule for v in violations)
        msgs  = "; ".join(v.message for v in violations)
        super().__init__(f"Trust boundary violation(s) [{rules}]: {msgs}")


# ── OrchestrationTree ─────────────────────────────────────────────────────────

class OrchestrationTree:
    """
    Registry and enforcement engine for agent trust boundaries.

    Typical usage — production singleton::

        tree = OrchestrationTree()
        tree.register(AgentDescriptor("banxe_aml_orchestrator", level=1, ...))
        tree.register(AgentDescriptor("aml_orchestrator",       level=2, ...))

        # Before calling _layer2_assess:
        tree.assert_call_allowed("banxe_aml_orchestrator", "aml_orchestrator")

    Typical usage — test::

        tree = OrchestrationTree()
        tree.register(AgentDescriptor("engine", level=2, trust_zone="GREEN"))
        tree.register(AgentDescriptor("orchestrator", level=1, trust_zone="GREEN"))
        violations = tree.check_call("engine", "orchestrator")
        assert violations[0].rule == "B-01"
    """

    def __init__(self) -> None:
        self._agents: dict[str, AgentDescriptor] = {}

    # ── registration ──────────────────────────────────────────────────────────

    def register(self, agent: AgentDescriptor) -> None:
        """Register an agent descriptor.  Re-registering the same agent_id
        overwrites the previous descriptor (idempotent for tests)."""
        self._agents[agent.agent_id] = agent

    def get(self, agent_id: str) -> AgentDescriptor | None:
        return self._agents.get(agent_id)

    def registered_ids(self) -> list[str]:
        return list(self._agents.keys())

    # ── boundary evaluation ───────────────────────────────────────────────────

    def check_call(
        self,
        caller_id: str,
        callee_id: str,
    ) -> list[TrustViolation]:
        """
        Evaluate all boundary rules for a proposed caller → callee call.

        Returns a (possibly empty) list of TrustViolation objects.
        Violations with ``blocked=True`` must abort the call.
        Violations with ``blocked=False`` are warnings (logged, not aborted).

        Unknown agent IDs are treated as Level-3, RED-zone for safety.
        """
        caller = self._agents.get(caller_id) or AgentDescriptor(
            agent_id=caller_id, level=3, trust_zone="RED"
        )
        callee = self._agents.get(callee_id) or AgentDescriptor(
            agent_id=callee_id, level=3, trust_zone="RED"
        )

        violations: list[TrustViolation] = []

        # B-01 / B-02: Level-2 or Level-3 cannot call Level-1
        if caller.level >= 2 and callee.level == 1:
            violations.append(TrustViolation(
                caller_id = caller_id,
                callee_id = callee_id,
                rule      = "B-01" if caller.level == 2 else "B-02",
                message   = (
                    f"Level-{caller.level} agent '{caller_id}' cannot call "
                    f"Level-1 orchestrator '{callee_id}' "
                    "(upward call = lateral privilege escalation)."
                ),
                blocked   = True,
            ))

        # B-03: Level-3 cannot call Level-2 (must go through Ports)
        if caller.level == 3 and callee.level == 2:
            violations.append(TrustViolation(
                caller_id = caller_id,
                callee_id = callee_id,
                rule      = "B-03",
                message   = (
                    f"Level-3 adapter '{caller_id}' cannot call Level-2 engine "
                    f"'{callee_id}' directly — use a Port interface."
                ),
                blocked   = True,
            ))

        # B-04: RED-zone caller cannot call GREEN-zone callee
        if caller.trust_zone == "RED" and callee.trust_zone == "GREEN":
            violations.append(TrustViolation(
                caller_id = caller_id,
                callee_id = callee_id,
                rule      = "B-04",
                message   = (
                    f"RED-zone agent '{caller_id}' cannot directly call "
                    f"GREEN-zone agent '{callee_id}' — untrusted to trusted boundary."
                ),
                blocked   = True,
            ))

        # B-05: AMBER-zone → GREEN-zone (warn, do not block)
        if caller.trust_zone == "AMBER" and callee.trust_zone == "GREEN":
            violations.append(TrustViolation(
                caller_id = caller_id,
                callee_id = callee_id,
                rule      = "B-05",
                message   = (
                    f"AMBER-zone agent '{caller_id}' is calling GREEN-zone "
                    f"agent '{callee_id}' — cross-zone call audited."
                ),
                blocked   = False,
            ))

        # B-06: Level-2/3 agents must not declare or use policy_write (I-22)
        if caller.level >= 2 and caller.has_capability("policy_write"):
            violations.append(TrustViolation(
                caller_id = caller_id,
                callee_id = callee_id,
                rule      = "B-06",
                message   = (
                    f"Level-{caller.level} agent '{caller_id}' declares "
                    "'policy_write' capability — forbidden by I-22 (PolicyPort read-only)."
                ),
                blocked   = True,
            ))

        return violations

    def can_call(self, caller_id: str, callee_id: str) -> bool:
        """Returns True only when no *blocking* violations exist."""
        return not any(v.blocked for v in self.check_call(caller_id, callee_id))

    def assert_call_allowed(self, caller_id: str, callee_id: str) -> list[TrustViolation]:
        """
        Check the call and raise TrustBoundaryError for any blocked violations.
        Warnings (blocked=False) are returned but do not raise.

        Returns the full list of violations (including non-blocking warnings).
        """
        violations = self.check_call(caller_id, callee_id)
        blocked    = [v for v in violations if v.blocked]
        if blocked:
            raise TrustBoundaryError(blocked)
        return violations

    # ── capability check ──────────────────────────────────────────────────────

    def check_capability(
        self,
        agent_id:   str,
        capability: str,
    ) -> TrustViolation | None:
        """
        Returns a TrustViolation if the agent is not allowed to use the
        requested capability, or None if it is allowed.

        Currently enforces B-06: policy_write forbidden for Level 2/3.
        """
        agent = self._agents.get(agent_id) or AgentDescriptor(
            agent_id=agent_id, level=3, trust_zone="RED"
        )
        if capability == "policy_write" and agent.level >= 2:
            return TrustViolation(
                caller_id = agent_id,
                callee_id = "PolicyPort",
                rule      = "B-06",
                message   = (
                    f"Level-{agent.level} agent '{agent_id}' requested "
                    "'policy_write' — forbidden by I-22 (PolicyPort is read-only)."
                ),
                blocked   = True,
            )
        return None


# ── Default production tree ───────────────────────────────────────────────────

_DEFAULT_TREE: OrchestrationTree | None = None


def get_default_tree() -> OrchestrationTree:
    """
    Singleton OrchestrationTree with all BANXE compliance stack agents
    pre-registered.  Call this from production code.

    Returns the same instance on every call (use a fresh OrchestrationTree()
    in tests to avoid state leakage).
    """
    global _DEFAULT_TREE
    if _DEFAULT_TREE is None:
        _DEFAULT_TREE = _build_default_tree()
    return _DEFAULT_TREE


def _build_default_tree() -> OrchestrationTree:
    tree = OrchestrationTree()

    # ── Level 1 — Orchestrators ───────────────────────────────────────────────
    tree.register(AgentDescriptor(
        agent_id     = "banxe_aml_orchestrator",
        level        = 1,
        capabilities = ("aml_assess", "orchestrate", "emit_decision"),
        trust_zone   = "GREEN",
    ))

    # ── Level 2 — Screening Engines ───────────────────────────────────────────
    tree.register(AgentDescriptor(
        agent_id     = "aml_orchestrator",
        level        = 2,
        capabilities = ("aml_screen",),
        trust_zone   = "GREEN",
    ))
    tree.register(AgentDescriptor(
        agent_id     = "tx_monitor",
        level        = 2,
        capabilities = ("tx_screen",),
        trust_zone   = "GREEN",
    ))
    tree.register(AgentDescriptor(
        agent_id     = "sanctions_check",
        level        = 2,
        capabilities = ("sanctions_screen",),
        trust_zone   = "GREEN",
    ))
    tree.register(AgentDescriptor(
        agent_id     = "crypto_aml",
        level        = 2,
        capabilities = ("crypto_screen",),
        trust_zone   = "GREEN",
    ))

    # ── Level 3 — External Adapters ───────────────────────────────────────────
    tree.register(AgentDescriptor(
        agent_id     = "watchman_adapter",
        level        = 3,
        capabilities = ("sanctions_lookup",),
        trust_zone   = "AMBER",
    ))
    tree.register(AgentDescriptor(
        agent_id     = "jube_adapter",
        level        = 3,
        capabilities = ("fraud_lookup",),
        trust_zone   = "AMBER",
    ))
    tree.register(AgentDescriptor(
        agent_id     = "yente_adapter",
        level        = 3,
        capabilities = ("pep_lookup",),
        trust_zone   = "AMBER",
    ))
    tree.register(AgentDescriptor(
        agent_id     = "clickhouse_writer",
        level        = 3,
        capabilities = ("audit_append",),
        trust_zone   = "GREEN",
    ))

    return tree
