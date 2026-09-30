#!/usr/bin/env bash
# PreToolUse hook: block-unresolved-cr-merge.sh
#
# Blocks `gh pr merge` on FOUR independent gates, run in order:
#   1. CR gate (HIMMEL-936): unresolved CodeRabbit review threads or a
#      CodeRabbit check-run still running on the head SHA (except a proven old
#      zombie backed by success status + zero unresolved threads, HIMMEL-980;
#      operator rule 2026-07-11: never merge over unresolved CodeRabbit remarks).
#   2. CI-green gate (HIMMEL-1043): the PR's head SHA must have green overall
#      CI — no failing/pending check-run, no failing/pending combined status.
#      This repo has NO branch protection, so GitHub will not otherwise block a
#      merge over red/pending CI (operator rule: "ready to merge" requires green).
#   3. Console-GO gate (HIMMEL-2919/HIMMEL-3142): when this is a console-spawned
#      leg (HIMMEL_CONSOLE_LEG truthy, exported by headed-arm-leg.sh), the PR's
#      head SHA must have a matching GO file under the handover root's
#      `.locks/go/` (console-kit/go.sh writes it — "the file IS the GO"). Before
#      this gate existed, a leg merging via `gh pr merge` directly (instead of
#      merge-on-green.sh) never consulted `.locks/go/` at all, so the GO was
#      advisory rather than binding on that path (PR #798). No bypass env var —
#      same as merge-on-green.sh's own console-GO gate, which this one shares
#      its predicate with (scripts/lib/go-gate.sh) so the two cannot drift.
#      Untouched for a non-leg session (HIMMEL_CONSOLE_LEG unset/falsy skips it
#      whole).
#   4. CI trust-path gate (HIMMEL-3910): for EVERY session, a PR touching a CI
#      trust path (scripts/ci/ci-trust-paths.txt on the default branch) needs a
#      trust-reviewed console GO (go.sh --trust-reviewed) and a merge pinned
#      to its head — merge-on-green.sh's rule (HIMMEL-3895), asked through the
#      same trust_path_check in scripts/lib/go-gate.sh. Fails closed.
# Sibling of check-cr-marker-on-pr-create.sh / block-merged-pr-commit.sh.
#
# Exit: 0 allow (incl. every fail-open path), 2 block (stderr shown to model).
# HIMMEL-3915: the PR lookup itself (bounded `gh pr view`) fails CLOSED on a
# real merge; the CR/CI gates' own API errors stay fail-open (HIMMEL-936).
# Bypass: CR_MERGE_GATE_OK=1 and/or CI_MERGE_GATE_OK=1 in the LAUNCHING shell
# (each gates its own check independently). CR_PROFILE=none skips the CR gate.
# The console-GO and trust-path gates have no bypass (see gates 3 and 4 above).
set -uo pipefail
# NOT set -e: fail-open hook, must never abort on a sub-call's rc 1.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The CR-gate bypasses (CR_MERGE_GATE_OK=1 / CR_PROFILE=none) are handled
# INSIDE cr_merge_gate (self-bypass → rc 0), NOT with an early exit here — an
# early `exit 0` would also skip the independent CI-green gate below, letting a
# red/pending-CI merge through whenever a CR bypass is set (CodeRabbit, #1230).
# The CI gate has its OWN bypass (CI_MERGE_GATE_OK=1) inside ci_green_gate. So
# both gates are always reached; each self-bypasses its own check.
command -v jq >/dev/null 2>&1 || exit 0   # cannot parse stdin: fail open

payload=$(cat) || exit 0

# Fast path: skip the jq spawn unless the raw payload could contain a merge.
# Deliberately LOOSE (`merge` anywhere, not the exact phrase): a double-spaced
# `gh  pr  merge` must NOT dodge the gate via the fast path (plan-critic #2);
# non-merge commands mentioning "merge" fall through to the cheap regex below.
case "$payload" in
    *merge*) ;;
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
cmd=$(printf '%s' "$cmd" | tr -d '\r')
[ -z "$cmd" ] && exit 0

# Quote-blindness guard (coderabbit CR round): match + tokenize on a copy with
# each QUOTED SPAN replaced by the placeholder token Q - text inside quotes can
# neither look like a command boundary (`git commit -m "done; gh pr merge 42"`
# is NOT a merge - false-block vector) nor smuggle a quoted selector, while
# token POSITIONS survive so value-taking flags (`--repo "o/r" 42`) still
# consume exactly one token (coderabbit app round: full deletion collapsed
# positions and let --repo eat the selector). An unbalanced quote leaves
# residue whose worst case is a mis-extracted selector -> rc=3 re-anchor ->
# fail-open, never a false block on quoted text.
cmd_stripped=$(printf '%s' "$cmd" | sed -e "s/'[^']*'/Q/g" -e 's/"[^"]*"/Q/g')

