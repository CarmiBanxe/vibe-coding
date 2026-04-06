#!/usr/bin/env python3
"""
test_explanation_bundle.py — Unit tests for G-02 ExplanationBundle.

Tests:
  T-01  from_banxe_result() builds top_factors sorted by score desc
  T-02  top_factors format: (rule_id: str, contribution_pct: float, direction: str)
  T-03  contribution_pct = signal.score / 100
  T-04  direction is always "↑"
  T-05  top_factors limited to top_n (default 5)
  T-06  narrative is non-empty string
  T-07  APPROVE narrative: "approved" + score
  T-08  HOLD narrative: "EDD" or "Enhanced Due Diligence"
  T-09  REJECT narrative: "blocked" + reject threshold
  T-10  SAR narrative: "MLRO" + "NCA" + "POCA 2002"
  T-11  hard_override narrative: "Hard-block" + rule name
  T-12  high_risk_floor narrative: "high-risk floor"
  T-13  method = "rule-based"
  T-14  confidence = 0.95
  T-15  APPROVE → counterfactual is None
  T-16  HOLD → counterfactual.decision_would_be = "APPROVE"
  T-17  REJECT → counterfactual.decision_would_be = "HOLD"
  T-18  SAR → counterfactual.decision_would_be = "REJECT"
  T-19  to_dict() is JSON-serialisable
  T-20  to_dict() top_factors: lists not tuples (JSON compat)
  T-21  explanation_id is UUID string
  T-22  empty signals → top_factors = [], narrative still valid
  T-23  I-25: BanxeAMLResult.explanation is not None after banxe_assess()
  T-24  explanation in to_api_response() output

Invariant coverage:
  I-25: ExplanationBundle required for decisions > £10,000 (T-23, T-24)
"""
from __future__ import annotations

import asyncio
import json
import sys
import os
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

BASE = os.path.dirname(os.path.abspath(__file__))   # src/compliance/
SRC  = os.path.dirname(BASE)                         # src/
sys.path.insert(0, SRC)
sys.path.insert(0, BASE)

from compliance.utils.explanation_builder import (
    ExplanationBundle,
    CounterfactualExplanation,
)


def run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


# ── Helpers ───────────────────────────────────────────────────────────────────

def _make_signal(rule: str, score: int, source: str = "tx_monitor", reason: str = "") -> MagicMock:
    sig = MagicMock()
    sig.rule   = rule
    sig.score  = score
    sig.source = source
    sig.reason = reason or f"Test reason for {rule}"
    sig.authority = "MLR 2017"
    return sig


def _make_result(
    decision: str = "HOLD",
    score: int = 55,
    decision_reason: str = "threshold",
    signals=None,
    case_id: str = None,
    hard_block_hit: bool = False,
    sanctions_hit: bool = False,
) -> MagicMock:
    result = MagicMock()
    result.decision        = decision
    result.score           = score
    result.decision_reason = decision_reason
    result.case_id         = case_id or str(uuid.uuid4())
    result.hard_block_hit  = hard_block_hit
    result.sanctions_hit   = sanctions_hit
    result.signals         = signals or []
    return result


# ═══════════════════════════════════════════════════════════════════════════════
# T-01  top_factors sorted by score desc
# ═══════════════════════════════════════════════════════════════════════════════

def test_t01_top_factors_sorted_desc():
    """top_factors are ordered by score contribution descending."""
    signals = [
        _make_signal("RULE_LOW",  score=10),
        _make_signal("RULE_HIGH", score=50),
        _make_signal("RULE_MID",  score=30),
    ]
    result = _make_result(decision="REJECT", score=90, signals=signals)
    bundle = ExplanationBundle.from_banxe_result(result)

    scores = [f[1] for f in bundle.top_factors]
    assert scores == sorted(scores, reverse=True), "top_factors must be sorted by contribution_pct desc"
    assert bundle.top_factors[0][0] == "RULE_HIGH"


# ═══════════════════════════════════════════════════════════════════════════════
# T-02  top_factors format: (str, float, str)
# ═══════════════════════════════════════════════════════════════════════════════

def test_t02_top_factors_format():
    """Each top_factor is a (rule_id: str, contribution_pct: float, direction: str) tuple."""
    signals = [_make_signal("FPS_STRUCTURING", score=40)]
    result  = _make_result(decision="HOLD", score=40, signals=signals)
    bundle  = ExplanationBundle.from_banxe_result(result)

    assert len(bundle.top_factors) == 1
    rule_id, pct, direction = bundle.top_factors[0]
    assert isinstance(rule_id,   str)
    assert isinstance(pct,       float)
    assert isinstance(direction, str)


