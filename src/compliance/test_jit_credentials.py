"""
test_jit_credentials.py — G-10 Zero Standing Privileges Tests

T-01  issue_credential returns TemporaryCredential with correct fields
T-02  issued credential is not expired immediately after issuance
T-03  credential token is 64-char hex string
T-04  two credentials have different tokens (uniqueness)
T-05  TTL expiry: credential expired after time.sleep
T-06  assert_valid raises CredentialExpiredError on expired credential
T-07  validate returns credential for valid token
T-08  validate raises CredentialExpiredError after TTL
T-09  revoke returns True for active credential
T-10  revoke returns False for already-revoked token
T-11  validate raises CredentialRevokedError after explicit revoke
T-12  ZSP-01: Level-3 agent cannot receive EMIT_DECISION
T-13  ZSP-01: Level-3 agent cannot receive APPEND_AUDIT
T-14  ZSP-01: Level-3 agent cannot receive CHECK_EMERGENCY
T-15  ZSP-01: Level-3 agent cannot receive ORCHESTRATE
T-16  ZSP-01: Level-3 agent CAN receive READ_POLICY
T-17  ZSP-01: Level-2 agent cannot receive ORCHESTRATE
T-18  ZSP-01: Level-2 agent CAN receive EMIT_DECISION
T-19  ZSP-01: Level-1 agent CAN receive ORCHESTRATE
T-20  issue_credential raises ValueError for empty agent_id
T-21  issue_credential raises ValueError for invalid level (0 or 4)
T-22  revoke_all_for_agent revokes all active creds for that agent
T-23  active_count decreases after revocation
T-24  purge_expired removes expired credentials
T-25  active_for_agent returns only credentials for that agent
T-26  CredentialScope.POLICY_WRITE does not exist in enum (I-22)
T-27  get_credential_manager returns singleton
T-28  TemporaryCredential.to_dict() does not expose full token
"""
from __future__ import annotations

import time
import pytest

from compliance.security.jit_credentials import (
    CredentialScope,
    TemporaryCredential,
    JITCredentialManager,
    InMemoryCredentialStore,
    CredentialError,
    CredentialExpiredError,
    CredentialRevokedError,
    ScopeViolationError,
    get_credential_manager,
)


@pytest.fixture
def mgr():
    """Fresh manager per test."""
    return JITCredentialManager(default_ttl=300)


# ── T-01: basic issuance ──────────────────────────────────────────────────────

def test_T01_issue_returns_credential(mgr):
    cred = mgr.issue_credential("sanctions_check", CredentialScope.READ_POLICY, level=2)
    assert isinstance(cred, TemporaryCredential)
    assert cred.agent_id == "sanctions_check"
    assert cred.scope == CredentialScope.READ_POLICY
    assert cred.level == 2


# ── T-02: not expired immediately ────────────────────────────────────────────

def test_T02_not_expired_immediately(mgr):
    cred = mgr.issue_credential("tx_monitor", CredentialScope.EMIT_DECISION, level=1)
    assert not cred.is_expired


# ── T-03: token format ────────────────────────────────────────────────────────

def test_T03_token_is_hex(mgr):
    cred = mgr.issue_credential("a1", CredentialScope.READ_POLICY, level=2)
    assert len(cred.token) == 64
    int(cred.token, 16)  # must be valid hex


# ── T-04: tokens are unique ───────────────────────────────────────────────────

def test_T04_tokens_are_unique(mgr):
    c1 = mgr.issue_credential("agent_x", CredentialScope.READ_POLICY, level=2)
    c2 = mgr.issue_credential("agent_x", CredentialScope.READ_POLICY, level=2)
    assert c1.token != c2.token


# ── T-05: TTL expiry ─────────────────────────────────────────────────────────

def test_T05_credential_expires_after_ttl(mgr):
    cred = mgr.issue_credential("fast_agent", CredentialScope.READ_POLICY, level=2, ttl=1)
    assert not cred.is_expired
    time.sleep(1.1)
    assert cred.is_expired


# ── T-06: assert_valid raises on expired ─────────────────────────────────────

def test_T06_assert_valid_raises_when_expired(mgr):
    cred = mgr.issue_credential("a", CredentialScope.READ_POLICY, level=2, ttl=1)
    time.sleep(1.1)
    with pytest.raises(CredentialExpiredError):
        cred.assert_valid()


# ── T-07: validate returns active credential ──────────────────────────────────

def test_T07_validate_returns_credential(mgr):
    cred = mgr.issue_credential("agent_a", CredentialScope.READ_POLICY, level=2)
    validated = mgr.validate(cred.token)
    assert validated.token == cred.token


# ── T-08: validate raises after TTL ──────────────────────────────────────────

def test_T08_validate_raises_after_ttl(mgr):
    cred = mgr.issue_credential("agent_b", CredentialScope.READ_POLICY, level=2, ttl=1)
    time.sleep(1.1)
    with pytest.raises(CredentialExpiredError):
        mgr.validate(cred.token)


# ── T-09: revoke returns True for active ─────────────────────────────────────

def test_T09_revoke_returns_true_for_active(mgr):
    cred = mgr.issue_credential("agent_c", CredentialScope.READ_POLICY, level=2)
    assert mgr.revoke(cred.token) is True


# ── T-10: revoke returns False for already-revoked ────────────────────────────

def test_T10_revoke_returns_false_already_revoked(mgr):
    cred = mgr.issue_credential("agent_d", CredentialScope.READ_POLICY, level=2)
    mgr.revoke(cred.token)
    assert mgr.revoke(cred.token) is False


# ── T-11: validate raises after revoke ───────────────────────────────────────

