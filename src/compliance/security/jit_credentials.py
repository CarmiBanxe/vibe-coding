"""
jit_credentials.py — G-10 Zero Standing Privileges: JIT Credential Manager

Implements Just-In-Time credential issuance for compliance agents.
Level-3 (adapter/leaf) agents receive only READ_POLICY scope.
EMIT_DECISION, APPEND_AUDIT, CHECK_EMERGENCY require Level-1 or Level-2.

Architecture:
    JITCredentialManager  — issues and revokes TemporaryCredential objects
    TemporaryCredential   — frozen dataclass with TTL, scope, agent_id, token
    CredentialScope       — enum: READ_POLICY | EMIT_DECISION | APPEND_AUDIT |
                                  CHECK_EMERGENCY | ORCHESTRATE | POLICY_WRITE (reserved, never issued)

Invariants enforced:
    I-22: POLICY_WRITE scope is never issued (maps to B-06 / trust boundary)
    ZSP-01: Level-3 agents cannot receive EMIT_DECISION or APPEND_AUDIT
    ZSP-02: Credentials expire automatically after TTL seconds
    ZSP-03: All issuances and revocations are logged to structured_logger

Sprint 5 migration path:
    Replace InMemoryCredentialStore with VaultCredentialStore — same interface.
    JITCredentialManager._store is injected: swap class, no other changes.
"""
from __future__ import annotations

import secrets
import threading
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable

# ── Scope ──────────────────────────────────────────────────────────────────────

class CredentialScope(str, Enum):
    """Scopes that can be requested for a temporary credential."""
    READ_POLICY       = "read_policy"        # Read compliance thresholds (PolicyPort)
    EMIT_DECISION     = "emit_decision"      # Emit BanxeAMLResult (DecisionPort)
    APPEND_AUDIT      = "append_audit"       # Write DecisionEvent (AuditPort)
    CHECK_EMERGENCY   = "check_emergency"    # Read circuit-breaker state (EmergencyPort)
    ORCHESTRATE       = "orchestrate"        # Delegate to sub-agents (Level-1 only)
    # POLICY_WRITE is intentionally absent — never issued (I-22 / B-06)


# Scopes that Level-3 (adapter/leaf) agents are NOT allowed to hold
_LEVEL_3_FORBIDDEN_SCOPES: frozenset[CredentialScope] = frozenset({
    CredentialScope.EMIT_DECISION,
    CredentialScope.APPEND_AUDIT,
    CredentialScope.CHECK_EMERGENCY,
    CredentialScope.ORCHESTRATE,
})

# Scopes that Level-2 (sub-orchestrator) agents are NOT allowed to hold
_LEVEL_2_FORBIDDEN_SCOPES: frozenset[CredentialScope] = frozenset({
    CredentialScope.ORCHESTRATE,
})


# ── Errors ─────────────────────────────────────────────────────────────────────

class CredentialError(Exception):
    """Base class for JIT credential errors."""


class ScopeViolationError(CredentialError):
    """Raised when an agent requests a scope it is not permitted to hold."""


class CredentialExpiredError(CredentialError):
    """Raised when a credential is used after its TTL has elapsed."""


class CredentialRevokedError(CredentialError):
    """Raised when a credential has been explicitly revoked."""


# ── TemporaryCredential ────────────────────────────────────────────────────────

@dataclass(frozen=True)
class TemporaryCredential:
    """
    Immutable credential issued for a single agent + scope combination.

    Fields:
        token       — cryptographically random hex token (32 bytes)
        agent_id    — identity of the requesting agent
        scope       — what this credential permits
        issued_at   — Unix timestamp of issuance
        expires_at  — Unix timestamp of expiry (issued_at + ttl)
        level       — trust level of the agent (1|2|3)
    """
    token:      str
    agent_id:   str
    scope:      CredentialScope
    issued_at:  float
    expires_at: float
    level:      int

    @property
    def ttl_seconds(self) -> float:
        return self.expires_at - self.issued_at

    @property
    def is_expired(self) -> bool:
        return time.time() >= self.expires_at

    @property
    def remaining_seconds(self) -> float:
        return max(0.0, self.expires_at - time.time())

    def assert_valid(self) -> None:
        """Raise CredentialExpiredError if the credential has expired."""
        if self.is_expired:
            raise CredentialExpiredError(
                f"Credential for {self.agent_id}/{self.scope.value} expired "
                f"{time.time() - self.expires_at:.1f}s ago"
            )

    def to_dict(self) -> dict:
        return {
            "token_prefix": self.token[:8] + "...",
            "agent_id":     self.agent_id,
            "scope":        self.scope.value,
            "issued_at":    self.issued_at,
            "expires_at":   self.expires_at,
            "level":        self.level,
            "is_expired":   self.is_expired,
        }


