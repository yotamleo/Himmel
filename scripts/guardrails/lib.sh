#!/usr/bin/env bash
# scripts/guardrails/lib.sh - shared git-state predicates.
#
# Sourced by (non-exhaustive - grep for `guardrails/lib.sh` for the full
# consumer set):
#   - scripts/hooks/check-worktree-isolation.sh
#   - scripts/hooks/check-pr-lane-isolation.sh
#   - scripts/hooks/check-merged-branch.sh
#   - scripts/hooks/check-push-target.sh
#   - scripts/hooks/block-edit-on-main.sh
#   - scripts/hooks/block-read-secrets.sh
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
#   - branches with no commits of their own whose HEAD sits on the default
#     branch's first-parent chain (ahead=0), regardless of behind-count
#     (HIMMEL-1947, superseding the narrower HIMMEL-114 form)
# Returns 2 if the resolved default-branch ref (main or master) is missing or
# git plumbing fails (predicate cannot be evaluated - e.g., shallow clones
# missing the merge base).
#
# Known limitations (chosen tradeoffs, NOT bugs):
# - FAST-FORWARD MERGE AMBIGUITY (HIMMEL-114, widened by HIMMEL-1947): a
#   branch that was FF-merged to main produces ahead=0 with HEAD still on
#   main's first-parent chain (FF-merge creates no new commit, so the tip
#   stays on that chain permanently) - REGARDLESS of whether main has since
#   advanced. HIMMEL-114 only pinned the no-advance case; HIMMEL-1947 replaced
#   the behind-count check with the first-parent-chain check above, which
#   extends the same ambiguity to behind>0 too, because an FF-merged tip and
#   a fresh branch off main are REFERENTIALLY INDISTINGUISHABLE in the DAG
#   either way - no graph-only predicate can tell them apart. The
#   short-circuit treats both as "not merged" because (a) himmel's workflow
#   uses squash + --no-ff merges via `gh pr merge`, so true FF-merge is rare,
#   and (b) narrowing this back to catch FF-merges would reintroduce
#   HIMMEL-1947 itself: blocking the FIRST commit on every fresh branch once
#   main has advanced, the more painful failure mode by far. The squash arm
#   covers most real merge cases via patch-id equivalence. A reflog-based
#   heuristic could distinguish fresh-from-FF-merged but breaks across clones.
# - FORCE-RESET TO BRANCH SHA: if `main` is force-reset to a feature
#   branch's tip out-of-band (admin-merge bypass + manual update-ref), HEAD
#   is trivially on the (now-identical) first-parent chain and ahead=0 also
#   holds. Same short-circuit returns "not merged". Acceptance argument:
#   force-resetting main requires bypassing no-push-to-main + branch
#   protection + admin-merge guards already, so reaching this state means
#   multiple guards have already been bypassed.
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

    # Short-circuit "branch has committed nothing of its own" BEFORE the
    # direct-merge listing arm, which otherwise fires on any ref reachable
    # from main (`git branch --merged main` lists them all) and blocks the
    # FIRST commit on a fresh branch.
    #
    # ahead>0 is always an active branch -> fall through to the direct-merge
    # and squash arms. ahead=0 means no commits of the branch's own, and two
    # graph shapes land there. BEHIND-count does not separate them
    # (HIMMEL-114 assumed it did, so it only caught behind=0 and a fresh
    # branch still got blocked the moment main advanced - HIMMEL-1947); the
    # FIRST-PARENT chain does:
    #   HEAD on $db's first-parent line  -> branch point, nothing committed
    #       yet. Fresh branch, whether or not main has since advanced.
    #   HEAD off that line               -> the second parent of a --no-ff
    #       merge, i.e. a genuinely direct-merged feature branch. Blocks.
    # FF-merged-with-no-advance stays indistinguishable from a fresh branch
    # (identical refs) and keeps returning not-merged - the tradeoff
    # HIMMEL-114 chose and its test still pins.
    local ahead
    ahead=$(git -C "$dir" rev-list "$db..HEAD" --count 2>/dev/null) || return 2
    if [ "$ahead" = "0" ]; then
        local head_sha first_parents
        head_sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 2
        first_parents=$(git -C "$dir" rev-list --first-parent "$db" 2>/dev/null) || return 2
        # Pure-bash whole-line membership test — no pipeline and no here-string.
        # A `grep -q` pipeline takes SIGPIPE on first match, which `set -o
        # pipefail` reports as a FAILED pipeline on a SUCCESSFUL match
        # (HIMMEL-1430); a here-string of >= 64 KiB (main passed 1600
        # first-parent commits) wedges Git Bash forever — bash writes it into
        # a pipe before the reader runs and MSYS over-reports the pipe size
        # (HIMMEL-2027). Newline-framing both sides keeps the match exact.
        case "$first_parents" in
            "$head_sha"|"$head_sha"$'\n'*|*$'\n'"$head_sha"|*$'\n'"$head_sha"$'\n'*)
                return 1
                ;;
        esac
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

