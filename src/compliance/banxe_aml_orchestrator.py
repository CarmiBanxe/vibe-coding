#!/usr/bin/env python3
"""
BANXE AML Block Runtime — Layer 3

This is the canonical BANXE decision entry point for AML/compliance rulings
on payments, customer events, and cases.

Architecture:
  Layer 1 — Policy (developer-core)
    compliance_validator.py — jurisdiction lists, thresholds, forbidden patterns

  Layer 2 — AML Engines (vibe-coding/src/compliance/)
    tx_monitor.py      — transaction behaviour: velocity, structuring, jurisdiction
    sanctions_check.py — entity/name watchlist screening (Watchman + fuzzy)
    crypto_aml.py      — crypto wallet risk: OFAC address, mixer, darknet flags
    aml_orchestrator.py— generic layer-2 aggregator (reused internally)

  Layer 3 — BANXE Runtime (THIS FILE)
    banxe_aml_orchestrator.py — adds customer context, channel, case_id, policy version

Decision priority (signal-first, not pure summation):
  P1  Policy hard-block (Category A jurisdiction, SANCTIONS_CONFIRMED, CRYPTO_SANCTIONS)
      → always REJECT (or SAR if composite ≥ 85)
  P2  Confirmed sanctions / OFAC address hit
      → always REJECT, requires_mlro = True
  P3  High-risk jurisdiction (Cat B) or PEP customer
      → score floor = HOLD (40), even if transaction score alone < 40
  P4  Customer unacceptable risk rating
      → minimum REJECT
  P5  Standard threshold-based decision from composite score:
      SAR ≥ 85 | REJECT ≥ 70 | HOLD ≥ 40 | APPROVE < 40

Usage:
    from compliance.banxe_aml_orchestrator import banxe_assess

    result = await banxe_assess(
        transaction  = txn,           # TransactionInput | None
        customer     = cust,          # CustomerProfile  | None
        counterparty = entity,        # SanctionsSubject | None
        wallet       = wallet,        # WalletScreeningInput | None
        channel      = "bank_transfer",
    )

    # result.decision      → "APPROVE" | "HOLD" | "REJECT" | "SAR"
    # result.score         → 0–100
    # result.case_id       → UUID for Marble MLRO queue
    # result.policy_version→ "developer-core@2026-04-05"
    # result.to_api_response() → flat dict ready for BANXE API response
"""
from __future__ import annotations

import asyncio
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional

# ── Policy scope (mirrors compliance_validator._POLICY_* constants) ──────────
POLICY_JURISDICTION = "UK"        # FCA EMI — source of truth for policy scope
POLICY_REGULATOR    = "FCA"       # Authorising regulator
POLICY_FRAMEWORK    = "MLR 2017"  # Money Laundering Regulations

from compliance.models import (
    TransactionInput,
    SanctionsSubject,
    WalletScreeningInput,
    CustomerProfile,
    RiskSignal,
    AMLResult,
)
from compliance.verification.compliance_validator import (
    _THRESHOLD_SAR,
    _THRESHOLD_REJECT,
    _THRESHOLD_HOLD,
    _HARD_BLOCK_JURISDICTIONS,
    _HIGH_RISK_JURISDICTIONS,
)
from compliance.aml_orchestrator import assess as _layer2_assess
from compliance.utils.structured_logger import get_logger
from compliance.utils.decision_event_log import DecisionEvent, get_decision_log
from compliance.utils.explanation_builder import ExplanationBundle
from compliance.utils.rego_evaluator import PolicyInput, PolicyViolation, evaluate, input_from_banxe_result
from compliance.agents.orchestration_tree import TrustBoundaryError, get_default_tree

_log = get_logger("banxe_aml_orchestrator")

__all__ = ["banxe_assess", "BanxeAMLResult"]

# ── Policy version — identifies which compliance_validator build is active ─────
# Updated manually when compliance_validator.py changes materially.
_POLICY_VERSION = "developer-core@2026-04-05"

