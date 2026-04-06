"""
chainalysis_adapter.py — Chainalysis Crypto AML Commercial Adapter (Stub)

Provides blockchain transaction screening and wallet risk scoring
via the Chainalysis KYT (Know Your Transaction) API.
Supplements / replaces crypto_aml.py (Jube-only) for commercial coverage.

Modes:
    STUB (default when CHAINALYSIS_API_KEY not set):
        Returns NotConfiguredError with onboarding instructions.
    LIVE (when CHAINALYSIS_API_KEY env var is set):
        Calls Chainalysis KYT REST API.

Vendor:
    Chainalysis — Blockchain Analytics
    Docs: https://docs.chainalysis.com/api/kyt/
    Auth: CHAINALYSIS_API_KEY in env
    Contract needed: contact vendors@banxe.ai
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Optional

from compliance.models import RiskSignal
from compliance.adapters.dowjones_adapter import NotConfiguredError, VendorAPIError


# ── Config ────────────────────────────────────────────────────────────────────

@dataclass
class ChainalysisConfig:
    """
    Configuration for Chainalysis KYT API.

    Fields:
        api_key:           env CHAINALYSIS_API_KEY
        api_url:           base URL (US or EU endpoint)
        risk_threshold:    score above which to flag as high-risk (0–10, default 7)
        timeout_s:         request timeout
    """
    api_key: str = ""
    api_url: str = "https://api.chainalysis.com"
    risk_threshold: int = 7
    timeout_s: float = 10.0

    @classmethod
    def from_env(cls) -> "ChainalysisConfig":
        return cls(
            api_key=os.environ.get("CHAINALYSIS_API_KEY", ""),
            api_url=os.environ.get("CHAINALYSIS_API_URL", cls.api_url),
            risk_threshold=int(os.environ.get("CHAINALYSIS_RISK_THRESHOLD", str(cls.risk_threshold))),
        )

    @property
    def is_configured(self) -> bool:
        return bool(self.api_key.strip())


# ── Result types ──────────────────────────────────────────────────────────────

@dataclass
class WalletRiskResult:
    """Risk assessment for a crypto wallet address."""
    address: str
    chain: str                          # eth | btc | tron | sol | ...
    risk_score: int                     # 0–10 (Chainalysis scale)
    risk_category: str = "UNKNOWN"      # LOW | MEDIUM | HIGH | SEVERE
    exposure_categories: list[str] = field(default_factory=list)   # darknet | mixing | sanctions | etc.
    sanctions_exposure: float = 0.0    # % of funds from sanctioned entities
    cluster_name: str = ""             # known entity label (e.g. "Binance", "Tornado Cash")
    raw_response: dict = field(default_factory=dict)

    @property
    def is_high_risk(self) -> bool:
        return self.risk_category in ("HIGH", "SEVERE")

    def to_risk_signal(self) -> Optional[RiskSignal]:
        if self.risk_score < 5:
            return None
        score = min(self.risk_score * 10, 100)
        categories_str = ", ".join(self.exposure_categories) if self.exposure_categories else "unknown"
        return RiskSignal(
            source="chainalysis_kyt",
            rule=f"CRYPTO_RISK_{self.risk_category}",
            score=score,
            reason=(
                f"Chainalysis KYT: wallet {self.address[:10]}... ({self.chain.upper()}) "
                f"risk score {self.risk_score}/10, category={self.risk_category}. "
                f"Exposure: {categories_str}."
                + (f" Sanctions: {self.sanctions_exposure:.1%}" if self.sanctions_exposure > 0 else "")
            ),
            authority="FCA Cryptoasset AML / Travel Rule (JMLSG Part III)",
            requires_edd=self.is_high_risk,
            requires_mlro=self.risk_category == "SEVERE" or self.sanctions_exposure > 0.1,
        )


@dataclass
class TransactionRiskResult:
    """Risk assessment for a specific crypto transaction."""
    tx_hash: str
    chain: str
    risk_score: int                     # 0–10
    risk_category: str = "UNKNOWN"
    sent_exposure: dict = field(default_factory=dict)   # counterparty risk breakdown (sent)
    received_exposure: dict = field(default_factory=dict)  # counterparty risk breakdown (received)
    alerts: list[str] = field(default_factory=list)    # Chainalysis alert types
    raw_response: dict = field(default_factory=dict)

    def to_risk_signal(self) -> Optional[RiskSignal]:
        if self.risk_score < 5:
            return None
        score = min(self.risk_score * 10, 100)
        return RiskSignal(
            source="chainalysis_kyt",
            rule=f"CRYPTO_TX_{self.risk_category}",
            score=score,
            reason=(
                f"Chainalysis KYT: transaction {self.tx_hash[:12]}... ({self.chain.upper()}) "
                f"risk={self.risk_score}/10, alerts={self.alerts or 'none'}"
            ),
            authority="FCA Cryptoasset AML / FATF VASP Travel Rule",
            requires_edd=self.risk_score >= 7,
            requires_mlro=self.risk_score >= 9,
        )


# ── Adapter ───────────────────────────────────────────────────────────────────

class ChainalysisAdapter:
    """
    Chainalysis KYT (Know Your Transaction) adapter.

    STUB mode: raises NotConfiguredError.
    LIVE mode: calls Chainalysis REST API.

    Usage:
        adapter = ChainalysisAdapter()
        result = adapter.screen_wallet("0xabc...", chain="eth")
        signal = result.to_risk_signal()
    """

    _ONBOARDING_MSG = (
        "Chainalysis API key not configured. "
        "To enable commercial-grade crypto transaction screening: "
        "1. Contact vendors@banxe.ai to obtain Chainalysis KYT contract. "
        "2. Set env var: CHAINALYSIS_API_KEY=<your-key>. "
        "3. Optionally: CHAINALYSIS_API_URL=<eu-endpoint> for GDPR compliance. "
        "Current fallback: Jube crypto_aml.py (open-source, lower coverage)."
    )

    def __init__(self, config: Optional[ChainalysisConfig] = None) -> None:
        self._config = config or ChainalysisConfig.from_env()
        self._mode = "LIVE" if self._config.is_configured else "STUB"

    @property
    def mode(self) -> str:
        return self._mode

    def screen_wallet(self, address: str, chain: str = "eth") -> WalletRiskResult:
        """
        Screen a crypto wallet address for risk.

        Args:
            address: Wallet address (hex for EVM chains, base58 for BTC/SOL).
            chain:   Blockchain: eth | btc | tron | sol | bnb | ...

        Returns:
            WalletRiskResult

        Raises:
            NotConfiguredError: In STUB mode.
            VendorAPIError:     On API errors.
        """
        if self._mode == "STUB":
            raise NotConfiguredError(self._ONBOARDING_MSG)
        return self._live_screen_wallet(address, chain)

    def screen_transaction(self, tx_hash: str, chain: str = "eth") -> TransactionRiskResult:
        """
        Screen a specific blockchain transaction for risk.

        Args:
            tx_hash: Transaction hash.
            chain:   Blockchain identifier.

        Returns:
            TransactionRiskResult

        Raises:
            NotConfiguredError: In STUB mode.
            VendorAPIError:     On API errors.
        """
        if self._mode == "STUB":
            raise NotConfiguredError(self._ONBOARDING_MSG)
        return self._live_screen_transaction(tx_hash, chain)

    def _live_screen_wallet(self, address: str, chain: str) -> WalletRiskResult:
        try:
            import json
            import urllib.request

            url = f"{self._config.api_url}/api/kyt/v2/users/{address}/summary"
            req = urllib.request.Request(
                url,
                headers={
                    "Token": self._config.api_key,
                    "Accept": "application/json",
                },
            )
            with urllib.request.urlopen(req, timeout=self._config.timeout_s) as resp:
                data = json.loads(resp.read())

            score = int(data.get("riskScore", 0) * 10)  # normalize to 0-10
            category = _score_to_category(score, self._config.risk_threshold)
            return WalletRiskResult(
                address=address,
                chain=chain,
                risk_score=score,
                risk_category=category,
                exposure_categories=data.get("exposureCategories", []),
                sanctions_exposure=float(data.get("sanctionsExposure", 0)),
                cluster_name=data.get("clusterName", ""),
                raw_response=data,
            )
        except Exception as e:
            raise VendorAPIError(f"Chainalysis wallet API error: {e}") from e

    def _live_screen_transaction(self, tx_hash: str, chain: str) -> TransactionRiskResult:
        try:
            import json
            import urllib.request

            url = f"{self._config.api_url}/api/kyt/v2/transfers/{tx_hash}/summary"
            req = urllib.request.Request(
                url,
                headers={
                    "Token": self._config.api_key,
                    "Accept": "application/json",
                },
            )
            with urllib.request.urlopen(req, timeout=self._config.timeout_s) as resp:
                data = json.loads(resp.read())

            score = int(data.get("riskScore", 0) * 10)
            return TransactionRiskResult(
                tx_hash=tx_hash,
                chain=chain,
                risk_score=score,
                risk_category=_score_to_category(score, self._config.risk_threshold),
                sent_exposure=data.get("sentExposure", {}),
                received_exposure=data.get("receivedExposure", {}),
                alerts=data.get("alerts", []),
                raw_response=data,
            )
        except Exception as e:
            raise VendorAPIError(f"Chainalysis tx API error: {e}") from e


def _score_to_category(score: int, threshold: int) -> str:
    """Map 0–10 score to risk category."""
    if score >= 9:
        return "SEVERE"
    if score >= threshold:
        return "HIGH"
    if score >= 4:
        return "MEDIUM"
    return "LOW"
