# COLLAB.md v4.0 — Four-Partner Swarm Architecture

**Stack:** BANXE AI Stack v2.0  
**Version:** 4.0 | 2026-04-06  
**Repository:** `~/developer/` (and all downstream projects)

---

## User Principle

```bash
cd ~/project
claude
```

That is all. No manual executor commands. No separate terminals. No coordination overhead.

---

## What Happens Under The Hood

```
YOU → Claude Code (architect/orchestrator)
         ├── Ruflo        (multi-step orchestration)
         ├── Aider CLI    (code execution — sole executor)
         └── MiroFish     (behavioural simulation)
              ↓
         Claude Code (synthesis + review) → YOU
```

### Automatic flow

1. **You start Claude** in project directory
2. **Claude reads** project instructions (CANON → CLAUDE.md → AGENTS.md)
3. **Claude delegates** code execution to Aider CLI via LiteLLM automatically
4. **Ruflo orchestrates** multi-step flows when needed
5. **MiroFish simulates** regulatory / fraud / behavioural edge cases on trigger
6. **Claude reviews** all results and presents unified outcome

### You see

- Clean result presentation
- What was analyzed
- What was changed / executed
- What was verified (parallel-verify.sh consensus)
- What risks remain

### You don't see

- LiteLLM routing internals
- Aider invocation commands
- Internal agent coordination
- Context loading complexity

---

## Architecture

```
[MetaClaw/OpenClaw Platform — GMKtec сервер]
├── Ollama :11434 (qwen3-30b, qwen3-banxe, glm-4-flash, gpt-oss-20b)
├── LiteLLM :4000 (OpenAI-совместимый роутер ко всем моделям)
├── OpenClaw Bots :18789 / :18791 / :18793
└── MiroFish :3001 (frontend UI) / :5004 (backend API)
         │
         ▼
[Ruflo Orchestrator] ← enterprise multi-step coordination layer
         │
         ▼
┌─────────────────────────────────────────────────┐
│            PARTNER SYNERGY v2.0                 │
│                                                 │
│  Claude Code = Архитектор/Координатор           │
│  ├── subagents = параллельные работники         │
│  ├── Aider CLI = Исполнитель (код + git)        │
│  │   └── через LiteLLM :4000                   │
│  ├── MiroFish = Симулятор/Adversarial           │
│  │   └── через Ollama (qwen3-banxe backend)     │
│  └── parallel-verify.sh = 3-модельная проверка  │
│      └── через LiteLLM :4000                   │
│                                                 │
│  [Ruflo] = оркестратор multi-step потоков       │
│  └── координирует всех партнёров                │
└─────────────────────────────────────────────────┘
         │
         ▼
[OpenClaw Bots — production deploy target]
```

---

## Partners (exactly four)

| # | Partner | Role | Entry point |
|---|---------|------|-------------|
| 1 | **Claude Code** | Architect, reviewer, orchestrator | `claude` |
| 2 | **Ruflo** | Multi-step flow orchestrator | `ruflo/start-ruflo.sh` |
| 3 | **Aider CLI** | Sole code executor | `scripts/aider-banxe.sh` |
| 4 | **MiroFish** | Behavioural + regulatory simulator | `:3001` (UI) / `:5004/health` (API) |

**LiteLLM** = infrastructure model routing layer — not a partner.  
**MetaClaw/OpenClaw** = platform layer — not a partner.

---

## Instruction Hierarchy

Agents follow instructions in this priority order:

1. **Explicit user instruction** (highest authority)
2. **CANON** (`~/developer/canon/`) — universal rules (CORE.md, DEV.md, FR_MODULE.md …)
3. **Repository-level contracts**:
   - `CLAUDE.md` — project context
   - `AGENTS.md` — agent execution instructions
   - `COLLAB.md` — this file
   - `COMPLIANCE_ARCH.md` — compliance invariants (if applicable)
4. **Global defaults**: `~/.claude/CLAUDE.md`

**Rule:** closer to working directory = higher priority. CANON sits above CLAUDE.md.

---

## Project Isolation (Canon)

### Hard invariant

**One terminal = one project = one repository.**

Agents must NEVER:
- Read files outside current git root
- Mix configs / secrets / context across repositories
- Reuse artifacts from another project implicitly

**Violation is a critical error, not a style issue.**

### Cross-project work

If you explicitly request cross-project work:

```
"Copy the sanctions_check.py module from vibe-coding to developer"
```

Then agents must:
1. Confirm both repository names
2. Work sequentially (one at a time)
3. Maintain strict separation during each operation
4. Request narrow, per-step permission for each repository

---

## When Collaboration is Visible

Normally collaboration is invisible. It becomes visible when:

### Aider execution failure

