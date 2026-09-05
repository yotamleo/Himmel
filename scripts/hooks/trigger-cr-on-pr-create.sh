#!/usr/bin/env bash
# Claude Code PostToolUse hook (Bash matcher): after a SUCCESSFUL `gh pr create`,
# post an `@coderabbitai review` trigger comment on the new PR (HIMMEL-1362).
#
# CodeRabbit's `auto_review` is OFF on this repo by design (.coderabbit.yaml),
# so the App reviews a PR ONLY when someone posts an explicit `@coderabbitai
# review` comment. On 2026-07-29 an autonomous chain left triggering to agent
# discretion: every open PR ended up with NO CodeRabbit review at its head, and
# — worse — CodeRabbit's "Review skipped: automatic reviews are disabled"
# success check-run is indistinguishable from a clean review to any gate that
# reads only the status. This hook makes the trigger STRUCTURAL rather than
# discretionary: a `gh pr create` that opens a PR is ALWAYS followed by the
# trigger comment.
#
# A hook (not a tweak to scripts/lib/forge-github.sh) so it also catches the
# DIRECT `gh pr create` invocations that bypass the lib — exactly the
# agent-discretion path that failed tonight.
#
# Pairs with:
#   - PreToolUse  check-cr-marker-on-pr-create.sh  (gates the create), and
#   - check-ci.sh `skipped`/`absent` arms           (the BACKSTOP: if this
#     hook's post ever fails, the gate refuses green until a genuine review
#     exists at head).
#
# ONE REVIEW PER HEAD SHA (HIMMEL-1906): dedup used to be keyed per PR (scan
# for ANY existing `@coderabbitai review` comment) — that made sense when this
# hook only fired at PR creation, but it silently blackholed every later fix
# round: a push after the first review left the PR's comment list non-empty,
# so the per-PR scan always short-circuited, the merge gate correctly refused
# the "Review skipped" head, and nothing ever re-triggered (PRs #1717/#1718).
# Dedup is now keyed by head SHA via the shared ledger in
# scripts/lib/cr-trigger-ledger.sh — the SAME ledger a sibling hook,
# trigger-cr-on-push.sh, uses to trigger a review on a PUSH that advances an
# open PR's head. The per-PR comment scan is kept here ONLY as a secondary
# guard (a reused/reopened PR number can carry a stale trigger comment); it no
# longer gates the push path, where it would reintroduce the same bug.
#
# Input: PostToolUse JSON on stdin. Bash shape:
#   { "tool_name": "Bash",
#     "tool_input": { "command": "gh pr create ..." },
#     "tool_response": { ...carrying the new PR URL gh printed to stdout... } }
#
# Exit semantics — ADVISORY / non-blocking, exit 0 in EVERY case. The PR is
# already created by the time a PostToolUse hook runs; a hard block here could
# not un-create it and would only confuse the model. A failed post (no auth, no
# network, API error) WARNS to stderr and exits 0; the gate is the structural
# backstop that refuses green until a real review lands at head.
#
# Fail-open policy: on THIS script's own bugs (missing jq, malformed JSON) we
# exit 0 with a stderr warning — never strand a successful PR-create.
set -euo pipefail

# ─── helpers ────────────────────────────────────────────────────────────────
warn() { echo "trigger-cr-on-pr-create: $*" >&2; }

# Shared per-head-SHA ledger (HIMMEL-1906) — see scripts/lib/cr-trigger-ledger.sh
# for the dedup contract, and for cr_trigger_repo_armed (HIMMEL-2034), the
# foreign-repo guard. Sourcing failure fails CLOSED for the POST specifically
# (warn + exit 0, post nothing): without the lib this hook can neither dedup
# nor tell whose repo the PR is on. The hook itself still exits 0, so a
# successful PR create is never stranded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/cr-trigger-ledger.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../lib/cr-trigger-ledger.sh" 2>/dev/null; then
    # Was: fall back to a per-PR comment scan and post anyway. That fallback is
    # gone (HIMMEL-2034) — this lib now also owns cr_trigger_repo_armed, the
    # check that keeps the trigger off FOREIGN repos, so a run without it
    # cannot tell whose PR it is about to comment on. Not posting is the cheap
    # failure: the merge gate refuses green until a review lands at head, which
    # is loud, whereas a comment on a stranger's PR is not ours to make.
    warn "WARNING: could not load cr-trigger-ledger.sh — cannot verify this PR's repo is ours; not triggering CodeRabbit. Post '@coderabbitai review' manually if this PR is on one of our repos"
    exit 0
fi

# Read stdin once (small payload — safe to buffer).
payload=""
if ! payload=$(cat); then
    warn "WARNING: could not read stdin; fail-open"
    exit 0
fi

