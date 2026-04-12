"""
Integration tests for api.py via FastAPI TestClient.
No live server required — all external dependencies are mocked.

Coverage targets:
  POST /api/v1/screen/person   — clean, PEP hit, sanctions hit, empty name, skip_ami
  POST /api/v1/screen/company  — basic, sanctions hit
  GET  /api/v1/kyb/{entity_id} — found, not found, asyncpg unavailable

Run: pytest src/compliance/test_api_integration.py -v
"""
from __future__ import annotations

import sys
import types
import uuid
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import os
import pytest

# ── Path setup ────────────────────────────────────────────────────────────────
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# ── Inject stub modules BEFORE importing api ──────────────────────────────────
# These modules live on the server only and must not be required locally.

def _make_stub(name: str, **attrs) -> types.ModuleType:
    mod = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(mod, k, v)
    return mod


# sar_generator — server-only module
_sar_stub = _make_stub(
    "sar_generator",
    generate_sar=lambda result: {"narrative": "stub SAR narrative", "sar_id": "SAR-STUB-001"},
)
sys.modules.setdefault("sar_generator", _sar_stub)

# audit_trail — needs ClickHouse/Postgres; replace async functions with stubs
import audit_trail as _at  # exists locally
_at.setup_schema  = AsyncMock(return_value={})
_at.log_screening = AsyncMock(return_value={})
_at.get_stats     = AsyncMock(return_value={})

# api.py calls os.makedirs("/data/banxe/data/logs") at module level.
# Patch it before importing so the import succeeds without /data access.
from unittest.mock import patch as _patch
with _patch("os.makedirs"):
    from api import app  # noqa: E402

from fastapi.testclient import TestClient  # noqa: E402

client = TestClient(app, raise_server_exceptions=True)


# ── Fixtures / helpers ────────────────────────────────────────────────────────

CLEAN_SANCTIONS = {
    "sanctioned": False, "hit_count": 0, "lists_with_hits": [], "top_match": "",
}
CLEAN_PEP = {
    "hit": False, "source": "wikidata", "full_name": "Test User",
    "description": "", "positions": [], "qid": "", "check_time_ms": 10,
}
CLEAN_AMI = {
    "risk_score": 0, "risk_level": "NONE", "hits": 0,
    "top_articles": [], "articles": [],
}

HIT_SANCTIONS = {
    "sanctioned": True, "hit_count": 1,
    "lists_with_hits": ["OFAC SDN"],
    "top_match": "Vladimir Putin",
}
HIT_PEP = {
    "hit": True, "source": "wikidata", "full_name": "Emmanuel Macron",
    "description": "president of france", "positions": [{"position": "President"}],
    "qid": "Q3052772", "check_time_ms": 50,
}

CLEAN_KYB = {
    "source": "companies_house", "canonical_name": "Test Corp Ltd",
    "jurisdiction_code": "GB", "registration_number": "12345678",
    "status": "active", "is_inactive": False,
    "officers": [], "high_risk_ubos": [], "reason": "Clean",
    "kyb_decision": "APPROVE",
}


# ── Tests: POST /api/v1/screen/person ────────────────────────────────────────