def test_T11_validate_raises_after_revoke(mgr):
    cred = mgr.issue_credential("agent_e", CredentialScope.READ_POLICY, level=2)
    mgr.revoke(cred.token)
    with pytest.raises(CredentialRevokedError):
        mgr.validate(cred.token)


# ── T-12..T-15: Level-3 forbidden scopes ─────────────────────────────────────

@pytest.mark.parametrize("scope", [
    CredentialScope.EMIT_DECISION,
    CredentialScope.APPEND_AUDIT,
    CredentialScope.CHECK_EMERGENCY,
    CredentialScope.ORCHESTRATE,
])
def test_T12_to_T15_level3_cannot_receive_privileged_scopes(mgr, scope):
    with pytest.raises(ScopeViolationError, match="Level-3"):
        mgr.issue_credential("watchman_adapter", scope, level=3)


# ── T-16: Level-3 CAN receive READ_POLICY ────────────────────────────────────

def test_T16_level3_can_receive_read_policy(mgr):
    cred = mgr.issue_credential("watchman_adapter", CredentialScope.READ_POLICY, level=3)
    assert cred.scope == CredentialScope.READ_POLICY


# ── T-17: Level-2 cannot receive ORCHESTRATE ─────────────────────────────────

def test_T17_level2_cannot_receive_orchestrate(mgr):
    with pytest.raises(ScopeViolationError, match="Level-2"):
        mgr.issue_credential("aml_orchestrator", CredentialScope.ORCHESTRATE, level=2)


# ── T-18: Level-2 CAN receive EMIT_DECISION ──────────────────────────────────

def test_T18_level2_can_receive_emit_decision(mgr):
    cred = mgr.issue_credential("aml_orchestrator", CredentialScope.EMIT_DECISION, level=2)
    assert cred.scope == CredentialScope.EMIT_DECISION


# ── T-19: Level-1 CAN receive ORCHESTRATE ────────────────────────────────────

def test_T19_level1_can_receive_orchestrate(mgr):
    cred = mgr.issue_credential("banxe_aml_orchestrator", CredentialScope.ORCHESTRATE, level=1)
    assert cred.scope == CredentialScope.ORCHESTRATE


# ── T-20: empty agent_id ─────────────────────────────────────────────────────

def test_T20_empty_agent_id_raises(mgr):
    with pytest.raises(ValueError, match="agent_id"):
        mgr.issue_credential("", CredentialScope.READ_POLICY, level=2)


# ── T-21: invalid level ───────────────────────────────────────────────────────

@pytest.mark.parametrize("bad_level", [0, 4, -1, 99])
def test_T21_invalid_level_raises(mgr, bad_level):
    with pytest.raises(ValueError, match="level"):
        mgr.issue_credential("x", CredentialScope.READ_POLICY, level=bad_level)


# ── T-22: revoke_all_for_agent ────────────────────────────────────────────────

def test_T22_revoke_all_for_agent(mgr):
    mgr.issue_credential("multi_agent", CredentialScope.READ_POLICY, level=2)
    mgr.issue_credential("multi_agent", CredentialScope.EMIT_DECISION, level=2)
    mgr.issue_credential("other_agent", CredentialScope.READ_POLICY, level=2)
    count = mgr.revoke_all_for_agent("multi_agent")
    assert count == 2
    # other_agent credential still active
    assert mgr.active_count() == 1


# ── T-23: active_count decreases ─────────────────────────────────────────────

def test_T23_active_count_decreases_after_revoke(mgr):
    c1 = mgr.issue_credential("a", CredentialScope.READ_POLICY, level=2)
    c2 = mgr.issue_credential("b", CredentialScope.READ_POLICY, level=2)
    assert mgr.active_count() == 2
    mgr.revoke(c1.token)
    assert mgr.active_count() == 1


# ── T-24: purge_expired ───────────────────────────────────────────────────────

def test_T24_purge_expired_cleans_store(mgr):
    mgr.issue_credential("fast", CredentialScope.READ_POLICY, level=2, ttl=1)
    mgr.issue_credential("slow", CredentialScope.READ_POLICY, level=2, ttl=300)
    time.sleep(1.1)
    purged = mgr.purge_expired()
    assert purged == 1
    assert mgr.active_count() == 1


# ── T-25: active_for_agent ────────────────────────────────────────────────────

def test_T25_active_for_agent(mgr):
    mgr.issue_credential("alpha", CredentialScope.READ_POLICY, level=2)
    mgr.issue_credential("alpha", CredentialScope.EMIT_DECISION, level=2)
    mgr.issue_credential("beta", CredentialScope.READ_POLICY, level=2)
    alpha_creds = mgr._store.active_for_agent("alpha")
    assert len(alpha_creds) == 2
    assert all(c.agent_id == "alpha" for c in alpha_creds)


# ── T-26: POLICY_WRITE does not exist (I-22) ─────────────────────────────────

def test_T26_policy_write_scope_does_not_exist():
    """I-22: PolicyPort has no write methods — reflected in CredentialScope."""
    scope_values = {s.value for s in CredentialScope}
    assert "policy_write" not in scope_values
    assert not hasattr(CredentialScope, "POLICY_WRITE")


# ── T-27: singleton ──────────────────────────────────────────────────────────

def test_T27_get_credential_manager_returns_singleton():
    m1 = get_credential_manager()
    m2 = get_credential_manager()
    assert m1 is m2


# ── T-28: to_dict does not expose full token ──────────────────────────────────

def test_T28_to_dict_truncates_token(mgr):
    cred = mgr.issue_credential("agent", CredentialScope.READ_POLICY, level=2)
    d = cred.to_dict()
    assert "token_prefix" in d
    assert d["token_prefix"].endswith("...")
    assert len(d["token_prefix"]) < 20  # not the full 64-char token
    assert "token" not in d  # full token NOT in dict
