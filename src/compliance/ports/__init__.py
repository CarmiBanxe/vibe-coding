"""
ports — BANXE Hexagonal Architecture port interfaces (G-16).

All four ABCs live here. Import from this package for clean dependency injection:

    from compliance.ports import AuditPort, PolicyPort, DecisionPort, EmergencyPort

Adapters live in compliance.adapters.*
"""
from compliance.ports.audit_port     import AuditPort
from compliance.ports.policy_port    import PolicyPort
from compliance.ports.decision_port  import DecisionPort
from compliance.ports.emergency_port import EmergencyPort

__all__ = ["AuditPort", "PolicyPort", "DecisionPort", "EmergencyPort"]