# Fast-path: pure-bash substring check before any jq / network. PostToolUse
# fires on every Bash call and the vast majority have nothing to do with
# `gh pr create`. `gh pr create` has no JSON-special chars, so a substring scan
# cannot miss a real invocation; a false positive here only buys the slow path
# (jq + the anchored regex below), which then correctly rejects it.
# The fast path is a cheap NECESSARY condition, nothing more — it exists only
# to skip the jq+regex work on the overwhelming majority of Bash calls, and it
# must never be able to produce a false negative.
#
# Any multi-word literal here can: the shell collapses nothing, so `gh  pr
# create` and `gh pr  create` are both valid and both miss a `gh pr create` or
# `pr create` substring. Two successive CR rounds found exactly that, one
# whitespace position apart — a regress with no end, because there is always
# another gap to widen. Matching the single token `create` ends the class:
# every spelling of `gh pr create` contains it, so no whitespace arrangement
# can slip past. The cost is that a few unrelated commands (`docker create`,
# `gh release create`) reach the anchored regex below, which correctly
# rejects them.
case "$payload" in
    *create*) ;;  # might be real — fall through to the slow path
    *) exit 0 ;;
esac

# Everything past the fast-path needs jq. A text-only fallback cannot honour
# the "scan ONLY .tool_response" invariant (see extract_pr_url): without a
# JSON parser there is no reliable boundary between tool_input and
# tool_response (key order is not guaranteed), so a grep over the raw payload
# can pick up a URL embedded in the command or PR title and post the trigger
# on the WRONG PR. A wrong-PR comment is worse than no comment — the gate's
# skipped/absent arms backstop a MISSING review at head, but nothing catches a
# spurious one. So: no jq → warn + exit 0 (fail-open per the header policy).
# The warning can fire on a fast-path false positive (e.g. `echo "gh pr
# create"`); acceptable noise in the rare jq-less environment. Deliberate
# divergence from the PreToolUse sibling's grep -oP fallback: the sibling only
# GATES on the command (worst case there: a missed block, backstopped by the
# merge gate), while this hook POSTS to a PR it names.
if ! command -v jq >/dev/null 2>&1; then
    warn "WARNING: jq not in PATH — cannot safely isolate the new PR URL from tool_response; if this created a PR, post '@coderabbitai review' on it manually (the merge gate refuses green until a review lands at head)"
    exit 0
fi

# Extract tool_input.command (jq guaranteed by the guard above).
extract_command() {
    local input="$1"
    jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null
}

cmd=$(extract_command "$payload" || true)
if [ -z "$cmd" ]; then
    exit 0
fi

# Anchored: `gh pr create` only at a command position — line-start or after
# a command-separator (`;`, `&`, `|`, backtick, `$(` / `(`). Same rationale as
# the PreToolUse sibling (S-1, task #22): avoids false positives on
#   echo "gh pr create docs"     (string literal)
#   cat foo | grep 'gh pr create' (substring inside another command)
#   # TODO: gh pr create later    (comment)
# while still catching real calls hidden in subshells:
#   $(gh pr create -t foo)        (command substitution)
#   `gh pr create -t foo`         (legacy backtick substitution)
# Deliberate divergence from the sibling (glm-3, round 2): `\s*` sits OUTSIDE
# the alternation here. grep matches per LINE, so `^` already anchors every
# line of a multi-line command — but an INDENTED continuation line, ordinary
# in this harness:
#   git add . && \
#     gh pr create -t foo
# starts with whitespace, which `(^|[...]\s*)` rejects: a silent false
# negative that leaves the PR unreviewed, the exact failure HIMMEL-1362
# exists to close. `(^|[...])\s*` accepts it while keeping every negative
# case above negative.
# shellcheck disable=SC2016  # literal $ inside the character class — intentional
# POSIX bracket classes, NOT `\s`/`\b`: those are GNU extensions. On BSD grep
# (macOS) `\s` matches a literal `s` and `\b` a literal `b`, so the ENTIRE
# matcher would silently never fire — the gate would look installed and do
# nothing on a whole platform (CR codex-2 + glm-3, independently agreed).
# `\b` is replaced by an explicit "end of token" alternation.
#
# HIMMEL-1975 — this line is now BYTE-IDENTICAL to the PreToolUse sibling
# check-cr-marker-on-pr-create.sh; keep it that way (HIMMEL-1362 lockstep, and
# the two have already diverged once). Two changes landed together:
#   - the end-of-token class widened from `[[:space:]]` to `[^[:alnum:]_-]`, so
#     an argument-less invocation ending on a metacharacter (`gh pr create;`,
#     `$(gh pr create)`, `gh pr create>out`) is no longer silently skipped —
#     the sibling has had this since HIMMEL-1372, this twin had not;
#   - the command position gained `{` / `!` plus one optional reserved-word or
#     wrapper prefix, closing `{ gh pr create; }`, `if gh pr create`,
#     `! gh pr create`, `then|else|elif|while|until|do gh pr create` and
#     `sudo|env|nohup|timeout|command|exec|xargs … gh pr create`.
# The full rationale (why exactly these heads, why `[^|;&]*` is bounded, and
# why this is not a tokenizer — HIMMEL-912) lives on the sibling, next to the
# same line; it is not duplicated here so the two cannot drift in prose either.
if ! echo "$cmd" | grep -qE '(^|[;&|`$({!])[[:space:]]*((if|then|else|elif|while|until|do|time|sudo|nohup|command|exec)[[:space:]]+)?((env|timeout|xargs)[[:space:]]+[^|;&]*)?gh[[:space:]]+pr[[:space:]]+create([^[:alnum:]_-]|$)'; then
    exit 0
