#!/usr/bin/env bash
# scripts/cr/coderabbit-review.sh - CodeRabbit CLI finding pass for /pr-check (HIMMEL-926).
#
# Runs `coderabbit review` over the current branch's COMMITTED diff vs the base
# branch and prints the findings on stdout, so /pr-check can merge them as
# [coderabbit-N] blocking candidates (same merge contract as the codex
# adversarial pass, step 3.1). Availability-gated + fail-open: a missing CLI,
# a dead WSL, a timeout, a rate-limit/quota-exhaustion, or a CodeRabbit error
# never blocks the gate - the caller degrades to the remaining critics.
#
# Invocation lanes (resolved in order):
#   1. native - `coderabbit` on PATH (Linux/macOS).
#   2. wsl    - Windows host with the CLI installed inside WSL (the supported
#               install on Windows). wsl.exe is probed for the binary.
#   Neither -> exit 3 with a one-line skip note (caller prints it and moves on).
#
# Both lanes review a TEMP CLONE of the primary checkout, not the live tree:
#   - WSL git cannot resolve a Windows-created worktree (the worktree's .git
#     pointer file holds a C:/ absolute path), and /pr-check usually runs from
#     a worktree.
#   - The clone pins the review to committed state - uncommitted noise in the
#     working tree never leaks into the review.
# The clone is cheap (single-branch, --no-tags).
#
# Usage: coderabbit-review.sh [--branch <b>] [--base <ref>]
#   default --branch = current branch; default --base = repo default branch.
#
# Env: CODERABBIT_TIMEOUT_SECS - wall-clock cap for the review call inside the
#          clone; clone/fetch use one quarter (default 900).
#      CODERABBIT_BIN - test seam: overrides the binary probed/invoked.
#      CODERABBIT_WSL - test seam: overrides the wsl.exe launcher (also lets a
#          POSIX test force the wsl lane).
#
# stdout = CodeRabbit findings (--agent mode). stderr = one panel-availability line
# in the ledger contract (slug = 2nd token, status = 3rd token):
#   "panel-availability: coderabbit ok"
#   "panel-availability: coderabbit unavailable (rc=N)"
# Exit: 0 = review completed (zero findings included); 1 = review failed
# (fail-open at caller); 2 = usage; 3 = not configured (skip, no availability
# line - a machine without the CLI is not a critic drop-out); 4 = rate-limited
# or quota-exhausted (a MISSING review signal - the caller records it
# unavailable and retries later, distinct from a skip and from a real failure).
# bash 3.2-safe.
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage: coderabbit-review.sh [--branch <b>] [--base <ref>]

Reviews the branch's committed diff vs the base via the CodeRabbit CLI
(native PATH install, or inside WSL on Windows) in a temp clone of the
primary checkout. stdout = findings; stderr = one panel-availability line.
Exit: 0 review completed; 1 review failed (fail-open); 2 usage; 3 CLI absent; 4 rate-limited/quota.
EOF
}

BRANCH=""
BASE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --branch) [ $# -ge 2 ] || { echo "coderabbit-review: --branch needs an argument" >&2; exit 2; }; BRANCH="$2"; shift 2 ;;
        --base)   [ $# -ge 2 ] || { echo "coderabbit-review: --base needs an argument" >&2; exit 2; }; BASE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "coderabbit-review: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$BRANCH" ] || BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$BRANCH" ] || { echo "coderabbit-review: no --branch and cannot resolve current branch" >&2; exit 2; }
if [ -z "$BASE" ]; then
    # shellcheck disable=SC1091
    BASE="$(. "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null && default_branch || echo main)"
fi
if [ "$BRANCH" = "$BASE" ]; then
    echo "coderabbit-review: branch equals base ($BASE) - nothing to review" >&2
    exit 2
fi
# Both names ride the wsl.exe command line as positional args - refuse anything
# outside the safe ref-name alphabet rather than trying to quote it through.
case "$BRANCH$BASE" in
    *[!A-Za-z0-9._/+-]*) echo "coderabbit-review: branch/base contains unsupported characters" >&2; exit 2 ;;
