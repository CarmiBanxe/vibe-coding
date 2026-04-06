#!/usr/bin/env python3
"""
test_config_loader.py — Unit tests for G-07 Config Loader (12-Factor Factor III).

Tests:
  T-01  compliance_config.yaml loads without error
  T-02  threshold values: SAR=85, REJECT=70, HOLD=40
  T-03  watchman min_match = 0.80
  T-04  hard_block jurisdictions contains RU, IR, KP (Category A)
  T-05  high_risk jurisdictions contains SY, IQ (Category B)
  T-06  hard_block and high_risk are mutually exclusive sets
  T-07  forbidden_patterns is non-empty list of strings
  T-08  audit_ttl_years = 5 (FCA MLR 2017 minimum)
  T-09  mlr_reporting_threshold_gbp = 10000
  T-10  yente_min_score = watchman_min_match (consistent)
  T-11  COMPLIANCE_CONFIG_PATH env var overrides config path
  T-12  reload_config() clears cache → re-reads file
  T-13  compliance_validator exports correct constants after refactor
  T-14  explanation_builder uses config values (not local hardcodes)
  T-15  sanctions_check WATCHMAN_MIN_MATCH comes from config
  T-16  tx_monitor _MLR_REPORTING_THRESHOLD_GBP comes from config
  T-17  YAML is valid and all required sections present
  T-18  policy_version string is non-empty

Coverage:
  G-07: 12-Factor Factor III — config in compliance_config.yaml, not in Python source
"""
from __future__ import annotations

import os
import sys
import tempfile
import textwrap

import pytest

BASE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.dirname(BASE)
sys.path.insert(0, SRC)
sys.path.insert(0, BASE)

from compliance.utils.config_loader import (
    get_threshold_sar,
    get_threshold_reject,
    get_threshold_hold,
    get_watchman_min_match,
    get_yente_min_score,
    get_hard_block_jurisdictions,
    get_high_risk_jurisdictions,
    get_forbidden_patterns,
    get_audit_ttl_years,
    get_mlr_reporting_threshold_gbp,
    get_policy_version,
    reload_config,
)


# ═══════════════════════════════════════════════════════════════════════════════
# T-01  compliance_config.yaml loads without error
# ═══════════════════════════════════════════════════════════════════════════════

def test_t01_config_loads():
    """compliance_config.yaml loads without error (YAML valid, file present)."""
    reload_config()
    # If any exception is raised, config is broken
    sar = get_threshold_sar()
    assert isinstance(sar, int)


# ═══════════════════════════════════════════════════════════════════════════════
# T-02  Decision thresholds: SAR=85, REJECT=70, HOLD=40
# ═══════════════════════════════════════════════════════════════════════════════

def test_t02_decision_thresholds():
    """SAR=85, REJECT=70, HOLD=40 — canonical BANXE decision boundaries."""
    assert get_threshold_sar()    == 85
    assert get_threshold_reject() == 70
    assert get_threshold_hold()   == 40


# ═══════════════════════════════════════════════════════════════════════════════
# T-03  watchman min_match = 0.80
# ═══════════════════════════════════════════════════════════════════════════════

def test_t03_watchman_min_match():
    """Watchman Jaro-Winkler threshold = 0.80."""
    assert get_watchman_min_match() == pytest.approx(0.80)


# ═══════════════════════════════════════════════════════════════════════════════
# T-04  hard_block contains Category A jurisdictions
# ═══════════════════════════════════════════════════════════════════════════════

def test_t04_hard_block_jurisdictions():
    """Category A (hard_block) must include RU, IR, KP."""
    hb = get_hard_block_jurisdictions()
    assert "RU" in hb, "Russia must be in hard_block (SAMLA 2018)"
    assert "IR" in hb, "Iran must be in hard_block (SAMLA 2018)"
    assert "KP" in hb, "North Korea must be in hard_block (UNSC Res 1718)"
    assert isinstance(hb, frozenset)


# ═══════════════════════════════════════════════════════════════════════════════
# T-05  high_risk contains Category B jurisdictions
# ═══════════════════════════════════════════════════════════════════════════════

def test_t05_high_risk_jurisdictions():
    """Category B (high_risk) must include SY (Syria, Jul 2025) and IQ."""
    hr = get_high_risk_jurisdictions()
    assert "SY" in hr, "Syria must be in high_risk (moved from Cat A Jul 2025)"
    assert "IQ" in hr, "Iraq must be in high_risk (FATF)"
    assert isinstance(hr, frozenset)


# ═══════════════════════════════════════════════════════════════════════════════
# T-06  hard_block and high_risk are mutually exclusive
# ═══════════════════════════════════════════════════════════════════════════════

