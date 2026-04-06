"""
test_policy_drift.py — G-08 Policy Drift Detection Tests

T-01  --verify returns 0 when baseline matches current files
T-02  --verify returns 2 when no baseline exists
T-03  --update creates/updates policy_checksums.json
T-04  --update records updated_at timestamp
T-05  --update handles missing files gracefully (records in "missing")
T-06  --verify returns 1 when a file is modified
T-07  --verify output reports MODIFIED with both hash prefixes
T-08  --verify returns 1 when a tracked file is deleted
T-09  --verify output reports DELETED file
T-10  --show prints current hashes without modifying baseline
T-11  --show prints <missing> for non-existent files
T-12  policy_checksums.json is valid JSON after --update
T-13  policy_checksums.json contains all 5 tracked keys
T-14  cmd_verify exits 0 after --update when files unchanged
T-15  --update is idempotent (double run, same checksums)
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import sys as _sys
import pytest

_VIBE_ROOT = Path(__file__).parent.parent.parent
# Ensure src/ is on the path so `import compliance.validators.*` works from within pytest
if str(_VIBE_ROOT / "src") not in _sys.path:
    _sys.path.insert(0, str(_VIBE_ROOT / "src"))
_VALIDATOR  = _VIBE_ROOT / "src" / "compliance" / "validators" / "policy_drift_check.py"
_BASELINE   = _VIBE_ROOT / "src" / "compliance" / "validators" / "policy_checksums.json"


def _run(*args: str) -> tuple[int, str, str]:
    r = subprocess.run(
        [sys.executable, str(_VALIDATOR)] + list(args),
        capture_output=True, text=True, cwd=str(_VIBE_ROOT),
    )
    return r.returncode, r.stdout, r.stderr


# ── T-01: baseline matches ────────────────────────────────────────────────────

def test_T01_verify_ok_when_baseline_matches():
    # Ensure baseline exists
    rc, _, _ = _run("--update")
    assert rc == 0
    rc, out, _ = _run("--verify")
    assert rc == 0
    assert "OK" in out


# ── T-02: no baseline ─────────────────────────────────────────────────────────

def test_T02_verify_returns_2_when_no_baseline(tmp_path):
    """Move baseline away and verify returns exit 2."""
    backup = tmp_path / "backup.json"
    if _BASELINE.exists():
        shutil.copy(_BASELINE, backup)
    try:
        _BASELINE.unlink(missing_ok=True)
        rc, _, err = _run("--verify")
        assert rc == 2
        assert "baseline" in err.lower() or "No baseline" in err
    finally:
        if backup.exists():
            shutil.copy(backup, _BASELINE)


# ── T-03: --update creates file ───────────────────────────────────────────────

def test_T03_update_creates_baseline():
    _BASELINE.unlink(missing_ok=True)
    rc, out, _ = _run("--update")
    assert rc == 0
    assert _BASELINE.exists()


# ── T-04: --update records timestamp ─────────────────────────────────────────

def test_T04_update_records_timestamp():
    _run("--update")
    data = json.loads(_BASELINE.read_text())
    assert "updated_at" in data
    assert "T" in data["updated_at"]  # ISO format


# ── T-05: missing files in baseline ──────────────────────────────────────────

def test_T05_update_handles_missing_files(monkeypatch, tmp_path):
    """Patch _POLICY_FILES to include a non-existent file."""
    import compliance.validators.policy_drift_check as mod
    orig = dict(mod._POLICY_FILES)
    mod._POLICY_FILES["fake/nonexistent.md"] = tmp_path / "nonexistent.md"
    try:
        rc, out, _ = mod.cmd_update(), "", ""
        data = json.loads(_BASELINE.read_text())
        assert "fake/nonexistent.md" in data.get("missing", [])
    finally:
        mod._POLICY_FILES.clear()
        mod._POLICY_FILES.update(orig)
        _run("--update")  # restore clean baseline


# ── T-06: modified file detected ─────────────────────────────────────────────

def test_T06_verify_returns_1_when_file_modified(tmp_path):
    """Create a temp file, add it to policy files, update baseline, then modify."""
    import compliance.validators.policy_drift_check as mod

    tf = tmp_path / "test_policy.md"
    tf.write_text("original content")
    orig_baseline = _BASELINE.read_bytes() if _BASELINE.exists() else b""

    orig_files = dict(mod._POLICY_FILES)
    mod._POLICY_FILES["test/test_policy.md"] = tf
    tmp_baseline = tmp_path / "checksums.json"
    orig_bf = mod._BASELINE_FILE
    mod._BASELINE_FILE = tmp_baseline

    try:
        mod.cmd_update()
        tf.write_text("modified content")
        rc = mod.cmd_verify()
        assert rc == 1
    finally:
        mod._POLICY_FILES.clear()
        mod._POLICY_FILES.update(orig_files)
        mod._BASELINE_FILE = orig_bf
        # Restore original baseline
        if orig_baseline:
            _BASELINE.write_bytes(orig_baseline)


# ── T-07: MODIFIED in output ──────────────────────────────────────────────────

def test_T07_modified_file_shows_in_output(tmp_path, capsys):
    import compliance.validators.policy_drift_check as mod

    tf = tmp_path / "tracked.md"
    tf.write_text("v1")
    tmp_baseline = tmp_path / "checksums.json"
    orig_files, orig_bf = dict(mod._POLICY_FILES), mod._BASELINE_FILE
    mod._POLICY_FILES = {"test/tracked.md": tf}
    mod._BASELINE_FILE = tmp_baseline

    try:
        mod.cmd_update()
        tf.write_text("v2 — different")
        mod.cmd_verify()
        captured = capsys.readouterr()
        assert "MODIFIED" in captured.out
        assert "test/tracked.md" in captured.out
    finally:
        mod._POLICY_FILES = orig_files
        mod._BASELINE_FILE = orig_bf


# ── T-08: deleted file detected ──────────────────────────────────────────────

def test_T08_verify_returns_1_when_file_deleted(tmp_path):
    import compliance.validators.policy_drift_check as mod

    tf = tmp_path / "will_be_deleted.md"
    tf.write_text("exists")
    tmp_baseline = tmp_path / "checksums.json"
    orig_files, orig_bf = dict(mod._POLICY_FILES), mod._BASELINE_FILE
    mod._POLICY_FILES = {"test/will_be_deleted.md": tf}
    mod._BASELINE_FILE = tmp_baseline

    try:
        mod.cmd_update()
        tf.unlink()
        rc = mod.cmd_verify()
        assert rc == 1
    finally:
        mod._POLICY_FILES = orig_files
        mod._BASELINE_FILE = orig_bf


# ── T-09: DELETED in output ───────────────────────────────────────────────────

def test_T09_deleted_file_shows_in_output(tmp_path, capsys):
    import compliance.validators.policy_drift_check as mod

    tf = tmp_path / "deleted.md"
    tf.write_text("content")
    tmp_baseline = tmp_path / "checksums.json"
    orig_files, orig_bf = dict(mod._POLICY_FILES), mod._BASELINE_FILE
    mod._POLICY_FILES = {"test/deleted.md": tf}
    mod._BASELINE_FILE = tmp_baseline

    try:
        mod.cmd_update()
        tf.unlink()
        mod.cmd_verify()
        captured = capsys.readouterr()
        assert "DELETED" in captured.out
    finally:
        mod._POLICY_FILES = orig_files
        mod._BASELINE_FILE = orig_bf


# ── T-10: --show does not modify baseline ─────────────────────────────────────

def test_T10_show_does_not_modify_baseline():
    _run("--update")
    mtime_before = _BASELINE.stat().st_mtime
    rc, out, _ = _run("--show")
    assert rc == 0
    mtime_after = _BASELINE.stat().st_mtime
    assert mtime_before == mtime_after


# ── T-11: --show prints <missing> ─────────────────────────────────────────────

def test_T11_show_prints_missing_for_nonexistent(tmp_path, capsys):
    import compliance.validators.policy_drift_check as mod

    orig_files = dict(mod._POLICY_FILES)
    mod._POLICY_FILES["ghost/file.md"] = tmp_path / "ghost.md"
    try:
        mod.cmd_show()
        captured = capsys.readouterr()
        assert "<missing>" in captured.out
    finally:
        mod._POLICY_FILES.clear()
        mod._POLICY_FILES.update(orig_files)


# ── T-12: valid JSON ──────────────────────────────────────────────────────────

def test_T12_baseline_is_valid_json():
    _run("--update")
    data = json.loads(_BASELINE.read_text())
    assert isinstance(data, dict)
    assert "checksums" in data


# ── T-13: 5 tracked keys ─────────────────────────────────────────────────────

def test_T13_baseline_contains_all_tracked_keys():
    _run("--update")
    data = json.loads(_BASELINE.read_text())
    checksums = data["checksums"]
    expected_keys = {
        "docs/SOUL.md",
        "AGENTS.md",
        "src/compliance/compliance_config.yaml",
        "src/compliance/policies/banxe_compliance.rego",
        "banxe-architecture/INVARIANTS.md",
    }
    # Only check keys for files that actually exist
    for key in expected_keys:
        assert key in checksums or key in data.get("missing", [])


# ── T-14: verify after update exits 0 ────────────────────────────────────────

def test_T14_verify_ok_after_update():
    _run("--update")
    rc, out, _ = _run("--verify")
    assert rc == 0
    assert "OK" in out


# ── T-15: idempotent update ───────────────────────────────────────────────────

def test_T15_update_is_idempotent():
    _run("--update")
    data1 = json.loads(_BASELINE.read_text())
    checksums1 = data1["checksums"]

    _run("--update")
    data2 = json.loads(_BASELINE.read_text())
    checksums2 = data2["checksums"]

    assert checksums1 == checksums2
