"""
test_midaz_transaction.py — T-01..T-15
IL-006 Step 4: Transaction API tests (CTX-06 AMBER, G-16)
No real HTTP — all Midaz calls mocked via unittest.mock.patch.
"""
import pytest
from decimal import Decimal
from unittest.mock import MagicMock, patch

from compliance.adapters.midaz_adapter import MidazLedgerAdapter
from compliance.ports.ledger_port import TransactionRequest, TransactionResult

# ── Banxe safeguarding IDs (from ADR-013 / Block J Phase 1) ─────────────────
ORG_ID      = "019d6301-32d7-70a1-bc77-0a05379ee510"
LEDGER_ID   = "019d632f-519e-7865-8a30-3c33991bba9c"
OP_ACCOUNT  = "019d6332-f274-709a-b3a7-983bc8745886"  # operational (asset)
CF_ACCOUNT  = "019d6332-da7f-752f-b9fd-fa1c6fc777ec"  # client_funds (liability)

TX_ENDPOINT = f"/v1/organizations/{ORG_ID}/ledgers/{LEDGER_ID}/transactions/json"
LIST_ENDPOINT = f"/v1/organizations/{ORG_ID}/ledgers/{LEDGER_ID}/transactions"


def _ok_tx_response(tx_id: str = "tx-001", amount: int = 10000) -> dict:
    """Minimal valid Midaz transaction response."""
    return {
        "id": tx_id,
        "amount": amount,
        "assetCode": "GBP",
        "status": {"code": "CREATED"},
        "source": [OP_ACCOUNT],
        "destination": [CF_ACCOUNT],
        "description": "",
        "pending": False,
    }


# ── T-01: successful create_transaction ──────────────────────────────────────

def test_T01_create_transaction_success():
    adapter = MidazLedgerAdapter()
    mock_resp = MagicMock()
    mock_resp.ok = True
    mock_resp.status_code = 201
    mock_resp.json.return_value = _ok_tx_response()
    mock_resp.content = b'{"id":"tx-001"}'

    with patch("compliance.adapters.midaz_adapter.requests.post", return_value=mock_resp) as mock_post:
        result = adapter.create_transaction(
            ORG_ID, LEDGER_ID, Decimal("100.00"), "GBP", OP_ACCOUNT, CF_ACCOUNT
        )

    assert result.id == "tx-001"
    assert result.status == "CREATED"
    assert result.amount == Decimal("100.00")
    assert result.asset_code == "GBP"
    assert result.pending is False

    call_json = mock_post.call_args.kwargs["json"]
    assert call_json["send"]["asset"] == "GBP"
    assert call_json["send"]["value"] == "10000"   # £100.00 → 10000 pence


# ── T-02: amount correctly converted to pence ────────────────────────────────

def test_T02_amount_to_pence_conversion():
    assert MidazLedgerAdapter._to_smallest_unit(Decimal("1.00"))    == "100"
    assert MidazLedgerAdapter._to_smallest_unit(Decimal("100.00"))  == "10000"
    assert MidazLedgerAdapter._to_smallest_unit(Decimal("0.01"))    == "1"
    assert MidazLedgerAdapter._to_smallest_unit(Decimal("1000.00")) == "100000"
    assert MidazLedgerAdapter._to_smallest_unit(Decimal("1.50"))    == "150"


# ── T-03: from_smallest_unit converts back correctly ─────────────────────────

def test_T03_from_smallest_unit_conversion():
    assert MidazLedgerAdapter._from_smallest_unit(10000) == Decimal("100.00")
    assert MidazLedgerAdapter._from_smallest_unit(100)   == Decimal("1.00")
    assert MidazLedgerAdapter._from_smallest_unit(1)     == Decimal("0.01")
    assert MidazLedgerAdapter._from_smallest_unit(150)   == Decimal("1.50")


# ── T-04: send.value == from.amount.value == to.amount.value ─────────────────