class TestScreenPerson:

    def test_clean_person_returns_approve(self):
        with (
            patch("api.check_sanctions", new=AsyncMock(return_value=CLEAN_SANCTIONS)),
            patch("api.check_pep", return_value=CLEAN_PEP),
            patch("api.check_adverse_media", new=AsyncMock(return_value=CLEAN_AMI)),
            patch("api._save_log", return_value="report_test.json"),
        ):
            resp = client.post("/api/v1/screen/person", json={"name": "Emma Johnson"})

        assert resp.status_code == 200
        body = resp.json()
        assert body["entity_name"] == "Emma Johnson"
        assert body["sanctions_hit"] is False
        assert body["pep_hit"] is False
        assert body["decision"] == "APPROVE"
        assert "composite_score" in body
        assert "report_id" in body

    def test_pep_hit_raises_hold(self):
        with (
            patch("api.check_sanctions", new=AsyncMock(return_value=CLEAN_SANCTIONS)),
            patch("api.check_pep", return_value=HIT_PEP),
            patch("api.check_adverse_media", new=AsyncMock(return_value=CLEAN_AMI)),
            patch("api._save_log", return_value="report_pep.json"),
        ):
            resp = client.post("/api/v1/screen/person", json={"name": "Emmanuel Macron"})

        assert resp.status_code == 200
        body = resp.json()
        assert body["pep_hit"] is True
        assert body["decision"] in ("HOLD", "REJECT")
        assert body["composite_score"] >= 40

    def test_sanctions_hit_returns_reject(self):
        with (
            patch("api.check_sanctions", new=AsyncMock(return_value=HIT_SANCTIONS)),
            patch("api.check_pep", return_value=CLEAN_PEP),
            patch("api.check_adverse_media", new=AsyncMock(return_value=CLEAN_AMI)),
            patch("api._save_log", return_value="report_sanctions.json"),
        ):
            resp = client.post("/api/v1/screen/person", json={"name": "Vladimir Putin"})

        assert resp.status_code == 200
        body = resp.json()
        assert body["sanctions_hit"] is True
        assert body["overall_risk"] == "BLOCK"
        assert body["decision"] == "REJECT"
        assert body["sar_required"] is True

    def test_empty_name_returns_400(self):
        resp = client.post("/api/v1/screen/person", json={"name": ""})
        assert resp.status_code == 400

    def test_missing_name_field_returns_422(self):
        resp = client.post("/api/v1/screen/person", json={})
        assert resp.status_code == 422

    def test_skip_ami_skips_adverse_media(self):
        """When skip_ami=True adverse media module must not be called."""
        ami_mock = AsyncMock(return_value=CLEAN_AMI)
        with (
            patch("api.check_sanctions", new=AsyncMock(return_value=CLEAN_SANCTIONS)),
            patch("api.check_pep", return_value=CLEAN_PEP),
            patch("api.check_adverse_media", new=ami_mock),
            patch("api._save_log", return_value="r.json"),
        ):
            resp = client.post(
                "/api/v1/screen/person",
                json={"name": "Emma Johnson", "skip_ami": True},
            )

        assert resp.status_code == 200
        ami_mock.assert_not_called()

    def test_response_contains_required_fields(self):
        required = {
            "entity_name", "entity_type", "timestamp", "screening_time_ms",
            "sanctions_hit", "pep_hit", "ami_score", "ami_risk",
            "composite_score", "decision", "overall_risk", "requires_edd",
            "sar_required", "reason", "report_id",
        }
        with (
            patch("api.check_sanctions", new=AsyncMock(return_value=CLEAN_SANCTIONS)),
            patch("api.check_pep", return_value=CLEAN_PEP),
            patch("api.check_adverse_media", new=AsyncMock(return_value=CLEAN_AMI)),
            patch("api._save_log", return_value="r.json"),
        ):
            resp = client.post("/api/v1/screen/person", json={"name": "Test User"})

        assert resp.status_code == 200
        body = resp.json()
        missing = required - body.keys()
        assert not missing, f"Missing fields: {missing}"


# ── Tests: POST /api/v1/screen/company ───────────────────────────────────────

class TestScreenCompany:

    def test_basic_company_screen_returns_200(self):
        with (
            patch("api.check_company", new=AsyncMock(return_value=CLEAN_KYB)),
            patch("api.check_sanctions", new=AsyncMock(return_value=CLEAN_SANCTIONS)),
            patch("api._save_log", return_value="company_report.json"),
        ):
            resp = client.post(
                "/api/v1/screen/company",
                json={"name": "Revolut Ltd", "jurisdiction": "GB"},
            )

        assert resp.status_code == 200
        body = resp.json()
        assert body["entity_name"] == "Revolut Ltd"
        assert body["entity_type"] == "company"
        assert "kyb_result" in body
        assert "decision" in body

    def test_company_with_sanctions_hit(self):
        with (
            patch("api.check_company", new=AsyncMock(return_value=CLEAN_KYB)),
            patch("api.check_sanctions", new=AsyncMock(return_value=HIT_SANCTIONS)),
            patch("api._save_log", return_value="company_sanction.json"),
        ):
            resp = client.post(
                "/api/v1/screen/company",
                json={"name": "Sanctioned Corp", "jurisdiction": "RU"},
            )

        assert resp.status_code == 200
        body = resp.json()
        assert body["sanctions_hit"] is True
        assert body["decision"] == "REJECT"

    def test_empty_company_name_returns_400(self):
        resp = client.post("/api/v1/screen/company", json={"name": ""})
        assert resp.status_code == 400

    def test_company_response_fields(self):
        required = {
            "entity_name", "entity_type", "jurisdiction",
            "sanctions_hit", "kyb_result", "kyb_high_risk",
            "composite_score", "decision", "requires_edd",
        }
        with (
            patch("api.check_company", new=AsyncMock(return_value=CLEAN_KYB)),
            patch("api.check_sanctions", new=AsyncMock(return_value=CLEAN_SANCTIONS)),
            patch("api._save_log", return_value="r.json"),
        ):
            resp = client.post("/api/v1/screen/company", json={"name": "ACME Ltd"})

        assert resp.status_code == 200
        body = resp.json()
        missing = required - body.keys()
        assert not missing, f"Missing fields: {missing}"


