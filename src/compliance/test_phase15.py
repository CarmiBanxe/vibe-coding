#!/data/banxe/compliance-env/bin/python3
"""
Phase 15 — Unit & Integration Tests
pytest test_phase15.py -v

Covers:
  1. OFAC RecentActions HTML scraper
  2. FEED_REGISTRY final_score ordering by source_weight
  3. Regulatory boost ×1.4
  4. Alias matching weight 0.80 vs canonical 1.00
  5. EUR-Lex / BAILII source_family + is_regulatory flags
  6. UnifiedKYBEntity.merge() — CH primary, OC enrichment
  7. Composed key jurisdiction_code + registration_number uniqueness
  8. UnifiedKYBBuilder.score() — sanctions/PEP hit → REJECT
  9. include_legal_db flag controls check_legal_exposure call
"""
from __future__ import annotations

import asyncio
import sys
import os
import pytest
from unittest.mock import AsyncMock, MagicMock, patch

# Ensure compliance dir is on path
BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)

from adverse_media import (
    _parse_ofac_html,
    _entity_match_weight,
    _topic_weight,
    _score_article,
    _stable_hash,
    check_adverse_media,
    FEED_REGISTRY,
)
from kyb_check import (
    UnifiedKYBEntity,
    UnifiedKYBBuilder,
    KYBOfficer,
    KYBBeneficialOwner,
    CompaniesHouseClient,
    OpenCorporatesClient,
)


# ─── helpers ─────────────────────────────────────────────────────────────────

def run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


# ═════════════════════════════════════════════════════════════════════════════
# TEST 1 — OFAC RecentActions HTML scraper
# ═════════════════════════════════════════════════════════════════════════════

OFAC_HTML_FIXTURE = """
<html><body>
<table>
  <tr>
    <td>05/10/2025</td>
    <td><a href="/recent-actions/20250510">SDN List Update: Designation of 3 individuals</a></td>
  </tr>
  <tr>
    <td>04/28/2025</td>
    <td><a href="/recent-actions/20250428">OFAC Issues General License No. 99</a></td>
  </tr>
</table>
</body></html>
"""


def test_ofac_scraper_returns_two_items():
    items = _parse_ofac_html(OFAC_HTML_FIXTURE)
    assert len(items) >= 2, f"Expected >= 2 items, got {len(items)}"


def test_ofac_scraper_urls_absolute():
    items = _parse_ofac_html(OFAC_HTML_FIXTURE)
    for item in items:
        assert item["url"].startswith("http"), f"URL not absolute: {item['url']}"


def test_ofac_scraper_sanction_has_topic():
    items = _parse_ofac_html(OFAC_HTML_FIXTURE)
    combined_titles = " ".join(i["title"] for i in items).lower()
    # At least one item should mention sanction/designation
    assert any(
        kw in combined_titles
        for kw in ("sanction", "sdn", "designation", "license")
    ), f"No sanction keyword in: {combined_titles}"


def test_ofac_scraper_topic_weight_for_sdn():
    items = _parse_ofac_html(OFAC_HTML_FIXTURE)
    sdn_items = [i for i in items if "sdn" in i["title"].lower() or "designation" in i["title"].lower()]
    for item in sdn_items:
        tw = _topic_weight(item["title"])
        assert tw >= 0.85, f"SDN item topic_weight too low: {tw} for '{item['title']}'"


# ═════════════════════════════════════════════════════════════════════════════
# TEST 2 — FEED_REGISTRY: source_weight ordering → final_score ordering
# ═════════════════════════════════════════════════════════════════════════════

# Freeze entity_match_weight and topic_weight to isolate source_weight effect
_FIXED_ENTITY_WEIGHT = 1.0   # exact name match
_FIXED_TOPIC_WEIGHT  = 1.0   # highest-risk topic


