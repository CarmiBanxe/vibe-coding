#!/usr/bin/env python3
"""
test_emergency_stop.py — Integration tests for EU AI Act Art. 14 emergency stop.

Invariant coverage:
  I-23: Emergency stop checked BEFORE any automated decision
  I-24: All events logged (CRITICAL/WARNING on activate/resume)

Test architecture:
  - `_STOP_FILE` redirected to /tmp → no /data permission issues on Legion
  - `redis.asyncio` mocked in sys.modules with an in-memory async store
  - api.py heavy dependencies mocked (audit_trail, sar_generator, etc.)
  - Tests run without GMKtec, Redis, or any external service

Test matrix:
  T-01  Status idle → active=false
  T-02  Activate — returns 200 with activated_at + operator_id
  T-03  Activate validates operator_id required
  T-04  Activate validates reason required
  T-05  Screen person → 503 when stop active  [I-23]
  T-06  Screen company → 503 when stop active [I-23]
  T-07  Screen wallet → 503 when stop active  [I-23]
  T-08  Transaction check → 503 when stop active [I-23]
  T-09  Resume when not stopped → "not_stopped" status
  T-10  Resume validates mlro_id required
  T-11  Resume validates resume_reason required
  T-12  Full lifecycle: activate → 503 → resume → 200 on screening endpoint
  T-13  Fail-open: Redis + file both unavailable → screening allowed through
  T-14  Status reflects active=true after activate
  T-15  Status reflects active=false after resume
  T-16  Idempotent activate: second activate while stopped still returns 503
  T-17  Resume returns previous stop metadata for audit
"""
from __future__ import annotations

import sys
import os
import json
import asyncio
import tempfile
from unittest.mock import AsyncMock, MagicMock, patch
import pytest
import httpx

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)


# ── In-memory Redis stub ──────────────────────────────────────────────────────

class _RedisStub:
    """Minimal async Redis stub — only the methods emergency_stop.py uses."""

    def __init__(self):
        self._data: dict = {}

    async def get(self, key):
        return self._data.get(key)

    async def set(self, key, value):
        self._data[key] = value

    async def delete(self, key):
        self._data.pop(key, None)

    async def ping(self):
        return True

    async def aclose(self):
        pass


_redis_instance = _RedisStub()


class _FakeAioRedis:
    """Fake redis.asyncio module so emergency_stop.py can `import redis.asyncio as aioredis`."""

    @staticmethod
    def from_url(url, decode_responses=True):
        return _redis_instance


_fake_redis_module = MagicMock()
_fake_redis_module.asyncio = _FakeAioRedis()


# ── Temp stop file ────────────────────────────────────────────────────────────

_TEMP_STOP_FILE = os.path.join(tempfile.gettempdir(), "banxe_test_emergency_stop.json")


# ── Temp log dir ─────────────────────────────────────────────────────────────

_TEMP_LOG_DIR = tempfile.mkdtemp(prefix="banxe_test_logs_")

# Tracks original sys.modules entries so we can restore them after the module
# finishes — prevents mock contamination of other test files (order-dependent failures)
_INJECTED_MOCKS: dict = {}


# ── Build the FastAPI app with all external deps mocked ──────────────────────