def test_t06_jurisdiction_sets_mutually_exclusive():
    """A jurisdiction must not appear in both hard_block and high_risk."""
    hb = get_hard_block_jurisdictions()
    hr = get_high_risk_jurisdictions()
    overlap = hb & hr
    assert not overlap, (
        f"Jurisdictions in both sets (conflict): {overlap}. "
        "A jurisdiction must be either Category A or B, not both."
    )


# ═══════════════════════════════════════════════════════════════════════════════
# T-07  forbidden_patterns is non-empty list of strings
# ═══════════════════════════════════════════════════════════════════════════════

def test_t07_forbidden_patterns():
    """forbidden_patterns is a non-empty list of regex strings."""
    patterns = get_forbidden_patterns()
    assert isinstance(patterns, list)
    assert len(patterns) > 0
    for p in patterns:
        assert isinstance(p, str)
    # Key patterns must be present
    combined = " ".join(patterns)
    assert "kyc" in combined
    assert "edd" in combined or "enhanced" in combined


# ═══════════════════════════════════════════════════════════════════════════════
# T-08  audit_ttl_years = 5
# ═══════════════════════════════════════════════════════════════════════════════

def test_t08_audit_ttl_years():
    """FCA MLR 2017 minimum retention: 5 years."""
    assert get_audit_ttl_years() == 5


# ═══════════════════════════════════════════════════════════════════════════════
# T-09  mlr_reporting_threshold_gbp = 10000
# ═══════════════════════════════════════════════════════════════════════════════

def test_t09_mlr_threshold():
    """MLR 2017 single-transaction reporting threshold: £10,000."""
    assert get_mlr_reporting_threshold_gbp() == 10_000


# ═══════════════════════════════════════════════════════════════════════════════
# T-10  yente_min_score == watchman_min_match (consistent screening thresholds)
# ═══════════════════════════════════════════════════════════════════════════════

def test_t10_yente_watchman_consistency():
    """yente_min_score must equal watchman_min_match for consistent hit rates."""
    assert get_yente_min_score() == pytest.approx(get_watchman_min_match()), (
        "Yente and Watchman must use the same fuzzy match threshold "
        "to avoid false-negative inconsistency between screening engines."
    )


# ═══════════════════════════════════════════════════════════════════════════════
# T-11  COMPLIANCE_CONFIG_PATH env var overrides config path
# ═══════════════════════════════════════════════════════════════════════════════

def test_t11_env_var_override():
    """COMPLIANCE_CONFIG_PATH env var loads a different config file."""
    alt_yaml = textwrap.dedent("""\
        policy:
          version: "test-override"
          jurisdiction: "UK"
          regulator: "FCA"
          framework: "MLR 2017"
          audit_ttl_years: 7
        decision_thresholds:
          sar: 90
          reject: 75
          hold: 45
        watchman:
          url: "http://127.0.0.1:8084"
          min_match: 0.85
          timeout: 5
        sanctions_screening:
          yente_min_score: 0.85
        jurisdictions:
          hard_block: [RU, IR]
          high_risk:  [SY]
        transaction_monitoring:
          mlr_reporting_threshold_gbp: 15000
        forbidden_patterns:
          - bypass\\s+kyc
    """)

    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
        f.write(alt_yaml)
        tmp_path = f.name

    try:
        os.environ["COMPLIANCE_CONFIG_PATH"] = tmp_path
        reload_config()

        assert get_threshold_sar()    == 90
        assert get_threshold_reject() == 75
        assert get_threshold_hold()   == 45
        assert get_audit_ttl_years()  == 7
        assert get_mlr_reporting_threshold_gbp() == 15_000
        assert get_watchman_min_match() == pytest.approx(0.85)
    finally:
        del os.environ["COMPLIANCE_CONFIG_PATH"]
        os.unlink(tmp_path)
        reload_config()   # restore default config


# ═══════════════════════════════════════════════════════════════════════════════
# T-12  reload_config() clears cache
# ═══════════════════════════════════════════════════════════════════════════════

def test_t12_reload_config_clears_cache():
    """reload_config() forces re-read on next access."""
    reload_config()
    v1 = get_threshold_sar()
    reload_config()
    v2 = get_threshold_sar()
    # Values should be identical (same file), but cache was cleared
    assert v1 == v2


# ═══════════════════════════════════════════════════════════════════════════════
# T-13  compliance_validator exports correct constants after refactor
# ═══════════════════════════════════════════════════════════════════════════════

def test_t13_compliance_validator_exports():
    """
    compliance_validator.py still exports _THRESHOLD_* and _*_JURISDICTIONS
    with correct values after G-07 refactor (backward compat for all importers).
    """
    from compliance.verification.compliance_validator import (
        _THRESHOLD_SAR,
        _THRESHOLD_REJECT,
        _THRESHOLD_HOLD,
        _WATCHMAN_MIN_MATCH,
        _HARD_BLOCK_JURISDICTIONS,
        _HIGH_RISK_JURISDICTIONS,
    )
    assert _THRESHOLD_SAR    == 85
    assert _THRESHOLD_REJECT == 70
    assert _THRESHOLD_HOLD   == 40
    assert _WATCHMAN_MIN_MATCH == pytest.approx(0.80)
    assert "RU" in _HARD_BLOCK_JURISDICTIONS
    assert "SY" in _HIGH_RISK_JURISDICTIONS


