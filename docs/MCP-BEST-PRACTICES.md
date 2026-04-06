# MCP Best Practices for Qoder CLI

**Project:** Banxe AI Bank (CarmiBanxe/vibe-coding)  
**Version:** 1.0 | 2026-04-03

---

## Architecture overview

```
Claude Code (planner/reviewer)
    ↓ MCP call
Qoder CLI mcp-server (executor)
    ↓ executes in
Current repository (isolated scope)
```

---

## Configuration hierarchy

### Global (~/.claude/settings.json)

```json
{
  "mcpServers": {
    "qoder": {
      "type": "stdio",
      "command": "qodercli",
      "args": ["mcp-server"]
    }
  }
}
```

**Why stdio:** Lowest latency, no network overhead, direct process communication.

### Project (~/.qoder/config.yml)

```yaml
mcp:
  loadContext: true
  contextPaths:
    - "AGENTS.md"
    - ".qoder/context.md"
    - "CLAUDE.md"
  timeout: 60000
```

---

## Best practice #1: Single responsibility

**DO:**
- Use Qoder for execution-heavy tasks
- Keep architecture decisions in Claude loop
- Delegate tests, commands, file edits to MCP

**DON'T:**
- Use MCP for strategic decisions
- Expect Qoder to understand business context
- Mix planner and executor roles

---

## Best practice #2: Repository isolation

**MCP server must:**

1. Detect git root on startup
2. Constrain all operations to that root
3. Refuse cross-repository access without explicit instruction
4. Report repository boundaries in status

**Implementation:**

```bash
# Qoder receives repo path from Claude
qodercli mcp-server --repo-root $(git rev-parse --show-toplevel)
```

---

## Best practice #3: Context loading priority

Load project context in this order:

1. `AGENTS.md` — agent-specific instructions (highest)
2. `.qoder/context.md` — execution contract
3. `CLAUDE.md` — project context
4. `COLLAB.md` — collaboration pattern
5. `src/compliance/COMPLIANCE_ARCH.md` — compliance invariants

**Rule:** First match wins. Closer to working directory = higher priority.

---

## Best practice #4: WSL optimization

For WSL2 environments:

```yaml
wsl:
  watchPolling: true        # Avoid filesystem watcher hangs
  watchInterval: 1000       # Poll every 1s
  maxConcurrentOperations: 2  # Reduce memory pressure
  preferWslPaths: true      # Use /home/mmber not \\wsl$
  disableInterop: true      # Don't call Windows executables
```

**Why:** WSL filesystem watchers can hang on large node_modules or .git operations.

---

## Best practice #5: Timeout handling

```yaml
execution:
  commandTimeout: 300   # 5 minutes for long operations
  retryCount: 1         # Retry once on failure
  timeout: 60000        # MCP operation timeout (ms)
```

**Pattern:** Fail fast on user-facing operations, allow longer timeouts for background tasks.

---

## Best practice #6: Logging and observability

```yaml
logging:
  level: info
  path: ~/.qoder/logs
```

**Log structure:**

```
~/.qoder/logs/
├── qodercli_mcp_YYYY-MM-DD_HH-MM-SS.log
├── qodercli_exec_YYYY-MM-DD_HH-MM-SS.log
└── events_YYYY-MM-DD.jsonl
```

**Key events to log:**
- MCP connection established/closed
- Context files loaded
- Command execution start/end
- Test results
- Errors and retries

---

## Best practice #7: Error reporting

**MCP error format:**

```json
{
  "error": {
    "code": -32000,
    "message": "Command failed",
    "data": {
      "command": "pytest src/compliance/test_phase15.py -v",
      "exit_code": 1,
      "stdout": "...",
      "stderr": "...",
      "repository": "/home/mmber/vibe-coding",
      "context_violation": false
    }
  }
}
```

**Always include:**
- Exact command that failed
- Exit code
- Full stdout/stderr
- Repository context
- Whether context rules were violated

---

## Best practice #8: Compliance-sensitive mode

When working in `src/compliance/`:

```yaml
compliance:
  requireArchRead: true
  invariantPaths:
    - "src/compliance/COMPLIANCE_ARCH.md"
  protectedPatterns:
    - "minMatch"
    - "TTL"
    - "threshold"
    - "weight"
```

**Behavior:**
- Block changes to protected patterns without explicit approval
- Require COMPLIANCE_ARCH.md read before any edit
- Log all compliance-related changes to audit trail

---

## Best practice #9: Parallel workers

For independent tasks:

```bash
# Claude spawns parallel Qoder workers
qodercli --worktree --branch feature-a -p "implement X" &
qodercli --worktree --branch feature-b -p "implement Y" &
wait
```

**Use cases:**
- Parallel feature implementation
- Simultaneous test suites
- Independent refactors

**Caution:** Each worker must be in isolated worktree/branch.

---

## Best practice #10: Health checks

**MCP server should respond to:**

```bash
qodercli mcp-server --health
```

**Expected response:**

```json
{
  "status": "healthy",
  "version": "0.1.38",
  "repository": "/home/mmber/vibe-coding",
  "context_loaded": true,
  "active_workers": 0,
  "uptime_seconds": 3600
}
```

---

## Testing MCP integration

### Test 1: Context loading

```bash
cd ~/vibe-coding
qodercli -p "List all active instruction files"
```

**Expected:** AGENTS.md, .qoder/context.md, CLAUDE.md listed.

### Test 2: Repository isolation

```bash
cd ~/vibe-coding
qodercli -p "Read ../../guiyon/CLAUDE.md"
```

**Expected:** Error — cross-repository access denied.

### Test 3: Compliance invariant protection

```bash
cd ~/vibe-coding
qodercli -p "Change Watchman minMatch to 0.90 in sanctions_check.py"
```

**Expected:** Warning — COMPLIANCE_ARCH.md invariant violation.

---

## Troubleshooting

### Problem: MCP server hangs

**Symptoms:**
- Claude waits indefinitely
- No Qoder response

**Fix:**
```bash
# Kill stuck MCP server
pkill -f "qodercli mcp-server"

# Restart with verbose logging
qodercli mcp-server --verbose
```

### Problem: Context not loading

**Symptoms:**
- Qoder doesn't follow project rules
- Invariants ignored

**Check:**
```bash
# Verify config exists
cat ~/.qoder/config.yml

# Check context paths exist
ls -la AGENTS.md .qoder/context.md CLAUDE.md
```

### Problem: WSL filesystem hangs

**Symptoms:**
- File watchers freeze
- High CPU on node_modules scan

**Fix:**
```yaml
# In ~/.qoder/config.yml
wsl:
  watchPolling: true
  maxConcurrentOperations: 2
```

---

## Security considerations

### Never expose via network

```yaml
# WRONG — never do this
mcp:
  transport: http
  port: 8080  # DANGEROUS
```

**Always use stdio:**

```yaml
# CORRECT
mcp:
  type: stdio
  command: qodercli
  args: ["mcp-server"]
```

### Token scoping

If using API tokens:

```bash
# Scope to specific repository
export QODER_REPO_SCOPE=/home/mmber/vibe-coding
export QODER_ALLOWED_COMMANDS="edit,run_test,read_file"
```

---

## Performance tuning

### For large repositories

```yaml
execution:
  maxWorkers: 2
  ignorePatterns:
    - "node_modules/**"
    - ".git/**"
    - "**/*.pyc"
    - "__pycache__/**"
```

### For slow networks

```yaml
mcp:
  timeout: 120000  # 2 minutes
  retryCount: 2
```

---

## Summary checklist

- [ ] Global MCP config in `~/.claude/settings.json`
- [ ] Project context in `~/.qoder/config.yml`
- [ ] WSL optimizations enabled
- [ ] Repository isolation enforced
- [ ] Compliance mode for sensitive paths
- [ ] Logging configured
- [ ] Timeouts set appropriately
- [ ] Health checks working
- [ ] Error reporting includes full context
- [ ] Parallel workers use isolated worktrees
