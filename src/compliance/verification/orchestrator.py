"""
Verification Orchestrator — Consensus Engine (2/3 majority)
Runs all 3 verifier agents in parallel, computes consensus,
flags HITL on disagreement, writes to training corpus.

Usage:
    python3 -m compliance.verification.orchestrator \
        --statement "Agent statement here" \
        --agent-id "kyc-specialist-v2" \
        --agent-role "KYC Specialist"
"""
from __future__ import annotations

import argparse
import json
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Optional

from compliance.verification.compliance_validator import (
    VerificationResult as CVResult,
    Verdict,
    verify as cv_verify,
)
from compliance.verification.policy_agent import (
    VerificationResult as PAResult,
    verify as pa_verify,
)
from compliance.verification.workflow_agent import (
    VerificationResult as WAResult,
    verify as wa_verify,
)

TRAINING_CORPUS_PATH = Path("compliance/training/corpus")
TRAINING_CORPUS_PATH.mkdir(parents=True, exist_ok=True)


@dataclass
class ConsensusResult:
    interaction_id: str
    agent_id: str
    agent_role: str
    statement: str
    context: dict

    # Verdicts from each verifier
    compliance_verdict: str
    compliance_rule: Optional[str]
    compliance_reason: str
    compliance_confidence: float

    policy_verdict: str
    policy_rule: Optional[str]
    policy_reason: str
    policy_confidence: float

    workflow_verdict: str
    workflow_rule: Optional[str]
    workflow_reason: str
    workflow_confidence: float

    # Consensus output
    consensus: str           # CONFIRMED / REFUTED / UNCERTAIN
    confidence_score: float  # avg of agreeing verifiers
    drift_score: float       # fraction of REFUTED/UNCERTAIN
    escalation_correct: bool
    role_boundary_violated: bool
    training_flag: bool      # True = needs correction
    correction: Optional[str]
    correction_source: Optional[str]
    hitl_required: bool
    timestamp: str


def run_verification(
    statement: str,
    agent_id: str = "unknown",
    agent_role: str = "unknown",
    context: dict | None = None,
) -> ConsensusResult:
    context = context or {}
    context["agent_role"] = agent_role
    interaction_id = str(uuid.uuid4())

    # Run 3 verifiers in parallel
    results: dict[str, CVResult | PAResult | WAResult] = {}
    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = {
            executor.submit(cv_verify, statement, context): "compliance",
            executor.submit(pa_verify, statement, context): "policy",
            executor.submit(wa_verify, statement, context): "workflow",
        }
        for future in as_completed(futures):
            name = futures[future]
            results[name] = future.result()

    cv = results["compliance"]
    pa = results["policy"]
    wa = results["workflow"]

    # Compute consensus (2/3 majority)
    verdicts = [cv.verdict.value, pa.verdict.value, wa.verdict.value]
    confirmed_count = verdicts.count("CONFIRMED")
    refuted_count = verdicts.count("REFUTED")
    uncertain_count = verdicts.count("UNCERTAIN")

    # HARD OVERRIDE 1: Compliance Validator confidence=1.0 → red-line violation.
    # No majority can override a categorical regulatory breach (FCA MLR 2017).
    if cv.verdict == Verdict.REFUTED and cv.confidence >= 1.0:
        consensus = "REFUTED"
    # HARD OVERRIDE 2: Workflow Agent confidence≥0.95 → MLRO/HITL bypass detected.
    # FCA Senior Managers Regime requires MLRO authority — cannot be overruled by policy/compliance.
    elif wa.verdict == Verdict.REFUTED and wa.confidence >= 0.95:
        consensus = "REFUTED"
    # HARD OVERRIDE 3: Policy Agent confidence≥0.90 on EMI scope violation.
    # Claiming unlicensed products (mortgage, loans) is FCA misselling — regulatory breach.
    elif (pa.verdict == Verdict.REFUTED and pa.confidence >= 0.90
          and pa.rule and "EMI Authorisation Scope" in pa.rule):
        consensus = "REFUTED"
    elif refuted_count >= 2:
        consensus = "REFUTED"
    elif confirmed_count >= 2:
        consensus = "CONFIRMED"
    else:
        consensus = "UNCERTAIN"

    # Confidence score (average of all verifiers)
    all_confidences = [cv.confidence, pa.confidence, wa.confidence]
    confidence_score = sum(all_confidences) / len(all_confidences)

    # Drift score: fraction of non-CONFIRMED verdicts
    drift_score = (refuted_count + uncertain_count) / 3.0

    # Role boundary violated if workflow or compliance says REFUTED
    role_boundary_violated = (
        wa.verdict == Verdict.REFUTED and "role boundary" in wa.reason.lower()
    ) or (
        cv.verdict == Verdict.REFUTED and "role" in cv.reason.lower()
    )

    # Escalation correctness
    escalation_correct = not (
        wa.verdict == Verdict.REFUTED and "escalation" in wa.reason.lower()
    )

    # Training flag: any disagreement or non-confirmed consensus
    training_flag = consensus != "CONFIRMED" or refuted_count > 0 or uncertain_count > 1

    # HITL required: any REFUTED, or uncertain consensus, or high drift
    hitl_required = consensus == "REFUTED" or drift_score >= 0.33

    # Determine correction source
    correction = None
    correction_source = None
    if consensus == "REFUTED":
        # Use the highest-confidence refutation
        refuters = [
            (cv, "Compliance Validator"),
            (pa, "Policy Agent"),
            (wa, "Workflow Agent"),
        ]
        refuters = [(r, n) for r, n in refuters if r.verdict == Verdict.REFUTED]
        if refuters:
            best = max(refuters, key=lambda x: x[0].confidence)
            correction = best[0].reason
            correction_source = f"{best[1]}: {best[0].rule or 'internal policy'}"

    result = ConsensusResult(
        interaction_id=interaction_id,
        agent_id=agent_id,
        agent_role=agent_role,
        statement=statement,
        context=context,
        compliance_verdict=cv.verdict.value,
        compliance_rule=cv.rule,
        compliance_reason=cv.reason,
        compliance_confidence=cv.confidence,
        policy_verdict=pa.verdict.value,
        policy_rule=pa.rule,
        policy_reason=pa.reason,
        policy_confidence=pa.confidence,
        workflow_verdict=wa.verdict.value,
        workflow_rule=wa.rule,
        workflow_reason=wa.reason,
        workflow_confidence=wa.confidence,
        consensus=consensus,
        confidence_score=round(confidence_score, 3),
        drift_score=round(drift_score, 3),
        escalation_correct=escalation_correct,
        role_boundary_violated=role_boundary_violated,
        training_flag=training_flag,
        correction=correction,
        correction_source=correction_source,
        hitl_required=hitl_required,
        timestamp=datetime.now(timezone.utc).isoformat(),
    )

    # Write to training corpus if flagged
    if training_flag:
        _save_to_corpus(result)

    return result