# ── Tests: GET /api/v1/kyb/{entity_id} ───────────────────────────────────────

class TestKybEndpoint:

    _entity_id = str(uuid.uuid4())

    def _mock_asyncpg_conn(self, entity_row, officers=None):
        """Build a mock asyncpg connection that returns preset data."""
        mock_conn = AsyncMock()
        mock_conn.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_conn.__aexit__ = AsyncMock(return_value=False)

        # fetchrow returns entity row or None
        mock_conn.fetchrow = AsyncMock(return_value=entity_row)
        # fetch returns officers list
        mock_conn.fetch = AsyncMock(return_value=officers or [])
        mock_conn.close = AsyncMock()
        return mock_conn

    def _entity_row(self):
        """Mimics asyncpg Record as a dict."""
        eid = uuid.UUID(self._entity_id)
        return {
            "entity_id":           eid,
            "canonical_name":      "Revolut Ltd",
            "jurisdiction_code":   "GB",
            "registration_number": "08804411",
            "status":              "active",
            "incorporation_date":  None,
            "dissolution_date":    None,
            "company_type":        "private-limited-company",
            "is_inactive":         False,
        }

    def test_found_entity_returns_200(self):
        mock_conn = self._mock_asyncpg_conn(self._entity_row())

        mock_asyncpg = MagicMock()
        mock_asyncpg.connect = AsyncMock(return_value=mock_conn)

        with patch.dict(sys.modules, {"asyncpg": mock_asyncpg}):
            resp = client.get(f"/api/v1/kyb/{self._entity_id}")

        assert resp.status_code == 200
        body = resp.json()
        assert body["canonical_name"] == "Revolut Ltd"
        assert body["jurisdiction_code"] == "GB"
        assert body["registration_number"] == "08804411"
        assert body["sanctioned_or_pep"] is False
        assert isinstance(body["officers"], list)

    def test_entity_not_found_returns_404(self):
        mock_conn = self._mock_asyncpg_conn(entity_row=None)
        mock_asyncpg = MagicMock()
        mock_asyncpg.connect = AsyncMock(return_value=mock_conn)

        with patch.dict(sys.modules, {"asyncpg": mock_asyncpg}):
            resp = client.get(f"/api/v1/kyb/{uuid.uuid4()}")

        assert resp.status_code == 404

    def test_sanctioned_officer_sets_flag(self):
        officer_row = {
            "full_name":     "Bad Actor",
            "position":      "Director",
            "appointed_on":  None,
            "resigned_on":   None,        # active officer
            "nationality":   "RU",
            "sanctions_hit": True,
            "pep_hit":       False,
        }
        mock_conn = self._mock_asyncpg_conn(
            self._entity_row(), officers=[officer_row]
        )
        mock_asyncpg = MagicMock()
        mock_asyncpg.connect = AsyncMock(return_value=mock_conn)

        with patch.dict(sys.modules, {"asyncpg": mock_asyncpg}):
            resp = client.get(f"/api/v1/kyb/{self._entity_id}")

        assert resp.status_code == 200
        assert resp.json()["sanctioned_or_pep"] is True

    def test_resigned_officer_hit_does_not_set_flag(self):
        """Resigned officer with sanctions_hit should NOT trigger sanctioned_or_pep."""
        officer_row = {
            "full_name":     "Old Director",
            "position":      "Director",
            "appointed_on":  None,
            "resigned_on":   "2020-01-01",   # resigned
            "nationality":   "US",
            "sanctions_hit": True,
            "pep_hit":       False,
        }
        mock_conn = self._mock_asyncpg_conn(
            self._entity_row(), officers=[officer_row]
        )
        mock_asyncpg = MagicMock()
        mock_asyncpg.connect = AsyncMock(return_value=mock_conn)

        with patch.dict(sys.modules, {"asyncpg": mock_asyncpg}):
            resp = client.get(f"/api/v1/kyb/{self._entity_id}")

        assert resp.status_code == 200
        assert resp.json()["sanctioned_or_pep"] is False

    def test_asyncpg_unavailable_returns_503(self):
        """If asyncpg is not installed the endpoint returns 503."""
        # Remove asyncpg from sys.modules so the runtime import fails
        original = sys.modules.pop("asyncpg", None)
        # Also patch builtins.__import__ so ImportError is raised
        import builtins
        real_import = builtins.__import__

        def mock_import(name, *args, **kwargs):
            if name == "asyncpg":
                raise ImportError("asyncpg not installed")
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=mock_import):
            resp = client.get(f"/api/v1/kyb/{self._entity_id}")

        assert resp.status_code == 503

        if original is not None:
            sys.modules["asyncpg"] = original

    def test_kyb_response_required_fields(self):
        mock_conn = self._mock_asyncpg_conn(self._entity_row())
        mock_asyncpg = MagicMock()
        mock_asyncpg.connect = AsyncMock(return_value=mock_conn)

        required = {
            "entity_id", "canonical_name", "jurisdiction_code",
            "registration_number", "status", "is_inactive",
            "officers", "sanctioned_or_pep",
        }
        with patch.dict(sys.modules, {"asyncpg": mock_asyncpg}):
            resp = client.get(f"/api/v1/kyb/{self._entity_id}")

        assert resp.status_code == 200
        missing = required - resp.json().keys()
        assert not missing, f"Missing fields: {missing}"

    def test_kyb_postgres_connect_failure_returns_503(self):
        mock_asyncpg = MagicMock()
        mock_asyncpg.connect = AsyncMock(side_effect=Exception("connection refused"))

        with patch.dict(sys.modules, {"asyncpg": mock_asyncpg}):
            resp = client.get(f"/api/v1/kyb/{self._entity_id}")

        assert resp.status_code == 503


