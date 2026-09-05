#!/usr/bin/env bash
# Smoke test for scripts/lib/flow-run-ledger-path.sh (HIMMEL-2130).
# Usage: bash scripts/lib/test-flow-run-ledger-path.sh
# Exit 0 if all cases pass, 1 otherwise. Hermetic — HOME is redirected to a
# scratch dir for every case, so the real ~/.himmel/flow-runs.jsonl is never
# touched even when a case exercises the unset-override default path.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LEDGER_SH="$REPO_ROOT/scripts/lib/flow-run-ledger.sh"

[ -f "$LEDGER_SH" ] || { echo "FAIL: $LEDGER_SH not found"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/flow-ledger-path-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

echo "== HIMMEL_FLOW_RUNS_LEDGER override: --append-start writes there, not the default =="
scratch_home="$tmp/home"
override_ledger="$tmp/scratch-flow-runs.jsonl"
default_ledger="$scratch_home/.himmel/flow-runs.jsonl"
mkdir -p "$scratch_home"

HOME="$scratch_home" HIMMEL_FLOW_RUNS_LEDGER="$override_ledger" \
    bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247 >/dev/null

if [ -f "$override_ledger" ]; then
    pass "override path got the row"
else
    fail "override path missing: $override_ledger"
fi

if [ -f "$default_ledger" ]; then
    fail "default path was written despite override: $default_ledger"
else
    pass "default path untouched"
fi

echo
echo "== HIMMEL-2241 suite-marker quarantine =="
# The guard in flow_run_append: inside a shell-suite run (run-shell-tests.sh
# exports HIMMEL_SUITE_LOCK_HELD) a write with NO explicit override is a
# fixture that fell back to the production ledger -- quarantine it loudly.
q_home="$tmp/q-home"
q_tmp="$tmp/q-tmp"
mkdir -p "$q_home" "$q_tmp"
q_default="$q_home/.himmel/flow-runs.jsonl"
q_file="$q_tmp/flow-runs-unredirected.jsonl"

# POSITIVE control: marker set, no override -> quarantined, default untouched.
q_err="$tmp/q-err.txt"
env -u HIMMEL_FLOW_RUNS_LEDGER HOME="$q_home" TMPDIR="$q_tmp"     HIMMEL_SUITE_LOCK_HELD="$q_tmp/fake-suite-lock"     bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247     >/dev/null 2>"$q_err"

if [ -f "$q_file" ]; then
    pass "marker set + no override: row quarantined in TMPDIR"
else
    fail "marker set + no override: quarantine file missing: $q_file"
fi
if [ -f "$q_default" ]; then
    fail "marker set + no override: the default ledger was written anyway"
else
    pass "marker set + no override: default ledger untouched"
fi
if grep -q 'HIMMEL-2241 WARN' "$q_err"; then
    pass "quarantine warned on stderr"
else
    fail "quarantine was silent; stderr: $(cat "$q_err")"
fi

# NEGATIVE control: NO marker, no override -> the default path still wins.
# This is the "a genuine flow outside any suite is untouched" proof.
n_home="$tmp/n-home"
n_tmp="$tmp/n-tmp"
mkdir -p "$n_home" "$n_tmp"
n_default="$n_home/.himmel/flow-runs.jsonl"
env -u HIMMEL_FLOW_RUNS_LEDGER -u HIMMEL_SUITE_LOCK_HELD     HOME="$n_home" TMPDIR="$n_tmp"     bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247 >/dev/null

if [ -f "$n_default" ]; then
    pass "no marker + no override: default ledger still gets the row"
else
    fail "no marker + no override: default ledger missing: $n_default"
fi
if [ -f "$n_tmp/flow-runs-unredirected.jsonl" ]; then
    fail "no marker: quarantined a genuine non-suite write"
else
    pass "no marker: nothing quarantined"
fi

# An explicit override inside a suite still wins over the quarantine path.
o_tmp="$tmp/o-tmp"
mkdir -p "$o_tmp"
o_ledger="$tmp/o-ledger.jsonl"
env HOME="$q_home" TMPDIR="$o_tmp" HIMMEL_SUITE_LOCK_HELD="$o_tmp/fake-suite-lock"     HIMMEL_FLOW_RUNS_LEDGER="$o_ledger"     bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247 >/dev/null

if [ -f "$o_ledger" ]; then
    pass "marker set + override: the override still wins"
else
    fail "marker set + override: override path missing: $o_ledger"
fi
if [ -f "$o_tmp/flow-runs-unredirected.jsonl" ]; then
    fail "marker set + override: quarantined despite an explicit redirect"
else
    pass "marker set + override: nothing quarantined"
fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