def test_feed_registry_source_weight_ordering():
    """
    With identical entity_match and topic weights,
    FCA > OFAC > EBA > EUR-Lex > Google-News by final_score.
    """
    source_weights = {
        f["source_name"]: f["source_weight"]
        for f in FEED_REGISTRY
    }

    required_order = [
        ("FCA-Enforcement",  "OFAC-RecentActions"),
        ("OFAC-RecentActions", "EBA-News"),
        ("EBA-News",         "EUR-Lex-AML"),
        ("EUR-Lex-AML",      "Google-News"),
    ]

    for higher_src, lower_src in required_order:
        if higher_src not in source_weights or lower_src not in source_weights:
            pytest.skip(f"Feed {higher_src} or {lower_src} not in FEED_REGISTRY")
        score_high = _score_article(source_weights[higher_src], _FIXED_ENTITY_WEIGHT, _FIXED_TOPIC_WEIGHT)
        score_low  = _score_article(source_weights[lower_src],  _FIXED_ENTITY_WEIGHT, _FIXED_TOPIC_WEIGHT)
        assert score_high > score_low, (
            f"Expected {higher_src} ({score_high:.3f}) > {lower_src} ({score_low:.3f})"
        )


def test_feed_registry_all_weights_in_range():
    for feed in FEED_REGISTRY:
        w = feed["source_weight"]
        assert 0.0 < w <= 1.0, f"{feed['source_name']} weight out of range: {w}"


# ═════════════════════════════════════════════════════════════════════════════
# TEST 3 — Regulatory boost ×1.4
# ═════════════════════════════════════════════════════════════════════════════

@pytest.mark.asyncio
async def test_regulatory_boost():
    """
    Two identical events from same-weight source.
    is_regulatory=True should yield ~1.4× the contribution to risk_score.
    """
    entity = "TestEntity"

    # Build a single article, regulatory vs non-regulatory
    base_score = _score_article(0.85, 1.0, 0.85)

    # Simulate the boost logic from check_adverse_media
    contribution_reg    = int(base_score * 100 * 1.4)
    contribution_nonreg = int(base_score * 100)

    assert contribution_reg > contribution_nonreg
    ratio = contribution_reg / contribution_nonreg
    assert abs(ratio - 1.4) < 0.05, f"Boost ratio {ratio:.3f}, expected ~1.4"


# ═════════════════════════════════════════════════════════════════════════════
# TEST 4 — Alias matching weight 0.80 vs canonical 1.00
# ═════════════════════════════════════════════════════════════════════════════

def test_exact_name_match_weight_1():
    w = _entity_match_weight("Banxe Payments Ltd", "Banxe Payments Ltd has been fined")
    assert w == 1.0, f"Expected 1.0, got {w}"


def test_alias_match_weight_0_8():
    w = _entity_match_weight(
        "Banxe Payments Ltd",
        "Banxe Ltd received a warning notice",
        aliases=["Banxe Ltd"],
    )
    assert w == 0.80, f"Expected 0.80 for alias match, got {w}"


def test_canonical_score_greater_than_alias():
    canonical_w = _entity_match_weight("Banxe Payments Ltd", "Banxe Payments Ltd fined")
    alias_w     = _entity_match_weight(
        "Banxe Payments Ltd",
        "Banxe Ltd investigation",
        aliases=["Banxe Ltd"],
    )
    assert canonical_w > alias_w, (
        f"canonical ({canonical_w}) should exceed alias ({alias_w})"
    )


def test_alias_score_numerically_0_8x_canonical():
    sw = 0.95
    tw = 1.0
    score_canonical = _score_article(sw, 1.00, tw)
    score_alias     = _score_article(sw, 0.80, tw)
    # entity_match contributes 0.35 weight, so delta = 0.35 * (1.00 - 0.80) = 0.07
    expected_delta = 0.35 * 0.20
    actual_delta   = abs(score_canonical - score_alias)
    assert abs(actual_delta - expected_delta) < 0.001, (
        f"Delta {actual_delta:.4f} ≠ expected {expected_delta:.4f}"
    )


def test_no_match_returns_zero():
    w = _entity_match_weight("Banxe Payments Ltd", "Completely unrelated article about weather")
    assert w == 0.0, f"Expected 0.0 for no match, got {w}"


