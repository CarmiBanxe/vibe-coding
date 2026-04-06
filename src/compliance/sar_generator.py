"""
sar_generator.py — Suspicious Activity Report generator
Banxe Collective — FCA / POCA 2002 / MLR 2017 compliant

Generates SAR narratives and IDs for MLRO review.
Logs to ClickHouse banxe.sar_queue (append-only, I-24).
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from typing import Any

try:
    from clickhouse_driver import Client as CHClient
    _CH_AVAILABLE = True
except ImportError:
    _CH_AVAILABLE = False

_CH_HOST = "localhost"
_CH_PORT = 9000
_CH_DB   = "banxe"


def _build_narrative(result: dict[str, Any]) -> str:
    """Build SAR narrative from screening result."""
    parts: list[str] = []
    name = result.get("entity_name") or result.get("name", "UNKNOWN")
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    parts.append(f"SUSPICIOUS ACTIVITY REPORT — {ts}")
    parts.append(f"Subject: {name}")

    if result.get("sanctions_hit"):
        lists = result.get("sanctions_lists", [])
        parts.append(
            f"SANCTIONS MATCH detected on: {', '.join(lists) if lists else 'unknown list'}. "
            "Activity constitutes a potential breach of The Sanctions and Anti-Money Laundering Act 2018."
        )

    if result.get("pep_hit"):
        parts.append(
            "POLITICALLY EXPOSED PERSON (PEP) identified. "
            "Enhanced due diligence required under MLR 2017 Reg. 35."
        )

    score = result.get("risk_score") or result.get("composite", 0)
    if score:
        parts.append(f"Composite risk score: {score}/100.")

    if result.get("adverse_media"):
        parts.append("Adverse media hits detected.")

    if result.get("crypto_risk"):
        addr = result.get("wallet_address", "")
        parts.append(
            f"Cryptocurrency wallet {addr} flagged for high-risk activity."
        )

    tx_amount = result.get("amount_gbp") or result.get("amount")
    if tx_amount and float(tx_amount) >= 10_000:
        parts.append(
            f"Transaction amount £{tx_amount:,.2f} exceeds £10,000 threshold "
            "(FCA SS1/23, I-25 ExplanationBundle attached)."
        )

    reason = result.get("reason", "")
    if reason:
        parts.append(f"System reason: {reason}")

    parts.append(
        "This SAR is submitted in accordance with Part 7 of the Proceeds of Crime Act 2002 "
        "and is designated for MLRO review within 24 hours."
    )
    return "\n\n".join(parts)


def _log_to_clickhouse(sar_id: str, narrative: str, result: dict[str, Any]) -> None:
    """Append SAR to ClickHouse banxe.sar_queue (I-24: append-only)."""
    if not _CH_AVAILABLE:
        return
    try:
        ch = CHClient(host=_CH_HOST, port=_CH_PORT, database=_CH_DB)
        ch.execute(
            """
            INSERT INTO banxe.sar_queue
                (sar_id, entity_name, risk_score, narrative, result_json, created_at, status)
            VALUES
            """,
            [{
                "sar_id":      sar_id,
                "entity_name": result.get("entity_name") or result.get("name", ""),
                "risk_score":  int(result.get("risk_score") or result.get("composite") or 0),
                "narrative":   narrative,
                "result_json": json.dumps(result, default=str),
                "created_at":  datetime.now(timezone.utc),
                "status":      "PENDING_MLRO",
            }],
        )
    except Exception:
        # Non-fatal: SAR narrative returned regardless of CH availability
        pass


def generate_sar(result: dict[str, Any]) -> dict[str, str]:
    """
    Generate a SAR from a screening/transaction result.

    Returns:
        {"sar_id": str, "narrative": str}

    Logs to ClickHouse banxe.sar_queue (append-only, I-24).
    Fails safe: ClickHouse unavailability does not block SAR generation.
    """
    sar_id    = str(uuid.uuid4())
    narrative = _build_narrative(result)

    _log_to_clickhouse(sar_id, narrative, result)

    return {
        "sar_id":    sar_id,
        "narrative": narrative,
    }
