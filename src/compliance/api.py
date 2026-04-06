#!/data/banxe/compliance-env/bin/python3
"""
Banxe Collective LexisNexis — FastAPI Gateway
Phase 10: Full orchestration of all compliance modules.
Port: 8090
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time
import glob
from datetime import datetime, timezone
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
import httpx

# ── Path setup ────────────────────────────────────────────────────────────────
BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)

from pep_check       import check_pep
from adverse_media   import check_adverse_media
from sanctions_check import check_sanctions        # backward-compat wrapper → screen_entity()
from doc_verify      import verify_passport, verify_face
from kyb_check       import check_company
from crypto_aml      import check_wallet           # backward-compat wrapper → analyse_chain()
from tx_monitor      import check_transaction      # backward-compat wrapper → score_transaction()
from models          import TransactionInput        # for TransactionRequest mapping
from sar_generator   import generate_sar
from audit_trail     import log_screening, get_screening_history, get_stats, setup_schema
from emergency_stop  import activate_stop, clear_stop, get_stop_state, require_not_stopped
from utils.explanation_builder import ExplanationBundle
try:
    from legal_databases import check_legal_exposure
    LEGAL_DB_AVAILABLE = True
except ImportError:
    LEGAL_DB_AVAILABLE = False

LOGS_DIR = "/data/banxe/data/logs"
os.makedirs(LOGS_DIR, exist_ok=True)

# ── App setup ─────────────────────────────────────────────────────────────────
app = FastAPI(
    title="Banxe Collective LexisNexis",
    description="Open-source AML/KYC compliance stack for Banxe AI Bank",
    version="1.0.0",
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def startup():
    await setup_schema()


# ── Request / Response models ─────────────────────────────────────────────────

class PersonScreenRequest(BaseModel):
    name: str
    dob: Optional[str] = None
    nationality: Optional[str] = None
    skip_ami: bool = False

class CompanyScreenRequest(BaseModel):
    name: str
    jurisdiction: str = "GB"
    number: Optional[str] = None

class WalletScreenRequest(BaseModel):
    address: str
    chain: str = "eth"

class TransactionRequest(BaseModel):
    from_name: str
    to_name: str
    amount: float
    currency: str = "GBP"
    tx_type: str = "wire"
    jurisdiction: Optional[str] = None
    from_account: Optional[str] = None
    to_account: Optional[str] = None

class EmergencyStopRequest(BaseModel):
    operator_id: str                # email or operator handle of the person activating stop
    reason: str                     # mandatory free-text explanation (audit trail)
    scope: str = "all"              # "all" or comma-separated engine list (Phase 2)

class EmergencyResumeRequest(BaseModel):
    mlro_id: str                    # MLRO identity — required for resume authority
    resume_reason: str              # mandatory explanation for clearing stop


# ── Helpers ───────────────────────────────────────────────────────────────────

def _save_log(name: str, result: dict) -> str:
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    slug = name.lower().replace(" ", "_")[:30]
    path = os.path.join(LOGS_DIR, f"{ts}_{slug}.json")
    with open(path, "w") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    return os.path.basename(path)


def _load_risk_matrix() -> dict:
    path = "/data/banxe/config/risk_matrix.json"
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {"weights": {}, "thresholds": {"reject": 70, "enhanced_due_diligence": 40}}


def _composite_score(result: dict, rm: dict) -> int:
    weights = rm.get("weights", {})
    score = 0
    if result.get("sanctions_hit"):
        score += weights.get("sanctions_hit", 100)
    if result.get("pep_hit"):
        score += weights.get("pep_hit", 40)
    ami = result.get("ami_score", 0)
    if ami > 80:
        score += weights.get("adverse_media_score > 80", 50)
    elif ami > 50:
        score += weights.get("adverse_media_score > 50", 30)
    if result.get("doc_expired"):
        score += weights.get("doc_expired", 50)
    if result.get("kyb_high_risk"):
        score += weights.get("kyb_officer_flagged", 35)
    if result.get("crypto_flagged"):
        score += weights.get("crypto_wallet_flagged", 60)
    return min(score, 200)


def _make_decision(composite: int, rm: dict) -> str:
    t = rm.get("thresholds", {})
    if composite >= t.get("reject", 70):
        return "REJECT"
    if composite >= t.get("enhanced_due_diligence", 40):
        return "HOLD"
    return "APPROVE"


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.post("/api/v1/screen/person")
async def screen_person(
    req: PersonScreenRequest,
    background_tasks: BackgroundTasks,
    _: None = Depends(require_not_stopped),
):
    """
    Full person screening: Sanctions + PEP + Adverse Media (PARALLEL SCREENING LAYER).
    Returns risk decision and SAR draft if required.
    """
    name = req.name.strip()
    if not name:
        raise HTTPException(400, "name is required")

    t0 = time.time()
    rm = _load_risk_matrix()

    # PARALLEL SCREENING LAYER
    loop = asyncio.get_event_loop()
    sanctions_task  = asyncio.create_task(check_sanctions(name))
    pep_task        = loop.run_in_executor(None, check_pep, name)
    ami_task        = asyncio.create_task(check_adverse_media(name)) if not req.skip_ami else None

    sanctions_result = await sanctions_task
    pep_result       = await pep_task
    ami_result       = await ami_task if ami_task else {"risk_score": 0, "risk_level": "NONE", "hits": 0, "articles": []}

    # Aggregate
    result = {
        "entity_name":    name,
        "entity_type":    "person",
        "timestamp":      datetime.now(timezone.utc).isoformat(),
        "screening_time_ms": int((time.time() - t0) * 1000),

        # Sanctions
        "sanctions_hit":    sanctions_result.get("sanctioned", False),
        "sanctions_lists":  sanctions_result.get("lists_with_hits", []),
        "sanctions_match":  sanctions_result.get("top_match", ""),

        # PEP
        "pep_hit":       pep_result.get("hit", False),
        "pep_positions": pep_result.get("positions", []),
        "pep_qid":       pep_result.get("qid", ""),

        # Adverse Media
        "ami_score":    ami_result.get("risk_score", 0),
        "ami_risk":     ami_result.get("risk_level", "NONE"),
        "ami_findings": [a.get("title", "") for a in ami_result.get("top_articles", [])[:3]],
        "ami_hits":     ami_result.get("hits", 0),
    }

    composite = _composite_score(result, rm)
    decision  = _make_decision(composite, rm)
    result.update({
        "composite_score": composite,
        "decision":   decision,
        "overall_risk": (
            "BLOCK" if result["sanctions_hit"] else
            "HIGH"   if composite >= 70 else
            "MEDIUM" if composite >= 40 else
            "LOW"
        ),
        "requires_edd": composite >= rm.get("thresholds", {}).get("enhanced_due_diligence", 40),
        "sar_required": composite >= rm.get("sar_auto_threshold", 85) or result["sanctions_hit"],
        "reason": (
            f"Sanctions: {', '.join(result['sanctions_lists'])}" if result["sanctions_hit"] else
            f"PEP + score {composite}" if result["pep_hit"] else
            f"AMI score {result['ami_score']}" if result["ami_score"] >= 40 else
            "Clean"
        ),
    })

    # EDD — Legal exposure check (EUR-Lex + BAILII) when composite_score >= 40
    if result["requires_edd"] and LEGAL_DB_AVAILABLE:
        try:
            legal = await check_legal_exposure(name)
            result["legal_risk_score"] = legal.get("legal_risk_score", 0)
            result["legal_risk_level"] = legal.get("legal_risk_level", "NONE")
            result["eu_legal_hits"]    = legal.get("eu_legal", {}).get("hits", 0)
            result["uk_legal_hits"]    = legal.get("uk_legal", {}).get("hits", 0)
            result["legal_findings"]   = (
                legal.get("eu_legal", {}).get("findings", [])[:3] +
                legal.get("uk_legal", {}).get("findings", [])[:3]
            )
            # Boost composite score if legal exposure found
            if legal.get("legal_risk_score", 0) >= 20:
                boost = min(legal["legal_risk_score"] // 2, 20)
                result["composite_score"] = min(result["composite_score"] + boost, 200)
                result["decision"] = _make_decision(result["composite_score"], rm)
        except Exception:
            result["legal_risk_score"] = 0

    # SAR if needed
    if result["sar_required"]:
        sar = generate_sar(result)
        result["sar_draft"] = sar.get("narrative", "")
        result["sar_draft_id"] = sar.get("sar_id", "")

    # Log to file + ClickHouse (background)
    report_id = _save_log(name, result)
    result["report_id"] = report_id
    background_tasks.add_task(log_screening, result)

    return result


@app.post("/api/v1/screen/company")
async def screen_company(
    req: CompanyScreenRequest,
    background_tasks: BackgroundTasks,
    _: None = Depends(require_not_stopped),
):
    """KYB company screening with UBO sanctions/PEP check."""
    name = req.name.strip()
    if not name:
        raise HTTPException(400, "name is required")

    kyb = await check_company(name, req.jurisdiction, req.number)

    # Also screen company name in sanctions
    sanctions = await check_sanctions(name, entity_type="company")

    rm = _load_risk_matrix()
    result = {
        "entity_name":  name,
        "entity_type":  "company",
        "timestamp":    datetime.now(timezone.utc).isoformat(),
        "jurisdiction": req.jurisdiction,
        "sanctions_hit":   sanctions.get("sanctioned", False),
        "sanctions_lists": sanctions.get("lists_with_hits", []),
        "kyb_result":      kyb,
        "kyb_high_risk":   bool(kyb.get("high_risk_ubos")),
        "high_risk_ubos":  kyb.get("high_risk_ubos", []),
    }

    composite = _composite_score(result, rm)
    decision  = _make_decision(composite, rm)
    result.update({
        "composite_score": composite,
        "decision": decision,
        "overall_risk": "HIGH" if composite >= 70 else "MEDIUM" if composite >= 40 else "LOW",
        "requires_edd": composite >= 40,
        "reason": kyb.get("reason", "Clean") if not sanctions["sanctioned"] else f"Sanctions: {sanctions['top_match']}",
    })

    report_id = _save_log(name, result)
    result["report_id"] = report_id
    background_tasks.add_task(log_screening, result)
    return result


@app.post("/api/v1/screen/wallet")
async def screen_wallet(
    req: WalletScreenRequest,
    background_tasks: BackgroundTasks,
    _: None = Depends(require_not_stopped),
):
    """Crypto wallet AML screening via FINOS OpenAML + Watchman OFAC."""
    result = await check_wallet(req.address, req.chain)

    if "error" not in result:
        rm = _load_risk_matrix()
        result.update({
            "entity_name":   req.address,
            "entity_type":   "wallet",
            "timestamp":     datetime.now(timezone.utc).isoformat(),
            "sar_required":  result.get("risk_score", 0) >= 70,
            "report_id":     _save_log(req.address, result),
        })
        background_tasks.add_task(log_screening, result)

    return result


@app.post("/api/v1/transaction/check")
async def transaction_check(
    req: TransactionRequest,
    _: None = Depends(require_not_stopped),
):
    """Real-time transaction monitoring rules (structuring, velocity, jurisdiction)."""
    # Map Pydantic request → TransactionInput dataclass expected by tx_monitor
    tx_input = TransactionInput(
        origin_jurisdiction      = req.jurisdiction or "GB",
        destination_jurisdiction = req.jurisdiction or "GB",
        amount_gbp               = req.amount,   # api.py assumes GBP; multi-currency TBD
        currency                 = req.currency,
        sender_account           = req.from_account or "",
        recipient_account        = req.to_account or "",
        tx_type                  = req.tx_type,
    )
    result = await check_transaction(tx_input)

    # If flagged — also screen counterparties
    if result.get("flagged"):
        sender_check = await check_sanctions(req.from_name)
        result["sender_sanctions"] = sender_check.get("sanctioned", False)

    # I-25: ExplanationBundle required for transactions ≥ £10,000 (FCA SS1/23)
    if req.amount >= 10_000:
        result["explanation"] = ExplanationBundle.from_banxe_result(
            result, amount_gbp=req.amount
        ).model_dump()

    return result


@app.get("/api/v1/legal/{entity_name}")
async def legal_lookup(entity_name: str):
    """EUR-Lex + BAILII legal exposure check (EDD layer)."""
    if not LEGAL_DB_AVAILABLE:
        raise HTTPException(503, "legal_databases module not available")
    return await check_legal_exposure(entity_name)


@app.get("/api/v1/kyb/{entity_id}")
async def kyb_entity(entity_id: str):
    """
    Read-only. Returns unified KYB record from Postgres by entity_id (UUID).
    Includes: basic company fields, officers, sanctioned_or_pep flag.
    Does not modify any record or trigger new screening.
    """
    try:
        import asyncpg
    except ImportError:
        raise HTTPException(503, "asyncpg not available")

    PG_DSN = "postgresql://banxe:banxe_secure_2026@127.0.0.1:5432/banxe_compliance"

    try:
        conn = await asyncpg.connect(PG_DSN, timeout=5)
    except Exception as e:
        raise HTTPException(503, f"Postgres unavailable: {e}")

    try:
        # Basic company record
        row = await conn.fetchrow(
            """
            SELECT entity_id, canonical_name, jurisdiction_code,
                   registration_number, status, incorporation_date,
                   dissolution_date, company_type, is_inactive
            FROM banxe_compliance.kyb_entities
            WHERE entity_id = $1::uuid
            """,
            entity_id,
        )
        if row is None:
            raise HTTPException(404, f"Entity {entity_id} not found")

        # Officers
        officers = await conn.fetch(
            """
            SELECT full_name, position, appointed_on, resigned_on,
                   nationality, sanctions_hit, pep_hit
            FROM banxe_compliance.kyb_officers
            WHERE entity_id = $1::uuid
            ORDER BY resigned_on NULLS FIRST, appointed_on DESC
            """,
            entity_id,
        )

    finally:
        await conn.close()

    officer_list = [dict(o) for o in officers]

    # sanctioned_or_pep: true if any active officer/UBO has a hit
    sanctioned_or_pep = any(
        o.get("sanctions_hit") or o.get("pep_hit")
        for o in officer_list
        if o.get("resigned_on") is None
    )

    return {
        "entity_id":           str(row["entity_id"]),
        "canonical_name":      row["canonical_name"],
        "jurisdiction_code":   row["jurisdiction_code"],
        "registration_number": row["registration_number"],
        "status":              row["status"],
        "incorporation_date":  str(row["incorporation_date"]) if row["incorporation_date"] else None,
        "dissolution_date":    str(row["dissolution_date"])   if row["dissolution_date"]   else None,
        "company_type":        row["company_type"],
        "is_inactive":         row["is_inactive"],
        "officers":            officer_list,
        "sanctioned_or_pep":   sanctioned_or_pep,
    }


@app.get("/api/v1/report/{report_id}")
async def get_report(report_id: str):
    """Retrieve a screening report by ID (filename stem)."""
    matches = glob.glob(os.path.join(LOGS_DIR, f"*{report_id}*"))
    if not matches:
        raise HTTPException(404, f"Report {report_id} not found")
    with open(matches[0]) as f:
        return json.load(f)


@app.get("/api/v1/history/{entity_name}")
async def entity_history(entity_name: str, limit: int = 20):
    """Screening history for an entity from ClickHouse."""
    rows = await get_screening_history(entity_name, limit)
    return {"entity": entity_name, "count": len(rows), "history": rows}


@app.get("/api/v1/stats")
async def compliance_stats():
    """Aggregate compliance statistics from ClickHouse."""
    return await get_stats()


# ── EU AI Act Art. 14 — Emergency Stop admin panel ───────────────────────────

_PANEL_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "emergency_panel.html")


@app.get("/compliance/admin/emergency", response_class=HTMLResponse, include_in_schema=False)
async def emergency_panel():
    """
    MLRO admin panel for emergency stop (EU AI Act Art. 14).

    Served as a static HTML page — no JS framework, no build step.
    Access: http://<gmktec>:8090/compliance/admin/emergency
    Bookmark this URL in Marble (or pin as a Marble case action link).

    Features:
    - Live status polling (15s interval)
    - Activate stop: operator_id + reason
    - Resume: mlro_id + resume_reason (MLRO authority)
    - Visual indicator: green (running) / red pulsing (suspended)
    """
    try:
        with open(_PANEL_PATH) as f:
            html = f.read()
    except FileNotFoundError:
        raise HTTPException(500, "Emergency panel HTML not found")
    return HTMLResponse(content=html)


# ── EU AI Act Art. 14 — Emergency Stop endpoints ─────────────────────────────

@app.post("/api/v1/compliance/emergency-stop")
async def emergency_stop(req: EmergencyStopRequest):
    """
    Activate emergency stop: suspend all automated compliance screening.

    EU AI Act Art. 14 — human oversight.  While active, all screening endpoints
    return HTTP 503 and require manual MLRO review.

    operator_id: identity of the person activating the stop (required for audit).
    reason:      mandatory explanation (logged to CRITICAL, stored in Redis + file).
    scope:       "all" (default) — Phase 2 will support per-engine scope.
    """
    if not req.operator_id.strip():
        raise HTTPException(400, "operator_id is required")
    if not req.reason.strip():
        raise HTTPException(400, "reason is required")

    state = await activate_stop(
        operator_id=req.operator_id.strip(),
        reason=req.reason.strip(),
        scope=req.scope.strip() or "all",
    )
    return {
        "status":       "stop_activated",
        "activated_at": state["activated_at"],
        "operator_id":  state["operator_id"],
        "scope":        state["scope"],
        "message":      (
            "All automated compliance screening is now suspended. "
            "Manual MLRO review required for all decisions. "
            "Resume via POST /api/v1/compliance/emergency-resume (MLRO authority)."
        ),
    }


@app.post("/api/v1/compliance/emergency-resume")
async def emergency_resume(req: EmergencyResumeRequest):
    """
    Clear emergency stop: resume automated compliance screening.

    Requires MLRO authority (mlro_id must be provided).
    Previous stop state is returned for audit purposes.
    """
    if not req.mlro_id.strip():
        raise HTTPException(400, "mlro_id is required")
    if not req.resume_reason.strip():
        raise HTTPException(400, "resume_reason is required")

    current = await get_stop_state()
    if not current.get("active"):
        return {
            "status":  "not_stopped",
            "message": "No active emergency stop — system is already running.",
        }

    prev = await clear_stop(
        mlro_id=req.mlro_id.strip(),
        resume_reason=req.resume_reason.strip(),
    )
    return {
        "status":           "resumed",
        "resumed_at":       datetime.now(timezone.utc).isoformat(),
        "mlro_id":          req.mlro_id.strip(),
        "resume_reason":    req.resume_reason.strip(),
        "previous_stop":    {
            "activated_at": prev.get("activated_at"),
            "operator_id":  prev.get("operator_id"),
            "reason":       prev.get("reason"),
            "scope":        prev.get("scope"),
        },
        "message": "Automated compliance screening resumed.",
    }


@app.get("/api/v1/compliance/emergency-stop/status")
async def emergency_stop_status():
    """
    Current emergency stop state.  Safe to poll — read-only, no side effects.
    Returns active=false when system is running normally.
    """
    state = await get_stop_state()
    return {
        "active":        state.get("active", False),
        "activated_at":  state.get("activated_at"),
        "operator_id":   state.get("operator_id"),
        "reason":        state.get("reason"),
        "scope":         state.get("scope"),
        "screening_suspended": state.get("active", False),
    }


@app.get("/api/v1/health")
async def health():
    """Health check: Watchman, Jube, Postgres, Redis, ClickHouse."""
    checks = {}
    async with httpx.AsyncClient(timeout=3) as client:
        # Yente (OpenSanctions) — Phase 3, ADR-009
        try:
            r = await client.get("http://127.0.0.1:8086/")
            checks["yente"] = "ok" if r.status_code == 200 else f"http_{r.status_code}"
        except Exception as e:
            checks["yente"] = f"error: {e}"

        # Watchman (fallback sanctions source)
        try:
            r = await client.get("http://127.0.0.1:8084/v2/search", params={"name": "test", "limit": 1})
            checks["watchman"] = "ok" if r.status_code == 200 else f"http_{r.status_code}"
        except Exception as e:
            checks["watchman"] = f"error: {e}"

        # Jube
        try:
            r = await client.get("http://127.0.0.1:5001/")
            checks["jube"] = "ok" if r.status_code in (200, 302) else f"http_{r.status_code}"
        except Exception as e:
            checks["jube"] = f"error: {e}"

        # ClickHouse
        try:
            r = await client.get("http://127.0.0.1:8123/ping")
            checks["clickhouse"] = "ok" if r.text.strip() == "Ok." else "error"
        except Exception as e:
            checks["clickhouse"] = f"error: {e}"

    # Postgres
    try:
        import asyncpg
        conn = await asyncpg.connect("postgresql://banxe:banxe_secure_2026@127.0.0.1:5432/banxe_compliance",
                                     timeout=3)
        await conn.close()
        checks["postgres"] = "ok"
    except Exception as e:
        checks["postgres"] = f"error: {e}"

    # Redis
    try:
        import redis.asyncio as aioredis
        r = aioredis.from_url("redis://127.0.0.1:6379")
        await r.ping()
        await r.aclose()
        checks["redis"] = "ok"
    except Exception as e:
        checks["redis"] = f"error: {e}"

    all_ok = all(v == "ok" for v in checks.values())
    return {
        "status": "healthy" if all_ok else "degraded",
        "checks": checks,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "version": "1.0.0",
    }


@app.get("/")
async def root():
    return {"service": "Banxe Collective LexisNexis", "docs": "/docs", "health": "/api/v1/health"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8090, log_level="info")