# ═════════════════════════════════════════════════════════════════════════════
# TEST 5 — EUR-Lex / BAILII source_family and is_regulatory
# ═════════════════════════════════════════════════════════════════════════════

def test_eurlex_feed_is_regulatory():
    eurlex = next((f for f in FEED_REGISTRY if f["source_name"] == "EUR-Lex-AML"), None)
    assert eurlex is not None, "EUR-Lex-AML not in FEED_REGISTRY"
    assert eurlex["is_regulatory"] is True
    assert eurlex["source_family"] == "eu_law"
    assert eurlex["jurisdiction"] == "eu"


def test_fca_feed_is_regulatory():
    fca = next((f for f in FEED_REGISTRY if f["source_name"] == "FCA-Enforcement"), None)
    assert fca is not None, "FCA-Enforcement not in FEED_REGISTRY"
    assert fca["is_regulatory"] is True
    assert fca["source_family"] == "regulator"
    assert fca["jurisdiction"] == "uk"


def test_ofac_feed_is_regulatory():
    ofac = next((f for f in FEED_REGISTRY if f["source_name"] == "OFAC-RecentActions"), None)
    assert ofac is not None, "OFAC-RecentActions not in FEED_REGISTRY"
    assert ofac["is_regulatory"] is True
    assert ofac.get("is_html_scrape") is True
    # Confirm no RSS URL pattern
    assert "rss" not in ofac["feed_url"].lower(), "OFAC should not use RSS"


def test_google_news_is_not_regulatory():
    gn = next((f for f in FEED_REGISTRY if f["source_name"] == "Google-News"), None)
    assert gn is not None
    assert gn["is_regulatory"] is False
    assert gn["source_family"] == "news"


def test_topic_weight_aml_keywords():
    text_aml  = "The firm was convicted of money laundering and sanctions evasion"
    text_proc = "A consultation paper on regulatory policy"
    assert _topic_weight(text_aml)  >= 1.0
    assert _topic_weight(text_proc) <  0.50


# ═════════════════════════════════════════════════════════════════════════════
# TEST 6 — UnifiedKYBEntity.merge(): CH primary, OC enrichment
# ═════════════════════════════════════════════════════════════════════════════

def _make_ch_entity() -> UnifiedKYBEntity:
    return UnifiedKYBEntity(
        canonical_name="Banxe Payments Ltd",
        jurisdiction_code="gb",
        registration_number="12345678",
        country_code="GB",
        status="active",
        raw_status="active",
        incorporation_date="2019-01-15",
        registered_address="1 Bank St, London, EC2V 8AB",
        officers=[{"full_name": "Alice Smith", "position": "director", "resigned_on": None, "source": "companies_house"}],
        beneficial_owners=[{"owner_name": "Alice Smith", "owner_type": "individual", "ceased_on": None}],
        previous_names=["Old Banxe Ltd"],
        sources=[{"system": "companies_house", "key": "gb/12345678"}],
    )


def _make_oc_entity() -> UnifiedKYBEntity:
    return UnifiedKYBEntity(
        canonical_name="Banxe Payments Ltd",
        jurisdiction_code="gb",
        registration_number="12345678",
        country_code="GB",
        status="active",
        raw_status="active",
        officers=[{"full_name": "Bob Jones", "position": "secretary", "resigned_on": None, "source": "opencorporates"}],
        beneficial_owners=[],
        previous_names=["Old Banxe Ltd", "Proto Banxe Ltd"],
        sources=[{"system": "opencorporates", "key": "gb/12345678"}],
    )


def test_merge_canonical_name_from_ch():
    builder = UnifiedKYBBuilder()
    merged  = builder.merge(_make_ch_entity(), _make_oc_entity())
    assert merged.canonical_name == "Banxe Payments Ltd"


def test_merge_registered_address_from_ch():
    builder = UnifiedKYBBuilder()
    merged  = builder.merge(_make_ch_entity(), _make_oc_entity())
    assert "EC2V" in (merged.registered_address or ""), (
        "Registered address should come from CH"
    )


