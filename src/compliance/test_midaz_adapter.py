"""
test_midaz_adapter.py — Pytest tests for MidazLedgerAdapter
BANXE Compliance Stack — Sprint 8 BLOCK-A
"""
import os
from decimal import Decimal
from unittest.mock import MagicMock, patch

import pytest

from compliance.adapters.midaz_adapter import MidazLedgerAdapter


def _mock_response(status_code: int, json_data=None, text: str = "") -> MagicMock:
    resp = MagicMock()
    resp.status_code = status_code
    resp.ok = 200 <= status_code < 300
    resp.text = text or (str(json_data) if json_data else "")
    resp.content = b"x" if (json_data or text) else b""
    resp.json.return_value = json_data or {}
    return resp


class TestHealthCheck:
    def test_health_check_healthy(self):
        resp = MagicMock()
        resp.ok = True
        resp.text = "healthy"
        with patch("compliance.adapters.midaz_adapter.requests.get", return_value=resp):
            assert MidazLedgerAdapter().health_check() is True

    def test_health_check_unhealthy(self):
        resp = MagicMock()
        resp.ok = True
        resp.text = "degraded"
        with patch("compliance.adapters.midaz_adapter.requests.get", return_value=resp):
            assert MidazLedgerAdapter().health_check() is False

    def test_health_check_http_error(self):
        resp = MagicMock()
        resp.ok = False
        resp.text = "service unavailable"
        with patch("compliance.adapters.midaz_adapter.requests.get", return_value=resp):
            assert MidazLedgerAdapter().health_check() is False


class TestCreateOrganization:
    def test_create_organization_success(self):
        data = {"id": "org-1", "legalName": "BANXE LTD", "status": {"code": "ACTIVE"}}
        resp = _mock_response(201, data)
        with patch("compliance.adapters.midaz_adapter.requests.post", return_value=resp):
            result = MidazLedgerAdapter().create_organization("BANXE LTD", "12345678", "GB")
        assert result.id == "org-1"
        assert result.legal_name == "BANXE LTD"
        assert result.status == "ACTIVE"

    def test_create_organization_error(self):
        resp = _mock_response(400, text="bad request")
        with patch("compliance.adapters.midaz_adapter.requests.post", return_value=resp):
            with pytest.raises(RuntimeError, match="400"):
                MidazLedgerAdapter().create_organization("X", "Y", "Z")


class TestGetOrganization:
    def test_get_organization_success(self):
        data = {"id": "org-2", "legalName": "ACME", "status": {"code": "ACTIVE"}}
        resp = _mock_response(200, data)
        with patch("compliance.adapters.midaz_adapter.requests.get", return_value=resp):
            result = MidazLedgerAdapter().get_organization("org-2")
        assert result.id == "org-2"
        assert result.legal_name == "ACME"

    def test_get_organization_not_found(self):
        resp = _mock_response(404, text="not found")
        with patch("compliance.adapters.midaz_adapter.requests.get", return_value=resp):
            with pytest.raises(RuntimeError, match="404"):
                MidazLedgerAdapter().get_organization("nonexistent")


class TestCreateLedger:
    def test_create_ledger_success(self):
        data = {"id": "led-1", "name": "Main Ledger", "organizationId": "org-1"}
        resp = _mock_response(201, data)
        with patch("compliance.adapters.midaz_adapter.requests.post", return_value=resp):
            result = MidazLedgerAdapter().create_ledger("org-1", "Main Ledger", "GBP")
        assert result.id == "led-1"
        assert result.name == "Main Ledger"
        assert result.organization_id == "org-1"


class TestCreateAccount:
    def test_create_account_success(self):
        data = {
            "id": "acc-1",
            "name": "Safeguarding GBP",
            "ledgerId": "led-1",
            "organizationId": "org-1",
        }
        resp = _mock_response(201, data)
        with patch("compliance.adapters.midaz_adapter.requests.post", return_value=resp):
            result = MidazLedgerAdapter().create_account("org-1", "led-1", "Safeguarding GBP", "GBP")
        assert result.id == "acc-1"
        assert result.ledger_id == "led-1"
        assert result.organization_id == "org-1"


class TestGetBalance:
    def test_get_balance_success(self):
        data = {"available": {"amount": 10000, "scale": 2}}
        resp = _mock_response(200, data)
        with patch("compliance.adapters.midaz_adapter.requests.get", return_value=resp):
            balance = MidazLedgerAdapter().get_balance("org-1", "led-1", "acc-1")
        assert balance == Decimal("100.00")

    def test_get_balance_scale_calculation(self):
        data = {"available": {"amount": 500, "scale": 2}}
        resp = _mock_response(200, data)
        with patch("compliance.adapters.midaz_adapter.requests.get", return_value=resp):
            balance = MidazLedgerAdapter().get_balance("org-1", "led-1", "acc-1")
        assert balance == Decimal("5.00")

    def test_get_balance_zero_scale(self):
        data = {"available": {"amount": 42, "scale": 0}}
        resp = _mock_response(200, data)
        with patch("compliance.adapters.midaz_adapter.requests.get", return_value=resp):
            balance = MidazLedgerAdapter().get_balance("org-1", "led-1", "acc-1")
        assert balance == Decimal("42")


class TestCreateTransaction:
    def test_create_transaction_implemented(self):
        # create_transaction is now implemented (IL-006 Step 2).
        # Full coverage is in test_midaz_transaction.py T-01..T-15.
        from unittest.mock import MagicMock, patch
        mock_resp = MagicMock()
        mock_resp.ok = True
        mock_resp.status_code = 201
        mock_resp.content = b"{}"
        mock_resp.json.return_value = {
            "id": "tx-stub", "amount": 5000, "assetCode": "GBP",
            "status": {"code": "CREATED"}, "source": ["acc-a"],
            "destination": ["acc-b"], "description": "test", "pending": False,
        }
        with patch("compliance.adapters.midaz_adapter.requests.post", return_value=mock_resp):
            result = MidazLedgerAdapter().create_transaction(
                "org-1", "led-1", Decimal("50.00"), "GBP", "acc-a", "acc-b", "test"
            )
        assert result.id == "tx-stub"
        assert result.status == "CREATED"


class TestEnvBaseUrl:
    def test_adapter_uses_env_base_url(self, monkeypatch):
        monkeypatch.setenv("MIDAZ_BASE_URL", "http://10.0.0.5:9999")
        resp = MagicMock()
        resp.ok = True
        resp.text = "healthy"
        with patch("compliance.adapters.midaz_adapter.requests.get", return_value=resp) as mock_get:
            MidazLedgerAdapter().health_check()
        called_url = mock_get.call_args[0][0]
        assert called_url.startswith("http://10.0.0.5:9999")
