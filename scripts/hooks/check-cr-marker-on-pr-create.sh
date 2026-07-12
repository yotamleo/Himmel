#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash matcher): block `gh pr create` while a CR
# review marker is pending for the current branch.
#
# Pairs with scripts/hooks/check-cr-before-push.sh (which writes the marker on
# pre-push) and the /pr-check slash command (which runs the review and clears
# the marker on clean output).
#
# Input: receives PreToolUse JSON on stdin. Schema:
#   { "tool_name": "Bash", "tool_input": { "command": "...", ... }, ... }
#
# Output / exit semantics (per Claude Code hooks docs):
#   - exit 0  → allow tool use
#   - exit 2  → block tool use; stderr is shown to the model + user
#   - other   → non-blocking error (tool proceeds)
#
# Fail-open policy: if THIS script errors (missing jq, missing git, malformed
# JSON, etc.), exit 0 with a stderr warning. We never block on our own bugs —
# the cost of a false block (broken PR-create workflow) outweighs the cost of a
# missed block (the human or /pr-check still catches it).
#
# Dependency: prefers `jq` for JSON parsing; falls back to a `grep -oP` regex
# extraction if `jq` is unavailable.
set -euo pipefail

# ─── helpers ────────────────────────────────────────────────────────────────
warn() { echo "check-cr-marker-on-pr-create: $*" >&2; }

# Read stdin once (small payload — safe to buffer)
payload=""
if ! payload=$(cat); then
    warn "WARNING: could not read stdin; fail-open"
    exit 0
fi

# Fast-path (N-1, task #22): pure-bash substring check on the raw JSON payload
# before shelling out to jq. The PreToolUse hook fires on every Bash call and
# the vast majority don't touch `gh pr create` at all — short-circuit those in
# ~sub-ms instead of paying ~20-50ms for stdin→jq→grep miss.
#
# Trade-off: this matches the substring `gh pr create` anywhere in the raw
# JSON, including inside a string literal. That's fine — false positives here
# only cost us the slow path (jq + the anchored regex below), which then
# correctly rejects the false positive. False *negatives* would be a real
# bug, but the JSON-escaped form of `gh pr create` is still `gh pr create`
# (no special chars in the literal), so a substring scan can't miss a real
# invocation.
#
# (Preferred fix per task brief: narrow the PreToolUse matcher in
# .claude/settings.json with `"if": "Bash(gh pr create*)"` so the harness
# skips this hook entirely. That edit is documented in the PR body — apply
# it manually if/when the permission rules allow.)
case "$payload" in
    *"gh pr create"*) ;;  # might be a real invocation — fall through to slow path
    *) exit 0 ;;
esac

# Extract tool_input.command. Try jq first, fall back to grep -oP.
extract_command() {
    local input="$1"
    if command -v jq >/dev/null 2>&1; then
        # -r raw, // "" coalesces missing to empty string. `2>/dev/null` swallows
        # jq parse errors; we'll detect via empty output below.
        jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null
        return
    fi
    # Fallback: pull the first "command":"…" value. Handles \" escapes minimally.
    # Not a full JSON parser; good enough for the well-formed payloads Claude
    # Code sends. Returns empty on no match.
    echo "$input" | grep -oP '"command"\s*:\s*"(\\.|[^"\\])*"' \
        | head -1 \
        | sed -E 's/^"command"\s*:\s*"(.*)"$/\1/' \
        | sed 's/\\"/"/g'
}

cmd=$(extract_command "$payload" || true)

# Nothing to do if we couldn't extract a command (malformed JSON, or this
# matcher fired for a non-Bash tool somehow). Fail-open.
if [ -z "$cmd" ]; then
    exit 0
fi

# Only gate `gh pr create`. Anything else passes.
# Anchored: matches `gh pr create` only at a command position — start-of-string
# or after a command-separator: `;`, `&`, `|`, backtick (legacy substitution),
# or `$(` / `(` (subshell / command substitution). Avoids false positives from
# echo/heredoc/comment/pipeline-grep like:
#   echo "gh pr create docs"            (string literal)
#   cat foo | grep 'gh pr create'       (substring inside another command)
#   # TODO: gh pr create later          (comment)
# AND catches real invocations hidden inside subshells:
#   $(gh pr create -t foo)              (command substitution)
#   `gh pr create -t foo`               (legacy backtick substitution)
# (S-1 fix, task #22; backtick+$( coverage added per review on #46.)
# shellcheck disable=SC2016  # literal $ inside the character class — intentional
if ! echo "$cmd" | grep -qE '(^|[;&|`$(]\s*)gh\s+pr\s+create\b'; then
    exit 0
fi

# Need git + a project dir to look up the marker.
project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ]; then
    warn "WARNING: CLAUDE_PROJECT_DIR unset; fail-open"
    exit 0
