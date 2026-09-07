#!/usr/bin/env bash
# Claude Code PostToolUse hook (Bash matcher): after a `git push` that
# advances an OPEN PR's head, post an `@coderabbitai review` trigger comment
# (HIMMEL-1906).
#
# CodeRabbit's `auto_review` is OFF (.coderabbit.yaml, HIMMEL-1252), so the
# App reviews a PR ONLY on an explicit `@coderabbitai review` comment.
# trigger-cr-on-pr-create.sh posts that comment on PR CREATE, but its dedup
# used to be keyed per PR (any existing trigger comment silenced it forever).
# That blackholed every fix round: push a follow-up commit, the new head gets
# CodeRabbit's "Review skipped: automatic reviews are disabled" status (NOT a
# real review), the merge gate correctly refuses it, and nothing re-triggers
# because a trigger comment from the FIRST head already exists on the PR
# (PRs #1717/#1718). This sibling hook + the shared per-head-SHA ledger in
# scripts/lib/cr-trigger-ledger.sh close that gap: trigger AT MOST ONCE per
# head SHA, on push as well as on create.
#
# Sibling, not a merge into trigger-cr-on-pr-create.sh: the two fire on
# different command shapes (`gh pr create` vs `git push`) and need different
# fast-path tokens; the two files stay double-post-safe because BOTH read and
# write the SAME ledger (scripts/lib/cr-trigger-ledger.sh) — whichever hook
# runs first for a given head SHA wins, the other becomes a no-op. Hooks
# under one PostToolUse matcher run sequentially, so there is no race between
# a `git push && gh pr create` compound command hitting both hooks in one
# dispatch.
#
# GitHub is the source of truth for "did the push land", not tool_response
# exit-code sniffing: this hook always asks `gh pr view` what the PR's
# CURRENT head SHA is, and only acts if it differs from what the ledger has
# already triggered. A failed/partial push leaves the PR's head unchanged,
# so this is naturally a no-op — no need to parse `git push`'s output.
#
# Exit semantics — ADVISORY / non-blocking, exit 0 in EVERY case, mirroring
# trigger-cr-on-pr-create.sh: a PostToolUse hook cannot un-push, and a failure
# here must never strand a successful push. The merge gate's skipped/absent
# arms are the structural backstop if this hook's post ever fails.
#
# ponytail: resolves the PR via `gh pr view` for the CURRENT checked-out
# branch — it does not parse the pushed ref out of the `git push` command.
# DELIBERATE (CR round-2 codex-2, re-raised from round 1 — a decision, not an
# oversight): himmel's structural invariant is one branch per worktree, so
# "current checked-out branch" and "the branch this push just advanced" are
# the same thing in every supported workflow. If that assumption ever breaks
# — a push naming a DIFFERENT remote ref than the checked-out branch — the
# trigger silently doesn't fire for that PR: its head advances but stays on
# CodeRabbit's "Review skipped" status, and the merge gate refuses green
# until someone triggers it manually. Upgrade path: parse the destination
# ref from the command if that ceiling is ever actually hit.
#
# Input: PostToolUse JSON on stdin. Bash shape:
#   { "tool_name": "Bash",
#     "tool_input": { "command": "git push ..." },
#     "tool_response": { ... } }
#
# Fail-open policy: on this script's own bugs (missing jq/gh, malformed JSON,
# no PR for the branch, ledger unreadable) we exit 0, optionally with a
# stderr warning — never strand a successful push.
#
# FOREIGN REPOS (HIMMEL-2034): a push can advance a PR on an upstream or on
# someone else's fork, and CodeRabbit is not ours to summon there. The guard
# lives in cr_trigger_post_review (scripts/lib/cr-trigger-ledger.sh) rather
# than here — that one function is the single seam every trigger post in this
# repo goes through, so scoping it there covers this hook, the `gh pr create`
# hook, and the forge seam at once.
set -euo pipefail

# ─── helpers ────────────────────────────────────────────────────────────────
warn() { echo "trigger-cr-on-push: $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/cr-trigger-ledger.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../lib/cr-trigger-ledger.sh" 2>/dev/null; then
    warn "WARNING: could not load cr-trigger-ledger.sh — cannot dedup safely; skipping this run"
    exit 0
fi

# Read stdin once (small payload — safe to buffer).
payload=""
if ! payload=$(cat); then
    warn "WARNING: could not read stdin; fail-open"
    exit 0
fi

# Fast-path: pure-bash substring check before any jq / network — same
# reasoning as trigger-cr-on-pr-create.sh's `create` token (see its header):
# match the single token `push`, immune to whitespace variants like
# `git  push` / `git push  origin`, at the cost of a few unrelated commands
# (`docker push`, `git push` in a comment) reaching the anchored regex below,
# which correctly rejects them.
case "$payload" in
    *push*) ;;  # might be real — fall through to the slow path
    *) exit 0 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
    warn "WARNING: jq not in PATH — cannot safely parse this event; if this pushed to an open PR, post '@coderabbitai review' on it manually"
    exit 0
