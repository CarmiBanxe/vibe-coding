"""
rego_evaluator.py — G-19: Python enforcement of banxe.rego invariants.

Implements the same rules as policies/banxe_compliance.rego in pure Python.
No OPA binary required — this IS the executable enforcement for Sprint 2.

When OPA sidecar is deployed (Sprint 3 / G-14), this module will delegate
to OPA REST API (http://localhost:8181/v1/data/banxe/compliance/deny)
and fall back to Python evaluation if OPA is unavailable.

Design:
  - Fail-OPEN on OPA unavailability (never block because of infra issue)
  - Python evaluator: fail-CLOSED on invariant violations (block is correct)
  - All violations logged to structured audit log (G-20)

Input:
    PolicyInput dataclass — mirrors the Rego input shape

Output:
    list[PolicyViolation] — empty = allow; non-empty = at least one rule fired

Closes: GAP-REGISTER G-19
Invariants: I-21, I-22, I-23, I-25
Authority: FINOS AIGF v2.0, EU AI Act Art. 14, FCA MLR 2017
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Optional

from compliance.utils.config_loader import get_mlr_reporting_threshold_gbp

log = logging.getLogger(__name__)

# Protected path prefixes (mirrors banxe_compliance.rego)
_POLICY_LAYER_PREFIXES = (
    "developer-core/compliance/",
    "src/compliance/verification/",
)

_BEHAVIORAL_IDENTITY_FILES = (
    "SOUL.md",
    "AGENTS.md",
    "IDENTITY.md",
    "BOOTSTRAP.md",
)

_TRANSACTION_ACTIONS = frozenset({
    "approve_transaction",
    "hold_transaction",
    "reject_transaction",
    "file_sar",
})


# ── Input / Output contracts ──────────────────────────────────────────────────

@dataclass
class PolicyInput:
    """
    Input to the Rego evaluator — mirrors the Rego input object.

    Fields correspond 1:1 to the Rego spec in policies/banxe_compliance.rego.
    """
    agent_level:               int    = 1        # 0=MLRO, 1=Orchestrator, 2=L2, 3=Feedback
    agent_id:                  str    = "unknown"
    action:                    str    = ""        # approve_transaction | hold_transaction | ...
    target_path:               str    = ""        # for write_file actions
    target_repo:               str    = ""        # for git_push / git_commit actions
    mlro_approved:             bool   = False
    amount_gbp:                float  = 0.0
    explanation_bundle_present: bool  = False
    emergency_stop_checked:    bool   = False
    decision:                  str    = ""        # APPROVE | HOLD | REJECT | SAR


@dataclass
class PolicyViolation:
    """
    A single fired deny rule from the Rego evaluator.

    invariant: which BANXE invariant was violated (I-21, I-22, I-23, I-25, or "GOVERNANCE")
    rule:      machine-readable rule identifier
    message:   human-readable message (same text as the Rego deny message)
    severity:  CRITICAL | ERROR | WARNING
    blocked:   True = execution MUST stop; False = log only
    """
    invariant: str
    rule:      str
    message:   str
    severity:  str   = "CRITICAL"
    blocked:   bool  = True


# ── Evaluator ─────────────────────────────────────────────────────────────────

def evaluate(inp: PolicyInput) -> list[PolicyViolation]:
    """
    Evaluate all banxe.compliance Rego rules against the input.

    Returns [] if all rules pass (allow=True).
    Returns one PolicyViolation per fired deny rule.

    Corresponds to OPA query:
        POST /v1/data/banxe/compliance/deny
        {"input": {...}}
    """
    violations: list[PolicyViolation] = []
    _rule_i22(inp, violations)
    _rule_i21_write(inp, violations)
    _rule_i21_push(inp, violations)
    _rule_i23(inp, violations)
    _rule_i25(inp, violations)
    _rule_sar_submit(inp, violations)
    return violations


def evaluate_dict(inp: dict) -> list[PolicyViolation]:
    """Convenience wrapper — accepts a plain dict and coerces to PolicyInput."""
    return evaluate(PolicyInput(**{
        k: inp[k] for k in PolicyInput.__dataclass_fields__ if k in inp
    }))


def is_allowed(inp: PolicyInput) -> bool:
    """Returns True if no deny rules fired (mirrors Rego `allow` default)."""
    return len(evaluate(inp)) == 0


# ── Individual rules (mirror Rego deny blocks 1:1) ────────────────────────────

def _rule_i22(inp: PolicyInput, out: list[PolicyViolation]) -> None:
    """I-22: Level 2 agent cannot write to policy layer."""
    if inp.agent_level != 2:
        return
    if inp.action != "write_file":
        return
    for prefix in _POLICY_LAYER_PREFIXES:
        if inp.target_path.startswith(prefix):
            out.append(PolicyViolation(
                invariant = "I-22",
                rule      = "L2_POLICY_LAYER_WRITE",
                message   = (
                    f"BLOCKED [I-22]: Agent '{inp.agent_id}' (level 2) cannot write "
                    f"to policy layer. Path: {inp.target_path} — "
                    f"Policy layer is write-restricted to developer terminal only. "
                    f"Authority: NCC Group Orchestration Tree, GAP-REGISTER G-04."
                ),
                severity  = "CRITICAL",
                blocked   = True,
            ))
            return   # one violation per rule (don't double-fire on multiple prefix matches)


def _rule_i21_write(inp: PolicyInput, out: list[PolicyViolation]) -> None:
    """I-21: Level 2/3 agent cannot write to behavioral identity docs."""
    if inp.agent_level not in (2, 3):
        return
    if inp.action != "write_file":
        return
    for fname in _BEHAVIORAL_IDENTITY_FILES:
        if fname in inp.target_path:
            out.append(PolicyViolation(
                invariant = "I-21",
                rule      = "FEEDBACK_IDENTITY_DOC_WRITE",
                message   = (
                    f"BLOCKED [I-21]: Agent '{inp.agent_id}' (level {inp.agent_level}) "
                    f"cannot write to behavioral identity doc '{fname}'. "
                    f"Use protect-soul.sh update after MLRO+CTO approval. "
                    f"Authority: governance/change-classes.yaml CLASS_B_SOUL_AGENTS."
                ),
                severity  = "CRITICAL",
                blocked   = True,
            ))
            return


def _rule_i21_push(inp: PolicyInput, out: list[PolicyViolation]) -> None:
    """I-21 extension: Feedback Agent (level 3) cannot push to developer-core."""
    if inp.agent_level != 3:
        return
    if inp.action not in ("git_push", "git_commit"):
        return
    if "developer-core" in inp.target_repo:
        out.append(PolicyViolation(
            invariant = "I-21",
            rule      = "FEEDBACK_DEVCORE_PUSH",
            message   = (
                f"BLOCKED [I-21]: Feedback Agent '{inp.agent_id}' cannot push to "
                f"developer-core. Propose patch via PR + Level 0 approval. "
                f"Authority: governance/change-classes.yaml CLASS_B_SOUL_AGENTS."
            ),
            severity  = "CRITICAL",
            blocked   = True,
        ))


def _rule_i23(inp: PolicyInput, out: list[PolicyViolation]) -> None:
    """I-23: Emergency stop must be checked before any automated decision."""
    if inp.action not in _TRANSACTION_ACTIONS:
        return
    if not inp.emergency_stop_checked:
        out.append(PolicyViolation(
            invariant = "I-23",
            rule      = "EMERGENCY_STOP_NOT_CHECKED",
            message   = (
                f"BLOCKED [I-23]: Emergency stop state not verified before automated "
                f"decision '{inp.action}' by agent '{inp.agent_id}'. "
                f"HTTP 503 must be returned if stop is active. "
                f"Authority: EU AI Act Art. 14(4)(e), GAP-REGISTER G-03."
            ),
            severity  = "CRITICAL",
            blocked   = True,
        ))


def _rule_i25(inp: PolicyInput, out: list[PolicyViolation]) -> None:
    """I-25: ExplanationBundle required for decisions > £10,000."""
    if inp.action not in _TRANSACTION_ACTIONS:
        return
    threshold = get_mlr_reporting_threshold_gbp()
    if inp.amount_gbp <= threshold:
        return
    if not inp.explanation_bundle_present:
        out.append(PolicyViolation(
            invariant = "I-25",
            rule      = "EXPLANATION_BUNDLE_ABSENT",
            message   = (
                f"BLOCKED [I-25]: ExplanationBundle absent for decision '{inp.action}' "
                f"on £{inp.amount_gbp:,.0f} transaction by agent '{inp.agent_id}'. "
                f"Required for amounts > £{threshold:,}. "
                f"Authority: FCA SS1/23, UK GDPR Art. 22, FCA PS7/24."
            ),
            severity  = "CRITICAL",
            blocked   = True,
        ))


def _rule_sar_submit(inp: PolicyInput, out: list[PolicyViolation]) -> None:
    """SAR NCA submission requires explicit MLRO approval."""
    if inp.action != "submit_sar":
        return
    if not inp.mlro_approved:
        out.append(PolicyViolation(
            invariant = "GOVERNANCE",
            rule      = "SAR_SUBMIT_WITHOUT_MLRO",
            message   = (
                f"BLOCKED: SAR NCA submission by agent '{inp.agent_id}' requires "
                f"mlro_approved=true. "
                f"Authority: POCA 2002 §330, FCA MLR 2017 §19."
            ),
            severity  = "CRITICAL",
            blocked   = True,
        ))


# ── OPA REST API client (Sprint 3, fail-open fallback) ───────────────────────

async def evaluate_via_opa(
    inp: PolicyInput,
    opa_url: str = "http://127.0.0.1:8181",
    timeout: float = 0.5,
) -> list[PolicyViolation]:
    """
    Delegate evaluation to OPA REST API (Sprint 3 / G-14).
    Falls back to Python evaluator if OPA is unavailable (fail-open on infra).

    OPA query: POST {opa_url}/v1/data/banxe/compliance/deny
    """
    try:
        import aiohttp
        payload = {"input": {
            "agent_level":               inp.agent_level,
            "agent_id":                  inp.agent_id,
            "action":                    inp.action,
            "target_path":               inp.target_path,
            "target_repo":               inp.target_repo,
            "mlro_approved":             inp.mlro_approved,
            "amount_gbp":                inp.amount_gbp,
            "explanation_bundle_present": inp.explanation_bundle_present,
            "emergency_stop_checked":    inp.emergency_stop_checked,
            "decision":                  inp.decision,
        }}
        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"{opa_url}/v1/data/banxe/compliance/deny",
                json=payload,
                timeout=aiohttp.ClientTimeout(total=timeout),
            ) as resp:
                data = await resp.json()
                deny_messages = data.get("result", [])
                return [
                    PolicyViolation(
                        invariant = _extract_invariant(msg),
                        rule      = "OPA_DENY",
                        message   = msg,
                        severity  = "CRITICAL",
                        blocked   = True,
                    )
                    for msg in deny_messages
                ]
    except Exception as e:
        log.warning(
            "rego_evaluator: OPA unavailable (%s) — falling back to Python evaluator",
            type(e).__name__,
        )
        return evaluate(inp)   # Python fallback


def _extract_invariant(opa_message: str) -> str:
    """Extract invariant ID from OPA deny message (e.g. 'BLOCKED [I-22]: ...' → 'I-22')."""
    import re
    m = re.search(r"\[([A-Z0-9-]+)\]", opa_message)
    return m.group(1) if m else "UNKNOWN"


# ── Convenience: build PolicyInput from BanxeAMLResult ───────────────────────

def input_from_banxe_result(
    result,                           # BanxeAMLResult
    *,
    amount_gbp: float = 0.0,
    emergency_stop_checked: bool = True,
    agent_id: str = "banxe_aml_orchestrator",
) -> PolicyInput:
    """
    Build a PolicyInput from a BanxeAMLResult for post-decision invariant check.
    Used in banxe_aml_orchestrator.banxe_assess() after building the result.
    """
    _DECISION_TO_ACTION = {
        "APPROVE": "approve_transaction",
        "HOLD":    "hold_transaction",
        "REJECT":  "reject_transaction",
        "SAR":     "file_sar",
    }
    return PolicyInput(
        agent_level               = 1,    # Orchestrator
        agent_id                  = agent_id,
        action                    = _DECISION_TO_ACTION.get(result.decision, "approve_transaction"),
        amount_gbp                = amount_gbp,
        explanation_bundle_present = result.explanation is not None,
        emergency_stop_checked    = emergency_stop_checked,
        mlro_approved             = False,  # not applicable for detection step
        decision                  = result.decision,
    )