fi
if ! command -v git >/dev/null 2>&1; then
    warn "WARNING: git not in PATH; fail-open"
    exit 0
fi

# Resolve the branch whose marker we should check.
#
# `gh pr create` runs in a worktree on the FEATURE branch, but
# CLAUDE_PROJECT_DIR points at the main checkout (typically on `main`).
# Looking up the project_dir branch would check cr-pending/main (empty) and
# miss the marker entirely (HIMMEL-213). The `--head <branch>` flag on the
# extracted command names the PR's source branch explicitly and is
# worktree-independent, so prefer it. Handle both `--head feat/x` and
# `--head=feat/x`. Fall back to the project_dir branch when --head is absent
# (do not regress that path — a missed block beats a false block).
head_branch=""
# Disable pathname expansion before the unquoted split: we want word-splitting
# of $cmd into argv, but NOT glob expansion — a title like `--title "fix *.md"`
# must not expand `*.md` against the cwd and inject spurious tokens.
set -f
# shellcheck disable=SC2086  # intentional word-splitting of the command
set -- $cmd
set +f
while [ "$#" -gt 0 ]; do
    case "$1" in
        --head=*) head_branch="${1#--head=}" ;;
        --head|-H)
            if [ "$#" -ge 2 ]; then head_branch="$2"; fi
            ;;
    esac
    shift
done

resolved_from_head=0
if [ -n "$head_branch" ]; then
    # gh accepts `--head <owner>:<branch>` to target a fork. The marker is
    # keyed by the bare branch name (check-cr-before-push writes it from the
    # local branch), so strip a leading `owner:` segment if present.
    branch="${head_branch##*:}"
    resolved_from_head=1
else
    branch=$(git -C "$project_dir" branch --show-current 2>/dev/null || true)
fi
if [ -z "$branch" ]; then
    warn "WARNING: no branch resolved (no --head, detached HEAD?); fail-open"
    exit 0
fi

git_dir=$(git -C "$project_dir" rev-parse --git-common-dir 2>/dev/null || true)
if [ -z "$git_dir" ]; then
    warn "WARNING: could not resolve .git dir; fail-open"
    exit 0
fi
# git rev-parse --git-common-dir returns either an absolute path or a path
# relative to the project_dir; normalize to absolute. We use --git-common-dir
# (shared .git) not --git-dir (per-worktree) so the marker lookup works
# regardless of which worktree gh pr create is invoked from.
case "$git_dir" in
    /*|[A-Za-z]:[/\\]*) ;;  # already absolute (POSIX or Windows drive)
    *) git_dir="${project_dir}/${git_dir}" ;;
esac

marker="${git_dir}/cr-pending/${branch}"

# No marker → nothing pending → allow.
if [ ! -f "$marker" ]; then
    exit 0
fi

# When the branch was resolved from `--head`, it may differ from the
# project_dir branch (the worktree-vs-main pattern HIMMEL-213 fixes). In that
# case `git -C $project_dir rev-parse HEAD` is main's HEAD, NOT the head
# branch's HEAD, so the SHA-match refinement below would compare the wrong
# tips. Simplest correct behaviour: the presence of a marker for the head
# branch means a CR is pending for it — BLOCK. (Cross-worktree SHA-staleness
# refinement is out of scope; a present marker is never a false block here
# because check-cr-before-push only writes it when a CR is genuinely owed.)
if [ "$resolved_from_head" = "1" ]; then
    echo "CR review pending for ${branch}. Run /pr-check (or /pr-review-toolkit:review-pr) first. After review passes, marker auto-clears." >&2
    exit 2
fi

current_head=$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || true)
if [ -z "$current_head" ]; then
    warn "WARNING: could not resolve HEAD; fail-open"
    exit 0
fi

# Marker format (set by check-cr-before-push.sh): "<iso-date> | <sha>[ | <lane>]"
# (HIMMEL-303 appends an optional 3rd lane field; we read only field 2 here.)
# FS is a literal " | " — use a bracket class [|] not \| (gawk warns on \| and
# treats it as alternation, splitting on every space → field 2 becomes "|").
marker_sha=$(awk -F' [|] ' '{print $2; exit}' "$marker" 2>/dev/null || true)
short_head=$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null || echo "$current_head")

if [ "$marker_sha" = "$current_head" ]; then
    echo "CR review pending for ${branch} (HEAD=${short_head}). Run /pr-check (or /pr-review-toolkit:review-pr) first. After review passes, marker auto-clears." >&2
    exit 2
fi

# Marker exists but SHA mismatch — new commits were added after the last marker.
# Block as a stale-marker re-review case.
echo "CR review pending for ${branch} (HEAD=${short_head}) — stale marker — re-review needed. Run /pr-check (or /pr-review-toolkit:review-pr) first. After review passes, marker auto-clears." >&2
exit 2