# ── In-memory credential store ─────────────────────────────────────────────────

class InMemoryCredentialStore:
    """
    Thread-safe in-memory credential store.
    Sprint 5 migration: replace with VaultCredentialStore (same interface).
    """

    def __init__(self) -> None:
        self._active: dict[str, TemporaryCredential] = {}  # token → credential
        self._revoked: set[str] = set()
        self._lock = threading.Lock()

    def save(self, cred: TemporaryCredential) -> None:
        with self._lock:
            self._active[cred.token] = cred

    def get(self, token: str) -> TemporaryCredential | None:
        with self._lock:
            return self._active.get(token)

    def revoke(self, token: str) -> bool:
        """Mark token as revoked. Returns True if it was active."""
        with self._lock:
            if token in self._active:
                del self._active[token]
                self._revoked.add(token)
                return True
            return False

    def is_revoked(self, token: str) -> bool:
        with self._lock:
            return token in self._revoked

    def purge_expired(self) -> int:
        """Remove expired credentials. Returns count purged."""
        now = time.time()
        with self._lock:
            expired = [t for t, c in self._active.items() if c.expires_at <= now]
            for token in expired:
                del self._active[token]
        return len(expired)

    def active_count(self) -> int:
        with self._lock:
            return len(self._active)

    def active_for_agent(self, agent_id: str) -> list[TemporaryCredential]:
        with self._lock:
            return [c for c in self._active.values() if c.agent_id == agent_id]


# ── Audit logger (lazy import to avoid circular deps) ─────────────────────────

def _noop_log(*args, **kwargs) -> None:
    pass


def _get_logger() -> Callable:
    """Return structured logger if available, else noop."""
    try:
        from compliance.utils.structured_logger import StructuredLogger
        logger = StructuredLogger("jit_credentials")

        def _log(event: str, **kwargs) -> None:
            logger.event(event_type=event, payload=kwargs)

        return _log
    except Exception:
        return _noop_log


# ── JITCredentialManager ───────────────────────────────────────────────────────

