"""
statement_fetcher.py — StatementFetcher (CSV placeholder)
Block D-recon, IL-007 Step 3
FCA CASS 7.15: external bank statement ingestion.

Phase 1 (Sprint 9): CSV file from SFTP drop.
Phase 2 (Sprint 10): Barclays Open Banking API (once account opened).
"""
from __future__ import annotations

import csv
import os
from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from pathlib import Path
from typing import List, Optional


@dataclass(frozen=True)
class StatementBalance:
    """External bank balance for one account on one date."""
    account_id: str      # internal mapping key (Midaz account UUID)
    currency: str        # ISO-4217
    balance: Decimal     # closing balance in major currency unit (e.g. £100.00)
    statement_date: date
    source_file: str     # filename for audit trail


class StatementFetcher:
    """
    Reads external bank statement CSV and returns per-account balances.

    CSV format (one row per account per date):
        account_id, currency, balance, statement_date, source_file
        019d6332-f274-709a-b3a7-983bc8745886,GBP,5000.00,2026-04-06,stmt_20260406.csv

    In production: replace with SFTP download + CAMT.053 / OFX parser.
    """

    def __init__(self, statement_dir: Optional[str] = None) -> None:
        self._dir = Path(
            statement_dir
            or os.environ.get("STATEMENT_DIR", "/data/banxe/statements")
        )

    def fetch(self, recon_date: date) -> List[StatementBalance]:
        """
        Return all account balances for `recon_date`.
        Looks for file named: stmt_YYYYMMDD.csv in statement_dir.
        Returns empty list if file not found (triggers PENDING status in engine).
        """
        filename = f"stmt_{recon_date.strftime('%Y%m%d')}.csv"
        path = self._dir / filename
        if not path.exists():
            return []

        balances: List[StatementBalance] = []
        with path.open(newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                balances.append(
                    StatementBalance(
                        account_id=row["account_id"].strip(),
                        currency=row["currency"].strip().upper(),
                        balance=Decimal(row["balance"].strip()),
                        statement_date=date.fromisoformat(row["statement_date"].strip()),
                        source_file=filename,
                    )
                )
        return balances

    def fetch_from_file(self, path: Path) -> List[StatementBalance]:
        """Load from explicit file path (for testing / manual reconciliation)."""
        if not path.exists():
            return []
        balances: List[StatementBalance] = []
        with path.open(newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                balances.append(
                    StatementBalance(
                        account_id=row["account_id"].strip(),
                        currency=row["currency"].strip().upper(),
                        balance=Decimal(row["balance"].strip()),
                        statement_date=date.fromisoformat(row["statement_date"].strip()),
                        source_file=str(path.name),
                    )
                )
        return balances