fi

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null || true)
if [ -z "$cmd" ]; then
    exit 0
fi

# Strip carriage returns at the CAPTURE boundary (HIMMEL-2234), BEFORE any
# shape-matching below. A CRLF-encoded command reaches this hook with a CR
# glued to the end of every line, and jq on this platform can emit that CR
# TWICE for text that already carried one - so a continuation arrives as
# backslash-CR-CR-LF, which the single-CR substitution below never matched:
# the continuation went unjoined and the re-review nudge silently never fired
# on a perfectly ordinary multi-line push. Enumerating those variants at the
# use site is the exact widening game this hook comment warns against;
# normalising once here is the structural version of the same lesson. (Same
# class as the pin-dir fence in #2005, where a trailing CR disabled
# continuation detection entirely and left scripts unscanned.)
cmd=${cmd//$'\r'/}

# Undo bash's own line-continuation elision (a backslash immediately
# followed by a newline joins two lines into one logical command) before
# matching. Without this, a `git`/`push` split across a continuation --
# e.g. `git \` + newline + `  push origin main`, an ordinary shape for a
# long invocation -- silently never fires: `[[:space:]]+` between the two
# tokens can't cross the literal backslash byte, which is not whitespace.
# trigger-cr-on-pr-create.sh's header already lived through two rounds of
# widening a whitespace character class one gap at a time with no end in
# sight; the fix there was to stop matching whitespace shapes and match a
# single token instead. Same lesson here, applied structurally: normalize
# the one construct bash itself elides, rather than adding a `\\` alternate
# into the character class (the next gap — a continuation elsewhere in the
# command - would just reopen the same class of bug). Line endings are
# already normalised at the capture boundary above, so this only has to undo
# the bare-LF continuation bash itself elides.
cmd=${cmd//\\$'\n'/ }

# Anchored: `git push` only at a command position — same rationale and same
# POSIX bracket classes (no `\s`/`\b` — BSD grep would silently never match)
# as trigger-cr-on-pr-create.sh's `gh pr create` matcher.
# shellcheck disable=SC2016  # literal $ inside the character class — intentional
if ! echo "$cmd" | grep -qE '(^|[;&|`$(])[[:space:]]*git[[:space:]]+push([[:space:]]|$)'; then
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    warn "WARNING: gh not in PATH; could not check for an open PR to trigger CodeRabbit on"
    exit 0
fi

# Ask GitHub, not the local tool_response, whether this push actually landed
# on an open PR (see header). No PR for the current branch, or gh failing for
# any other reason (auth, network, closed/merged PR excluded below), is a
# quiet no-op — pushing before a PR exists is the common case, not an error.
pr_json=$(gh pr view --json number,url,headRefOid,state 2>/dev/null || true)
if [ -z "$pr_json" ]; then
    exit 0
fi

state=$(jq -r '.state // ""' <<<"$pr_json" 2>/dev/null || true)
if [ "$state" != "OPEN" ]; then
    exit 0
fi

head_sha=$(jq -r '.headRefOid // ""' <<<"$pr_json" 2>/dev/null || true)
num=$(jq -r '.number // ""' <<<"$pr_json" 2>/dev/null || true)
pr_url=$(jq -r '.url // ""' <<<"$pr_json" 2>/dev/null || true)
if [ -z "$head_sha" ] || [ -z "$num" ] || [ -z "$pr_url" ]; then
    warn "WARNING: could not parse the open PR's number/head/url from gh pr view — trigger the review manually if this push needs one"
    exit 0
fi

repo_path=${pr_url#*github.com/}
repo_path=${repo_path%%/pull/*}
if [ -z "$repo_path" ] || [ "$repo_path" = "$pr_url" ]; then
    warn "WARNING: could not parse owner/repo from '$pr_url'; trigger the review manually"
    exit 0
fi

# scan_existing=0 (see scripts/lib/cr-trigger-ledger.sh header): the per-PR
# comment scan cannot tell which head an old comment targeted, so it must not
# gate a new-head trigger here — the ledger's per-SHA check above already
# owns that decision.
cr_trigger_post_review "$head_sha" "$num" "$repo_path" 0

exit 0
