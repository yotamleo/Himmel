#!/usr/bin/env bash
# Hidden acceptance test for task shell-red-green (HIMMEL-4090).
# Usage: accept.sh <worktree> <fixture-sha>
# bash -c bodies take their values as positional args, so single quotes are right.
# shellcheck disable=SC2016
set -u
. "$(dirname "$0")/../accept-common.sh"
WT="$1"
S="$WT/lq-work/semver-cmp.sh"
T="$WT/lq-work/test-semver-cmp.sh"

cmp_out() { bash "$S" "$1" "$2" 2>/dev/null; }

accept_ok script-exists test -f "$S"
accept_eq equal 0 "$(cmp_out 1.2.3 1.2.3)"
accept_eq patch-older -1 "$(cmp_out 1.2.3 1.2.4)"
accept_eq numeric-minor 1 "$(cmp_out 1.10.0 1.9.9)"
accept_eq numeric-major -1 "$(cmp_out 2.0.0 10.0.0)"
accept_eq patch-newer 1 "$(cmp_out 0.0.1 0.0.0)"
accept_rc ok-exit 0 bash "$S" 3.4.5 3.4.5
accept_rc two-parts 64 bash "$S" 1.2 1.2.3
accept_rc v-prefix 64 bash "$S" v1.2.3 1.2.3
accept_rc non-digit 64 bash "$S" 1.2.3 1.2.x
accept_rc one-arg 64 bash "$S" 1.2.3
accept_rc suffix 64 bash "$S" 1.2.3-rc1 1.2.3

# The candidate's own test must pass against its own script.
accept_ok own-test-passes bash -c 'cd "$1" && bash lq-work/test-semver-cmp.sh' _ "$WT"

# Test quality: the candidate's test must FAIL against a stub that always
# answers 0 (a test that cannot fail is not evidence).
MUT="$(mktemp -d "${TMPDIR:-/tmp}/lq-mut.XXXXXX")" || { echo "accept: mktemp failed" >&2; exit 1; }
if [ -f "$T" ]; then cp -R "$WT/lq-work" "$MUT/"; fi
printf '#!/usr/bin/env bash\necho 0\n' > "$MUT/lq-work/semver-cmp.sh" 2>/dev/null
accept_ok own-test-catches-stub bash -c 'cd "$1" && [ -f lq-work/test-semver-cmp.sh ] && ! bash lq-work/test-semver-cmp.sh' _ "$MUT"
rm -rf "$MUT"

accept_done
