#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash matcher): block `gh pr create` while a CR
# review marker is pending for the current branch.
#
# Pairs with scripts/hooks/check-cr-before-push.sh (which writes the marker on
# pre-push) and the /pr-check slash command (which runs the review and clears
# the marker on clean output).
#
# Input: receives PreToolUse JSON on stdin. Schema:
#   { "tool_name": "Bash", "tool_input": { "command": "...", ... },
#     "cwd": "<session cwd>", ... }
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

# Read stdin once (small payload — safe to buffer). HIMMEL-2123: a bash
# builtin `read` instead of `$(cat)` avoids one external-process spawn per
# call (this hook fires on every Bash tool call). `read -d ''` reads to EOF
# and always returns non-zero there (no NUL delimiter in JSON), so it cannot
# distinguish a genuine stdin I/O error from ordinary EOF the way `cat`'s
# exit status could — but the fail-open outcome is identical either way: an
# empty $payload falls through the `*create*` case below to `exit 0`, same
# as the old explicit warn+exit0 branch.
payload=""
IFS= read -r -d '' payload 2>/dev/null || true

# Fast-path (N-1, task #22): pure-bash substring check on the raw JSON payload
# before shelling out to jq. The PreToolUse hook fires on every Bash call and
# the vast majority don't touch `gh pr create` at all — short-circuit those in
# ~sub-ms instead of paying ~20-50ms for stdin→jq→grep miss.
#
# The fast path is a cheap NECESSARY condition, nothing more: a false positive
# only costs the slow path (jq + the anchored regex below), which then
# correctly rejects it, but a false NEGATIVE silently un-gates a real
# `gh pr create`.
#
# Any multi-word literal here can produce one: the shell collapses nothing, so
# `gh  pr create` and `gh pr  create` are both valid and both miss a
# `gh pr create` (or `pr create`) substring. Matching the single token `create`
# ends that class — every spelling of `gh pr create` contains it, so no
# whitespace arrangement can slip past. The cost is that a few unrelated
# commands (`docker create`, `gh release create`) reach the anchored regex
# below, which correctly rejects them. Same reasoning, same shape as the
# PostToolUse sibling trigger-cr-on-pr-create.sh (HIMMEL-1362).
#
# (Preferred fix per task brief: narrow the PreToolUse matcher in
# .claude/settings.json with `"if": "Bash(gh pr create*)"` so the harness
# skips this hook entirely. That edit is documented in the PR body — apply
# it manually if/when the permission rules allow.)
case "$payload" in
    *create*) ;;  # might be a real invocation — fall through to slow path
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