def test_T04_request_amounts_balanced():
    adapter = MidazLedgerAdapter()
    mock_resp = MagicMock()
    mock_resp.ok = True
    mock_resp.json.return_value = _ok_tx_response()
    mock_resp.content = b"{}"

    with patch("compliance.adapters.midaz_adapter.requests.post", return_value=mock_resp) as mock_post:
        adapter.create_transaction(
            ORG_ID, LEDGER_ID, Decimal("50.00"), "GBP", OP_ACCOUNT, CF_ACCOUNT
        )

    body = mock_post.call_args.kwargs["json"]
    send_value   = body["send"]["value"]
    from_value   = body["send"]["source"]["from"][0]["amount"]["value"]
    to_value     = body["send"]["distribute"]["to"][0]["amount"]["value"]
    assert send_value == from_value == to_value == "5000"


# ── T-05: correct endpoint used ──────────────────────────────────────────────

def test_T05_correct_endpoint():
    adapter = MidazLedgerAdapter()
    mock_resp = MagicMock()
    mock_resp.ok = True
    mock_resp.json.return_value = _ok_tx_response()
    mock_resp.content = b"{}"

    with patch("compliance.adapters.midaz_adapter.requests.post", return_value=mock_resp) as mock_post:
        adapter.create_transaction(
            ORG_ID, LEDGER_ID, Decimal("100.00"), "GBP", OP_ACCOUNT, CF_ACCOUNT
        )

    url = mock_post.call_args.args[0]
    assert url.endswith(TX_ENDPOINT)


# ── T-06: accountAlias uses UUID directly ────────────────────────────────────

def test_T06_account_alias_is_uuid():
    adapter = MidazLedgerAdapter()
    mock_resp = MagicMock()
    mock_resp.ok = True
    mock_resp.json.return_value = _ok_tx_response()
    mock_resp.content = b"{}"

    with patch("compliance.adapters.midaz_adapter.requests.post", return_value=mock_resp) as mock_post:
        adapter.create_transaction(
            ORG_ID, LEDGER_ID, Decimal("1.00"), "GBP", OP_ACCOUNT, CF_ACCOUNT
        )

    body = mock_post.call_args.kwargs["json"]
    assert body["send"]["source"]["from"][0]["accountAlias"] == OP_ACCOUNT
    assert body["send"]["distribute"]["to"][0]["accountAlias"] == CF_ACCOUNT


# ── T-07: description included when provided ─────────────────────────────────

def test_T07_description_in_payload():
    adapter = MidazLedgerAdapter()
    mock_resp = MagicMock()
    mock_resp.ok = True
    mock_resp.json.return_value = _ok_tx_response()
    mock_resp.content = b"{}"

    with patch("compliance.adapters.midaz_adapter.requests.post", return_value=mock_resp) as mock_post:
        adapter.create_transaction(
            ORG_ID, LEDGER_ID, Decimal("10.00"), "GBP",
            OP_ACCOUNT, CF_ACCOUNT,
            description="Safeguarding transfer",
        )

    body = mock_post.call_args.kwargs["json"]
    assert body["description"] == "Safeguarding transfer"


# ── T-08: description omitted when empty ─────────────────────────────────────

def test_T08_empty_description_omitted():
    adapter = MidazLedgerAdapter()
    mock_resp = MagicMock()
    mock_resp.ok = True
    mock_resp.json.return_value = _ok_tx_response()
    mock_resp.content = b"{}"

    with patch("compliance.adapters.midaz_adapter.requests.post", return_value=mock_resp) as mock_post:
        adapter.create_transaction(
            ORG_ID, LEDGER_ID, Decimal("10.00"), "GBP", OP_ACCOUNT, CF_ACCOUNT
        )

    body = mock_post.call_args.kwargs["json"]
    assert "description" not in body


# ── T-09: API error raises RuntimeError ──────────────────────────────────────

