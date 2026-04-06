"""
soul_governance.py — G-05 Governance Gate for CLASS_B/C changes.

Enforces that SOUL.md (and other high-risk files) cannot be auto-modified
by feedback_loop.py or protect-soul.sh without explicit human approval.

Change classification (from change_classes.yaml):
  CLASS A — auto-approved (AGENTS.md, docs)
  CLASS B — requires DEVELOPER | CTIO | CEO  (SOUL.md, openclaw.json)
  CLASS C — requires MLRO | CEO  (compliance_config.yaml, OPA policies)

Design:
  GovernanceGate.check_and_approve() → raises GovernanceError if gated
  GovernanceGate.record()            → always writes to append-only JSONL log
  Governance log: docs/governance/governance_log.jsonl (append-only, committed)

Usage (in feedback_loop.py):
    gate = GovernanceGate()
    req  = ChangeRequest(
        target_file   = "docs/SOUL.md",
        change_type   = "soul_update",
        proposed_by   = "feedback_loop",
        content_diff  = "...",
        approver_id   = args.approver,   # None → will raise for CLASS_B
        approver_role = args.approver_role,
        reason        = args.reason or "",
    )
    decision = gate.evaluate(req)   # raises GovernanceError if blocked

Usage (in protect-soul.sh via wrapper):
    python3 -m compliance.governance.soul_governance check --target docs/SOUL.md \\
        --approver mlro-001 --role MLRO --reason "quarterly SOUL update"
"""
from __future__ import annotations

import fnmatch
import json
import os
import sys
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

# ── Config path ───────────────────────────────────────────────────────────────
_HERE         = Path(__file__).parent
_CONFIG_PATH  = Path(os.environ.get(
    "CHANGE_CLASSES_PATH",
    str(_HERE / "change_classes.yaml"),
))
_VIBE_DIR     = Path(os.environ.get("VIBE_DIR", Path.home() / "vibe-coding"))
_GOV_LOG_PATH = Path(os.environ.get(
    "GOVERNANCE_LOG_PATH",
    str(_VIBE_DIR / "docs" / "governance" / "governance_log.jsonl"),
))

ChangeClass  = Literal["A", "B", "C"]
DecisionType = Literal["APPROVED", "REJECTED", "BLOCKED"]


# ── Exceptions ────────────────────────────────────────────────────────────────

class GovernanceError(RuntimeError):
    """
    Raised when a CLASS_B or CLASS_C change is attempted without the required
    human approver, or when the approver's role is not in the allowed list.

    Attributes:
        change_class  The class that blocked the change (B or C).
        target_file   The file that triggered the gate.
        required_roles List of roles that could have approved.
    """
    def __init__(
        self,
        target_file:    str,
        change_class:   ChangeClass,
        required_roles: list[str],
        message:        str,
    ) -> None:
        self.target_file    = target_file
        self.change_class   = change_class
        self.required_roles = required_roles
        super().__init__(message)


# ── Data classes ──────────────────────────────────────────────────────────────

@dataclass
class ChangeRequest:
    """
    Describes a proposed change to a governed file.

    Attributes:
        target_file    Repo-relative path (e.g. "docs/SOUL.md").
        change_type    Semantic type: "soul_update", "config_update", etc.
        proposed_by    Who / what is proposing the change ("feedback_loop", agent_id).
        content_diff   Short human-readable diff / description of the change.
        approver_id    Human approver identifier (None = no approval provided).
        approver_role  Role of the approver ("DEVELOPER", "MLRO", "CEO", "CTIO").
        reason         Reason for the change (required for CLASS_B/C).
        request_id     UUID, auto-generated.
        timestamp      ISO-8601 UTC, auto-generated.
    """
    target_file:    str
    change_type:    str
    proposed_by:    str
    content_diff:   str                 = ""
    approver_id:    str | None          = None
    approver_role:  str | None          = None
    reason:         str                 = ""
    request_id:     str                 = field(default_factory=lambda: str(uuid.uuid4()))
    timestamp:      str                 = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class GovernanceDecision:
    """
    Immutable record of a governance gate decision.

    Written to governance_log.jsonl (append-only).
    """
    request_id:     str
    target_file:    str
    change_class:   ChangeClass
    decision:       DecisionType
    approver_id:    str | None
    approver_role:  str | None
    reason:         str
    proposed_by:    str
    timestamp:      str                 = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )

    def to_dict(self) -> dict:
        return asdict(self)

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), ensure_ascii=False)