# ── Decision ordering (for floor/ceiling logic) ───────────────────────────────
_DECISION_ORDER = {"APPROVE": 0, "HOLD": 1, "REJECT": 2, "SAR": 3}


def _stricter(a: str, b: str) -> str:
    """Return the more restrictive of two decisions."""
    return a if _DECISION_ORDER[a] >= _DECISION_ORDER[b] else b


def _score_to_decision(score: int) -> str:
    return ("SAR"    if score >= _THRESHOLD_SAR    else
            "REJECT" if score >= _THRESHOLD_REJECT else
            "HOLD"   if score >= _THRESHOLD_HOLD   else "APPROVE")


# ── Customer context signals ──────────────────────────────────────────────────

def _customer_signals(customer: CustomerProfile) -> list[RiskSignal]:
    """Derive RiskSignals from customer profile context."""
    signals: list[RiskSignal] = []

    # ── KYC status ────────────────────────────────────────────────────────────
    if customer.kyc_status != "verified":
        signals.append(RiskSignal(
            source="banxe_customer",
            rule="CUSTOMER_KYC_INCOMPLETE",
            score=40,
            reason=(f"Customer {customer.customer_id} KYC status "
                    f"'{customer.kyc_status}' — EDD and identity verification required."),
            authority="MLR 2017 §28",
            requires_edd=True,
        ))

    # ── PEP status ────────────────────────────────────────────────────────────
    if customer.is_pep:
        pep_label = customer.pep_category or "PEP"
        signals.append(RiskSignal(
            source="banxe_customer",
            rule="CUSTOMER_PEP",
            score=35,
            reason=(f"Customer is {pep_label.upper()} — EDD mandatory, "
                    "senior management approval required (FCA EDD §4.1)."),
            authority="FCA EDD §4.1 / MLR 2017 §35",
            requires_edd=True,
            requires_mlro=True,
        ))

    # ── Risk rating ───────────────────────────────────────────────────────────
    if customer.risk_rating == "high":
        signals.append(RiskSignal(
            source="banxe_customer",
            rule="CUSTOMER_HIGH_RISK_RATING",
            score=25,
            reason=f"Customer {customer.customer_id} is rated 'high' risk. "
                   "Ongoing monitoring applies.",
            requires_edd=True,
        ))
    elif customer.risk_rating == "unacceptable":
        signals.append(RiskSignal(
            source="banxe_customer",
            rule="CUSTOMER_UNACCEPTABLE_RISK",
            score=70,
            reason=(f"Customer {customer.customer_id} is rated 'unacceptable' risk. "
                    "Transaction must be blocked. MLRO review mandatory."),
            requires_edd=True,
            requires_mlro=True,
        ))

    # ── Prior SAR history ─────────────────────────────────────────────────────
    if customer.prior_sars > 0:
        boost = min(customer.prior_sars * 15, 30)  # max +30
        signals.append(RiskSignal(
            source="banxe_customer",
            rule="CUSTOMER_PRIOR_SAR",
            score=boost,
            reason=(f"Customer has {customer.prior_sars} prior SAR filing(s). "
                    "Elevated monitoring — MLRO review mandatory."),
            requires_mlro=True,
        ))

    # ── Customer jurisdiction (nationality / residence) ───────────────────────
    for jur_code, field_name in [
        (customer.nationality,             "nationality"),
        (customer.residence_jurisdiction,  "residence"),
    ]:
        if not jur_code:
            continue
        jur = jur_code.upper()
        if jur in _HARD_BLOCK_JURISDICTIONS:
            signals.append(RiskSignal(
                source="banxe_customer",
                rule="CUSTOMER_JURISDICTION_A",
                score=100,
                reason=(f"Customer {field_name} '{jur}' is Category A "
                        "(hard block): SAMLA 2018 / UK HMT. MLRO notified."),
                authority="SAMLA 2018 / UK HMT Consolidated List",
                requires_edd=True,
                requires_mlro=True,
            ))
        elif jur in _HIGH_RISK_JURISDICTIONS:
            signals.append(RiskSignal(
                source="banxe_customer",
                rule="CUSTOMER_JURISDICTION_B",
                score=35,
                reason=(f"Customer {field_name} '{jur}' is Category B "
                        "(high-risk): EDD mandatory (FCA EDD §4.2)."),
                authority="FCA EDD §4.2",
                requires_edd=True,
            ))

    # ── New account / first payment ───────────────────────────────────────────
    if "new_account" in customer.flags and customer.account_age_days < 30:
        signals.append(RiskSignal(
            source="banxe_customer",
            rule="CUSTOMER_NEW_ACCOUNT",
            score=10,
            reason=f"Account age {customer.account_age_days}d — new account monitoring.",
        ))

    return signals


