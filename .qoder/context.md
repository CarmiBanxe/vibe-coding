# .qoder/context.md — Qoder Execution Contract (Three-Partner Synergy)

**Repository:** Generic project template  
**Purpose:** Universal execution contract for ALL projects  
**Version:** 3.0 | 2026-04-03

---

## Core rule

**Repository scope = current project only.**

This project uses **three-partner synergy**: Claude Code + Qoder CLI + MiroFish.

### What this means

- All projects have access to full three-partner stack
- MiroFish auto-triggers for validation-critical tasks
- Project-specific scenarios in docs/MIROFISH-SCENARIOS.md
- Update docs/MEMORY.md after significant changes

---

## Three-Partner Architecture

| Partner | Role | Activation | Scope |
|---------|------|------------|-------|
| **Claude Code** | Architect & Coordinator | Every `claude` session | Design, review, orchestration |
| **Qoder CLI** | Executor | MCP auto-load | Implementation, edits, tests |
| **MiroFish** | Simulator & Validator | Auto-trigger by keywords | Behavioral simulation, stress-testing |

### MiroFish for ALL Projects

**Banxe projects (vibe-coding, collaboration, MetaClaw, banxe-mirofish):**
- HITL handoff simulations (дублёр trust thresholds)
- FCA compliance policy testing
- Fraud pattern detection
- Market reaction modeling
- UX validation for banking flows

**Legal projects (guiyon, ss1):**
- Court strategy simulation (судебная стратегия)
- Judge reaction modeling (реакция суда)
- Appeal dynamics (апелляционная динамика)
- Counter-argument stress-testing (контраргументы)
- Witness credibility analysis

**Developer-core:**
- All scenario templates (MASTER)
- Sync coordination
- Infrastructure validation

---

## Project isolation

**Hard invariant:** One terminal = one project = one repository.

| Do | Don't |
|----|-------|
| Implement project features | Mix files from other projects |
| Run MiroFish simulations | Assume paths from other repos |
| Update MEMORY.md | Commit without testing |
| Follow project-specific rules | Expose sensitive data |

### Violation is a critical error

Never:
- Read project files without explicit instruction
- Assume project structure matches templates
- Mix components from different projects

---

## Role definition

**Qoder CLI role in this repository:**

1. **Implementation executor** — write code, edit files, run tests
2. **Simulation assistant** — help run MiroFish scenarios
3. **Documentation helper** — update project docs

### Typical tasks

- Implement features
- Write and run tests
- Run MiroFish simulations (auto-triggered)
- Update documentation

---

## Working method

### For implementation tasks

1. Read relevant design docs
2. Implement with clear diff
3. Write tests
4. Update MEMORY.md
5. Commit with clear message

### For MiroFish simulations

When Claude detects validation-critical task:

1. Claude triggers MiroFish automatically
2. MiroFish runs project-specific scenario
3. Results inform design decisions
4. Qoder implements based on validated design

**Auto-trigger keywords (ALL projects):**
- `HITL`, `handoff`, `дублёр` → hitl-handoff.yml
- `FCA`, `compliance`, `sandbox` → pre-fca-sandbox.yml
- `fraud pattern`, `social engineering` → fraud-social-eng.yml
- `market reaction`, `launch` → gtm-reaction.yml
- `UX validation`, `drop-off` → ux-validation.yml
- `stress test`, `crisis` → fraud-stress-test.yml
- `court`, `judge`, `суд` → court-strategy.yml (legal)
- `appeal`, `counter-argument`, `апелляция` → appeal-dynamics.yml (legal)

---

## Instruction priority

When working in this repository:

1. **User instruction** — explicit commands
2. **This context** (.qoder/context.md) — execution rules
3. **AGENTS.md** — agent instructions
4. **CLAUDE.md** — project context
5. **docs/MIROFISH-SCENARIOS.md** — project-specific scenarios
6. **Global defaults** (~/.claude/CLAUDE.md)

---

## Output expectations

After completing work:

```
✓ Task completed: {description}
✓ Files changed: {count}
✓ Tests passed: {count}
✓ Simulation run: {scenario-name} (if triggered)
✓ MEMORY.md updated: yes/no
○ Pending: {follow-up actions}
```

---

## Quick reference

| Command | Purpose |
|---------|---------|
| `bash collab.sh worker "task" branch` | Parallel implementation |
| `bash collab.sh run "command"` | Single command |
| `bash collab.sh jobs` | Check active tasks |
| `bash ../developer/mirofish/run-simulation.sh <scenario>` | Run MiroFish simulation |
| `python -m pytest tests/` | Run test suite |

---

## Files in this repository

| Path | Purpose |
|------|---------|
| `.qoder/context.md` | This file — execution contract (UNIVERSAL) |
| `.qoder/config.yml` | Qoder CLI configuration |
| `AGENTS.md` | Three-partner agent instructions |
| `CLAUDE.md` | Project context |
| `docs/COLLAB.md` | Collaboration pattern |
| `docs/MIROFISH-SCENARIOS.md` | Project-specific MiroFish scenarios |
| `docs/MEMORY.md` | Long-term memory |

---

## Project-Specific MiroFish Scenarios

### Banxe Projects (Banking/FCA)
- `hitl-handoff.yml` — Human-in-the-loop trust thresholds
- `pre-fca-sandbox.yml` — Compliance policy testing
- `fraud-social-eng.yml` — Fraud pattern detection
- `gtm-reaction.yml` — Market reaction modeling
- `ux-validation.yml` — Banking UX validation

### Legal Projects (Court/Appeals)
- `court-strategy.yml` — Судебная стратегия, реакция суда
- `appeal-dynamics.yml` — Апелляционная динамика, контраргументы
- `witness-credibility.yml` — Анализ показаний свидетелей
- `judge-reaction.yml` — Моделирование реакции судьи

### Developer-Core (Infrastructure)
- ALL scenario templates (MASTER copies)
- Sync validation scenarios
- Infrastructure stress-tests

---

**Source:** `~/developer/.qoder/context.md` (MASTER)  
**Synced:** Auto-sync via sync-all.sh  
**Architecture:** Three-Partner Synergy (Claude + Qoder + MiroFish) for ALL projects
