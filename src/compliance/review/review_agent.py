"""
review_agent.py — G-15 Multi-Agent Review Pattern

Independent review agent that evaluates proposed changes before application.
Implements Plan > Build > Review pattern for the feedback pipeline.

Design:
    - ReviewAgent is independent of the "builder" — it never generated the change
    - Rule-based review: no LLM calls, deterministic, auditable
    - CLASS_B: automatic REJECT (requires human MLRO+CEO approval)
    - CLASS_C: automatic ESCALATE_TO_HUMAN (MLRO required)
    - CLASS_A: rule-based review against trust zones, invariants, BC boundaries
    - All review decisions logged append-only (I-24)

Integration:
    feedback_loop.py calls ReviewAgent.review(request) before applying a patch.
    If ReviewResult.recommendation == REJECT → patch is blocked.
    If ESCALATE_TO_HUMAN → held for human review queue.

Closes: GAP-REGISTER G-15
Invariants: I-21 (no auto-patch SOUL.md), I-22 (no policy write from L2/L3),
            I-24 (audit append-only)
Authority: EU AI Act Art. 14, FINOS AIGF v2.0
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

# ── Recommendation enum ────────────────────────────────────────────────────────

class Recommendation:
    APPROVE = "APPROVE"
    REJECT = "REJECT"
    ESCALATE_TO_HUMAN = "ESCALATE_TO_HUMAN"


# ── Change class constants ─────────────────────────────────────────────────────

# Match governance/change-classes.yaml keys
CLASS_A = "CLASS_A"       # Auto-approvable (code, tests, docs)
CLASS_B = "CLASS_B"       # Behavioral identity — NEVER auto-apply
CLASS_C = "CLASS_C"       # Policy/config — MLRO required
CLASS_D = "CLASS_D"       # Architecture — CEO+CTO required


# Files that belong to CLASS_B (behavioral identity)
_CLASS_B_FILES: frozenset[str] = frozenset({
    "SOUL.md", "AGENTS.md", "IDENTITY.md", "BOOTSTRAP.md",
    "openclaw.json",
})

# Files that belong to CLASS_C (compliance config)
_CLASS_C_PATTERNS: tuple[str, ...] = (
    "compliance_config.yaml",
    ".rego",
    "change-classes.yaml",
    "INVARIANTS.md",
)

# Files that belong to CLASS_D (architecture)
_CLASS_D_PATTERNS: tuple[str, ...] = (
    "ADR-",
    "GAP-REGISTER.md",
    "trust-zones.yaml",
    "context-map.yaml",
    "/schemas/",
)

# Policy layer paths (I-22: no write from L2/L3)
_POLICY_LAYER_PATHS: tuple[str, ...] = (
    "developer-core/compliance/",
    "src/compliance/verification/",
    "banxe-architecture/",
)

# Bounded context import patterns (simplified — warns on cross-context writes)
_BC_BOUNDARY_PATTERNS: dict[str, list[str]] = {
    "CTX-01": ["src/compliance/"],
    "CTX-03": ["src/compliance/event_sourcing/", "src/compliance/utils/decision_event_log.py"],
    "CTX-04": ["src/compliance/utils/", "src/compliance/api.py"],
}


# ── Request / Result dataclasses ──────────────────────────────────────────────

@dataclass
class ReviewRequest:
    """
    A proposed change to be reviewed.

    Fields:
        proposed_change:  Diff text or description of the change
        change_class:     CLASS_A | CLASS_B | CLASS_C | CLASS_D (or None for auto-detect)
        author_agent_id:  The agent that produced the change
        target_file:      File path being modified
        rationale:        Why this change is needed
        author_level:     Trust level of author (1/2/3), default 2
        context:          Extra context (e.g. {"amount_gbp": 5000})
    """
    proposed_change: str
    author_agent_id: str
    target_file: str
    rationale: str = ""
    change_class: str | None = None   # None → auto-detected
    author_level: int = 2
    context: dict[str, Any] = field(default_factory=dict)


@dataclass
class ReviewResult:
    """
    Result of a review by ReviewAgent.

    Fields:
        approved:           True iff recommendation is APPROVE
        reviewer_agent_id:  Identity of the review agent
        concerns:           List of concern messages (empty if approved cleanly)
        risk_score:         0–100 (>50 → escalate, >80 → block)
        recommendation:     APPROVE | REJECT | ESCALATE_TO_HUMAN
        resolved_class:     The change class used for the decision
    """
    approved: bool
    reviewer_agent_id: str
    concerns: list[str]
    risk_score: int
    recommendation: str
    resolved_class: str = CLASS_A


# ── ReviewAgent ────────────────────────────────────────────────────────────────

class ReviewAgent:
    """
    Independent rule-based review agent.

    Usage:
        agent = ReviewAgent()
        result = agent.review(ReviewRequest(
            proposed_change=diff,
            author_agent_id="feedback_agent",
            target_file="src/compliance/banxe_aml_orchestrator.py",
        ))
        if result.recommendation == Recommendation.REJECT:
            raise ValueError(f"Change blocked: {result.concerns}")
    """

    REVIEWER_AGENT_ID = "review_agent_v1"
    HIGH_RISK_ESCALATION_THRESHOLD = 50
    AUTO_REJECT_THRESHOLD = 80

    def __init__(self) -> None:
        self._logger = self._build_logger()

    @staticmethod
    def _build_logger():
        try:
            from compliance.utils.structured_logger import StructuredLogger
            return StructuredLogger("review_agent")
        except Exception:
            return None

    def _log(self, event_type: str, payload: dict) -> None:
        if self._logger is not None:
            try:
                self._logger.event(event_type=event_type, payload=payload)
            except Exception:
                pass

    def review(self, request: ReviewRequest) -> ReviewResult:
        """
        Review a proposed change and return a ReviewResult.

        Decision logic:
            CLASS_B → automatic REJECT (MLRO+CEO required)
            CLASS_C → automatic ESCALATE_TO_HUMAN
            CLASS_D → automatic REJECT (CEO+CTO required)
            CLASS_A → rule-based: check invariants, trust zones, BC boundaries
                      risk_score > 50 → ESCALATE_TO_HUMAN
                      risk_score > 80 → REJECT

        All decisions are logged (I-24 append-only).
        """
        concerns: list[str] = []
        risk_score = 0

        # Step 1: Resolve change class
        resolved_class = request.change_class or self._detect_change_class(request.target_file)

        # Step 2: Class-based hard gates
        if resolved_class in (CLASS_B, CLASS_D):
            concerns.append(
                f"{resolved_class} change to '{request.target_file}' requires human approval "
                f"(MLRO+CEO). Auto-apply is NEVER permitted."
            )
            result = ReviewResult(
                approved=False,
                reviewer_agent_id=self.REVIEWER_AGENT_ID,
                concerns=concerns,
                risk_score=100,
                recommendation=Recommendation.REJECT,
                resolved_class=resolved_class,
            )
            self._audit_log(request, result)
            return result

        if resolved_class == CLASS_C:
            concerns.append(
                f"CLASS_C change to '{request.target_file}' requires MLRO review. "
                f"Escalating to human review queue."
            )
            result = ReviewResult(
                approved=False,
                reviewer_agent_id=self.REVIEWER_AGENT_ID,
                concerns=concerns,
                risk_score=75,
                recommendation=Recommendation.ESCALATE_TO_HUMAN,
                resolved_class=resolved_class,
            )
            self._audit_log(request, result)
            return result

        # Step 3: CLASS_A rule-based checks
        risk_score, concerns = self._rule_based_review(request, concerns)

        # Step 4: Map risk score to recommendation
        if risk_score > self.AUTO_REJECT_THRESHOLD:
            recommendation = Recommendation.REJECT
            approved = False
        elif risk_score > self.HIGH_RISK_ESCALATION_THRESHOLD:
            recommendation = Recommendation.ESCALATE_TO_HUMAN
            approved = False
        else:
            recommendation = Recommendation.APPROVE
            approved = len(concerns) == 0

        result = ReviewResult(
            approved=approved,
            reviewer_agent_id=self.REVIEWER_AGENT_ID,
            concerns=concerns,
            risk_score=risk_score,
            recommendation=recommendation,
            resolved_class=resolved_class,
        )
        self._audit_log(request, result)
        return result

    # ── Change class detection ─────────────────────────────────────────────────

    @staticmethod
    def _detect_change_class(target_file: str) -> str:
        """Auto-detect change class from target file path/name."""
        filename = target_file.split("/")[-1] if "/" in target_file else target_file

        # CLASS_B: behavioral identity files
        if filename in _CLASS_B_FILES:
            return CLASS_B

        # CLASS_C: policy/config files
        for pattern in _CLASS_C_PATTERNS:
            if pattern in target_file:
                return CLASS_C

        # CLASS_D: architecture files
        for pattern in _CLASS_D_PATTERNS:
            if pattern in target_file:
                return CLASS_D

        return CLASS_A

    # ── Rule-based review ──────────────────────────────────────────────────────

    def _rule_based_review(
        self,
        request: ReviewRequest,
        concerns: list[str],
    ) -> tuple[int, list[str]]:
        """Run all CLASS_A rules. Returns (risk_score, concerns)."""
        risk_score = 0
        concerns = list(concerns)  # copy

        # I-21: no auto-patch of SOUL.md (extra guard beyond class detection)
        risk_score, concerns = self._check_i21(request, risk_score, concerns)

        # I-22: no policy write from L2/L3
        risk_score, concerns = self._check_i22(request, risk_score, concerns)

        # Trust zone: check zone constraints
        risk_score, concerns = self._check_trust_zone(request, risk_score, concerns)

        # BC boundaries: check for cross-context write
        risk_score, concerns = self._check_bc_boundary(request, risk_score, concerns)

        # Rationale presence check
        if not request.rationale.strip():
            concerns.append("No rationale provided for this change.")
            risk_score += 10

        return risk_score, concerns

    @staticmethod
    def _check_i21(
        request: ReviewRequest,
        risk_score: int,
        concerns: list[str],
    ) -> tuple[int, list[str]]:
        """I-21: Level-2/3 agents cannot auto-patch behavioral identity."""
        identity_keywords = ("SOUL", "AGENTS", "IDENTITY", "BOOTSTRAP")
        for kw in identity_keywords:
            if kw in request.target_file.upper():
                concerns.append(
                    f"I-21 violation: '{request.target_file}' appears to be a behavioral "
                    f"identity document. Auto-patching by agent '{request.author_agent_id}' "
                    f"is not permitted. Use protect-soul.sh update after CEO+MLRO approval."
                )
                risk_score += 90
                break
        return risk_score, concerns

    @staticmethod
    def _check_i22(
        request: ReviewRequest,
        risk_score: int,
        concerns: list[str],
    ) -> tuple[int, list[str]]:
        """I-22: Level-2/3 agents cannot write to policy layer."""
        if request.author_level not in (2, 3):
            return risk_score, concerns
        for path_prefix in _POLICY_LAYER_PATHS:
            if request.target_file.startswith(path_prefix):
                concerns.append(
                    f"I-22 violation: Level-{request.author_level} agent "
                    f"'{request.author_agent_id}' cannot write to policy layer path "
                    f"'{request.target_file}'. Policy layer is write-restricted."
                )
                risk_score += 85
                break
        return risk_score, concerns

    @staticmethod
    def _check_trust_zone(
        request: ReviewRequest,
        risk_score: int,
        concerns: list[str],
    ) -> tuple[int, list[str]]:
        """Trust zone: RED zone files require GOVERNANCE_BYPASS."""
        red_zone_patterns = (
            "SOUL.md", "IDENTITY.md", "BOOTSTRAP.md",
            "compliance_config.yaml", ".rego",
            "change-classes.yaml", "INVARIANTS.md",
            "trust-zones.yaml", "ADR-",
        )
        for pattern in red_zone_patterns:
            if pattern in request.target_file:
                concerns.append(
                    f"Trust zone violation: '{request.target_file}' is in Zone RED. "
                    f"Changes require GOVERNANCE_BYPASS=1 and explicit human approval."
                )
                risk_score += 70
                break
        return risk_score, concerns

    @staticmethod
    def _check_bc_boundary(
        request: ReviewRequest,
        risk_score: int,
        concerns: list[str],
    ) -> tuple[int, list[str]]:
        """BC boundaries: warn if proposed_change imports across forbidden boundaries."""
        # Simplified: detect cross-context imports in diff text
        audit_ctx_pattern = r"from compliance\.event_sourcing|from compliance\.utils\.decision_event_log"
        decision_ctx_pattern = r"from compliance\.(?:banxe_aml_orchestrator|aml_orchestrator)"

        if re.search(audit_ctx_pattern, request.proposed_change):
            # Audit context (CTX-03) should not be imported by non-operations code
            if "event_sourcing" not in request.target_file and "utils" not in request.target_file:
                concerns.append(
                    "BC boundary warning: proposed change imports from CTX-03 (Audit) "
                    "into a non-audit module. Verify bounded context rules."
                )
                risk_score += 20

        if re.search(decision_ctx_pattern, request.proposed_change):
            # Decision context (CTX-01) should not be imported by adapters directly
            if "adapters" in request.target_file:
                concerns.append(
                    "BC boundary warning: adapter directly imports from CTX-01 (Decision Engine). "
                    "Use Port interfaces instead."
                )
                risk_score += 25

        return risk_score, concerns

    # ── Audit logging ──────────────────────────────────────────────────────────

    def _audit_log(self, request: ReviewRequest, result: ReviewResult) -> None:
        """Log review decision append-only (I-24)."""
        self._log("REVIEW_DECISION", {
            "author_agent_id": request.author_agent_id,
            "target_file": request.target_file,
            "change_class": result.resolved_class,
            "recommendation": result.recommendation,
            "risk_score": result.risk_score,
            "concerns_count": len(result.concerns),
        })
