"""
sumsub_adapter.py — Sumsub KYC/KYB Verification Commercial Adapter (Stub)

Provides document verification, face liveness, and KYB business verification
via the Sumsub API. Replaces manual KYC document review for FCA onboarding.

Modes:
    STUB (default when SUMSUB_APP_TOKEN not set):
        Returns NotConfiguredError with onboarding instructions.
    LIVE (when SUMSUB_APP_TOKEN env var is set):
        Calls Sumsub REST API.

Vendor:
    Sumsub — Identity Verification Platform
    Docs: https://developers.sumsub.com/
    Auth: SUMSUB_APP_TOKEN + SUMSUB_SECRET_KEY (HMAC-SHA256 signed requests)
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
class SumsubConfig:
    """
    Configuration for Sumsub API.

    Fields:
        app_token:   env SUMSUB_APP_TOKEN
        secret_key:  env SUMSUB_SECRET_KEY (HMAC signing)
        api_url:     base URL
        level_name:  verification level (default: "banxe-kyc-basic")
        timeout_s:   request timeout
    """
    app_token: str = ""
    secret_key: str = ""
    api_url: str = "https://api.sumsub.com"
    level_name: str = "banxe-kyc-basic"
    timeout_s: float = 10.0

    @classmethod
    def from_env(cls) -> "SumsubConfig":
        return cls(
            app_token=os.environ.get("SUMSUB_APP_TOKEN", ""),
            secret_key=os.environ.get("SUMSUB_SECRET_KEY", ""),
            api_url=os.environ.get("SUMSUB_API_URL", cls.api_url),
            level_name=os.environ.get("SUMSUB_LEVEL_NAME", cls.level_name),
        )

    @property
    def is_configured(self) -> bool:
        return bool(self.app_token.strip() and self.secret_key.strip())


# ── Result types ──────────────────────────────────────────────────────────────

@dataclass
class VerificationResult:
    """Result from Sumsub document/identity verification."""
    applicant_id: str
    status: str                         # APPROVED | REJECTED | PENDING | AWAITING_REVIEW
    review_result: str = ""             # GREEN | RED | YELLOW (Sumsub internal)
    reject_labels: list[str] = field(default_factory=list)    # reason codes
    document_type: str = ""
    country: str = ""
    full_name: str = ""
    date_of_birth: str = ""
    raw_response: dict = field(default_factory=dict)

    @property
    def is_approved(self) -> bool:
        return self.status == "APPROVED"

    @property
    def is_rejected(self) -> bool:
        return self.status == "REJECTED"

    def to_risk_signal(self) -> Optional[RiskSignal]:
        """Generate a RiskSignal only on rejection or pending review."""
        if self.is_approved:
            return None
        score = 80 if self.is_rejected else 40
        return RiskSignal(
            source="sumsub_kyc",
            rule=f"KYC_{self.status}",
            score=score,
            reason=(
                f"Sumsub KYC {self.status} for applicant {self.applicant_id}: "
                + (f"reject labels: {self.reject_labels}" if self.reject_labels else "pending human review")
            ),
            authority="FCA MLR 2017 §28 / AML Directive 5 Art.13",
            requires_edd=self.status == "AWAITING_REVIEW",
            requires_mlro=self.is_rejected,
        )


@dataclass
class KYBResult:
    """Result from Sumsub company/KYB verification."""
    company_id: str
    company_name: str
    status: str                         # APPROVED | REJECTED | PENDING
    ubo_list: list[str] = field(default_factory=list)         # ultimate beneficial owners
    director_list: list[str] = field(default_factory=list)
    jurisdiction: str = ""
    incorporation_date: str = ""
    psc_flags: list[str] = field(default_factory=list)        # persons of significant control
    raw_response: dict = field(default_factory=dict)

    @property
    def is_approved(self) -> bool:
        return self.status == "APPROVED"

    def to_risk_signal(self) -> Optional[RiskSignal]:
        if self.is_approved:
            return None
        return RiskSignal(
            source="sumsub_kyb",
            rule=f"KYB_{self.status}",
            score=75,
            reason=f"Sumsub KYB {self.status} for company '{self.company_name}' ({self.company_id})",
            authority="FCA MLR 2017 §28 / Companies Act 2006",
            requires_edd=True,
            requires_mlro=self.status == "REJECTED",
        )


# ── Adapter ───────────────────────────────────────────────────────────────────

class SumsubAdapter:
    """
    Sumsub KYC/KYB verification adapter.

    STUB mode: raises NotConfiguredError.
    LIVE mode: calls Sumsub REST API with HMAC-signed requests.

    Usage:
        adapter = SumsubAdapter()
        result = adapter.verify_document("applicant-123", "PASSPORT")
    """

    _ONBOARDING_MSG = (
        "Sumsub API credentials not configured. "
        "To enable automated KYC/KYB document verification: "
        "1. Contact vendors@banxe.ai to obtain Sumsub contract. "
        "2. Set env vars: SUMSUB_APP_TOKEN=<token> SUMSUB_SECRET_KEY=<secret>. "
        "3. Optionally: SUMSUB_LEVEL_NAME=banxe-kyc-enhanced for EDD flow. "
        "Current fallback: manual KYC review queue."
    )

    def __init__(self, config: Optional[SumsubConfig] = None) -> None:
        self._config = config or SumsubConfig.from_env()
        self._mode = "LIVE" if self._config.is_configured else "STUB"

    @property
    def mode(self) -> str:
        return self._mode

    def verify_document(self, applicant_id: str, document_type: str = "PASSPORT") -> VerificationResult:
        """
        Verify an applicant's identity document.

        Args:
            applicant_id:  Sumsub applicant ID (created via create_applicant).
            document_type: Document type: PASSPORT | ID_CARD | DRIVERS | RESIDENCE_PERMIT.

        Returns:
            VerificationResult

        Raises:
            NotConfiguredError: In STUB mode.
        """
        if self._mode == "STUB":
            raise NotConfiguredError(self._ONBOARDING_MSG)
        return self._live_verify_document(applicant_id, document_type)

    def verify_kyb(self, company_id: str, company_name: str, jurisdiction: str = "GB") -> KYBResult:
        """
        Verify a company (KYB — Know Your Business).

        Args:
            company_id:   Sumsub company applicant ID.
            company_name: Registered company name.
            jurisdiction: ISO2 country code.

        Returns:
            KYBResult including UBO list and directors.

        Raises:
            NotConfiguredError: In STUB mode.
        """
        if self._mode == "STUB":
            raise NotConfiguredError(self._ONBOARDING_MSG)
        return self._live_verify_kyb(company_id, company_name, jurisdiction)

    def get_applicant_status(self, applicant_id: str) -> str:
        """
        Poll applicant review status.

        Returns:
            Status string: APPROVED | REJECTED | PENDING | AWAITING_REVIEW

        Raises:
            NotConfiguredError: In STUB mode.
        """
        if self._mode == "STUB":
            raise NotConfiguredError(self._ONBOARDING_MSG)
        return self._live_get_status(applicant_id)

    def _sign_request(self, method: str, path: str, ts: int) -> str:
        """Generate HMAC-SHA256 signature for Sumsub request."""
        import hmac
        import hashlib
        message = f"{ts}{method.upper()}{path}".encode()
        return hmac.new(self._config.secret_key.encode(), message, hashlib.sha256).hexdigest()

    def _live_verify_document(self, applicant_id: str, document_type: str) -> VerificationResult:
        try:
            import time
            import json
            import urllib.request

            ts = int(time.time())
            path = f"/resources/applicants/{applicant_id}/requiredIdDocsStatus"
            signature = self._sign_request("GET", path, ts)
            req = urllib.request.Request(
                f"{self._config.api_url}{path}",
                headers={
                    "X-App-Token": self._config.app_token,
                    "X-App-Access-Ts": str(ts),
                    "X-App-Access-Sig": signature,
                },
            )
            with urllib.request.urlopen(req, timeout=self._config.timeout_s) as resp:
                data = json.loads(resp.read())

            status = data.get("reviewResult", {}).get("reviewAnswer", "PENDING")
            return VerificationResult(
                applicant_id=applicant_id,
                status=status,
                document_type=document_type,
                raw_response=data,
            )
        except Exception as e:
            raise VendorAPIError(f"Sumsub API error: {e}") from e

    def _live_verify_kyb(self, company_id: str, company_name: str, jurisdiction: str) -> KYBResult:
        try:
            import time
            import json
            import urllib.request

            ts = int(time.time())
            path = f"/resources/applicants/{company_id}/one"
            signature = self._sign_request("GET", path, ts)
            req = urllib.request.Request(
                f"{self._config.api_url}{path}",
                headers={
                    "X-App-Token": self._config.app_token,
                    "X-App-Access-Ts": str(ts),
                    "X-App-Access-Sig": signature,
                },
            )
            with urllib.request.urlopen(req, timeout=self._config.timeout_s) as resp:
                data = json.loads(resp.read())

            status = data.get("review", {}).get("reviewResult", {}).get("reviewAnswer", "PENDING")
            return KYBResult(
                company_id=company_id,
                company_name=company_name,
                status=status,
                jurisdiction=jurisdiction,
                raw_response=data,
            )
        except Exception as e:
            raise VendorAPIError(f"Sumsub KYB API error: {e}") from e

    def _live_get_status(self, applicant_id: str) -> str:
        try:
            import time
            import json
            import urllib.request

            ts = int(time.time())
            path = f"/resources/applicants/{applicant_id}/status/api"
            signature = self._sign_request("GET", path, ts)
            req = urllib.request.Request(
                f"{self._config.api_url}{path}",
                headers={
                    "X-App-Token": self._config.app_token,
                    "X-App-Access-Ts": str(ts),
                    "X-App-Access-Sig": signature,
                },
            )
            with urllib.request.urlopen(req, timeout=self._config.timeout_s) as resp:
                data = json.loads(resp.read())
            return data.get("reviewResult", {}).get("reviewAnswer", "PENDING")
        except Exception as e:
            raise VendorAPIError(f"Sumsub status API error: {e}") from e
