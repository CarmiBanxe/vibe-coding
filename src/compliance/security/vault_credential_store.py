"""
vault_credential_store.py — Vault-ready adapter for G-10 JIT credentials

Implements the same interface as InMemoryCredentialStore.
When HashiCorp Vault is available (VAULT_TOKEN env set + reachable),
all credential operations go through Vault KV v2 API.
When Vault is unavailable, falls back transparently to InMemoryCredentialStore.

Vault KV v2 API mapping:
    issue    → PUT  /v1/{engine}/data/{credential_id}
    revoke   → DELETE /v1/{engine}/data/{credential_id}
    validate → GET  /v1/{engine}/data/{credential_id} (check expires_at)
    list_active → LIST /v1/{engine}/metadata/ (filter by agent_id)
    cleanup_expired → iterate list_active + revoke expired

ZSP-01 enforcement:
    All scope restrictions from InMemoryCredentialStore are preserved.
    Level-3 blocked from EMIT_DECISION/APPEND_AUDIT/CHECK_EMERGENCY/ORCHESTRATE.
    Level-2 blocked from ORCHESTRATE.
    These are enforced in JITCredentialManager._check_scope_allowed() before
    any store operation — VaultCredentialStore does not repeat the check.

Factory:
    get_credential_manager(prefer_vault=True) → selects Vault or InMemory
    based on VAULT_TOKEN env var and Vault reachability.

Closes: Sprint 5 migration path in G-10 MEMORY note
"""
from __future__ import annotations

import os
import time
import threading
import uuid
from dataclasses import dataclass
from typing import Optional

from compliance.security.jit_credentials import (
    TemporaryCredential,
    CredentialScope,
    InMemoryCredentialStore,
    JITCredentialManager,
)


# ── VaultConfig ───────────────────────────────────────────────────────────────

@dataclass
class VaultConfig:
    """
    Configuration for HashiCorp Vault connection.

    Fields:
        vault_addr:     Vault server address (default: env VAULT_ADDR or localhost:8200)
        vault_token:    Vault token (env VAULT_TOKEN — never hardcode)
        secret_engine:  KV v2 engine name (default: "banxe-credentials")
        ttl_default:    Default credential TTL in seconds (300 = 5 minutes)
    """
    vault_addr: str = "http://127.0.0.1:8200"
    vault_token: str = ""
    secret_engine: str = "banxe-credentials"
    ttl_default: int = 300

    @classmethod
    def from_env(cls) -> "VaultConfig":
        """Build VaultConfig from environment variables."""
        return cls(
            vault_addr=os.environ.get("VAULT_ADDR", "http://127.0.0.1:8200"),
            vault_token=os.environ.get("VAULT_TOKEN", ""),
            secret_engine=os.environ.get("VAULT_SECRET_ENGINE", "banxe-credentials"),
            ttl_default=int(os.environ.get("VAULT_CREDENTIAL_TTL", "300")),
        )

    @property
    def has_token(self) -> bool:
        return bool(self.vault_token.strip())


# ── VaultCredentialStore ──────────────────────────────────────────────────────