# Strip carriage returns at the CAPTURE boundary (HIMMEL-2234). CRLF command
# text otherwise leaves a stray CR glued to the LAST token of every line, and
# every position-sensitive check below then silently stops matching: a
# $-anchored regex, an exact string comparison, a word-split token used as a
# lookup key. Doing it ONCE here rather than at each use site is the whole
# point of the rule (the same class fixed the pin-dir fence in #2005, where a
# trailing CR disabled line-continuation detection and left scripts
# UNSCANNED). Removing CRs can only make a deny check match MORE, never less,
# so the failure direction stays closed. Pure bash: a hook runs on every tool
# call and must not pay for a subprocess.
cmd=${cmd//$'\r'/}

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
#
# POSIX bracket classes, NOT `\s`/`\b` (HIMMEL-1372): those are GNU
# extensions. On BSD grep (macOS) `\s` matches a literal `s` and `\b` a
# literal `b`, so this ENTIRE matcher would never fire — a blocking gate that
# looks installed and does nothing on a whole platform. `\b` is replaced by an
# explicit end-of-token alternation: any character that cannot continue the
# `create` token, or end-of-line. NOT just whitespace — an argument-less
# invocation ends on a metacharacter instead (`gh pr create;`, `$(gh pr
# create)`, `gh pr create>out`, `gh pr create&&echo`), and a whitespace-only
# boundary would let every one of those spellings through a BLOCKING gate
# (CR codex-1). `-` is treated as a token character so `create-x` stays a
# different word. The whitespace quantifier sits OUTSIDE the
# alternation so an INDENTED continuation line (`git add . && \` / newline /
# `    gh pr create -t foo`) still matches. Kept BYTE-IDENTICAL to the
# PostToolUse sibling trigger-cr-on-pr-create.sh (HIMMEL-1362): the two are
# maintained as a pair and diverged once already — the sibling was still on the
# whitespace-only end-of-token class until HIMMEL-1975 re-converged them.
#
# HIMMEL-1975 — the command position also admits `{` and `!` (single characters
# that can only PRECEDE a command) and ONE leading reserved word or wrapper
# command. That closes the five measured bypasses:
#   { gh pr create -t x; }      if gh pr create -t x; then      ! gh pr create
#   then|else|elif|while|until|do gh pr create                  sudo gh pr create
# Two optional prefix groups, each of which must itself sit at a command
# position (the anchor above still applies):
#   1. reserved words + wrappers that take NO words of their own before the
#      command — if/then/else/elif/while/until/do/time, sudo/nohup/command/exec.
#   2. env/timeout/xargs, which DO carry words first (`env FOO=1`, `timeout 60`,
#      `xargs -I{}`), so a run of non-separator characters may sit between them
#      and `gh`. Bounded to `[^|;&]*` precisely so it can never cross into the
#      NEXT command — a run that could cross a separator would be
#      "match anywhere", which is what the narrow class exists to avoid.
# Deliberately NOT a tokenizer (that is HIMMEL-912's territory) and deliberately
# NOT "match anywhere": every pinned negative below stays negative, because none
# of echo/grep/git is a wrapper and neither `"` nor `#` is a command separator.
# Accepted residual: `<wrapper> … "gh pr create"` inside quotes after one of the
# three word-taking wrappers (e.g. `xargs grep 'gh pr create'`) matches. On this
# BLOCKING gate that is a false block, so it is bounded to those three heads
# only — the cheap direction is to over-block a wrapper line, never to un-gate.
# shellcheck disable=SC2016  # literal $ inside the character class — intentional
if ! echo "$cmd" | grep -qE '(^|[;&|`$({!])[[:space:]]*((if|then|else|elif|while|until|do|time|sudo|nohup|command|exec)[[:space:]]+)?((env|timeout|xargs)[[:space:]]+[^|;&]*)?gh[[:space:]]+pr[[:space:]]+create([^[:alnum:]_-]|$)'; then
    exit 0
fi

# Need git to look up the marker.
if ! command -v git >/dev/null 2>&1; then
    warn "WARNING: git not in PATH; fail-open"
    exit 0
fi

# Resolve the repo whose marker this call is about (HIMMEL-2035).
#
# The marker lives in the .git of the repo `gh pr create` actually runs in, and
# that is not necessarily the himmel checkout: an operator opens PRs from an
# adopter's repo or from a throwaway upstream clone too. Reading only
# CLAUDE_PROJECT_DIR was wrong in BOTH directions - a foreign `gh pr create`
# was un-gated, and a himmel branch of the SAME NAME false-blocked one.
#
# Order `.tool_input.cwd` then `.cwd` then CLAUDE_PROJECT_DIR (today's
# behaviour) - the first two mirror block-graphify-egress.sh:63,
# block-terminal-write-fence.sh:203 and cadence-approve-engines.sh:502.
#
# Measured on this harness (HIMMEL-2035 step 0, 2026-08-23): the Bash tool
# takes no `cwd` input, so `.tool_input.cwd` is ABSENT and `.cwd` is the
# SESSION cwd. That cwd does follow a `cd` issued by an earlier Bash call, so
# `cd <repo>` ... then ... `gh pr create` resolves correctly; a single compound
# `cd <repo> && gh pr create` still reports the pre-cd dir and stays un-gated.
# Fail-open by design - we do not parse `cd` out of the command (tokenizer
# territory, explicitly out of this hook's scope).
is_work_tree() {
    [ -n "${1:-}" ] || return 1
    [ -d "$1" ] || return 1
    [ "$(git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ]
}

# Candidates, newline-separated, in precedence order. EVERY candidate is
# validated on its own and the first one that RESOLVES wins — not the first one
# that merely exists (CR round 1 codex-3): a `.tool_input.cwd` that is present
# but is not a work tree must never shadow a perfectly good `.cwd`.
#
# jq-less box (CR round 1 codex-2): without a fallback the hook silently
# reverted to CLAUDE_PROJECT_DIR and reproduced exactly the cross-repo bug this
# change closes. The extraction below is the same best-effort shape as
# extract_command's fallback above, minus `grep -P` (GNU-only): plain `grep -o`
# is supported by both GNU and BSD grep. It emits EVERY `"cwd"` in the payload,
# not just the first (CR round 2 codex-1) — key order in a JSON object is not
# guaranteed, so keeping only the first would let an invalid `.tool_input.cwd`
# swallow a valid `.cwd` and drop back to CLAUDE_PROJECT_DIR. What the jq-less
# path loses is the ORDER of the two, never a candidate. Safety does not rest on
# the parse either way: a misparse cannot select a WRONG repo, because every
# candidate must still pass is_work_tree and a failing one falls through.
cwd_candidates=""
if command -v jq >/dev/null 2>&1; then
    # `| tr -d '\r'`: on Windows jq is a NATIVE build and writes CRLF, so every
    # line but the last arrives with a trailing CR. An embedded CR makes the
    # `[ -d ]` probe miss, and the candidate silently loses to the next one —
    # which is exactly a valid `.tool_input.cwd` falling through to `.cwd`
    # (measured 2026-08-23; the single-value form hid it because `$( )` strips
    # only the trailing newline and a TRAILING CR happened to be tolerated).
    cwd_candidates=$(jq -r '[.tool_input.cwd, .cwd] | map(select(type == "string" and . != "")) | .[]' <<<"$payload" 2>/dev/null | tr -d '\r' || true)
else
    # Order is enforced without parsing nested JSON (CR round 3 codex-1): the
    # payload after the LAST `"tool_input"` can only reach a `"cwd"` that is
    # inside that object — unless the object has none, in which case the value
    # found is the top-level one and putting it first changes nothing, because
    # it is then the only candidate. So `_ti_cwd` is `.tool_input.cwd` whenever
    # one exists, and the full ordered list follows it. A duplicate costs one
    # extra `[ -d ]` probe and nothing else.
    #
    # Accepted limit, deliberately NOT fixed here (CR round 3 codex-2): `[^"]*`
    # stops at an ESCAPED quote and the unescaping handles `\\` only, so a cwd
    # containing `\"` or a `\uXXXX` escape is not recovered. Writing a JSON
    # string unescaper in shell to chase a directory name with a quote in it is
    # the wrong trade — and the failure direction is already the safe one: an
    # unrecovered value fails is_work_tree and falls through to
    # CLAUDE_PROJECT_DIR, i.e. exactly the pre-2035 behaviour, never a wrong repo.
    _cwd_grep() {
        printf '%s' "$1" \
            | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed 's/.*:[[:space:]]*"//; s/"$//; s/\\\\/\\/g' | tr -d '\r' || true
    }
    _ti_cwd=$(_cwd_grep "${payload##*\"tool_input\"}" | head -1)
    cwd_candidates=$(printf '%s\n%s' "$_ti_cwd" "$(_cwd_grep "$payload")")
fi

repo_dir=""
while IFS= read -r _cand; do
    [ -n "$_cand" ] || continue
    if is_work_tree "$_cand"; then repo_dir="$_cand"; break; fi
done <<CWD_CANDIDATES
$cwd_candidates
${CLAUDE_PROJECT_DIR:-}
CWD_CANDIDATES
if [ -z "$repo_dir" ]; then
    warn "WARNING: no git work tree from the payload cwd or CLAUDE_PROJECT_DIR; fail-open"
    exit 0
fi

# Resolve the branch whose marker we should check.
#
# `gh pr create` runs in a worktree on the FEATURE branch, but repo_dir may
# be the main checkout (typically on `main`) - it is whenever the resolution
# above fell through to CLAUDE_PROJECT_DIR.
# Looking up the repo_dir branch would then check cr-pending/main (empty) and
# miss the marker entirely (HIMMEL-213). The `--head <branch>` flag on the
# extracted command names the PR's source branch explicitly and is
# worktree-independent, so prefer it. Handle both `--head feat/x` and
# `--head=feat/x`. Fall back to the repo_dir branch when --head is absent
# (do not regress that path — a missed block beats a false block).
head_branch=""
repo_nwo=""
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
        --repo=*) repo_nwo="${1#--repo=}" ;;
        --repo|-R)
            if [ "$#" -ge 2 ]; then repo_nwo="$2"; fi
            ;;
    esac
    shift
