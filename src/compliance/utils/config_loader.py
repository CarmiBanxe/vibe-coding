"""
config_loader.py — 12-Factor Factor III: BANXE AML Policy Config Loader.

Single source of truth for all AML thresholds and jurisdiction lists.
Config is loaded from compliance_config.yaml (checked into git for audit trail).

Override for tests / staging:
    export COMPLIANCE_CONFIG_PATH=/path/to/test_compliance_config.yaml

Reload in tests:
    from compliance.utils.config_loader import reload_config
    reload_config()   # clears lru_cache, reloads from current COMPLIANCE_CONFIG_PATH

Closes: GAP-REGISTER G-07 (12-Factor Factor III)
Authority: FCA MLR 2017, SAMLA 2018, UK HMT Consolidated List
"""
from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path
from typing import Any

# Default config path — relative to this file: ../../compliance_config.yaml
_DEFAULT_CONFIG_PATH = Path(__file__).parent.parent / "compliance_config.yaml"


@lru_cache(maxsize=1)
def _load() -> dict:
    """
    Load and cache compliance_config.yaml.
    Uses COMPLIANCE_CONFIG_PATH env var if set (for tests / staging).
    """
    path = os.environ.get("COMPLIANCE_CONFIG_PATH", str(_DEFAULT_CONFIG_PATH))
    try:
        import yaml
    except ImportError:
        raise ImportError(
            "PyYAML is required for compliance config loading. "
            "Run: pip install pyyaml"
        )
    with open(path) as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise ValueError(f"compliance_config.yaml must be a YAML mapping, got: {type(data)}")
    return data


def reload_config() -> None:
    """
    Clear the lru_cache and reload config.
    Call after setting COMPLIANCE_CONFIG_PATH in tests.
    """
    _load.cache_clear()


# ── Decision thresholds ────────────────────────────────────────────────────────

def get_threshold_sar() -> int:
    """Composite score threshold for SAR obligation (default: 85)."""
    return int(_load()["decision_thresholds"]["sar"])


def get_threshold_reject() -> int:
    """Composite score threshold for REJECT (default: 70)."""
    return int(_load()["decision_thresholds"]["reject"])


def get_threshold_hold() -> int:
    """Composite score threshold for HOLD (default: 40). Below = APPROVE."""
    return int(_load()["decision_thresholds"]["hold"])


# ── Watchman / Yente ──────────────────────────────────────────────────────────

def get_watchman_min_match() -> float:
    """Jaro-Winkler similarity floor for Watchman hits (default: 0.80)."""
    return float(_load()["watchman"]["min_match"])


def get_watchman_url() -> str:
    """Watchman service URL (default: http://127.0.0.1:8084)."""
    return str(_load()["watchman"]["url"])


def get_watchman_timeout() -> int:
    """Watchman HTTP timeout in seconds (default: 5)."""
    return int(_load()["watchman"]["timeout"])


def get_yente_min_score() -> float:
    """YENTE confidence floor (default: 0.80)."""
    return float(_load()["sanctions_screening"]["yente_min_score"])


# ── Jurisdiction lists ─────────────────────────────────────────────────────────

def get_hard_block_jurisdictions() -> frozenset:
    """
    Category A jurisdictions — immediate REJECT/SAR.
    Authority: SAMLA 2018, UK HMT Consolidated List, OFAC SDN.
    """
    return frozenset(_load()["jurisdictions"]["hard_block"])


def get_high_risk_jurisdictions() -> frozenset:
    """
    Category B jurisdictions — EDD mandatory, HOLD floor.
    Authority: FCA EDD §4.2, FATF high-risk jurisdictions.
    """
    return frozenset(_load()["jurisdictions"]["high_risk"])


# ── Transaction monitoring ────────────────────────────────────────────────────

def get_mlr_reporting_threshold_gbp() -> int:
    """Single-transaction reporting threshold in GBP (default: 10,000)."""
    return int(_load()["transaction_monitoring"]["mlr_reporting_threshold_gbp"])


# ── Policy metadata ───────────────────────────────────────────────────────────

def get_audit_ttl_years() -> int:
    """FCA MLR 2017 minimum audit retention in years (default: 5)."""
    return int(_load()["policy"]["audit_ttl_years"])


def get_policy_version() -> str:
    """Policy version string for audit trail provenance."""
    return str(_load()["policy"]["version"])


# ── Forbidden patterns ────────────────────────────────────────────────────────

def get_forbidden_patterns() -> list[str]:
    """Regex patterns that agents MUST NOT emit (FCA MLR 2017 §3 red lines)."""
    return list(_load()["forbidden_patterns"])
