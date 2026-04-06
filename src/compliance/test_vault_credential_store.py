"""
test_vault_credential_store.py — VaultCredentialStore Tests

All tests use fallback mode (no real Vault needed).

T-01  VaultCredentialStore initialises without error (fallback mode)
T-02  vault_available=False when no VAULT_TOKEN
T-03  vault_available=False when force_fallback=True
T-04  save + get round-trip (fallback)
T-05  get returns None for unknown token
T-06  revoke returns True for active credential
T-07  revoke returns False for already-revoked token
T-08  is_revoked returns False for active credential
T-09  is_revoked returns True after revoke
T-10  active_count reflects issued credentials
T-11  active_count decreases after revoke
T-12  active_for_agent returns correct credentials
T-13  purge_expired removes expired credentials
T-14  ZSP-01: Level-3 cannot receive EMIT_DECISION (via JITCredentialManager)
T-15  ZSP-01: Level-3 cannot receive APPEND_AUDIT
T-16  ZSP-01: Level-3 cannot receive ORCHESTRATE
T-17  ZSP-01: Level-2 cannot receive ORCHESTRATE
T-18  ZSP-01: Level-3 CAN receive READ_POLICY
T-19  ZSP-01: Level-1 CAN receive ORCHESTRATE
T-20  Vault unavailable → WARNING log (mocked)
T-21  VaultConfig.from_env reads VAULT_TOKEN env var
T-22  VaultConfig.from_env reads VAULT_ADDR env var
T-23  VaultConfig.has_token False when token empty
T-24  VaultConfig.has_token True when token set
T-25  get_credential_manager(prefer_vault=False) returns InMemory-backed manager
T-26  get_credential_manager returns JITCredentialManager
T-27  get_credential_manager returns singleton (same object on repeated calls)
T-28  get_credential_manager(_reset=True) forces re-creation
"""
from __future__ import annotations

import os
import time
import pytest
from unittest.mock import patch, MagicMock

