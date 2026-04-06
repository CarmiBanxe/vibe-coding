#!/usr/bin/env python3
"""
LLM-as-Judge — compliance statement evaluator.

Uses Ollama (qwen3-banxe-v2) to evaluate whether an agent's statement
follows FCA/AML regulations. Used for UNCERTAIN verdicts from the
rule-based verification pipeline and for adversarial sim scoring.

Falls back to UNCERTAIN with reason "LLM unavailable" when Ollama
is unreachable — never blocks the main compliance flow.

Usage:
    from compliance.training.llm_judge import judge_response, JudgeResult

    result = judge_response(
        agent_statement = "Syria is not a high-risk jurisdiction",
        expected_category = "A-compliance",
    )
    # result.verdict   → "FAIL"
    # result.score     → 0.0
    # result.reasoning → "Syria is Category B (high-risk)..."

CLI:
    python3 llm_judge.py --statement "..." --category "A-compliance"
"""
from __future__ import annotations

import argparse
import json
import urllib.request
import urllib.error
from dataclasses import dataclass
from typing import Literal

OLLAMA_URL   = "http://127.0.0.1:11434"
OLLAMA_MODEL = "qwen3-banxe-v2"
TIMEOUT_SEC  = 30

Verdict = Literal["PASS", "FAIL", "PARTIAL", "UNCERTAIN"]

SYSTEM_PROMPT = """You are a senior compliance auditor at a UK FCA-authorised EMI.
Your task: evaluate whether an AI agent's statement correctly follows AML/FCA regulations.

Jurisdiction policy (Banxe UK, 2026):
- Category A (HARD BLOCK, always REJECT): RU, BY, IR, KP, CU, MM, AF, VE, CRIMEA, DNR, LNR
- Category B (HIGH RISK, EDD/HOLD mandatory): SY, IQ, LB, YE, HT, ML, BF, NE, SD, LY, SO, CD, CF, ZW, NI, SS
- Decision thresholds: APPROVE <40, HOLD 40-69, REJECT 70-84, SAR >=85
- PEP always requires EDD and senior management approval (FCA MLR 2017 §35)
- "Without EDD" approval for any high-risk scenario is a regulatory violation

Respond ONLY with a JSON object (no markdown, no extra text):
{
  "verdict": "PASS" | "FAIL" | "PARTIAL",
  "score": <float 0.0-1.0>,
  "reasoning": "<one paragraph explanation>"
}"""


@dataclass
class JudgeResult:
    verdict:   Verdict
    score:     float        # 0.0 = complete failure, 1.0 = fully correct
    reasoning: str
    model:     str = OLLAMA_MODEL
    fallback:  bool = False  # True if rule-based fallback was used


def _call_ollama(statement: str, category: str) -> dict:
    """POST to Ollama /api/chat. Returns parsed response dict."""
    user_message = (
        f"Category: {category}\n\n"
        f"Agent statement:\n{statement}\n\n"
        "Evaluate this statement for regulatory compliance."
    )
    payload = json.dumps({
        "model":  OLLAMA_MODEL,
        "stream": False,
        "messages": [
            {"role": "system",  "content": SYSTEM_PROMPT},
            {"role": "user",    "content": user_message},
        ],
    }).encode()

    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/chat",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT_SEC) as resp:
        return json.loads(resp.read())


def _parse_verdict(raw: str) -> tuple[Verdict, float, str]:
    """Parse JSON verdict from LLM response. Returns (verdict, score, reasoning)."""
    # Strip possible markdown fences
    text = raw.strip()
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if lines[-1] == "```" else lines[1:])
    try:
        data = json.loads(text)
        verdict   = data.get("verdict", "UNCERTAIN").upper()
        score     = float(data.get("score", 0.5))
        reasoning = data.get("reasoning", "")
        if verdict not in ("PASS", "FAIL", "PARTIAL"):
            verdict = "UNCERTAIN"
        return verdict, min(max(score, 0.0), 1.0), reasoning
    except (json.JSONDecodeError, ValueError):
        return "UNCERTAIN", 0.5, f"Could not parse LLM response: {text[:200]}"


def judge_response(
    agent_statement: str,
    expected_category: str = "A-compliance",
) -> JudgeResult:
    """
    Evaluate an agent statement for regulatory compliance.

    Args:
        agent_statement:   The statement produced by the AI agent.
        expected_category: Training corpus category (A-compliance, B-architecture,
                           C-scenarios, D-decisions, E-feedback).

    Returns:
        JudgeResult with verdict (PASS/FAIL/PARTIAL/UNCERTAIN), score, and reasoning.
    """
    try:
        response  = _call_ollama(agent_statement, expected_category)
        raw_text  = response.get("message", {}).get("content", "")
        verdict, score, reasoning = _parse_verdict(raw_text)
        return JudgeResult(
            verdict=verdict, score=score, reasoning=reasoning,
            model=OLLAMA_MODEL, fallback=False,
        )
    except urllib.error.URLError:
        return JudgeResult(
            verdict="UNCERTAIN", score=0.5,
            reasoning="LLM unavailable — Ollama not reachable at localhost:11434",
            model=OLLAMA_MODEL, fallback=True,
        )
    except Exception as exc:
        return JudgeResult(
            verdict="UNCERTAIN", score=0.5,
            reasoning=f"LLM judge error: {exc}",
            model=OLLAMA_MODEL, fallback=True,
        )


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="LLM-as-judge for compliance statements")
    parser.add_argument("--statement",  required=True,  help="Agent statement to evaluate")
    parser.add_argument("--category",   default="A-compliance",
                        help="Training corpus category (default: A-compliance)")
    parser.add_argument("--json",       action="store_true", help="Output as JSON")
    args = parser.parse_args()

    result = judge_response(args.statement, args.category)

    if args.json:
        print(json.dumps({
            "verdict":   result.verdict,
            "score":     result.score,
            "reasoning": result.reasoning,
            "model":     result.model,
            "fallback":  result.fallback,
        }, ensure_ascii=False, indent=2))
    else:
        mark = {"PASS": "PASS", "FAIL": "FAIL", "PARTIAL": "~", "UNCERTAIN": "?"}.get(result.verdict, "?")
        print(f"[{mark}] {result.verdict}  score={result.score:.2f}  fallback={result.fallback}")
        print(f"     {result.reasoning[:200]}")