def _make_app():
    """
    Build api.py with heavy deps mocked and stop file/Redis redirected.

    Design:
    - Mocks injected PERMANENTLY into sys.modules (no context manager revert)
      so that emergency_stop module identity stays stable across all tests.
    - _STOP_FILE redirected to /tmp so _write_file works on Legion.
    - api.LOGS_DIR redirected to a real tempdir so _save_log works.
    - redis module replaced with in-memory stub so _write/_read_redis work.
    """
    module_mocks = {
        "audit_trail": MagicMock(
            log_screening=AsyncMock(return_value=None),
            get_screening_history=AsyncMock(return_value=[]),
            get_stats=AsyncMock(return_value={}),
            setup_schema=AsyncMock(return_value=None),
        ),
        "sar_generator": MagicMock(
            generate_sar=MagicMock(return_value={"narrative": "", "sar_id": ""}),
        ),
        "pep_check": MagicMock(
            check_pep=MagicMock(return_value={"hit": False, "positions": [], "qid": ""}),
        ),
        "adverse_media": MagicMock(
            check_adverse_media=AsyncMock(return_value={
                "risk_score": 0, "risk_level": "NONE",
                "hits": 0, "articles": [], "top_articles": [],
            }),
        ),
        "sanctions_check": MagicMock(
            check_sanctions=AsyncMock(return_value={
                "sanctioned": False, "hits": [], "hit_count": 0,
                "lists_with_hits": [], "top_match": "", "sources_checked": [],
            }),
        ),
        "doc_verify": MagicMock(
            verify_passport=AsyncMock(return_value={}),
            verify_face=AsyncMock(return_value={}),
        ),
        "kyb_check": MagicMock(
            check_company=AsyncMock(return_value={"high_risk_ubos": [], "reason": "Clean"}),
        ),
        "crypto_aml": MagicMock(
            check_wallet=AsyncMock(return_value={"risk_score": 0, "decision": "APPROVE"}),
        ),
        "tx_monitor": MagicMock(
            check_transaction=AsyncMock(return_value={
                "flagged": False, "decision": "APPROVE", "risk_score": 0,
            }),
        ),
        "legal_databases": MagicMock(),
        # In-memory Redis stub — makes _write_redis/_read_redis work without the package
        "redis": _fake_redis_module,
        "redis.asyncio": _FakeAioRedis,
    }

    # Save originals for cleanup — restore after module teardown so other
    # test files don't inherit our mocks (fixes order-dependent test failures)
    _saved = {k: sys.modules.get(k) for k in module_mocks}
    _INJECTED_MOCKS.update(_saved)

    for name, mock in module_mocks.items():
        sys.modules[name] = mock

    # Drop cached api + emergency_stop so they reimport with our mocks
    for mod in ("api", "emergency_stop"):
        sys.modules.pop(mod, None)

    # Import emergency_stop and redirect paths before api.py sees it
    import emergency_stop as _es
    _es._STOP_FILE = _TEMP_STOP_FILE

    # Import api.py — LOGS_DIR is set at module level, override after import
    with patch("os.makedirs", return_value=None):
        sys.modules.pop("api", None)
        import api as _api

    # Redirect LOGS_DIR to tempdir so _save_log works in tests
    _api.LOGS_DIR = _TEMP_LOG_DIR

    return _api.app


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def app():
    yield _make_app()
    # ── Teardown: restore sys.modules so other test files are not polluted ────
    for name, original in _INJECTED_MOCKS.items():
        if original is None:
            sys.modules.pop(name, None)
        else:
            sys.modules[name] = original
    for mod in ("api", "emergency_stop"):
        sys.modules.pop(mod, None)


@pytest.fixture(scope="module")
def client(app):
    transport = httpx.ASGITransport(app=app)
    return httpx.AsyncClient(transport=transport, base_url="http://test")


@pytest.fixture(autouse=True)
def clean_stop():
    """Reset ALL stop state before each test — Redis stub + file."""
    _redis_instance._data.clear()
    if os.path.exists(_TEMP_STOP_FILE):
        os.remove(_TEMP_STOP_FILE)
    yield
    # Cleanup after test
    _redis_instance._data.clear()
    if os.path.exists(_TEMP_STOP_FILE):
        os.remove(_TEMP_STOP_FILE)


def run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


# ═══════════════════════════════════════════════════════════════════════════════
# T-01  Status idle
# ═══════════════════════════════════════════════════════════════════════════════

def test_t01_status_idle(client):
    """GET status with no stop → active=false."""
    resp = run(client.get("/api/v1/compliance/emergency-stop/status"))
    assert resp.status_code == 200
    body = resp.json()
    assert body["active"] is False
    assert body["screening_suspended"] is False
    assert body["activated_at"] is None
    assert body["operator_id"] is None


