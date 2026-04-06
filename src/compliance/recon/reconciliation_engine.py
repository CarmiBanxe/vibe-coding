"""
reconciliation_engine.py — ReconciliationEngine
Block D-recon, IL-007 Step 2
FCA CASS 7.15: daily internal (Midaz) vs external (bank statement) reconciliation.

Architecture: D-RECON-DESIGN.md (commit 98ca7d7)
CTX-06 AMBER — calls LedgerPort only, never Midaz HTTP directly.
"""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from typing import List, Optional, Protocol

logger = logging.getLogger(__name__)

# Discrepancy threshold: differences <= threshold are MATCHED.
# Default £1.00 — CEO decision (D-RECON-DESIGN.md Q3).
_DEFAULT_THRESHOLD = Decimal("1.00")

# Safeguarding account IDs (ADR-013 Block J Phase 1)
SAFEGUARDING_ACCOUNTS = {
    "019d6332-f274-709a-b3a7-983bc8745886": "operational",    # asset
    "019d6332-da7f-752f-b9fd-fa1c6fc777ec": "client_funds",   # liability
}
ORG_ID    = "019d6301-32d7-70a1-bc77-0a05379ee510"
LEDGER_ID = "019d632f-519e-7865-8a30-3c33991bba9c"


@dataclass(frozen=True)
class ReconResult:
    """Result for one account on one reconciliation date."""
    recon_date: date
    account_id: str
    account_type: str        # 'operational' | 'client_funds'
    currency: str
    internal_balance: Decimal
    external_balance: Decimal
    discrepancy: Decimal     # external - internal (positive = bank has more)
    status: str              # 'MATCHED' | 'DISCREPANCY' | 'PENDING'
    source_file: str
    alert_sent: bool = False


class LedgerPortProtocol(Protocol):
    """Minimal protocol for dependency injection (avoids circular import)."""
    def get_balance(self, org_id: str, ledger_id: str, account_id: str) -> Decimal: ...


class ClickHouseClientProtocol(Protocol):
    """Minimal CH client protocol for injection."""
    def execute(self, query: str, params: Optional[dict] = None) -> None: ...


class ReconciliationEngine:
    """
    FCA CASS 7.15 daily reconciliation engine.

    Usage:
        engine = ReconciliationEngine(ledger_port, ch_client, fetcher)
        results = engine.reconcile(date.today())
        # results written to ClickHouse banxe.safeguarding_events
    """

    def __init__(
        self,
        ledger_port: LedgerPortProtocol,
        ch_client: ClickHouseClientProtocol,
        statement_fetcher: "StatementFetcherProtocol",
        threshold: Decimal = _DEFAULT_THRESHOLD,
        org_id: str = ORG_ID,
        ledger_id: str = LEDGER_ID,
    ) -> None:
        self._port = ledger_port
        self._ch = ch_client
        self._fetcher = statement_fetcher
        self._threshold = threshold
        self._org_id = org_id
        self._ledger_id = ledger_id

    # ── public API ────────────────────────────────────────────────────────────

    def reconcile(self, recon_date: date) -> List[ReconResult]:
        """
        Run daily reconciliation for all safeguarding accounts.
        1. Pull internal balances from Midaz via LedgerPort.
        2. Pull external balances from bank statement.
        3. Compare, classify, write to ClickHouse.
        Returns list of ReconResult (one per account).
        """
        external = self._fetcher.fetch(recon_date)
        ext_map = {b.account_id: b for b in external}

        results: List[ReconResult] = []
        for account_id, account_type in SAFEGUARDING_ACCOUNTS.items():
            result = self._reconcile_account(
                recon_date, account_id, account_type, ext_map
            )
            results.append(result)
            self._write_to_clickhouse(result)
            if result.status == "DISCREPANCY":
                logger.warning(
                    "CASS 7.15 DISCREPANCY: account=%s type=%s delta=%s",
                    account_id, account_type, result.discrepancy,
                )

        return results

    # ── internal ─────────────────────────────────────────────────────────────

    def _reconcile_account(
        self,
        recon_date: date,
        account_id: str,
        account_type: str,
        ext_map: dict,
    ) -> ReconResult:
        internal = self._port.get_balance(self._org_id, self._ledger_id, account_id)

        if account_id not in ext_map:
            # No external statement for this account → PENDING
            return ReconResult(
                recon_date=recon_date,
                account_id=account_id,
                account_type=account_type,
                currency="GBP",
                internal_balance=internal,
                external_balance=Decimal("0"),
                discrepancy=Decimal("0"),
                status="PENDING",
                source_file="",
            )

        ext = ext_map[account_id]
        discrepancy = abs(ext.balance - internal)
        status = "MATCHED" if discrepancy <= self._threshold else "DISCREPANCY"

        return ReconResult(
            recon_date=recon_date,
            account_id=account_id,
            account_type=account_type,
            currency=ext.currency,
            internal_balance=internal,
            external_balance=ext.balance,
            discrepancy=ext.balance - internal,
            status=status,
            source_file=ext.source_file,
        )

    def _write_to_clickhouse(self, r: ReconResult) -> None:
        """Insert one reconciliation event into banxe.safeguarding_events."""
        self._ch.execute(
            """
            INSERT INTO banxe.safeguarding_events
            (recon_date, account_id, account_type, currency,
             internal_balance, external_balance, discrepancy,
             status, alert_sent, source_file)
            VALUES
            """,
            {
                "recon_date": r.recon_date.isoformat(),
                "account_id": r.account_id,
                "account_type": r.account_type,
                "currency": r.currency,
                "internal_balance": float(r.internal_balance),
                "external_balance": float(r.external_balance),
                "discrepancy": float(r.discrepancy),
                "status": r.status,
                "alert_sent": int(r.alert_sent),
                "source_file": r.source_file,
            },
        )


class StatementFetcherProtocol(Protocol):
    """Protocol for StatementFetcher (avoids circular import in engine)."""
    def fetch(self, recon_date: date) -> list: ...
