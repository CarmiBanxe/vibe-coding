"""
midaz_adapter.py — MidazLedgerAdapter
BANXE Compliance Stack — Sprint 8 BLOCK-A / IL-006
ADR-013: Midaz PRIMARY CBS adapter (http://127.0.0.1:8095)
CTX-06 AMBER — direct HTTP only via this adapter, never from outside port
"""
import os
from decimal import Decimal
from typing import List, Optional

import requests

from compliance.ports.ledger_port import (
    AccountResult,
    LedgerPort,
    LedgerResult,
    OrganizationResult,
    TransactionResult,
)

_DEFAULT_BASE_URL = "http://127.0.0.1:8095"
_TIMEOUT = 10
_AMOUNT_SCALE = 2  # GBP/USD/EUR use scale=2 (pence/cents)


class MidazLedgerAdapter(LedgerPort):
    """Concrete adapter for the Midaz REST API (PLUGIN_AUTH_ENABLED=false)."""

    def __init__(self) -> None:
        self._base = os.environ.get("MIDAZ_BASE_URL", _DEFAULT_BASE_URL).rstrip("/")

    # ── helpers ──────────────────────────────────────────────────────────────

    def _check(self, resp: requests.Response) -> dict:
        if not resp.ok:
            raise RuntimeError(
                f"Midaz API error {resp.status_code}: {resp.text[:500]}"
            )
        if resp.content:
            return resp.json()
        return {}

    @staticmethod
    def _to_smallest_unit(amount: Decimal, scale: int = _AMOUNT_SCALE) -> str:
        """
        Convert Decimal major-unit amount to smallest-unit string.
        £100.00 → "10000"  (scale=2, pence)
        £1.50   → "150"
        Midaz requires: value > 0, string, integer in smallest unit.
        """
        return str(int(amount * Decimal(10 ** scale)))

    @staticmethod
    def _from_smallest_unit(value: int, scale: int = _AMOUNT_SCALE) -> Decimal:
        """Convert smallest-unit integer back to Decimal major amount."""
        return Decimal(str(value)) / Decimal(10 ** scale)

    # ── organisation / ledger / account ──────────────────────────────────────

    def health_check(self) -> bool:
        resp = requests.get(f"{self._base}/v1/health", timeout=_TIMEOUT)
        return resp.ok and resp.text.strip().lower() == "healthy"

    def create_organization(self, legal_name: str, legal_document: str, country: str) -> OrganizationResult:
        payload = {
            "legalName": legal_name,
            "legalDocument": legal_document,
            "address": {
                "country": country,
                "line1": "N/A",
                "city": "N/A",
                "state": "N/A",
                "zipCode": "N/A",
            },
            "status": {"code": "ACTIVE"},
        }
        resp = requests.post(f"{self._base}/v1/organizations", json=payload, timeout=_TIMEOUT)
        data = self._check(resp)
        return OrganizationResult(
            id=data["id"],
            legal_name=data.get("legalName", legal_name),
            status=data.get("status", {}).get("code", "ACTIVE"),
        )

    def get_organization(self, org_id: str) -> OrganizationResult:
        resp = requests.get(f"{self._base}/v1/organizations/{org_id}", timeout=_TIMEOUT)
        data = self._check(resp)
        return OrganizationResult(
            id=data["id"],
            legal_name=data.get("legalName", ""),
            status=data.get("status", {}).get("code", "ACTIVE"),
        )

    def create_ledger(self, org_id: str, name: str, currency: str) -> LedgerResult:
        payload = {
            "name": name,
            "metadata": {"currency": currency},
        }
        resp = requests.post(
            f"{self._base}/v1/organizations/{org_id}/ledgers",
            json=payload,
            timeout=_TIMEOUT,
        )
        data = self._check(resp)
        return LedgerResult(
            id=data["id"],
            name=data.get("name", name),
            organization_id=data.get("organizationId", org_id),
        )

    def create_account(self, org_id: str, ledger_id: str, name: str, asset_code: str) -> AccountResult:
        payload = {
            "name": name,
            "assetCode": asset_code,
            "type": "deposit",
            "status": {"code": "ACTIVE"},
        }
        resp = requests.post(
            f"{self._base}/v1/organizations/{org_id}/ledgers/{ledger_id}/accounts",
            json=payload,
            timeout=_TIMEOUT,
        )
        data = self._check(resp)
        return AccountResult(
            id=data["id"],
            name=data.get("name", name),
            ledger_id=data.get("ledgerId", ledger_id),
            organization_id=data.get("organizationId", org_id),
        )

    def get_balance(self, org_id: str, ledger_id: str, account_id: str) -> Decimal:
        resp = requests.get(
            f"{self._base}/v1/organizations/{org_id}/ledgers/{ledger_id}/accounts/{account_id}/balance",
            timeout=_TIMEOUT,
        )
        data = self._check(resp)
        available = data.get("available", {})
        amount = Decimal(str(available["amount"]))
        scale = int(available.get("scale", _AMOUNT_SCALE))
        return amount / Decimal(10 ** scale)

    # ── transactions ─────────────────────────────────────────────────────────

    def create_transaction(
        self,
        org_id: str,
        ledger_id: str,
        amount: Decimal,
        asset_code: str,
        from_account: str,
        to_account: str,
        description: str = "",
    ) -> TransactionResult:
        """
        Create a bilateral transfer via Midaz /transactions/json endpoint.

        Amount is in major currency unit (e.g. Decimal("100.00") = £100.00).
        Internally converted to pence string per Midaz API contract.
        send.value == from[].amount.value == to[].amount.value (Midaz constraint).
        """
        value_str = self._to_smallest_unit(amount)
        payload: dict = {
            "pending": False,
            "send": {
                "asset": asset_code,
                "value": value_str,
                "source": {
                    "from": [
                        {
                            "accountAlias": from_account,
                            "amount": {"asset": asset_code, "value": value_str},
                        }
                    ]
                },
                "distribute": {
                    "to": [
                        {
                            "accountAlias": to_account,
                            "amount": {"asset": asset_code, "value": value_str},
                        }
                    ]
                },
            },
        }
        if description:
            payload["description"] = description

        resp = requests.post(
            f"{self._base}/v1/organizations/{org_id}/ledgers/{ledger_id}/transactions/json",
            json=payload,
            timeout=_TIMEOUT,
        )
        data = self._check(resp)
        return TransactionResult(
            id=data["id"],
            amount=self._from_smallest_unit(int(data.get("amount", 0))),
            asset_code=data.get("assetCode", asset_code),
            status=data.get("status", {}).get("code", "CREATED"),
            source=tuple(data.get("source", [])),
            destination=tuple(data.get("destination", [])),
            description=data.get("description", description),
            pending=data.get("pending", False),
        )

    def list_transactions(
        self,
        org_id: str,
        ledger_id: str,
        limit: int = 20,
        cursor: Optional[str] = None,
    ) -> List[TransactionResult]:
        """
        Return paginated list of transactions.
        Midaz uses cursor-based pagination; pass cursor from previous response.
        """
        params: dict = {"limit": min(limit, 100)}  # Midaz MAX_PAGINATION_LIMIT=100
        if cursor:
            params["cursor"] = cursor

        resp = requests.get(
            f"{self._base}/v1/organizations/{org_id}/ledgers/{ledger_id}/transactions",
            params=params,
            timeout=_TIMEOUT,
        )
        data = self._check(resp)
        items = data.get("items", [])
        return [
            TransactionResult(
                id=item["id"],
                amount=self._from_smallest_unit(int(item.get("amount", 0))),
                asset_code=item.get("assetCode", ""),
                status=item.get("status", {}).get("code", ""),
                source=tuple(item.get("source", [])),
                destination=tuple(item.get("destination", [])),
                description=item.get("description", ""),
                pending=item.get("pending", False),
            )
            for item in items
        ]