# ═══════════════════════════════════════════════════════════════════════════════
# T-02  Activate returns correct payload
# ═══════════════════════════════════════════════════════════════════════════════

def test_t02_activate_response(client):
    """POST emergency-stop → 200 with activated_at and operator_id."""
    resp = run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "compliance@banxe.io",
        "reason":      "Potential data integrity issue detected",
        "scope":       "all",
    }))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "stop_activated"
    assert body["operator_id"] == "compliance@banxe.io"
    assert body["scope"] == "all"
    assert body["activated_at"] is not None


# ═══════════════════════════════════════════════════════════════════════════════
# T-03  Activate — operator_id required
# ═══════════════════════════════════════════════════════════════════════════════

def test_t03_activate_missing_operator_id(client):
    """operator_id blank → 400."""
    resp = run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "   ",
        "reason":      "Test reason",
    }))
    assert resp.status_code == 400


# ═══════════════════════════════════════════════════════════════════════════════
# T-04  Activate — reason required
# ═══════════════════════════════════════════════════════════════════════════════

def test_t04_activate_missing_reason(client):
    """reason blank → 400."""
    resp = run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "compliance@banxe.io",
        "reason":      "",
    }))
    assert resp.status_code == 400


# ═══════════════════════════════════════════════════════════════════════════════
# T-05  I-23: screen/person → 503 when stop active
# ═══════════════════════════════════════════════════════════════════════════════

def test_t05_i23_screen_person_503(client):
    """I-23: screen/person returns 503 while emergency stop is active."""
    run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "mlro@banxe.io",
        "reason":      "Audit required",
    }))
    resp = run(client.post("/api/v1/screen/person", json={"name": "Alice Smith"}))
    assert resp.status_code == 503, resp.text
    detail = resp.json().get("detail", {})
    assert detail.get("error") == "emergency_stop_active"
    assert "EU AI Act Art. 14" in detail.get("message", "")
    assert detail.get("operator_id") == "mlro@banxe.io"


# ═══════════════════════════════════════════════════════════════════════════════
# T-06  I-23: screen/company → 503 when stop active
# ═══════════════════════════════════════════════════════════════════════════════

def test_t06_i23_screen_company_503(client):
    """I-23: screen/company returns 503 while emergency stop is active."""
    run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "mlro@banxe.io",
        "reason":      "MLRO request",
    }))
    resp = run(client.post("/api/v1/screen/company", json={"name": "Test Corp", "jurisdiction": "GB"}))
    assert resp.status_code == 503
    assert resp.json()["detail"]["error"] == "emergency_stop_active"


# ═══════════════════════════════════════════════════════════════════════════════
# T-07  I-23: screen/wallet → 503 when stop active
# ═══════════════════════════════════════════════════════════════════════════════

def test_t07_i23_screen_wallet_503(client):
    """I-23: screen/wallet returns 503 while emergency stop is active."""
    run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "mlro@banxe.io",
        "reason":      "Crypto risk event",
    }))
    resp = run(client.post("/api/v1/screen/wallet", json={"address": "0xDEAD", "chain": "eth"}))
    assert resp.status_code == 503
    assert resp.json()["detail"]["error"] == "emergency_stop_active"


# ═══════════════════════════════════════════════════════════════════════════════
# T-08  I-23: transaction/check → 503 when stop active
# ═══════════════════════════════════════════════════════════════════════════════

def test_t08_i23_transaction_503(client):
    """I-23: transaction/check returns 503 while emergency stop is active."""
    run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "mlro@banxe.io",
        "reason":      "Suspicious activity cluster",
    }))
    resp = run(client.post("/api/v1/transaction/check", json={
        "from_name": "Alice", "to_name": "Bob",
        "amount": 5000.0, "currency": "GBP",
    }))
    assert resp.status_code == 503
    assert resp.json()["detail"]["error"] == "emergency_stop_active"