# ── Channel scoring adjustments ───────────────────────────────────────────────

def _channel_signals(channel: str, tx: Optional[TransactionInput]) -> list[RiskSignal]:
    """Channel-specific baseline signals."""
    signals: list[RiskSignal] = []
    ch = channel.lower()

    if ch in ("crypto", "defi", "exchange"):
        # Already handled by crypto_aml if wallet is provided;
        # this covers crypto-channel transactions without explicit wallet
        if tx and tx.is_crypto:
            pass  # tx_monitor CRYPTO_FLAG already fires
        elif tx:
            signals.append(RiskSignal(
                source="banxe_channel",
                rule="CHANNEL_CRYPTO_BASELINE",
                score=15,
                reason=f"Payment via crypto channel '{channel}' — elevated monitoring.",
                authority="FATF Recommendation 15",
            ))

    elif ch in ("cash", "cash_deposit"):
        signals.append(RiskSignal(
            source="banxe_channel",
            rule="CHANNEL_CASH",
            score=20,
            reason=f"Cash channel '{channel}' — inherently higher ML risk.",
            authority="MLR 2017 §7",
        ))

    elif ch in ("high_value_wire", "swift"):
        if tx and tx.amount_gbp >= 50_000:
            signals.append(RiskSignal(
                source="banxe_channel",
                rule="CHANNEL_HIGH_VALUE_WIRE",
                score=15,
                reason=(f"High-value SWIFT/wire £{tx.amount_gbp:,.0f} — "
                        "correspondent bank EDD may apply."),
                requires_edd=True,
            ))

    return signals


# ── Priority decision engine ──────────────────────────────────────────────────

_HARD_OVERRIDE_RULES = frozenset({
    "HARD_BLOCK_JURISDICTION",
    "SUBJECT_JURISDICTION_A",
    "CUSTOMER_JURISDICTION_A",
    "SANCTIONS_CONFIRMED",
    "CRYPTO_SANCTIONS",
    "CUSTOMER_UNACCEPTABLE_RISK",
})

_HIGH_RISK_FLOOR_RULES = frozenset({
    "HIGH_RISK_JURISDICTION",
    "SUBJECT_JURISDICTION_B",
    "CUSTOMER_JURISDICTION_B",
    "CUSTOMER_PEP",
    "CUSTOMER_KYC_INCOMPLETE",
})


def _priority_decision(
    score: int,
    all_signals: list[RiskSignal],
) -> tuple[str, str]:
    """
    Signal-priority decision engine.

    Returns (decision, priority_reason) where priority_reason explains
    if a floor or override was applied.
    """
    triggered = {s.rule for s in all_signals}

    # P1: Hard override — always REJECT or SAR
    if triggered & _HARD_OVERRIDE_RULES:
        threshold_decision = _score_to_decision(score)
        # SAR if composite score already warrants it; otherwise REJECT
        decision = _stricter(threshold_decision, "REJECT")
        return decision, "hard_override"

    # P2: High-risk floor — minimum HOLD even if score < 40
    minimum_decision = "APPROVE"
    if triggered & _HIGH_RISK_FLOOR_RULES:
        minimum_decision = "HOLD"

    # P3: Standard threshold + floor
    threshold_decision = _score_to_decision(score)
    decision = _stricter(threshold_decision, minimum_decision)

    reason = "threshold"
    if minimum_decision != "APPROVE" and _DECISION_ORDER[minimum_decision] > _DECISION_ORDER[threshold_decision]:
        reason = "high_risk_floor"

    return decision, reason