def test_T09_api_error_raises():
    adapter = MidazLedgerAdapter()
    mock_resp = MagicMock()
    mock_resp.ok = False
    mock_resp.status_code = 422
    mock_resp.text = '{"code":"ErrInsufficientFunds","message":"Not enough balance"}'
    mock_resp.content = b'{"code":"ErrInsufficientFunds"}'

    with patch("compliance.adapters.midaz_adapter.requests.post", return_value=mock_resp):
        with pytest.raises(RuntimeError, match="422"):
            adapter.create_transaction(
                ORG_ID, LEDGER_ID, Decimal("999999.00"), "GBP", OP_ACCOUNT, CF_ACCOUNT
            )


# ── T-10: 404 account not found raises RuntimeError ──────────────────────────

def test_T10_account_not_found_raises():
    adapter = MidazLedgerAdapter()
    mock_resp = MagicMock()
    mock_resp.ok = False
    mock_resp.status_code = 404
    mock_resp.text = '{"code":"ErrAccountAliasNotFound"}'
    mock_resp.content = b"{}"

    with patch("compliance.adapters.midaz_adapter.requests.post", return_value=mock_resp):
        with pytest.raises(RuntimeError, match="404"):
            adapter.create_transaction(
                ORG_ID, LEDGER_ID, Decimal("1.00"), "GBP",
                "nonexistent-id", CF_ACCOUNT
            )


# ── T-11: list_transactions success ──────────────────────────────────────────

def test_T11_list_transactions_success():
    adapter = MidazLedgerAdapter()
    mock_resp = MagicMock()
    mock_resp.ok = True
    mock_resp.content = b"{}"
    mock_resp.json.return_value = {
        "items": [
            _ok_tx_response("tx-001", 10000),
            _ok_tx_response("tx-002", 5000),
        ]
    }

    with patch("compliance.adapters.midaz_adapter.requests.get", return_value=mock_resp):
        results = adapter.list_transactions(ORG_ID, LEDGER_ID)

    assert len(results) == 2
    assert results[0].id == "tx-001"
    assert results[1].id == "tx-002"
    assert results[1].amount == Decimal("50.00")


# ── T-12: list_transactions empty ────────────────────────────────────────────

def test_T12_list_transactions_empty():
    adapter = MidazLedgerAdapter()
    mock_resp = MagicMock()
    mock_resp.ok = True
    mock_resp.content = b"{}"
    mock_resp.json.return_value = {"items": []}

    with patch("compliance.adapters.midaz_adapter.requests.get", return_value=mock_resp):
        results = adapter.list_transactions(ORG_ID, LEDGER_ID)

    assert results == []


# ── T-13: list_transactions limit capped at 100 ──────────────────────────────

def test_T13_list_transactions_limit_capped():
    adapter = MidazLedgerAdapter()
    mock_resp = MagicMock()
    mock_resp.ok = True
    mock_resp.content = b"{}"
    mock_resp.json.return_value = {"items": []}

    with patch("compliance.adapters.midaz_adapter.requests.get", return_value=mock_resp) as mock_get:
        adapter.list_transactions(ORG_ID, LEDGER_ID, limit=500)

    params = mock_get.call_args.kwargs["params"]
    assert params["limit"] == 100  # Midaz MAX_PAGINATION_LIMIT=100


# ── T-14: TransactionRequest is frozen (immutable) ───────────────────────────

def test_T14_transaction_request_is_frozen():
    req = TransactionRequest(
        org_id=ORG_ID,
        ledger_id=LEDGER_ID,
        amount=Decimal("100.00"),
        asset_code="GBP",
        from_account=OP_ACCOUNT,
        to_account=CF_ACCOUNT,
    )
    with pytest.raises(Exception):  # FrozenInstanceError
        req.amount = Decimal("200.00")  # type: ignore[misc]


# ── T-15: TransactionResult is frozen (immutable) ────────────────────────────

def test_T15_transaction_result_is_frozen():
    result = TransactionResult(
        id="tx-001",
        amount=Decimal("100.00"),
        asset_code="GBP",
        status="CREATED",
    )
    with pytest.raises(Exception):  # FrozenInstanceError
        result.status = "PENDING"  # type: ignore[misc]
