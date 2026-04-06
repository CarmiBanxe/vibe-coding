#!/data/banxe/compliance-env/bin/python3
"""
Audit Trail — Phase 9
ClickHouse storage for all compliance screenings.
FCA requirement: 5-year retention (MLR 2017).
"""
import asyncio
import json
import hashlib
import sys
from datetime import datetime, timezone
from typing import Optional

CLICKHOUSE_URL = "http://127.0.0.1:8123"
CLICKHOUSE_DB  = "banxe"
TABLE          = "compliance_screenings"

# ── Schema setup ──────────────────────────────────────────────────────────────

CREATE_TABLE_SQL = f"""
CREATE TABLE IF NOT EXISTS {CLICKHOUSE_DB}.{TABLE}
(
    id                   String,
    timestamp            DateTime64(3, 'UTC'),
    entity_name          String,
    entity_type          LowCardinality(String),
    decision             LowCardinality(String),
    overall_risk         LowCardinality(String),
    composite_score      UInt16,
    sanctions_hit        UInt8,
    sanctions_lists      Array(String),
    sanctions_match      String,
    pep_hit              UInt8,
    pep_positions        String,
    ami_score            UInt8,
    ami_risk             LowCardinality(String),
    ami_findings         Array(String),
    kyb_result           String,
    crypto_result        String,
    doc_result           String,
    sar_required         UInt8,
    sar_draft_id         String,
    requires_edd         UInt8,
    reason               String,
    reviewer             String,
    notes                String,
    raw_json             String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, entity_name)
TTL timestamp + INTERVAL 5 YEAR
SETTINGS index_granularity = 8192
"""

CREATE_DB_SQL = f"CREATE DATABASE IF NOT EXISTS {CLICKHOUSE_DB}"


async def _ch_query(sql: str, data: str = None) -> dict:
    """Execute ClickHouse query via HTTP interface."""
    import httpx
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            if data:
                resp = await client.post(CLICKHOUSE_URL, content=data.encode(),
                                         params={"query": sql})
            else:
                resp = await client.post(CLICKHOUSE_URL, content=sql.encode())
        if resp.status_code != 200:
            return {"ok": False, "error": resp.text[:200]}
        return {"ok": True, "result": resp.text.strip()}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def setup_schema() -> dict:
    """Create DB and table if not exists."""
    r1 = await _ch_query(CREATE_DB_SQL)
    r2 = await _ch_query(CREATE_TABLE_SQL)
    return {"db": r1, "table": r2}


# ── Log a screening result ────────────────────────────────────────────────────

def _make_id(entity_name: str, ts: str) -> str:
    return hashlib.sha256(f"{entity_name}:{ts}".encode()).hexdigest()[:16]


def _safe_str(val) -> str:
    if val is None:
        return ""
    if isinstance(val, (dict, list)):
        return json.dumps(val, ensure_ascii=False)
    return str(val)


def _safe_arr(val) -> str:
    """Format Python list as ClickHouse Array literal."""
    if not val:
        return "[]"
    items = [f"'{str(v).replace(chr(39), '')}'" for v in val]
    return f"[{', '.join(items)}]"


