"""
test_commercial_adapters.py — Commercial Adapter Stubs Tests

DowJones:
T-01  DowJonesAdapter initialises in STUB mode (no API key)
T-02  DowJonesAdapter.screen_entity raises NotConfiguredError in STUB mode
T-03  DowJonesAdapter.screen_pep raises NotConfiguredError in STUB mode
T-04  DowJonesAdapter.mode == "STUB" without API key
T-05  DowJonesAdapter.mode == "LIVE" with API key set
T-06  ScreeningResult.is_hit=False → to_risk_signal() returns None
T-07  ScreeningResult.is_hit=True → to_risk_signal() returns RiskSignal
T-08  PEPResult.is_pep=False → to_risk_signal() returns None
T-09  PEPResult.is_pep=True → to_risk_signal() returns RiskSignal with requires_edd=True
T-10  PEPResult Tier-1 → to_risk_signal() requires_mlro=True
T-11  DowJonesConfig.from_env reads DOW_JONES_API_KEY
T-12  DowJonesConfig.is_configured False when key empty

Sumsub:
T-13  SumsubAdapter initialises in STUB mode
T-14  SumsubAdapter.verify_document raises NotConfiguredError in STUB mode
T-15  SumsubAdapter.verify_kyb raises NotConfiguredError in STUB mode
T-16  SumsubAdapter.get_applicant_status raises NotConfiguredError in STUB mode
T-17  VerificationResult.is_approved True when status=APPROVED
T-18  VerificationResult.is_rejected True when status=REJECTED
T-19  VerificationResult APPROVED → to_risk_signal() returns None
T-20  VerificationResult REJECTED → to_risk_signal() returns RiskSignal requires_mlro=True
T-21  SumsubConfig.from_env reads SUMSUB_APP_TOKEN + SUMSUB_SECRET_KEY

Chainalysis:
T-22  ChainalysisAdapter initialises in STUB mode
T-23  ChainalysisAdapter.screen_wallet raises NotConfiguredError in STUB mode
T-24  ChainalysisAdapter.screen_transaction raises NotConfiguredError in STUB mode
T-25  WalletRiskResult score < 5 → to_risk_signal() returns None
T-26  WalletRiskResult score >= 5 → to_risk_signal() returns RiskSignal
T-27  WalletRiskResult SEVERE category → requires_mlro=True
T-28  ChainalysisConfig.from_env reads CHAINALYSIS_API_KEY
"""
from __future__ import annotations

import os
import pytest
from unittest.mock import patch

from compliance.adapters.dowjones_adapter import (
    DowJonesAdapter,
    DowJonesConfig,
    ScreeningResult,
    PEPResult,
    NotConfiguredError,
)
from compliance.adapters.sumsub_adapter import (
    SumsubAdapter,
    SumsubConfig,
    VerificationResult,
    KYBResult,
)
from compliance.adapters.chainalysis_adapter import (
    ChainalysisAdapter,
    ChainalysisConfig,
    WalletRiskResult,
    TransactionRiskResult,
)
from compliance.models import RiskSignal


# ══════════════════════════════════════════════════════════════════════════════
# Dow Jones Tests (T-01..T-12)
# ══════════════════════════════════════════════════════════════════════════════

def test_T01_dowjones_stub_mode_no_key():
    with patch.dict(os.environ, {}, clear=True):
        adapter = DowJonesAdapter(config=DowJonesConfig(api_key=""))
        assert adapter.mode == "STUB"


def test_T02_dowjones_screen_entity_raises_in_stub():
    adapter = DowJonesAdapter(config=DowJonesConfig(api_key=""))
    with pytest.raises(NotConfiguredError) as exc:
        adapter.screen_entity("Ivan Petrov", "RU")
    assert "DOW_JONES_API_KEY" in str(exc.value) or "vendors@banxe.ai" in str(exc.value)


def test_T03_dowjones_screen_pep_raises_in_stub():
    adapter = DowJonesAdapter(config=DowJonesConfig(api_key=""))
    with pytest.raises(NotConfiguredError):
        adapter.screen_pep("Vladimir Putin")


def test_T04_dowjones_mode_stub():
    adapter = DowJonesAdapter(config=DowJonesConfig(api_key=""))
    assert adapter.mode == "STUB"


def test_T05_dowjones_mode_live_with_key():
    adapter = DowJonesAdapter(config=DowJonesConfig(api_key="fake-key-for-test"))
    assert adapter.mode == "LIVE"


def test_T06_screening_result_no_hit_returns_none():
    result = ScreeningResult(is_hit=False, entity_name="John Smith")
    assert result.to_risk_signal() is None


def test_T07_screening_result_hit_returns_risk_signal():
    result = ScreeningResult(
        is_hit=True,
        entity_name="Ivan Petrov",
        match_score=0.95,
        list_name="HM Treasury",
        match_type="EXACT",
        risk_level="CRITICAL",
    )
    signal = result.to_risk_signal()
    assert isinstance(signal, RiskSignal)
    assert signal.source == "dowjones_djrc"
    assert signal.score > 0
    assert signal.requires_mlro is True


def test_T08_pep_result_no_pep_returns_none():
    result = PEPResult(is_pep=False, entity_name="Jane Smith")
    assert result.to_risk_signal() is None


def test_T09_pep_result_pep_returns_signal_with_edd():
    result = PEPResult(
        is_pep=True,
        entity_name="Boris Johnson",
        pep_tier=2,
        roles=["Prime Minister"],
        jurisdiction="GB",
    )
    signal = result.to_risk_signal()
    assert isinstance(signal, RiskSignal)
    assert signal.requires_edd is True
    assert "PEP" in signal.rule


