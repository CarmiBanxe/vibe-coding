"""
test_reconciliation.py — T-16..T-30
IL-007 Step 4: ReconciliationEngine + StatementFetcher tests
No real HTTP, no real ClickHouse — all dependencies mocked.
"""
import csv
import pytest
import tempfile
from datetime import date
from decimal import Decimal
from pathlib import Path
from unittest.mock import MagicMock, call

from compliance.recon.reconciliation_engine import (
    ReconciliationEngine,
    ReconResult,
    SAFEGUARDING_ACCOUNTS,
    ORG_ID,
    LEDGER_ID,
    _DEFAULT_THRESHOLD,
)
from compliance.recon.statement_fetcher import StatementFetcher, StatementBalance

OP_ACCOUNT = "019d6332-f274-709a-b3a7-983bc8745886"
CF_ACCOUNT = "019d6332-da7f-752f-b9fd-fa1c6fc777ec"
RECON_DATE = date(2026, 4, 6)


# ── helpers ──────────────────────────────────────────────────────────────────

def _make_engine(
    internal_balances: dict,
    external_balances: list,
    threshold: Decimal = _DEFAULT_THRESHOLD,
) -> tuple:
    ledger = MagicMock()
    ledger.get_balance.side_effect = lambda org, ledger_id, acct: internal_balances.get(
        acct, Decimal("0")
    )

    ch = MagicMock()

    fetcher = MagicMock()
    fetcher.fetch.return_value = external_balances

    engine = ReconciliationEngine(ledger, ch, fetcher, threshold=threshold)
    return engine, ledger, ch, fetcher


def _stmt(account_id: str, balance: str, currency: str = "GBP") -> StatementBalance:
    return StatementBalance(
        account_id=account_id,
        currency=currency,
        balance=Decimal(balance),
        statement_date=RECON_DATE,
        source_file="stmt_20260406.csv",
    )


# ── T-16: MATCHED when balances equal ────────────────────────────────────────

def test_T16_matched_when_equal():
    engine, *_ = _make_engine(
        {OP_ACCOUNT: Decimal("1000.00"), CF_ACCOUNT: Decimal("5000.00")},
        [_stmt(OP_ACCOUNT, "1000.00"), _stmt(CF_ACCOUNT, "5000.00")],
    )
    results = engine.reconcile(RECON_DATE)
    for r in results:
        assert r.status == "MATCHED"


# ── T-17: MATCHED within threshold ───────────────────────────────────────────

def test_T17_matched_within_threshold():
    engine, *_ = _make_engine(
        {OP_ACCOUNT: Decimal("1000.00"), CF_ACCOUNT: Decimal("5000.00")},
        [_stmt(OP_ACCOUNT, "1000.50"), _stmt(CF_ACCOUNT, "5000.00")],  # £0.50 diff
    )
    results = engine.reconcile(RECON_DATE)
    op_result = next(r for r in results if r.account_id == OP_ACCOUNT)
    assert op_result.status == "MATCHED"


# ── T-18: DISCREPANCY when delta > threshold ─────────────────────────────────

def test_T18_discrepancy_when_delta_exceeds_threshold():
    engine, *_ = _make_engine(
        {OP_ACCOUNT: Decimal("1000.00"), CF_ACCOUNT: Decimal("5000.00")},
        [_stmt(OP_ACCOUNT, "1002.00"), _stmt(CF_ACCOUNT, "5000.00")],  # £2 diff
    )
    results = engine.reconcile(RECON_DATE)
    op_result = next(r for r in results if r.account_id == OP_ACCOUNT)
    assert op_result.status == "DISCREPANCY"
    assert op_result.discrepancy == Decimal("2.00")


# ── T-19: PENDING when no external statement ─────────────────────────────────

def test_T19_pending_when_no_external_statement():
    engine, *_ = _make_engine(
        {OP_ACCOUNT: Decimal("1000.00"), CF_ACCOUNT: Decimal("5000.00")},
        [],  # no statement files
    )
    results = engine.reconcile(RECON_DATE)
    for r in results:
        assert r.status == "PENDING"
        assert r.source_file == ""


# ── T-20: calls LedgerPort for both accounts ─────────────────────────────────

def test_T20_calls_ledger_port_for_both_accounts():
    engine, ledger, *_ = _make_engine(
        {OP_ACCOUNT: Decimal("100.00"), CF_ACCOUNT: Decimal("200.00")},
        [_stmt(OP_ACCOUNT, "100.00"), _stmt(CF_ACCOUNT, "200.00")],
    )
    engine.reconcile(RECON_DATE)
    calls = ledger.get_balance.call_args_list
    called_accounts = {c.args[2] for c in calls}
    assert called_accounts == set(SAFEGUARDING_ACCOUNTS.keys())


# ── T-21: writes two ClickHouse rows ─────────────────────────────────────────

def test_T21_writes_two_clickhouse_rows():
    engine, _, ch, _ = _make_engine(
        {OP_ACCOUNT: Decimal("100.00"), CF_ACCOUNT: Decimal("200.00")},
        [_stmt(OP_ACCOUNT, "100.00"), _stmt(CF_ACCOUNT, "200.00")],
    )
    engine.reconcile(RECON_DATE)
    assert ch.execute.call_count == 2


# ── T-22: discrepancy = external - internal (signed) ─────────────────────────