esac

# Timeout validation (same convention as critic-panel.sh).
CODERABBIT_TIMEOUT_SECS="${CODERABBIT_TIMEOUT_SECS:-900}"
if expr "$CODERABBIT_TIMEOUT_SECS" : '^[0-9][0-9]*$' > /dev/null 2>&1 && [ "$CODERABBIT_TIMEOUT_SECS" -gt 0 ]; then
    : # valid
else
    echo "coderabbit-review: CODERABBIT_TIMEOUT_SECS=$CODERABBIT_TIMEOUT_SECS invalid, using 900" >&2
    CODERABBIT_TIMEOUT_SECS="900"
fi

# Clone source = the PRIMARY checkout root (worktree branches live in its
# shared refs; a worktree path itself is not cloneable from WSL).
common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
[ -n "$common" ] || { echo "coderabbit-review: not in a git repository" >&2; exit 2; }
SRC="$(cd "$common/.." && pwd -P)" || { echo "coderabbit-review: cannot resolve primary checkout from $common" >&2; exit 2; }

CR_BIN="${CODERABBIT_BIN:-coderabbit}"
WSL_BIN="${CODERABBIT_WSL:-wsl.exe}"
case "$CR_BIN" in
    *[!A-Za-z0-9._/-]*) echo "coderabbit-review: CODERABBIT_BIN contains unsupported characters" >&2; exit 2 ;;
esac

# Lane resolution: native binary first, then WSL probe (Windows).
LANE=""
if command -v "$CR_BIN" >/dev/null 2>&1; then
    LANE="native"
elif command -v "$WSL_BIN" >/dev/null 2>&1; then
    probe_rc=0
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 5 30 "$WSL_BIN" -e bash -lc "command -v $CR_BIN" >/dev/null 2>&1 || probe_rc=$?
    else
        "$WSL_BIN" -e bash -lc "command -v $CR_BIN" >/dev/null 2>&1 || probe_rc=$?
    fi
    if [ "$probe_rc" -eq 0 ]; then
        LANE="wsl"
        # WSL consumes Windows paths only after wslpath translation; hand it the
        # mixed form (C:/...) which survives the command line unmangled.
        if command -v cygpath >/dev/null 2>&1; then
            SRC="$(cygpath -m "$SRC")"
        fi
    elif [ "$probe_rc" -eq 124 ] || [ "$probe_rc" -eq 137 ]; then
        echo "panel-availability: coderabbit unavailable (WSL probe timeout 30s)" >&2
        exit 1
    fi
fi
if [ -z "$LANE" ]; then
    echo "coderabbit pass skipped (coderabbit CLI not found on PATH or in WSL)" >&2
    exit 3
fi

