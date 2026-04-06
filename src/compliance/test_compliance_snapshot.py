"""
test_compliance_snapshot.py — G-13 Compliance Snapshot Bundle Tests

T-01  collect_snapshot returns ComplianceSnapshot instance
T-02  snapshot.timestamp is ISO-8601 UTC string
T-03  snapshot.version is non-empty string
T-04  snapshot.git_sha is 40-char hex or "unknown"
T-05  policy_checksums contains exactly 5 entries
T-06  policy_checksums values are 64-char hex (sha256) or "file-not-found"
T-07  invariants_count >= 0
T-08  agent_passports_count >= 0
T-09  rego_rules_count >= 0
T-10  gap_register_summary has done/open/deferred keys
T-11  gap_register_summary values are non-negative ints
T-12  test_results has passed/failed keys
T-13  collect_snapshot(run_tests=False) returns test_results with 0 counts
T-14  snapshot.errors is a list
T-15  to_dict() returns a dict with all expected keys
T-16  to_markdown() returns string containing "BANXE Compliance Snapshot"
T-17  to_markdown() includes gap register section
T-18  to_markdown() includes test results section
T-19  to_markdown() includes policy checksums section
T-20  export_snapshot_zip creates a ZIP file
T-21  ZIP contains snapshot.json
T-22  ZIP contains snapshot.md
T-23  snapshot.json inside ZIP is valid JSON
T-24  snapshot.json has all required keys
T-25  export_snapshot_zip is idempotent (second call overwrites)
T-26  export_snapshot_zip with missing artefact files does not raise
T-27  collect_snapshot with missing gap register file returns zeros
T-28  to_markdown includes errors section when errors present
"""
from __future__ import annotations

import json
import tempfile
import zipfile
from pathlib import Path
from unittest.mock import patch

import pytest

from compliance.utils.compliance_snapshot import (
    ComplianceSnapshot,
    collect_snapshot,
    export_snapshot_zip,
    _sha256,
    _parse_gap_register,
    _count_passports,
    _count_rego_rules,
    _count_invariants,
    _git_sha,
    _read_version,
)

REQUIRED_SNAPSHOT_KEYS = {
    "timestamp", "version", "git_sha", "policy_checksums",
    "invariants_count", "test_results", "agent_passports_count",
    "rego_rules_count", "gap_register_summary", "thresholds", "errors",
}


@pytest.fixture(scope="module")
def snapshot():
    """Collect once per module (run_tests=False for speed)."""
    return collect_snapshot(run_tests=False)


# ── T-01..T-03: basic fields ──────────────────────────────────────────────────

def test_T01_collect_returns_snapshot(snapshot):
    assert isinstance(snapshot, ComplianceSnapshot)


def test_T02_timestamp_is_iso8601(snapshot):
    ts = snapshot.timestamp
    assert "T" in ts and ("Z" in ts or "+" in ts or ts.endswith("+00:00"))


def test_T03_version_non_empty(snapshot):
    assert isinstance(snapshot.version, str)
    assert len(snapshot.version) > 0


# ── T-04: git sha ─────────────────────────────────────────────────────────────

def test_T04_git_sha_format(snapshot):
    sha = snapshot.git_sha
    assert sha == "unknown" or (len(sha) == 40 and all(c in "0123456789abcdef" for c in sha))


# ── T-05..T-06: policy checksums ──────────────────────────────────────────────

def test_T05_policy_checksums_five_entries(snapshot):
    assert len(snapshot.policy_checksums) == 5


def test_T06_checksums_are_sha256_or_missing(snapshot):
    for name, sha in snapshot.policy_checksums.items():
        assert sha == "file-not-found" or (len(sha) == 64 and all(c in "0123456789abcdef" for c in sha)), \
            f"Bad checksum for {name}: {sha}"


# ── T-07..T-09: counts ────────────────────────────────────────────────────────

def test_T07_invariants_count_nonneg(snapshot):
    assert snapshot.invariants_count >= 0


def test_T08_passports_count_nonneg(snapshot):
    assert snapshot.agent_passports_count >= 0


def test_T09_rego_rules_count_nonneg(snapshot):
    assert snapshot.rego_rules_count >= 0


# ── T-10..T-11: gap register ──────────────────────────────────────────────────

def test_T10_gap_summary_has_required_keys(snapshot):
    assert "done" in snapshot.gap_register_summary
    assert "open" in snapshot.gap_register_summary
    assert "deferred" in snapshot.gap_register_summary


def test_T11_gap_summary_nonneg(snapshot):
    for k, v in snapshot.gap_register_summary.items():
        assert isinstance(v, int) and v >= 0


# ── T-12..T-13: test results ──────────────────────────────────────────────────

def test_T12_test_results_keys(snapshot):
    assert "passed" in snapshot.test_results
    assert "failed" in snapshot.test_results