# ── Result contract ───────────────────────────────────────────────────────────

@dataclass
class BanxeAMLResult:
    """
    BANXE AML runtime result — Layer 3 output.

    Extends AMLResult with BANXE-specific routing, case management,
    and policy traceability fields.
    """
    # Core decision
    decision: str               # APPROVE / HOLD / REJECT / SAR
    score: int                  # 0–100 composite
    signals: list[RiskSignal]
    decision_reason: str        # "threshold" | "hard_override" | "high_risk_floor"

    # Routing flags
    requires_edd: bool
    requires_mlro_review: bool

    # Context flags
    hard_block_hit: bool        # Category A jurisdiction or OFAC exact match
    sanctions_hit: bool         # Any confirmed/probable sanctions hit
    crypto_risk: bool
    customer_risk_flag: bool    # Customer profile triggered a signal

    # BANXE-specific
    case_id: str                # UUID for Marble MLRO queue
    policy_version: str         # compliance_validator provenance
    channel: str
    project: str = "BANXE"

    # Policy provenance — mirrors VerificationResult.policy_scope contract
    policy_scope: dict[str, str] = field(default_factory=lambda: {
        "policy_jurisdiction": POLICY_JURISDICTION,
        "policy_regulator":    POLICY_REGULATOR,
        "policy_framework":    POLICY_FRAMEWORK,
    })

    # Explainability (G-02 / I-25 — required for tx >= £10,000, always built)
    explanation: Optional["ExplanationBundle"] = None

    # Audit
    audit_payload: dict = field(default_factory=dict)
    timestamp: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )

    def to_api_response(self) -> dict:
        """Flat dict for BANXE API response (HTTP 200 body)."""
        resp = {
            "decision":            self.decision,
            "score":               self.score,
            "requires_edd":        self.requires_edd,
            "requires_mlro_review":self.requires_mlro_review,
            "case_id":             self.case_id,
            "policy_version":      self.policy_version,
            "channel":             self.channel,
            "signals": [
                {
                    "source":    s.source,
                    "rule":      s.rule,
                    "score":     s.score,
                    "reason":    s.reason,
                    "authority": s.authority,
                }
                for s in self.signals
            ],
            "hard_block_hit":      self.hard_block_hit,
            "sanctions_hit":       self.sanctions_hit,
            "crypto_risk":         self.crypto_risk,
            "timestamp":           self.timestamp,
        }
        if self.explanation is not None:
            resp["explanation"] = self.explanation.to_dict()
        return resp

    def to_audit_dict(self) -> dict:
        """Flat dict for ClickHouse `audit_trail` insert."""
        return {
            "timestamp":           self.timestamp,
            "case_id":             self.case_id,
            "decision":            self.decision,
            "score":               self.score,
            "decision_reason":     self.decision_reason,
            "requires_edd":        self.requires_edd,
            "requires_mlro_review":self.requires_mlro_review,
            "hard_block_hit":      self.hard_block_hit,
            "sanctions_hit":       self.sanctions_hit,
            "crypto_risk":         self.crypto_risk,
            "customer_risk_flag":  self.customer_risk_flag,
            "channel":             self.channel,
            "policy_version":      self.policy_version,
            **self.policy_scope,   # policy_jurisdiction, policy_regulator, policy_framework
            "project":             self.project,
            "signal_count":        len(self.signals),
            "rules_triggered":     sorted({s.rule for s in self.signals}),
            **self.audit_payload,
        }


# ── Public entry point ────────────────────────────────────────────────────────

