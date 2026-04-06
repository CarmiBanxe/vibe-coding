#!/usr/bin/env python3
"""
Evidently Drift Monitor — training corpus quality monitoring.

Detects drift in agent response quality between reference and current periods.
Uses Evidently AI (if installed) or manual drift computation as fallback.

Drift threshold: max_drift_score = 0.15 (from COMPLIANCE_ARCH.md calibration log)

Usage:
    from compliance.training.evidently_monitor import check_drift, DriftReport

    report = check_drift(
        corpus_dir  = Path("src/compliance/training/corpus"),
        window_days = 7,
    )
    # report.drift_detected → True/False
    # report.drift_score    → 0.0–1.0
    # report.details        → {"confirmed_rate_delta": ..., "refuted_rate_delta": ...}

CLI:
    python3 evidently_monitor.py --corpus-dir src/compliance/training/corpus --days 7
"""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

MAX_DRIFT_SCORE = 0.15   # from COMPLIANCE_ARCH.md calibration log


@dataclass
class DriftReport:
    drift_detected: bool
    drift_score:    float       # 0.0 = stable, 1.0 = complete drift
    window_days:    int
    reference_size: int         # number of records in reference period
    current_size:   int         # number of records in current period
    details:        dict = field(default_factory=dict)
    evidently_used: bool = False
    generated_at:   str  = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )

    def summary(self) -> str:
        status = "DRIFT DETECTED" if self.drift_detected else "STABLE"
        return (f"[{status}] score={self.drift_score:.3f} "
                f"(threshold={MAX_DRIFT_SCORE}) "
                f"ref_n={self.reference_size} cur_n={self.current_size} "
                f"window={self.window_days}d")


# ── Corpus loading ────────────────────────────────────────────────────────────

def _load_corpus(corpus_dir: Path) -> list[dict]:
    """Load all JSONL records from corpus directory."""
    records = []
    for path in sorted(corpus_dir.glob("*.jsonl")):
        try:
            for line in path.read_text().splitlines():
                line = line.strip()
                if line:
                    records.append(json.loads(line))
        except Exception:
            continue
    return records


def _split_by_window(
    records: list[dict],
    window_days: int,
) -> tuple[list[dict], list[dict]]:
    """
    Split records into reference (older) and current (recent window_days) periods.
    Uses 'timestamp' field if present, otherwise falls back to equal split.
    """
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=window_days)

    current   = []
    reference = []

    for r in records:
        ts_str = r.get("timestamp") or r.get("created_at") or ""
        try:
            ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            if ts >= cutoff:
                current.append(r)
            else:
                reference.append(r)
        except (ValueError, TypeError):
            # No timestamp — fall back to even split
            reference.append(r)

    # Fallback: if no timestamps, split 70/30
    if not current and not reference and records:
        split = int(len(records) * 0.7)
        reference = records[:split]
        current   = records[split:]

    return reference, current


# ── Manual drift computation (stdlib fallback) ────────────────────────────────

def _compute_stats(records: list[dict]) -> dict:
    """Compute key quality metrics from corpus records."""
    if not records:
        return {"confirmed_rate": 0.5, "refuted_rate": 0.5, "uncertain_rate": 0.0,
                "hitl_rate": 0.0, "avg_confidence": 0.5, "n": 0}

    n            = len(records)
    confirmed    = sum(1 for r in records if r.get("consensus") == "CONFIRMED")
    refuted      = sum(1 for r in records if r.get("consensus") == "REFUTED")
    uncertain    = sum(1 for r in records if r.get("consensus") == "UNCERTAIN")
    hitl_count   = sum(1 for r in records if r.get("hitl_required", False))
    confidences  = [float(r.get("confidence_score", 0.5)) for r in records
                    if "confidence_score" in r]
    avg_conf     = sum(confidences) / len(confidences) if confidences else 0.5

    return {
        "confirmed_rate":   confirmed / n,
        "refuted_rate":     refuted   / n,
        "uncertain_rate":   uncertain / n,
        "hitl_rate":        hitl_count / n,
        "avg_confidence":   avg_conf,
        "n":                n,
    }


def _manual_drift(ref_stats: dict, cur_stats: dict) -> float:
    """
    Simple drift score: mean absolute delta across key metrics.
    Range 0.0 (identical) to 1.0 (completely different).
    """
    metrics = ["confirmed_rate", "refuted_rate", "uncertain_rate",
               "hitl_rate", "avg_confidence"]
    deltas = [abs(cur_stats.get(m, 0) - ref_stats.get(m, 0)) for m in metrics]
    return sum(deltas) / len(deltas) if deltas else 0.0


# ── Evidently AI (optional) ───────────────────────────────────────────────────

