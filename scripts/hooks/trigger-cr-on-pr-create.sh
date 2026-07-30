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
# ONE REVIEW PER PR, NOT PER PUSH: this hook fires only on PR CREATION (a
# PostToolUse on `gh pr create`), never on push. It also scans the PR for an
# existing `@coderabbitai (full )?review` comment before posting, so a retried
# or idempotent create never double-posts.
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
if ! echo "$cmd" | grep -qE '(^|[;&|`$(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
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

# Need gh to scan for an existing trigger and to post the comment.
if ! command -v gh >/dev/null 2>&1; then
    warn "WARNING: gh not in PATH; could not trigger CodeRabbit on PR #$num — post '@coderabbitai review' manually"
    exit 0
fi

# Idempotency (one review per PR): if a `@coderabbitai (full )?review` trigger
# already exists on the PR, do not double-post. Network call — only reached on a
# real PR creation, so the cost is acceptable.
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
