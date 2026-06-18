#!/usr/bin/env bash
# Update an existing himmel checkout (HIMMEL-397).
#
# WHY this exists: himmel's marketplace is registered from a LOCAL `directory`
# source (see docs/setup/settings-template.json), so Claude Code's marketplace
# `autoUpdate` only RE-SYNCS plugins from the on-disk dir — it never fetches
# from GitHub. And the core hooks + slash commands aren't plugins at all;
# they run from $CLAUDE_PROJECT_DIR. So `git pull` of THIS checkout is the only
# thing that delivers a himmel update. This wraps the two steps that follow it:
# pull, then refresh the marketplace from the freshly-pulled local dir.
#
# Full model: docs/setup/updating.md.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

# 1. Pull. --ff-only so a diverged/feature branch fails loudly instead of
#    opening a merge — the operator decides how to reconcile in that case.
echo "==> git pull --ff-only (branch: $branch)"
if ! git pull --ff-only; then
    echo "" >&2
    echo "update: pull was not a fast-forward (branch '$branch' has diverged from upstream, or local edits block the update)." >&2
    echo "        Resolve manually: stash/commit local work, or 'git checkout main' first," >&2
    echo "        then re-run. himmel updates land on the default branch." >&2
    exit 1
fi

# 2. Re-sync the himmel marketplace from the (now-updated) local dir so a
#    running install picks up plugin changes. Best-effort: skip cleanly if the
#    claude CLI is absent. `marketplace update` is non-interactive.
if command -v claude >/dev/null 2>&1; then
    echo "==> claude plugin marketplace update himmel"
    claude plugin marketplace update himmel || \
        echo "update: marketplace re-sync failed (non-fatal) — run 'claude plugin marketplace update himmel' yourself." >&2
else
    echo "update: claude CLI not on PATH — skipping marketplace re-sync." >&2
fi

cat <<'EOF'

==> himmel updated.
    - Hooks are live immediately (PreToolUse/etc. re-read from disk per call).
    - Plugins / slash commands / skills load at session start — RESTART any
      running Claude session to pick them up.
EOF