# primary_checkout_root [DIR] — echo the PRIMARY checkout root for DIR
# (default '.'; no trailing slash). Returns 1 when DIR is not a non-bare git
# repo.
#
# A LINKED worktree's per-worktree git dir differs from the shared common
# dir; a main checkout (normal OR --separate-git-dir) has them equal. That
# distinction picks the right root in every case — no single path expression
# does (HIMMEL-1131 / CR #478):
#  - main checkout  -> --show-toplevel is the checkout root (correct for a
#    normal repo AND --separate-git-dir, where the git dir lives elsewhere so
#    dirname(common_dir) would point outside the worktree).
#  - linked worktree -> the PRIMARY checkout is the parent of the shared
#    common git dir.
#
# Extracted from _himmel_dev_marker_path (HIMMEL-2526) so main_checkout_verdict
# and any other primary-checkout-anchored guard share ONE implementation
# instead of a second copy of this comparison drifting in.
primary_checkout_root() {
    local d="${1:-.}" bare git_dir common_dir top
    bare=$(git -C "$d" rev-parse --is-bare-repository 2>/dev/null) || return 1
    [ "$bare" = "false" ] || return 1
    git_dir=$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null) || return 1
    git_dir=$(cd "$git_dir" 2>/dev/null && pwd) || return 1
    common_dir=$(git -C "$d" rev-parse --git-common-dir 2>/dev/null) || return 1
    common_dir=$(cd "$d" 2>/dev/null && cd "$common_dir" 2>/dev/null && pwd) || return 1
    if [ "$git_dir" = "$common_dir" ]; then
        top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || return 1
    else
        top=$(dirname "$common_dir")
    fi
    printf '%s\n' "$top"
}

# _himmel_dev_marker_path [DIR] — echo the PRIMARY checkout's .himmel-dev path.
# The marker is gitignored and lives only in the primary checkout, so this
# resolves via primary_checkout_root (correct for normal repos, linked
# worktrees, AND repos using --separate-git-dir). Prints nothing and returns 1
# when DIR is not a non-bare git repo.
_himmel_dev_marker_path() {
    local d="${1:-.}" top
    top=$(primary_checkout_root "$d") || return 1
    printf '%s/.himmel-dev' "$top"
}

# is_himmel_dev_repo [DIR]
# True only in a himmel-contributor checkout, signalled by an untracked,
# gitignored `.himmel-dev` marker dropped by contributor setup.
# Keeps the doc-guard gate OFF for adopters/users who run himmel as a harness.
# Returns rc: 0 present | 1 absent | 2 cannot resolve repo root (fail-closed).
is_himmel_dev_repo() {
    # Resolve from `git worktree list --porcelain` rather than --show-toplevel
    # (the CURRENT worktree root). The gitignored .himmel-dev marker lives only
    # in the primary checkout, so a --show-toplevel lookup returns absent from
    # every linked worktree — and every dependent gate then silently no-ops
    # inside a worktree, which is exactly where himmel feature work happens
    # (HIMMEL-1131). The worktree list also identifies the primary checkout when
    # its git dir lives elsewhere via --separate-git-dir.
    # Honor the optional DIR arg (defaults to PWD) like every other predicate in
    # this lib, resolving the primary marker relative to it.
    local d="${1:-.}" m
    m=$(_himmel_dev_marker_path "$d") || return 2
    [ -f "$m" ]
}

# warn_doc_guard_off DIR — non-fatal nudge (stderr) when DIR is a himmel-source
# checkout (catalog + pre-commit config present) but the opt-in .himmel-dev
# marker is absent, so the doc-guard gate is silently off. Always rc 0.
warn_doc_guard_off() {
    local d="${1:-.}" m
    m=$(_himmel_dev_marker_path "$d") || m=""
    # Require a resolved marker path ([ -n "$m" ]): a non-git dir has no primary
    # checkout to enable the gate in, so don't nudge there. The hint points at the
    # RESOLVED primary marker "$m" (not a bare ".himmel-dev") so that from a linked
    # worktree the operator touches the primary's marker, not a stray file in the
    # worktree root that would not enable the gate (HIMMEL-1131).
    if [ -n "$m" ] && [ -f "$d/docs/commands-catalog.md" ] && [ -f "$d/.pre-commit-config.yaml" ] && [ ! -f "$m" ]; then
        echo "⚠ doc-guard is OFF: this looks like a himmel-source checkout but .himmel-dev is missing. Run 'touch \"$m\"' (see docs/contributing.md) to enable the catalog-sync gate." >&2
    fi
    return 0
}