# ── Config loader ─────────────────────────────────────────────────────────────

def _load_config(path: Path | None = None) -> dict:
    """Load change_classes.yaml. Returns parsed dict."""
    import yaml  # type: ignore[import-untyped]
    config_path = path or _CONFIG_PATH
    with open(config_path) as f:
        return yaml.safe_load(f)


def _classify_target(target_file: str, config: dict) -> ChangeClass:
    """
    Return the most restrictive change class matching target_file.

    Precedence order: C > B > A.
    Unknown files default to CLASS_B (fail-safe).
    """
    classes      = config.get("change_classes", {})
    precedence   = config.get("precedence", ["C", "B", "A"])
    # Normalise: strip leading slash or ./
    normalised   = target_file.lstrip("/").lstrip("./")

    for cls in precedence:
        patterns = classes.get(cls, {}).get("target_patterns", [])
        for pat in patterns:
            if fnmatch.fnmatch(normalised, pat) or fnmatch.fnmatch(
                Path(normalised).name, pat
            ):
                return cls  # type: ignore[return-value]

    # Unknown target → fail-safe: CLASS_B
    return "B"


# ── GovernanceGate ────────────────────────────────────────────────────────────

class GovernanceGate:
    """
    Governance enforcement engine.

    Evaluates a ChangeRequest against change_classes.yaml and either:
      - Returns GovernanceDecision("APPROVED") for CLASS_A (auto-approved)
      - Returns GovernanceDecision("APPROVED") for B/C with valid approver+role
      - Raises GovernanceError for B/C without approver or wrong role
      - Always writes decision to governance_log.jsonl (append-only)

    Args:
        config_path      Override path to change_classes.yaml.
        log_path         Override path to governance_log.jsonl.
        dry_run          If True, evaluate but do NOT write to log (for tests).
    """

    def __init__(
        self,
        config_path: Path | str | None = None,
        log_path:    Path | str | None = None,
        dry_run:     bool              = False,
    ) -> None:
        self._config   = _load_config(Path(config_path) if config_path else None)
        self._log_path = Path(log_path) if log_path else _GOV_LOG_PATH
        self._dry_run  = dry_run

    # ── public API ────────────────────────────────────────────────────────────

    def classify(self, target_file: str) -> ChangeClass:
        """Return the change class for target_file."""
        return _classify_target(target_file, self._config)

    def evaluate(self, req: ChangeRequest) -> GovernanceDecision:
        """
        Evaluate a ChangeRequest.  Raises GovernanceError if blocked.
        Always writes the final decision to the governance log.

        Returns the GovernanceDecision (APPROVED).
        """
        cls        = self.classify(req.target_file)
        cls_config = self._config["change_classes"].get(cls, {})
        requires   = cls_config.get("requires_approver", False)
        allowed    = [r.upper() for r in cls_config.get("approver_roles", [])]

        # CLASS_A — auto-approve, record, return
        if not requires:
            decision = GovernanceDecision(
                request_id   = req.request_id,
                target_file  = req.target_file,
                change_class = cls,
                decision     = "APPROVED",
                approver_id  = "auto",
                approver_role= "CLASS_A",
                reason       = req.reason or "auto-approved (CLASS_A)",
                proposed_by  = req.proposed_by,
            )
            self._record(decision)
            return decision

        # CLASS_B or CLASS_C — require explicit human approver ────────────────

        # No approver provided
        if not req.approver_id:
            decision = GovernanceDecision(
                request_id   = req.request_id,
                target_file  = req.target_file,
                change_class = cls,
                decision     = "BLOCKED",
                approver_id  = None,
                approver_role= None,
                reason       = f"CLASS_{cls} change requires approver from: {allowed}",
                proposed_by  = req.proposed_by,
            )
            self._record(decision)
            raise GovernanceError(
                target_file    = req.target_file,
                change_class   = cls,
                required_roles = allowed,
                message        = (
                    f"CLASS_{cls} change to '{req.target_file}' requires human approval.\n"
                    f"Allowed roles: {', '.join(allowed)}\n"
                    f"Pass --approver <id> --approver-role <role> --reason '<text>'\n"
                    f"or call gate.evaluate() with approver_id set."
                ),
            )

        # Approver provided but role missing or wrong
        role_upper = (req.approver_role or "").upper()
        if allowed and role_upper not in allowed:
            decision = GovernanceDecision(
                request_id   = req.request_id,
                target_file  = req.target_file,
                change_class = cls,
                decision     = "REJECTED",
                approver_id  = req.approver_id,
                approver_role= req.approver_role,
                reason       = (
                    f"Role '{req.approver_role}' not authorised for CLASS_{cls}. "
                    f"Required: {allowed}"
                ),
                proposed_by  = req.proposed_by,
            )
            self._record(decision)
            raise GovernanceError(
                target_file    = req.target_file,
                change_class   = cls,
                required_roles = allowed,
                message        = (
                    f"Approver '{req.approver_id}' has role '{req.approver_role}' which is "
                    f"not authorised for CLASS_{cls} changes to '{req.target_file}'.\n"
                    f"Required roles: {', '.join(allowed)}"
                ),
            )

        # All checks passed — APPROVED
        decision = GovernanceDecision(
            request_id   = req.request_id,
            target_file  = req.target_file,
            change_class = cls,
            decision     = "APPROVED",
            approver_id  = req.approver_id,
            approver_role= req.approver_role or role_upper,
            reason       = req.reason or f"Approved by {req.approver_id}",
            proposed_by  = req.proposed_by,
        )
        self._record(decision)
        return decision

    # ── log ───────────────────────────────────────────────────────────────────

    def _record(self, decision: GovernanceDecision) -> None:
        """Append decision to governance_log.jsonl (append-only, create dirs)."""
        if self._dry_run:
            return
        self._log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self._log_path, "a") as f:
            f.write(decision.to_json() + "\n")

    def read_log(self, tail: int = 50) -> list[GovernanceDecision]:
        """Read last N decisions from the governance log."""
        if not self._log_path.exists():
            return []
        lines = self._log_path.read_text().splitlines()
        recent = lines[-tail:] if len(lines) > tail else lines
        result = []
        for line in recent:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
                result.append(GovernanceDecision(**d))
            except Exception:
                pass
        return result