done

# FR1a (HIMMEL-2035): `--repo <owner>/<name>` names the PR's TARGET repo, which
# for the ordinary fork/upstream flow (`origin` = your fork, `--repo` = upstream)
# is deliberately not the local one. The marker, though, always belongs to the
# repo the branch lives in — the one resolved above — so a divergence is
# INFORMATION, not a reason to skip the gate.
#
# The plan's first cut exited 0 here. That was a fail-open on exactly the shape
# this ticket exists for: an upstream contribution from a fork carries a
# divergent `--repo` on every single `gh pr create`, so the gate would have
# skipped itself on the ticket's own motivating scenario (CR codex-1). It also
# un-gated a shape that is gated TODAY, since the pre-2035 hook ignored `--repo`
# entirely. So: warn, then fall through to the ordinary marker check. Blocking
# stays recoverable the usual way (`/pr-check`, or `SKIP_CR=1 git push`).
if [ -n "$repo_nwo" ]; then
    # Reuse the SHARED canonicalizer (scripts/lib/nwo.sh, HIMMEL-2034) instead of
    # re-deriving origin-URL parsing here — it already handles the host segment,
    # ssh userinfo, an explicit port, and GitHub's case-insensitivity, each closed
    # by its own CR round. Sourced HERE, inside the `gh pr create` branch, so the
    # ~1s Git-Bash fork it costs is never paid by this PreToolUse hook's common
    # (non-matching) case. Absent lib -> no advisory, never a failure: the marker
    # check below is what actually gates, and it is unaffected either way.
    _nwo_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/nwo.sh"
    if [ -f "$_nwo_lib" ]; then
        # shellcheck disable=SC1090,SC1091  # runtime-resolved path; not followable statically
        . "$_nwo_lib"
        want_nwo=""; have_nwo=""; origin_url_nwo=""
        _cmg_canon_nwo "$repo_nwo" && want_nwo="$_CMG_CANON"
        if _origin_probe=$(cd "$repo_dir" && _cmg_local_nwo 2>/dev/null); then
            origin_url_nwo="$_origin_probe"
        fi
        _cmg_canon_nwo "$origin_url_nwo" && have_nwo="$_CMG_CANON"
        if [ -z "$want_nwo" ] || [ -z "$have_nwo" ] || ! _cmg_nwo_eq "$want_nwo" "$have_nwo"; then
            warn "advisory: --repo ${repo_nwo} targets a different repo than the resolved origin (${have_nwo:-<none>}); the marker checked below is THIS repo's, keyed by branch"
        fi
    fi