_deny() { echo "block-unresolved-cr-merge: $1" >&2; exit 2; }

# HIMMEL-3918 (2): a prefix before `gh` (env / command / builtin / exec / ...,
# or a NAME=value assignment) moved `gh` out of command position, so the anchor
# below skipped the merge entirely. Stripping prefixes needs a grammar (env -u X,
# env -i, `command -p`, ...), and every clever parse rule here has been a bypass
# (HIMMEL-3915), so a prefixed merge is DENIED, not parsed.
# shellcheck disable=SC2016  # literal backtick/$( in the class - intentional
if printf '%s' "$cmd_stripped" | grep -E '(^|[;&|`$(]|[[:space:]])(env|command|builtin|exec|nohup|time|sudo|xargs)[[:space:]]+([^;&|]*[[:space:]])?gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)|[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' >/dev/null; then
    _deny "a gh pr merge behind an env/command/builtin/exec prefix or a NAME=value assignment is not parsed — refusing (GATE INTEGRITY). Run it bare with --match-head-commit, or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
fi

# Command-position anchor (POSIX classes - BSD grep lacks \s/\b; coderabbit
# app round). `merge` must be followed by whitespace or end-of-string.
# shellcheck disable=SC2016  # literal backtick/$( in the class - intentional
if ! printf '%s' "$cmd_stripped" | grep -E '(^|[;&|`$(][[:space:]]*)gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' >/dev/null; then
    exit 0
fi

# Isolate the SEGMENT containing `gh pr merge` before tokenizing. A whole-
# command token walk trips on earlier `merge` words: `git merge main && gh pr
# merge 42` would take "main" as the selector (plan-critic #1). Split on
# ; && || and newlines (NOT |) with bash-native expansion - BSD sed leaves
# \n LITERAL in replacements, which silently broke this split on macOS
# (coderabbit app round) - then pick the first matching segment.
merge_segment=""
normalised=${cmd_stripped//&&/$'\n'}
normalised=${normalised//||/$'\n'}
normalised=${normalised//;/$'\n'}
while IFS= read -r segment || [ -n "$segment" ]; do
    # shellcheck disable=SC2016  # literal backtick/$( in the class - intentional
    # HIMMEL-3918: the boundary set matches the command-position anchor above (a
    # bare `&` / `|` is not a segment split, so `sleep 1 & gh pr merge 42` and
    # `x | gh pr merge 42` must still find their merge here, not fall to exit 0).
    if printf '%s' "$segment" | grep -E '(^|[;&|`$(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' >/dev/null; then
        merge_segment="$segment"
        break
    fi
done <<EOF
$normalised
EOF
[ -z "$merge_segment" ] && exit 0

# HIMMEL-3918 (1): the cwd-branch anchor (and every gh call) resolves against the
# payload's cwd, but a `cd`/`pushd` earlier in the same command moves gh into
# another checkout, so the gates would gate the WRONG branch. Resolving that
# correctly needs a shell interpreter; deny any directory change instead.
if printf '%s' "$cmd_stripped" | grep -E '(^|[^[:alnum:]_./-])(cd|pushd|popd)([^[:alnum:]_./-]|$)' >/dev/null; then
    _deny "a directory change (cd/pushd/popd) in the same command as gh pr merge — the gates resolve the PR from the hook's cwd, not where the merge would run — refusing (GATE INTEGRITY). Run the merge from its own checkout, or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
fi

# Extract the selector + --repo from the merge segment only;
# selector = first non-flag token after the `merge` verb.
sel=""; repo=""; match_head=""
set -f
# shellcheck disable=SC2086
set -- $merge_segment
set +f
seen_merge=0
while [ "$#" -gt 0 ]; do
    if [ "$seen_merge" = "0" ]; then
        [ "$1" = "merge" ] && seen_merge=1
        shift; continue
    fi
    # gh pr merge's own arguments end at the first | & > < (a pipe, a
    # background, a redirect): what follows belongs to another command or a
    # file, so `--squash | sort -h` / `& ls -h` / `> --help` must not read as
    # merge flags (HIMMEL-3915 judge round).
    # HIMMEL-3918 (6): only a | or & ENDS the walk; a redirect (`2>&1`, `>f`,
    # `> f`, `&>f`) is skipped, with a spaced target consumed, and the walk goes
    # on - `gh pr merge 2>&1 42` merges #42, so stopping at the redirect made the
    # hook gate the cwd branch instead.
    stop_walk=0; skip_next=0; cur="$1"; rest=""
    case "$1" in
        '&>'*) cur=""; rest="${1#&}" ;;
        *[\|\&\>\<]*)
            cur="${1%%[|&><]*}"
            case "${1:${#cur}:1}" in
                '>'|'<') rest="${1:${#cur}}" ;;
                *) stop_walk=1 ;;
            esac ;;
    esac
    if [ -n "$rest" ]; then
        # `2>&1` / `42>x`: an all-digit prefix before a > or < is an fd number,
        # not a selector - discard it (HIMMEL-3915 judge NO-GO).
        case "$cur" in *[!0-9]*) ;; *) cur="" ;; esac
        # The redirect target: nothing after the operator run means the NEXT token
        # is the target; a | or & inside it ends the walk (`>f|cat`).
        rest_ops="${rest%%[!<>&|]*}"
        rest_tgt="${rest#"$rest_ops"}"
        case "$rest_tgt" in
            # A spaced target that itself carries a | or & (`> f|cat`) ends the walk
            # too: what follows belongs to another command, not to this merge.
            '') skip_next=1
                case "${2-}" in *[\|\&]*) stop_walk=1 ;; esac ;;
            # A second redirect inside the token (`>a> b`) leaves a target this
            # walk cannot place: end the walk rather than guess (deny over parse).
            *[\|\&\>\<]*) stop_walk=1 ;;
        esac
    fi
    if [ "$cur" != "$1" ]; then
        shift
        [ "$skip_next" = "1" ] && [ "$#" -ge 1 ] && shift
        if [ -z "$cur" ]; then
            [ "$stop_walk" = "1" ] && break
            continue
        fi
        set -- "$cur" "$@"
    fi
    case "$1" in
        --repo=*) repo="${1#--repo=}" ;;
        --repo|-R) if [ "$#" -ge 2 ]; then repo="$2"; shift; fi ;;
        # --match-head-commit is captured (not just consumed) so gate 3 can
        # verify a leg's merge pins the head its GO was bound to (HIMMEL-3142
        # CR round). Both spellings: the space form below, and =-form here.
        --match-head-commit=*) match_head="${1#--match-head-commit=}" ;;
        --match-head-commit)
            if [ "$#" -ge 2 ]; then match_head="$2"; shift; fi ;;
        # gh pr merge's own value-taking flags: consume the value token so it
        # is never mistaken for the selector (coderabbit CR round; the rc=3
        # re-anchor still backstops flags this list misses).
        -b|--body|-F|--body-file|-t|--subject|-A|--author-email)
            if [ "$#" -ge 2 ]; then shift; fi ;;
        --*|-*) ;;             # other flags: ignore (an unknown value-taking
                               # flag may feed a value token; a wrong selector
                               # only fails gh pr view = rc 3 -> re-anchor,
                               # never a false block)
        *) [ -z "$sel" ] && sel="$1" ;;
    esac
    [ "$stop_walk" = "1" ] && break
    shift