# ═══════════════════════════════════════════════════════════════════════════════
# T-09  Resume when not stopped
# ═══════════════════════════════════════════════════════════════════════════════

def test_t09_resume_when_not_stopped(client):
    """Resume with no active stop → status=not_stopped (idempotent, no error)."""
    resp = run(client.post("/api/v1/compliance/emergency-resume", json={
        "mlro_id":       "sarah.chen@banxe.io",
        "resume_reason": "False alarm, system verified clean",
    }))
    assert resp.status_code == 200
    assert resp.json()["status"] == "not_stopped"


# ═══════════════════════════════════════════════════════════════════════════════
# T-10  Resume — mlro_id required
# ═══════════════════════════════════════════════════════════════════════════════

def test_t10_resume_missing_mlro_id(client):
    """mlro_id blank → 400."""
    run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "mlro@banxe.io", "reason": "Test",
    }))
    resp = run(client.post("/api/v1/compliance/emergency-resume", json={
        "mlro_id":       "",
        "resume_reason": "Cleared",
    }))
    assert resp.status_code == 400


# ═══════════════════════════════════════════════════════════════════════════════
# T-11  Resume — resume_reason required
# ═══════════════════════════════════════════════════════════════════════════════

def test_t11_resume_missing_resume_reason(client):
    """resume_reason blank → 400."""
    run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "mlro@banxe.io", "reason": "Test",
    }))
    resp = run(client.post("/api/v1/compliance/emergency-resume", json={
        "mlro_id":       "sarah.chen@banxe.io",
        "resume_reason": "   ",
    }))
    assert resp.status_code == 400


# ═══════════════════════════════════════════════════════════════════════════════
# T-12  Full lifecycle: activate → 503 → resume → 200
# ═══════════════════════════════════════════════════════════════════════════════

def test_t12_full_lifecycle(client):
    """
    Full EU AI Act Art. 14 lifecycle:
      1. Operator activates stop
      2. Screening endpoint → 503
      3. MLRO resumes
      4. Same screening endpoint → 200
    """
    # Step 1: activate
    act = run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "compliance@banxe.io",
        "reason":      "Regulatory examination — FCA supervisory visit",
    }))
    assert act.status_code == 200, act.text
    assert act.json()["status"] == "stop_activated"

    # Step 2: screening blocked
    blocked = run(client.post("/api/v1/screen/person", json={"name": "Alice Smith"}))
    assert blocked.status_code == 503
    assert blocked.json()["detail"]["error"] == "emergency_stop_active"

    # Step 3: MLRO resumes
    resume = run(client.post("/api/v1/compliance/emergency-resume", json={
        "mlro_id":       "sarah.chen@banxe.io",
        "resume_reason": "FCA visit concluded — system cleared for automated screening",
    }))
    assert resume.status_code == 200, resume.text
    body = resume.json()
    assert body["status"] == "resumed"
    assert body["mlro_id"] == "sarah.chen@banxe.io"
    assert body["previous_stop"]["operator_id"] == "compliance@banxe.io"
    assert body["previous_stop"]["reason"] == "Regulatory examination — FCA supervisory visit"

    # Step 4: screening now allowed
    allowed = run(client.post("/api/v1/screen/person", json={"name": "Alice Smith"}))
    assert allowed.status_code == 200, allowed.text


# ═══════════════════════════════════════════════════════════════════════════════
# T-13  Fail-open: both stores unavailable → screening allowed through
# ═══════════════════════════════════════════════════════════════════════════════

