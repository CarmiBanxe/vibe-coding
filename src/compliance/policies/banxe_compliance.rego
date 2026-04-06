# banxe_compliance.rego — G-19: OPA/Rego Controls-as-Code
#
# Package:  banxe.compliance
# Status:   PRODUCTION SPEC (Python evaluator is executable enforcement now;
#           OPA sidecar deferred to Sprint 3 — GAP-REGISTER G-14)
#
# Invariants enforced:
#   I-21 — feedback_loop.py NEVER auto-writes SOUL.md/AGENTS.md
#   I-22 — Level 2 agents cannot write to policy layer (developer-core/compliance/)
#   I-23 — Emergency stop must be checked before any automated decision
#   I-24 — Decision Event Log: no UPDATE/DELETE (DB-level, informational here)
#   I-25 — ExplanationBundle required for decisions on tx > £10,000
#
# Input shape (from banxe_aml_orchestrator and any agent call):
#   input.agent_level              : int    (0=MLRO, 1=Orchestrator, 2=L2, 3=Feedback)
#   input.agent_id                 : string ("banxe_aml_orchestrator", "kyc_agent", ...)
#   input.action                   : string (see ACTIONS below)
#   input.target_path              : string (filesystem path, if action=write_file)
#   input.target_repo              : string (repo name, if action=git_push)
#   input.mlro_approved            : bool
#   input.amount_gbp               : float  (0 if not a transaction decision)
#   input.explanation_bundle_present: bool
#   input.emergency_stop_checked   : bool
#   input.decision                 : string (APPROVE|HOLD|REJECT|SAR)
#
# ACTIONS vocabulary:
#   write_file, git_push, git_commit
#   approve_transaction, hold_transaction, reject_transaction, file_sar, submit_sar
#
# Authority: FINOS AIGF v2.0, EU AI Act Art. 14, FCA MLR 2017
# Sprint:    2 (Python evaluator), 3 (OPA sidecar), 4 (full enforcement)
# ──────────────────────────────────────────────────────────────────────────────

package banxe.compliance

import future.keywords.if
import future.keywords.in

# ── Protected paths ────────────────────────────────────────────────────────────

policy_layer_prefixes := [
    "developer-core/compliance/",
    "src/compliance/verification/",
]

behavioral_identity_files := [
    "SOUL.md",
    "AGENTS.md",
    "IDENTITY.md",
    "BOOTSTRAP.md",
]

transaction_actions := {
    "approve_transaction",
    "hold_transaction",
    "reject_transaction",
    "file_sar",
}

# EDD / I-25 threshold — mirrors compliance_config.yaml decision_thresholds
i25_amount_threshold_gbp := 10000


# ── I-22: Level 2 agent → policy layer write (BLOCKED) ───────────────────────

deny contains msg if {
    input.agent_level == 2
    input.action == "write_file"
    some prefix in policy_layer_prefixes
    startswith(input.target_path, prefix)
    msg := sprintf(
        "BLOCKED [I-22]: Agent '%v' (level 2) cannot write to policy layer. Path: %v — " +
        "Policy layer is write-restricted to developer terminal only. " +
        "Authority: NCC Group Orchestration Tree, GAP-REGISTER G-04.",
        [input.agent_id, input.target_path],
    )
}


# ── I-21: Level 2/3 agent → behavioral identity docs (BLOCKED) ───────────────

deny contains msg if {
    input.agent_level in {2, 3}
    input.action == "write_file"
    some fname in behavioral_identity_files
    contains(input.target_path, fname)
    msg := sprintf(
        "BLOCKED [I-21]: Agent '%v' (level %v) cannot write to behavioral identity doc '%v'. " +
        "Use protect-soul.sh update after MLRO+CTO approval. " +
        "Authority: governance/change-classes.yaml CLASS_B_SOUL_AGENTS.",
        [input.agent_id, input.agent_level, fname],
    )
}


# ── I-21 (extension): Feedback Agent cannot push to developer-core ────────────

deny contains msg if {
    input.agent_level == 3
    input.action in {"git_push", "git_commit"}
    contains(input.target_repo, "developer-core")
    msg := sprintf(
        "BLOCKED [I-21]: Feedback Agent '%v' cannot push to developer-core. " +
        "Propose patch via PR + Level 0 approval. " +
        "Authority: governance/change-classes.yaml CLASS_B_SOUL_AGENTS.",
        [input.agent_id],
    )
}


# ── I-23: Emergency stop must be checked before any automated decision ─────────

deny contains msg if {
    input.action in transaction_actions
    not input.emergency_stop_checked == true
    msg := sprintf(
        "BLOCKED [I-23]: Emergency stop state not verified before automated decision '%v' " +
        "by agent '%v'. HTTP 503 must be returned if stop is active. " +
        "Authority: EU AI Act Art. 14(4)(e), GAP-REGISTER G-03.",
        [input.action, input.agent_id],
    )
}


# ── I-25: ExplanationBundle required for decisions > £10,000 ──────────────────

deny contains msg if {
    input.action in transaction_actions
    input.amount_gbp > i25_amount_threshold_gbp
    not input.explanation_bundle_present == true
    msg := sprintf(
        "BLOCKED [I-25]: ExplanationBundle absent for decision '%v' on £%v transaction " +
        "by agent '%v'. Required for amounts > £%v. " +
        "Authority: FCA SS1/23, UK GDPR Art. 22, FCA PS7/24.",
        [input.action, input.amount_gbp, input.agent_id, i25_amount_threshold_gbp],
    )
}


# ── SAR: submit_sar requires MLRO approval ────────────────────────────────────
# Note: file_sar = detect & queue for MLRO review (automatic, no approval needed)
#       submit_sar = NCA filing (requires explicit MLRO approval)

deny contains msg if {
    input.action == "submit_sar"
    not input.mlro_approved == true
    msg := sprintf(
        "BLOCKED: SAR NCA submission by agent '%v' requires mlro_approved=true. " +
        "Authority: POCA 2002 §330, FCA MLR 2017 §19.",
        [input.agent_id],
    )
}


# ── Allowed actions per agent level ───────────────────────────────────────────
#
# Level 0 (MLRO):         All actions
# Level 1 (Orchestrator): route, emit_decision, read_policy, escalate, file_sar,
#                         approve_transaction, hold_transaction, reject_transaction
# Level 2 (L2 Agent):     read_external, write_output, call_api
# Level 3 (Feedback):     read_corpus, propose_patch
#
# (Informational — enforcement via deny rules above, not whitelist here)

level_allowed_actions := {
    0: {"*"},
    1: {"route", "emit_decision", "read_policy", "escalate",
        "approve_transaction", "hold_transaction", "reject_transaction", "file_sar"},
    2: {"read_external", "write_output", "call_api"},
    3: {"read_corpus", "propose_patch"},
}


# ── Default: allow if no deny rules fired ─────────────────────────────────────

default allow := false

allow if {
    count(deny) == 0
}
