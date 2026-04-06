"""
BANXE Policy Agent — Layer 2 (Product)
Verifies alignment with BANXE platform tariffs, limits, and product rules.
Authority: BANXE Product Policy (internal), FCA EMI authorisation scope
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from typing import Optional


class Verdict(str, Enum):
    CONFIRMED = "CONFIRMED"
    REFUTED = "REFUTED"
    UNCERTAIN = "UNCERTAIN"


@dataclass
class VerificationResult:
    verdict: Verdict
    rule: Optional[str]
    reason: str
    confidence: float


# BANXE Platform limits (source of truth — update requires CEO approval)
BANXE_LIMITS = {
    "single_transfer_max_gbp": 50_000,
    "daily_transfer_max_gbp": 100_000,
    "monthly_transfer_max_gbp": 500_000,
    "kyc_basic_max_gbp": 1_000,      # before full KYC
    "kyc_enhanced_max_gbp": 10_000,  # before EDD
    "min_transfer_gbp": 1,
}

# BANXE supported currencies (EMI scope)
SUPPORTED_CURRENCIES = {"GBP", "EUR", "USD", "PLN", "RON", "HUF", "CZK"}

# GUIYON is categorically excluded from Banxe (COMPLIANCE_ARCH invariant §6)
EXCLUDED_ENTITIES = {"guiyon", "guiyon.ai", "port 18794"}

# Products BANXE offers
BANXE_PRODUCTS = {
    "current_account", "savings_account", "debit_card", "virtual_card",
    "sepa_transfer", "swift_transfer", "faster_payments", "crypto_exchange",
    "business_account", "multi_currency_wallet"
}


def verify(statement: str, context: dict | None = None) -> VerificationResult:
    """
    Verify that the agent's statement matches BANXE platform policy.
    """
    text = statement.lower()
    context = context or {}

    # --- GUIYON exclusion (hard invariant) ---
    for entity in EXCLUDED_ENTITIES:
        if entity in text:
            return VerificationResult(
                verdict=Verdict.REFUTED,
                rule="COMPLIANCE_ARCH.md §6 — GUIYON Exclusion",
                reason=f"Statement references GUIYON which is categorically excluded from BANXE",
                confidence=1.0,
            )

    # --- Out-of-scope product check (EMI scope — must be FIRST before amount checks) ---
    out_of_scope = _detect_out_of_scope_products(text)
    if out_of_scope:
        return VerificationResult(
            verdict=Verdict.REFUTED,
            rule="BANXE EMI Authorisation Scope",
            reason=f"BANXE (EMI) does not offer '{out_of_scope}' — outside FCA EMI authorisation scope",
            confidence=0.90,
        )

    # --- Currency check ---
    # Abbreviations that are not currencies
    NON_CURRENCY_ABBREVS = {
        "KYC", "AML", "EDD", "SAR", "PEP", "SDN", "FCA", "NCA", "EMI",
        "UBO", "PSC", "MLR", "CDD", "SDD", "JMLSG", "OFAC", "HMT",
        "TIN", "DOB", "POA", "MRZ", "API", "URL", "IDD", "EEA", "UK",
        "EU", "UN", "PCI", "DSS", "ISO", "IVS", "TTV", "HITL", "RLHF",
        "VIP", "CEO", "CFO", "COO", "CTO", "SME", "SLA", "KPI", "OTP",
        "SMS", "MFA", "SSN", "DOC", "PDF", "ETA", "ETD", "STP", "ACH",
    }
    mentioned_currencies = re.findall(r'\b([A-Z]{3})\b', statement)
    for currency in mentioned_currencies:
        if currency not in SUPPORTED_CURRENCIES and currency not in NON_CURRENCY_ABBREVS:
            return VerificationResult(
                verdict=Verdict.UNCERTAIN,
                rule="BANXE EMI Scope — Supported Currencies",
                reason=f"Currency '{currency}' not in BANXE supported currencies: {SUPPORTED_CURRENCIES}",
                confidence=0.75,
            )

    # --- Limit check (extract numbers from statement) ---
    amounts = re.findall(r'£([\d,]+)', statement)
    for amount_str in amounts:
        amount = int(amount_str.replace(",", ""))
        if amount > BANXE_LIMITS["single_transfer_max_gbp"]:
            if "hold" not in text and "reject" not in text and "edd" not in text:
                return VerificationResult(
                    verdict=Verdict.REFUTED,
                    rule="BANXE Transfer Limits Policy",
                    reason=f"Amount £{amount:,} exceeds single transfer limit £{BANXE_LIMITS['single_transfer_max_gbp']:,} without HOLD/REJECT",
                    confidence=0.88,
                )

    # --- KYC tier check ---
    if _mentions_large_amount_without_kyc(text):
        return VerificationResult(
            verdict=Verdict.REFUTED,
            rule="BANXE KYC Policy — Tiered Limits",
            reason="Large amount referenced without full KYC verification mention",
            confidence=0.82,
        )

    return VerificationResult(
        verdict=Verdict.CONFIRMED,
        rule=None,
        reason="Statement aligns with BANXE platform policy and limits",
        confidence=0.80,
    )


def _mentions_large_amount_without_kyc(text: str) -> bool:
    amounts = re.findall(r'£([\d,]+)', text)
    for amount_str in amounts:
        amount = int(amount_str.replace(",", ""))
        if amount > BANXE_LIMITS["kyc_basic_max_gbp"]:
            kyc_keywords = ["kyc", "verified", "identity", "edd", "hitl",
                            "enhanced due diligence", "compliance officer", "manual review"]
            if not any(k in text for k in kyc_keywords):
                return True
    return False


def _detect_out_of_scope_products(text: str) -> str | None:
    out_of_scope_keywords = [
        "insurance", "lending", "mortgage", "loan", "credit",
        "investment advice", "wealth management", "pension"
    ]
    for keyword in out_of_scope_keywords:
        if keyword in text:
            return keyword
    return None


if __name__ == "__main__":
    import sys
    statement = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Customer wants to transfer £75,000 immediately."
    result = verify(statement)
    print(f"Verdict:    {result.verdict.value}")
    print(f"Rule:       {result.rule or '—'}")
    print(f"Reason:     {result.reason}")
    print(f"Confidence: {result.confidence:.2f}")
