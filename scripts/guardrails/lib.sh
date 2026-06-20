#!/usr/bin/env bash
# scripts/guardrails/lib.sh - shared git-state predicates.
#
# Sourced by:
#   - scripts/hooks/check-worktree-isolation.sh
#   - scripts/hooks/check-pr-lane-isolation.sh
#   - scripts/hooks/check-merged-branch.sh
#   - scripts/hooks/check-push-target.sh
#   - scripts/hooks/block-edit-on-main.sh
#   - scripts/guardrails/guard-gh.sh
#
# Contract: each predicate returns one of:
#   0 - true  (predicate holds)
#   1 - false (predicate does not hold)
#   2 - internal error: predicate cannot be evaluated (git missing, repo
#       broken, required ref absent). Callers MUST treat rc=2 as fail-closed.
#
# rc=2 is silent (predicates do NOT print to stderr); the caller is the right
# place to emit a context-specific diagnostic on fail-closed paths. Use the
# `guard_call` helper below in `if` contexts - bare `if predicate; then ...`
# collapses rc=1 and rc=2 into one branch and silently fails-OPEN on errors.
#
# Each predicate accepts an optional first arg DIR (defaults to PWD).
# Exception: `is_main_ref` takes a ref string (not a directory) as its only
# arg; see its docstring.

set -uo pipefail

# guard_call PREDICATE [ARGS...]
# Wraps a predicate call so rc=2 (internal error) becomes an immediate
# fail-closed exit instead of being silently demoted to "false" by bash's
# `if`. Prints a diagnostic to stderr identifying the predicate that errored.
# Use as:   if guard_call is_on_main "$dir"; then ...
# Callers that need finer control should branch explicitly on $? = 0/1/2.
guard_call() {
    local name="$1"; shift
    "$name" "$@"
    local rc=$?
    if [ "$rc" -eq 2 ]; then
        echo "guardrails: $name returned rc=2 (internal error) - fail-closed" >&2
        exit 2
    fi
    return "$rc"
}

# Internal: current branch name from the resolved git-dir's HEAD file. Reading
# HEAD here (rather than `git branch --show-current`) keeps every guardrail on
# ONE branch-read path and exposes an rc distinction show-current lacks
# (0=branch, 1=detached, 2=cannot read) for fail-closed callers under `set -e`.
# `git branch --show-current` is worktree-correct under normal invocation; it
# misreads the PRIMARY worktree's HEAD only when GIT_DIR is aimed at the shared
# .git — and reading HEAD via `--absolute-git-dir` follows that same GIT_DIR, so
# this is consistency + rc semantics, NOT a defense against a mis-aimed GIT_DIR
# (HIMMEL-323).
#
# Detached-HEAD handling: prints empty string and returns rc=1 (no current
# branch). Callers MUST distinguish empty branch from a valid branch name -
# `is_on_main` does this via the string compare to main/master.
_branch() {
    local dir="${1:-.}"
    local git_dir
    # `--absolute-git-dir` ensures the HEAD file resolves correctly even when
    # the caller's PWD differs from DIR (the plain `--git-dir` returns a
    # repo-relative path that breaks `[ -f "$git_dir/HEAD" ]` from outside).
    git_dir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 2
    local head_file="${git_dir}/HEAD"
    if [ ! -f "$head_file" ]; then
        return 2
    fi
    local ref
    ref=$(cat "$head_file") || return 2
    case "$ref" in
        "ref: refs/heads/"*)
            printf '%s' "${ref#ref: refs/heads/}"
            ;;
        *)
            # Detached HEAD: HEAD contains a raw SHA, not `ref: refs/heads/X`.
            # Emit empty stdout + return 1 (no current branch) so callers
            # cannot mistake a SHA for a branch name.
            printf ''
            return 1
            ;;
    esac
}