async def log_screening(result: dict, reviewer: str = "system", notes: str = "") -> dict:
    """
    Persist screening result to ClickHouse.
    result: ScreeningResult dict (from screener.py or api.py)
    """
    ts = result.get("timestamp", datetime.now(timezone.utc).isoformat())
    entity_name = result.get("entity_name", "")
    record_id = _make_id(entity_name, ts)

    # ClickHouse INSERT via VALUES
    sql = f"""
    INSERT INTO {CLICKHOUSE_DB}.{TABLE}
    (id, timestamp, entity_name, entity_type, decision, overall_risk,
     composite_score, sanctions_hit, sanctions_lists, sanctions_match,
     pep_hit, pep_positions, ami_score, ami_risk, ami_findings,
     kyb_result, crypto_result, doc_result,
     sar_required, sar_draft_id, requires_edd, reason,
     reviewer, notes, raw_json)
    VALUES (
        '{record_id}',
        parseDateTimeBestEffort('{ts}'),
        '{entity_name.replace(chr(39), '')}',
        '{result.get("entity_type", "person")}',
        '{result.get("decision", "")}',
        '{result.get("overall_risk", "")}',
        {result.get("composite_score", result.get("ami_score", 0))},
        {1 if result.get("sanctions_hit") else 0},
        {_safe_arr(result.get("sanctions_lists", []))},
        '{_safe_str(result.get("sanctions_match", "")).replace(chr(39), "")}',
        {1 if result.get("pep_hit") else 0},
        '{_safe_str(result.get("pep_positions", []))[:1000]}',
        {result.get("ami_score", 0)},
        '{result.get("ami_risk", "NONE")}',
        {_safe_arr(result.get("ami_findings", []))},
        '{_safe_str(result.get("kyb_result", "")).replace(chr(39), "")[:500]}',
        '{_safe_str(result.get("crypto_result", "")).replace(chr(39), "")[:500]}',
        '{_safe_str(result.get("doc_result", "")).replace(chr(39), "")[:500]}',
        {1 if result.get("sar_required") or result.get("requires_sar") else 0},
        '{result.get("sar_draft_id", "")}',
        {1 if result.get("requires_edd") else 0},
        '{_safe_str(result.get("reason", "")).replace(chr(39), "")[:500]}',
        '{reviewer}',
        '{notes.replace(chr(39), "")}',
        '{json.dumps(result, ensure_ascii=False).replace(chr(39), "")[:8000]}'
    )
    """
    r = await _ch_query(sql)
    r["record_id"] = record_id
    return r


# ── Query history ─────────────────────────────────────────────────────────────

async def get_screening_history(entity_name: str, limit: int = 20) -> list[dict]:
    """Retrieve screening history for an entity."""
    name_safe = entity_name.replace("'", "")
    sql = f"""
    SELECT id, toString(timestamp) as ts, decision, overall_risk,
           composite_score, sanctions_hit, pep_hit, ami_score,
           sar_required, reason, reviewer
    FROM {CLICKHOUSE_DB}.{TABLE}
    WHERE entity_name ILIKE '%{name_safe}%'
    ORDER BY timestamp DESC
    LIMIT {limit}
    FORMAT JSONEachRow
    """
    r = await _ch_query(sql)
    if not r.get("ok") or not r.get("result"):
        return []
    rows = []
    for line in r["result"].split("\n"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    return rows


async def get_stats() -> dict:
    """Aggregate compliance stats from ClickHouse."""
    sql = f"""
    SELECT
        count() as total_screenings,
        countIf(decision = 'REJECT') as rejected,
        countIf(decision = 'HOLD') as held,
        countIf(decision = 'APPROVE') as approved,
        countIf(sar_required = 1) as sars_generated,
        countIf(sanctions_hit = 1) as sanctions_hits,
        countIf(pep_hit = 1) as pep_hits,
        avg(ami_score) as avg_ami_score,
        max(timestamp) as last_screening
    FROM {CLICKHOUSE_DB}.{TABLE}
    FORMAT JSON
    """
    r = await _ch_query(sql)
    if not r.get("ok"):
        return {"error": r.get("error", "ClickHouse error")}
    try:
        data = json.loads(r["result"])
        return data["data"][0] if data.get("data") else {}
    except Exception as e:
        return {"error": str(e), "raw": r.get("result", "")[:200]}


if __name__ == "__main__":
    async def main():
        print("Setting up ClickHouse schema...")
        r = await setup_schema()
        print(json.dumps(r, indent=2))

        print("\nTest log...")
        test_result = {
            "entity_name": "Test Entity",
            "entity_type": "person",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "decision": "APPROVE",
            "overall_risk": "LOW",
            "composite_score": 0,
            "sanctions_hit": False,
            "sanctions_lists": [],
            "sanctions_match": "",
            "pep_hit": False,
            "pep_positions": [],
            "ami_score": 0,
            "ami_risk": "NONE",
            "ami_findings": [],
            "requires_edd": False,
            "sar_required": False,
            "reason": "Clean",
        }
        r2 = await log_screening(test_result)
        print(json.dumps(r2, indent=2))

        print("\nStats:")
        stats = await get_stats()
        print(json.dumps(stats, indent=2))

    asyncio.run(main())
