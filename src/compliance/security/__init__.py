"""
security/ — BANXE Zero Standing Privileges (G-10)

JIT credential management for compliance agents.
Provides TemporaryCredential lifecycle (issue → use → auto-revoke on TTL).

Interface is Vault-ready: replace InMemoryCredentialStore with VaultAdapter in Sprint 5.
"""
from .jit_credentials import (
    CredentialScope,
    TemporaryCredential,
    JITCredentialManager,
    CredentialError,
    ScopeViolationError,
    get_credential_manager,
)

__all__ = [
    "CredentialScope",
    "TemporaryCredential",
    "JITCredentialManager",
    "CredentialError",
    "ScopeViolationError",
    "get_credential_manager",
]