def test_T10_pep_tier1_requires_mlro():
    result = PEPResult(is_pep=True, entity_name="Head of State", pep_tier=1, jurisdiction="RU")
    signal = result.to_risk_signal()
    assert signal.requires_mlro is True


def test_T11_dowjones_config_from_env():
    with patch.dict(os.environ, {"DOW_JONES_API_KEY": "dj-test-key-123"}):
        config = DowJonesConfig.from_env()
        assert config.api_key == "dj-test-key-123"


def test_T12_dowjones_config_not_configured_empty_key():
    config = DowJonesConfig(api_key="")
    assert config.is_configured is False


# ══════════════════════════════════════════════════════════════════════════════
# Sumsub Tests (T-13..T-21)
# ══════════════════════════════════════════════════════════════════════════════

def test_T13_sumsub_stub_mode():
    adapter = SumsubAdapter(config=SumsubConfig(app_token="", secret_key=""))
    assert adapter.mode == "STUB"


def test_T14_sumsub_verify_document_raises_stub():
    adapter = SumsubAdapter(config=SumsubConfig(app_token="", secret_key=""))
    with pytest.raises(NotConfiguredError) as exc:
        adapter.verify_document("applicant-001", "PASSPORT")
    assert "SUMSUB_APP_TOKEN" in str(exc.value) or "vendors@banxe.ai" in str(exc.value)


def test_T15_sumsub_verify_kyb_raises_stub():
    adapter = SumsubAdapter(config=SumsubConfig(app_token="", secret_key=""))
    with pytest.raises(NotConfiguredError):
        adapter.verify_kyb("company-001", "ACME Ltd", "GB")


def test_T16_sumsub_get_status_raises_stub():
    adapter = SumsubAdapter(config=SumsubConfig(app_token="", secret_key=""))
    with pytest.raises(NotConfiguredError):
        adapter.get_applicant_status("applicant-001")


def test_T17_verification_result_approved():
    result = VerificationResult(applicant_id="a1", status="APPROVED")
    assert result.is_approved is True
    assert result.is_rejected is False


def test_T18_verification_result_rejected():
    result = VerificationResult(applicant_id="a2", status="REJECTED")
    assert result.is_rejected is True
    assert result.is_approved is False


def test_T19_verification_approved_no_signal():
    result = VerificationResult(applicant_id="a3", status="APPROVED")
    assert result.to_risk_signal() is None


def test_T20_verification_rejected_signal_requires_mlro():
    result = VerificationResult(
        applicant_id="a4",
        status="REJECTED",
        reject_labels=["FORGERY", "FACE_MATCH_FAILED"],
    )
    signal = result.to_risk_signal()
    assert isinstance(signal, RiskSignal)
    assert signal.requires_mlro is True
    assert signal.score >= 70


def test_T21_sumsub_config_from_env():
    with patch.dict(os.environ, {
        "SUMSUB_APP_TOKEN": "test-app-token",
        "SUMSUB_SECRET_KEY": "test-secret",
    }):
        config = SumsubConfig.from_env()
        assert config.app_token == "test-app-token"
        assert config.secret_key == "test-secret"
        assert config.is_configured is True


# ══════════════════════════════════════════════════════════════════════════════
# Chainalysis Tests (T-22..T-28)
# ══════════════════════════════════════════════════════════════════════════════

def test_T22_chainalysis_stub_mode():
    adapter = ChainalysisAdapter(config=ChainalysisConfig(api_key=""))
    assert adapter.mode == "STUB"


def test_T23_chainalysis_screen_wallet_raises_stub():
    adapter = ChainalysisAdapter(config=ChainalysisConfig(api_key=""))
    with pytest.raises(NotConfiguredError) as exc:
        adapter.screen_wallet("0xdeadbeef")
    assert "CHAINALYSIS_API_KEY" in str(exc.value) or "vendors@banxe.ai" in str(exc.value)


def test_T24_chainalysis_screen_tx_raises_stub():
    adapter = ChainalysisAdapter(config=ChainalysisConfig(api_key=""))
    with pytest.raises(NotConfiguredError):
        adapter.screen_transaction("0xabc123")


def test_T25_wallet_risk_low_score_no_signal():
    result = WalletRiskResult(address="0xclean", chain="eth", risk_score=2, risk_category="LOW")
    assert result.to_risk_signal() is None


def test_T26_wallet_risk_medium_returns_signal():
    result = WalletRiskResult(
        address="0xsuspect123",
        chain="eth",
        risk_score=6,
        risk_category="MEDIUM",
        exposure_categories=["mixing", "high_risk_exchange"],
    )
    signal = result.to_risk_signal()
    assert isinstance(signal, RiskSignal)
    assert signal.source == "chainalysis_kyt"
    assert signal.score == 60


def test_T27_wallet_severe_requires_mlro():
    result = WalletRiskResult(
        address="0xbad",
        chain="eth",
        risk_score=9,
        risk_category="SEVERE",
        sanctions_exposure=0.15,
    )
    assert result.is_high_risk is True
    signal = result.to_risk_signal()
    assert signal.requires_mlro is True


def test_T28_chainalysis_config_from_env():
    with patch.dict(os.environ, {"CHAINALYSIS_API_KEY": "chain-key-abc"}):
        config = ChainalysisConfig.from_env()
        assert config.api_key == "chain-key-abc"
        assert config.is_configured is True