# Inner script, shared by both lanes. Runs under the TARGET bash (native or
# WSL) with positional args: $1=src $2=branch $3=base $4=timeout-secs $5=bin.
# A C:/ src is translated via wslpath (present only inside WSL). Clone, fetch,
# and review are timeboxed when coreutils timeout exists; degrade without it
# (same graceful-degrade convention as critic-panel.sh). --agent = the
# agent-readable output mode the coderabbitai/skills code-review skill
# prescribes (findings grouped Critical/Warning/Info).
# shellcheck disable=SC2016  # single-quoted on purpose: expands in the TARGET shell
INNER='set -u
src="$1"; branch="$2"; base="$3"; to="$4"; bin="$5"
op_to=$((to / 4))
# Floor the per-git-step timeout: clone/fetch here are LOCAL ops (<1s normally),
# but a slow machine (Windows Git-Bash) can exceed a tiny op_to and time the
# clone out BEFORE the review runs, masking the rate-limit path (HIMMEL-1219
# T12). 15s is generous for a local clone and never bites production, where the
# default to=900 gives op_to=225.
[ "$op_to" -ge 15 ] || op_to=15
run_git_step() {
    step="$1"; shift
    step_rc=0
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 5 "$op_to" "$@" || step_rc=$?
    else
        "$@" || step_rc=$?
    fi
    if [ "$step_rc" -eq 124 ] || [ "$step_rc" -eq 137 ]; then
        echo "coderabbit-review: $step timed out after ${op_to}s" >&2
    fi
    return "$step_rc"
}
case "$src" in [A-Za-z]:/*) src="$(wslpath -a "$src")" ;; esac
tmp="$(mktemp -d -t coderabbit-cr.XXXXXX)" || exit 1
trap '\''rm -rf "$tmp"'\'' EXIT
run_git_step "git clone" git clone --quiet --no-tags --single-branch --branch "$branch" "$src" "$tmp/repo" || exit $?
cd "$tmp/repo" || exit 1
run_git_step "git fetch" git fetch --quiet origin "+refs/heads/$base:refs/heads/$base" || exit $?
# Point the clone origin at the real upstream so CodeRabbit attributes the
# review to the org plan (HIMMEL-1219). Live evidence (2026-07-20 /pr-check on
# this repo): with origin left as the local primary-checkout filesystem path,
# CodeRabbit reported isProUser:false, orgAttributed:false and the message
# "...will use the free CLI allowance" / "Rate limit exceeded ... waitTime 13
# minutes ... cannot apply an organization plan until this repository is
# connected to CodeRabbit", even though the repo IS connected (the CodeRabbit
# App posts reviews + statuses on its PRs). The CLI matches a review to an
# organization by reading the origin URL; a filesystem path matches nothing,
# so every CLI review burned the free tier instead of the paid org plan - the
# most plausible cause of the exhaustion this ticket exists to manage.
#
# ORDERING IS LOAD-BEARING. The clone + fetch above run while origin is still
# the local path (fast, no network, no credentials). Only AFTER the fetch do
# we rewrite origin to the upstream URL. CodeRabbit reads the URL for
# attribution only and never fetches from it; rewriting before the fetch would
# turn the fetch into a slow network op that needs credentials.
upstream="$(git -C "$src" remote get-url origin 2>/dev/null || true)"
if [ -z "$upstream" ]; then
    # No origin in the primary checkout: CodeRabbit cannot attribute this
    # review to an org. Never fail the review over attribution - proceed on
    # the free allowance exactly as before.
    echo "coderabbit-review: primary checkout has no origin remote; review will use the free CLI allowance" >&2
else
    # SECURITY: strip any embedded credential (user:token@ or bare token@)
    # from an HTTPS origin before writing it into the temp clone config. A
    # credential must not reach disk even briefly (the temp dir is removed on
    # exit, but a secret is never written in the first place). SSH forms
    # (git@github.com:owner/repo.git, ssh://git@host/...) carry no secret -
    # the userinfo is the conventional git SSH username - so they pass
    # through verbatim. Only http(s)://userinfo@host is rewritten, to the
    # bare scheme://host. The [^/]* class matches up to the LAST @ in the
    # authority (greedy, but it cannot cross a slash), so even a malformed
    # password containing a literal @ is fully stripped, while an @ that
    # lives in the PATH (after a slash) is never mistaken for userinfo.
    clean_url="$(printf '\''%s\n'\'' "$upstream" | sed -E '\''s#^(https?://)[^/]*@#\1#'\'')"
    git remote set-url origin "$clean_url" 2>/dev/null \
        || echo "coderabbit-review: git remote set-url failed; review will use the free CLI allowance" >&2
fi
# Capture the review call so a rate-limit/quota message can be classified
# from the CLI text. The CLI exit code is NOT a stable signal for rate-
# limiting - a 429 currently lands as rc=1 (generic failure), which the
# caller fails OPEN, dropping a missing-review signal silently. Streams
# replay to their original fds on the success path so findings still reach
# stdout unchanged.
review_out="$tmp/review.out"
review_err="$tmp/review.err"
if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$to" "$bin" review --agent --type committed --base "$base" >"$review_out" 2>"$review_err"
else
    "$bin" review --agent --type committed --base "$base" >"$review_out" 2>"$review_err"
fi
review_rc=$?
if [ "$review_rc" -eq 124 ] || [ "$review_rc" -eq 137 ]; then
    # Timeout. Two defects both lived here, both fixed:
    # 1. A review that hangs BECAUSE it is being rate-limited must NOT surface
    #    as a generic timeout (rc=124). That is exactly the silent-fail-open
    #    shape this ticket exists to kill: under a bare rc=124 a rate-limited
    #    reviewer is indistinguishable from a slow one, and the caller fails
    #    open on it. Run the SAME rate-limit grep the non-timeout path uses
    #    against both captured streams and classify rc=4 when it matches,
    #    rc=124 otherwise.
    # 2. Emit both captured streams. A timed-out run previously discarded
    #    $review_out / $review_err entirely (they were never emitted on this
    #    path), so a hang yielded zero diagnostic output - you could not tell
    #    why it hung. They are not valid findings, so they go to stderr.
    cat "$review_err" >&2
    cat "$review_out" >&2  # not valid findings - surface for debug, keep stdout clean
    if grep -Ei "rate[ -]?limit|429|too many requests|quota" "$review_out" "$review_err" >/dev/null 2>&1; then
        exit 4
    fi
    exit 124  # genuine timeout - let the outer lane map it to the timeout-flavored line
fi
# Rate-limit/quota detection from the CLI text (case-insensitive, both
# streams - wording and stream choice are not a stable contract). Only
# checked on a FAILED review so a successful run with incidental matching
# text (e.g. a finding that quotes "quota") is never misclassified. Prefer
# a false-positive (loud + retryable) over a false-negative (silent fail-
# open = the bug being fixed).
if [ "$review_rc" -ne 0 ] && grep -Ei "rate[ -]?limit|429|too many requests|quota" "$review_out" "$review_err" >/dev/null 2>&1; then
    cat "$review_err" >&2
    cat "$review_out" >&2  # not valid findings - surface for debug, keep stdout clean
    exit 4
fi
cat "$review_err" >&2
if [ "$review_rc" -eq 0 ]; then
    cat "$review_out"
else
    cat "$review_out" >&2  # not valid findings - keep stdout clean
fi
exit "$review_rc"'

rc=0
if [ "$LANE" = "native" ]; then
    bash -c "$INNER" coderabbit-review "$SRC" "$BRANCH" "$BASE" "$CODERABBIT_TIMEOUT_SECS" "$CR_BIN" || rc=$?
else
    # MSYS arg conversion would rewrite /-prefixed fragments inside the inner
    # script on the way to a native exe - disable it for this one call.
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
        "$WSL_BIN" -e bash -lc "$INNER" coderabbit-review "$SRC" "$BRANCH" "$BASE" "$CODERABBIT_TIMEOUT_SECS" "$CR_BIN" || rc=$?
fi

if [ "$rc" -eq 0 ]; then
    echo "panel-availability: coderabbit ok" >&2
    exit 0
fi
if [ "$rc" -eq 4 ]; then
    # Rate-limited/quota-exhausted: a MISSING review signal, distinct from a
    # real failure (rc=1) and from not-configured (rc=3). Surface a loud
    # retry-later note for a reader scanning the output, then the availability
    # line so the caller records unavailable (never ok - a rate-limited
    # reviewer never happened, and clear-cr-marker.sh gate 3 would otherwise
    # clear the marker on a review that did not run).
    echo "coderabbit pass rate-limited/quota-exhausted - retry later" >&2
    echo "panel-availability: coderabbit unavailable (rc=4)" >&2
    exit 4
fi
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "panel-availability: coderabbit unavailable (timeout ${CODERABBIT_TIMEOUT_SECS}s)" >&2
else
    echo "panel-availability: coderabbit unavailable (rc=$rc)" >&2
fi
exit 1
