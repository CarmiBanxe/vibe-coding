"""
gates/ — G-09 Pre-Transaction Gate (Redis hot-path)

Fast-path pre-screening before full AML stack.
SLA: <80ms p99. Fail-open (ESCALATE) when Redis unavailable.
"""
from .pre_tx_gate import (
    PreTxGate,
    GateDecision,
    GateOutcome,
    TransactionGateInput,
    InMemoryRedisStub,
)

__all__ = [
    "PreTxGate",
    "GateDecision",
    "GateOutcome",
    "TransactionGateInput",
    "InMemoryRedisStub",
]