# ── CLI wrapper (called from protect-soul.sh) ─────────────────────────────────

def _cli() -> None:
    """
    Minimal CLI for shell integration.

    Usage:
        python3 -m compliance.governance.soul_governance check \\
            --target docs/SOUL.md \\
            --approver mark-001 --role DEVELOPER \\
            --reason "update forbidden pattern"

    Exit codes:
        0  APPROVED
        1  BLOCKED / REJECTED (message to stderr)
        2  Usage error
    """
    import argparse

    parser = argparse.ArgumentParser(
        description="BANXE Governance Gate CLI",
        prog="soul_governance",
    )
    sub = parser.add_subparsers(dest="cmd")

    # check
    chk = sub.add_parser("check", help="Evaluate a change request")
    chk.add_argument("--target",   required=True, help="Repo-relative file path")
    chk.add_argument("--approver", default=None,  help="Approver ID")
    chk.add_argument("--role",     default=None,  help="Approver role")
    chk.add_argument("--reason",   default="",    help="Reason for change")
    chk.add_argument("--proposed-by", default="shell", help="Proposer ID")
    chk.add_argument("--dry-run",  action="store_true")

    # classify
    clf = sub.add_parser("classify", help="Show change class for a file")
    clf.add_argument("target", help="Repo-relative file path")

    args = parser.parse_args()

    if args.cmd == "classify":
        gate = GovernanceGate()
        print(f"CLASS_{gate.classify(args.target)}")
        return

    if args.cmd == "check":
        gate = GovernanceGate(dry_run=args.dry_run)
        req  = ChangeRequest(
            target_file   = args.target,
            change_type   = "shell_update",
            proposed_by   = args.proposed_by,
            approver_id   = args.approver,
            approver_role = args.role,
            reason        = args.reason,
        )
        try:
            decision = gate.evaluate(req)
            print(f"APPROVED  [{decision.change_class}]  {args.target}")
            print(f"  approver={decision.approver_id}  role={decision.approver_role}")
            print(f"  request_id={decision.request_id}")
            sys.exit(0)
        except GovernanceError as e:
            print(f"BLOCKED  {e}", file=sys.stderr)
            sys.exit(1)
        return

    parser.print_help()
    sys.exit(2)


if __name__ == "__main__":
    _cli()