fi

resolved_from_head=0
if [ -n "$head_branch" ]; then
    # gh accepts `--head <owner>:<branch>` to target a fork. The marker is
    # keyed by the bare branch name (check-cr-before-push writes it from the
    # local branch), so strip a leading `owner:` segment if present.
    branch="${head_branch##*:}"
    resolved_from_head=1
else
    branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
fi
if [ -z "$branch" ]; then
    warn "WARNING: no branch resolved (no --head, detached HEAD?); fail-open"
    exit 0
fi

git_dir=$(git -C "$repo_dir" rev-parse --git-common-dir 2>/dev/null || true)
if [ -z "$git_dir" ]; then
    warn "WARNING: could not resolve .git dir; fail-open"
    exit 0
fi
# git rev-parse --git-common-dir returns either an absolute path or a path
# relative to the repo_dir; normalize to absolute. We use --git-common-dir
# (shared .git) not --git-dir (per-worktree) so the marker lookup works
# regardless of which worktree gh pr create is invoked from.
case "$git_dir" in
    /*|[A-Za-z]:[/\\]*) ;;  # already absolute (POSIX or Windows drive)
    *) git_dir="${repo_dir}/${git_dir}" ;;
esac

marker="${git_dir}/cr-pending/${branch}"

# No marker → nothing pending → allow.
if [ ! -f "$marker" ]; then
    exit 0
fi

# When the branch was resolved from `--head`, it may differ from the
# repo_dir branch (the worktree-vs-main pattern HIMMEL-213 fixes). In that
# case `git -C $repo_dir rev-parse HEAD` is main's HEAD, NOT the head
# branch's HEAD, so the SHA-match refinement below would compare the wrong
# tips. Simplest correct behaviour: the presence of a marker for the head
# branch means a CR is pending for it — BLOCK. (Cross-worktree SHA-staleness
# refinement is out of scope; a present marker is never a false block here
# because check-cr-before-push only writes it when a CR is genuinely owed.)
if [ "$resolved_from_head" = "1" ]; then
    echo "CR review pending for ${branch}. Run /pr-check (or /pr-review-toolkit:review-pr) first. After review passes, marker auto-clears." >&2
    exit 2
fi

current_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
if [ -z "$current_head" ]; then
    warn "WARNING: could not resolve HEAD; fail-open"
    exit 0
fi

# Marker format (set by check-cr-before-push.sh): "<iso-date> | <sha>[ | <lane>]"
# (HIMMEL-303 appends an optional 3rd lane field; we read only field 2 here.)
# FS is a literal " | " — use a bracket class [|] not \| (gawk warns on \| and
# treats it as alternation, splitting on every space → field 2 becomes "|").
marker_sha=$(awk -F' [|] ' '{print $2; exit}' "$marker" 2>/dev/null || true)
short_head=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo "$current_head")

if [ "$marker_sha" = "$current_head" ]; then
    echo "CR review pending for ${branch} (HEAD=${short_head}). Run /pr-check (or /pr-review-toolkit:review-pr) first. After review passes, marker auto-clears." >&2
    exit 2
fi

# Marker exists but SHA mismatch — new commits were added after the last marker.
# Block as a stale-marker re-review case.
echo "CR review pending for ${branch} (HEAD=${short_head}) — stale marker — re-review needed. Run /pr-check (or /pr-review-toolkit:review-pr) first. After review passes, marker auto-clears." >&2
exit 2
