#!/usr/bin/env bash
# Pre-push hook: marker-only CR gate trigger.
#
# REDESIGN (HIMMEL-26, 2026-05-18): this hook used to spawn a print-mode
# claude subprocess to run the multi-agent review inline. That was architecturally
# wrong — nested Claude sessions are unreliable, contend for MCP / rate limits,
# and can hang the outer session that triggered the push.
#
# New design: this hook is a STATUS-CHECK TRIGGER, not an orchestrator.
# - It writes an untracked marker file under .git/cr-pending/<branch>
# - The actual review is run later, from inside the outer Claude session,
#   via the /pr-check slash command (which invokes /pr-review-toolkit:review-pr
#   directly — no nested CLI process).
# - The gate fires at `gh pr create` time via a Claude Code PreToolUse hook
#   (scripts/hooks/check-cr-marker-on-pr-create.sh), which blocks PR creation
#   while a marker exists for the current branch + HEAD.
# - /pr-check deletes the marker when the review is clean.
#
# Bypass:
#   - SKIP_CR=1 git push ...    (env-var skip; logs WARNING)
#   - git push --no-verify ...  (skip all pre-push hooks)
#
# Note: the prior TTY-check landmine (silent no-op under pre-commit framework)
# is no longer relevant — there's no subprocess to gate on TTY. The whole
# subprocess block is gone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# default_branch() resolves the repo's protected default (main OR master,
# HIMMEL-297) used as the diff base below. Fail-closed: a missing guardrail
# substrate means we cannot compute the right base, so refuse the push.
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "→ code-review: cannot source guardrails/lib.sh — refusing the push (fix the guardrail lib or bypass with SKIP_CR=1)" >&2
    exit 2
fi

branch=$(git branch --show-current)

# Skip on a protected default (main OR master) / detached HEAD — pushing the
# default branch is blocked elsewhere and there's no meaningful diff to review.
if [ -z "$branch" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    exit 0
fi

# Explicit skip
if [ "${SKIP_CR:-0}" = "1" ]; then
    echo "→ code-review: SKIP_CR=1 set — skipping marker write (WARNING: review locally with /pr-check before opening PR)" >&2
    exit 0
fi

# Resolve diff base: prefer the more up-to-date ref.
# 'db' is the repo's protected default (main OR master, HIMMEL-297). When both
# the local 'db' and 'origin/db' exist and local 'db' is an ancestor of
# 'origin/db' (i.e. origin is ahead), use 'origin/db' so we don't diff against a
# stale local copy and generate false-positive markers. No network call — git
# merge-base --is-ancestor uses only locally-fetched refs. If neither ref
# exists, skip with WARNING.
db=$(default_branch)
diff_base=""
if git rev-parse --verify --quiet "$db" >/dev/null && \
   git rev-parse --verify --quiet "origin/$db" >/dev/null; then
    if git merge-base --is-ancestor "$db" "origin/$db" 2>/dev/null; then
        diff_base="origin/$db"
    else
        diff_base="$db"
    fi
elif git rev-parse --verify --quiet "$db" >/dev/null; then
    diff_base="$db"
elif git rev-parse --verify --quiet "origin/$db" >/dev/null; then
    diff_base="origin/$db"
else
    echo "→ code-review: no '$db' or 'origin/$db' ref — skipping (WARNING: cannot compute diff for review)" >&2
    exit 0
fi

# Skip on docs-only / merge-only diffs to avoid pointless review gating
changed=$(git diff --name-only "${diff_base}...HEAD")
if [ -z "$changed" ]; then
    echo "→ code-review: no diff vs ${diff_base} — skipping" >&2
    exit 0
fi
# Classify the diff to pick the CR lane (HIMMEL-303):
#   - any non-docs code  -> "full"       marker (the 6-reviewer heavy/holistic lane via /pr-check)
#   - reviewable docs only -> "docs-audit" marker (one code-reviewer w/ docs charter via /pr-check)
#   - handover-state only  -> no marker (personal auto-committed state, exempt — HIMMEL-142)
# "Reviewable docs" = .md/.txt or docs/ that are NOT under handovers/. Handover
# state stays exempt so handover/* auto-commits don't gate on a review they
# don't need. The marker carries the lane as a 3rd field; the PR-create hook
# parses only field 2 (the SHA), so the extra field is backward-compatible.
non_docs=$(echo "$changed" | grep -Ev '\.(md|txt)$|^docs/|^handovers/' || true)
if [ -n "$non_docs" ]; then
    audit_kind="full"
else
    reviewable_docs=$(echo "$changed" | grep -Ev '^handovers/' | grep -E '\.(md|txt)$|^docs/' || true)
    if [ -z "$reviewable_docs" ]; then
        echo "→ code-review: handover-state-only change — skipping marker write" >&2
        exit 0
    fi
    audit_kind="docs-audit"
fi

# Write marker. .git/ is never tracked, so this is safe to scribble in.
# Use --git-common-dir (shared .git) NOT --git-dir (per-worktree) so a marker
# written from one worktree is visible to PR creation from another worktree
# or from the main repo. One marker per branch; overwrites on re-push.
# Branch names may contain '/' (e.g. feat/foo) — mkdir -p the full parent so
# we don't trip on missing intermediate dirs.
git_dir=$(git rev-parse --git-common-dir)
marker_path="${git_dir}/cr-pending/${branch}"
mkdir -p "$(dirname "${marker_path}")"
head_sha=$(git rev-parse HEAD)
short_sha=$(git rev-parse --short HEAD)
printf '%s | %s | %s\n' "$(date -Iseconds)" "${head_sha}" "${audit_kind}" > "${marker_path}"

if [ "$audit_kind" = "docs-audit" ]; then
    echo "→ code-review: docs-audit marker written for ${branch} (HEAD=${short_sha}). Run /pr-check (docs-audit lane: one code-reviewer with the docs charter) before opening the PR — docs are never zero-CR (HIMMEL-303)." >&2
else
    echo "→ code-review: marker written for ${branch} (HEAD=${short_sha}). Run /pr-review-toolkit:review-pr (or /pr-check) in your Claude session before opening the PR." >&2
fi
exit 0