def test_T22_discrepancy_is_signed():
    engine, *_ = _make_engine(
        {OP_ACCOUNT: Decimal("1000.00"), CF_ACCOUNT: Decimal("5000.00")},
        [_stmt(OP_ACCOUNT, "998.00"), _stmt(CF_ACCOUNT, "5000.00")],  # bank has less
    )
    results = engine.reconcile(RECON_DATE)
    op = next(r for r in results if r.account_id == OP_ACCOUNT)
    assert op.discrepancy == Decimal("-2.00")   # bank < internal
    assert op.status == "DISCREPANCY"


# ── T-23: ReconResult is frozen ───────────────────────────────────────────────

def test_T23_recon_result_is_frozen():
    r = ReconResult(
        recon_date=RECON_DATE,
        account_id=OP_ACCOUNT,
        account_type="operational",
        currency="GBP",
        internal_balance=Decimal("100"),
        external_balance=Decimal("100"),
        discrepancy=Decimal("0"),
        status="MATCHED",
        source_file="stmt.csv",
    )
    with pytest.raises(Exception):
        r.status = "DISCREPANCY"  # type: ignore[misc]


# ── T-24: custom threshold respected ─────────────────────────────────────────

def test_T24_custom_threshold():
    engine, *_ = _make_engine(
        {OP_ACCOUNT: Decimal("1000.00"), CF_ACCOUNT: Decimal("5000.00")},
        [_stmt(OP_ACCOUNT, "1000.005"), _stmt(CF_ACCOUNT, "5000.00")],
        threshold=Decimal("0.01"),  # tight threshold
    )
    results = engine.reconcile(RECON_DATE)
    op = next(r for r in results if r.account_id == OP_ACCOUNT)
    assert op.status == "MATCHED"   # 0.005 < 0.01


# ── T-25: StatementFetcher returns empty when file missing ───────────────────

def test_T25_fetcher_returns_empty_when_file_missing():
    with tempfile.TemporaryDirectory() as tmpdir:
        fetcher = StatementFetcher(statement_dir=tmpdir)
        result = fetcher.fetch(RECON_DATE)
    assert result == []


# ── T-26: StatementFetcher parses CSV correctly ──────────────────────────────

def test_T26_fetcher_parses_csv():
    with tempfile.TemporaryDirectory() as tmpdir:
        csv_path = Path(tmpdir) / "stmt_20260406.csv"
        with csv_path.open("w", newline="") as f:
            writer = csv.DictWriter(
                f,
                fieldnames=["account_id", "currency", "balance", "statement_date", "source_file"]
            )
            writer.writeheader()
            writer.writerow({
                "account_id": OP_ACCOUNT,
                "currency": "GBP",
                "balance": "1234.56",
                "statement_date": "2026-04-06",
                "source_file": "stmt_20260406.csv",
            })

        fetcher = StatementFetcher(statement_dir=tmpdir)
        results = fetcher.fetch(RECON_DATE)

    assert len(results) == 1
    assert results[0].account_id == OP_ACCOUNT
    assert results[0].balance == Decimal("1234.56")
    assert results[0].currency == "GBP"


# ── T-27: StatementFetcher returns multiple rows ─────────────────────────────

def test_T27_fetcher_returns_multiple_rows():
    with tempfile.TemporaryDirectory() as tmpdir:
        csv_path = Path(tmpdir) / "stmt_20260406.csv"
        with csv_path.open("w", newline="") as f:
            writer = csv.DictWriter(
                f,
                fieldnames=["account_id", "currency", "balance", "statement_date", "source_file"]
            )
            writer.writeheader()
            for acct, bal in [(OP_ACCOUNT, "1000.00"), (CF_ACCOUNT, "5000.00")]:
                writer.writerow({
                    "account_id": acct, "currency": "GBP",
                    "balance": bal, "statement_date": "2026-04-06",
                    "source_file": "stmt_20260406.csv",
                })

        fetcher = StatementFetcher(statement_dir=tmpdir)
        results = fetcher.fetch(RECON_DATE)

    assert len(results) == 2
    accounts = {r.account_id for r in results}
    assert accounts == {OP_ACCOUNT, CF_ACCOUNT}


# ── T-28: StatementBalance is frozen ─────────────────────────────────────────

def test_T28_statement_balance_is_frozen():
    b = StatementBalance(
        account_id=OP_ACCOUNT,
        currency="GBP",
        balance=Decimal("100"),
        statement_date=RECON_DATE,
        source_file="stmt.csv",
    )
    with pytest.raises(Exception):
        b.balance = Decimal("200")  # type: ignore[misc]


# ── T-29: both safeguarding accounts tracked ─────────────────────────────────

def test_T29_both_safeguarding_accounts_in_results():
    engine, *_ = _make_engine(
        {OP_ACCOUNT: Decimal("100.00"), CF_ACCOUNT: Decimal("500.00")},
        [_stmt(OP_ACCOUNT, "100.00"), _stmt(CF_ACCOUNT, "500.00")],
    )
    results = engine.reconcile(RECON_DATE)
    account_ids = {r.account_id for r in results}
    assert OP_ACCOUNT in account_ids
    assert CF_ACCOUNT in account_ids
    assert len(results) == 2


# ── T-30: source_file recorded in result ─────────────────────────────────────

def test_T30_source_file_recorded():
    engine, *_ = _make_engine(
        {OP_ACCOUNT: Decimal("100.00"), CF_ACCOUNT: Decimal("200.00")},
        [_stmt(OP_ACCOUNT, "100.00"), _stmt(CF_ACCOUNT, "200.00")],
    )
    results = engine.reconcile(RECON_DATE)
    for r in results:
        assert r.source_file == "stmt_20260406.csv"
