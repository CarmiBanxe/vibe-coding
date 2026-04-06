#!/bin/bash
# Check active agent instructions in current project (v4.0 — Four-Partner Swarm)
# Usage: bash scripts/check-agent-instructions.sh

set -e

echo "════════════════════════════════════════════"
echo "  Active Agent Instructions Checker v4.0"
echo "════════════════════════════════════════════"
echo ""

# Detect git root
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
echo "Repository root: $GIT_ROOT"
echo ""

echo "=== GLOBAL INSTRUCTIONS ==="
if [ -f ~/.claude/CLAUDE.md ]; then
    echo "✓ ~/.claude/CLAUDE.md exists"
    echo "  Lines: $(wc -l < ~/.claude/CLAUDE.md)"
else
    echo "✗ ~/.claude/CLAUDE.md NOT FOUND"
fi
echo ""

echo "=== PROJECT INSTRUCTIONS ==="
for file in "CLAUDE.md" "AGENTS.md" "docs/COLLAB.md" "COLLAB.md"; do
    if [ -f "$GIT_ROOT/$file" ]; then
        echo "✓ $file exists"
        echo "  Lines: $(wc -l < $GIT_ROOT/$file)"
    fi
done
echo ""

echo "=== CANON ==="
CANON_DIR="$GIT_ROOT/canon/modules"
if [ -d "$CANON_DIR" ]; then
    echo "✓ canon/modules/ exists"
    for mod in CORE.md DEV.md DECISION.md; do
        [ -f "$CANON_DIR/$mod" ] && echo "  ✓ $mod" || echo "  ✗ $mod MISSING"
    done
else
    echo "○ canon/modules/ not found (not a developer-core repo?)"
fi
echo ""

echo "=== BANXE STACK v2.0 ==="

# LiteLLM
if curl -sf http://localhost:4000/v1/models > /dev/null 2>&1; then
    echo "✓ LiteLLM :4000 — responding"
else
    echo "✗ LiteLLM :4000 — NOT responding"
fi

# Aider
if which aider > /dev/null 2>&1; then
    echo "✓ Aider CLI — found"
else
    echo "✗ Aider CLI — NOT FOUND"
fi

# Ruflo config
if [ -f "$GIT_ROOT/ruflo/config.yaml" ]; then
    echo "✓ ruflo/config.yaml — found"
else
    echo "○ ruflo/config.yaml not found"
fi

# MiroFish
if curl -sf http://localhost:5004/health > /dev/null 2>&1; then
    echo "✓ MiroFish :5004 — responding (frontend :3001)"
else
    echo "○ MiroFish :5004 — not deployed"
fi
echo ""

echo "=== COMPLIANCE ARCH (if applicable) ==="
if [ -f "$GIT_ROOT/src/compliance/COMPLIANCE_ARCH.md" ]; then
    echo "✓ src/compliance/COMPLIANCE_ARCH.md exists"
    echo "  Invariants:"
    grep -E "^[0-9]+\." $GIT_ROOT/src/compliance/COMPLIANCE_ARCH.md | head -6
else
    echo "○ Compliance arch not found (not a compliance project?)"
fi
echo ""

echo "════════════════════════════════════════════"
echo "  Instruction hierarchy: COMPLETE"
echo "  Stack: BANXE AI Stack v2.0"
echo "════════════════════════════════════════════"
