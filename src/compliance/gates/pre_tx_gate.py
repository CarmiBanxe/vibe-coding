"""
pre_tx_gate.py — G-09 Redis Hot-Path Pre-Transaction Gate

Fast pre-screening layer before the full AML stack.
Executes 4 checks against Redis with a combined SLA of <80ms p99.

Checks (in order):
    1. EMERGENCY_STOP   — Redis KEY "banxe:emergency_stop" → BLOCK
    2. JURISDICTION     — Redis SET "banxe:blocked_jurisdictions" → BLOCK
    3. SANCTIONS_CACHE  — Redis SET "banxe:sanctions_hits" → BLOCK
    4. VELOCITY         — Redis ZSET "banxe:velocity:{customer_id}" (24h window) → ESCALATE

Fail-open design:
    Redis unavailable → ESCALATE (NOT BLOCK).
    Pre-tx gate must never block business due to infra failure.
    Full AML stack is the fallback for all ESCALATE decisions.

Integration point:
    result = gate.evaluate(tx)
    if result.decision == GateOutcome.BLOCK:
        return BanxeAMLResult(decision="REJECT", ...)
    if result.decision == GateOutcome.ESCALATE:
        # proceed to full AML + set requires_mlro_review=True
    # PASS → proceed normally

Closes: GAP-REGISTER G-09
Authority: SAMLA 2018, UK HMT Consolidated List, FATF
"""
from __future__ import annotations

import time
import threading
from dataclasses import dataclass, field
from typing import Any, Optional


# ── Outcome constants ─────────────────────────────────────────────────────────

class GateOutcome:
    PASS = "PASS"
    BLOCK = "BLOCK"
    ESCALATE = "ESCALATE"


# ── Redis key constants ───────────────────────────────────────────────────────

_KEY_EMERGENCY_STOP = "banxe:emergency_stop"
_KEY_BLOCKED_JURISDICTIONS = "banxe:blocked_jurisdictions"
_KEY_SANCTIONS_HITS = "banxe:sanctions_hits"
_KEY_VELOCITY_PREFIX = "banxe:velocity:"

_VELOCITY_WINDOW_SECONDS = 86400        # 24 hours
_VELOCITY_THRESHOLD_GBP = 25_000.0     # escalate above £25,000 / 24h
_SLA_WARNING_MS = 80.0                  # warn if total latency exceeds this


# ── Input / Output dataclasses ────────────────────────────────────────────────

@dataclass
class TransactionGateInput:
    """
    Minimal input for the pre-transaction gate.

    Fields:
        customer_id:              Unique customer identifier (for velocity tracking)
        origin_jurisdiction:      ISO2 origin country code
        destination_jurisdiction: ISO2 destination country code
        amount_gbp:               Transaction amount in GBP
        sanctions_subject_id:     Optional: entity ID to check against sanctions cache
    """
    customer_id: str
    origin_jurisdiction: str
    destination_jurisdiction: str
    amount_gbp: float
    sanctions_subject_id: str = ""


@dataclass(frozen=True)
class GateDecision:
    """
    Result from the pre-transaction gate.

    Fields:
        decision:    PASS | BLOCK | ESCALATE
        rule_id:     Identifier of the rule that fired (or "none" for PASS)
        latency_ms:  Total gate evaluation time in milliseconds
        reason:      Human-readable explanation
    """
    decision: str
    rule_id: str
    latency_ms: float
    reason: str

    @classmethod
    def pass_(cls, latency_ms: float) -> "GateDecision":
        return cls(
            decision=GateOutcome.PASS,
            rule_id="none",
            latency_ms=latency_ms,
            reason="All pre-transaction gate checks passed",
        )

    @classmethod
    def block(cls, rule_id: str, reason: str, latency_ms: float) -> "GateDecision":
        return cls(decision=GateOutcome.BLOCK, rule_id=rule_id, latency_ms=latency_ms, reason=reason)

    @classmethod
    def escalate(cls, rule_id: str, reason: str, latency_ms: float) -> "GateDecision":
        return cls(decision=GateOutcome.ESCALATE, rule_id=rule_id, latency_ms=latency_ms, reason=reason)


