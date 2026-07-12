#!/usr/bin/env bash
# scripts/cr/coderabbit-review.sh - CodeRabbit CLI finding pass for /pr-check (HIMMEL-926).
#
# Runs `coderabbit review` over the current branch's COMMITTED diff vs the base
# branch and prints the findings on stdout, so /pr-check can merge them as
# [coderabbit-N] blocking candidates (same merge contract as the codex
# adversarial pass, step 3.1). Availability-gated + fail-open: a missing CLI,
# a dead WSL, a timeout, or a CodeRabbit error never blocks the gate - the
# caller degrades to the remaining critics.
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
# line - a machine without the CLI is not a critic drop-out).
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
Exit: 0 review completed; 1 review failed (fail-open); 2 usage; 3 CLI absent.
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
[ "$op_to" -gt 0 ] || op_to=1
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
if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$to" "$bin" review --agent --type committed --base "$base"
else
    "$bin" review --agent --type committed --base "$base"
fi'

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
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "panel-availability: coderabbit unavailable (timeout ${CODERABBIT_TIMEOUT_SECS}s)" >&2
else
    echo "panel-availability: coderabbit unavailable (rc=$rc)" >&2
fi
exit 1