async def banxe_assess(
    transaction:  Optional[TransactionInput]     = None,
    customer:     Optional[CustomerProfile]      = None,
    counterparty: Optional[SanctionsSubject]     = None,
    wallet:       Optional[WalletScreeningInput] = None,
    channel:      str = "bank_transfer",
    project:      str = "BANXE",
) -> BanxeAMLResult:
    """
    BANXE AML Block Runtime — single assess() entry point.

    Runs Layer 2 engines (tx_monitor + sanctions_check + crypto_aml) in parallel,
    then enriches with customer context and channel signals, then applies
    signal-priority decision logic.

    Parameters:
        transaction  — payment event (amount, jurisdictions, velocity)
        customer     — customer risk profile (PEP, risk rating, prior SARs)
        counterparty — entity to screen (sanctions, PEP, jurisdiction)
        wallet       — crypto address (OFAC, mixer, darknet flags)
        channel      — payment channel ("bank_transfer", "crypto", "cash", "swift", ...)
        project      — always "BANXE" (for multi-tenant audit trail)

    Returns:
        BanxeAMLResult with decision, case_id, policy_version and full audit payload.
    """
    # ── Step 1: Trust boundary check (G-04) ──────────────────────────────────
    # banxe_aml_orchestrator (Level-1) → aml_orchestrator (Level-2): always OK.
    # This call also surfaces any non-blocking AMBER→GREEN warnings to the audit log.
    _tree = get_default_tree()
    _trust_warnings = _tree.assert_call_allowed(
        "banxe_aml_orchestrator", "aml_orchestrator"
    )
    for _w in _trust_warnings:
        _log.warning_event("TRUST_BOUNDARY_WARN", {
            "rule":      _w.rule,
            "message":   _w.message,
            "caller_id": _w.caller_id,
            "callee_id": _w.callee_id,
        })

    # ── Step 2: Run Layer 2 engines (generic orchestrator) ────────────────────
    layer2: AMLResult = await _layer2_assess(
        tx=transaction,
        subject=counterparty,
        wallet=wallet,
    )
    all_signals: list[RiskSignal] = list(layer2.signals)

    # ── Step 3: Customer context signals ──────────────────────────────────────
    customer_signals: list[RiskSignal] = []
    if customer is not None:
        customer_signals = _customer_signals(customer)
        all_signals.extend(customer_signals)

    # ── Step 4: Channel signals ───────────────────────────────────────────────
    channel_signals = _channel_signals(channel, transaction)
    all_signals.extend(channel_signals)

    # ── Step 5: Composite score (cap at 100) ──────────────────────────────────
    raw_score = sum(s.score for s in all_signals)
    score     = min(raw_score, 100)

    # ── Step 6: Priority decision (floors + hard overrides) ───────────────────
    decision, decision_reason = _priority_decision(score, all_signals)

    # ── Step 7: Routing flags ──────────────────────────────────────────────────
    requires_edd  = any(s.requires_edd   for s in all_signals)
    requires_mlro = any(s.requires_mlro  for s in all_signals)

    triggered_rules = {s.rule for s in all_signals}
    hard_block_hit  = bool(triggered_rules & {
        "HARD_BLOCK_JURISDICTION", "SUBJECT_JURISDICTION_A",
        "CUSTOMER_JURISDICTION_A", "CRYPTO_SANCTIONS",
    })
    sanctions_hit   = bool(triggered_rules & {
        "SANCTIONS_CONFIRMED", "SANCTIONS_PROBABLE", "SUBJECT_JURISDICTION_A",
    })
    crypto_risk     = any(s.source == "crypto_aml" for s in all_signals)
    customer_risk_flag = bool(customer_signals)

    # SAR always requires MLRO
    if decision == "SAR":
        requires_mlro = True

    # ── Step 8: Case ID + audit payload ───────────────────────────────────────
    case_id = str(uuid.uuid4())

    audit_payload = {
        "rules_triggered":    sorted(triggered_rules),
        "signal_count":       len(all_signals),
        "raw_score":          raw_score,
        "decision_reason":    decision_reason,
        "hard_override":      decision_reason == "hard_override",
        "high_risk_floor":    decision_reason == "high_risk_floor",
        "channel":            channel,
        "project":            project,
        "customer_id":        customer.customer_id if customer else None,
        **layer2.audit_payload,  # velocity_24h_gbp, tx_count_24h, hard_block from Layer 2
    }

    result = BanxeAMLResult(
        decision=decision,
        score=score,
        signals=all_signals,
        decision_reason=decision_reason,
        requires_edd=requires_edd,
        requires_mlro_review=requires_mlro,
        hard_block_hit=hard_block_hit,
        sanctions_hit=sanctions_hit,
        crypto_risk=crypto_risk,
        customer_risk_flag=customer_risk_flag,
        case_id=case_id,
        policy_version=_POLICY_VERSION,
        channel=channel,
        project=project,
        policy_scope={
            "policy_jurisdiction": POLICY_JURISDICTION,
            "policy_regulator":    POLICY_REGULATOR,
            "policy_framework":    POLICY_FRAMEWORK,
        },
        audit_payload=audit_payload,
    )

    # ── ExplanationBundle (G-02 / I-25) ─────────────────────────────────────
    # Required for tx >= £10,000 (I-25). Built for all decisions regardless.
    # Deterministic — derived from RiskSignal metadata, no ML required.
    amount_gbp = transaction.amount_gbp if transaction else 0.0
    result.explanation = ExplanationBundle.from_banxe_result(
        result, amount_gbp=amount_gbp
    )

    # ── G-19: Invariant enforcement (I-21 / I-22 / I-23 / I-25) ────────────────
    # Post-decision invariant check — verifies correctness of the result we built.
    # Fail-open for I-23 (API layer already enforces via require_not_stopped).
    # Fail-CLOSED for I-25: missing ExplanationBundle is a code bug, never infra issue.
    _policy_input = input_from_banxe_result(
        result,
        amount_gbp             = amount_gbp,
        emergency_stop_checked = True,   # API layer guarantees this; orchestrator trusts caller
    )
    _violations = evaluate(_policy_input)
    if _violations:
        for _v in _violations:
            _log.critical_event("POLICY_VIOLATION", {
                "invariant": _v.invariant,
                "rule":      _v.rule,
                "message":   _v.message,
                "case_id":   case_id,
                "blocked":   _v.blocked,
            })
        # I-25 violation = code bug (ExplanationBundle builder failed)
        # This should never happen in production — raise to surface immediately
        i25 = [v for v in _violations if v.invariant == "I-25"]
        if i25:
            raise RuntimeError(
                f"I-25 VIOLATION: ExplanationBundle missing for case_id={case_id}, "
                f"amount_gbp={amount_gbp}. This is a code bug."
            )

    # ── Structured audit log (Factor XI / G-20) ──────────────────────────────
    tx_id       = transaction.tx_id if transaction and hasattr(transaction, "tx_id") else None
    customer_id = customer.customer_id if customer else None
    _log.decision(
        decision,
        composite_score=score,
        tx_id=tx_id,
        case_id=case_id,
        customer_id=customer_id,
        requires_mlro=requires_mlro,
        decision_reason=decision_reason,
        hard_block_hit=hard_block_hit,
        sanctions_hit=sanctions_hit,
        channel=channel,
        policy_version=_POLICY_VERSION,
    )

    # ── Decision Event Log (G-01 / I-24 append-only) ─────────────────────────
    # Fire-and-forget: DB failure must never affect the compliance decision.
    # The event was already logged to stdout (G-20); Postgres is additional durability.
    try:
        event = DecisionEvent.from_aml_result(result)
        await get_decision_log().append_event(event)
    except Exception as _e:
        _log.error_event("DECISION_EVENT_LOG_FAIL", {
            "error": type(_e).__name__,
            "case_id": case_id,
        })

    return result


