"""
test_hooks.py — G-21 Claude Code Hooks Tests

Tests hook scripts by simulating Claude Code stdin payloads.
All hooks are invoked as subprocesses with synthetic JSON on stdin.

T-01  settings.json is valid JSON and contains required hook events
T-02  settings.json has PreToolUse hook for Edit|Write
T-03  settings.json has PostToolUse with invariant_check + bounded_context_check
T-04  settings.json has UserPromptSubmit hook
T-05  All 4 hook scripts exist and are valid Python syntax
T-06  policy_guard: SOUL.md edit is BLOCKED (exit 2)
T-07  policy_guard: AGENTS.md edit is allowed (exit 0)
T-08  policy_guard: compliance_config.yaml edit is BLOCKED (exit 2, CLASS_C)
T-09  policy_guard: banxe_compliance.rego edit is BLOCKED (exit 2, CLASS_C)
T-10  policy_guard: .py file edit is allowed (exit 0)
T-11  policy_guard: GOVERNANCE_BYPASS=1 allows SOUL.md edit
T-12  policy_guard: missing file_path is allowed (exit 0)
T-13  policy_guard: openclaw.json is BLOCKED (exit 2, CLASS_B)
T-14  policy_guard: IDENTITY.md is BLOCKED (exit 2, CLASS_B)
T-15  policy_guard: BOOTSTRAP.md is BLOCKED (exit 2, CLASS_B)
T-16  policy_guard: CLASS_B output mentions governance path
T-17  policy_guard: CLASS_C output mentions MLRO
T-18  invariant_check: non-compliance file is silent (exit 0)
T-19  invariant_check: malformed JSON is fail-open (exit 0)
T-20  invariant_check: empty file_path is silent (exit 0)
T-21  bounded_context_check: non-.py file is silent (exit 0)
T-22  bounded_context_check: agents/ importing engine warns BC-01
T-23  bounded_context_check: event_sourcing/ importing orchestrator warns BC-02
T-24  bounded_context_check: governance/ importing agents/ warns BC-03
T-25  bounded_context_check: test file importing Postgres adapter warns BC-04
T-26  bounded_context_check: clean py file is silent (exit 0)
T-27  load_architecture: unrelated prompt is silent (exit 0)
T-28  load_architecture: "gap" in prompt outputs summary
T-29  load_architecture: "invariant" in prompt outputs summary
T-30  load_architecture: "architecture" in prompt outputs summary
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

# ── Paths ──────────────────────────────────────────────────────────────────────
_BASE      = Path(__file__).parent
_SRC       = _BASE.parent
_VIBE_ROOT = _SRC.parent
_HOOKS_DIR = _VIBE_ROOT / ".claude" / "hooks"
_SETTINGS  = _VIBE_ROOT / ".claude" / "settings.json"

sys.path.insert(0, str(_SRC))
sys.path.insert(0, str(_BASE))


# ── Helpers ───────────────────────────────────────────────────────────────────

def _run_hook(
    script: str,
    payload: dict,
    env_extra: dict | None = None,
) -> tuple[int, str, str]:
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    result = subprocess.run(
        [sys.executable, str(_HOOKS_DIR / script)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        cwd=str(_VIBE_ROOT),
    )
    return result.returncode, result.stdout, result.stderr


def _edit(path: str) -> dict:
    return {"session_id": "t", "tool_name": "Edit",
            "tool_input": {"file_path": path, "old_string": "x", "new_string": "y"}}


def _post(path: str) -> dict:
    return {"session_id": "t", "tool_name": "Edit",
            "tool_input": {"file_path": path}, "tool_response": {}}


def _prompt(text: str) -> dict:
    return {"session_id": "t", "prompt": text}


# ── T-01..T-05: settings.json ─────────────────────────────────────────────────

def test_T01_settings_json_valid():
    assert _SETTINGS.exists()
    cfg = json.loads(_SETTINGS.read_text())
    assert "hooks" in cfg


def test_T02_pretooluse_edit_write():
    cfg      = json.loads(_SETTINGS.read_text())
    matchers = [h.get("matcher", "") for h in cfg["hooks"].get("PreToolUse", [])]
    assert any("Edit" in m and "Write" in m for m in matchers)


def test_T03_posttooluse_two_hooks():
    cfg   = json.loads(_SETTINGS.read_text())
    cmds  = [
        h.get("command", "")
        for entry in cfg["hooks"].get("PostToolUse", [])
        for h in entry.get("hooks", [])
    ]
    assert any("invariant_check"       in c for c in cmds)
    assert any("bounded_context_check" in c for c in cmds)


def test_T04_userpromptsubmit_hook():
    cfg  = json.loads(_SETTINGS.read_text())
    cmds = [
        h.get("command", "")
        for entry in cfg["hooks"].get("UserPromptSubmit", [])
        for h in entry.get("hooks", [])
    ]
    assert any("load_architecture" in c for c in cmds)


def test_T05_hook_scripts_exist_and_valid_syntax():
    for name in ("policy_guard.py", "invariant_check.py",
                 "bounded_context_check.py", "load_architecture.py"):
        path = _HOOKS_DIR / name
        assert path.exists(), f"Missing: {path}"
        r = subprocess.run([sys.executable, "-m", "py_compile", str(path)],
                           capture_output=True)
        assert r.returncode == 0, f"Syntax error in {name}"


# ── T-06..T-17: policy_guard.py ──────────────────────────────────────────────

def test_T06_soul_md_blocked():
    rc, out, _ = _run_hook("policy_guard.py", _edit("/vibe-coding/docs/SOUL.md"))
    assert rc == 2 and "BLOCKED" in out


def test_T07_agents_md_allowed():
    rc, out, _ = _run_hook("policy_guard.py", _edit("/vibe-coding/agents/AGENTS.md"))
    assert rc == 0 and out.strip() == ""


def test_T08_compliance_config_blocked_class_c():
    rc, out, _ = _run_hook("policy_guard.py", _edit("/src/compliance/compliance_config.yaml"))
    assert rc == 2 and "CLASS_C" in out


def test_T09_rego_blocked_class_c():
    rc, out, _ = _run_hook("policy_guard.py", _edit("/src/compliance/policies/banxe_compliance.rego"))
    assert rc == 2 and "CLASS_C" in out


def test_T10_py_file_allowed():
    rc, out, _ = _run_hook("policy_guard.py", _edit("/src/compliance/banxe_aml_orchestrator.py"))
    assert rc == 0 and out.strip() == ""


def test_T11_governance_bypass_allows_soul():
    rc, _, _ = _run_hook("policy_guard.py", _edit("/docs/SOUL.md"),
                         env_extra={"GOVERNANCE_BYPASS": "1"})
    assert rc == 0


def test_T12_missing_file_path_allowed():
    rc, _, _ = _run_hook("policy_guard.py",
                         {"session_id": "t", "tool_name": "Edit", "tool_input": {}})
    assert rc == 0


def test_T13_openclaw_json_blocked():
    rc, out, _ = _run_hook("policy_guard.py", _edit("/root/.openclaw-moa/.openclaw/openclaw.json"))
    assert rc == 2 and "CLASS_B" in out


def test_T14_identity_md_blocked():
    rc, out, _ = _run_hook("policy_guard.py", _edit("/workspace/IDENTITY.md"))
    assert rc == 2 and "BLOCKED" in out


def test_T15_bootstrap_md_blocked():
    rc, out, _ = _run_hook("policy_guard.py", _edit("/workspace/BOOTSTRAP.md"))
    assert rc == 2


def test_T16_class_b_output_has_governance_path():
    _, out, _ = _run_hook("policy_guard.py", _edit("/docs/SOUL.md"))
    assert "protect-soul.sh" in out or "governance" in out.lower()


def test_T17_class_c_output_mentions_mlro():
    _, out, _ = _run_hook("policy_guard.py", _edit("/src/compliance/compliance_config.yaml"))
    assert "MLRO" in out


# ── T-18..T-20: invariant_check.py ───────────────────────────────────────────

def test_T18_non_compliance_file_silent():
    rc, out, _ = _run_hook("invariant_check.py", _post("/home/user/README.md"))
    assert rc == 0 and out.strip() == ""


def test_T19_malformed_json_fail_open():
    r = subprocess.run([sys.executable, str(_HOOKS_DIR / "invariant_check.py")],
                       input="NOT JSON", capture_output=True, text=True,
                       cwd=str(_VIBE_ROOT))
    assert r.returncode == 0


def test_T20_empty_file_path_silent():
    rc, out, _ = _run_hook("invariant_check.py", _post(""))
    assert rc == 0 and out.strip() == ""


# ── T-21..T-26: bounded_context_check.py ─────────────────────────────────────

def test_T21_non_py_silent():
    rc, out, _ = _run_hook("bounded_context_check.py", _post("/docs/README.md"))
    assert rc == 0 and out.strip() == ""


def _tmp_py(content: str, directory: Path, prefix: str = "tmp_") -> Path:
    f = tempfile.NamedTemporaryFile(
        prefix=prefix, suffix=".py", mode="w",
        delete=False, dir=str(directory)
    )
    f.write(content)
    f.close()
    return Path(f.name)


def test_T22_agents_importing_engine_warns():
    tmp = _tmp_py(
        "from compliance.tx_monitor import assess\n",
        _VIBE_ROOT / "src" / "compliance" / "agents",
    )
    try:
        rc, out, _ = _run_hook("bounded_context_check.py", _post(str(tmp)))
        assert rc == 0 and "BC-01" in out
    finally:
        tmp.unlink()


def test_T23_event_sourcing_importing_orchestrator_warns():
    tmp = _tmp_py(
        "from compliance.banxe_aml_orchestrator import banxe_assess\n",
        _VIBE_ROOT / "src" / "compliance" / "event_sourcing",
    )
    try:
        rc, out, _ = _run_hook("bounded_context_check.py", _post(str(tmp)))
        assert rc == 0 and "BC-02" in out
    finally:
        tmp.unlink()


def test_T24_governance_importing_agents_warns():
    tmp = _tmp_py(
        "from compliance.agents.orchestration_tree import OrchestrationTree\n",
        _VIBE_ROOT / "src" / "compliance" / "governance",
    )
    try:
        rc, out, _ = _run_hook("bounded_context_check.py", _post(str(tmp)))
        assert rc == 0 and "BC-03" in out
    finally:
        tmp.unlink()


def test_T25_test_importing_postgres_warns():
    tmp = _tmp_py(
        "from compliance.utils.decision_event_log import PostgresEventLogAdapter\n",
        _VIBE_ROOT / "src" / "compliance",
        prefix="test_tmp_",
    )
    try:
        rc, out, _ = _run_hook("bounded_context_check.py", _post(str(tmp)))
        assert rc == 0 and "BC-04" in out
    finally:
        tmp.unlink()


def test_T26_clean_py_silent():
    tmp = _tmp_py("x = 1\n", _VIBE_ROOT / "src" / "compliance")
    try:
        rc, out, _ = _run_hook("bounded_context_check.py", _post(str(tmp)))
        assert rc == 0 and out.strip() == ""
    finally:
        tmp.unlink()


# ── T-27..T-30: load_architecture.py ─────────────────────────────────────────

def test_T27_unrelated_prompt_silent():
    rc, out, _ = _run_hook("load_architecture.py", _prompt("what's for lunch?"))
    assert rc == 0 and out.strip() == ""


def test_T28_gap_in_prompt_outputs_summary():
    rc, out, _ = _run_hook("load_architecture.py", _prompt("show me the gap register"))
    assert rc == 0 and "BANXE ARCH" in out


def test_T29_invariant_in_prompt_outputs_summary():
    rc, out, _ = _run_hook("load_architecture.py", _prompt("which invariant covers SOUL.md?"))
    assert rc == 0 and "BANXE ARCH" in out


def test_T30_architecture_in_prompt_outputs_summary():
    rc, out, _ = _run_hook("load_architecture.py", _prompt("explain the architecture"))
    assert rc == 0 and "BANXE ARCH" in out and ("294" in out or "tests" in out)