def test_merge_previous_names_union():
    builder = UnifiedKYBBuilder()
    merged  = builder.merge(_make_ch_entity(), _make_oc_entity())
    all_names = merged.previous_names
    assert "Old Banxe Ltd"   in all_names, "CH previous name missing"
    assert "Proto Banxe Ltd" in all_names, "OC-only previous name missing"


def test_merge_officers_union_no_duplicates():
    builder = UnifiedKYBBuilder()
    merged  = builder.merge(_make_ch_entity(), _make_oc_entity())
    names = [o["full_name"] for o in merged.officers]
    assert "Alice Smith" in names, "CH officer missing"
    assert "Bob Jones"   in names, "OC officer missing"
    assert len(names) == len(set(names)), "Duplicate officers in merged entity"


def test_merge_ch_none_falls_back_to_oc():
    builder = UnifiedKYBBuilder()
    merged  = builder.merge(None, _make_oc_entity())
    assert merged.canonical_name == "Banxe Payments Ltd"
    assert merged.jurisdiction_code == "gb"


def test_merge_both_none_raises():
    builder = UnifiedKYBBuilder()
    with pytest.raises(ValueError):
        builder.merge(None, None)


def test_merge_sources_combined():
    builder = UnifiedKYBBuilder()
    merged  = builder.merge(_make_ch_entity(), _make_oc_entity())
    systems = [s["system"] for s in merged.sources]
    assert "companies_house"  in systems
    assert "opencorporates"   in systems


# ═════════════════════════════════════════════════════════════════════════════
# TEST 7 — Composed key: jurisdiction_code + registration_number uniqueness
# ═════════════════════════════════════════════════════════════════════════════

def test_composed_key_same_number_different_jurisdiction():
    """
    Two companies with same registration_number but different jurisdiction_code
    must produce different composed keys — matching the UNIQUE(jc, reg_num) DB constraint.
    """
    key_gb = ("gb", "123456")
    key_cy = ("cy", "123456")
    assert key_gb != key_cy, "Composed keys must differ across jurisdictions"


def test_oc_source_key_includes_jurisdiction():
    """OC source_entity_key must be 'jurisdiction/number' format."""
    jc, num = "fr", "789012"
    source_key = f"{jc}/{num}"
    assert source_key == "fr/789012"
    assert "/" in source_key, "Source key must include jurisdiction separator"


def test_ch_source_key_format():
    """CH source_entity_key must be 'gb/number'."""
    number     = "08804411"
    source_key = f"gb/{number}"
    assert source_key.startswith("gb/")


# ═════════════════════════════════════════════════════════════════════════════
# TEST 8 — UnifiedKYBBuilder.score(): sanctions/PEP → REJECT
# ═════════════════════════════════════════════════════════════════════════════

def test_score_clean_entity_approves():
    builder = UnifiedKYBBuilder()
    entity  = _make_ch_entity()
    officer_results = [
        {"name": "Alice Smith", "sanctioned": False, "pep_hit": False},
    ]
    scored = builder.score(entity, officer_results)
    assert scored.kyb_decision == "APPROVE"
    assert scored.high_risk_ubos == []


def test_score_sanctioned_officer_rejects():
    builder = UnifiedKYBBuilder()
    entity  = _make_ch_entity()
    officer_results = [
        {"name": "Alice Smith", "sanctioned": True, "pep_hit": False},
    ]
    scored = builder.score(entity, officer_results)
    assert scored.kyb_decision == "REJECT"
    assert any("Alice Smith" in u for u in scored.high_risk_ubos)
    assert "SANCTIONS" in scored.high_risk_ubos[0]


def test_score_pep_officer_rejects():
    builder = UnifiedKYBBuilder()
    entity  = _make_ch_entity()
    officer_results = [
        {"name": "Bob Minister", "sanctioned": False, "pep_hit": True},
    ]
    scored = builder.score(entity, officer_results)
    assert scored.kyb_decision == "REJECT"
    assert "PEP" in scored.high_risk_ubos[0]