# ═══════════════════════════════════════════════════════════════════════════════
# T-03  contribution_pct = signal.score / 100
# ═══════════════════════════════════════════════════════════════════════════════

def test_t03_contribution_pct_formula():
    """contribution_pct = signal.score / 100, rounded to 4 decimal places."""
    signals = [_make_signal("RULE_A", score=55)]
    result  = _make_result(signals=signals)
    bundle  = ExplanationBundle.from_banxe_result(result)

    _, pct, _ = bundle.top_factors[0]
    assert pct == pytest.approx(0.55, abs=0.0001)


# ═══════════════════════════════════════════════════════════════════════════════
# T-04  direction is always "↑"
# ═══════════════════════════════════════════════════════════════════════════════

def test_t04_direction_always_up():
    """All signals increase risk → direction is always '↑'."""
    signals = [
        _make_signal("A", score=20),
        _make_signal("B", score=35),
    ]
    result = _make_result(signals=signals)
    bundle = ExplanationBundle.from_banxe_result(result)

    for _, _, direction in bundle.top_factors:
        assert direction == "↑"


# ═══════════════════════════════════════════════════════════════════════════════
# T-05  top_factors limited to top_n
# ═══════════════════════════════════════════════════════════════════════════════

def test_t05_top_factors_limited():
    """top_factors respects top_n (default 5)."""
    signals = [_make_signal(f"RULE_{i}", score=i * 5) for i in range(1, 12)]
    result  = _make_result(signals=signals)

    bundle3 = ExplanationBundle.from_banxe_result(result, top_n=3)
    assert len(bundle3.top_factors) == 3

    bundle5 = ExplanationBundle.from_banxe_result(result, top_n=5)
    assert len(bundle5.top_factors) == 5


# ═══════════════════════════════════════════════════════════════════════════════
# T-06  narrative is non-empty string
# ═══════════════════════════════════════════════════════════════════════════════

def test_t06_narrative_non_empty():
    """narrative is always a non-empty string."""
    for decision, score, reason in [
        ("APPROVE", 10, "threshold"),
        ("HOLD",    45, "threshold"),
        ("REJECT",  75, "threshold"),
        ("SAR",     90, "threshold"),
    ]:
        result = _make_result(decision=decision, score=score, decision_reason=reason)
        bundle = ExplanationBundle.from_banxe_result(result)
        assert isinstance(bundle.narrative, str)
        assert len(bundle.narrative) > 20, f"Narrative too short for {decision}"


# ═══════════════════════════════════════════════════════════════════════════════
# T-07  APPROVE narrative
# ═══════════════════════════════════════════════════════════════════════════════

def test_t07_approve_narrative():
    """APPROVE narrative mentions 'approved' and the score."""
    result = _make_result(decision="APPROVE", score=15, signals=[])
    bundle = ExplanationBundle.from_banxe_result(result)

    assert "approved" in bundle.narrative.lower()
    assert "15" in bundle.narrative


# ═══════════════════════════════════════════════════════════════════════════════
# T-08  HOLD narrative
# ═══════════════════════════════════════════════════════════════════════════════

def test_t08_hold_narrative():
    """HOLD narrative mentions EDD."""
    result = _make_result(decision="HOLD", score=45)
    bundle = ExplanationBundle.from_banxe_result(result)

    assert "edd" in bundle.narrative.lower() or "enhanced due diligence" in bundle.narrative.lower()


# ═══════════════════════════════════════════════════════════════════════════════
# T-09  REJECT narrative
# ═══════════════════════════════════════════════════════════════════════════════

def test_t09_reject_narrative():
    """REJECT narrative mentions 'blocked' and the reject threshold."""
    result = _make_result(decision="REJECT", score=72)
    bundle = ExplanationBundle.from_banxe_result(result)

    assert "blocked" in bundle.narrative.lower()
    assert "70" in bundle.narrative   # reject threshold


# ═══════════════════════════════════════════════════════════════════════════════
# T-10  SAR narrative
# ═══════════════════════════════════════════════════════════════════════════════

def test_t10_sar_narrative():
    """SAR narrative mentions MLRO, NCA, and POCA 2002."""
    result = _make_result(decision="SAR", score=90)
    bundle = ExplanationBundle.from_banxe_result(result)

    narrative_lower = bundle.narrative.lower()
    assert "mlro" in narrative_lower
    assert "nca"  in narrative_lower
    assert "poca" in narrative_lower


# ═══════════════════════════════════════════════════════════════════════════════
# T-11  hard_override narrative
# ═══════════════════════════════════════════════════════════════════════════════