# ── __main__ smoke tests ──────────────────────────────────────────────────────

if __name__ == "__main__":

    async def _run():
        sep = "=" * 65
        print(f"\n{sep}")
        print("  banxe_aml_orchestrator.py — smoke tests (Layer 3)")
        print(f"  Policy: {_POLICY_VERSION}")
        print(f"  Thresholds: SAR≥{_THRESHOLD_SAR} | REJECT≥{_THRESHOLD_REJECT} "
              f"| HOLD≥{_THRESHOLD_HOLD}")
        print(sep)

        scenarios = [
            # ── label, expected, tx, customer, counterparty, wallet, channel
            (
                "APPROVE — clean UK retail",
                "APPROVE",
                TransactionInput("GB", "DE", 400.0, currency="GBP"),
                CustomerProfile("CUST-001", risk_rating="standard"),
                None, None, "bank_transfer",
            ),
            (
                "HOLD — high-risk jurisdiction floor (Cat B, low amount)",
                "HOLD",
                TransactionInput("SY", "GB", 200.0, currency="GBP"),
                CustomerProfile("CUST-002", risk_rating="standard"),
                None, None, "bank_transfer",
            ),
            (
                "HOLD — PEP customer, clean transaction",
                "HOLD",
                TransactionInput("GB", "GB", 500.0, currency="GBP"),
                CustomerProfile("CUST-003", is_pep=True, pep_category="domestic"),
                None, None, "bank_transfer",
            ),
            (
                "SAR — Category A hard block (RU, score=100 ≥ 85)",
                "SAR",
                TransactionInput("RU", "GB", 100.0, currency="GBP"),
                CustomerProfile("CUST-004"),
                None, None, "bank_transfer",
            ),
            (
                "REJECT — unacceptable customer risk rating",
                "REJECT",
                TransactionInput("GB", "GB", 500.0, currency="GBP"),
                CustomerProfile("CUST-005", risk_rating="unacceptable"),
                None, None, "bank_transfer",
            ),
            (
                "SAR — structuring + PEP + prior SAR",
                "SAR",
                TransactionInput("GB", "GB", 9_000.0, currency="GBP",
                                 flags=["structuring_hint"]),
                CustomerProfile("CUST-006", is_pep=True, prior_sars=2),
                None, None, "bank_transfer",
            ),
            (
                "REJECT — crypto mixer channel",
                "REJECT",
                TransactionInput("GB", "GB", 5_000.0, is_crypto=True),
                CustomerProfile("CUST-007"),
                None,
                WalletScreeningInput(
                    address="0xAbc1234567890abcdef1234567890abcdef123456",
                    chain="eth",
                    risk_flags=["mixer"],
                    tx_value_usd=6_000,
                ),
                "crypto",
            ),
            (
                "REJECT — sanctions counterparty (Cat A jurisdiction)",
                "REJECT",
                None,
                CustomerProfile("CUST-008"),
                SanctionsSubject("Dmitry Ivanov", entity_type="person", jurisdiction="RU"),
                None, "bank_transfer",
            ),
        ]

        passed = failed = 0
        for label, expected, tx, cust, counterparty, wallet, channel in scenarios:
            r = await banxe_assess(
                transaction=tx,
                customer=cust,
                counterparty=counterparty,
                wallet=wallet,
                channel=channel,
            )
            ok = r.decision == expected
            mark = "OK" if ok else "FAIL"
            if ok: passed += 1
            else:  failed += 1

            print(f"\n  {mark} [{label}]")
            print(f"     decision={r.decision} (expected={expected})  "
                  f"score={r.score}  reason={r.decision_reason}")
            print(f"     edd={r.requires_edd}  mlro={r.requires_mlro_review}  "
                  f"case_id={r.case_id[:8]}...")
            for s in r.signals:
                print(f"     [{s.score:+d}] {s.source}/{s.rule}")

        print(f"\n{sep}")
        print(f"  Results: {passed} passed, {failed} failed  |  "
              f"policy={_POLICY_VERSION}")
        print(f"{sep}\n")

    asyncio.run(_run())
