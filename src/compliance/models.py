"""
Shared compliance data contracts — the internal "collective LexisNexis" datamodel.

All AML modules (tx_monitor, sanctions_check, crypto_aml) produce RiskSignals
that are aggregated by aml_orchestrator into a single AMLResult.

Decision vocabulary (aligned with compliance_validator thresholds):
  APPROVE  — score < _THRESHOLD_HOLD (40)
  HOLD     — 40 <= score < 70  → EDD required
  REJECT   — 70 <= score < 85  → transaction blocked
  SAR      — score >= 85       → MLRO notified, SAR obligation triggered
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional


# ── Input contracts ───────────────────────────────────────────────────────────

@dataclass
class TransactionInput:
    """Structured transaction for monitoring. Shared across all AML modules."""
    origin_jurisdiction: str           # ISO2
    destination_jurisdiction: str      # ISO2
    amount_gbp: float
    currency: str = "GBP"
    amount_original: float = 0.0
    is_crypto: bool = False
    sender_account: str = ""
    recipient_account: str = ""
    counterparty_name: str = ""
    tx_type: str = "wire"
    flags: list[str] = field(default_factory=list)


@dataclass
class SanctionsSubject:
    """Entity to screen against sanctions lists."""
    name: str
    entity_type: str = "person"        # person / company / vessel
    jurisdiction: str = ""
    aliases: list[str] = field(default_factory=list)
    id_numbers: list[str] = field(default_factory=list)


@dataclass
class WalletScreeningInput:
    """Crypto wallet / address for AML screening."""
    address: str
    chain: str = "eth"                 # eth / btc / tron / sol / ...
    counterparty_name: str = ""
    risk_flags: list[str] = field(default_factory=list)
    # e.g. ["mixer", "darknet", "ransomware", "rapid_in_out"]
    tx_value_usd: float = 0.0


# ── Signal contract ───────────────────────────────────────────────────────────

@dataclass
class RiskSignal:
    """
    A single triggered rule from any AML module.
    All explainability is carried here — the orchestrator only aggregates signals.
    """
    source: str                        # "tx_monitor" / "sanctions_check" / "crypto_aml"
    rule: str                          # machine-readable rule id, e.g. "HARD_BLOCK_JURISDICTION"
    score: int                         # contribution to composite score (0–100)
    reason: str                        # human-readable explanation for MLRO / audit
    authority: Optional[str] = None   # legal basis, e.g. "SAMLA 2018", "FCA MLR 2017 §19"
    requires_edd: bool = False
    requires_mlro: bool = False


# ── Evidence contract ─────────────────────────────────────────────────────────

@dataclass
class EvidenceBundle:
    """
    Набор артефактов, обосновывающих AML-решение.
    Критично для SAR-workflow (NCA требует evidence pack)
    и FCA аудиторских проверок (MLR 2017 §20).
    """
    evidence_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    evidence_type: str = ""    # "sanctions_match" | "tx_pattern" | "pep_hit" |
                               # "velocity_alert" | "crypto_flag" | "jurisdiction_block"
    source: str = ""           # "watchman" | "jube" | "redis_velocity" |
                               # "pep_db" | "wikidata" | "eurlex" | "bailii"
    raw_payload: dict = field(default_factory=dict)   # оригинальный ответ источника
    confidence: float = 1.0   # 0.0-1.0, для fuzzy matches (Watchman Jaro-Winkler)
    match_score: float = 0.0  # score от источника (например Watchman match %)
    authority: str = ""        # правовое основание: "SAMLA 2018", "FCA MLR 2017 §19"
    timestamp: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )


# ── Result contract ───────────────────────────────────────────────────────────

@dataclass
class AMLResult:
    """
    Final aggregated result from the AML orchestrator.

    Thresholds come from compliance_validator (Layer 1):
      APPROVE  score < 40
      HOLD     40 <= score < 70
      REJECT   70 <= score < 85
      SAR      score >= 85
    """
    score: int
    decision: str                      # APPROVE / HOLD / REJECT / SAR
    signals: list[RiskSignal]
    requires_edd: bool
    requires_mlro_review: bool

    # Convenience fields for downstream consumers
    hard_block_hit: bool = False       # Category A jurisdiction or exact sanctions match
    sanctions_hit: bool = False        # Any watchlist hit
    crypto_risk: bool = False          # Crypto-specific risk detected

    # Evidence pack — for SAR NCA submission and FCA audit trail
    evidence: list[EvidenceBundle] = field(default_factory=list)

    # Jurisdiction scope — UK FCA EMI (preemptive label for multi-jurisdiction future)
    jurisdiction: str = "UK"

    # Policy provenance — mirrors VerificationResult.policy_scope contract
    # Keys prefixed with "policy_" to avoid collision with origin_jurisdiction etc.
    # **self.policy_scope unpacks directly into to_audit_dict() → ClickHouse columns.
    policy_scope: dict[str, str] = field(default_factory=lambda: {
        "policy_jurisdiction": "UK",
        "policy_regulator":    "FCA",
        "policy_framework":    "MLR 2017",
    })

    # Audit payload — ready for ClickHouse insert
    audit_payload: dict = field(default_factory=dict)
    timestamp: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )

    def to_audit_dict(self) -> dict:
        """Serialise to flat dict for ClickHouse audit_trail."""
        return {
            "timestamp": self.timestamp,
            "jurisdiction": self.jurisdiction,
            **self.policy_scope,           # policy_jurisdiction, policy_regulator, policy_framework
            "score": self.score,
            "decision": self.decision,
            "requires_edd": self.requires_edd,
            "requires_mlro_review": self.requires_mlro_review,
            "hard_block_hit": self.hard_block_hit,
            "sanctions_hit": self.sanctions_hit,
            "crypto_risk": self.crypto_risk,
            "signal_count": len(self.signals),
            "rules_triggered": [s.rule for s in self.signals],
            "reasons": [s.reason for s in self.signals],
            "evidence_count": len(self.evidence),
            "evidence_types": [e.evidence_type for e in self.evidence],
            "evidence_sources": list({e.source for e in self.evidence}),
            **self.audit_payload,
        }


@dataclass
class CustomerProfile:
    """
    Customer risk context injected by BANXE backend into the AML orchestrator.

    Populated from KYC database / SumSub webhook / internal risk ledger.
    All fields are optional — absent fields are treated as lowest-risk value.
    """
    customer_id: str                  # internal BANXE UUID

    # KYC / risk rating
    risk_rating: str = "standard"     # standard / medium / high / unacceptable
    kyc_status: str = "verified"      # verified / pending / expired / failed

    # PEP
    is_pep: bool = False
    pep_category: str = ""            # domestic / foreign / io (intl org) / rca (relative/close assoc)

    # Prior AML activity
    prior_sars: int = 0               # count of prior SAR filings for this customer
    prior_holds: int = 0              # count of prior HOLD decisions

    # Jurisdictions
    nationality: str = ""             # ISO2
    residence_jurisdiction: str = ""  # ISO2

    # Account context
    account_age_days: int = 0
    flags: list[str] = field(default_factory=list)
    # e.g. ["new_account", "first_payment", "high_value_segment", "business_account"]


__all__ = [
    "TransactionInput",
    "SanctionsSubject",
    "WalletScreeningInput",
    "CustomerProfile",
    "RiskSignal",
    "EvidenceBundle",
    "AMLResult",
]
