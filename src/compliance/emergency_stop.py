"""
emergency_stop.py — EU AI Act Art. 14 human oversight emergency stop.

Provides a global halt mechanism for all automated compliance decisions.

State priority (read + write):
  1. Redis  key: banxe:emergency_stop  (primary — survives API restarts, fast)
  2. File   path: /data/banxe/data/emergency_stop.json  (fallback if Redis down)
  3. active=False  (fail-open when both stores unavailable)

Fail-open rationale:
  If neither Redis nor filesystem is readable, we log an error and allow through.
  Rationale: Redis downtime must not cause a compliance API outage.  The dual-write
  ensures state survives a Redis failure (file remains), so fail-open is only
  reached during a catastrophic dual-failure scenario.

FastAPI dependency:
  require_not_stopped()  →  add Depends(require_not_stopped) to any endpoint
  that must be gated by the stop mechanism.

Endpoints (defined in api.py):
  POST /api/v1/compliance/emergency-stop    — activate stop (any authorised operator)
  POST /api/v1/compliance/emergency-resume  — clear stop (MLRO authority)
  GET  /api/v1/compliance/emergency-stop/status — current state

EU AI Act Art. 14 requirements covered:
  - Human oversight: operator_id + reason required at activation
  - Override: resume requires mlro_id (senior authority)
  - Interruption: all automated screening returns HTTP 503 while active
  - Audit: all events logged at CRITICAL / WARNING level + ClickHouse audit
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

from fastapi import HTTPException

_STOP_FILE = "/data/banxe/data/emergency_stop.json"
_REDIS_KEY = "banxe:emergency_stop"
_REDIS_URL = "redis://127.0.0.1:6379"

log = logging.getLogger(__name__)


# ── File store ────────────────────────────────────────────────────────────────

def _read_file() -> dict[str, Any] | None:
    try:
        with open(_STOP_FILE) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except Exception as e:
        log.warning("emergency_stop: file read error: %s", e)
        return None


def _write_file(state: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(_STOP_FILE), exist_ok=True)
    with open(_STOP_FILE, "w") as f:
        json.dump(state, f, indent=2)


def _delete_file() -> None:
    try:
        os.remove(_STOP_FILE)
    except FileNotFoundError:
        pass
    except Exception as e:
        log.warning("emergency_stop: file delete error: %s", e)


# ── Redis store ───────────────────────────────────────────────────────────────

async def _read_redis() -> dict[str, Any] | None:
    try:
        import redis.asyncio as aioredis
        r = aioredis.from_url(_REDIS_URL, decode_responses=True)
        raw = await r.get(_REDIS_KEY)
        await r.aclose()
        return json.loads(raw) if raw else None
    except Exception as e:
        log.warning("emergency_stop: redis read error: %s", e)
        return None


async def _write_redis(state: dict[str, Any]) -> None:
    try:
        import redis.asyncio as aioredis
        r = aioredis.from_url(_REDIS_URL, decode_responses=True)
        await r.set(_REDIS_KEY, json.dumps(state))
        await r.aclose()
    except Exception as e:
        log.warning("emergency_stop: redis write error (filesystem remains): %s", e)


async def _delete_redis() -> None:
    try:
        import redis.asyncio as aioredis
        r = aioredis.from_url(_REDIS_URL, decode_responses=True)
        await r.delete(_REDIS_KEY)
        await r.aclose()
    except Exception as e:
        log.warning("emergency_stop: redis delete error: %s", e)


# ── Public state API ──────────────────────────────────────────────────────────

async def get_stop_state() -> dict[str, Any]:
    """
    Returns current stop state dict.
    Priority: Redis → filesystem → {"active": False} (fail-open).
    """
    state = await _read_redis()
    if state is None:
        state = _read_file()
    return state or {"active": False}


async def activate_stop(
    operator_id: str,
    reason: str,
    scope: str = "all",
) -> dict[str, Any]:
    """
    Activate emergency stop.  Written to both Redis and filesystem.
    Logs at CRITICAL level for SIEM / alerting pickup.
    """
    state: dict[str, Any] = {
        "active":               True,
        "operator_id":          operator_id,
        "reason":               reason,
        "scope":                scope,
        "activated_at":         datetime.now(timezone.utc).isoformat(),
        "resume_requires_mlro": True,
    }
    await _write_redis(state)
    _write_file(state)
    log.critical(
        "EMERGENCY_STOP ACTIVATED — operator=%s scope=%s reason=%r",
        operator_id, scope, reason,
    )
    return state


async def clear_stop(mlro_id: str, resume_reason: str) -> dict[str, Any]:
    """
    Clear emergency stop.  Removes state from both Redis and filesystem.
    Returns the previous state for audit purposes.
    Logs at WARNING level.
    """
    prev = await get_stop_state()
    _delete_file()
    await _delete_redis()
    log.warning(
        "EMERGENCY_STOP CLEARED — mlro=%s was_active_since=%s resume_reason=%r",
        mlro_id, prev.get("activated_at", "unknown"), resume_reason,
    )
    return prev


# ── FastAPI dependency ────────────────────────────────────────────────────────

async def require_not_stopped() -> None:
    """
    FastAPI Depends() gate.  Raises HTTP 503 if emergency stop is active.

    Fail-open: if state cannot be read from either store, allows through
    and logs an error.  This prevents Redis downtime from causing a
    compliance API outage.
    """
    try:
        state = await get_stop_state()
    except Exception as e:
        log.error(
            "emergency_stop: failed to read state — failing open: %s", e
        )
        return

    if state.get("active"):
        raise HTTPException(
            status_code=503,
            detail={
                "error":              "emergency_stop_active",
                "message": (
                    "Automated compliance screening suspended (EU AI Act Art. 14). "
                    "All decisions require manual MLRO review until stop is cleared."
                ),
                "stop_activated_at":  state.get("activated_at"),
                "operator_id":        state.get("operator_id"),
                "reason":             state.get("reason"),
                "scope":              state.get("scope"),
                "resume_contact":     "MLRO — POST /api/v1/compliance/emergency-resume",
            },
        )