# ═══════════════════════════════════════════════════════════════════════════════
# T-14  explanation_builder uses config values (no local hardcodes)
# ═══════════════════════════════════════════════════════════════════════════════

def test_t14_explanation_builder_uses_config():
    """
    After G-07, explanation_builder reads thresholds from config.
    Verified by temporarily overriding config and checking narrative output.
    """
    from unittest.mock import MagicMock

    def _make_result(decision, score, reason="threshold"):
        r = MagicMock()
        r.decision        = decision
        r.score           = score
        r.decision_reason = reason
        r.case_id         = "test-case"
        r.signals         = []
        return r

    alt_yaml = textwrap.dedent("""\
        policy:
          version: "test"
          jurisdiction: "UK"
          regulator: "FCA"
          framework: "MLR 2017"
          audit_ttl_years: 5
        decision_thresholds:
          sar: 90
          reject: 75
          hold: 45
        watchman:
          url: "http://127.0.0.1:8084"
          min_match: 0.80
          timeout: 5
        sanctions_screening:
          yente_min_score: 0.80
        jurisdictions:
          hard_block: [RU]
          high_risk:  [SY]
        transaction_monitoring:
          mlr_reporting_threshold_gbp: 10000
        forbidden_patterns:
          - bypass\\s+kyc
    """)

    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
        f.write(alt_yaml)
        tmp_path = f.name

    try:
        os.environ["COMPLIANCE_CONFIG_PATH"] = tmp_path
        reload_config()

        # Re-import to pick up new config values
        import importlib
        import compliance.utils.explanation_builder as eb_module
        importlib.reload(eb_module)

        result = _make_result("SAR", 92)
        bundle = eb_module.ExplanationBundle.from_banxe_result(result)
        # Narrative must use config threshold 90, not hardcoded 85
        assert "90" in bundle.narrative, (
            f"Narrative must use config SAR threshold (90), not hardcoded 85. "
            f"Got: {bundle.narrative}"
        )
    finally:
        del os.environ["COMPLIANCE_CONFIG_PATH"]
        os.unlink(tmp_path)
        reload_config()
        import compliance.utils.explanation_builder as eb_module
        importlib.reload(eb_module)


# ═══════════════════════════════════════════════════════════════════════════════
# T-15  sanctions_check WATCHMAN_MIN_MATCH comes from config
# ═══════════════════════════════════════════════════════════════════════════════

def test_t15_sanctions_check_watchman_from_config():
    """sanctions_check.WATCHMAN_MIN_MATCH is loaded from compliance_config.yaml."""
    import importlib
    import compliance.sanctions_check as sc
    importlib.reload(sc)

    assert sc.WATCHMAN_MIN_MATCH == pytest.approx(get_watchman_min_match())
    assert sc.YENTE_MIN_SCORE    == pytest.approx(get_yente_min_score())


# ═══════════════════════════════════════════════════════════════════════════════
# T-16  tx_monitor _MLR_REPORTING_THRESHOLD_GBP comes from config
# ═══════════════════════════════════════════════════════════════════════════════

def test_t16_tx_monitor_mlr_threshold_from_config():
    """tx_monitor._MLR_REPORTING_THRESHOLD_GBP is loaded from compliance_config.yaml."""
    import importlib
    import compliance.tx_monitor as tx
    importlib.reload(tx)

    assert tx._MLR_REPORTING_THRESHOLD_GBP == get_mlr_reporting_threshold_gbp()


# ═══════════════════════════════════════════════════════════════════════════════
# T-17  YAML has all required sections
# ═══════════════════════════════════════════════════════════════════════════════

def test_t17_yaml_required_sections():
    """All required YAML sections are present."""
    import yaml
    config_path = os.path.join(BASE, "compliance_config.yaml")
    with open(config_path) as f:
        data = yaml.safe_load(f)

    required = [
        "policy",
        "decision_thresholds",
        "watchman",
        "sanctions_screening",
        "jurisdictions",
        "transaction_monitoring",
        "forbidden_patterns",
    ]
    for section in required:
        assert section in data, f"Missing required section: {section}"


# ═══════════════════════════════════════════════════════════════════════════════
# T-18  policy_version is non-empty string
# ═══════════════════════════════════════════════════════════════════════════════

def test_t18_policy_version():
    """policy.version is a non-empty string for audit trail provenance."""
    v = get_policy_version()
    assert isinstance(v, str)
    assert len(v) > 0