def _save_to_corpus(result: ConsensusResult) -> None:
    """Save flagged interaction to training corpus (JSONL format)."""
    corpus_file = TRAINING_CORPUS_PATH / f"corpus_{datetime.now().strftime('%Y%m%d')}.jsonl"
    with open(corpus_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(asdict(result), ensure_ascii=False) + "\n")


def print_result(result: ConsensusResult) -> None:
    """Human-readable output."""
    sep = "=" * 60
    print(f"\n{sep}")
    print(f"  VERIFICATION RESULT — {result.consensus}")
    print(sep)
    print(f"  Interaction: {result.interaction_id}")
    print(f"  Agent:       {result.agent_id} ({result.agent_role})")
    print(f"  Statement:   {result.statement[:80]}{'...' if len(result.statement) > 80 else ''}")
    print()
    print(f"  ┌─ Compliance Validator: {result.compliance_verdict} (conf: {result.compliance_confidence:.2f})")
    if result.compliance_rule:
        print(f"  │  Rule: {result.compliance_rule}")
    print(f"  │  {result.compliance_reason}")
    print()
    print(f"  ├─ Policy Agent:         {result.policy_verdict} (conf: {result.policy_confidence:.2f})")
    if result.policy_rule:
        print(f"  │  Rule: {result.policy_rule}")
    print(f"  │  {result.policy_reason}")
    print()
    print(f"  └─ Workflow Agent:       {result.workflow_verdict} (conf: {result.workflow_confidence:.2f})")
    if result.workflow_rule:
        print(f"     Rule: {result.workflow_rule}")
    print(f"     {result.workflow_reason}")
    print()
    print(f"  Consensus:         {result.consensus}")
    print(f"  Confidence Score:  {result.confidence_score:.3f}")
    print(f"  Drift Score:       {result.drift_score:.3f}")
    print(f"  HITL Required:     {'YES ⚠️' if result.hitl_required else 'No'}")
    print(f"  Training Flag:     {'YES — saved to corpus' if result.training_flag else 'No'}")
    if result.correction:
        print(f"  Correction:        {result.correction}")
        print(f"  Source:            {result.correction_source}")
    print(sep)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="BANXE Verification Orchestrator")
    parser.add_argument("--statement", required=True, help="Agent statement to verify")
    parser.add_argument("--agent-id", default="unknown", help="Agent identifier")
    parser.add_argument("--agent-role", default="unknown", help="Agent role")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    result = run_verification(
        statement=args.statement,
        agent_id=args.agent_id,
        agent_role=args.agent_role,
    )

    if args.json:
        import dataclasses
        print(json.dumps(dataclasses.asdict(result), indent=2, ensure_ascii=False))
    else:
        print_result(result)