# default_branch [DIR]
# Resolves the repo's default/integration branch name (main or master).
# Order: origin/HEAD symbolic-ref -> whichever of main/master exists locally
# -> init.defaultBranch -> "main". Used as the diff base by the merged/behind
# predicates + the CR diff-base scripts so they work on either default
# (HIMMEL-297: support main AND master). Always prints a non-empty name.
#
# Tie-break (HIMMEL-323): when origin/HEAD is UNSET *and* BOTH local `main` and
# `master` exist, the local-ref order silently prefers `main` — wrong on a
# master-default mirror that picked up a stray local `main`. We still return
# `main` (stable, documented default) but emit a one-line stderr ambiguity note
# so the wrong answer is no longer SILENT. origin/HEAD (set by `clone`, or
# `git remote set-head origin -a`) resolves the ambiguity deterministically and
# short-circuits this branch entirely. The note goes to stderr (fd 2), so it
# never pollutes the stdout callers capture via `$(default_branch)`.
default_branch() {
    local dir="${1:-.}" ref b
    if ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
        b="${ref#origin/}"
        [ -n "$b" ] && { printf '%s' "$b"; return 0; }
    fi
    # `if` form (not `cmd && flag=1`) so a missing ref — `git rev-parse` exits 1
    # — never trips a caller's `set -e`: an `if` condition is exempt, an `&&`
    # list's non-final failure is murkier. Both candidates are probed before the
    # tie-break decision.
    local has_main=0 has_master=0
    if git -C "$dir" rev-parse --verify --quiet refs/heads/main   >/dev/null 2>&1; then has_main=1; fi
    if git -C "$dir" rev-parse --verify --quiet refs/heads/master >/dev/null 2>&1; then has_master=1; fi
    if [ "$has_main" = 1 ] && [ "$has_master" = 1 ]; then
        echo "guardrails: default_branch - both local 'main' and 'master' exist and origin/HEAD is unset; defaulting to 'main' (run 'git remote set-head origin -a' to disambiguate)" >&2
        printf 'main'; return 0
    fi
    if [ "$has_main" = 1 ];   then printf 'main';   return 0; fi
    if [ "$has_master" = 1 ]; then printf 'master'; return 0; fi
    b=$(git -C "$dir" config init.defaultBranch 2>/dev/null)
    [ -n "$b" ] && { printf '%s' "$b"; return 0; }
    printf 'main'
}

# is_on_main [DIR]
# True iff current branch is a protected default branch (main OR master).
# Returns 1 on detached HEAD / feature branch; rc=2 if branch can't be read.
# (Name kept for caller stability; semantics widened to main+master — HIMMEL-297.)
is_on_main() {
    local b rc
    b=$(_branch "${1:-.}"); rc=$?
    if [ "$rc" -eq 2 ]; then return 2; fi
    [ "$b" = "main" ] || [ "$b" = "master" ]
}

# is_main_ref REF
# True iff REF is refs/heads/main OR refs/heads/master. Used by
# check-push-target.sh which reads remote refs from git's pre-push stdin.
# Both protected branches match so a direct push to either is blocked
# (HIMMEL-297). UNLIKE the other predicates, this takes a REF string.
is_main_ref() {
    [ "${1:-}" = "refs/heads/main" ] || [ "${1:-}" = "refs/heads/master" ]
}

# is_dirty [DIR]
# True iff `git status --porcelain` has any output (staged, unstaged, or
# untracked). Conservative - we'd rather warn on a stray file than miss a
# half-committed change.
is_dirty() {
    local dir="${1:-.}"
    local out
    out=$(git -C "$dir" status --porcelain 2>/dev/null) || return 2
    [ -n "$out" ]
}

