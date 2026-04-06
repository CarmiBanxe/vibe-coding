"""
InMemoryPolicyAdapter — PolicyPort for tests and local development.

Accepts threshold and jurisdiction overrides at construction time.
Defaults mirror compliance_config.yaml production values.
"""
from __future__ import annotations

from compliance.ports.policy_port import PolicyPort

_DEFAULT_THRESHOLDS: dict[str, float] = {
    "sar":                         85.0,
    "reject":                      70.0,
    "hold":                        40.0,
    "watchman_min_match":          0.80,
    "mlr_reporting_threshold_gbp": 10_000.0,
}

_DEFAULT_HARD_BLOCK = frozenset({"RU", "BY", "IR", "KP", "CU", "MM", "AF", "VE", "CRIMEA", "DNR", "LNR"})
_DEFAULT_HIGH_RISK  = frozenset({"SY", "IQ", "LB", "YE", "HT", "ML"})


class InMemoryPolicyAdapter(PolicyPort):
    """
    In-memory PolicyPort for tests and local dev.

    Usage:
        adapter = InMemoryPolicyAdapter()
        adapter = InMemoryPolicyAdapter(
            thresholds={"sar": 90, "reject": 75, "hold": 45},
            hard_block={"RU"},
        )
    """

    def __init__(
        self,
        *,
        thresholds: dict[str, float] | None = None,
        hard_block: set[str] | None = None,
        high_risk:  set[str] | None = None,
        forbidden_patterns: list[str] | None = None,
    ) -> None:
        self._thresholds = dict(_DEFAULT_THRESHOLDS)
        if thresholds:
            self._thresholds.update(thresholds)
        self._hard_block = frozenset(hard_block) if hard_block is not None else _DEFAULT_HARD_BLOCK
        self._high_risk  = frozenset(high_risk)  if high_risk  is not None else _DEFAULT_HIGH_RISK
        self._forbidden  = list(forbidden_patterns) if forbidden_patterns is not None else [
            r"bypass\s+kyc",
            r"skip\s+edd",
        ]

    def get_forbidden_patterns(self) -> list[str]:
        return list(self._forbidden)

    def get_threshold(self, name: str) -> float:
        if name not in self._thresholds:
            raise KeyError(
                f"Unknown threshold '{name}'. Known: {sorted(self._thresholds.keys())}"
            )
        return float(self._thresholds[name])

    def get_jurisdiction_class(self, iso_code: str) -> str:
        code = iso_code.upper()
        if code in self._hard_block:
            return "A"
        if code in self._high_risk:
            return "B"
        return "STANDARD"