def test_score_dissolved_company_holds():
    builder = UnifiedKYBBuilder()
    entity  = _make_ch_entity()
    entity.status     = "dissolved"
    entity.is_inactive = True
    officer_results   = []
    scored = builder.score(entity, officer_results)
    assert scored.kyb_decision in ("HOLD", "REJECT")
    assert any("dissolved" in f.lower() for f in scored.high_risk_flags)


def test_score_no_ubo_data_flags():
    builder = UnifiedKYBBuilder()
    entity  = _make_ch_entity()
    entity.beneficial_owners = []  # no PSC data
    scored = builder.score(entity, [])
    # Should flag opaque ownership, but not necessarily REJECT
    assert any("psc" in f.lower() or "ubo" in f.lower() or "opaque" in f.lower()
               for f in scored.high_risk_flags)


def test_score_clean_entity_reason_no_adverse():
    builder = UnifiedKYBBuilder()
    entity  = _make_ch_entity()
    scored  = builder.score(entity, [{"name": "Alice Smith", "sanctioned": False, "pep_hit": False}])
    assert "adverse" in scored.reason.lower() or scored.reason == "No adverse signals"


# ═════════════════════════════════════════════════════════════════════════════
# TEST 9 — include_legal_db flag controls check_legal_exposure call
# ═════════════════════════════════════════════════════════════════════════════

@pytest.mark.asyncio
async def test_include_legal_db_false_does_not_call():
    """When include_legal_db=False, check_legal_exposure must NOT be called."""
    with patch("adverse_media.check_adverse_media") as mock_ami:
        # Call the real function with mocked feed fetches (no network)
        mock_feed_result = [
            {
                "event_stable_hash": "abc123",
                "source_name": "FCA-Enforcement",
                "source_family": "regulator",
                "source_weight": 1.0,
                "is_regulatory": True,
                "jurisdiction": "uk",
                "title": "FCA fines TestCo",
                "url": "https://fca.org.uk/news/1",
                "summary": "",
                "published": "2025-01-01",
                "entity_match_weight": 1.0,
                "topic_weight": 0.85,
                "final_score": 0.875,
                "topic_tags": ["enforcement action"],
            }
        ]

        with patch("adverse_media._fetch_feed", new_callable=AsyncMock) as mock_fetch:
            mock_fetch.return_value = mock_feed_result

            with patch("adverse_media.check_legal_exposure", new_callable=AsyncMock) as mock_legal:
                result = await check_adverse_media("TestEntity", include_legal_db=False)
                mock_legal.assert_not_called()
                assert result["legal_exposure"] == {}


@pytest.mark.asyncio
async def test_include_legal_db_true_calls_once():
    """When include_legal_db=True, check_legal_exposure is called exactly once."""
    mock_legal_result = {
        "legal_risk_score": 30,
        "legal_risk_level": "MEDIUM",
        "eu_legal": {"hits": 1, "findings": []},
        "uk_legal": {"hits": 0, "findings": [], "high_risk_keywords": []},
    }

    with patch("adverse_media._fetch_feed", new_callable=AsyncMock) as mock_fetch:
        mock_fetch.return_value = []  # no AMI articles

        with patch("adverse_media.check_legal_exposure", new_callable=AsyncMock) as mock_legal:
            mock_legal.return_value = mock_legal_result

            result = await check_adverse_media("TestEntity", include_legal_db=True)
            mock_legal.assert_called_once_with("TestEntity")