# is_merged_into_main [DIR]
# NOTE (HIMMEL-297): "main" throughout this docstring denotes the resolved
# default branch (main OR master) per default_branch() — the predicate operates
# against whichever is the repo's default, not literally "main".
# True iff current branch is reachable from main via either:
#   (a) direct merge: `git branch --merged main` lists it
#   (b) squash-merge: every commit on this branch has a patch-equivalent
#       commit on main (cherry-pick equivalence via patch-id)
# False on:
#   - main itself
#   - detached HEAD
#   - branches at main's tip with NO divergence either way
#     (ahead=0 AND behind=0); see HIMMEL-114 short-circuit
# Returns 2 if the resolved default-branch ref (main or master) is missing or
# git plumbing fails (predicate cannot be evaluated - e.g., shallow clones
# missing the merge base).
#
# Known limitations (chosen tradeoffs, NOT bugs):
# - FAST-FORWARD MERGE AMBIGUITY (HIMMEL-114): a branch that was FF-merged
#   to main while main has NOT advanced since produces ahead=0 + behind=0,
#   which is REFERENTIALLY INDISTINGUISHABLE from a fresh branch created at
#   main's SHA. The HIMMEL-114 short-circuit treats both as "not merged"
#   because (a) himmel's workflow uses squash + --no-ff merges via
#   `gh pr merge`, so true FF-merge-no-advance is rare, and (b) blocking
#   the FIRST commit on every fresh branch is the more painful failure mode
#   in practice. The squash arm covers most real merge cases via
#   patch-id equivalence. A reflog-based heuristic could distinguish
#   fresh-from-FF-merged but breaks across clones.
# - FORCE-RESET TO BRANCH SHA: if `main` is force-reset to a feature
#   branch's tip out-of-band (admin-merge bypass + manual update-ref),
#   ahead=0 + behind=0 also holds. Same short-circuit returns "not
#   merged". Acceptance argument: force-resetting main requires bypassing
#   no-push-to-main + branch protection + admin-merge guards already, so
#   reaching this state means multiple guards have already been bypassed.
is_merged_into_main() {
    local dir="${1:-.}"
    local b rc
    b=$(_branch "$dir"); rc=$?
    if [ "$rc" -eq 2 ]; then return 2; fi
    # rc=1 (detached HEAD) or empty/default branch => not a merged feature branch.
    if [ -z "$b" ] || [ "$b" = "main" ] || [ "$b" = "master" ]; then
        return 1
    fi
    # Resolve the default branch (main or master) to use as the merge base.
    local db
    db=$(default_branch "$dir")
    # Bail with rc=2 when we cannot resolve the default branch - the rest of
    # this function would silently produce a false answer otherwise.
    if ! git -C "$dir" rev-parse --verify --quiet "refs/heads/$db" >/dev/null 2>&1; then
        return 2
    fi

    # HIMMEL-114: short-circuit "fresh branch at main's SHA" BEFORE the
    # direct-merge listing arm. The differentiator between a fresh branch
    # and a direct-merge is BEHIND-count, not ahead-count:
    #   ahead=0 + behind=0  -> fresh branch (HEAD == main, just diverged)
    #   ahead=0 + behind>0  -> direct-merge (main moved on past the merge)
    #   ahead>0             -> active branch (check direct-merge + squash)
    # Pre-HIMMEL-114 the direct-merge arm fired on fresh branches at main's
    # SHA because `git branch --merged main` lists every ref at main's SHA,
    # which blocked the FIRST commit on docs/feat branches.
    local ahead behind
    ahead=$(git -C "$dir" rev-list "$db..HEAD" --count 2>/dev/null) || return 2
    behind=$(git -C "$dir" rev-list "HEAD..$db" --count 2>/dev/null) || return 2
    if [ "$ahead" = "0" ] && [ "$behind" = "0" ]; then
        # Branch is at main's SHA with no divergence in either direction.
        return 1
    fi

    # Direct-merge arm. Capture the full branch list first, THEN grep with
    # -Fx (literal whole-line match) - using -E would treat regex metachars
    # in branch names (e.g. `feat/v1.2.0`) as regex syntax and produce false
    # positives. Capture-first also avoids SIGPIPE-on-`head` races where the
    # earlier pipeline element gets killed mid-write and the pipeline rc is
    # misread as success.
    local merged_raw merged
    merged_raw=$(git -C "$dir" branch --merged "$db" 2>/dev/null) || return 2
    merged=$(printf '%s\n' "$merged_raw" | sed 's/^[* ]*//' | grep -Fx -- "$b" || true)
    if [ -n "$merged" ]; then
        return 0
    fi

    # Squash-merge arm: every commit cherry-pick-equivalent on main.
    # Capture first to avoid SIGPIPE races (see merged_raw note above).
    local unique_raw unique
    unique_raw=$(git -C "$dir" log --cherry-pick --right-only --no-merges "$db...HEAD" --pretty=format:'%h' 2>/dev/null) || return 2
    unique=$(printf '%s' "$unique_raw" | head -1)
    if [ -z "$unique" ]; then
        return 0
    fi
    return 1
}

# is_behind_origin_main [DIR]
# True iff origin/<default> has commits not in HEAD, where <default> is the
# resolved default branch (main OR master) per default_branch() — HIMMEL-297.
# Caller is responsible for running `git fetch` first if freshness matters -
# this predicate reads the current refs as-is.
# Returns 1 (not behind) if the origin/<default> ref doesn't exist locally.
is_behind_origin_main() {
    local dir="${1:-.}"
    local db
    db=$(default_branch "$dir")
    if ! git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$db" >/dev/null 2>&1; then
        return 1
    fi
    local behind
    behind=$(git -C "$dir" rev-list "HEAD..origin/$db" --count 2>/dev/null) || return 2
    [ "${behind:-0}" -gt 0 ]
}

# is_himmel_dev_repo [DIR]
# True only in a himmel-contributor checkout, signalled by an untracked,
# gitignored `.himmel-dev` marker dropped by contributor setup.
# Keeps the doc-guard gate OFF for adopters/users who run himmel as a harness.
# Returns rc: 0 present | 1 absent | 2 cannot resolve repo root (fail-closed).
is_himmel_dev_repo() {
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null) || return 2
    [ -f "$top/.himmel-dev" ]
}

# warn_doc_guard_off DIR — non-fatal nudge (stderr) when DIR is a himmel-source
# checkout (catalog + pre-commit config present) but the opt-in .himmel-dev
# marker is absent, so the doc-guard gate is silently off. Always rc 0.
warn_doc_guard_off() {
    local d="${1:-.}"
    if [ -f "$d/docs/commands-catalog.md" ] && [ -f "$d/.pre-commit-config.yaml" ] && [ ! -f "$d/.himmel-dev" ]; then
        echo "⚠ doc-guard is OFF: this looks like a himmel-source checkout but .himmel-dev is missing. Run 'touch .himmel-dev' (see docs/contributing.md) to enable the catalog-sync gate." >&2
    fi
    return 0
}
