#!/data/banxe/compliance-env/bin/python3
"""
CEO Dashboard — Phase 12
ClickHouse analytics + SAR queue management.
Exposes data via FastAPI router (mounted on main api.py at /dashboard).
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import httpx

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
from audit_trail import _ch_query, CLICKHOUSE_DB, TABLE

router = APIRouter(prefix="/dashboard", tags=["CEO Dashboard"])

# ── ClickHouse Materialized Views (created once at startup) ──────────────────

DAILY_STATS_VIEW = f"""
CREATE MATERIALIZED VIEW IF NOT EXISTS {CLICKHOUSE_DB}.mv_daily_stats
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (day, decision)
POPULATE
AS SELECT
    toDate(timestamp) AS day,
    decision,
    count()         AS total,
    sum(sanctions_hit) AS sanctions_hits,
    sum(pep_hit)    AS pep_hits,
    sum(sar_required) AS sars,
    avg(composite_score) AS avg_score
FROM {CLICKHOUSE_DB}.{TABLE}
GROUP BY day, decision
"""

SAR_QUEUE_VIEW = f"""
CREATE MATERIALIZED VIEW IF NOT EXISTS {CLICKHOUSE_DB}.mv_sar_queue
ENGINE = ReplacingMergeTree()
ORDER BY id
POPULATE
AS SELECT
    id,
    timestamp,
    entity_name,
    entity_type,
    composite_score,
    overall_risk,
    reason,
    sar_draft_id,
    reviewer,
    notes