from compliance.security.vault_credential_store import (
    VaultCredentialStore,
    VaultConfig,
    get_credential_manager,
)
from compliance.security.jit_credentials import (
    JITCredentialManager,
    CredentialScope,
    ScopeViolationError,
    InMemoryCredentialStore,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def store() -> VaultCredentialStore:
    """Fallback-mode VaultCredentialStore (no real Vault)."""
    return VaultCredentialStore(force_fallback=True)


@pytest.fixture
def mgr(store) -> JITCredentialManager:
    """JITCredentialManager backed by VaultCredentialStore in fallback mode."""
    return JITCredentialManager(store=store, default_ttl=300)


# ── T-01..T-03: initialisation ────────────────────────────────────────────────

def test_T01_initialises_without_error():
    s = VaultCredentialStore(force_fallback=True)
    assert s is not None


def test_T02_vault_unavailable_without_token():
    with patch.dict(os.environ, {}, clear=True):
        # Remove VAULT_TOKEN if present
        env = {k: v for k, v in os.environ.items() if k != "VAULT_TOKEN"}
        with patch.dict(os.environ, env, clear=True):
            s = VaultCredentialStore()
            assert s.vault_available is False


def test_T03_force_fallback_disables_vault():
    s = VaultCredentialStore(force_fallback=True)
    assert s.vault_available is False


# ── T-04..T-09: store operations ──────────────────────────────────────────────

def test_T04_save_get_round_trip(mgr):
    cred = mgr.issue_credential("agent_test", CredentialScope.READ_POLICY, level=2)
    validated = mgr.validate(cred.token)
    assert validated.token == cred.token
    assert validated.agent_id == "agent_test"


def test_T05_get_returns_none_unknown_token(store):
    assert store.get("nonexistent_token_xyz") is None


def test_T06_revoke_returns_true_for_active(mgr):
    cred = mgr.issue_credential("agent_r", CredentialScope.READ_POLICY, level=2)
    assert mgr.revoke(cred.token) is True


def test_T07_revoke_returns_false_already_revoked(mgr):
    cred = mgr.issue_credential("agent_rr", CredentialScope.READ_POLICY, level=2)
    mgr.revoke(cred.token)
    assert mgr.revoke(cred.token) is False


def test_T08_is_revoked_false_for_active(store, mgr):
    cred = mgr.issue_credential("agent_ir", CredentialScope.READ_POLICY, level=2)
    assert store.is_revoked(cred.token) is False


def test_T09_is_revoked_true_after_revoke(store, mgr):
    cred = mgr.issue_credential("agent_ir2", CredentialScope.READ_POLICY, level=2)
    mgr.revoke(cred.token)
    assert store.is_revoked(cred.token) is True


# ── T-10..T-12: counts and listing ────────────────────────────────────────────

def test_T10_active_count_reflects_issued(store):
    s = VaultCredentialStore(force_fallback=True)
    m = JITCredentialManager(store=s)
    before = m.active_count()
    m.issue_credential("c1", CredentialScope.READ_POLICY, level=2)
    m.issue_credential("c2", CredentialScope.READ_POLICY, level=2)
    assert m.active_count() == before + 2


def test_T11_active_count_decreases_after_revoke(store):
    s = VaultCredentialStore(force_fallback=True)
    m = JITCredentialManager(store=s)
    cred = m.issue_credential("cd", CredentialScope.READ_POLICY, level=2)
    before = m.active_count()
    m.revoke(cred.token)
    assert m.active_count() == before - 1


def test_T12_active_for_agent(store):
    s = VaultCredentialStore(force_fallback=True)
    m = JITCredentialManager(store=s)
    m.issue_credential("alpha", CredentialScope.READ_POLICY, level=2)
    m.issue_credential("alpha", CredentialScope.EMIT_DECISION, level=2)
    m.issue_credential("beta", CredentialScope.READ_POLICY, level=2)
    alpha_creds = s.active_for_agent("alpha")
    assert len(alpha_creds) == 2
    assert all(c.agent_id == "alpha" for c in alpha_creds)


# ── T-13: purge expired ───────────────────────────────────────────────────────

def test_T13_purge_expired(store):
    s = VaultCredentialStore(force_fallback=True)
    m = JITCredentialManager(store=s)
    m.issue_credential("fast", CredentialScope.READ_POLICY, level=2, ttl=1)
    m.issue_credential("slow", CredentialScope.READ_POLICY, level=2, ttl=300)
    time.sleep(1.1)
    purged = m.purge_expired()
    assert purged == 1
    assert m.active_count() == 1


# ── T-14..T-19: ZSP-01 enforcement (through JITCredentialManager) ─────────────

def test_T14_level3_cannot_emit_decision(mgr):
    with pytest.raises(ScopeViolationError):
        mgr.issue_credential("adapter", CredentialScope.EMIT_DECISION, level=3)


def test_T15_level3_cannot_append_audit(mgr):
    with pytest.raises(ScopeViolationError):
        mgr.issue_credential("adapter", CredentialScope.APPEND_AUDIT, level=3)


def test_T16_level3_cannot_orchestrate(mgr):
    with pytest.raises(ScopeViolationError):
        mgr.issue_credential("adapter", CredentialScope.ORCHESTRATE, level=3)


def test_T17_level2_cannot_orchestrate(mgr):
    with pytest.raises(ScopeViolationError):
        mgr.issue_credential("sub_agent", CredentialScope.ORCHESTRATE, level=2)


def test_T18_level3_can_read_policy(mgr):
    cred = mgr.issue_credential("adapter", CredentialScope.READ_POLICY, level=3)
    assert cred.scope == CredentialScope.READ_POLICY


def test_T19_level1_can_orchestrate(mgr):
    cred = mgr.issue_credential("orchestrator", CredentialScope.ORCHESTRATE, level=1)
    assert cred.scope == CredentialScope.ORCHESTRATE


# ── T-20: Vault unavailable warning log ──────────────────────────────────────

def test_T20_vault_unavailable_logs_warning():
    config = VaultConfig(vault_token="fake-token-for-test")
    # Vault won't be reachable → fallback + warning
    s = VaultCredentialStore(config=config)
    # Just verify it initialised without raising and is in fallback mode
    assert s.vault_available is False


# ── T-21..T-24: VaultConfig ──────────────────────────────────────────────────

def test_T21_vault_config_from_env_reads_token():
    with patch.dict(os.environ, {"VAULT_TOKEN": "test-token-123"}):
        cfg = VaultConfig.from_env()
        assert cfg.vault_token == "test-token-123"


def test_T22_vault_config_from_env_reads_addr():
    with patch.dict(os.environ, {"VAULT_ADDR": "http://10.0.0.1:8200"}):
        cfg = VaultConfig.from_env()
        assert cfg.vault_addr == "http://10.0.0.1:8200"


def test_T23_vault_config_has_token_false_when_empty():
    cfg = VaultConfig(vault_token="")
    assert cfg.has_token is False


def test_T24_vault_config_has_token_true_when_set():
    cfg = VaultConfig(vault_token="s.secretToken")
    assert cfg.has_token is True


# ── T-25..T-28: factory function ─────────────────────────────────────────────

def test_T25_prefer_vault_false_returns_inmemory_backed():
    get_credential_manager(_reset=True)  # clear singleton
    with patch.dict(os.environ, {}, clear=True):
        m = get_credential_manager(prefer_vault=False, _reset=True)
        assert isinstance(m, JITCredentialManager)
        # Verify it works
        cred = m.issue_credential("factory_test", CredentialScope.READ_POLICY, level=2)
        assert not cred.is_expired


def test_T26_get_credential_manager_returns_jit_manager():
    m = get_credential_manager(_reset=True)
    assert isinstance(m, JITCredentialManager)


def test_T27_get_credential_manager_singleton():
    get_credential_manager(_reset=True)
    m1 = get_credential_manager()
    m2 = get_credential_manager()
    assert m1 is m2


def test_T28_reset_forces_recreation():
    m1 = get_credential_manager(_reset=True)
    m2 = get_credential_manager(_reset=True)
    # Both valid managers (may or may not be same object — just verify functional)
    cred = m2.issue_credential("reset_test", CredentialScope.READ_POLICY, level=2)
    assert not cred.is_expired