def test_t11_hard_override_narrative():
    """hard_override decision_reason → narrative mentions 'Hard-block' and the rule."""
    signals = [_make_signal("HARD_BLOCK_JURISDICTION", score=100)]
    result  = _make_result(
        decision="REJECT", score=100,
        decision_reason="hard_override",
        signals=signals,
    )
    bundle = ExplanationBundle.from_banxe_result(result)

    assert "hard-block" in bundle.narrative.lower()
    assert "HARD_BLOCK_JURISDICTION" in bundle.narrative


# ═══════════════════════════════════════════════════════════════════════════════
# T-12  high_risk_floor narrative
# ═══════════════════════════════════════════════════════════════════════════════

def test_t12_high_risk_floor_narrative():
    """high_risk_floor decision_reason → narrative mentions 'high-risk floor'."""
    signals = [_make_signal("CUSTOMER_JURISDICTION_B", score=35)]
    result  = _make_result(
        decision="HOLD", score=35,
        decision_reason="high_risk_floor",
        signals=signals,
    )
    bundle = ExplanationBundle.from_banxe_result(result)

    assert "high-risk floor" in bundle.narrative.lower()


# ═══════════════════════════════════════════════════════════════════════════════
# T-13  method = "rule-based"
# ═══════════════════════════════════════════════════════════════════════════════

def test_t13_method_rule_based():
    """method is always 'rule-based' for this deterministic engine."""
    result = _make_result()
    bundle = ExplanationBundle.from_banxe_result(result)
    assert bundle.method == "rule-based"


# ═══════════════════════════════════════════════════════════════════════════════
# T-14  confidence = 0.95
# ═══════════════════════════════════════════════════════════════════════════════

def test_t14_confidence():
    """confidence = 0.95 (deterministic rule-based engine)."""
    result = _make_result()
    bundle = ExplanationBundle.from_banxe_result(result)
    assert bundle.confidence == pytest.approx(0.95)


# ═══════════════════════════════════════════════════════════════════════════════
# T-15  APPROVE → counterfactual is None
# ═══════════════════════════════════════════════════════════════════════════════

def test_t15_approve_no_counterfactual():
    """APPROVE is the best outcome — no counterfactual generated."""
    result = _make_result(decision="APPROVE", score=10)
    bundle = ExplanationBundle.from_banxe_result(result)
    assert bundle.counterfactual is None


# ═══════════════════════════════════════════════════════════════════════════════
# T-16  HOLD → counterfactual.decision_would_be = "APPROVE"
# ═══════════════════════════════════════════════════════════════════════════════

def test_t16_hold_counterfactual():
    """HOLD counterfactual: decision_was=HOLD, decision_would_be=APPROVE."""
    result = _make_result(decision="HOLD", score=45)
    bundle = ExplanationBundle.from_banxe_result(result, amount_gbp=15_000)

    assert bundle.counterfactual is not None
    assert bundle.counterfactual.decision_was      == "HOLD"
    assert bundle.counterfactual.decision_would_be == "APPROVE"
    assert "40" in bundle.counterfactual.nearest_threshold   # hold_threshold


# ═══════════════════════════════════════════════════════════════════════════════
# T-17  REJECT → counterfactual.decision_would_be = "HOLD"
# ═══════════════════════════════════════════════════════════════════════════════

def test_t17_reject_counterfactual():
    """REJECT counterfactual: decision_was=REJECT, decision_would_be=HOLD."""
    result = _make_result(decision="REJECT", score=72)
    bundle = ExplanationBundle.from_banxe_result(result)

    assert bundle.counterfactual is not None
    assert bundle.counterfactual.decision_was      == "REJECT"
    assert bundle.counterfactual.decision_would_be == "HOLD"
    assert "70" in bundle.counterfactual.nearest_threshold   # reject_threshold


# ═══════════════════════════════════════════════════════════════════════════════
# T-18  SAR → counterfactual.decision_would_be = "REJECT"
# ═══════════════════════════════════════════════════════════════════════════════

def test_t18_sar_counterfactual():
    """SAR counterfactual: decision_was=SAR, decision_would_be=REJECT."""
    result = _make_result(decision="SAR", score=90)
    bundle = ExplanationBundle.from_banxe_result(result)

    assert bundle.counterfactual is not None
    assert bundle.counterfactual.decision_was      == "SAR"
    assert bundle.counterfactual.decision_would_be == "REJECT"
    assert "85" in bundle.counterfactual.nearest_threshold   # sar_threshold


# ═══════════════════════════════════════════════════════════════════════════════
# T-19  to_dict() is JSON-serialisable
# ═══════════════════════════════════════════════════════════════════════════════

def test_t19_to_dict_json_serialisable():
    """to_dict() output must be JSON-serialisable."""
    signals = [_make_signal("FPS_STRUCTURING", score=55)]
    result  = _make_result(decision="HOLD", score=55, signals=signals)
    bundle  = ExplanationBundle.from_banxe_result(result, amount_gbp=20_000)

    d = bundle.to_dict()
    serialised = json.dumps(d)   # must not raise
    assert "HOLD" in serialised
    assert "rule-based" in serialised


