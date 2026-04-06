# AGENTS.md — Developer Core: Central Repository for Shared Components

**Repository:** `~/developer/`  
**Version:** 4.0 | 2026-04-06  
**Purpose:** Shared components, templates, and configurations distributed across all projects  
**Architecture:** Four-Partner Swarm v2.0 (Claude Code + Ruflo + Aider CLI + MiroFish)

---

## Core mission

This repository is the **central source of truth** for:

- Agent instructions (AGENTS.md, CLAUDE.md templates)
- **Four-partner swarm architecture** (Claude Code + Ruflo + Aider CLI + MiroFish)
- Compliance architecture (COMPLIANCE_ARCH.md)
- Shared scripts and automation (sync-all.sh, onboard-project.sh)
- Project templates
- MCP best practices
- **MiroFish scenario templates** (MASTER copies for all projects)

### Four-Partner Swarm Architecture (v2.0)

All projects use the same four-partner stack:

| # | Partner | Role | Entry point |
|---|---------|------|-------------|
| 1 | **Claude Code** | Architect, reviewer, orchestrator | `claude` |
| 2 | **Ruflo** | Multi-step flow orchestrator | `ruflo/start-ruflo.sh` |
| 3 | **Aider CLI** | Sole code executor | `scripts/aider-banxe.sh` |
| 4 | **MiroFish** | Behavioural + regulatory simulator | `:3000/api` |

**LiteLLM** = infrastructure model routing layer (not a partner).  
**MetaClaw/OpenClaw** = platform layer (not a partner).

**Key principle:** MiroFish is a partner for ALL projects, not just Banxe.
- Banxe projects: banking/FCA/fraud scenarios
- Legal projects: court/judge/appeal scenarios
- Developer-core: infrastructure & sync validation

### Distribution model

Components from this repository are synced to:

| Project | Type | Sync target | MiroFish | Scenarios |
|---------|------|-------------|----------|-----------|
| vibe-coding | banxe | `/home/mmber/vibe-coding/` | ✅ | banking/FCA/fraud |
| collaboration | banxe | `/home/mmber/collaboration/` | ✅ | multi-agent conflicts |
| MetaClaw | banxe | `/home/mmber/MetaClaw/` | ✅ | orchestration scaling |
| guiyon | legal | `/home/mmber/guiyon/` | ✅ | court strategy |
| ss1 | legal | `/home/mmber/ss1/` | ✅ | appeal dynamics |
| banxe-mirofish | tool | `/home/mmber/banxe-mirofish/` | ✅ | MASTER templates |
| developer-core | core | `/home/mmber/developer/` | ✅ | ALL (MASTER) |

---

## Instruction hierarchy (for THIS repository)

1. **Explicit user instruction** (highest authority)
2. **CANON** (`~/developer/canon/`) — CORE.md, DEV.md, FR_MODULE.md
3. **Repository-level contracts**:
   - `CLAUDE.md` (project context)
   - `AGENTS.md` (this file)
   - `docs/COLLAB.md` (collaboration contract)
4. **Global defaults**: `~/.claude/CLAUDE.md`

---

## Orchestration Protocol v4.0

### Subagent patterns

Named patterns for Claude Code subagent orchestration — see `docs/subagent-patterns.md`:

| Pattern | When to use |
|---------|-------------|
| **RIV** | New feature with unknown dependencies |
| **MFR** | Refactor touching N≥3 files independently |
| **CA** | Compliance audit before PR merge |
| **PDG** | Pre-deploy gate before GMKtec production |
| **MED** | Human behaviour / fraud / regulatory design |

### Aider CLI as sole executor

All code changes go through Aider CLI via LiteLLM:

```bash
bash scripts/aider-banxe.sh --fast     # glm-4-flash — quick tasks
bash scripts/aider-banxe.sh --full     # qwen3-30b — complex tasks (default)
bash scripts/aider-banxe.sh --banxe    # qwen3-banxe — compliance domain
bash scripts/aider-banxe.sh --unrestricted  # gpt-oss-20b — no guardrails
```

### Parallel verification

Before committing compliance or security changes:

