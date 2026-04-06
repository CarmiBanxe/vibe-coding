"""
ComplianceConfigPolicyAdapter — PolicyPort backed by compliance_config.yaml (G-07).

Production adapter for read-only policy access.
All values come from the single-source YAML config via config_loader (G-07).

Invariant I-22: this adapter exposes ONLY read methods.
No write path exists — by design.
"""
from __future__ import annotations

from compliance.ports.policy_port import PolicyPort
from compliance.utils.config_loader import (
    get_threshold_sar,
    get_threshold_reject,
    get_threshold_hold,
    get_watchman_min_match,
    get_mlr_reporting_threshold_gbp,
    get_hard_block_jurisdictions,
    get_high_risk_jurisdictions,
    get_forbidden_patterns,
)

_THRESHOLD_REGISTRY = {
    "sar":                         get_threshold_sar,
    "reject":                      get_threshold_reject,
    "hold":                        get_threshold_hold,
    "watchman_min_match":          get_watchman_min_match,
    "mlr_reporting_threshold_gbp": get_mlr_reporting_threshold_gbp,
}


class ComplianceConfigPolicyAdapter(PolicyPort):
    """
    PolicyPort backed by compliance_config.yaml via config_loader.

    Threshold values are loaded lazily (lru_cache in config_loader).
    Jurisdiction lists are loaded on first call and cached in the adapter instance.
    """

    def get_forbidden_patterns(self) -> list[str]:
        """Return red-line regex patterns from compliance_config.yaml."""
        return get_forbidden_patterns()

    def get_threshold(self, name: str) -> float:
        """
        Return a named decision threshold.

        Raises KeyError for unknown threshold names — fail-fast prevents
        silent use of wrong default values in compliance logic.
        """
        if name not in _THRESHOLD_REGISTRY:
            raise KeyError(
                f"Unknown threshold '{name}'. "
                f"Known: {sorted(_THRESHOLD_REGISTRY.keys())}"
            )
        return float(_THRESHOLD_REGISTRY[name]())

    def get_jurisdiction_class(self, iso_code: str) -> str:
        """
        Return jurisdiction risk class: "A" | "B" | "STANDARD".

        Category A (hard_block): immediate REJECT/SAR.
        Category B (high_risk):  EDD mandatory, HOLD floor.
        STANDARD:                no special classification.
        """
        code = iso_code.upper()
        if code in get_hard_block_jurisdictions():
            return "A"
        if code in get_high_risk_jurisdictions():
            return "B"
        return "STANDARD"
