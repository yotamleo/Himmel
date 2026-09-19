#!/usr/bin/env bash
# scripts/upstream/run-target-tests.sh — run an upstream target's tests under a
# throwaway HERMES_HOME (HIMMEL-3053).
#
# /upstream-file builds and tests inside a clone of the target (hermes-agent at
# least). A test run there inherits this shell's live HERMES_HOME (e.g.
# ~/.hermes) and can write live runtime state into it — a stale
# gateway_state.json from a pytest run once read as a "detached" gateway and
# misled a migration diagnosis. This wrapper is the isolation, so it does not
# depend on the invoker remembering prose.
#
# Usage: run-target-tests.sh [--cwd <dir>] [--] <test-cmd> [args...]
#
#   1. Creates HERMES_HOME=$(mktemp -d) and removes it on exit (also on
#      INT/TERM).
#   2. Scrubs EVERY inherited HERMES_* variable before setting the fresh
#      HERMES_HOME — the hermes source honours dozens (HERMES_PROFILE,
#      HERMES_KANBAN_DB, HERMES_MANAGED_DIR, HERMES_SESSION_*, ...), and any of
#      them can steer state back at the live install. Prefix-scrub, not a
#      hand-kept list, so a variable added upstream is covered unasked.
#   3. REFUSES (rc=2, loud) if the sandbox would equal or sit inside the
#      caller's live home — HERMES_HOME as inherited, or the platform default
#      $HOME/.hermes — e.g. TMPDIR pointed into it. The check runs before the
#      target starts, and the half-made sandbox is removed.
#
# HOME is deliberately NOT redirected: hermes' own conftest documents that
# redirecting it breaks the target's subprocesses. A caller that must
# also shield credentials outside HERMES_* still passes its own `env -u`.
# ponytail: only HERMES_* is scrubbed; provider/bot credentials named without
# that prefix (TELEGRAM_BOT_TOKEN, ...) are inherited as-is — the hermes test
# conftest blocklists those itself, this wrapper does not.
#
# Exit status: the target's own, 2 on usage error or refusal, 143/130 when
# TERMed/INTed mid-run.
set -uo pipefail

usage() {
    echo "usage: run-target-tests.sh [--cwd <dir>] [--] <test-cmd> [args...]" >&2
    exit 2
}

cwd=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cwd) [ $# -ge 2 ] || usage; cwd=$2; shift 2 ;;
        --) shift; break ;;
        -h|--help) usage ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || usage

# The caller's live homes, captured BEFORE the scrub below.
live_env=${HERMES_HOME:-}
live_default=${HOME:-}/.hermes

sandbox=""
# shellcheck disable=SC2329,SC2317  # invoked via traps
cleanup() {
    case "$sandbox" in
        */hermes-test-home.*) [ -d "$sandbox" ] && rm -rf "$sandbox" ;;
    esac
    return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

if [ -n "$cwd" ]; then
    cd "$cwd" || { echo "run-target-tests: cannot cd to '$cwd'" >&2; exit 2; }
fi

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/hermes-test-home.XXXXXX") \
    || { echo "run-target-tests: cannot create a temporary HERMES_HOME" >&2; exit 2; }

phys() { (cd "$1" 2>/dev/null && pwd -P); }
sb=$(phys "$sandbox") || sb=$sandbox

for live in "$live_env" "$live_default"; do
    [ -n "$live" ] || continue
    lp=$(phys "$live") || lp=${live%/}
    [ -n "$lp" ] || continue
    case "$sb/" in
        "$lp"/*)
            echo "run-target-tests: REFUSING — sandbox HERMES_HOME '$sb' would equal or sit inside the live hermes home '$lp'; the target would write live state. Fix TMPDIR/HERMES_HOME and re-run." >&2
            exit 2
            ;;
    esac
done

unset_args=()
while IFS= read -r name; do
    [ -n "$name" ] && unset_args+=(-u "$name")
done < <(env | sed -n 's/^\(HERMES_[A-Za-z0-9_]*\)=.*/\1/p')

echo "run-target-tests: HERMES_HOME=$sandbox (live home not inherited; $(( ${#unset_args[@]} / 2 )) inherited HERMES_* vars scrubbed)" >&2

env ${unset_args[@]+"${unset_args[@]}"} HERMES_HOME="$sandbox" "$@"
rc=$?
exit "$rc"