```bash
bash scripts/parallel-verify.sh --file src/compliance/sanctions_check.py
# 3 models in parallel: compliance / security / alternative
# Consensus: 2/3 PASS → ✅  |  <2/3 → ⚠️ NEEDS REVIEW
```

### Rule for downstream projects

When syncing components TO a project, that project's local files take precedence over these templates.

**These are templates and starting points, not immutable laws.**

---

## Repository structure

```
~/developer/
├── AGENTS.md                        ← This file — agent instructions
├── CLAUDE.md                        ← Project context
├── canon/                           ← CANON modules (CORE, DEV, FR_MODULE …)
├── docs/
│   ├── COLLAB.md                    ← Collaboration contract (v4.0)
│   ├── subagent-patterns.md         ← Named subagent patterns
│   └── MCP-BEST-PRACTICES.md        ← MCP configuration guide
├── ruflo/
│   ├── config.yaml                  ← Ruflo orchestrator config
│   └── start-ruflo.sh               ← Stack health check + startup
├── scripts/
│   ├── aider-banxe.sh               ← Aider CLI via LiteLLM (4 modes)
│   ├── parallel-verify.sh           ← 3-model consensus gate
│   ├── start_banxe_stack.sh         ← Master startup script
│   ├── check-agent-instructions.sh  ← Diagnostic tool
│   └── sync-to-project.sh           ← Sync script
├── templates/
│   ├── project-template/            ← New project bootstrap
│   └── compliance-module/           ← AML/KYC module template
└── compliance/
    ├── COMPLIANCE_ARCH.md           ← Invariants contract
    └── api.py                       ← Reference implementation
```

---

## Component catalog

### Templates (copy to new projects)

| Component | Source | Target | Purpose |
|-----------|--------|--------|---------|
| `AGENTS.md` | `./AGENTS.md` | `{project}/AGENTS.md` | Agent instructions |
| `docs/COLLAB.md` | `./docs/COLLAB.md` | `{project}/docs/COLLAB.md` | Collaboration contract |
| `docs/subagent-patterns.md` | `./docs/subagent-patterns.md` | `{project}/docs/subagent-patterns.md` | Subagent patterns |
| `ruflo/config.yaml` | `./ruflo/config.yaml` | `{project}/ruflo/config.yaml` | Ruflo config |
| `scripts/aider-banxe.sh` | `./scripts/aider-banxe.sh` | `{project}/scripts/aider-banxe.sh` | Aider executor |
| `scripts/parallel-verify.sh` | `./scripts/parallel-verify.sh` | `{project}/scripts/parallel-verify.sh` | Verification gate |

### Compliance stack (read-only reference)

| Component | Purpose | Projects using |
|-----------|---------|----------------|
| `compliance/COMPLIANCE_ARCH.md` | Invariants contract | vibe-coding |
| `compliance/api.py` | Reference API | vibe-coding |
| `compliance/sanctions_check.py` | OFAC Watchman integration | vibe-coding |
| `compliance/audit_trail.py` | ClickHouse audit logging | vibe-coding |

### Scripts (shared utilities)

| Script | Purpose | Usage |
|--------|---------|-------|
| `scripts/start_banxe_stack.sh` | Master startup — all components | `bash start_banxe_stack.sh` |
| `scripts/aider-banxe.sh` | Aider CLI via LiteLLM | `bash aider-banxe.sh --full` |
| `scripts/parallel-verify.sh` | 3-model consensus gate | `bash parallel-verify.sh --file path.py` |
| `scripts/sync-all.sh` | Sync all projects from registry | `bash sync-all.sh [--dry-run]` |
| `scripts/onboard-project.sh` | Onboard new project | `./onboard-project.sh <name> <type>` |
| `scripts/check-agent-instructions.sh` | Verify instruction hierarchy | Debug agent setup |

---

## Sync protocol

### Sync protocol

#### Manual sync (current method)

```bash
cd ~/developer
bash scripts/sync-all.sh
```

#### Automatic sync (future state)

**Post-commit hook** (`~/developer/.git/hooks/post-commit`):
- On commit to `~/developer/`: auto-run sync-all.sh
- Detect changed components
- Identify affected projects
- Commit and push to all repos automatically

### Change management

### Safe changes (auto-sync allowed)

- Documentation updates
- Comment additions
- Formatting fixes
- Test additions