done

# No --help/-h carve-out (HIMMEL-3915): every spelling of it was a new bypass
# (escaped spaces, $'..' quoting, delimiters). A help-flagged merge is gated like
# any other; the deny text points at `gh help pr merge`, which is not a merge.

# Strip surrounding quotes the tokenizer preserved: `gh pr merge "42"` must
# not hand the literal `"42"` to gh (codex-adv-1 — quoted selector dodged the
# gate via the pr-view fail-open).
sel="${sel#\"}"; sel="${sel%\"}"; sel="${sel#\'}"; sel="${sel%\'}"
repo="${repo#\"}"; repo="${repo%\"}"; repo="${repo#\'}"; repo="${repo%\'}"
match_head="${match_head#\"}"; match_head="${match_head%\"}"
match_head="${match_head#\'}"; match_head="${match_head%\'}"

# The cwd branch — fallback anchor when no/bad selector was extracted.
cwd_branch=""
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
    cwd_branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
fi

# No explicit selector: gh infers the current branch; do the same.
[ -z "$sel" ] && sel="$cwd_branch"
[ -z "$sel" ] && exit 0   # cannot resolve target: fail open

# ── Resolve the PR (number + head, shared by gates 3 and 4) — FIRST, before any
# gate, and BOUNDED. HIMMEL-3915: on a real merge command an UNRESOLVED lookup
# (selector AND cwd-branch re-anchor) fails CLOSED for every session. It used to
# exit 0 after the CR/CI gates, so a transient gh/auth error let a trust-path PR
# through with no GO; and an unbounded `gh pr view` hang (here or in the gates'
# own lookups) exhausted the hook budget, which Claude Code reads as non-blocking.
# The HIMMEL-936 api-error-fails-open contract now covers only the CR/CI gates'
# own API reads, after this lookup has already succeeded. Each lookup is
# bounded (10s); a timeout reads as unresolved.
# _gate4_bounded <secs> <outfile> <cmd...> — run <cmd> with stdout to
# <outfile> (stderr to $_gate4_err when set, else discarded), killed after <secs>; rc is the command's, or 124 on timeout. Bash
# native (no timeout binary) so it bounds a shell function the same way on
# every platform.
# ponytail: kill -9 reaches the backgrounded subshell, not an in-flight gh it
# spawned (orphaned, it finishes on its own), upgrade path: a process-group
# kill if an orphaned gh is ever seen outliving its hook.
_gate4_bounded() {
    local secs=$1 out=$2 pid ticks=0
    shift 2
    "$@" >"$out" 2>"${_gate4_err:-/dev/null}" &
    pid=$!
    while [ "$ticks" -lt $((secs * 5)) ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
        ticks=$((ticks + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124
    fi
    wait "$pid"
}
go_tmp=$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-view.XXXXXX" 2>/dev/null) || go_tmp=""
gh_to_flag=$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-timeout.XXXXXX" 2>/dev/null) || gh_to_flag=""
trap 'rm -f "$go_tmp" "$gh_to_flag" "${trust_tmp:-}"' EXIT
# HIMMEL-3918 (3): every gh call the sourced gate libraries make (cr-merge-gate,
# ci-green-gate and the cr-signal / cr-body-findings helpers they call) goes
# through this shadow function, bounded (10s) like the lookup above. The libs
# fail OPEN on a gh error (HIMMEL-936), and an unbounded hang would run out the
# hook budget, which Claude Code reads as non-blocking - so a timeout is recorded
# in $gh_to_flag and the hook DENIES after each gate call (_gh_timed_out). Set in
# the hook, not the libs: it also bounds the transitive calls, and the libs'
# other callers (check-ci, pr-merge.sh) keep their own behaviour.
gh() {
    local out errf rc=0 _gate4_err
    # One timeout already means deny: skip later calls so a run of hung gh calls
    # cannot each spend another 10s of the hook budget before the deny.
    if [ -n "$gh_to_flag" ] && [ -s "$gh_to_flag" ]; then return 124; fi
    out=$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-gh.XXXXXX" 2>/dev/null) || out=""
    errf=$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-ghe.XXXXXX" 2>/dev/null) || errf=""
    if [ -z "$out" ] || [ -z "$errf" ]; then
        rm -f "$out" "$errf"
        [ -n "$gh_to_flag" ] && echo 1 >"$gh_to_flag"
        return 124   # cannot bound the call: read as a timeout (deny)
    fi
    # stderr is replayed: trust_path_check tells a 404 from an outage by it.
    _gate4_err=$errf
    _gate4_bounded 10 "$out" command gh "$@" || rc=$?
    if [ "$rc" = "124" ] && [ -n "$gh_to_flag" ]; then echo 1 >"$gh_to_flag"; fi
    cat "$out" 2>/dev/null
    cat "$errf" >&2 2>/dev/null
    rm -f "$out" "$errf"
    return "$rc"
}
_gh_timed_out() { [ -z "$gh_to_flag" ] || [ -s "$gh_to_flag" ]; }
# _go_view <selector> [repo] — sets go_meta ("" on any failure or timeout).
_go_view() {
    go_meta=""
    [ -n "$go_tmp" ] || return 1
    if [ -n "${2:-}" ]; then
        _gate4_bounded 10 "$go_tmp" gh pr view "$1" --repo "$2" --json number,headRefOid,url || return 1
    else
        _gate4_bounded 10 "$go_tmp" gh pr view "$1" --json number,headRefOid,url || return 1
    fi
    go_meta=$(cat "$go_tmp" 2>/dev/null) || go_meta=""
}
_go_view "$sel" "$repo" || go_meta=""
go_num=$(printf '%s' "$go_meta" | jq -r '.number // empty' 2>/dev/null || true)
go_sha=$(printf '%s' "$go_meta" | jq -r '.headRefOid // empty' 2>/dev/null || true)
if { [ -z "$go_num" ] || [ -z "$go_sha" ]; } && [ -n "$cwd_branch" ] && { [ "$cwd_branch" != "$sel" ] || [ -n "$repo" ]; }; then
    _go_view "$cwd_branch" "" || go_meta=""
    go_num=$(printf '%s' "$go_meta" | jq -r '.number // empty' 2>/dev/null || true)
    go_sha=$(printf '%s' "$go_meta" | jq -r '.headRefOid // empty' 2>/dev/null || true)
fi
if [ -z "$go_num" ] || [ -z "$go_sha" ]; then
    echo "block-unresolved-cr-merge: cannot resolve the PR for '$sel' (gh pr view failed or timed out) — refusing (GATE INTEGRITY: the CR, CI, leg-GO and trust-path gates need the PR number and head). Retry the merge, or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)" >&2
    exit 2
fi

# HIMMEL-3918 (4): a gate library that will not load DENIES on a real merge (it
# used to `|| exit 0`, so a missing/unreadable/truncated lib silently dropped the
# CR and CI gates). Readability first, per scripts/hooks/CLAUDE.md: on bash 3.2 a
# failed `.` exits the shell regardless of an `||` guard.
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../lib/cr-merge-gate.sh" ] && . "$SCRIPT_DIR/../lib/cr-merge-gate.sh"; } 2>/dev/null \
        || ! declare -F cr_merge_gate >/dev/null 2>&1; then
    _deny "cannot load scripts/lib/cr-merge-gate.sh — refusing (the CR gate must fail closed, not silently no-op)"
fi

reason=""
rc=0
reason=$(cr_merge_gate "$sel" "$repo") || rc=$?
if [ "$rc" = "3" ] && [ -n "$cwd_branch" ]; then
    # The extracted token did not resolve to a PR (a value-taking flag's
    # argument or leftover quoting mistaken for the selector — codex-1).
    # Re-anchor to the cwd branch IN THE CWD REPO (drop the extracted repo:
    # it may itself be a quote placeholder — coderabbit app round) so
    # ordinary CLI syntax cannot dodge the gate; if this ALSO fails to
    # resolve, the gate stays fail-open. Guard against re-running the
    # identical lookup (same branch, no repo override).
    if [ "$cwd_branch" != "$sel" ] || [ -n "$repo" ]; then
        rc=0
        reason=$(cr_merge_gate "$cwd_branch" "") || rc=$?
    fi
fi
_gh_timed_out && _deny "a gh call in the CR gate timed out (10s bound) or could not be bounded — refusing (GATE INTEGRITY: a hung read must not read as an allow). Retry, or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
if [ "$rc" = "2" ]; then
    echo "block-unresolved-cr-merge: $reason (For help run: gh help pr merge)" >&2
    exit 2
fi

# ── CI-green merge gate (HIMMEL-1043) — runs SECOND, after the CR gate ──
# Same extracted selector ($sel)/$repo + rc=3 re-anchor pattern as the CR gate
# above; the CI gate is independent (its own bypass CI_MERGE_GATE_OK=1) and
# never coupled to CR_PROFILE. A guard bug must NEVER block a legit merge, so
# every unresolvable/degraded path fails open (rc 0/3) inside ci_green_gate.
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../lib/ci-green-gate.sh" ] && . "$SCRIPT_DIR/../lib/ci-green-gate.sh"; } 2>/dev/null \
        || ! declare -F ci_green_gate >/dev/null 2>&1; then
    _deny "cannot load scripts/lib/ci-green-gate.sh — refusing (the CI gate must fail closed, not silently no-op)"
fi

ci_reason=""
ci_rc=0
ci_reason=$(ci_green_gate "$sel" "$repo") || ci_rc=$?
if [ "$ci_rc" = "3" ] && [ -n "$cwd_branch" ]; then
    # Mirror the CR gate's re-anchor: the extracted token did not resolve to a
    # PR, so retry once on the cwd branch (in the cwd repo) so ordinary CLI
    # syntax cannot dodge the gate; if this also fails, ci_green_gate fails open.
    if [ "$cwd_branch" != "$sel" ] || [ -n "$repo" ]; then
        ci_rc=0
        ci_reason=$(ci_green_gate "$cwd_branch" "") || ci_rc=$?
    fi
fi
_gh_timed_out && _deny "a gh call in the CI gate timed out (10s bound) or could not be bounded — refusing (GATE INTEGRITY: a hung read must not read as an allow). Retry, or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
if [ "$ci_rc" = "2" ]; then
    echo "block-red-ci-merge: $ci_reason" >&2
    exit 2
fi

# ── Console-GO merge gate (HIMMEL-2919/HIMMEL-3142) — runs THIRD, after CR
# and CI — see the header comment for gate 3. Only binds a console-spawned leg
# (console_leg truthy, scripts/lib/go-gate.sh — HIMMEL-3149); a non-leg
# session (HIMMEL_CONSOLE_LEG unset/empty, by far the common case) never
# reaches the `. go-gate.sh` below, so gate 3 never turns a broken library
# into a blocker for sessions it was never meant to bind. (Gate 4, the
# trust-path gate at the end, does load go-gate.sh for EVERY session — see
# there, HIMMEL-3910.)
#
# console_leg lives in scripts/lib/go-gate.sh beside go_gate() itself, shared
# with merge-on-green.sh's own console-GO gate and go.sh's own refusal, so
# none of the three can drift on "is this a leg". The five-spelling
# interpretation (empty/0/false/off/no, case-insensitive, whitespace-stripped)
# is console_leg's alone — this outer check is only "is the var non-empty at
# all", cheap enough not to duplicate that logic, so an explicitly-set falsy
# value (e.g. HIMMEL_CONSOLE_LEG=0) still sources go-gate.sh and gets the
# real, shared interpretation.
is_leg=1
if [ -n "${HIMMEL_CONSOLE_LEG:-}" ]; then
    # Drop any go_gate/console_leg already in scope first (a PATH executable
    # or an inherited `export -f` would otherwise survive the source below
    # undetected) so only the file's own definitions can satisfy the
    # declare -F checks below.
    unset -f go_gate console_leg go_mac go_key_file go_resolve_root _go_in_harness 2>/dev/null || true
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    if ! . "$SCRIPT_DIR/../lib/go-gate.sh" 2>/dev/null || ! declare -F console_leg >/dev/null 2>&1; then
        echo "block-unresolved-cr-merge: cannot load scripts/lib/go-gate.sh — refusing (the console-leg marker check must fail closed, not silently no-op)" >&2
        exit 2
    fi
    console_leg || is_leg=0
else
    is_leg=0
fi

# PR number + head-sha (shared by gates 3 and 4) were resolved up front
# (HIMMEL-3915, see "Resolve the PR" above).
go_url=$(printf '%s' "$go_meta" | jq -r '.url // empty' 2>/dev/null || true)

# HIMMEL-3578: the GO mac binds the repo, and gate 4 reads the trust list from
# it, so resolve nwo the same way merge-on-green.sh does — from an explicit
# --repo/-R on the merge command itself when given (already extracted into
# $repo above), else the current checkout. `gh repo view` is timeout-bounded:
# this hook runs on a budget, and a hang here must read as a refusal, never
# as an allow.
# HIMMEL-3578 (round 2): resolve the GNU-semantics `timeout` through the
# shared resolver, which also tries `gtimeout` — a bare `timeout` check alone
# left every merge refused on stock macOS (no coreutils). Gate 4 bounds its
# own calls with it too.
# shellcheck disable=SC1091
# shellcheck source=../lib/timeout-bin.sh
. "$SCRIPT_DIR/../lib/timeout-bin.sh"
go_nwo="$repo"
if [ -z "$go_nwo" ]; then
    if [ -n "${_TIMEOUT_BIN:-}" ]; then
        go_nwo=$("$_TIMEOUT_BIN" 5 gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || go_nwo=""
    else
        # HIMMEL-3585: neither `timeout` nor `gtimeout` is on PATH, so the
        # bound above is unavailable — a bare `gh repo view` here would run
        # UNBOUNDED and a hang would fail this fail-closed hook OPEN via
        # Claude Code's own hook timeout instead of reading as a refusal.
        # Bash-native bound: background `gh`, poll for up to 5s, then
        # kill it and treat that exactly like a timeout (empty go_nwo).
        _gh_out="$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-gh.XXXXXX" 2>/dev/null)" || _gh_out=""
        if [ -z "$_gh_out" ]; then
            go_nwo=""
        else
            gh repo view --json nameWithOwner --jq .nameWithOwner >"$_gh_out" 2>/dev/null &
            _gh_pid=$!
            _gh_waited=0
            while [ "$_gh_waited" -lt 5 ] && kill -0 "$_gh_pid" 2>/dev/null; do
                sleep 1
                _gh_waited=$((_gh_waited + 1))
            done
            if kill -0 "$_gh_pid" 2>/dev/null; then
                kill -9 "$_gh_pid" 2>/dev/null
                go_nwo=""
            else
                go_nwo="$(cat "$_gh_out" 2>/dev/null)"
            fi
            wait "$_gh_pid" 2>/dev/null
            rm -f "$_gh_out"
        fi
    fi
fi
if [ -z "$go_nwo" ]; then
    echo "block-unresolved-cr-merge: cannot resolve this repo's owner/name for PR #$go_num — refusing (GATE INTEGRITY: the GO mac binds the repo, and the trust-path gate reads its list from it). Pass --repo <owner>/<name>, or run from a checkout gh can resolve." >&2
    exit 2
fi

# HIMMEL-3910 (judge round): gates 3 and 4 use the PR's CANONICAL owner/name,
# read from the url of the PR gh resolved — never the --repo text as typed.
# gh accepts `-R github.com/o/r` (HOST/OWNER/REPO); fed verbatim to the trust
# list read, that spelling 404s, and a 404 reads as "another repo"
# (not-adopted), so a trust-path PR merged with no trust-reviewed GO. The
# typed or resolved nwo must name the same repo as the PR url (host and .git
# dropped, case-insensitive); anything else is refused, never guessed.
go_canon=""
case "$go_url" in
    https://*/*/*/pull/*)
        go_canon=${go_url#https://*/}
        go_canon=${go_canon%/pull/*} ;;
esac
case "$go_canon" in
    */*/*|/*|*/|*[!A-Za-z0-9._/-]*) go_canon="" ;;
    */*) ;;
    *) go_canon="" ;;
esac
if [ -z "$go_canon" ]; then
    echo "block-unresolved-cr-merge: cannot read PR #$go_num's owner/name from its url ('$go_url') — refusing (GATE INTEGRITY: the GO mac and the trust-path gate bind the canonical repo)." >&2
    exit 2
fi
go_typed=${go_nwo#https://}
go_typed=${go_typed#http://}
go_typed=${go_typed%/}
go_typed=${go_typed%.git}
case "$go_typed" in */*/*) go_typed=${go_typed#*/} ;; esac
if [ "$(printf '%s' "$go_typed" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$go_canon" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "block-unresolved-cr-merge: '$go_nwo' does not name the repo PR #$go_num resolved on ($go_canon) — refusing (GATE INTEGRITY). Pass --repo $go_canon." >&2
    exit 2
fi
go_nwo=$go_canon

if [ "$is_leg" -eq 1 ]; then
    go_root=""
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    # HIMMEL-3573 row 1: go_resolve_root is the same resolver go.sh writes
    # through, so a leg running `gh pr merge` directly with no HANDOVER_DIR in
    # its own env still lands on the anchor's .env-configured root, the one a
    # valid console GO was actually written under — a plain handover_root()
    # here fell back to the harness repo's inline stub instead and falsely
    # refused a valid GO.
    if . "$SCRIPT_DIR/../lib/handover-path.sh" 2>/dev/null && declare -F go_resolve_root >/dev/null 2>&1; then
        go_root=$(go_resolve_root "$SCRIPT_DIR/../.." 2>/dev/null) || go_root=""
    fi
    # go-gate.sh is already sourced above (console_leg check) — only confirm
    # go_gate and go_mac are defined (a truncated file could define
    # console_leg but not the rest).
    if ! declare -F go_gate >/dev/null 2>&1 || ! declare -F go_mac >/dev/null 2>&1; then
        echo "block-unresolved-cr-merge: scripts/lib/go-gate.sh sourced but go_gate is not defined (truncated file?) — refusing (a console-spawned leg's GO gate must fail closed, not silently no-op)" >&2
        exit 2
    fi
    go_reason=""
    go_rc=0
    go_reason=$(go_gate "$go_num" "$go_sha" "$go_root" "$go_nwo") || go_rc=$?
    if [ "$go_rc" -ne 0 ]; then
        if [ -z "$go_reason" ]; then
            go_reason="go_gate for PR #$go_num at $go_sha returned an unexpected exit code ($go_rc) — this is a console-spawned leg; send READY to your console and wait for GO"
        fi
        echo "block-unresolved-cr-merge: $go_reason" >&2
        exit 2
    fi

    # A confirmed GO is bound to $go_sha, but that is THIS hook's own
    # `gh pr view` read, not a property of the merge command that
    # follows — a separate `gh pr merge` invocation can land a different
    # commit unless it pins one itself (coderabbit CR round). Only this
    # half is fail-closed (GATE INTEGRITY, same boundary as the GO-file
    # check above): the resolution above still fails OPEN on an
    # unresolvable selector like its siblings, but once a GO is
    # confirmed valid, an unpinned or mismatched merge command must
    # never pass.
    if [ -z "$match_head" ]; then
        echo "block-unresolved-cr-merge: a console-spawned leg's merge must pin --match-head-commit $go_sha (the head the GO for PR #$go_num was bound to) — none was given" >&2
        exit 2
    fi
    if [ "$match_head" != "$go_sha" ]; then
        echo "block-unresolved-cr-merge: --match-head-commit $match_head does not match the GO-bound head $go_sha for PR #$go_num — refusing" >&2
        exit 2
    fi
fi

# ── Trust-path gate (HIMMEL-3910) — runs FOURTH, for EVERY session. A PR
# touching a CI trust path (scripts/ci/ci-trust-paths.txt) needs a
# trust-reviewed console GO, pinned to its head. merge-on-green.sh has asked
# this since HIMMEL-3895; a direct `gh pr merge` used to pass the same PR on an
# ordinary GO (a leg) or on none (the operator). The question itself is
# trust_path_check in scripts/lib/go-gate.sh, shared with merge-on-green.sh so
# the two entry points cannot drift. Unlike gate 3 this binds the operator too,
# exactly as merge-on-green.sh does for every caller: go.sh --trust-reviewed is
# the operator's route through it. Every failure below refuses — a trust check
# that cannot run must never read as "no trust path".
gate4_refuse() {
    echo "block-unresolved-cr-merge: $1" >&2
    exit 2
}
# Drop every go-gate name already in scope (a leg sourced the file for gate 3;
# an inherited `export -f` would otherwise survive) so only the anchor file's
# own definitions can satisfy the declare -F checks.
unset -f trust_path_check go_trust_gate go_trust_id_ok go_gate _go_gate_verify console_leg go_mac go_key_file go_resolve_root _go_in_harness 2>/dev/null || true
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../lib/go-gate.sh" ] && . "$SCRIPT_DIR/../lib/go-gate.sh"; } 2>/dev/null \
        || ! declare -F trust_path_check >/dev/null 2>&1 || ! declare -F go_trust_gate >/dev/null 2>&1; then
    gate4_refuse "cannot load trust_path_check and go_trust_gate from scripts/lib/go-gate.sh — refusing (the CI trust-path gate must fail closed, not silently no-op)"
fi
trust_anchor=$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd -P) || trust_anchor=""
[ -n "$trust_anchor" ] || gate4_refuse "cannot resolve the harness anchor for the CI trust-path check of PR #$go_num — refusing"
trust_tmp=$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-trust.XXXXXX" 2>/dev/null) \
    || gate4_refuse "cannot create a temp file for the CI trust-path check of PR #$go_num — refusing"
_gate4_bounded 10 "$trust_tmp" gh repo view "$go_nwo" --json defaultBranchRef --jq '.defaultBranchRef.name // ""' || true
trust_branch=$(cat "$trust_tmp" 2>/dev/null) || trust_branch=""
[ -n "$trust_branch" ] \
    || gate4_refuse "cannot read $go_nwo's default branch for the CI trust-path check of PR #$go_num — refusing"
trust_rc=0
_gate4_bounded 30 "$trust_tmp" trust_path_check "$go_nwo" "$go_num" "$go_sha" "$trust_branch" "$trust_anchor" || trust_rc=$?
trust_out=$(cat "$trust_tmp" 2>/dev/null) || trust_out=""
if [ "$trust_rc" -eq 124 ]; then
    gate4_refuse "the CI trust-path check of PR #$go_num timed out — refusing"
fi
if [ "$trust_rc" -ne 0 ]; then
    gate4_refuse "CI trust-path check refused PR #$go_num (${trust_out:-trust_path_check exited $trust_rc with no reason})"
fi
case "$trust_out" in
    none|not-adopted) ;;
    "hit "?*)
        trust_hit=${trust_out#hit }
        trust_root=""
        # shellcheck source=scripts/lib/handover-path.sh
        # shellcheck disable=SC1091
        if . "$SCRIPT_DIR/../lib/handover-path.sh" 2>/dev/null && declare -F go_resolve_root >/dev/null 2>&1; then
            trust_root=$(go_resolve_root "$SCRIPT_DIR/../.." 2>/dev/null) || trust_root=""
        fi
        trust_id=$(go_trust_gate "$go_num" "$go_sha" "$trust_root" "$go_nwo") \
            || gate4_refuse "PR #$go_num touches CI trust path $trust_hit and needs a trust-reviewed GO: ${trust_id:-go_trust_gate refused with no reason}"
        # The trust GO is bound to $go_sha — the merge command must pin it, for
        # the operator as for a leg (same reason as gate 3's pin).
        if [ "$match_head" != "$go_sha" ]; then
            gate4_refuse "PR #$go_num touches CI trust path $trust_hit — the merge must pin --match-head-commit $go_sha (the head its trust-reviewed GO $trust_id is bound to); got '${match_head:-none}'"
        fi
        ;;
    *) gate4_refuse "CI trust-path check gave an unrecognised answer for PR #$go_num — refusing" ;;
esac
# HIMMEL-3918 (5) — runs LAST, so each gate keeps its own reason: head TOCTOU. Every gate read the PR at $go_sha, but a
# bare `gh pr merge 42` merges whatever head the PR has at merge time - a push in
# that window lands unreviewed code past the gates. Gates 3 and 4 already demanded
# the pin when they applied; it is now required of EVERY direct merge, and it must
# equal the head this hook read (gh then aborts if the head moved).
# merge-on-green.sh pins the head itself in its own gh subprocess and never
# reaches this hook, so it is unaffected.
if [ -z "$match_head" ]; then
    _deny "a direct gh pr merge must pin --match-head-commit $go_sha (the head the gates just read for PR #$go_num) — none was given; without it a push after the gates lands unreviewed. Or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
fi
if [ "$match_head" != "$go_sha" ]; then
    _deny "--match-head-commit $match_head does not equal the head $go_sha the gates read for PR #$go_num — refusing. Pin the full 40-char head. (For help run: gh help pr merge)"
fi

exit 0