def _evidently_drift(
    reference: list[dict],
    current:   list[dict],
) -> Optional[tuple[float, dict]]:
    """
    Use Evidently AI for drift computation if available.
    Returns (drift_score, details) or None if Evidently not installed.
    """
    try:
        import pandas as pd
        from evidently.report import Report
        from evidently.metric_preset import DataDriftPreset

        metrics = ["confirmed_rate", "refuted_rate", "uncertain_rate",
                   "hitl_rate", "avg_confidence"]

        def records_to_df(records: list[dict]) -> pd.DataFrame:
            rows = []
            for r in records:
                rows.append({
                    "confirmed":   1 if r.get("consensus") == "CONFIRMED" else 0,
                    "refuted":     1 if r.get("consensus") == "REFUTED"   else 0,
                    "uncertain":   1 if r.get("consensus") == "UNCERTAIN" else 0,
                    "hitl":        1 if r.get("hitl_required", False)     else 0,
                    "confidence":  float(r.get("confidence_score", 0.5)),
                })
            return pd.DataFrame(rows) if rows else pd.DataFrame(columns=["confirmed", "refuted", "uncertain", "hitl", "confidence"])

        ref_df = records_to_df(reference)
        cur_df = records_to_df(current)

        if ref_df.empty or cur_df.empty:
            return None

        report = Report(metrics=[DataDriftPreset()])
        report.run(reference_data=ref_df, current_data=cur_df)
        result = report.as_dict()

        # Extract drift score from Evidently result
        metrics_list = result.get("metrics", [])
        drift_scores = []
        for m in metrics_list:
            if "result" in m and "drift_score" in m["result"]:
                drift_scores.append(m["result"]["drift_score"])

        avg_drift = sum(drift_scores) / len(drift_scores) if drift_scores else 0.0
        return avg_drift, {"evidently_metrics": len(metrics_list), "drift_scores": drift_scores}

    except ImportError:
        return None
    except Exception:
        return None


# ── Public API ────────────────────────────────────────────────────────────────

def check_drift(
    corpus_dir:  Path,
    window_days: int = 7,
) -> DriftReport:
    """
    Check for drift in agent response quality.

    Compares reference period (older records) vs current period (last window_days).
    Uses Evidently AI if installed, otherwise manual metric comparison.

    Args:
        corpus_dir:  Path to JSONL corpus directory.
        window_days: Number of days for current period (default: 7).

    Returns:
        DriftReport with drift_detected, drift_score, and details.
    """
    records   = _load_corpus(corpus_dir)
    reference, current = _split_by_window(records, window_days)

    ref_stats = _compute_stats(reference)
    cur_stats = _compute_stats(current)

    evidently_result = _evidently_drift(reference, current)
    if evidently_result:
        drift_score, ev_details = evidently_result
        evidently_used = True
        details = {
            "method":              "evidently",
            "reference_stats":     ref_stats,
            "current_stats":       cur_stats,
            "confirmed_rate_delta": cur_stats["confirmed_rate"] - ref_stats["confirmed_rate"],
            "refuted_rate_delta":   cur_stats["refuted_rate"]   - ref_stats["refuted_rate"],
            **ev_details,
        }
    else:
        drift_score    = _manual_drift(ref_stats, cur_stats)
        evidently_used = False
        details = {
            "method":              "manual",
            "reference_stats":     ref_stats,
            "current_stats":       cur_stats,
            "confirmed_rate_delta": cur_stats["confirmed_rate"] - ref_stats["confirmed_rate"],
            "refuted_rate_delta":   cur_stats["refuted_rate"]   - ref_stats["refuted_rate"],
        }

    return DriftReport(
        drift_detected = drift_score > MAX_DRIFT_SCORE,
        drift_score    = round(drift_score, 4),
        window_days    = window_days,
        reference_size = len(reference),
        current_size   = len(current),
        details        = details,
        evidently_used = evidently_used,
    )


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Evidently drift monitor for compliance corpus")
    parser.add_argument("--corpus-dir", required=True, type=Path)
    parser.add_argument("--days",       default=7, type=int)
    parser.add_argument("--json",       action="store_true")
    args = parser.parse_args()

    report = check_drift(args.corpus_dir, args.days)

    if args.json:
        print(json.dumps({
            "drift_detected": report.drift_detected,
            "drift_score":    report.drift_score,
            "window_days":    report.window_days,
            "reference_size": report.reference_size,
            "current_size":   report.current_size,
            "evidently_used": report.evidently_used,
            "details":        report.details,
            "generated_at":   report.generated_at,
        }, ensure_ascii=False, indent=2))
    else:
        print(report.summary())
        if report.drift_detected:
            print(f"  confirmed_rate: ref={report.details['reference_stats']['confirmed_rate']:.2%} "
                  f"→ cur={report.details['current_stats']['confirmed_rate']:.2%}")
            print(f"  refuted_rate:   ref={report.details['reference_stats']['refuted_rate']:.2%} "
                  f"→ cur={report.details['current_stats']['refuted_rate']:.2%}")