# _tolower_ascii STRING -> sets _TOLOWER_OUT to STRING with A-Z folded to a-z.
#
# HIMMEL-1741: is_secret_basename used to fold case with `printf | tr`, a fork
# PAIR per call. block-read-secrets.sh calls the predicate once per tokenised
# argument of every Bash/PowerShell command, so on Windows with Defender
# real-time scanning (~667 ms a fork pair, ~10x a normal Git-Bash spawn) that
# fold was the dominant cost of a hook that fires on EVERY Read/Grep/Bash tool
# call. This is the builtin-only replacement: zero processes.
#
# Result is returned in the global _TOLOWER_OUT rather than on stdout, because
# `x=$(...)` would fork a subshell and reintroduce exactly the cost being
# removed.
#
# bash-3.2-safe by construction: no `${var,,}` (bash 4), no associative arrays,
# no `+=`.
#
# LINEAR BY CONSTRUCTION, and that is a correctness requirement, not a nicety
# (codex-adv, HIMMEL-1741 CR r1). The input here is NOT bounded to a short
# filesystem basename: block-read-secrets.sh calls the predicate once per
# TOKEN of every Bash/PowerShell command, and a token can be a base64
# `-EncodedCommand` payload, a data: URI or a long JSON blob. The first
# implementation peeled one character at a time (`${s%"${s#?}"}` + `out="$out$c"`),
# which copies the shrinking suffix AND the growing output every iteration —
# O(n^2). Measured on this box, min-of-3, against the `printf | tr` fork pair
# it replaced:
#     len      char-loop     26-subst     printf|tr
#      64          26 ms        23 ms        80 ms
#    2000         398 ms        25 ms        80 ms
#    8000      13,435 ms        30 ms        75 ms
# i.e. one 8 KB uppercase-bearing token cost THIRTEEN SECONDS — a far worse
# stall than the fork this ticket set out to remove. The 26 `${b//A/a}`
# substitutions below are each a single linear pass, so the whole fold is
# bounded at 26n and stays flat (~timer floor) at every size, beating `tr` even
# on short input. Do not "simplify" this back into a character loop.
#
# ASCII-only, which MATCHES the `tr '[:upper:]' '[:lower:]'` it replaces: that
# tr is byte-oriented and folds only A-Z here, and every case arm below is
# ASCII, so a non-ASCII byte could never change a verdict either way. Verified
# byte-for-byte against tr over an alphabet/digit/punctuation/UTF-8 corpus.
# The uppercase pre-check makes the common already-lowercase path a single
# `case` with no substitution at all.
_tolower_ascii() {
    _TOLOWER_OUT="$1"
    case "$_TOLOWER_OUT" in
        *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) ;;
        *) return 0 ;;
    esac
    local b="$_TOLOWER_OUT"
    b="${b//A/a}"; b="${b//B/b}"; b="${b//C/c}"; b="${b//D/d}"
    b="${b//E/e}"; b="${b//F/f}"; b="${b//G/g}"; b="${b//H/h}"
    b="${b//I/i}"; b="${b//J/j}"; b="${b//K/k}"; b="${b//L/l}"
    b="${b//M/m}"; b="${b//N/n}"; b="${b//O/o}"; b="${b//P/p}"
    b="${b//Q/q}"; b="${b//R/r}"; b="${b//S/s}"; b="${b//T/t}"
    b="${b//U/u}"; b="${b//V/v}"; b="${b//W/w}"; b="${b//X/x}"
    b="${b//Y/y}"; b="${b//Z/z}"
    _TOLOWER_OUT="$b"
}

