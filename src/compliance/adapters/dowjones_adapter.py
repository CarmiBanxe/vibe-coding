"""
dowjones_adapter.py — Dow Jones Risk & Compliance Commercial Adapter (Stub)

Provides PEP/sanctions screening via Dow Jones Risk & Compliance API.
Covers relatives & associates (R&A) — not available in open-source alternatives.

Modes:
    STUB (default when DOW_JONES_API_KEY not set):
        Returns NotConfiguredError with vendor onboarding instructions.
    LIVE (when DOW_JONES_API_KEY env var is set):
        Calls Dow Jones REST API, maps response to RiskSignal.

Integration:
    Replaces / supplements pep_check.py (Wikidata only) and sanctions_check.py
    (Watchman only) for commercial-grade coverage.
    Called from banxe_aml_orchestrator Layer-2 when djrc_screening=True.

Vendor:
    Dow Jones Risk & Compliance (DJRC)
    Docs: https://developer.dowjones.com/risk-and-compliance/
    Auth: API key (env DOW_JONES_API_KEY)
    Contract needed: contact vendors@banxe.ai
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Optional

from compliance.models import RiskSignal


# ── Errors ────────────────────────────────────────────────────────────────────

class NotConfiguredError(Exception):
    """Raised when a commercial adapter is in STUB mode (API key not set)."""


class VendorAPIError(Exception):
    """Raised when the vendor API returns an unexpected error."""


# ── Config ────────────────────────────────────────────────────────────────────

@dataclass
class DowJonesConfig:
    """
    Configuration for Dow Jones Risk & Compliance API.

    Fields:
        api_key:     env DOW_JONES_API_KEY — never hardcode
        api_url:     base URL (default: production endpoint)
        timeout_s:   request timeout in seconds
        min_score:   minimum match score to report (0.0–1.0, default 0.80)
    """
    api_key: str = ""
    api_url: str = "https://api.dowjones.com/risk-compliance/v1"
    timeout_s: float = 5.0
    min_score: float = 0.80

    @classmethod
    def from_env(cls) -> "DowJonesConfig":
        return cls(
            api_key=os.environ.get("DOW_JONES_API_KEY", ""),
            api_url=os.environ.get("DOW_JONES_API_URL", cls.api_url),
            min_score=float(os.environ.get("DOW_JONES_MIN_SCORE", str(cls.min_score))),
        )

    @property
    def is_configured(self) -> bool:
        return bool(self.api_key.strip())


# ── Result types ──────────────────────────────────────────────────────────────

@dataclass
class ScreeningResult:
    """Result from PEP/sanctions entity screening."""
    is_hit: bool
    entity_name: str
    match_score: float = 0.0
    list_name: str = ""                  # e.g. "HM Treasury", "OFAC SDN", "PEP"
    match_type: str = ""                 # "EXACT" | "FUZZY" | "PHONETIC"
    jurisdiction: str = ""
    risk_level: str = "UNKNOWN"          # LOW | MEDIUM | HIGH | CRITICAL
    raw_response: dict = field(default_factory=dict)

    def to_risk_signal(self) -> Optional[RiskSignal]:
        """Convert a hit to a RiskSignal for the AML orchestrator."""
        if not self.is_hit:
            return None
        score = int(self.match_score * 100)
        return RiskSignal(
            source="dowjones_djrc",
            rule=f"DJRC_{self.match_type}_HIT",
            score=min(score, 100),
            reason=(
                f"Dow Jones DJRC match: '{self.entity_name}' on {self.list_name} "
                f"(score={self.match_score:.0%}, type={self.match_type})"
            ),
            authority="SAMLA 2018 / FCA MLR 2017",
            requires_edd=self.risk_level in ("HIGH", "CRITICAL"),
            requires_mlro=self.risk_level == "CRITICAL",
        )


@dataclass
class PEPResult:
    """Result from PEP screening including relatives & associates."""
    is_pep: bool
    entity_name: str
    pep_tier: int = 0                    # 1=head of state, 2=senior official, 3=associate
    relatives: list[str] = field(default_factory=list)    # names of PEP relatives
    associates: list[str] = field(default_factory=list)   # names of close associates
    match_score: float = 0.0
    jurisdiction: str = ""
    roles: list[str] = field(default_factory=list)        # political roles held
    raw_response: dict = field(default_factory=dict)

    def to_risk_signal(self) -> Optional[RiskSignal]:
        if not self.is_pep:
            return None
        score = 60 + (self.pep_tier == 1) * 30 + (self.pep_tier == 2) * 15
        return RiskSignal(
            source="dowjones_djrc",
            rule=f"PEP_TIER_{self.pep_tier}",
            score=score,
            reason=(
                f"PEP identified: '{self.entity_name}' — Tier {self.pep_tier} "
                f"({', '.join(self.roles) or 'unknown role'}). "
                + (f"R&A: {self.relatives + self.associates}" if self.relatives or self.associates else "")
            ),
            authority="FCA EDD §4.2 / FATF Rec 12",
            requires_edd=True,
            requires_mlro=self.pep_tier == 1,
        )


# ── Adapter ───────────────────────────────────────────────────────────────────

class DowJonesAdapter:
    """
    Dow Jones Risk & Compliance (DJRC) adapter.

    In STUB mode: raises NotConfiguredError with vendor onboarding instructions.
    In LIVE mode: calls DJRC REST API.

    Usage:
        adapter = DowJonesAdapter()
        result = adapter.screen_entity("Ivan Petrov", "RU")
        signal = result.to_risk_signal()
    """

    _ONBOARDING_MSG = (
        "Dow Jones Risk & Compliance (DJRC) API key not configured. "
        "To enable commercial-grade PEP/sanctions screening: "
        "1. Contact vendors@banxe.ai to obtain DJRC contract. "
        "2. Set env var: DOW_JONES_API_KEY=<your-key>. "
        "3. Optionally: DOW_JONES_API_URL=<custom-endpoint>. "
        "Fallback: Watchman (watchman-adapter) provides open-source sanctions screening."
    )

    def __init__(self, config: Optional[DowJonesConfig] = None) -> None:
        self._config = config or DowJonesConfig.from_env()
        self._mode = "LIVE" if self._config.is_configured else "STUB"

    @property
    def mode(self) -> str:
        return self._mode

    def screen_entity(self, name: str, jurisdiction: str = "") -> ScreeningResult:
        """
        Screen an entity against DJRC sanctions + PEP lists.

        Args:
            name:         Entity name (person or company).
            jurisdiction: ISO2 country code (optional, improves accuracy).

        Returns:
            ScreeningResult

        Raises:
            NotConfiguredError: In STUB mode (API key not set).
            VendorAPIError:     On API errors in LIVE mode.
        """
        if self._mode == "STUB":
            raise NotConfiguredError(self._ONBOARDING_MSG)
        return self._live_screen_entity(name, jurisdiction)

    def screen_pep(self, name: str, jurisdiction: str = "") -> PEPResult:
        """
        Screen an entity for PEP status including relatives & associates.

        Args:
            name:         Entity name.
            jurisdiction: ISO2 country code (optional).

        Returns:
            PEPResult — includes relatives[] and associates[] lists.

        Raises:
            NotConfiguredError: In STUB mode.
            VendorAPIError:     On API errors.
        """
        if self._mode == "STUB":
            raise NotConfiguredError(self._ONBOARDING_MSG)
        return self._live_screen_pep(name, jurisdiction)

    def _live_screen_entity(self, name: str, jurisdiction: str) -> ScreeningResult:
        """Live DJRC entity screening — called only when API key is set."""
        try:
            import urllib.request
            import json

            params = f"name={urllib.parse.quote(name)}&jurisdiction={jurisdiction}&minScore={self._config.min_score}"
            url = f"{self._config.api_url}/screen?{params}"
            req = urllib.request.Request(
                url,
                headers={"Authorization": f"Bearer {self._config.api_key}"},
            )
            with urllib.request.urlopen(req, timeout=self._config.timeout_s) as resp:
                data = json.loads(resp.read())

            hits = data.get("hits", [])
            if not hits:
                return ScreeningResult(is_hit=False, entity_name=name, raw_response=data)

            top = hits[0]
            return ScreeningResult(
                is_hit=True,
                entity_name=top.get("name", name),
                match_score=float(top.get("score", 0)),
                list_name=top.get("list", ""),
                match_type=top.get("matchType", "FUZZY"),
                jurisdiction=top.get("jurisdiction", jurisdiction),
                risk_level=top.get("riskLevel", "HIGH"),
                raw_response=data,
            )
        except Exception as e:
            raise VendorAPIError(f"DJRC API error: {e}") from e

    def _live_screen_pep(self, name: str, jurisdiction: str) -> PEPResult:
        """Live DJRC PEP screening."""
        try:
            import urllib.request
            import urllib.parse
            import json

            params = f"name={urllib.parse.quote(name)}&jurisdiction={jurisdiction}&type=pep"
            url = f"{self._config.api_url}/screen?{params}"
            req = urllib.request.Request(
                url,
                headers={"Authorization": f"Bearer {self._config.api_key}"},
            )
            with urllib.request.urlopen(req, timeout=self._config.timeout_s) as resp:
                data = json.loads(resp.read())

            peps = data.get("peps", [])
            if not peps:
                return PEPResult(is_pep=False, entity_name=name, raw_response=data)

            top = peps[0]
            return PEPResult(
                is_pep=True,
                entity_name=top.get("name", name),
                pep_tier=int(top.get("tier", 2)),
                relatives=top.get("relatives", []),
                associates=top.get("associates", []),
                match_score=float(top.get("score", 0)),
                jurisdiction=top.get("jurisdiction", jurisdiction),
                roles=top.get("roles", []),
                raw_response=data,
            )
        except Exception as e:
            raise VendorAPIError(f"DJRC PEP API error: {e}") from e
