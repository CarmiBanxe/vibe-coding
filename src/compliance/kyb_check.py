#!/data/banxe/compliance-env/bin/python3
"""
KYB Check — Phase 15
Unified KYB: Companies House (UK) + OpenCorporates (global).
Both map to UnifiedKYBEntity. Raw JSON saved in kyb_entity_sources.

Auth:
  CH  — Basic auth: API key as username, empty password
  OC  — Header: X-Api-Token or ?api_token=... query param

Env vars:
  COMPANIES_HOUSE_API_KEY   → set in /data/banxe/.env
  OPENCORPORATES_API_KEY    → set in /data/banxe/.env
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Optional

import httpx

# ── Config ────────────────────────────────────────────────────────────────────

CH_BASE   = "https://api.company-information.service.gov.uk"
OC_BASE   = "https://api.opencorporates.com/v0.4"

CH_KEY    = os.getenv("COMPANIES_HOUSE_API_KEY", "")
OC_TOKEN  = os.getenv("OPENCORPORATES_API_KEY", "")

TIMEOUT   = 15


# ── Unified data model ────────────────────────────────────────────────────────

@dataclass
class KYBOfficer:
    full_name:    str
    position:     str
    appointed_on: Optional[str] = None
    resigned_on:  Optional[str] = None
    nationality:  Optional[str] = None
    source:       str = ""


@dataclass
class KYBBeneficialOwner:
    owner_name:          str
    owner_type:          str
    control_nature:      list = field(default_factory=list)
    ownership_percentage: Optional[float] = None
    notified_on:         Optional[str] = None
    ceased_on:           Optional[str] = None
    source:              str = ""


@dataclass
class UnifiedKYBEntity:
    # Identity
    canonical_name:      str
    jurisdiction_code:   str
    registration_number: str
    country_code:        str

    # Status
    status:              str = "unknown"
    raw_status:          str = ""
    incorporation_date:  Optional[str] = None
    dissolution_date:    Optional[str] = None
    company_type:        Optional[str] = None
    is_inactive:         bool = False

    # Addresses
    registered_address:  Optional[str] = None

    # People
    officers:            list = field(default_factory=list)  # [KYBOfficer]
    beneficial_owners:   list = field(default_factory=list)  # [KYBBeneficialOwner]
    previous_names:      list = field(default_factory=list)

    # Filings summary
    filing_count:        int = 0
    last_filing_date:    Optional[str] = None

    # Provenance
    sources:             list = field(default_factory=list)  # [{"system", "key", "url", "retrieved_at"}]

    # Risk signals
    high_risk_flags:     list = field(default_factory=list)
    high_risk_ubos:      list = field(default_factory=list)

    # Meta
    kyb_decision:        str = "PENDING"
    reason:              str = ""
    check_time_ms:       int = 0


# ── Companies House client ────────────────────────────────────────────────────

class CompaniesHouseClient:
    """
    UK Companies House Public Data API.
    Endpoints: /company/{number}, /officers, /persons-with-significant-control,
               /filing-history, search/companies
    Auth: Basic auth — API key as username, empty password.
    """

    def __init__(self):
        self._key = CH_KEY

    def _auth(self) -> tuple:
        return (self._key, "")

    async def search(self, name: str, limit: int = 5) -> list[dict]:
        if not self._key:
            return []
        async with httpx.AsyncClient(timeout=TIMEOUT) as c:
            try:
                r = await c.get(
                    f"{CH_BASE}/search/companies",
                    params={"q": name, "items_per_page": limit},
                    auth=self._auth(),
                )
                if r.status_code == 200:
                    return r.json().get("items", [])
            except Exception:
                pass
        return []

    async def get_company(self, number: str) -> Optional[dict]:
        if not self._key:
            return None
        async with httpx.AsyncClient(timeout=TIMEOUT) as c:
            try:
                r = await c.get(f"{CH_BASE}/company/{number}", auth=self._auth())
                if r.status_code == 200:
                    return r.json()
            except Exception:
                pass
        return None

    async def get_officers(self, number: str) -> list[dict]:
        if not self._key:
            return []
        async with httpx.AsyncClient(timeout=TIMEOUT) as c:
            try:
                r = await c.get(
                    f"{CH_BASE}/company/{number}/officers",
                    params={"items_per_page": 100},
                    auth=self._auth(),
                )
                if r.status_code == 200:
                    return r.json().get("items", [])
            except Exception:
                pass
        return []

    async def get_pscs(self, number: str) -> list[dict]:
        if not self._key:
            return []
        async with httpx.AsyncClient(timeout=TIMEOUT) as c:
            try:
                r = await c.get(
                    f"{CH_BASE}/company/{number}/persons-with-significant-control",
                    params={"items_per_page": 100},
                    auth=self._auth(),
                )
                if r.status_code == 200:
                    return r.json().get("items", [])
            except Exception:
                pass
        return []

    async def get_filings(self, number: str, limit: int = 20) -> list[dict]:
        if not self._key:
            return []
        async with httpx.AsyncClient(timeout=TIMEOUT) as c:
            try:
                r = await c.get(
                    f"{CH_BASE}/company/{number}/filing-history",
                    params={"items_per_page": limit},
                    auth=self._auth(),
                )
                if r.status_code == 200:
                    return r.json().get("items", [])
            except Exception:
                pass
        return []

    def map_to_unified(
        self,
        profile: dict,
        officers: list[dict],
        pscs: list[dict],
        filings: list[dict],
    ) -> UnifiedKYBEntity:
        number = profile.get("company_number", "")
        addr_obj = profile.get("registered_office_address", {})
        addr_parts = [
            addr_obj.get("address_line_1", ""),
            addr_obj.get("address_line_2", ""),
            addr_obj.get("locality", ""),
            addr_obj.get("postal_code", ""),
            addr_obj.get("country", ""),
        ]
        registered_address = ", ".join(p for p in addr_parts if p)

        mapped_officers = []
        for o in officers:
            name = o.get("name", "")
            if not name:
                continue
            mapped_officers.append(KYBOfficer(
                full_name=name,
                position=o.get("officer_role", ""),
                appointed_on=o.get("appointed_on"),
                resigned_on=o.get("resigned_on"),
                nationality=o.get("nationality"),
                source="companies_house",
            ))

        mapped_ubos = []
        for p in pscs:
            name = p.get("name", "")
            if not name:
                continue
            mapped_ubos.append(KYBBeneficialOwner(
                owner_name=name,
                owner_type=p.get("kind", "individual"),
                control_nature=p.get("natures_of_control", []),
                notified_on=p.get("notified_on"),
                ceased_on=p.get("ceased_on"),
                source="companies_house",
            ))

        status_raw = profile.get("company_status", "unknown")
        status_norm = {
            "active": "active",
            "dissolved": "dissolved",
            "liquidation": "liquidation",
            "receivership": "insolvency",
            "administration": "insolvency",
            "voluntary-arrangement": "insolvency",
        }.get(status_raw, "unknown")

        prev_names = [n.get("name", "") for n in profile.get("previous_company_names", []) if n.get("name")]

        filing_dates = [f.get("date") for f in filings if f.get("date")]
        last_filing  = max(filing_dates) if filing_dates else None

        return UnifiedKYBEntity(
            canonical_name=profile.get("company_name", ""),
            jurisdiction_code="gb",
            registration_number=number,
            country_code="GB",
            status=status_norm,
            raw_status=status_raw,
            incorporation_date=profile.get("date_of_creation"),
            dissolution_date=profile.get("date_of_cessation"),
            company_type=profile.get("type"),
            is_inactive=status_raw not in ("active",),
            registered_address=registered_address,
            officers=[asdict(o) for o in mapped_officers],
            beneficial_owners=[asdict(u) for u in mapped_ubos],
            previous_names=prev_names,
            filing_count=len(filings),
            last_filing_date=last_filing,
            sources=[{
                "system":       "companies_house",
                "key":          f"gb/{number}",
                "url":          f"https://find-and-update.company-information.service.gov.uk/company/{number}",
                "retrieved_at": datetime.now(timezone.utc).isoformat(),
                "raw_json":     profile,
            }],
        )


# ── OpenCorporates client ─────────────────────────────────────────────────────

class OpenCorporatesClient:
    """
    OpenCorporates REST API v0.4.
    Requires api_token (free tier: 50 req/day, open-data use).
    Endpoints: /companies/search, /companies/{jc}/{number}, /companies/{jc}/{number}/officers
    """

    def __init__(self):
        self._token = OC_TOKEN

    def _params(self, extra: dict = None) -> dict:
        p = {}
        if self._token:
            p["api_token"] = self._token
        if extra:
            p.update(extra)
        return p

    async def search(self, name: str, jurisdiction_code: str = "", limit: int = 5) -> list[dict]:
        if not self._token:
            return []
        params = self._params({
            "q":                name,
            "per_page":         limit,
            "inactive":         "false",
        })
        if jurisdiction_code:
            params["jurisdiction_code"] = jurisdiction_code.lower()
        async with httpx.AsyncClient(timeout=TIMEOUT) as c:
            try:
                r = await c.get(f"{OC_BASE}/companies/search", params=params)
                if r.status_code == 200:
                    companies = r.json().get("results", {}).get("companies", [])
                    return [item.get("company", {}) for item in companies if item.get("company")]
            except Exception:
                pass
        return []

    async def get_company(self, jurisdiction_code: str, number: str) -> Optional[dict]:
        if not self._token:
            return None
        jc = jurisdiction_code.lower()
        async with httpx.AsyncClient(timeout=TIMEOUT) as c:
            try:
                r = await c.get(
                    f"{OC_BASE}/companies/{jc}/{number}",
                    params=self._params(),
                )
                if r.status_code == 200:
                    return r.json().get("results", {}).get("company")
            except Exception:
                pass
        return None

    async def get_officers(self, jurisdiction_code: str, number: str) -> list[dict]:
        if not self._token:
            return []
        jc = jurisdiction_code.lower()
        async with httpx.AsyncClient(timeout=TIMEOUT) as c:
            try:
                r = await c.get(
                    f"{OC_BASE}/companies/{jc}/{number}/officers",
                    params=self._params({"per_page": 100}),
                )
                if r.status_code == 200:
                    officers = r.json().get("results", {}).get("officers", [])
                    return [o.get("officer", {}) for o in officers if o.get("officer")]
            except Exception:
                pass
        return []

    def map_to_unified(
        self,
        profile: dict,
        officers: list[dict],
    ) -> UnifiedKYBEntity:
        jc     = profile.get("jurisdiction_code", "")
        number = profile.get("company_number", "")

        addr = profile.get("registered_address", {}) or {}
        addr_parts = [
            addr.get("street_address", ""),
            addr.get("locality", ""),
            addr.get("region", ""),
            addr.get("postal_code", ""),
            addr.get("country", ""),
        ]
        registered_address = ", ".join(p for p in addr_parts if p)

        mapped_officers = []
        for o in officers:
            name = o.get("name", "") or o.get("officer_name", "")
            if not name:
                continue
            mapped_officers.append(KYBOfficer(
                full_name=name,
                position=o.get("position", "") or o.get("role", ""),
                appointed_on=o.get("start_date"),
                resigned_on=o.get("end_date"),
                nationality=o.get("nationality"),
                source="opencorporates",
            ))

        status_raw  = profile.get("current_status", "unknown") or "unknown"
        status_norm = {
            "active":     "active",
            "dissolved":  "dissolved",
            "inactive":   "dissolved",
            "liquidation": "liquidation",
        }.get(status_raw.lower(), "unknown")

        prev_names = []
        for pn in profile.get("previous_names", []) or []:
            n = pn.get("company_name") or pn.get("name") or ""
            if n:
                prev_names.append(n)

        return UnifiedKYBEntity(
            canonical_name=profile.get("name", ""),
            jurisdiction_code=jc,
            registration_number=number,
            country_code=(jc[:2].upper() if jc else ""),
            status=status_norm,
            raw_status=status_raw,
            incorporation_date=profile.get("incorporation_date"),
            dissolution_date=profile.get("dissolution_date"),
            company_type=profile.get("company_type"),
            is_inactive=status_norm != "active",
            registered_address=registered_address,
            officers=[asdict(o) for o in mapped_officers],
            beneficial_owners=[],       # OC free tier doesn't expose UBO
            previous_names=prev_names,
            sources=[{
                "system":       "opencorporates",
                "key":          f"{jc}/{number}",
                "url":          profile.get("opencorporates_url", ""),
                "retrieved_at": datetime.now(timezone.utc).isoformat(),
                "raw_json":     profile,
            }],
        )


# ── Unified builder + risk scorer ─────────────────────────────────────────────

class UnifiedKYBBuilder:
    """
    Merges CH + OC results into a single UnifiedKYBEntity.
    Primary: CH (authoritative for UK). OC enriches for non-UK.
    """

    # High-risk filing codes / statuses
    HR_FILING_CODES = {
        "GAZ2",   # compulsory strike-off
        "DISS40", # dissolution
        "AM22",   # winding-up petition
        "AM23",   # winding-up order
        "LIQ01",  # winding-up
        "LIQ02",
        "INS01",  # insolvency
    }

    def merge(self, ch: Optional[UnifiedKYBEntity], oc: Optional[UnifiedKYBEntity]) -> UnifiedKYBEntity:
        """CH is primary. OC supplements missing fields."""
        if ch is None and oc is None:
            raise ValueError("both CH and OC returned None")

        primary   = ch or oc
        secondary = oc if ch else None

        if secondary:
            # Enrich previous_names
            for name in secondary.previous_names:
                if name not in primary.previous_names:
                    primary.previous_names.append(name)
            # Union officers — deduplicate by (full_name, position)
            existing_keys = {
                (o["full_name"], o.get("position", ""))
                for o in primary.officers
            }
            for o in secondary.officers:
                key = (o["full_name"], o.get("position", ""))
                if key not in existing_keys:
                    primary.officers.append(o)
                    existing_keys.add(key)
            # Merge sources
            primary.sources.extend(secondary.sources)

        return primary

    def score(
        self,
        entity: UnifiedKYBEntity,
        officer_sanctions_results: list[dict],  # [{name, sanctioned, pep_hit}]
    ) -> UnifiedKYBEntity:
        flags = []

        # Dissolved / inactive
        if entity.status in ("dissolved", "liquidation", "insolvency"):
            flags.append(f"Company status: {entity.status}")
            entity.kyb_decision = "HOLD"

        # No UBOs (opaque ownership)
        if not entity.beneficial_owners:
            flags.append("No PSC/UBO data — possible opaque ownership structure")

        # Sanctioned / PEP officers or UBOs
        high_risk_people = []
        for r in officer_sanctions_results:
            if r.get("sanctioned") or r.get("pep_hit"):
                tag = []
                if r.get("sanctioned"):
                    tag.append("SANCTIONS")
                if r.get("pep_hit"):
                    tag.append("PEP")
                label = f"{r['name']} ({'+'.join(tag)})"
                high_risk_people.append(label)
                flags.append(f"High-risk individual: {label}")

        entity.high_risk_ubos   = high_risk_people
        entity.high_risk_flags  = flags

        if high_risk_people:
            entity.kyb_decision = "REJECT"
            entity.reason = f"High-risk UBO/officer: {high_risk_people[0]}"
        elif flags:
            if entity.kyb_decision != "REJECT":
                entity.kyb_decision = "HOLD"
            entity.reason = flags[0]
        else:
            entity.kyb_decision = "APPROVE"
            entity.reason = "No adverse signals"

        return entity


# ── Top-level check_company ───────────────────────────────────────────────────

async def check_company(
    name: str,
    jurisdiction: str = "GB",
    number: Optional[str] = None,
) -> dict:
    """
    Unified KYB entry point.
    1. Companies House (if GB or explicit number)
    2. OpenCorporates (global fallback/enrichment)
    3. Screen active officers + UBOs via sanctions/PEP
    4. Return unified dict

    Returns dict compatible with api.py screen_company expectations.
    """
    t0 = time.time()
    ch_client = CompaniesHouseClient()
    oc_client = OpenCorporatesClient()
    builder   = UnifiedKYBBuilder()

    ch_entity: Optional[UnifiedKYBEntity] = None
    oc_entity: Optional[UnifiedKYBEntity] = None

    # ── Companies House ───────────────────────────────────────────────────────
    if CH_KEY and jurisdiction.upper() in ("GB", "UK"):
        try:
            if number:
                profile = await ch_client.get_company(number)
            else:
                results = await ch_client.search(name, limit=3)
                profile = results[0] if results else None

            if profile:
                comp_num = profile.get("company_number", number or "")
                officers, pscs, filings = await asyncio.gather(
                    ch_client.get_officers(comp_num),
                    ch_client.get_pscs(comp_num),
                    ch_client.get_filings(comp_num, limit=20),
                )
                ch_entity = ch_client.map_to_unified(profile, officers, pscs, filings)
        except Exception:
            pass

    # ── OpenCorporates ────────────────────────────────────────────────────────
    if OC_TOKEN:
        try:
            jc = jurisdiction.lower() if jurisdiction.lower() != "uk" else "gb"
            if number and ch_entity:
                pass  # CH is sufficient for GB
            else:
                oc_results = await oc_client.search(name, jurisdiction_code=jc, limit=3)
                if oc_results:
                    best = oc_results[0]
                    best_jc  = best.get("jurisdiction_code", jc)
                    best_num = best.get("company_number", "")
                    if best_num:
                        oc_profile  = await oc_client.get_company(best_jc, best_num)
                        oc_officers = await oc_client.get_officers(best_jc, best_num)
                        if oc_profile:
                            oc_entity = oc_client.map_to_unified(oc_profile, oc_officers)
        except Exception:
            pass

    # ── Pending (no keys) ─────────────────────────────────────────────────────
    if ch_entity is None and oc_entity is None:
        missing = []
        if not CH_KEY and jurisdiction.upper() in ("GB", "UK"):
            missing.append("COMPANIES_HOUSE_API_KEY")
        if not OC_TOKEN:
            missing.append("OPENCORPORATES_API_KEY")
        return {
            "status":       "pending",
            "kyb_decision": "HOLD",
            "reason":       f"Missing API keys: {', '.join(missing)}. Set in /data/banxe/.env",
            "entity_name":  name,
            "jurisdiction": jurisdiction,
        }

    # ── Merge ─────────────────────────────────────────────────────────────────
    entity = builder.merge(ch_entity, oc_entity)

    # ── Screen active officers + UBOs against sanctions/PEP ──────────────────
    people_to_screen = []
    for o in entity.officers:
        if not o.get("resigned_on"):
            people_to_screen.append(o["full_name"])
    for u in entity.beneficial_owners:
        if not u.get("ceased_on"):
            people_to_screen.append(u["owner_name"])

    officer_results = []
    if people_to_screen:
        try:
            from sanctions_check import check_sanctions
            from pep_check import check_pep
            import asyncio as _asyncio
            loop = _asyncio.get_event_loop()

            tasks = [check_sanctions(p) for p in people_to_screen]
            sanctions_results = await _asyncio.gather(*tasks, return_exceptions=True)

            pep_results = await _asyncio.gather(
                *[loop.run_in_executor(None, check_pep, p) for p in people_to_screen],
                return_exceptions=True,
            )

            for i, person in enumerate(people_to_screen):
                sr = sanctions_results[i] if not isinstance(sanctions_results[i], Exception) else {}
                pr = pep_results[i]       if not isinstance(pep_results[i], Exception) else {}
                officer_results.append({
                    "name":      person,
                    "sanctioned": sr.get("sanctioned", False),
                    "pep_hit":    pr.get("hit", False),
                })
        except Exception:
            pass

    entity = builder.score(entity, officer_results)
    entity.check_time_ms = int((time.time() - t0) * 1000)

    # ── Serialise ─────────────────────────────────────────────────────────────
    result = asdict(entity)
    result["ubo_checks"] = officer_results
    # Strip raw_json from sources (large, keep provenance metadata only)
    for src in result.get("sources", []):
        src.pop("raw_json", None)

    return result


# ── Standalone test ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    async def test():
        print("=" * 60)
        print("  KYB CHECK — Companies House + OpenCorporates")
        print("=" * 60)
        print(f"  CH key: {'SET' if CH_KEY else 'NOT SET'}")
        print(f"  OC key: {'SET' if OC_TOKEN else 'NOT SET'}")

        companies = [
            ("Revolut Ltd",  "GB", "08804411"),
            ("HSBC Holdings", "GB", None),
        ]
        for name, jc, num in companies:
            print(f"\n[{name} / {jc}]")
            r = await check_company(name, jc, num)
            print(f"  decision: {r.get('kyb_decision')}")
            print(f"  status:   {r.get('status')}")
            print(f"  officers: {len(r.get('officers', []))}")
            print(f"  UBOs:     {len(r.get('beneficial_owners', []))}")
            print(f"  flags:    {r.get('high_risk_flags', [])[:2]}")
            if r.get('reason'):
                print(f"  reason:   {r.get('reason')}")

    asyncio.run(test())
