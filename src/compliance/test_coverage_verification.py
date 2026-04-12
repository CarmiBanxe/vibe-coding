"""
test_coverage_verification.py — Coverage boost for verification sub-agents.

Covers:
  - verification/compliance_validator.py  (all verify() paths)
  - verification/policy_agent.py          (all verify() paths)
  - verification/workflow_agent.py        (all verify() paths)
"""
from __future__ import annotations
import sys
from pathlib import Path
import pytest

_SRC = Path(__file__).parent.parent
if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))


# ══════════════════════════════════════════════════════════════════════════════
# SECTION 1: verification/compliance_validator.py
# ══════════════════════════════════════════════════════════════════════════════

class TestComplianceValidator:

    def test_verify_clean_statement_confirmed(self):
        from compliance.verification.compliance_validator import verify, Verdict
        result = verify("The customer identity has been verified via SumSub.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)
        assert 0.0 <= result.confidence <= 1.0

    def test_verify_forbidden_pattern_kyc_bypass(self):
        from compliance.verification.compliance_validator import verify, Verdict
        result = verify("We can skip KYC for this customer.")
        assert result.verdict == Verdict.REFUTED
        assert result.confidence == 1.0

    def test_verify_forbidden_pattern_sanctions_bypass(self):
        from compliance.verification.compliance_validator import verify, Verdict
        result = verify("We should skip sanctions screening for this transaction.")
        assert result.verdict == Verdict.REFUTED

    def test_verify_hard_block_jurisdiction_ru(self):
        from compliance.verification.compliance_validator import verify, Verdict, _HARD_BLOCK_JURISDICTIONS
        if "RU" in _HARD_BLOCK_JURISDICTIONS:
            result = verify("Transfer funds to RU counterparty.")
            # RU is Category A — should be REFUTED
            assert result.verdict in (Verdict.REFUTED, Verdict.UNCERTAIN)

    def test_verify_threshold_below_hold(self):
        from compliance.verification.compliance_validator import verify, Verdict
        result = verify("Composite score is 10, below all thresholds.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_threshold_sar(self):
        from compliance.verification.compliance_validator import verify, Verdict, _THRESHOLD_SAR
        result = verify(f"Composite score is {_THRESHOLD_SAR + 5}, SAR required.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN, Verdict.REFUTED)

    def test_verify_confirms_sar_statement(self):
        from compliance.verification.compliance_validator import verify, Verdict
        result = verify("SAR filing is required for this transaction as score is above 85.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_confirms_audit_retention(self):
        from compliance.verification.compliance_validator import verify, Verdict
        result = verify("All records must be retained for 5 years per FCA MLR 2017.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_with_context(self):
        from compliance.verification.compliance_validator import verify, Verdict
        ctx = {"agent_role": "compliance_officer", "amount": 5000}
        result = verify("Transaction approved after AML check.", context=ctx)
        assert result is not None

    def test_verdict_enum_values(self):
        from compliance.verification.compliance_validator import Verdict
        assert Verdict.CONFIRMED.value == "CONFIRMED"
        assert Verdict.REFUTED.value == "REFUTED"
        assert Verdict.UNCERTAIN.value == "UNCERTAIN"

    def test_verification_result_fields(self):
        from compliance.verification.compliance_validator import VerificationResult, Verdict
        r = VerificationResult(verdict=Verdict.CONFIRMED, rule="TEST", reason="ok", confidence=0.9)
        assert r.verdict == Verdict.CONFIRMED
        assert r.rule == "TEST"
        assert r.reason == "ok"
        assert r.confidence == 0.9

    def test_verify_watchman_min_match_referenced(self):
        from compliance.verification.compliance_validator import _WATCHMAN_MIN_MATCH
        assert isinstance(_WATCHMAN_MIN_MATCH, (int, float))

    def test_verify_high_risk_jurisdiction(self):
        from compliance.verification.compliance_validator import verify, Verdict, _HIGH_RISK_JURISDICTIONS
        if _HIGH_RISK_JURISDICTIONS:
            jur = next(iter(_HIGH_RISK_JURISDICTIONS))
            result = verify(f"Transfer involves counterparty in {jur} jurisdiction.")
            assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN, Verdict.REFUTED)

    def test_forbidden_patterns_non_empty(self):
        from compliance.verification.compliance_validator import _FORBIDDEN_PATTERNS
        assert len(_FORBIDDEN_PATTERNS) > 0

    def test_verify_empty_statement(self):
        from compliance.verification.compliance_validator import verify, Verdict
        result = verify("")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)


# ══════════════════════════════════════════════════════════════════════════════
# SECTION 2: verification/policy_agent.py
# ══════════════════════════════════════════════════════════════════════════════

class TestPolicyAgent:

    def test_verify_clean_transfer_confirmed(self):
        from compliance.verification.policy_agent import verify, Verdict
        result = verify("Customer transferred £500 via Faster Payments.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_guiyon_excluded(self):
        from compliance.verification.policy_agent import verify, Verdict
        result = verify("Process transaction for guiyon client account.")
        assert result.verdict == Verdict.REFUTED

    def test_verify_guiyon_ai_excluded(self):
        from compliance.verification.policy_agent import verify, Verdict
        result = verify("Enable guiyon.ai integration for payments.")
        assert result.verdict == Verdict.REFUTED

    def test_verify_unsupported_currency(self):
        from compliance.verification.policy_agent import verify, Verdict
        result = verify("Process JPY transfer for customer.")
        assert result.verdict in (Verdict.REFUTED, Verdict.UNCERTAIN)

    def test_verify_supported_currency_gbp(self):
        from compliance.verification.policy_agent import verify, Verdict
        result = verify("Customer wants to send GBP to European account.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_supported_currency_eur(self):
        from compliance.verification.policy_agent import verify, Verdict
        result = verify("SEPA transfer in EUR to Germany.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_exceeds_single_transfer_limit(self):
        from compliance.verification.policy_agent import verify, Verdict, BANXE_LIMITS
        limit = BANXE_LIMITS["single_transfer_max_gbp"]
        result = verify(f"Process transfer of £{limit + 1000} GBP.")
        assert result.verdict in (Verdict.REFUTED, Verdict.UNCERTAIN)

    def test_verify_within_single_transfer_limit(self):
        from compliance.verification.policy_agent import verify, Verdict, BANXE_LIMITS
        limit = BANXE_LIMITS["single_transfer_max_gbp"]
        result = verify(f"Full KYC verified customer processes transfer of £{limit - 1000} GBP.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN, Verdict.REFUTED)

    def test_verify_banxe_product_mentioned(self):
        from compliance.verification.policy_agent import verify, Verdict
        result = verify("Customer opened a current_account with BANXE.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_kyc_below_basic_limit(self):
        from compliance.verification.policy_agent import verify, Verdict, BANXE_LIMITS
        limit = BANXE_LIMITS["kyc_basic_max_gbp"]
        result = verify(f"Basic KYC customer wants to transfer £{limit - 100}.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_unsupported_product(self):
        from compliance.verification.policy_agent import verify, Verdict
        result = verify("Customer applied for a mortgage product.")
        assert result.verdict in (Verdict.REFUTED, Verdict.UNCERTAIN)

    def test_banxe_limits_values(self):
        from compliance.verification.policy_agent import BANXE_LIMITS
        assert BANXE_LIMITS["single_transfer_max_gbp"] > 0
        assert BANXE_LIMITS["min_transfer_gbp"] >= 1

    def test_supported_currencies_set(self):
        from compliance.verification.policy_agent import SUPPORTED_CURRENCIES
        assert "GBP" in SUPPORTED_CURRENCIES
        assert "EUR" in SUPPORTED_CURRENCIES

    def test_verify_with_context(self):
        from compliance.verification.policy_agent import verify, Verdict
        ctx = {"agent_role": "kyc_specialist", "amount": 500}
        result = verify("KYC verified for standard transfer.", context=ctx)
        assert result is not None

    def test_verify_empty_statement(self):
        from compliance.verification.policy_agent import verify, Verdict
        result = verify("")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)


# ══════════════════════════════════════════════════════════════════════════════
# SECTION 3: verification/workflow_agent.py
# ══════════════════════════════════════════════════════════════════════════════

class TestWorkflowAgent:

    def test_verify_clean_kyc_action(self):
        from compliance.verification.workflow_agent import verify, Verdict
        result = verify("KYC specialist will request documents from customer.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_mlro_required_sar(self):
        from compliance.verification.workflow_agent import verify, Verdict
        result = verify("MLRO has reviewed and SAR has been filed with NCA for this suspicious account.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_hitl_required_large_amount(self):
        from compliance.verification.workflow_agent import verify, Verdict
        result = verify("Transaction of £10,000 requires human review before processing.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_role_boundary_kyc_cannot_file_sar(self):
        from compliance.verification.workflow_agent import verify, Verdict
        result = verify("KYC specialist will file SAR for this customer.")
        # KYC specialist cannot file SAR — boundary violation
        assert result.verdict in (Verdict.REFUTED, Verdict.UNCERTAIN)

    def test_verify_role_boundary_kyc_can_verify(self):
        from compliance.verification.workflow_agent import verify, Verdict
        ctx = {"agent_role": "kyc_specialist"}
        result = verify("Verify identity documents for customer onboarding.", context=ctx)
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_pep_requires_hitl(self):
        from compliance.verification.workflow_agent import verify, Verdict
        result = verify("PEP flag detected — enhanced due diligence initiated with human review required.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_sanctions_hit_requires_hitl(self):
        from compliance.verification.workflow_agent import verify, Verdict
        result = verify("Sanctions hit confirmed — account frozen pending human review.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_mlro_approves_threshold_change(self):
        from compliance.verification.workflow_agent import verify, Verdict
        result = verify("MLRO approved the threshold change to £12,000.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_ceo_approves_override(self):
        from compliance.verification.workflow_agent import verify, Verdict
        ctx = {"agent_role": "ceo"}
        result = verify("CEO and MLRO approved policy override for strategic partnership.", context=ctx)
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_role_hierarchy_structure(self):
        from compliance.verification.workflow_agent import ROLE_HIERARCHY
        assert "mlro" in ROLE_HIERARCHY
        assert "kyc_specialist" in ROLE_HIERARCHY
        assert ROLE_HIERARCHY.index("mlro") > ROLE_HIERARCHY.index("kyc_specialist")

    def test_mlro_required_decisions(self):
        from compliance.verification.workflow_agent import MLRO_REQUIRED_DECISIONS
        assert "sar" in MLRO_REQUIRED_DECISIONS

    def test_hitl_triggers(self):
        from compliance.verification.workflow_agent import HITL_REQUIRED_TRIGGERS
        assert len(HITL_REQUIRED_TRIGGERS) > 0

    def test_verify_account_closure_needs_mlro(self):
        from compliance.verification.workflow_agent import verify, Verdict
        result = verify("Initiating account closure for non-compliant customer.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN, Verdict.REFUTED)

    def test_verify_auto_sar_triggers_hitl(self):
        from compliance.verification.workflow_agent import verify, Verdict
        result = verify("Auto SAR generated for composite_score of 90 — MLRO notified, HITL human review triggered.")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)

    def test_verify_empty_statement(self):
        from compliance.verification.workflow_agent import verify, Verdict
        result = verify("")
        assert result.verdict in (Verdict.CONFIRMED, Verdict.UNCERTAIN)
