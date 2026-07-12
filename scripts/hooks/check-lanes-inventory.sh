#!/usr/bin/env bash
# HIMMEL-689 — block re-introducing the lane INVENTORY into CLAUDE.md prose (himmel-dev only).
# The lane inventory lives in scripts/lanes/lanes.json (queried via /lanes); CLAUDE.md keeps
# only invariant tier semantics + policy. Mirrors check-agents-md-fresh.sh: .himmel-dev-gated,
# validates the STAGED index bytes, fail-closed. rc: 0 pass | 1 drift | 2 cannot-evaluate.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
if ! . "$HERE/../guardrails/lib.sh" 2>/dev/null; then
    echo "→ lanes-inventory-guard: cannot source guardrails/lib.sh — fail-closed" >&2; exit 2
fi
# Tri-valued is_himmel_dev_repo (mirror check-agents-md-fresh.sh:15-17):
# rc=0 himmel-dev · rc=1 adopter → no-op · rc=2 cannot-resolve-root → fail CLOSED (never open).
rc=0; is_himmel_dev_repo || rc=$?
[ "$rc" -eq 2 ] && { echo "→ lanes-inventory-guard: cannot resolve repo root — fail-closed" >&2; exit 2; }
[ "$rc" -eq 1 ] && exit 0
[ "${LANES_GUARD_OK:-0}" = "1" ] && { echo "→ lanes-inventory-guard: LANES_GUARD_OK=1 — skipping" >&2; exit 0; }

git diff --cached --name-only | grep -qx 'CLAUDE.md' || exit 0   # only when CLAUDE.md is staged
# Validate the STAGED bytes, not the worktree (R1 M7). Drift → check.mjs exits 1, propagates (no || true).
git show ":CLAUDE.md" | node "$HERE/../lanes/check.mjs"