fi

# Extract the new PR URL from the tool RESPONSE (gh prints it to stdout). Scan
# ONLY strings under .tool_response — never .tool_input — so a URL embedded in
# the PR title or command cannot be mistaken for gh's output. Recursing over
# every string makes this robust to Claude Code version differences in the
# tool_response field name (stdout / output / content / ...). jq-only by
# design: the no-jq case already warned and exited above — a text-only scan
# cannot honour the tool_response-only invariant.
extract_pr_url() {
    local input="$1"
    printf '%s' "$input" \
        | jq -r '(.tool_response // {}) | .. | select(type=="string")' 2>/dev/null \
        | grep -oE 'https://github\.com/[^/" ]+/[^/" ]+/pull/[0-9]+' | head -1 || true
}

pr_url=$(extract_pr_url "$payload" || true)
if [ -z "$pr_url" ]; then
    # No PR URL in the response → the create opened no PR (it failed, --dry-run
    # prints no /pull/<n> URL, or a PR already exists). Nothing to do.
    exit 0
fi

# Parse owner/repo/number from the URL.
num=${pr_url##*/}               # 1461
rest=${pr_url%/pull/*}          # https://github.com/owner/repo
repo_path=${rest#*github.com/}  # owner/repo
if [ -z "$num" ] || [ -z "$repo_path" ] || [ "$repo_path" = "$rest" ]; then
    warn "WARNING: could not parse owner/repo/number from '$pr_url'; trigger the review manually"
    exit 0
fi

# HIMMEL-2034: `gh pr create` can open a PR on ANY repo — an upstream, someone
# else's fork — and this hook used to comment on whatever it was. Check before
# any gh call, so a foreign PR costs no API round-trip either. Redundant with
# the same check inside cr_trigger_post_review (that one covers the sibling
# push hook and the forge seam); kept here because the head-SHA fallback below
# posts directly, without going through that function.
if ! cr_trigger_repo_armed "$repo_path"; then
    warn "$repo_path: $CR_TRIGGER_FOREIGN_ADVISORY"
    exit 0
fi

# Need gh to look up the head SHA, to scan for an existing trigger, and to
# post the comment.
if ! command -v gh >/dev/null 2>&1; then
    warn "WARNING: gh not in PATH; could not trigger CodeRabbit on PR #$num — post '@coderabbitai review' manually"
    exit 0
fi

# Head SHA for the ledger key. A fresh `gh pr create` has exactly one head,
# but reading it back from the PR object (rather than trusting a local ref)
# keeps this correct even if something else moved HEAD between the create and
# this hook running.
head_sha=$(gh pr view "$num" --repo "$repo_path" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
if [ -n "$head_sha" ]; then
    # scan_existing=1: a reused/reopened PR number can carry a stale trigger
    # comment from a prior life — see the header note.
    cr_trigger_post_review "$head_sha" "$num" "$repo_path" 1
    exit 0
fi
warn "WARNING: could not resolve the head SHA for PR #$num — falling back to the per-PR comment scan"

# Fallback (head SHA unresolvable): the pre-HIMMEL-1906
# per-PR scan. Idempotency (one review per PR): if a `@coderabbitai (full
# )?review` trigger already exists on the PR, do not double-post.
existing=$(gh api "repos/$repo_path/issues/$num/comments" --paginate --jq '.[].body' 2>/dev/null || true)
if printf '%s\n' "$existing" | grep -qiE '@coderabbitai[[:space:]]+(full[[:space:]]+)?review'; then
    exit 0
fi

# Post the trigger. Non-blocking on failure: the PR is already created; the
# gate's skipped/absent arms are the backstop that refuses green without it.
if gh pr comment "$num" --repo "$repo_path" --body "@coderabbitai review" >/dev/null 2>&1; then
    echo "trigger-cr-on-pr-create: posted @coderabbitai review on PR #$num ($repo_path)" >&2
else
    warn "WARNING: failed to post @coderabbitai review on PR #$num — post it manually; the merge gate refuses green until a genuine review lands at head"
fi

exit 0