# ── Tests: miscellaneous endpoints ───────────────────────────────────────────

class TestMiscEndpoints:

    def test_root_returns_200(self):
        resp = client.get("/")
        assert resp.status_code == 200
        body = resp.json()
        assert "service" in body
        assert "health" in body

    def test_screen_wallet_valid_address(self):
        clean_wallet = {
            "address": "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae",
            "chain": "eth", "risk_score": 0, "decision": "APPROVE",
            "sanctions_hit": False, "flags": [],
        }
        with (
            patch("api.check_wallet", new=AsyncMock(return_value=clean_wallet)),
            patch("api._save_log", return_value="wallet_report.json"),
        ):
            resp = client.post(
                "/api/v1/screen/wallet",
                json={"address": "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae", "chain": "eth"},
            )

        assert resp.status_code == 200
        body = resp.json()
        assert "address" in body or "entity_name" in body

    def test_screen_wallet_invalid_address_returns_error(self):
        error_wallet = {"error": "Invalid ETH address format: bad_addr"}
        with patch("api.check_wallet", new=AsyncMock(return_value=error_wallet)):
            resp = client.post(
                "/api/v1/screen/wallet",
                json={"address": "bad_addr", "chain": "eth"},
            )

        assert resp.status_code == 200
        assert "error" in resp.json()

    def test_transaction_check_clean(self):
        clean_tx = {
            "flagged": False, "action": "PASS", "rules": [], "risk_score": 0,
        }
        # api.py awaits check_transaction, so use AsyncMock
        with patch("api.check_transaction", new=AsyncMock(return_value=clean_tx)):
            resp = client.post(
                "/api/v1/transaction/check",
                json={
                    "from_name": "Alice", "to_name": "Bob",
                    "amount": 500.0, "currency": "GBP",
                },
            )

        assert resp.status_code == 200
        body = resp.json()
        assert body["flagged"] is False

    def test_transaction_check_flagged_screens_sender(self):
        flagged_tx = {"flagged": True, "action": "ALERT", "rules": ["THRESHOLD"], "risk_score": 60}
        with (
            patch("api.check_transaction", new=AsyncMock(return_value=flagged_tx)),
            patch("api.check_sanctions", new=AsyncMock(return_value=CLEAN_SANCTIONS)),
        ):
            resp = client.post(
                "/api/v1/transaction/check",
                json={
                    "from_name": "Alice", "to_name": "Bob",
                    "amount": 15000.0, "currency": "GBP",
                },
            )

        assert resp.status_code == 200
        body = resp.json()
        assert body["flagged"] is True
        assert "sender_sanctions" in body

    def test_health_endpoint_returns_200(self):
        """Health check with all external services mocked as unavailable (degraded)."""
        resp = client.get("/api/v1/health")
        # Endpoint always returns 200 (healthy or degraded)
        assert resp.status_code == 200
        body = resp.json()
        assert "status" in body
        assert "checks" in body
        assert "timestamp" in body