```
Aider failed: pytest src/compliance/test_phase15.py
Exit code: 1
Stderr: ModuleNotFoundError: No module named 'clickhouse_driver'

Possible causes:
1. Virtualenv not activated
2. Dependency missing from requirements.txt
3. Test path incorrect
```

### Parallel verification disagreement

```
parallel-verify.sh result: 1/3 PASS → NEEDS REVIEW
compliance model: PASS
security model:   FAIL — hardcoded credential pattern detected
alternative model: FAIL — same issue confirmed

Action required: fix before commit.
```

### Review disagreement

```
Aider suggests: Change minMatch from 0.80 to 0.90
Analysis: This violates COMPLIANCE_ARCH.md invariant #3

Invariant #3 states: "Watchman minMatch: 0.80 (Jaro-Winkler)"

Change requires: MLRO approval + regression test on known cases.
Recommendation: Keep 0.80 unless explicit business decision made.
```

---

## Compliance-Sensitive Operations

When working in `src/compliance/` (vibe-coding):

### Mandatory pre-flight

**Before ANY change:** read `COMPLIANCE_ARCH.md` fully.

### Protected invariants

Cannot be changed without explicit user approval:

1. **Canonical key:** `(jurisdiction_code, registration_number)`
2. **OFAC RSS:** dead since 31 Jan 2025 — HTML scrape only
3. **Watchman minMatch:** 0.80 (Jaro-Winkler)
4. **ClickHouse TTL:** 5 YEAR (FCA MLR 2017 requirement)
5. **Jube AGPLv3:** internal use only

### Decision thresholds (read-only by default)

| Score | Decision | Action |
|-------|----------|--------|
| ≥ 70 | REJECT | Block + SAR |
| 40–69 | HOLD | Enhanced due diligence |
| < 40 | APPROVE | Pass |
| sanctions_hit = true | REJECT (always) | SAR mandatory |

**SAR auto-threshold:** composite ≥ 85 OR sanctions_hit

---

## Testing Requirements

Before marking task complete:

| Change type | Required tests |
|-------------|----------------|
| Business logic | Unit tests + integration smoke test |
| Compliance logic | Regression tests on known cases |
| API endpoints | Endpoint smoke test + schema validation |
| Infrastructure | Deploy script dry-run + health check |
| Multi-agent flow | Subagent pattern compliance (docs/subagent-patterns.md) |
| Documentation | Link check + build verification |

---

## HITL Checkpoints (Human In The Loop)

| Risk level | Confidence required | Approval |
|------------|---------------------|----------|
| LOW | >90% | Auto-approve |
| MEDIUM | Any | Human required |
| HIGH | Any | Human + Compliance officer |

All decisions logged to ClickHouse for FCA audit trail.

---

## Security Considerations

### Never commit

- `.env` files
- Secrets or API keys
- Credentials or tokens
- Private certificates

### Use environment variables

```bash
export BANXE_API_KEY="..."
export CLICKHOUSE_PASSWORD="..."
export LITELLM_API_KEY="anything"
```

---

## Summary Checklist

Before starting work in any project:

- [ ] CANON loaded (`~/developer/canon/modules/CORE.md`)
- [ ] Project has AGENTS.md and CLAUDE.md
- [ ] LiteLLM :4000 responding (for Aider CLI)
- [ ] Ruflo config present (`ruflo/config.yaml`)
- [ ] Compliance arch read (if touching `src/compliance/`)

After completing work:

- [ ] Changes committed to canonical repository
- [ ] Tests pass
- [ ] parallel-verify.sh run (for compliance/security changes)
- [ ] Documentation updated (if needed)
- [ ] No secrets committed
- [ ] Clear commit messages
- [ ] MEMORY.md updated

---

## Version History

| Version | Date | Change |
|---------|------|--------|
| 1.0 | 2026-03-XX | Two-terminal workflow (deprecated) |
| 2.0 | 2026-04-02 | Manual coordination pattern |
| 3.0 | 2026-04-03 | Single-terminal Claude Code + Qoder CLI synergy |
| 4.0 | 2026-04-06 | Four-Partner Swarm v2.0, Qoder removed, CANON layer added |

---

## Related Documents

- `docs/subagent-patterns.md` — named subagent patterns (RIV / MFR / CA / PDG / MED)
- `ruflo/config.yaml` — Ruflo orchestrator configuration
- `ruflo/start-ruflo.sh` — stack health check + startup
- `scripts/aider-banxe.sh` — Aider via LiteLLM (4 modes)
- `scripts/parallel-verify.sh` — 3-model consensus verification
- `AGENTS.md` — agent execution instructions
- `canon/modules/CORE.md` — universal canon rules
- `src/compliance/COMPLIANCE_ARCH.md` — compliance invariants (if applicable)