### Review-required changes (manual sync)

- Configuration changes (.qoder/config.yml)
- Instruction hierarchy changes (AGENTS.md)
- Compliance invariant changes (COMPLIANCE_ARCH.md)
- Script logic changes

### Sync approval workflow

1. Change committed to `~/developer/`
2. User runs `bash scripts/sync-to-project.sh <project>`
3. Script shows diff for each target
4. User approves/rejects per project
5. Changes applied to targets

---

## Project isolation enforcement

**CRITICAL:** This repository contains SHARED templates and MASTER scenario copies.

When working IN this repository:
- Edit templates for distribution
- Test changes before syncing
- Document breaking changes
- Maintain MiroFish scenario templates (MASTER)

When working IN a target project:
- Use synced templates as starting point
- Local overrides allowed and expected (especially MIROFISH-SCENARIOS.md)
- Report useful improvements back to developer/
- Project-specific scenarios stay in the project (not synced back)

---

## Testing requirements

Before syncing any component:

| Component type | Required validation |
|----------------|---------------------|
| Config files | Syntax check + dry-run |
| Scripts | Shellcheck + manual test |
| Templates | Bootstrap test project |
| Compliance | Compare with production |
| Documentation | Link check + build |

---

## Version tracking

Each synced component should include:

```markdown
**Source:** `~/developer/{path}`  
**Synced:** YYYY-MM-DD  
**Version:** X.Y
```

---

## Rollback procedure

If a synced change breaks a project:

1. Identify the broken component
2. Restore previous version in target project
3. Report issue to `~/developer/`
4. Fix in developer repo
5. Re-sync when ready

---

## Quick start for new components

To add a new shared component:

1. Create in appropriate directory (`scripts/`, `templates/`, etc.)
2. Add documentation header with purpose and usage
3. Test in isolation
4. Commit to `~/developer/`
5. Manually sync to interested projects
6. Update this AGENTS.md if needed

---

## People and responsibilities

| Role | Person | Scope |
|------|--------|-------|
| Component author | Any developer | Create/maintain specific components |
| Sync coordinator | Moriel Carmi | Approve cross-project distribution |
| Integration tester | Aider CLI | Validate synced components work |

---

## Files reference

| File | Purpose | Sync targets |
|------|---------|--------------|
| `AGENTS.md` | This file — four-partner swarm instructions | All projects |
| `docs/COLLAB.md` | Collaboration contract v4.0 | All projects |
| `docs/subagent-patterns.md` | Named subagent patterns | All projects |
| `ruflo/config.yaml` | Ruflo orchestrator config | All projects |
| `scripts/aider-banxe.sh` | Aider CLI via LiteLLM | All projects |
| `scripts/parallel-verify.sh` | 3-model verification gate | All projects |
| `scripts/start_banxe_stack.sh` | Master startup script | All projects |
| `docs/PROJECT-REGISTRY.csv` | Project registry for sync-all.sh | Internal use |
| `scripts/sync-all.sh` | Multi-repo sync automation | Internal use |
| `scripts/onboard-project.sh` | New project onboarding | Internal use |
| `compliance/COMPLIANCE_ARCH.md` | Compliance invariants | vibe-coding |

---

## Definition of done (for component development)

A component is ready for sync when:

- [ ] Implementation complete and tested
- [ ] Documentation header added
- [ ] No project-specific assumptions
- [ ] Works in isolation
- [ ] Backward-compatible or migration documented
- [ ] Committed to `~/developer/`
- [ ] Synced to at least one target project

---

## Next steps (pending work)

- [x] Create sync-all.sh for automated distribution
- [x] Update AGENTS.md with four-partner swarm architecture (Sprint 9)
- [x] Create onboard-project.sh for new project onboarding
- [x] Create aider-banxe.sh, parallel-verify.sh, ruflo config (Sprint 9)
- [x] Create docs/subagent-patterns.md (Sprint 9)
- [ ] Create git post-commit hook for auto-sync
- [ ] Deploy MiroFish to GMKtec (:3000)
- [ ] Create project-specific MIROFISH-SCENARIOS.md for all 6 projects
- [ ] Update MEMORY.md with four-partner stack documentation
