"""
ledger_port.py — LedgerPort ABC
BANXE Compliance Stack — Sprint 8 BLOCK-A
ADR-013: Midaz PRIMARY CBS
CTX-06 AMBER — all CBS operations via Port (I-28)
"""
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Optional, Dict, Any, List
from decimal import Decimal


@dataclass
class OrganizationResult:
    id: str
    legal_name: str
    status: str

@dataclass
class LedgerResult:
    id: str
    name: str
    organization_id: str

@dataclass
class AccountResult:
    id: str
    name: str
    ledger_id: str
    organization_id: str
    balance: Optional[Decimal] = None


@dataclass(frozen=True)
class TransactionRequest:
    """
    Immutable value object for a CBS transfer request.
    CTX-06 AMBER, I-28: all CBS operations through LedgerPort.

    amount: Decimal in major currency unit (e.g. Decimal("100.00") = £100.00).
    from_account / to_account: Midaz account UUID or @alias string.
    metadata: flat key-value pairs (no nested objects — Midaz constraint).
    """
    org_id: str
    ledger_id: str
    amount: Decimal
    asset_code: str
    from_account: str
    to_account: str
    description: str = ""
    pending: bool = False
    code: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = field(default=None, hash=False, compare=False)


@dataclass(frozen=True)
class TransactionResult:
    """
    Immutable value object returned by CBS after a transaction.
    status: CREATED | PENDING | NOTED | CANCELED
    source / destination: account aliases from CBS response (as tuples — hashable).
    """
    id: str
    amount: Decimal
    asset_code: str
    status: str
    source: tuple = ()
    destination: tuple = ()
    description: str = ""
    pending: bool = False


class LedgerPort(ABC):
    """Abstract port for Core Banking System operations (G-16 Hexagonal)."""

    @abstractmethod
    def health_check(self) -> bool:
        """Returns True if CBS is available."""
        ...

    @abstractmethod
    def create_organization(self, legal_name: str, legal_document: str, country: str) -> OrganizationResult:
        ...

    @abstractmethod
    def get_organization(self, org_id: str) -> OrganizationResult:
        ...

    @abstractmethod
    def create_ledger(self, org_id: str, name: str, currency: str) -> LedgerResult:
        ...

    @abstractmethod
    def create_account(self, org_id: str, ledger_id: str, name: str, asset_code: str) -> AccountResult:
        ...

    @abstractmethod
    def get_balance(self, org_id: str, ledger_id: str, account_id: str) -> Decimal:
        ...

    @abstractmethod
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
        ...

    @abstractmethod
    def list_transactions(
        self,
        org_id: str,
        ledger_id: str,
        limit: int = 20,
        cursor: Optional[str] = None,
    ) -> List[TransactionResult]:
        """Return paginated list of transactions for the ledger."""
        ...