FROM {CLICKHOUSE_DB}.{TABLE}
WHERE sar_required = 1
"""


async def setup_dashboard_views():
    """Create materialized views for dashboard. Called at startup."""
    await _ch_query(DAILY_STATS_VIEW)
    await _ch_query(SAR_QUEUE_VIEW)


# ── Dashboard endpoints ───────────────────────────────────────────────────────

@router.get("/overview")
async def dashboard_overview():
    """
    CEO overview: totals, today vs yesterday, SAR queue size.
    """
    sql_totals = f"""
    SELECT
        count()                              AS total_all_time,
        countIf(toDate(timestamp) = today()) AS today,
        countIf(toDate(timestamp) = yesterday()) AS yesterday,
        countIf(decision = 'REJECT')         AS total_rejected,
        countIf(decision = 'HOLD')           AS total_held,
        countIf(decision = 'APPROVE')        AS total_approved,
        countIf(sar_required = 1)            AS sar_queue_total,
        countIf(sar_required = 1 AND reviewer = 'system') AS sar_pending_review,
        countIf(sanctions_hit = 1)           AS sanctions_hits,
        countIf(pep_hit = 1)                 AS pep_hits,
        round(avg(composite_score), 1)       AS avg_risk_score,
        max(timestamp)                       AS last_screening
    FROM {CLICKHOUSE_DB}.{TABLE}
    FORMAT JSON
    """
    r = await _ch_query(sql_totals)
    if not r.get("ok"):
        raise HTTPException(503, f"ClickHouse error: {r.get('error')}")
    try:
        data = json.loads(r["result"])
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "overview": data["data"][0] if data.get("data") else {},
        }
    except Exception as e:
        raise HTTPException(500, str(e))


@router.get("/daily")
async def daily_stats(days: int = 30):
    """Daily screening volume and decisions for the last N days."""
    sql = f"""
    SELECT
        toDate(timestamp)            AS day,
        count()                      AS total,
        countIf(decision='REJECT')   AS rejected,
        countIf(decision='HOLD')     AS held,
        countIf(decision='APPROVE')  AS approved,
        countIf(sar_required=1)      AS sars,
        round(avg(composite_score),1) AS avg_score
    FROM {CLICKHOUSE_DB}.{TABLE}
    WHERE timestamp >= now() - INTERVAL {days} DAY
    GROUP BY day
    ORDER BY day DESC
    FORMAT JSONEachRow
    """
    r = await _ch_query(sql)
    if not r.get("ok"):
        raise HTTPException(503, r.get("error"))
    rows = []
    for line in (r.get("result") or "").split("\n"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    return {"days": days, "data": rows}


@router.get("/sar-queue")
async def sar_queue(status: str = "pending", limit: int = 50):
    """
    SAR queue management.
    status: pending (reviewer=system), reviewed, all
    """
    where_clause = {
        "pending":  "sar_required = 1 AND reviewer = 'system'",
        "reviewed": "sar_required = 1 AND reviewer != 'system'",
        "all":      "sar_required = 1",
    }.get(status, "sar_required = 1")

    sql = f"""
    SELECT
        id, toString(timestamp) AS ts,
        entity_name, entity_type, overall_risk,
        composite_score, reason, sar_draft_id, reviewer, notes
    FROM {CLICKHOUSE_DB}.{TABLE}
    WHERE {where_clause}
    ORDER BY timestamp DESC
    LIMIT {limit}
    FORMAT JSONEachRow
    """
    r = await _ch_query(sql)
    if not r.get("ok"):
        raise HTTPException(503, r.get("error"))
    rows = []
    for line in (r.get("result") or "").split("\n"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    return {"status": status, "count": len(rows), "queue": rows}


class SARReviewRequest(BaseModel):
    record_id: str
    reviewer: str
    notes: str = ""
    action: str = "reviewed"   # reviewed / escalated / filed


@router.post("/sar-queue/review")
async def review_sar(req: SARReviewRequest):
    """Mark a SAR as reviewed by human MLRO."""
    sql = f"""
    ALTER TABLE {CLICKHOUSE_DB}.{TABLE}
    UPDATE reviewer = '{req.reviewer}', notes = '{req.notes.replace(chr(39), "")}'
    WHERE id = '{req.record_id}'
    """
    r = await _ch_query(sql)
    if not r.get("ok"):
        raise HTTPException(503, r.get("error"))
    return {
        "record_id": req.record_id,
        "action": req.action,
        "reviewer": req.reviewer,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@router.get("/risk-heatmap")
async def risk_heatmap():
    """Top risk entities, jurisdictions, and decision breakdown."""
    sql_top_entities = f"""
    SELECT entity_name, count() AS count, max(composite_score) AS max_score, any(decision) AS last_decision
    FROM {CLICKHOUSE_DB}.{TABLE}
    WHERE decision IN ('REJECT', 'HOLD')
    GROUP BY entity_name
    ORDER BY max_score DESC
    LIMIT 20
    FORMAT JSONEachRow
    """
    sql_decisions = f"""
    SELECT decision, count() AS count, round(avg(composite_score),1) AS avg_score
    FROM {CLICKHOUSE_DB}.{TABLE}
    GROUP BY decision
    FORMAT JSONEachRow
    """
    r1 = await _ch_query(sql_top_entities)
    r2 = await _ch_query(sql_decisions)

    def parse_rows(r):
        rows = []
        for line in (r.get("result") or "").split("\n"):
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except Exception:
                    pass
        return rows

    return {
        "top_risk_entities": parse_rows(r1),
        "decision_breakdown": parse_rows(r2),
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }


@router.get("/agent-activity")
async def agent_activity():
    """Screening activity breakdown by entity_type (proxy for which agent handled it)."""
    sql = f"""
    SELECT
        entity_type,
        count()                       AS total,
        countIf(decision='REJECT')    AS rejected,
        countIf(decision='HOLD')      AS held,
        countIf(sar_required=1)       AS sars,
        round(avg(composite_score),1) AS avg_score
    FROM {CLICKHOUSE_DB}.{TABLE}
    GROUP BY entity_type
    ORDER BY total DESC
    FORMAT JSONEachRow
    """
    r = await _ch_query(sql)
    rows = []
    for line in (r.get("result") or "").split("\n"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    return {"agent_activity": rows}


if __name__ == "__main__":
    async def main():
        print("Setting up dashboard views...")
        await setup_dashboard_views()
        print("Done. Overview:")
        # Quick test via HTTP
        async with httpx.AsyncClient() as c:
            r = await c.get("http://127.0.0.1:8090/dashboard/overview")
            print(r.text[:500])
    asyncio.run(main())