def test_t13_fail_open_both_stores_down(app):
    """
    When both Redis and filesystem raise exceptions, emergency stop fails open:
    screening endpoints must NOT return 503 — compliance API must stay up.
    Rationale: Redis outage must not cause compliance API outage (dual-store design).
    """
    import emergency_stop as es

    async def _raise_redis(*args, **kwargs):
        raise RuntimeError("Redis unavailable")

    def _raise_file(*args, **kwargs):
        raise RuntimeError("Filesystem unavailable")

    with (
        patch.object(es, "_read_redis", new=AsyncMock(side_effect=_raise_redis)),
        patch.object(es, "_read_file",  new=MagicMock(side_effect=_raise_file)),
    ):
        transport = httpx.ASGITransport(app=app)
        c = httpx.AsyncClient(transport=transport, base_url="http://test")
        resp = run(c.post("/api/v1/screen/person", json={"name": "Alice Smith"}))
        run(c.aclose())

    # fail-open → 200, NOT 503
    assert resp.status_code == 200, f"Expected 200 (fail-open), got {resp.status_code}: {resp.text}"


# ═══════════════════════════════════════════════════════════════════════════════
# T-14  Status reflects active=true after activate
# ═══════════════════════════════════════════════════════════════════════════════

def test_t14_status_after_activate(client):
    """GET status after activate → active=true with correct fields."""
    run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "mlro@banxe.io",
        "reason":      "Suspicious transaction cluster",
        "scope":       "all",
    }))
    resp = run(client.get("/api/v1/compliance/emergency-stop/status"))
    assert resp.status_code == 200
    body = resp.json()
    assert body["active"] is True
    assert body["screening_suspended"] is True
    assert body["operator_id"] == "mlro@banxe.io"
    assert body["reason"] == "Suspicious transaction cluster"
    assert body["scope"] == "all"
    assert body["activated_at"] is not None


# ═══════════════════════════════════════════════════════════════════════════════
# T-15  Status reflects active=false after resume
# ═══════════════════════════════════════════════════════════════════════════════

def test_t15_status_after_resume(client):
    """GET status after resume → active=false."""
    run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "mlro@banxe.io",
        "reason":      "Test",
    }))
    run(client.post("/api/v1/compliance/emergency-resume", json={
        "mlro_id":       "sarah.chen@banxe.io",
        "resume_reason": "All clear",
    }))
    resp = run(client.get("/api/v1/compliance/emergency-stop/status"))
    assert resp.status_code == 200
    body = resp.json()
    assert body["active"] is False
    assert body["screening_suspended"] is False
    assert body["operator_id"] is None


# ═══════════════════════════════════════════════════════════════════════════════
# T-16  Idempotent activate: second activate while stopped still returns 503
# ═══════════════════════════════════════════════════════════════════════════════

def test_t16_idempotent_activate(client):
    """Activating twice while stopped → screening still 503 (state not corrupted)."""
    run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "mlro@banxe.io",
        "reason":      "First stop",
    }))
    run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "compliance@banxe.io",
        "reason":      "Second activate (scope override)",
    }))
    resp = run(client.post("/api/v1/screen/person", json={"name": "Alice Smith"}))
    assert resp.status_code == 503


# ═══════════════════════════════════════════════════════════════════════════════
# T-17  Resume returns previous stop metadata for audit trail
# ═══════════════════════════════════════════════════════════════════════════════

def test_t17_resume_returns_previous_metadata(client):
    """Resume response contains full previous stop metadata for audit (I-24)."""
    run(client.post("/api/v1/compliance/emergency-stop", json={
        "operator_id": "cto@banxe.io",
        "reason":      "Production incident — potential ML model drift",
        "scope":       "all",
    }))
    resp = run(client.post("/api/v1/compliance/emergency-resume", json={
        "mlro_id":       "sarah.chen@banxe.io",
        "resume_reason": "Root cause identified and remediated",
    }))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    prev = body["previous_stop"]
    assert prev["operator_id"] == "cto@banxe.io"
    assert prev["reason"] == "Production incident — potential ML model drift"
    assert prev["scope"] == "all"
    assert prev["activated_at"] is not None
    assert "resumed_at" in body
    assert body["resume_reason"] == "Root cause identified and remediated"