# guard_cmdpos_grammar — HIMMEL-1180. Sets EXEPFX / ASSIGN / CMDPOS in the
# CALLER's scope (plain assignment, not `local` — this is meant to be sourced
# inline into a hook script, the same way the rest of this file's predicates
# are). Byte-identical to the grammar block-destructive-commands.sh built up
# over several CR rounds (HIMMEL-851 r1/r2/r4/r5/r6/r7); factored out here so
# block-graphify-egress.sh can anchor its OWN atom ("graphify") to command
# position with the same wrapper/assignment tolerance instead of re-deriving
# — or worse, drifting from — a second copy.
#
# CMDPOS matches: start of command or right after a separator (|;&(`),
# optional whitespace, then zero or more of {a VAR=val assignment | a BOUNDED
# launcher wrapper — sudo/env/cmd [/switches] /c/powershell|pwsh [-flags]
# -c/-command, each with its own flag-and-assignment tolerance} each followed
# by required whitespace, then a final EXEPFX (optional quote + Windows drive
# + path segments) immediately before the atom the caller appends.
#
# Deliberately NOT a general shell parser. The documented residual is
# QUOTED-PAYLOAD wrappers (`bash -c "<atom> ..."`, `sh -c`, xargs/nohup
# chains) — out of scope per HIMMEL-851's own no-general-parser rule, and
# accepted for the graphify guard too (HIMMEL-1180): this hook is the fast
# gate for accidental agent egress, not an adversarial boundary — the
# post-`bash -c` unwrap graphify-fence.sh's own classify_clause does is a
# SEPARATE, deeper analysis that already handles that case for anything this
# gate's fast check lets through.
#
# Callers: append their own atom alternation directly after `"$CMDPOS"`, e.g.
#   grep -Eq "${CMDPOS}graphify(\.exe)?([^[:alnum:]_.-]|\$)"
guard_cmdpos_grammar() {
    EXEPFX='["'\'']?([a-z]:)?([^[:space:]|;&`"'\'']*[/\\])?'
    ASSIGN='[[:alnum:]_]+=('\''[^'\'']*'\''|"[^"]*"|[^[:space:]|;&]*)'
    # shellcheck disable=SC2034 # consumed by the CALLER after sourcing, not in this file
    CMDPOS='(^|[|;&(`])[[:space:]]*(('"$ASSIGN"'|'"$EXEPFX"'(sudo([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*|env([[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?|'"$ASSIGN"'))*|cmd(\.exe)?([[:space:]]+/[[:alnum:]]+(:[[:alnum:]]+)?)*[[:space:]]+/c|(powershell|pwsh)(\.exe)?([[:space:]]+-[^[:space:]]+)*[[:space:]]+-c[[:alnum:]]*))[[:space:]]+)*'"$EXEPFX"
}

# is_secret_basename PATH_OR_TOKEN
# True iff PATH_OR_TOKEN's basename matches a secret-file pattern (.env,
# .envrc, id_rsa, id_ed25519, credentials.json, secrets.y[a]ml, *.pem, *.key,
# *.p12, *.pfx). Basename match only (path-prefix agnostic); globs, no regex.
# Non-secret env TEMPLATES (.env.example, .env.sample, .env.template,
# .env.dist — committed, scrubbed placeholders) are carved out BEFORE the
# .env.* arm (first-match-wins) so reading them is allowed.
#
# BOTH separators are treated as basename boundaries: `/` and `\` -
# backslash is a path separator on Windows, and tool inputs (Read/Grep
# file_path, PowerShell commands) carry native backslash paths there, so
# stripping only `/` would let `C:\repo\.ENV` through as one giant
# non-matching "basename" (HIMMEL-879). On POSIX a literal backslash in a
# filename over-matches toward blocking - fail-closed, acceptable.
#
# The basename is lowercased BEFORE matching (_tolower_ascii, a builtin-only
# fold - HIMMEL-1741; bash-3.2-safe, no ${var,,}): git ls-files/check-ignore fold case on Windows/macOS
# (core.ignorecase=true), so a mixed-case name (.ENV, ID_RSA) would
# otherwise dodge these lowercase case-arms while the filesystem still
# treats it as the same file (HIMMEL-879). Case arms below stay lowercase.
#
# Trailing SPACES and DOTS are then stripped (same normalization-divergence
# class): Win32 CreateFile / Node fs strip trailing spaces and dots from
# path components, so ".env " / ".env." open the SAME file as .env - the
# predicate mirrors that OS normalization or the literal-string match lets
# them through. This also normalizes ".env.example " onto the template
# carve-out (allowed), consistent with what the OS actually opens.
#
# A single leading/trailing quote char (' or ") is stripped first - a caller
# that tokenizes raw shell command text (block-read-secrets.sh) may hand in
# a token still carrying a quote glued on by its quote-naive splitter (e.g.
# `'.env'` from `cat '.env'`); a clean path (block-edit-on-main.sh, jq-
# extracted) passes through the strip unchanged.
#
# Shared by block-read-secrets.sh and block-edit-on-main.sh - this predicate
# is the single source of truth for the secret-basename pattern list; do NOT
# fork a second copy. Deterministic - always returns 0 or 1, never 2 (rc=2 is
# reserved for "predicate cannot be evaluated", which never applies here).
is_secret_basename() {
    local p="${1#\"}"; p="${p#\'}"
    p="${p%\"}"; p="${p%\'}"
    local base="${p##*/}"
    base="${base##*\\}"
    _tolower_ascii "$base"
    base="$_TOLOWER_OUT"
    # Strip ALL trailing spaces/dots (Windows path-component normalization,
    # see header). bash-3.2-safe loop; terminates on empty string.
    while :; do
        case "$base" in
            *" "|*.) base="${base%?}" ;;
            *)       break ;;
        esac
    done
    case "$base" in
        .env.example|.env.sample|.env.template|.env.dist) return 1 ;;
        .env|.env.*|.envrc|id_rsa|id_ed25519|credentials.json|secrets.yaml|secrets.yml)
            return 0 ;;
        *.pem|*.key|*.p12|*.pfx)
            return 0 ;;
    esac
    return 1
}

