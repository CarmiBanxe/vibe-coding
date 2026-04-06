"""
PolicyPort — read-only access to the BANXE policy layer.

Part of Hexagonal Architecture (G-16, SPRINT-0-PLAN.md §1.1).

Design contract:
  - Read-only interface: NO methods that mutate policy.
  - Invariant I-22: Level-2 agents access policy only through this port.
    A Level-2 agent holding a PolicyPort reference can READ, never WRITE.
  - Adapters must never expose a write path.

Adapters (in adapters/):
  ComplianceConfigPolicyAdapter — backed by compliance_config.yaml (G-07)
  InMemoryPolicyAdapter         — for tests and local dev

Invariant I-22: Level 2 agent cannot write to policy layer.
Authority: NCC Group Orchestration Tree, GAP-REGISTER G-04, G-16.
"""
from __future__ import annotations

from abc import ABC, abstractmethod


class PolicyPort(ABC):
    """
    Read-only access to the BANXE policy layer.

    Provides thresholds, jurisdiction classifications, and forbidden patterns
    to any consumer that holds a PolicyPort reference, without exposing
    the underlying storage (YAML, SOUL.md, database, etc.).

    Invariant I-22: Level-2 agents use ONLY this interface to read policy.
    Any adapter that exposes a write method violates I-22 and must be rejected.
    """

    @abstractmethod
    def get_forbidden_patterns(self) -> list[str]:
        """
        Return the list of red-line regex patterns agents MUST NOT emit.
        Authority: FCA MLR 2017 §3.
        """
        ...

    @abstractmethod
    def get_threshold(self, name: str) -> float:
        """
        Return a named decision threshold.

        Known names:
          "sar"                         → 85  (auto-SAR obligation)
          "reject"                      → 70  (transaction block)
          "hold"                        → 40  (EDD required)
          "watchman_min_match"          → 0.80
          "mlr_reporting_threshold_gbp" → 10000
        """
        ...

    @abstractmethod
    def get_jurisdiction_class(self, iso_code: str) -> str:
        """
        Return the jurisdiction risk classification for the given ISO-2 code.

        Returns:
          "A"        — hard block (Category A: SAMLA 2018, OFAC, HMT)
          "B"        — high risk, EDD required (Category B: FATF)
          "STANDARD" — no special classification
        """
        ...

    # ── Intentionally absent (I-22) ──────────────────────────────────────────
    # def set_threshold(...)         — FORBIDDEN
    # def add_jurisdiction(...)      — FORBIDDEN
    # def update_forbidden(...)      — FORBIDDEN