# ── InMemoryRedisStub ─────────────────────────────────────────────────────────

class InMemoryRedisStub:
    """
    Thread-safe in-memory stub implementing the Redis API subset used by PreTxGate.

    Supports: SET/GET/EXISTS/DELETE/EXPIRE/SADD/SISMEMBER/ZADD/ZRANGEBYSCORE/ZCARD
    Used in unit tests in place of a real Redis connection.
    """

    def __init__(self) -> None:
        self._data: dict[str, Any] = {}
        self._sets: dict[str, set] = {}
        self._zsets: dict[str, dict[str, float]] = {}   # key → {member: score}
        self._lock = threading.Lock()

    # ── String ops ────────────────────────────────────────────────────────────

    def set(self, key: str, value: str, ex: Optional[int] = None) -> None:
        with self._lock:
            self._data[key] = value

    def get(self, key: str) -> Optional[bytes]:
        with self._lock:
            v = self._data.get(key)
            return v.encode() if isinstance(v, str) else v

    def exists(self, key: str) -> int:
        with self._lock:
            return 1 if key in self._data else 0

    def delete(self, *keys: str) -> int:
        with self._lock:
            count = 0
            for key in keys:
                for store in (self._data, self._sets, self._zsets):
                    if key in store:
                        del store[key]
                        count += 1
            return count

    def expire(self, key: str, seconds: int) -> int:
        # Stub: TTL not enforced (tests control expiry explicitly)
        return 1 if (key in self._data or key in self._sets or key in self._zsets) else 0

    # ── Set ops ───────────────────────────────────────────────────────────────

    def sadd(self, key: str, *members: str) -> int:
        with self._lock:
            if key not in self._sets:
                self._sets[key] = set()
            before = len(self._sets[key])
            self._sets[key].update(members)
            return len(self._sets[key]) - before

    def sismember(self, key: str, member: str) -> bool:
        with self._lock:
            return member in self._sets.get(key, set())

    def smembers(self, key: str) -> set:
        with self._lock:
            return set(self._sets.get(key, set()))

    # ── Sorted set ops ────────────────────────────────────────────────────────

    def zadd(self, key: str, mapping: dict, **kwargs) -> int:
        with self._lock:
            if key not in self._zsets:
                self._zsets[key] = {}
            added = 0
            for member, score in mapping.items():
                if member not in self._zsets[key]:
                    added += 1
                self._zsets[key][member] = float(score)
            return added

    def zrangebyscore(self, key: str, min_score: float, max_score: float) -> list:
        with self._lock:
            zset = self._zsets.get(key, {})
            return [
                m for m, s in zset.items()
                if min_score <= s <= max_score
            ]

    def zremrangebyscore(self, key: str, min_score: float, max_score: float) -> int:
        with self._lock:
            zset = self._zsets.get(key, {})
            to_remove = [m for m, s in zset.items() if min_score <= s <= max_score]
            for m in to_remove:
                del zset[m]
            return len(to_remove)

    def zcard(self, key: str) -> int:
        with self._lock:
            return len(self._zsets.get(key, {}))

    def ping(self) -> bool:
        return True


# ── PreTxGate ─────────────────────────────────────────────────────────────────