# ═══════════════════════════════════════════════════════════════════════════════
# T-20  to_dict() top_factors: lists not tuples
# ═══════════════════════════════════════════════════════════════════════════════

def test_t20_to_dict_top_factors_are_lists():
    """to_dict() converts tuples → lists for JSON compat (tuples are not valid JSON)."""
    signals = [_make_signal("RULE_X", score=30)]
    result  = _make_result(signals=signals)
    bundle  = ExplanationBundle.from_banxe_result(result)

    d = bundle.to_dict()
    for factor in d["top_factors"]:
        assert isinstance(factor, list), "top_factors items must be lists in to_dict()"


# ═══════════════════════════════════════════════════════════════════════════════
# T-21  explanation_id is UUID string
# ═══════════════════════════════════════════════════════════════════════════════

def test_t21_explanation_id_is_uuid():
    """explanation_id is a valid UUID v4 string."""
    result = _make_result()
    bundle = ExplanationBundle.from_banxe_result(result)

    # Should not raise ValueError
    parsed = uuid.UUID(bundle.explanation_id)
    assert str(parsed) == bundle.explanation_id


# ═══════════════════════════════════════════════════════════════════════════════
# T-22  empty signals → top_factors = [], narrative still valid
# ═══════════════════════════════════════════════════════════════════════════════

def test_t22_empty_signals():
    """Empty signals list → top_factors=[], narrative is still a valid string."""
    result = _make_result(decision="APPROVE", score=0, signals=[])
    bundle = ExplanationBundle.from_banxe_result(result)

    assert bundle.top_factors == []
    assert isinstance(bundle.narrative, str)
    assert len(bundle.narrative) > 0
    # APPROVE narrative with empty signals: mentions score and 0 signals
    assert "0 signal" in bundle.narrative or "approved" in bundle.narrative.lower()


# ═══════════════════════════════════════════════════════════════════════════════
# T-23  I-25: BanxeAMLResult.explanation is not None after banxe_assess()
# ═══════════════════════════════════════════════════════════════════════════════

def test_t23_i25_banxe_assess_has_explanation():
    """
    I-25: banxe_assess() must attach a non-null ExplanationBundle to BanxeAMLResult.
    Verified for a transaction >= £10,000.
    """
    from compliance.models import AMLResult, TransactionInput, CustomerProfile
    mock_layer2 = AMLResult(
        decision="HOLD",
        score=45,
        signals=[],
        requires_edd=True,
        requires_mlro_review=False,
    )

    with patch("compliance.banxe_aml_orchestrator._layer2_assess",
               new=AsyncMock(return_value=mock_layer2)):
        import compliance.banxe_aml_orchestrator as orch

        result = run(orch.banxe_assess(
            transaction=TransactionInput("GB", "DE", 15_000.0),
            customer=CustomerProfile("CUST-I25"),
        ))

    assert result.explanation is not None, "I-25: explanation must not be None for tx >= £10,000"
    # Use class name check — module reloads in test_config_loader.py T-14 can create
    # distinct class objects for the same ExplanationBundle class, breaking isinstance.
    assert result.explanation.__class__.__name__ == "ExplanationBundle", (
        f"explanation must be ExplanationBundle, got {type(result.explanation)}"
    )
    assert result.explanation.decision == result.decision
    assert result.explanation.case_id  == result.case_id


# ═══════════════════════════════════════════════════════════════════════════════
# T-24  explanation in to_api_response()
# ═══════════════════════════════════════════════════════════════════════════════

def test_t24_explanation_in_api_response():
    """explanation appears in to_api_response() output when present."""
    from compliance.models import AMLResult, TransactionInput, CustomerProfile
    mock_layer2 = AMLResult(
        decision="APPROVE",
        score=10,
        signals=[],
        requires_edd=False,
        requires_mlro_review=False,
    )

    with patch("compliance.banxe_aml_orchestrator._layer2_assess",
               new=AsyncMock(return_value=mock_layer2)):
        import compliance.banxe_aml_orchestrator as orch

        result = run(orch.banxe_assess(
            transaction=TransactionInput("GB", "DE", 500.0),
            customer=CustomerProfile("CUST-API"),
        ))

    api_resp = result.to_api_response()
    assert "explanation" in api_resp
    assert api_resp["explanation"]["method"]   == "rule-based"
    assert api_resp["explanation"]["decision"] == "APPROVE"
    assert api_resp["explanation"]["confidence"] == pytest.approx(0.95)
    # JSON-serialisable
    json.dumps(api_resp)