def test_T13_no_tests_returns_zero_counts():
    s = collect_snapshot(run_tests=False)
    assert s.test_results["passed"] == 0
    assert s.test_results["failed"] == 0


# ── T-14: errors list ─────────────────────────────────────────────────────────

def test_T14_errors_is_list(snapshot):
    assert isinstance(snapshot.errors, list)


# ── T-15..T-19: to_dict / to_markdown ────────────────────────────────────────

def test_T15_to_dict_has_all_keys(snapshot):
    d = snapshot.to_dict()
    assert REQUIRED_SNAPSHOT_KEYS.issubset(set(d.keys()))


def test_T16_to_markdown_contains_title(snapshot):
    md = snapshot.to_markdown()
    assert "BANXE Compliance Snapshot" in md


def test_T17_to_markdown_gap_section(snapshot):
    md = snapshot.to_markdown()
    assert "Gap Register" in md
    assert "Done:" in md


def test_T18_to_markdown_test_section(snapshot):
    md = snapshot.to_markdown()
    assert "Test Results" in md
    assert "Passed:" in md


def test_T19_to_markdown_checksums_section(snapshot):
    md = snapshot.to_markdown()
    assert "Policy Checksums" in md


# ── T-20..T-25: ZIP export ───────────────────────────────────────────────────

def test_T20_export_creates_zip(snapshot):
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
        out = Path(f.name)
    try:
        result = export_snapshot_zip(out, snapshot)
        assert result.exists()
        assert zipfile.is_zipfile(result)
    finally:
        out.unlink(missing_ok=True)


def test_T21_zip_contains_snapshot_json(snapshot):
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
        out = Path(f.name)
    try:
        export_snapshot_zip(out, snapshot)
        with zipfile.ZipFile(out) as zf:
            assert "snapshot.json" in zf.namelist()
    finally:
        out.unlink(missing_ok=True)


def test_T22_zip_contains_snapshot_md(snapshot):
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
        out = Path(f.name)
    try:
        export_snapshot_zip(out, snapshot)
        with zipfile.ZipFile(out) as zf:
            assert "snapshot.md" in zf.namelist()
    finally:
        out.unlink(missing_ok=True)


def test_T23_snapshot_json_is_valid_json(snapshot):
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
        out = Path(f.name)
    try:
        export_snapshot_zip(out, snapshot)
        with zipfile.ZipFile(out) as zf:
            data = json.loads(zf.read("snapshot.json"))
        assert isinstance(data, dict)
    finally:
        out.unlink(missing_ok=True)


def test_T24_snapshot_json_has_required_keys(snapshot):
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
        out = Path(f.name)
    try:
        export_snapshot_zip(out, snapshot)
        with zipfile.ZipFile(out) as zf:
            data = json.loads(zf.read("snapshot.json"))
        assert REQUIRED_SNAPSHOT_KEYS.issubset(set(data.keys()))
    finally:
        out.unlink(missing_ok=True)


def test_T25_export_idempotent(snapshot):
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
        out = Path(f.name)
    try:
        export_snapshot_zip(out, snapshot)
        size1 = out.stat().st_size
        export_snapshot_zip(out, snapshot)
        size2 = out.stat().st_size
        # Both should produce a valid ZIP
        assert zipfile.is_zipfile(out)
        # Size may differ by timestamp — just check both > 0
        assert size1 > 0 and size2 > 0
    finally:
        out.unlink(missing_ok=True)


# ── T-26: missing artefact files graceful ────────────────────────────────────

def test_T26_export_graceful_with_missing_artefacts(snapshot):
    """ZIP export should not raise even if artefact files are missing."""
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
        out = Path(f.name)
    try:
        # Patch exists() to return False for all artefact paths
        with patch.object(Path, "exists", return_value=False):
            # Should not raise
            result = export_snapshot_zip(out, snapshot)
        assert result == out
    finally:
        out.unlink(missing_ok=True)


# ── T-27: missing gap register ───────────────────────────────────────────────

def test_T27_missing_gap_register_returns_zeros():
    with patch(
        "compliance.utils.compliance_snapshot.ARCH_ROOT",
        Path("/nonexistent-dir-that-does-not-exist")
    ):
        summary = _parse_gap_register()
    assert summary == {"done": 0, "open": 0, "deferred": 0}


# ── T-28: errors in markdown ─────────────────────────────────────────────────

def test_T28_markdown_includes_errors_section():
    snap = ComplianceSnapshot(
        timestamp="2026-04-05T00:00:00+00:00",
        version="1.0.0",
        git_sha="abc123",
        policy_checksums={"SOUL.md": "file-not-found"},
        invariants_count=0,
        test_results={"passed": 0, "failed": 0},
        agent_passports_count=0,
        rego_rules_count=0,
        gap_register_summary={"done": 0, "open": 0, "deferred": 0},
        thresholds={},
        errors=["Policy file not found: SOUL.md"],
    )
    md = snap.to_markdown()
    assert "Collection Errors" in md
    assert "SOUL.md" in md
