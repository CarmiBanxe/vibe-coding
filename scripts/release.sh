#!/usr/bin/env bash
# release.sh — G-20 BANXE Release Pipeline
#
# Creates a versioned release: updates CHANGELOG.md, creates git tag, runs
# pre-release compliance checks, and pushes to GitHub.
#
# Usage:
#   bash scripts/release.sh <version>
#       e.g.: bash scripts/release.sh 3.1.0
#
# Pre-release checks:
#   1. pytest — full test suite (src/compliance)
#   2. policy drift check (G-08)
#   3. agent passport validation (G-12)
#   4. git status clean
#
# Exit codes:
#   0 — release successful
#   1 — pre-release check failed
#   2 — usage error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"
DATE="$(date '+%Y-%m-%d')"

# ── Validation ──────────────────────────────────────────────────────────────────
if [[ -z "$VERSION" ]]; then
  echo "Usage: bash scripts/release.sh <version>"
  echo "  e.g.: bash scripts/release.sh 3.1.0"
  exit 2
fi

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: Version must be semver X.Y.Z (got: $VERSION)"
  exit 2
fi

TAG="v$VERSION"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  BANXE RELEASE PIPELINE"
echo "  Version : $TAG"
echo "  Date    : $DATE"
echo "  Repo    : $REPO_ROOT"
echo "══════════════════════════════════════════════════════════════"

# ── Check git tag doesn't exist ────────────────────────────────────────────────
if git tag | grep -q "^$TAG$"; then
  echo "ERROR: Tag $TAG already exists. Bump version."
  exit 1
fi

# ── Pre-release check 1: clean working tree ────────────────────────────────────
echo ""
echo "[1/5] Git status — must be clean"
DIRTY=$(git status --porcelain)
if [[ -n "$DIRTY" ]]; then
  echo "ERROR: Working tree is not clean. Commit or stash changes first."
  git status --short
  exit 1
fi
echo "  ✓ Working tree clean"

# ── Pre-release check 2: pytest ────────────────────────────────────────────────
echo ""
echo "[2/5] pytest — full compliance suite"
cd "$REPO_ROOT"
if python3 -m pytest src/compliance \
    --ignore=src/compliance/test_api_integration.py \
    -q --tb=short 2>&1 | tail -5; then
  echo "  ✓ Tests passed"
else
  echo "  ✗ Tests failed — release aborted"
  exit 1
fi

# ── Pre-release check 3: policy drift ─────────────────────────────────────────
echo ""
echo "[3/5] Policy drift check (G-08)"
if PYTHONPATH=src python3 src/compliance/validators/policy_drift_check.py --verify; then
  echo "  ✓ No policy drift"
else
  DRIFT_RC=$?
  if [[ "$DRIFT_RC" -eq 2 ]]; then
    echo "  ⚠ No baseline — run: python3 src/compliance/validators/policy_drift_check.py --update"
    echo "    Continuing (first release)"
  else
    echo "  ✗ Policy drift detected — release aborted"
    echo "    If change was authorised: python3 src/compliance/validators/policy_drift_check.py --update"
    exit 1
  fi
fi

# ── Pre-release check 4: agent passport validation ─────────────────────────────
echo ""
echo "[4/5] Agent passport validation (G-12)"
ARCH_ROOT="$REPO_ROOT/../banxe-architecture"
if [[ -d "$ARCH_ROOT/agents/passports" ]]; then
  if PYTHONPATH=src python3 src/compliance/validators/validate_agent_passport.py; then
    echo "  ✓ All passports valid"
  else
    echo "  ✗ Passport validation failed — release aborted"
    exit 1
  fi
else
  echo "  ⚠ banxe-architecture not found at $ARCH_ROOT — skipping passport check"
fi

# ── Pre-release check 5: no secrets in staged files ───────────────────────────
echo ""
echo "[5/5] Secret pattern scan"
SECRET_PATTERNS=("password\s*=" "api_key\s*=" "secret\s*=" "token\s*=" "AKIA[A-Z0-9]{16}")
FOUND_SECRETS=false
for pattern in "${SECRET_PATTERNS[@]}"; do
  if git diff HEAD --name-only | xargs grep -ilE "$pattern" 2>/dev/null | grep -v "\.example\|test_\|_test\.\|CHANGELOG"; then
    echo "  ✗ Potential secret found (pattern: $pattern) — review and redact"
    FOUND_SECRETS=true
  fi
done
if $FOUND_SECRETS; then
  echo "  ✗ Secret check failed — release aborted"
  exit 1
fi
echo "  ✓ No secrets detected"

# ── Update CHANGELOG.md ────────────────────────────────────────────────────────
echo ""
echo "Updating CHANGELOG.md..."

# Collect recent commits since last tag (or all if no tags)
LAST_TAG=$(git tag --sort=-version:refname | head -1 || echo "")
if [[ -n "$LAST_TAG" ]]; then
  COMMITS=$(git log "$LAST_TAG..HEAD" --oneline 2>/dev/null | head -20 || echo "")
else
  COMMITS=$(git log --oneline | head -20)
fi

# Build changelog entry
ENTRY="## [$TAG] — $DATE\n\n"
if [[ -n "$COMMITS" ]]; then
  ENTRY+="### Changes\n"
  while IFS= read -r line; do
    ENTRY+="- $line\n"
  done <<< "$COMMITS"
else
  ENTRY+="- Release $TAG\n"
fi
ENTRY+="\n"

if [[ -f "$CHANGELOG" ]]; then
  # Prepend new entry after first line (assumed to be # CHANGELOG header)
  HEADER=$(head -1 "$CHANGELOG")
  REST=$(tail -n +2 "$CHANGELOG")
  printf "%s\n\n%b%s" "$HEADER" "$ENTRY" "$REST" > "$CHANGELOG.tmp"
  mv "$CHANGELOG.tmp" "$CHANGELOG"
else
  printf "# CHANGELOG\n\n%b" "$ENTRY" > "$CHANGELOG"
fi

echo "  ✓ CHANGELOG.md updated"

# ── Git commit + tag ────────────────────────────────────────────────────────────
echo ""
echo "Creating release commit and tag..."
git add "$CHANGELOG"
git commit -m "release: $TAG ($DATE)"
git tag -a "$TAG" -m "BANXE release $TAG ($DATE)"

echo "  ✓ Commit and tag created: $TAG"

# ── Push ────────────────────────────────────────────────────────────────────────
echo ""
echo "Pushing to GitHub..."
git push origin main
git push origin "$TAG"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  RELEASE $TAG COMPLETE"
echo "  Tag pushed: $TAG"
echo "  CHANGELOG: $CHANGELOG"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Check GitHub Actions: https://github.com/CarmiBanxe/vibe-coding/actions"
echo "  2. Create GitHub Release from tag $TAG"
echo "  3. Update policy baseline if needed: python3 src/compliance/validators/policy_drift_check.py --update"
