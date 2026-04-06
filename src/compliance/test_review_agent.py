"""
test_review_agent.py — G-15 Multi-Agent Review Pattern Tests

T-01  review returns ReviewResult instance
T-02  CLASS_A change to non-sensitive file → APPROVE
T-03  CLASS_B change → automatic REJECT
T-04  CLASS_C change → automatic ESCALATE_TO_HUMAN
T-05  CLASS_D change → automatic REJECT
T-06  REJECT has approved=False
T-07  ESCALATE_TO_HUMAN has approved=False
T-08  APPROVE has approved=True (no concerns)
T-09  I-21 violation: SOUL.md in target_file → high risk_score + concern
T-10  I-22 violation: level-2 write to banxe-architecture/ → concern added
T-11  I-22 violation: level-3 write to policy path → concern added
T-12  I-22: level-1 write to policy path → no I-22 concern
T-13  trust zone violation: .rego file in target → concern added
T-14  BC boundary: adapter imports from CTX-01 → concern added
T-15  BC boundary: non-audit imports from CTX-03 → concern added
T-16  no rationale → concern added
T-17  risk_score > 50 → ESCALATE_TO_HUMAN for CLASS_A
T-18  risk_score > 80 → REJECT for CLASS_A
T-19  audit log called on every review (I-24)
T-20  auto-detect CLASS_B for SOUL.md target
T-21  auto-detect CLASS_C for compliance_config.yaml target
T-22  auto-detect CLASS_C for .rego file target
T-23  auto-detect CLASS_D for ADR- file target
T-24  auto-detect CLASS_A for regular .py file
T-25  ReviewResult reviewer_agent_id is set
T-26  resolved_class populated in result
T-27  concerns is a list (possibly empty)
T-28  APPROVE: concerns empty + risk_score low + approved=True
"""
from __future__ import annotations

import pytest
from unittest.mock import MagicMock