class PreTxGate:
    """
    Redis-backed pre-transaction gate.

    Executes fast-path checks before the full AML orchestrator.
    Designed for <80ms p99 total latency.

    Usage:
        gate = PreTxGate(redis_client=redis.Redis())
        decision = gate.evaluate(tx)
        if decision.decision == GateOutcome.BLOCK:
            return BanxeAMLResult(decision="REJECT", ...)

    For tests: pass InMemoryRedisStub() as redis_client.
    """

    def __init__(self, redis_client=None) -> None:
        self._redis = redis_client
        self._logger = self._build_logger()

    @staticmethod
    def _build_logger():
        try:
            from compliance.utils.structured_logger import StructuredLogger
            return StructuredLogger("pre_tx_gate")
        except Exception:
            return None

    def _log(self, event_type: str, payload: dict) -> None:
        if self._logger is not None:
            try:
                self._logger.event(event_type=event_type, payload=payload)
            except Exception:
                pass

    # ── Main evaluation ───────────────────────────────────────────────────────

    def evaluate(self, tx: TransactionGateInput) -> GateDecision:
        """
        Run all 4 fast-path checks against Redis.

        Returns GateDecision with PASS / BLOCK / ESCALATE.
        Never raises — Redis errors → ESCALATE (fail-open).
        """
        t0 = time.perf_counter()

        try:
            # Check 1: Emergency stop (highest priority)
            if self._redis is not None and self._check_emergency_stop():
                return self._make_decision(
                    GateDecision.block("EMERGENCY_STOP",
                        "System emergency stop is active — all transactions blocked",
                        t0),
                    tx,
                )

            # Check 2: Hard-block jurisdiction
            blocked_j = self._check_jurisdiction(tx)
            if blocked_j:
                return self._make_decision(
                    GateDecision.block("JURISDICTION_BLOCK",
                        f"Transaction involves hard-block jurisdiction: {blocked_j} "
                        f"(SAMLA 2018 / UK HMT Consolidated List)",
                        t0),
                    tx,
                )

            # Check 3: Sanctions cache hit
            if tx.sanctions_subject_id and self._check_sanctions_cache(tx.sanctions_subject_id):
                return self._make_decision(
                    GateDecision.block("SANCTIONS_CACHE",
                        f"Entity '{tx.sanctions_subject_id}' matches cached sanctions hit. "
                        f"Full rescreening required before proceeding.",
                        t0),
                    tx,
                )

            # Check 4: Velocity breach
            breach = self._check_velocity(tx)
            if breach is not None:
                return self._make_decision(
                    GateDecision.escalate("VELOCITY_BREACH",
                        f"Velocity breach: 24h total £{breach:,.0f} + £{tx.amount_gbp:,.0f} "
                        f"exceeds £{_VELOCITY_THRESHOLD_GBP:,.0f} threshold. "
                        f"MLRO review required.",
                        t0),
                    tx,
                )

            # All checks passed — record velocity entry
            self._record_velocity(tx)

            latency_ms = (time.perf_counter() - t0) * 1000
            return self._make_decision(GateDecision.pass_(latency_ms), tx)

        except _RedisUnavailableError:
            latency_ms = (time.perf_counter() - t0) * 1000
            self._log("PRE_TX_GATE_REDIS_UNAVAILABLE", {
                "customer_id": tx.customer_id,
                "latency_ms": latency_ms,
            })
            return GateDecision.escalate(
                "REDIS_UNAVAILABLE",
                "Redis unavailable — escalating to full AML stack (fail-open)",
                latency_ms,
            )

    def _make_decision(self, decision: GateDecision, tx: TransactionGateInput) -> GateDecision:
        """Log decision and check SLA."""
        if decision.latency_ms > _SLA_WARNING_MS:
            self._log("PRE_TX_GATE_SLA_BREACH", {
                "latency_ms": decision.latency_ms,
                "threshold_ms": _SLA_WARNING_MS,
                "customer_id": tx.customer_id,
            })
        self._log("PRE_TX_GATE_DECISION", {
            "customer_id": tx.customer_id,
            "decision": decision.decision,
            "rule_id": decision.rule_id,
            "latency_ms": decision.latency_ms,
            "origin": tx.origin_jurisdiction,
            "destination": tx.destination_jurisdiction,
            "amount_gbp": tx.amount_gbp,
        })
        return decision

    # ── Individual checks ─────────────────────────────────────────────────────

    def _check_emergency_stop(self) -> bool:
        try:
            return bool(self._redis.exists(_KEY_EMERGENCY_STOP))
        except Exception as e:
            raise _RedisUnavailableError(str(e)) from e

    def _check_jurisdiction(self, tx: TransactionGateInput) -> Optional[str]:
        """Returns the blocked jurisdiction code, or None if clean."""
        try:
            for jurisdiction in (tx.origin_jurisdiction, tx.destination_jurisdiction):
                if not jurisdiction:
                    continue
                if self._redis is not None and self._redis.sismember(
                    _KEY_BLOCKED_JURISDICTIONS, jurisdiction.upper()
                ):
                    return jurisdiction.upper()
            return None
        except Exception as e:
            raise _RedisUnavailableError(str(e)) from e

    def _check_sanctions_cache(self, subject_id: str) -> bool:
        try:
            return bool(self._redis.sismember(_KEY_SANCTIONS_HITS, subject_id))
        except Exception as e:
            raise _RedisUnavailableError(str(e)) from e

    def _check_velocity(self, tx: TransactionGateInput) -> Optional[float]:
        """
        Returns the current 24h rolling total (before adding current tx) if breach,
        or None if under threshold.
        """
        if not tx.customer_id or tx.amount_gbp <= 0:
            return None
        try:
            key = f"{_KEY_VELOCITY_PREFIX}{tx.customer_id}"
            now = time.time()
            window_start = now - _VELOCITY_WINDOW_SECONDS

            # Clean up expired entries first
            self._redis.zremrangebyscore(key, 0, window_start)

            # Sum existing entries in the window (member format: "{amount}:{timestamp}")
            entries = self._redis.zrangebyscore(key, window_start, now)
            existing_total = sum(
                float(e.split(":")[0]) if isinstance(e, str) and ":" in e else float(e)
                for e in entries
            )

            if existing_total + tx.amount_gbp > _VELOCITY_THRESHOLD_GBP:
                return existing_total
            return None
        except Exception as e:
            raise _RedisUnavailableError(str(e)) from e

    def _record_velocity(self, tx: TransactionGateInput) -> None:
        """Record this transaction in the velocity sorted set."""
        if not tx.customer_id or tx.amount_gbp <= 0 or self._redis is None:
            return
        try:
            key = f"{_KEY_VELOCITY_PREFIX}{tx.customer_id}"
            now = time.time()
            # Use amount as member value (suffixed with timestamp for uniqueness)
            member = f"{tx.amount_gbp}:{now}"
            self._redis.zadd(key, {member: now})
            self._redis.expire(key, _VELOCITY_WINDOW_SECONDS + 60)
        except Exception:
            pass  # velocity recording failure is non-blocking

    # ── Warm-up / sync helpers ────────────────────────────────────────────────

    def sync_blocked_jurisdictions(
        self,
        jurisdictions: Optional[list[str]] = None,
    ) -> int:
        """
        Load hard-block jurisdictions into Redis SET.

        Args:
            jurisdictions: Override list. If None, loads from compliance_config.yaml.

        Returns:
            Number of entries loaded into Redis.
        """
        if jurisdictions is None:
            jurisdictions = self._load_jurisdictions_from_config()

        if not jurisdictions or self._redis is None:
            return 0

        count = self._redis.sadd(_KEY_BLOCKED_JURISDICTIONS, *[j.upper() for j in jurisdictions])
        self._log("PRE_TX_GATE_JURISDICTIONS_SYNCED", {
            "count": len(jurisdictions),
            "jurisdictions": jurisdictions,
        })
        return len(jurisdictions)

    @staticmethod
    def _load_jurisdictions_from_config() -> list[str]:
        """Read hard_block list from compliance_config.yaml."""
        try:
            from compliance.utils.config_loader import load_config
            config = load_config()
            return config.get("jurisdictions", {}).get("hard_block", [])
        except Exception:
            # Fallback to canonical list if config unavailable
            return ["RU", "BY", "IR", "KP", "CU", "MM", "AF", "VE", "CRIMEA", "DNR", "LNR"]

    def sync_sanctions_cache(self, entity_ids: list[str]) -> int:
        """
        Populate the sanctions cache with confirmed hit entity IDs.
        Called from sanctions_check.py after a confirmed match.

        Args:
            entity_ids: List of entity IDs confirmed as sanctions hits.

        Returns:
            Number of IDs added.
        """
        if not entity_ids or self._redis is None:
            return 0
        return self._redis.sadd(_KEY_SANCTIONS_HITS, *entity_ids)


# ── Internal sentinel ─────────────────────────────────────────────────────────

class _RedisUnavailableError(Exception):
    """Internal: raised when Redis call fails, triggers fail-open ESCALATE."""
