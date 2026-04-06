#!/usr/bin/env bash
# sync-compliance-arch.sh — sync COMPLIANCE_ARCH.md between locations
#
# The authoritative version is src/compliance/COMPLIANCE_ARCH.md (Phase 16, Phase N...).
# docs/COMPLIANCE_ARCH.md is a copy for MkDocs navigation.
#
# Usage:
#   bash scripts/sync-compliance-arch.sh          # vibe-coding internal sync only
#   bash scripts/sync-compliance-arch.sh --full   # also push to developer-core

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_DIR}/src/compliance/COMPLIANCE_ARCH.md"
DST_DOCS="${REPO_DIR}/docs/COMPLIANCE_ARCH.md"
DEVELOPER_CORE="${HOME}/developer/compliance/COMPLIANCE_ARCH.md"
FULL="${1:-}"

echo "[sync-compliance-arch] Source: ${SRC}"

# ── 1. Sync within vibe-coding: src/compliance/ → docs/ ──────────────────────
cp "${SRC}" "${DST_DOCS}"
echo "[sync-compliance-arch] Updated: docs/COMPLIANCE_ARCH.md"

SRC_VER=$(grep "^Version\|^\*\*Version" "${SRC}" | head -1 || echo "unknown")
echo "[sync-compliance-arch] Version: ${SRC_VER}"

# ── 2. Optionally sync to developer-core ─────────────────────────────────────
if [[ "${FULL}" == "--full" ]]; then
    if [[ -f "${DEVELOPER_CORE}" ]]; then
        cp "${SRC}" "${DEVELOPER_CORE}"
        echo "[sync-compliance-arch] Updated: ~/developer/compliance/COMPLIANCE_ARCH.md"
        cd "${HOME}/developer"
        if git diff --quiet HEAD "${DEVELOPER_CORE}" 2>/dev/null; then
            echo "[sync-compliance-arch] developer-core: no change"
        else
            git add compliance/COMPLIANCE_ARCH.md
            git commit -m "sync: COMPLIANCE_ARCH.md from vibe-coding Phase 16"
            git push
            echo "[sync-compliance-arch] developer-core: pushed"
        fi
    else
        echo "[sync-compliance-arch] WARN: developer-core path not found, skipping"
    fi
fi

echo "[sync-compliance-arch] Done."