from compliance.review.review_agent import (
    ReviewAgent,
    ReviewRequest,
    ReviewResult,
    Recommendation,
    CLASS_A, CLASS_B, CLASS_C, CLASS_D,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def agent():
    return ReviewAgent()


def _clean_request(**kwargs) -> ReviewRequest:
    defaults = {
        "proposed_change": "- old_line\n+ new_line\n",
        "author_agent_id": "feedback_agent",
        "target_file": "src/compliance/banxe_aml_orchestrator.py",
        "rationale": "Improve performance",
        "change_class": CLASS_A,
        "author_level": 2,
    }
    defaults.update(kwargs)
    return ReviewRequest(**defaults)


# ── T-01..T-02: basic ─────────────────────────────────────────────────────────

def test_T01_returns_review_result(agent):
    result = agent.review(_clean_request())
    assert isinstance(result, ReviewResult)


def test_T02_class_a_safe_file_approve(agent):
    req = _clean_request(
        target_file="src/compliance/utils/some_helper.py",
        change_class=CLASS_A,
        author_level=2,
        rationale="Fix a minor bug",
    )
    result = agent.review(req)
    assert result.recommendation == Recommendation.APPROVE
    assert result.approved is True


# ── T-03..T-05: hard gates ────────────────────────────────────────────────────

def test_T03_class_b_auto_reject(agent):
    req = _clean_request(change_class=CLASS_B, target_file="SOUL.md")
    result = agent.review(req)
    assert result.recommendation == Recommendation.REJECT
    assert result.approved is False
    assert result.risk_score == 100


def test_T04_class_c_escalate(agent):
    req = _clean_request(change_class=CLASS_C, target_file="compliance_config.yaml")
    result = agent.review(req)
    assert result.recommendation == Recommendation.ESCALATE_TO_HUMAN
    assert result.approved is False


def test_T05_class_d_reject(agent):
    req = _clean_request(change_class=CLASS_D, target_file="banxe-architecture/decisions/ADR-010.md")
    result = agent.review(req)
    assert result.recommendation == Recommendation.REJECT
    assert result.approved is False


# ── T-06..T-08: approved flag ─────────────────────────────────────────────────

def test_T06_reject_approved_false(agent):
    result = agent.review(_clean_request(change_class=CLASS_B))
    assert result.approved is False


def test_T07_escalate_approved_false(agent):
    result = agent.review(_clean_request(change_class=CLASS_C))
    assert result.approved is False


def test_T08_approve_approved_true(agent):
    req = _clean_request(
        target_file="src/compliance/test_something.py",
        change_class=CLASS_A,
        author_level=1,
        rationale="Adding new test coverage",
    )
    result = agent.review(req)
    assert result.approved is True


# ── T-09: I-21 violation ──────────────────────────────────────────────────────

def test_T09_i21_violation_soul_in_path(agent):
    req = _clean_request(
        target_file="docs/SOUL.md",
        change_class=CLASS_A,  # force CLASS_A to test rule, not class gate
    )
    result = agent.review(req)
    assert result.risk_score >= 90
    assert any("I-21" in c for c in result.concerns)


# ── T-10..T-12: I-22 violations ──────────────────────────────────────────────

def test_T10_i22_level2_write_banxe_architecture(agent):
    req = _clean_request(
        target_file="banxe-architecture/INVARIANTS.md",
        change_class=CLASS_A,
        author_level=2,
        rationale="fix typo",
    )
    result = agent.review(req)
    assert any("I-22" in c for c in result.concerns)


def test_T11_i22_level3_write_policy_path(agent):
    req = _clean_request(
        target_file="developer-core/compliance/rules.py",
        change_class=CLASS_A,
        author_level=3,
        rationale="fix",
    )
    result = agent.review(req)
    assert any("I-22" in c for c in result.concerns)


def test_T12_i22_level1_no_violation(agent):
    req = _clean_request(
        target_file="developer-core/compliance/rules.py",
        change_class=CLASS_A,
        author_level=1,
        rationale="Authorized change by orchestrator",
    )
    result = agent.review(req)
    # Level-1 should not trigger I-22
    assert not any("I-22" in c for c in result.concerns)


# ── T-13: trust zone violation ────────────────────────────────────────────────

def test_T13_trust_zone_rego_file(agent):
    req = _clean_request(
        target_file="banxe_compliance.rego",
        change_class=CLASS_A,
        rationale="test",
    )
    result = agent.review(req)
    assert any("Zone RED" in c or "trust zone" in c.lower() for c in result.concerns)


# ── T-14..T-15: BC boundary ───────────────────────────────────────────────────

def test_T14_bc_adapter_imports_ctx01(agent):
    req = _clean_request(
        target_file="src/compliance/adapters/some_adapter.py",
        proposed_change="from compliance.banxe_aml_orchestrator import BanxeAMLOrchestrator\n",
        change_class=CLASS_A,
        rationale="direct import",
    )
    result = agent.review(req)
    assert any("CTX-01" in c or "adapter" in c.lower() for c in result.concerns)


def test_T15_bc_non_audit_imports_ctx03(agent):
    req = _clean_request(
        target_file="src/compliance/banxe_aml_orchestrator.py",
        proposed_change="from compliance.event_sourcing.store import EventStore\n",
        change_class=CLASS_A,
        rationale="audit import",
    )
    result = agent.review(req)
    assert any("CTX-03" in c for c in result.concerns)


# ── T-16: no rationale ───────────────────────────────────────────────────────

def test_T16_no_rationale_adds_concern(agent):
    req = _clean_request(rationale="", change_class=CLASS_A)
    result = agent.review(req)
    assert any("rationale" in c.lower() for c in result.concerns)


# ── T-17..T-18: risk score thresholds ────────────────────────────────────────

def test_T17_risk_over_50_escalates(agent):
    # I-22 adds 85 points — should push to REJECT (>80) or ESCALATE (>50)
    req = _clean_request(
        target_file="banxe-architecture/INVARIANTS.md",
        change_class=CLASS_A,
        author_level=2,
        rationale="fix",
    )
    result = agent.review(req)
    assert result.risk_score > 50
    assert result.recommendation in (Recommendation.ESCALATE_TO_HUMAN, Recommendation.REJECT)


def test_T18_risk_over_80_rejects(agent):
    # I-21 adds 90 points → should REJECT
    req = _clean_request(
        target_file="docs/SOUL.md",
        change_class=CLASS_A,
        author_level=2,
        rationale="update soul",
    )
    result = agent.review(req)
    assert result.risk_score > 80
    assert result.recommendation == Recommendation.REJECT


# ── T-19: audit logging ───────────────────────────────────────────────────────

def test_T19_audit_log_called(agent):
    agent._logger = MagicMock()
    agent.review(_clean_request())
    agent._logger.event.assert_called_once()
    call_str = str(agent._logger.event.call_args)
    assert "REVIEW_DECISION" in call_str


# ── T-20..T-24: auto-detect change class ─────────────────────────────────────

def test_T20_auto_detect_class_b_soul(agent):
    req = ReviewRequest(
        proposed_change="diff",
        author_agent_id="feedback",
        target_file="SOUL.md",
        rationale="test",
    )
    result = agent.review(req)
    assert result.resolved_class == CLASS_B


def test_T21_auto_detect_class_c_config(agent):
    req = ReviewRequest(
        proposed_change="diff",
        author_agent_id="feedback",
        target_file="compliance_config.yaml",
        rationale="test",
    )
    result = agent.review(req)
    assert result.resolved_class == CLASS_C


def test_T22_auto_detect_class_c_rego(agent):
    req = ReviewRequest(
        proposed_change="diff",
        author_agent_id="feedback",
        target_file="banxe_compliance.rego",
        rationale="test",
    )
    result = agent.review(req)
    assert result.resolved_class == CLASS_C


def test_T23_auto_detect_class_d_adr(agent):
    req = ReviewRequest(
        proposed_change="diff",
        author_agent_id="feedback",
        target_file="banxe-architecture/decisions/ADR-012.md",
        rationale="test",
    )
    result = agent.review(req)
    assert result.resolved_class == CLASS_D


def test_T24_auto_detect_class_a_regular_py(agent):
    req = ReviewRequest(
        proposed_change="diff",
        author_agent_id="feedback",
        target_file="src/compliance/sanctions_check.py",
        rationale="test",
    )
    result = agent.review(req)
    assert result.resolved_class == CLASS_A


# ── T-25..T-28: result structure ──────────────────────────────────────────────

def test_T25_reviewer_agent_id_set(agent):
    result = agent.review(_clean_request())
    assert result.reviewer_agent_id == "review_agent_v1"


def test_T26_resolved_class_populated(agent):
    result = agent.review(_clean_request(change_class=CLASS_A))
    assert result.resolved_class == CLASS_A


def test_T27_concerns_is_list(agent):
    result = agent.review(_clean_request())
    assert isinstance(result.concerns, list)


def test_T28_clean_approve_all_fields(agent):
    req = _clean_request(
        target_file="src/compliance/test_something.py",
        change_class=CLASS_A,
        author_level=1,
        rationale="Add test for edge case",
        proposed_change="+ def test_edge_case(): pass\n",
    )
    result = agent.review(req)
    assert result.approved is True
    assert result.concerns == []
    assert result.risk_score < 50
    assert result.recommendation == Recommendation.APPROVE