class JITCredentialManager:
    """
    Issues and validates JIT credentials for compliance agents.

    Usage:
        mgr = JITCredentialManager()
        cred = mgr.issue_credential("sanctions_check", CredentialScope.READ_POLICY, level=2)
        cred.assert_valid()
        mgr.revoke(cred.token)

    Sprint 5 Vault migration:
        mgr = JITCredentialManager(store=VaultCredentialStore(vault_addr="..."))
    """

    DEFAULT_TTL = 300  # 5 minutes

    def __init__(
        self,
        store: InMemoryCredentialStore | None = None,
        default_ttl: int = DEFAULT_TTL,
    ) -> None:
        self._store = store or InMemoryCredentialStore()
        self._default_ttl = default_ttl
        self._log = _get_logger()

    def issue_credential(
        self,
        agent_id: str,
        scope: CredentialScope,
        level: int = 2,
        ttl: int | None = None,
    ) -> TemporaryCredential:
        """
        Issue a temporary credential for agent_id with the given scope.

        Args:
            agent_id: Identifier of the requesting agent.
            scope:    The CredentialScope being requested.
            level:    Trust level of the agent (1=orchestrator, 2=sub-agent, 3=adapter).
            ttl:      Credential lifetime in seconds. Defaults to DEFAULT_TTL (300s).

        Returns:
            TemporaryCredential (frozen dataclass, expires automatically after TTL).

        Raises:
            ScopeViolationError: If the agent's level does not permit the requested scope.
            ValueError: If agent_id is empty or level is not 1, 2, or 3.
        """
        if not agent_id:
            raise ValueError("agent_id must be non-empty")
        if level not in (1, 2, 3):
            raise ValueError(f"level must be 1, 2, or 3 (got {level})")

        # ZSP-01: enforce level-based scope restrictions
        self._check_scope_allowed(agent_id, scope, level)

        effective_ttl = ttl if ttl is not None else self._default_ttl
        now = time.time()

        cred = TemporaryCredential(
            token      = secrets.token_hex(32),
            agent_id   = agent_id,
            scope      = scope,
            issued_at  = now,
            expires_at = now + effective_ttl,
            level      = level,
        )
        self._store.save(cred)

        self._log(
            "CREDENTIAL_ISSUED",
            agent_id=agent_id,
            scope=scope.value,
            level=level,
            ttl=effective_ttl,
            token_prefix=cred.token[:8],
        )
        return cred

    def validate(self, token: str) -> TemporaryCredential:
        """
        Validate a token and return its credential.

        Raises:
            CredentialRevokedError: Token was explicitly revoked.
            CredentialExpiredError: Token has expired.
            CredentialError: Token not found.
        """
        if self._store.is_revoked(token):
            raise CredentialRevokedError(f"Token {token[:8]}... has been revoked")

        cred = self._store.get(token)
        if cred is None:
            raise CredentialError(f"Token {token[:8]}... not found")

        cred.assert_valid()
        return cred

    def revoke(self, token: str) -> bool:
        """
        Explicitly revoke a credential before its TTL expires.
        Returns True if the credential was active, False if already gone.
        """
        cred = self._store.get(token)
        revoked = self._store.revoke(token)
        if revoked and cred:
            self._log(
                "CREDENTIAL_REVOKED",
                agent_id=cred.agent_id,
                scope=cred.scope.value,
                token_prefix=token[:8],
                remaining_seconds=cred.remaining_seconds,
            )
        return revoked

    def revoke_all_for_agent(self, agent_id: str) -> int:
        """Revoke all active credentials for an agent. Returns count revoked."""
        creds = self._store.active_for_agent(agent_id)
        count = 0
        for cred in creds:
            if self.revoke(cred.token):
                count += 1
        return count

    def purge_expired(self) -> int:
        """Remove expired credentials from store. Returns count purged."""
        return self._store.purge_expired()

    def active_count(self) -> int:
        """Return number of active (non-expired, non-revoked) credentials."""
        self._store.purge_expired()
        return self._store.active_count()

    @staticmethod
    def _check_scope_allowed(agent_id: str, scope: CredentialScope, level: int) -> None:
        """Raise ScopeViolationError if level cannot hold scope."""
        if level == 3 and scope in _LEVEL_3_FORBIDDEN_SCOPES:
            raise ScopeViolationError(
                f"ZSP-01 violation: Level-3 agent '{agent_id}' cannot receive "
                f"scope '{scope.value}' (forbidden: {[s.value for s in _LEVEL_3_FORBIDDEN_SCOPES]})"
            )
        if level == 2 and scope in _LEVEL_2_FORBIDDEN_SCOPES:
            raise ScopeViolationError(
                f"ZSP-01 violation: Level-2 agent '{agent_id}' cannot receive "
                f"scope '{scope.value}' (requires Level-1 orchestrator)"
            )


# ── Singleton ─────────────────────────────────────────────────────────────────

_MANAGER: JITCredentialManager | None = None
_MANAGER_LOCK = threading.Lock()


def get_credential_manager(
    default_ttl: int = JITCredentialManager.DEFAULT_TTL,
) -> JITCredentialManager:
    """Return the process-wide JITCredentialManager singleton."""
    global _MANAGER
    if _MANAGER is None:
        with _MANAGER_LOCK:
            if _MANAGER is None:
                _MANAGER = JITCredentialManager(default_ttl=default_ttl)
    return _MANAGER