# guard_canon_path PATH — canonicalise PATH without requiring GNU `realpath -m`
# or python (neither is a dependency of this file today, and this predicate
# must not add one).
#
# WHY (HIMMEL-2526): a destination-based write fence has to compare the
# TARGET path against a protected repo root as a literal prefix. Without
# canonicalisation, `<worktree>/../scripts/x.sh` — or any other `.`/`..`
# segment — escapes that prefix check even though it resolves to a path
# inside the protected checkout.
#
# Algorithm: find the longest EXISTING ancestor of PATH (a plain `[ -e ]` walk
# — the kernel already resolves any `..`/symlink IN that literal ancestor
# string the same way `cd` would, so the walk needs no pre-normalization of
# its own), resolve that ancestor with `cd "$prefix" && pwd -P` (follows
# symlinks, matching realpath -m's existing-portion behaviour), then
# textually normalise the remaining NON-existent tail component-by-component
# (`.` dropped, `..` pops the previous component) since a path that doesn't
# exist yet cannot be resolved via `cd`.
#
# A relative PATH is resolved against $PWD — callers that already joined a
# tool-reported cwd onto a relative target should pass the joined form in.
#
# Echoes the canonical absolute path (no trailing newline swallowed by a
# caller's `$(...)`). Returns 1 and echoes nothing when PATH is empty, the
# existing prefix cannot be entered (e.g. permission denied, or the walk
# never reaches a directory that exists), or (HIMMEL-2597) the final-component
# symlink chain still has not settled after the depth cap below — exhausting
# the cap is NOT success, and a caller that printed a still-symlinked path as
# though fully resolved would misclassify it.
#
# guard_canon_path_nofollow PATH — same algorithm, but does not chase a
# final-component symlink chain at all: it canonicalises every ANCESTOR
# directory and returns the entry's OWN canonical path, preserving the
# entry's name even when the entry itself is a symlink. Needed by callers
# whose operation acts on the directory ENTRY rather than what it points to
# (e.g. `rm` unlinking a symlink) — dereferencing there would misjudge which
# checkout is actually being written to. Both are thin wrappers over
# `_guard_canon_path_impl`; see its body for the shared algorithm.
# _guard_is_drive_root PATH — true iff PATH is a BARE Windows drive root
# (`C:`, `C:/` or `C:\`) with no further segment. guard_canon_path's ancestor
# walk needs this as an extra stop condition: `dirname` has no concept of a
# drive letter and reduces a bare `C:` straight to `.` (the POSIX cwd), which
# would silently reintroduce the very $PWD-prefix bug codex-7 reports one
# level down. Not reached for a POSIX-absolute path (never matches).
_guard_is_drive_root() {
    case "$1" in
        [A-Za-z]:|[A-Za-z]:/|[A-Za-z]:\\) return 0 ;;
        *) return 1 ;;
    esac
}

# _guard_collapse_dotdot BASE TAIL — textually append TAIL (a `/`-separated
# component string, no leading slash) onto the already-canonical absolute
# path BASE, collapsing `.`/`..` components along the way. No filesystem
# access — pure string manipulation. Shared by guard_canon_path's own
# non-existent-tail join AND its post-symlink resolution step below (both
# need the identical `..`-popping semantics against a moving base).
_guard_collapse_dotdot() {
    local base="$1" tail="$2" comp
    while [ -n "$tail" ]; do
        comp="${tail%%/*}"
        case "$tail" in
            */*) tail="${tail#*/}" ;;
            *)   tail="" ;;
        esac
        case "$comp" in
            ""|".") : ;;
            "..")
                case "$base" in
                    /) : ;;
                    *) base="${base%/*}"; [ -n "$base" ] || base="/" ;;
                esac
                ;;
            *)
                case "$base" in
                    /) base="/$comp" ;;
                    *) base="$base/$comp" ;;
                esac
                ;;
        esac
    done
    printf '%s' "$base"
}

# _guard_resolve_existing_prefix EXISTING [TAIL] — find the longest EXISTING
# ancestor starting from EXISTING (a `[ -e ]`-shaped walk that pops a
# basename into TAIL and climbs via `dirname` while NOT A DIRECTORY — see
# codex-1 below), physically resolve that ancestor with `cd`+`pwd -P`, then
# textually re-append TAIL (collapsing `.`/`..`) via `_guard_collapse_dotdot`.
# This IS `_guard_canon_path_impl`'s own top-level resolution algorithm,
# factored out so a second call site (HIMMEL-2597's per-hop symlink-chain
# resolution, below) can reuse the exact same "longest existing ancestor"
# notion instead of inventing a second, narrower one (which is what
# regressed: trying only the immediate parent directory, so an ancestor
# further up that was itself a symlink never got re-resolved whenever that
# immediate parent didn't exist yet).
#
# codex-1 (HIMMEL-2526): walk while NOT A DIRECTORY (was: not existent) — an
# EXISTING regular file must still have its basename popped into TAIL so the
# walk `cd`s into its containing directory, not the file itself (`cd` onto a
# file always fails, which used to fail the whole function for any
# already-existing target).
#
# Echoes the canonicalised path and returns 0. Returns 1 and echoes nothing
# only when EXISTING is empty or the resolved ancestor cannot be entered
# (permission denied, or an I/O error) — callers that want a fail-OPEN
# fallback (e.g. keep the last textual value on a dangling chain) must check
# the return themselves rather than treat rc=1 here as fatal.
_guard_resolve_existing_prefix() {
    local existing="${1:-}" tail="${2:-}" comp prev=""
    [ -n "$existing" ] || return 1
    while [ ! -d "$existing" ] && [ "$existing" != "$prev" ] && [ "$existing" != "/" ] \
          && ! _guard_is_drive_root "$existing"; do
        comp=$(basename "$existing")
        tail="$comp/$tail"
        prev="$existing"
        existing=$(dirname "$existing") || existing="$prev"
    done

    local resolved
    if _guard_is_drive_root "$existing" && [ ! -d "$existing" ]; then
        # A bare drive root that isn't itself a real directory on THIS
        # platform (i.e. every non-Windows station): take it literally
        # instead of `cd`ing into it (which would fail here, and which a real
        # Git Bash resolves via its own drive-letter translation this
        # function does not attempt to model).
        resolved="$existing"
    else
        resolved=$(cd "$existing" 2>/dev/null && pwd -P) || return 1
    fi
    [ -n "$resolved" ] || return 1

    _guard_collapse_dotdot "$resolved" "$tail"
}