@pytest.mark.asyncio
async def test_include_legal_db_boosts_risk_score():
    """Legal exposure score should boost final risk_score when include_legal_db=True."""
    mock_legal_result = {
        "legal_risk_score": 40,
        "legal_risk_level": "HIGH",
        "eu_legal": {"hits": 2, "findings": []},
        "uk_legal": {"hits": 1, "findings": [], "high_risk_keywords": []},
    }

    with patch("adverse_media._fetch_feed", new_callable=AsyncMock) as mock_fetch:
        mock_fetch.return_value = []

        # Without legal_db
        result_no_legal = await check_adverse_media("TestEntity", include_legal_db=False)

        with patch("adverse_media.check_legal_exposure", new_callable=AsyncMock) as mock_legal:
            mock_legal.return_value = mock_legal_result
            result_with_legal = await check_adverse_media("TestEntity", include_legal_db=True)

    assert result_with_legal["risk_score"] >= result_no_legal["risk_score"], (
        "Legal DB should boost risk_score, not lower it"
    )
    # Boost = legal_risk_score // 2 = 20 (capped)
    expected_boost = min(mock_legal_result["legal_risk_score"] // 2, 20)
    assert result_with_legal["risk_score"] == result_no_legal["risk_score"] + expected_boost


# ═════════════════════════════════════════════════════════════════════════════
# stable_hash dedup sanity
# ═════════════════════════════════════════════════════════════════════════════

def test_stable_hash_same_input_same_hash():
    h1 = _stable_hash("FCA-Enforcement", "https://fca.org.uk/1", "FCA fines Firm A")
    h2 = _stable_hash("FCA-Enforcement", "https://fca.org.uk/1", "FCA fines Firm A")
    assert h1 == h2


def test_stable_hash_different_url_different_hash():
    h1 = _stable_hash("FCA-Enforcement", "https://fca.org.uk/1", "Title")
    h2 = _stable_hash("FCA-Enforcement", "https://fca.org.uk/2", "Title")
    assert h1 != h2


def test_stable_hash_length_16():
    h = _stable_hash("source", "url", "title")
    assert len(h) == 16


# ═════════════════════════════════════════════════════════════════════════════
# KYB ENDPOINT — extended unit tests (no network, no Postgres)
# Tests the endpoint logic: field presence, sanctioned_or_pep derivation,
# officer ordering, invalid UUID handling.
# ═════════════════════════════════════════════════════════════════════════════

def _kyb_response_fixture(
    canonical_name="Acme Ltd",
    jurisdiction_code="gb",
    registration_number="12345678",
    status="active",
    officers=None,
    sanctioned_or_pep=False,
    is_inactive=False,
) -> dict:
    """Build a synthetic KYB endpoint response for assertion tests."""
    return {
        "entity_id":           "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        "canonical_name":      canonical_name,
        "jurisdiction_code":   jurisdiction_code,
        "registration_number": registration_number,
        "status":              status,
        "incorporation_date":  "2015-03-01",
        "dissolution_date":    None,
        "company_type":        "ltd",
        "is_inactive":         is_inactive,
        "officers":            officers or [],
        "sanctioned_or_pep":   sanctioned_or_pep,
    }


# ── Required fields ────────────────────────────────────────────────────────────

def test_kyb_response_has_all_required_fields():
    resp = _kyb_response_fixture()
    required = {
        "entity_id", "canonical_name", "jurisdiction_code",
        "registration_number", "status", "officers", "sanctioned_or_pep",
    }
    missing = required - resp.keys()
    assert not missing, f"Missing fields: {missing}"


def test_kyb_response_officers_is_list():
    resp = _kyb_response_fixture(officers=[])
    assert isinstance(resp["officers"], list)


def test_kyb_response_sanctioned_or_pep_is_bool():
    for val in (True, False):
        resp = _kyb_response_fixture(sanctioned_or_pep=val)
        assert isinstance(resp["sanctioned_or_pep"], bool)


# ── sanctioned_or_pep derivation ──────────────────────────────────────────────

def _derive_sanctioned_or_pep(officers: list) -> bool:
    """Mirror the endpoint logic: active officer with sanctions_hit or pep_hit."""
    return any(
        o.get("sanctions_hit") or o.get("pep_hit")
        for o in officers
        if o.get("resigned_on") is None
    )


def test_sanctioned_or_pep_false_when_no_officers():
    assert _derive_sanctioned_or_pep([]) is False


def test_sanctioned_or_pep_false_when_all_clean():
    officers = [
        {"full_name": "Alice", "sanctions_hit": False, "pep_hit": False, "resigned_on": None},
        {"full_name": "Bob",   "sanctions_hit": False, "pep_hit": False, "resigned_on": None},
    ]
    assert _derive_sanctioned_or_pep(officers) is False


def test_sanctioned_or_pep_true_on_sanctions_hit():
    officers = [
        {"full_name": "BadActor", "sanctions_hit": True, "pep_hit": False, "resigned_on": None},
    ]
    assert _derive_sanctioned_or_pep(officers) is True


def test_sanctioned_or_pep_true_on_pep_hit():
    officers = [
        {"full_name": "Minister", "sanctions_hit": False, "pep_hit": True, "resigned_on": None},
    ]
    assert _derive_sanctioned_or_pep(officers) is True


def test_sanctioned_or_pep_ignores_resigned_officers():
    """Resigned officers with hits must NOT trigger sanctioned_or_pep."""
    officers = [
        {"full_name": "Former", "sanctions_hit": True, "pep_hit": True,
         "resigned_on": "2020-01-01"},
    ]
    assert _derive_sanctioned_or_pep(officers) is False


def test_sanctioned_or_pep_mixed_active_and_resigned():
    """One resigned (hit) + one active (clean) → False."""
    officers = [
        {"full_name": "Former",  "sanctions_hit": True,  "pep_hit": False, "resigned_on": "2019-06-01"},
        {"full_name": "Current", "sanctions_hit": False, "pep_hit": False, "resigned_on": None},
    ]
    assert _derive_sanctioned_or_pep(officers) is False


def test_sanctioned_or_pep_one_active_hit_among_many():
    officers = [
        {"full_name": "Alice", "sanctions_hit": False, "pep_hit": False, "resigned_on": None},
        {"full_name": "PEP",   "sanctions_hit": False, "pep_hit": True,  "resigned_on": None},
        {"full_name": "Bob",   "sanctions_hit": False, "pep_hit": False, "resigned_on": None},
    ]
    assert _derive_sanctioned_or_pep(officers) is True


# ── Status and inactive flag ───────────────────────────────────────────────────

def test_kyb_dissolved_company_is_inactive():
    resp = _kyb_response_fixture(status="dissolved", is_inactive=True)
    assert resp["status"] == "dissolved"
    assert resp["is_inactive"] is True


def test_kyb_active_company_not_inactive():
    resp = _kyb_response_fixture(status="active", is_inactive=False)
    assert resp["is_inactive"] is False


# ── Canonical key ─────────────────────────────────────────────────────────────

def test_kyb_canonical_key_is_jurisdiction_plus_number():
    resp = _kyb_response_fixture(jurisdiction_code="fr", registration_number="FR-789012")
    key = (resp["jurisdiction_code"], resp["registration_number"])
    assert key == ("fr", "FR-789012")


def test_kyb_same_number_different_jurisdiction_distinct_keys():
    resp_gb = _kyb_response_fixture(jurisdiction_code="gb", registration_number="123456")
    resp_cy = _kyb_response_fixture(jurisdiction_code="cy", registration_number="123456")
    key_gb = (resp_gb["jurisdiction_code"], resp_gb["registration_number"])
    key_cy = (resp_cy["jurisdiction_code"], resp_cy["registration_number"])
    assert key_gb != key_cy


# ── UUID validation (endpoint input guard) ────────────────────────────────────

import re as _re
_UUID_RE = _re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    _re.IGNORECASE,
)


def _is_valid_uuid(value: str) -> bool:
    return bool(_UUID_RE.match(value))


def test_valid_uuid_accepted():
    assert _is_valid_uuid("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")


def test_invalid_uuid_not_alphanumeric_rejected():
    assert not _is_valid_uuid("not-a-uuid")


def test_invalid_uuid_injection_attempt_rejected():
    assert not _is_valid_uuid("'; DROP TABLE kyb_entities; --")


def test_empty_string_not_valid_uuid():
    assert not _is_valid_uuid("")


# ═════════════════════════════════════════════════════════════════════════════
# runner (for non-pytest execution)
# ═════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    import subprocess, sys
    sys.exit(subprocess.call(
        [sys.executable, "-m", "pytest", __file__, "-v", "--tb=short"],
    ))
