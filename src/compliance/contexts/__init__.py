"""
contexts/ — BANXE Bounded Context Registry (G-18)

Canonical source of truth for bounded context membership.
See also: banxe-architecture/domain/context-map.yaml

Each context is a Python dataclass with module lists, ports, and allowed deps.
The validate_contexts.py script uses this registry to enforce boundaries at CI time.

Contexts:
    CTX-01  Compliance / Decision Engine  (AMBER, core domain)
    CTX-02  Policy Context                (RED, supporting)
    CTX-03  Audit Context                 (RED, supporting)
    CTX-04  Operations Context            (GREEN, supporting)
    CTX-05  Agent Trust Context           (AMBER, generic subdomain)
"""
from .registry import CONTEXTS, BoundedContext, ContextId

__all__ = ["CONTEXTS", "BoundedContext", "ContextId"]