_guard_canon_path_impl() {
    local path="${1:-}" follow="${2:-1}"
    [ -n "$path" ] || return 1
    case "$path" in
        # codex-7 (HIMMEL-2526): a Windows drive-absolute path (`C:/...` or
        # `C:\...`) is ALREADY absolute — matching
        # block-write-into-main-checkout.sh's own _bwimc_resolve_abs. Without
        # this, such a path falls to the `*` branch below and gets prefixed
        # with $PWD, resolving a DIFFERENT location on Git Bash.
        /*|[A-Za-z]:/*|[A-Za-z]:\\*) : ;;
        *) path="$PWD/$path" ;;
    esac

    local existing="$path" tail="" comp

    # HIMMEL-2597 (nofollow-mode directory-symlink fix): the ancestor walk
    # inside `_guard_resolve_existing_prefix` stops as soon as
    # `[ -d "$existing" ]` is true — and `-d` FOLLOWS a symlink, so a final
    # component that is a symlink TO A DIRECTORY (unlike one to a regular
    # file, which fails `-d` and falls into the walk on its own) would never
    # get its basename popped into `tail`, and the subsequent `cd`+`pwd -P`
    # would dereference it. That is correct for `guard_canon_path` (follow=1:
    # a directory symlink SHOULD dereference, same as a file symlink), but
    # violates guard_canon_path_nofollow's contract, which must return the
    # ENTRY's own canonical path — an entry whose operation is
    # `rm <primary>/dirlink -> <worktree>/dir` unlinks the ENTRY in the
    # primary, and dereferencing it here would resolve OUT to the worktree
    # and let the write fence ALLOW the delete. Pop the final component's
    # basename by hand in nofollow mode BEFORE calling the shared walk —
    # exactly the way that walk itself would for a non-directory target — so
    # every ANCESTOR still gets physically resolved normally. A
    # trailing-slash input (`dirlink/`) is deliberately NOT touched here:
    # `-L` is false on it (the trailing slash already forces directory
    # resolution, i.e. FOLLOW), so it falls through to the ordinary walk
    # unchanged.
    if [ "$follow" = "0" ] && [ -L "$existing" ]; then
        comp=$(basename "$existing")
        tail="$comp/"
        existing=$(dirname "$existing") || existing="$path"
    fi

    local resolved
    resolved=$(_guard_resolve_existing_prefix "$existing" "$tail") || return 1

    if [ "$follow" = "1" ]; then
        # codex-3 (HIMMEL-2526): the ancestor walk above only follows a
        # symlink that sits in the EXISTING PREFIX and resolves to a
        # DIRECTORY (`cd` + `pwd -P` already dereferences those) — a symlink
        # whose target is a regular file (or nothing) never gets `cd`'d
        # into, so it fell out of the walk as a plain textual TAIL component
        # and was joined onto `resolved` unresolved. That let a worktree
        # symlink pointing at a file inside the PRIMARY checkout
        # (`<worktree>/link.txt -> <primary>/existing.txt`) read back as a
        # worktree-local path, bypassing the fence. Follow the FINAL
        # resolved path as a symlink chain here, depth-capped so a loop
        # (A -> B -> A) cannot hang the hook. A relative target resolves
        # against the link's OWN containing directory, never $PWD (a
        # caller's cwd has no bearing on where a symlink itself lives). A
        # dangling target (readlink succeeds, nothing exists there) or a
        # readlink failure (not a symlink, or a genuine I/O error) stops the
        # chain and keeps the last resolved value rather than failing this
        # function — returning 1 here would make every caller in this file
        # DENY with "cannot-canonicalise", a false positive on an ordinary
        # dangling symlink.
        #
        # HIMMEL-2597: each hop also re-canonicalises its own referent via
        # `_guard_resolve_existing_prefix` (the SAME longest-existing-ancestor
        # walk the top-level resolution above runs) before the next
        # iteration, so a referent reached through the chain that itself sits
        # inside a symlinked ANCESTOR directory (`<wt>/link ->
        # /symlinked-dir/file`, where `symlinked-dir` is itself a symlink)
        # gets that ancestor physically resolved too — closing the gap this
        # loop used to leave (a link through a symlinked directory could hide
        # a primary-checkout write inside the hop budget).
        #
        # HIMMEL-2597 (fix: try the LONGEST existing ancestor, not just the
        # immediate parent): the first cut of this only tried `cd`ing into
        # the referent's IMMEDIATE parent directory, and kept the textual
        # value verbatim whenever that single `cd` failed. That is too coarse
        # — when the immediate parent does not exist YET (a symlink whose
        # target has a non-existent tail, e.g. `<alias-to-primary>/
        # missing-dir/f.txt`), the whole path stayed textual, INCLUDING any
        # symlinked ancestor further up (`alias-to-primary` itself), which
        # then never got dereferenced. Reusing the shared walk fixes this by
        # construction: it climbs past however many non-existent trailing
        # components there are and resolves whichever ancestor actually
        # exists, exactly as the top-level resolution already does for the
        # ORIGINAL path. A genuinely dangling referent (no ancestor above the
        # walk's root stop conditions exists — practically never, since `/`
        # itself always exists) falls back to keeping the textual value, same
        # as before.
        #
        # Exhausting the depth cap while `$resolved` is STILL a symlink is
        # not success — it means an unresolved chain got printed as though
        # fully resolved, which a caller classified as "safe" without
        # actually knowing where it points. Fail closed in that case only
        # (never on the dangling/readlink-failure `break`s above, which
        # leave the depth below the cap).
        #
        # HIMMEL-2597 (cap raised 8 -> 40): 8 was tight enough to fail-CLOSE a
        # legitimate long chain that never leaves the worktree — a false
        # positive, not a safety win. 40 is parity with the kernel's ELOOP
        # limit, which is effectively what `realpath -m` honours in the
        # Write-tool fence (block-edit-on-main.sh) — the two fences now agree
        # on where "pathological" starts instead of disagreeing by a factor
        # of five.
        local _guard_symlink_max_hops=40
        local _guard_symlink_depth=0 _guard_link_target _guard_link_dir _guard_link_realdir
        while [ "$_guard_symlink_depth" -lt "$_guard_symlink_max_hops" ] && [ -L "$resolved" ]; do
            _guard_link_target=$(readlink "$resolved" 2>/dev/null) || break
            [ -n "$_guard_link_target" ] || break
            case "$_guard_link_target" in
                /*|[A-Za-z]:/*|[A-Za-z]:\\*)
                    resolved="$_guard_link_target"
                    ;;
                *)
                    _guard_link_dir="${resolved%/*}"
                    [ -n "$_guard_link_dir" ] || _guard_link_dir="/"
                    resolved=$(_guard_collapse_dotdot "$_guard_link_dir" "$_guard_link_target")
                    ;;
            esac
            _guard_link_realdir=$(_guard_resolve_existing_prefix "$resolved")
            if [ -n "$_guard_link_realdir" ]; then
                resolved="$_guard_link_realdir"
            fi
            _guard_symlink_depth=$((_guard_symlink_depth+1))
        done

        if [ "$_guard_symlink_depth" -ge "$_guard_symlink_max_hops" ] && [ -L "$resolved" ]; then
            return 1
        fi
    fi

    printf '%s\n' "$resolved"
}

# guard_canon_path / guard_canon_path_nofollow — see the docstring above
# `_guard_canon_path_impl` for the shared algorithm and the follow/nofollow
# contract. Thin wrappers only; do not duplicate the algorithm here.
guard_canon_path() {
    _guard_canon_path_impl "${1:-}" 1
}

guard_canon_path_nofollow() {
    _guard_canon_path_impl "${1:-}" 0
}

# repo_root_for_path PATH — walk PATH's ancestors for a `.git` entry (a
# directory in a normal checkout, a FILE in a linked worktree or submodule)
# and echo the repo root it finds (no trailing slash). Echoes nothing and
# returns 1 when PATH is inside no repo.
#
# Lifted from block-edit-on-main.sh's original inline walk (HIMMEL-2526) so a
# Bash-mediated write can be fenced by the SAME resolution the Edit/Write hook
# uses, rather than a second copy that could drift.
#
# `.git`-EXISTENCE only ([ -e ], no git invocation): a not-yet-created Write
# target whose parent directories don't exist yet still resolves, because the
# walk just keeps climbing past the missing components to the nearest real
# ancestor that DOES carry a `.git`. The loop terminates when `dirname` stops
# changing its output (both `/...` and bare-drive `C:/...` forms eventually
# stabilise there); a `dirname` failure falls back to the previous value
# instead of aborting the walk under a caller's `set -e`.
#
# Starts the walk AT PATH ITSELF when PATH is an existing DIRECTORY, and at
# dirname(PATH) otherwise. This part is NEW relative to the original inline
# walk, and load-bearing: `cp x <primary-checkout>` names the primary
# checkout DIRECTORY itself as the write target, and starting at
# dirname(PATH) would walk to the primary's PARENT and miss
# `<primary>/.git` entirely — silently escaping the fence for the "write the
# checkout root itself" shape.
repo_root_for_path() {
    local p="${1:-}"
    [ -n "$p" ] || return 1
    local d
    if [ -d "$p" ]; then
        d="$p"
    else
        d=$(dirname "$p") || return 1
    fi
    local prev=""
    while [ "$d" != "$prev" ]; do
        if [ -e "$d/.git" ]; then
            printf '%s\n' "${d%/}"
            return 0
        fi
        prev="$d"
        d=$(dirname "$d") || d="$prev"
    done
    return 1
}

# main_checkout_verdict PATH — the shared "may this path be written?"
# predicate (HIMMEL-2526). PATH must already be canonical and absolute —
# callers canonicalise first (guard_canon_path, or block-edit-on-main.sh's own
# canon()).
#
# Echoes the resolved repo root on stdout (for the caller's message; empty
# when PATH is not inside any repo). Return codes:
#   0 — allow
#   1 — deny: the target's repo is on its default branch (main/master)
#   2 — deny: the target's repo is the PRIMARY checkout on a feature branch
#   3 — cannot evaluate (branch unreadable) — callers MUST fail CLOSED on this
#
# The decision sequence below is EXACTLY the order block-edit-on-main.sh used
# in its inline form — preserve it; that hook's smoke test pins it:
#   1. resolve repo root; not in a repo -> allow
#   2. <repo>/handovers/* -> allow (docs carve-out)
#   3. branch check: rc=1 + `.git` NOT a directory (linked worktree/submodule)
#      -> allow; rc=1 + `.git` IS a directory -> "primary-feature"; rc=0 ->
#      "main"; rc>=2 -> cannot-evaluate
#   4. ignored-untracked exemption: a file that is BOTH untracked AND
#      gitignored can never land in an on-main/primary-feature commit, so
#      blocking it is a false positive — UNLESS its basename is in the
#      secret-file class (.env, keys, ... — stays denied so an unattended
#      write can't clobber a real secret) OR is exactly `.single-writer`.
#      The `.single-writer` carve-out is NEW (HIMMEL-2526 §4): that marker is
#      itself gitignored+untracked, so without this exclusion a Bash write
#      could CREATE it and silently disable this entire fence from inside
#      the very checkout it's meant to protect. Any `ls-files` rc other than
#      1 (untracked) skips the exemption — fail closed on a git-command
#      surprise.
#   5. EDIT_ON_MAIN_OK=1 -> allow (session bypass)
#   6. <repo>/.single-writer marker present -> allow (opt-in single-writer repo)
#   7. deny: "main" -> rc 1, "primary-feature" -> rc 2
#
# Every fallible internal command is captured via an explicit `|| var=...`
# (never a bare failing statement) so this predicate is safe to call from a
# `set -e` caller without the caller itself having to shield every line —
# only the OUTER call (which legitimately returns nonzero as part of its own
# contract, same as every other predicate in this file) needs the caller's
# own `|| rc=$?` guard.
main_checkout_verdict() {
    local file_real="${1:-}"
    local repo_real=""
    repo_real=$(repo_root_for_path "$file_real") || repo_real=""
    [ -n "$repo_real" ] || return 0
    repo_real="${repo_real%/}"

    case "$file_real" in
        "$repo_real"/handovers/*)
            printf '%s\n' "$repo_real"
            return 0
            ;;
    esac

    local branch_rc=0
    is_on_main "$repo_real" || branch_rc=$?

    local block_reason=""
    if [ "$branch_rc" -eq 1 ]; then
        if [ ! -d "$repo_real/.git" ]; then
            printf '%s\n' "$repo_real"
            return 0
        fi
        block_reason="primary-feature"
    elif [ "$branch_rc" -eq 0 ]; then
        block_reason="main"
    else
        printf '%s\n' "$repo_real"
        return 3
    fi

    local base="${file_real##*/}"
    if ! is_secret_basename "$file_real" && [ "$base" != ".single-writer" ]; then
        local ls_rc=0
        git -C "$repo_real" ls-files --error-unmatch -- "$file_real" >/dev/null 2>&1 || ls_rc=$?
        if [ "$ls_rc" -eq 1 ] && git -C "$repo_real" check-ignore -q -- "$file_real" >/dev/null 2>&1; then
            printf '%s\n' "$repo_real"
            return 0
        fi
    fi

    if [ "${EDIT_ON_MAIN_OK:-0}" = "1" ]; then
        printf '%s\n' "$repo_real"
        return 0
    fi

    if [ -f "$repo_real/.single-writer" ]; then
        printf '%s\n' "$repo_real"
        return 0
    fi

    printf '%s\n' "$repo_real"
    if [ "$block_reason" = "primary-feature" ]; then
        return 2
    fi
    return 1
}