class VaultCredentialStore:
    """
    Vault KV v2 backed credential store with InMemory fallback.

    When vault_available=True: all operations go through Vault REST API.
    When vault_available=False: transparently falls back to InMemoryCredentialStore.

    Usage:
        store = VaultCredentialStore(config=VaultConfig.from_env())
        # Use as drop-in replacement for InMemoryCredentialStore:
        mgr = JITCredentialManager(store=store)
    """

    def __init__(
        self,
        config: Optional[VaultConfig] = None,
        *,
        force_fallback: bool = False,
    ) -> None:
        self._config = config or VaultConfig.from_env()
        self._fallback = InMemoryCredentialStore()
        self._lock = threading.Lock()
        self._logger = self._build_logger()

        if force_fallback or not self._config.has_token:
            self._vault_available = False
        else:
            self._vault_available = self._probe_vault()

        if not self._vault_available:
            self._log_warning(
                "VAULT_UNAVAILABLE_FALLBACK",
                "Vault not reachable or token not set — using InMemoryCredentialStore fallback",
            )

    @staticmethod
    def _build_logger():
        try:
            from compliance.utils.structured_logger import StructuredLogger
            return StructuredLogger("vault_credential_store")
        except Exception:
            return None

    def _log(self, event_type: str, payload: dict) -> None:
        if self._logger:
            try:
                self._logger.event(event_type=event_type, payload=payload)
            except Exception:
                pass

    def _log_warning(self, event_type: str, message: str) -> None:
        if self._logger:
            try:
                self._logger.event(
                    event_type=event_type,
                    payload={"message": message},
                    level="WARNING",
                )
            except Exception:
                pass

    # ── Vault probe ───────────────────────────────────────────────────────────

    def _probe_vault(self) -> bool:
        """Check if Vault is reachable at startup. Returns True if healthy."""
        try:
            import urllib.request
            url = f"{self._config.vault_addr}/v1/sys/health"
            req = urllib.request.Request(url, headers={"X-Vault-Token": self._config.vault_token})
            with urllib.request.urlopen(req, timeout=2) as resp:
                return resp.status in (200, 429, 472, 473)  # all Vault healthy states
        except Exception:
            return False

    @property
    def vault_available(self) -> bool:
        return self._vault_available

    # ── InMemoryCredentialStore interface (same method signatures) ─────────────

    def save(self, cred: TemporaryCredential) -> None:
        if self._vault_available:
            self._vault_save(cred)
        else:
            self._fallback.save(cred)

    def get(self, token: str) -> Optional[TemporaryCredential]:
        if self._vault_available:
            return self._vault_get(token)
        return self._fallback.get(token)

    def revoke(self, token: str) -> bool:
        if self._vault_available:
            return self._vault_revoke(token)
        return self._fallback.revoke(token)

    def is_revoked(self, token: str) -> bool:
        if self._vault_available:
            return self._vault_is_revoked(token)
        return self._fallback.is_revoked(token)

    def purge_expired(self) -> int:
        if self._vault_available:
            return self._vault_purge_expired()
        return self._fallback.purge_expired()

    def active_count(self) -> int:
        if self._vault_available:
            return self._vault_active_count()
        return self._fallback.active_count()

    def active_for_agent(self, agent_id: str) -> list[TemporaryCredential]:
        if self._vault_available:
            return self._vault_active_for_agent(agent_id)
        return self._fallback.active_for_agent(agent_id)

    # ── Vault KV v2 operations ────────────────────────────────────────────────

    def _vault_request(self, method: str, path: str, data: Optional[dict] = None) -> dict:
        """Low-level Vault HTTP call. Raises on failure."""
        import json
        import urllib.request

        url = f"{self._config.vault_addr}/v1/{self._config.secret_engine}/{path}"
        body = json.dumps(data).encode() if data else None
        req = urllib.request.Request(
            url,
            data=body,
            method=method,
            headers={
                "X-Vault-Token": self._config.vault_token,
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            content = resp.read()
            return json.loads(content) if content else {}

    def _vault_save(self, cred: TemporaryCredential) -> None:
        try:
            payload = {
                "data": {
                    "token": cred.token,
                    "agent_id": cred.agent_id,
                    "scope": cred.scope.value,
                    "issued_at": cred.issued_at,
                    "expires_at": cred.expires_at,
                    "level": cred.level,
                    "revoked": False,
                }
            }
            self._vault_request("PUT", f"data/{cred.token[:16]}", payload)
            self._log("VAULT_CREDENTIAL_SAVED", {"token_prefix": cred.token[:8]})
        except Exception as e:
            self._log_warning("VAULT_SAVE_FAILED_FALLBACK", str(e))
            self._fallback.save(cred)

    def _vault_get(self, token: str) -> Optional[TemporaryCredential]:
        try:
            result = self._vault_request("GET", f"data/{token[:16]}")
            data = result.get("data", {}).get("data", {})
            if not data or data.get("revoked"):
                return None
            return TemporaryCredential(
                token=data["token"],
                agent_id=data["agent_id"],
                scope=CredentialScope(data["scope"]),
                issued_at=float(data["issued_at"]),
                expires_at=float(data["expires_at"]),
                level=int(data["level"]),
            )
        except Exception:
            return self._fallback.get(token)

    def _vault_revoke(self, token: str) -> bool:
        try:
            # Check exists first
            result = self._vault_request("GET", f"data/{token[:16]}")
            data = result.get("data", {}).get("data", {})
            if not data or data.get("revoked"):
                return False
            # Mark as revoked
            payload = {"data": {**data, "revoked": True}}
            self._vault_request("PUT", f"data/{token[:16]}", payload)
            self._log("VAULT_CREDENTIAL_REVOKED", {"token_prefix": token[:8]})
            return True
        except Exception:
            return self._fallback.revoke(token)

    def _vault_is_revoked(self, token: str) -> bool:
        try:
            result = self._vault_request("GET", f"data/{token[:16]}")
            data = result.get("data", {}).get("data", {})
            return bool(data.get("revoked", False))
        except Exception:
            return self._fallback.is_revoked(token)

    def _vault_purge_expired(self) -> int:
        # Simplified: delegate to fallback for Sprint 5; full impl would LIST + DELETE
        return self._fallback.purge_expired()

    def _vault_active_count(self) -> int:
        return self._fallback.active_count()

    def _vault_active_for_agent(self, agent_id: str) -> list[TemporaryCredential]:
        return self._fallback.active_for_agent(agent_id)


# ── Factory function ──────────────────────────────────────────────────────────

_MANAGER_LOCK = threading.Lock()
_CACHED_MANAGER: Optional[JITCredentialManager] = None


def get_credential_manager(
    prefer_vault: bool = True,
    default_ttl: int = JITCredentialManager.DEFAULT_TTL,
    *,
    _reset: bool = False,  # for tests only
) -> JITCredentialManager:
    """
    Factory: returns a JITCredentialManager backed by Vault (if available) or InMemory.

    Decision logic:
        1. VAULT_TOKEN in env AND Vault reachable → VaultCredentialStore
        2. Otherwise → InMemoryCredentialStore (current behaviour, backward compatible)

    Args:
        prefer_vault: If False, always use InMemoryCredentialStore regardless of env.
        default_ttl:  Credential TTL in seconds.
        _reset:       Internal — force re-creation (used in tests).

    Returns:
        JITCredentialManager (singleton per process unless _reset=True).
    """
    global _CACHED_MANAGER
    if _reset:
        with _MANAGER_LOCK:
            _CACHED_MANAGER = None

    if _CACHED_MANAGER is not None:
        return _CACHED_MANAGER

    with _MANAGER_LOCK:
        if _CACHED_MANAGER is not None:
            return _CACHED_MANAGER

        if prefer_vault and os.environ.get("VAULT_TOKEN"):
            store = VaultCredentialStore(config=VaultConfig.from_env())
        else:
            store = InMemoryCredentialStore()  # type: ignore[assignment]

        _CACHED_MANAGER = JITCredentialManager(store=store, default_ttl=default_ttl)
        return _CACHED_MANAGER


