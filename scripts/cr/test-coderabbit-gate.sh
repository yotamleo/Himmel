#!/usr/bin/env bash
# Smoke test for scripts/cr/coderabbit-gate.sh (HIMMEL-2226).
#
# Hermetic: builds a throwaway "fixture root" under mktemp that mirrors just
# enough of the real repo layout for coderabbit-gate.sh's own SCRIPT_DIR /
# HIMMEL_ROOT derivation to resolve INSIDE the fixture, not the real repo -
# scripts/cr/coderabbit-review.sh in that fixture is a STUB (STUB_RC /
# STUB_FINDINGS / STUB_AVAIL driven), never the real, rate-limited reviewer.
# The small git-config predicates it depends on (default_branch,
# cr_trigger_repo_armed, cr_app_configured, load_dotenv) are also fixture
# stand-ins, controlled by FIXTURE_ARMED / FIXTURE_CR_APP / CR_PROFILE - their
# own behaviour has its own test suites; this suite is scoped to
# coderabbit-gate.sh's own branching. Never touches the real $HOME, the real
# repo's scripts/lib/*, or any network.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/coderabbit-gate.sh"

fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: $3 - got '$1' want '$2'"; fail=1; }; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

tmp="$(mktemp -d -t coderabbit-gate.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT

# --- fixture root: coderabbit-gate.sh's OWN HIMMEL_ROOT resolves here -------
build_fixture_root() {
    local root="$1"
    mkdir -p "$root/scripts/cr" "$root/scripts/guardrails" "$root/scripts/lib"
    cp "$SCRIPT" "$root/scripts/cr/coderabbit-gate.sh"
    chmod +x "$root/scripts/cr/coderabbit-gate.sh"

    # Stubbed CodeRabbit reviewer - the ONLY component under test that would
    # otherwise cost a real, rate-limited call. Records that it ran (marker
    # file) so tests can assert conserved/skipped/CR_PROFILE=none paths never
    # invoke it.
    cat > "$root/scripts/cr/coderabbit-review.sh" <<'STUBEOF'
#!/usr/bin/env bash
: > "${STUB_MARKER:?}"
[ -n "${STUB_FINDINGS:-}" ] && printf '%s\n' "$STUB_FINDINGS"
[ -n "${STUB_AVAIL:-}" ] && printf '%s\n' "$STUB_AVAIL" >&2
[ -n "${STUB_STDERR:-}" ] && printf '%s\n' "$STUB_STDERR" >&2
exit "${STUB_RC:-0}"
STUBEOF
    chmod +x "$root/scripts/cr/coderabbit-review.sh"

    cat > "$root/scripts/guardrails/lib.sh" <<'EOF'
default_branch() { echo main; }
EOF

    cat > "$root/scripts/lib/load-dotenv.sh" <<'EOF'
_load_dotenv_primary_for() { printf '%s\n' "$1"; }
load_dotenv() { return 0; }
EOF

    cat > "$root/scripts/lib/nwo.sh" <<'EOF'
_cmg_local_nwo() { printf 'github.com/fixture/repo\n'; return 0; }
_cmg_canon_nwo() { _CMG_CANON="github.com/fixture/repo"; return 0; }
EOF

    cat > "$root/scripts/lib/cr-trigger-ledger.sh" <<'EOF'
cr_trigger_repo_armed() { [ "${FIXTURE_ARMED:-0}" = "1" ]; }
EOF

    cat > "$root/scripts/lib/cr-available.sh" <<'EOF'
cr_app_configured() { [ "${FIXTURE_CR_APP:-0}" = "1" ]; }
EOF
}

# --- fixture git repo, checked out on branch "work" (the name every case below
# passes as the captured --branch, which is also what scopes the scratch
# file) ----------------------------------------------------------------------
make_repo() {
    local d="$1"
    mkdir -p "$d"
    (
        cd "$d" || exit 1
        git init -q -b work .
        git config user.email t@t
        git config user.name t
        git config commit.gpgsign false
        git commit -q --allow-empty -m init
        git commit -q --allow-empty -m second
    )
}

gitdir_of() { (cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd); }

write_verdicts() {
    # $1 = repo dir, $2... = verdict lines
    local d="$1" gitdir; shift
    gitdir="$(gitdir_of "$d")"
    mkdir -p "$gitdir/cr-prior-blocking"
    printf '%s\n' "$@" > "$gitdir/cr-prior-blocking/work"
}

# run_gate <repo-dir> <root-dir> -- runs coderabbit-gate.sh from repo-dir with
# HIMMEL_ROOT=root-dir, capturing stdout/stderr/rc separately.
run_gate() {
    local d="$1" root="$2"; shift 2
    ( cd "$d" && bash "$root/scripts/cr/coderabbit-gate.sh" "$@" >"$tmp/out" 2>"$tmp/err" )
    echo $?
}

root="$tmp/root"; build_fixture_root "$root"
repo="$tmp/repo"; make_repo "$repo"
export STUB_MARKER="$tmp/stub-ran"

# HIMMEL-2542: the gate now REFUSES a --head/--base-sha that names no commit in
# the repo it runs in, so every case below pins to the fixture repo's own two
# commits. They are deliberately DIFFERENT commits, so a case that swapped the
# two pins would still be reviewing a real range - the check under test is
# "resolves to a commit here", and a same-SHA pair would make an accidental
# pass indistinguishable from a real one for the T12 cases below.
head_sha="$(git -C "$repo" rev-parse work)"
base_sha="$(git -C "$repo" rev-parse 'work^')"
if [ -z "$head_sha" ] || [ -z "$base_sha" ]; then
    echo "FAIL: fixture repo produced no commit SHAs for the gate's --head/--base-sha pins"
    exit 1
fi
# A well-formed 40-hex value that names no object in this repo - the exact
# shape the ticket was filed on (a short hash expanded by hand).
unresolvable_sha="0000000000000000000000000000000000000000"

reset_env() {
    rm -f "$STUB_MARKER"
    unset CR_PROFILE FIXTURE_ARMED FIXTURE_CR_APP STUB_RC STUB_FINDINGS STUB_AVAIL STUB_STDERR 2>/dev/null || true
}

# =============================================================================
# T1: all verdicts disproved -> count 0 -> CodeRabbit RUNS.
reset_env
write_verdicts "$repo" "VERDICT [x-1] = disproved"
export FIXTURE_ARMED=1 STUB_RC=0 STUB_FINDINGS="finding: something" STUB_AVAIL="panel-availability: coderabbit ok"
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$base_sha")"
check "$rc" "0" "T1 rc"
[ -f "$STUB_MARKER" ] || { echo "FAIL: T1 stub did not run"; fail=1; }
contains "$(cat "$tmp/out")" "finding: something" || { echo "FAIL: T1 findings not on stdout"; fail=1; }
contains "$(cat "$tmp/err")" "panel-availability: coderabbit ok" || { echo "FAIL: T1 avail line not on stderr"; fail=1; }

# T2: one 'agreed' verdict -> CONSERVED, conserved avail line on stderr, no
# CodeRabbit invocation.
reset_env
write_verdicts "$repo" "VERDICT [x-1] = agreed"
export FIXTURE_ARMED=1
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$base_sha")"
check "$rc" "0" "T2 rc"
[ -f "$STUB_MARKER" ] && { echo "FAIL: T2 stub ran but should have been conserved"; fail=1; }
contains "$(cat "$tmp/err")" "coderabbit pass CONSERVED" || { echo "FAIL: T2 missing CONSERVED message"; fail=1; }
contains "$(cat "$tmp/err")" "panel-availability: coderabbit unavailable (conserved) reason=conserved" || { echo "FAIL: T2 missing conserved avail line"; fail=1; }
check "$(cat "$tmp/out")" "" "T2 stdout empty"

# T3: {disproved, unaddressed} for the SAME id -> BLOCKS -> CONSERVED (fail-
# closed direction round 5 fixed).
reset_env
write_verdicts "$repo" "VERDICT [x-1] = disproved" "VERDICT [x-1] = unaddressed"
export FIXTURE_ARMED=1
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$base_sha")"
check "$rc" "0" "T3 rc"
[ -f "$STUB_MARKER" ] && { echo "FAIL: T3 stub ran but {disproved,unaddressed} must BLOCK"; fail=1; }
contains "$(cat "$tmp/err")" "coderabbit pass CONSERVED" || { echo "FAIL: T3 missing CONSERVED message (fail-closed direction)"; fail=1; }
contains "$(cat "$tmp/err")" "left 1 surviving" || { echo "FAIL: T3 derived count is not 1"; fail=1; }

# T4a: missing verdicts file -> fail-open, RUNS, UNKNOWN message.
reset_env
rm -f "$(gitdir_of "$repo")/cr-prior-blocking/work"
export FIXTURE_ARMED=1 STUB_RC=0
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$base_sha")"
check "$rc" "0" "T4a rc"
[ -f "$STUB_MARKER" ] || { echo "FAIL: T4a stub did not run (missing file must fail-open)"; fail=1; }
contains "$(cat "$tmp/err")" "prior-blocking signal UNKNOWN" || { echo "FAIL: T4a missing UNKNOWN message"; fail=1; }

# T4b: garbage/non-numeric-content verdicts file (no VERDICT lines at all) ->
# the awk script's END block always emits a plain digit count ("n + 0"), so
# this lands as prior_count="0" via the SAME normal numeric branch a real
# zero-blocker verdicts file takes (not the UNKNOWN branch) -> still
# fail-open, still RUNS. (An actually-unreadable file -- chmod'd unreadable,
# or a directory in the file's place -- was tried here too, to drive the
# `|| echo ""` catch and its UNKNOWN message the way a missing file does in
# T4a; on this platform's bundled Git-for-Windows awk neither reliably fails
# to open, so that specific sub-case is not reproducible here and is not
# asserted. T4a already exercises the UNKNOWN-message code path via a
# genuinely missing file.)
reset_env
write_verdicts "$repo" "not a verdict line at all" "garbage garbage"
export FIXTURE_ARMED=1 STUB_RC=0
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$base_sha")"
check "$rc" "0" "T4b rc"
[ -f "$STUB_MARKER" ] || { echo "FAIL: T4b stub did not run (garbage-content file must fail-open, count 0)"; fail=1; }

# T5: CR_PROFILE=none -> skipped entirely, no invocation.
reset_env
write_verdicts "$repo" "VERDICT [x-1] = agreed"
export FIXTURE_ARMED=1 CR_PROFILE=none
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$base_sha")"
check "$rc" "0" "T5 rc"
[ -f "$STUB_MARKER" ] && { echo "FAIL: T5 stub ran under CR_PROFILE=none"; fail=1; }
check "$(cat "$tmp/out")" "" "T5 stdout empty"
check "$(cat "$tmp/err")" "" "T5 stderr empty (CR_PROFILE=none skips silently)"

# T6: unarmed repo -> HIMMEL-2034/2035 skip message, no invocation.
reset_env
write_verdicts "$repo" "VERDICT [x-1] = disproved"
export FIXTURE_ARMED=0
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$base_sha")"
check "$rc" "0" "T6 rc"
[ -f "$STUB_MARKER" ] && { echo "FAIL: T6 stub ran on an unarmed repo"; fail=1; }
contains "$(cat "$tmp/err")" "coderabbit=unarmed" || { echo "FAIL: T6 missing unarmed message"; fail=1; }
contains "$(cat "$tmp/err")" "HIMMEL-2034/2035" || { echo "FAIL: T6 missing HIMMEL-2034/2035 reference"; fail=1; }

# T7: stubbed reviewer exit 5 -> script exits 5 with the ABORT block, AND the
# reviewer's own stderr is relayed. Two distinct causes share rc=5 (a pin
# mismatch and a setup failure that would silently degrade the refusal or the
# output); the reviewer's REFUSING line is the ONLY place the specific one
# appears. This branch used to `rm -f` the capture file without printing it,
# so an operator hitting a mktemp failure read "the checkout moved" and
# re-ran /pr-check for a checkout that had not moved (HIMMEL-2321 CR).
reset_env
write_verdicts "$repo" "VERDICT [x-1] = disproved"
export FIXTURE_ARMED=1 STUB_RC=5
export STUB_STDERR="coderabbit-review: REFUSING - cannot create the stdout capture file (mktemp failed), so review output could not be safely relayed (HIMMEL-2321)"
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$base_sha")"
check "$rc" "5" "T7 rc"
[ -f "$STUB_MARKER" ] || { echo "FAIL: T7 stub did not run"; fail=1; }
contains "$(cat "$tmp/err")" "ABORT - coderabbit-review.sh exit 5" || { echo "FAIL: T7 missing ABORT block"; fail=1; }
contains "$(cat "$tmp/err")" "cannot create the stdout capture file" \
    || { echo "FAIL: T7 the reviewer's REFUSING line was not relayed - the operator cannot tell which rc=5 cause fired"; fail=1; }

# T8: stubbed reviewer exit 4 -> unavailable recorded, not clean.
reset_env
write_verdicts "$repo" "VERDICT [x-1] = disproved"
export FIXTURE_ARMED=1 STUB_RC=4
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$base_sha")"
check "$rc" "0" "T8 rc"
[ -f "$STUB_MARKER" ] || { echo "FAIL: T8 stub did not run"; fail=1; }
contains "$(cat "$tmp/err")" "RATE-LIMITED" || { echo "FAIL: T8 missing RATE-LIMITED message"; fail=1; }
contains "$(cat "$tmp/err")" "NOT clean" || { echo "FAIL: T8 missing 'NOT clean' framing"; fail=1; }

# T9: missing --head / --branch / --base-sha -> exit 2.
reset_env
rc="$(run_gate "$repo" "$root" --branch work --base-sha "$base_sha")"
check "$rc" "2" "T9a rc (missing --head)"
rc="$(run_gate "$repo" "$root" --head "$head_sha" --base-sha "$base_sha")"
check "$rc" "2" "T9b rc (missing --branch)"
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work)"
check "$rc" "2" "T9c rc (missing --base-sha)"

# T10: the conservation scratch file is scoped to the CAPTURED --branch, not
# the live checkout (HIMMEL-1175 as amended by HIMMEL-2226). Phase A writes
# cr-prior-blocking/<captured branch>, so a run invoked with a DIFFERENT
# --branch must not be conserved by branch "work"'s surviving blockers - the
# repo stays checked out on "work" throughout, which is exactly the mid-run
# same-SHA branch switch the SHA pins cannot catch.
reset_env
write_verdicts "$repo" "VERDICT [x-1] = agreed"
export FIXTURE_ARMED=1 STUB_RC=0
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch other --base-sha "$base_sha")"
check "$rc" "0" "T10 rc"
[ -f "$STUB_MARKER" ] || { echo "FAIL: T10 branch work's blockers conserved a --branch other run"; fail=1; }
contains "$(cat "$tmp/err")" "coderabbit pass CONSERVED" && { echo "FAIL: T10 CONSERVED on another branch's verdicts"; fail=1; }

# T10b: and the same-branch case still conserves (T10 must not pass by simply
# never reading the file).
reset_env
write_verdicts "$repo" "VERDICT [x-1] = agreed"
export FIXTURE_ARMED=1 STUB_RC=0
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$base_sha")"
check "$rc" "0" "T10b rc"
[ -f "$STUB_MARKER" ] && { echo "FAIL: T10b stub ran; the captured branch's own blocker must conserve"; fail=1; }
contains "$(cat "$tmp/err")" "coderabbit pass CONSERVED" || { echo "FAIL: T10b missing CONSERVED message"; fail=1; }

# T11: HIMMEL-2375 — all verdicts `deferred` (with a ticket) -> count 0 ->
# CodeRabbit RUNS. deferred is a REAL, tracked finding (dispositioned onto
# another ticket via the CR ledger's own `deferred` verdict, an unaffected,
# separate mechanism) but must never conserve, or an all-deferred round could
# never let CodeRabbit run again — the panel re-raises the same deferred
# residuals every round, livelocking the branch at 0 CodeRabbit calls
# forever.
reset_env
write_verdicts "$repo" "VERDICT [x-1] = deferred -> HIMMEL-1" "VERDICT [x-2] = deferred -> HIMMEL-2"
export FIXTURE_ARMED=1 STUB_RC=0 STUB_FINDINGS="finding: something" STUB_AVAIL="panel-availability: coderabbit ok"
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$base_sha")"
check "$rc" "0" "T11 rc"
[ -f "$STUB_MARKER" ] || { echo "FAIL: T11 stub did not run (all-deferred round must not conserve)"; fail=1; }
contains "$(cat "$tmp/out")" "finding: something" || { echo "FAIL: T11 findings not on stdout"; fail=1; }

# T12a: HIMMEL-2542 — an unresolvable --head ABORTs at the gate's documented
# exit 5, naming the ARGUMENT, and the scarce reviewer is never spent on it.
# The repo is ARMED and the verdicts are all-disproved here, i.e. every other
# condition says "RUN CodeRabbit" — so the refusal can only come from the pin.
reset_env
write_verdicts "$repo" "VERDICT [x-1] = disproved"
export FIXTURE_ARMED=1 STUB_RC=0
rc="$(run_gate "$repo" "$root" --head "$unresolvable_sha" --branch work --base-sha "$base_sha")"
check "$rc" "5" "T12a rc (unresolvable --head aborts at 5)"
[ -f "$STUB_MARKER" ] && { echo "FAIL: T12a CodeRabbit was called on an unresolvable --head"; fail=1; }
check "$(cat "$tmp/out")" "" "T12a stdout empty"
contains "$(cat "$tmp/err")" "--head $unresolvable_sha does not resolve to a commit in this repo" \
    || { echo "FAIL: T12a ABORT does not name the --head argument"; fail=1; }

# T12b: the same for --base-sha, the other caller-supplied pin. A --head-only
# check would pass T12a while leaving this hole open.
reset_env
write_verdicts "$repo" "VERDICT [x-1] = disproved"
export FIXTURE_ARMED=1 STUB_RC=0
rc="$(run_gate "$repo" "$root" --head "$head_sha" --branch work --base-sha "$unresolvable_sha")"
check "$rc" "5" "T12b rc (unresolvable --base-sha aborts at 5)"
[ -f "$STUB_MARKER" ] && { echo "FAIL: T12b CodeRabbit was called on an unresolvable --base-sha"; fail=1; }
contains "$(cat "$tmp/err")" "--base-sha $unresolvable_sha does not resolve to a commit in this repo" \
    || { echo "FAIL: T12b ABORT does not name the --base-sha argument"; fail=1; }

# T12c: NEGATIVE CONTROL (HIMMEL-2518 control contract). A mutant with both
# T12 guards deleted must RUN, PRODUCE a value, and produce the SPECIFIC wrong
# value — exit 0 with the reviewer actually CALLED on a pin that names nothing.
# Each property has its own failure message, so a mutant that merely crashed
# can never be mistaken for a reproduced defect. The mutant lives inside the
# fixture root: the gate resolves coderabbit-review.sh from its own
# SCRIPT_DIR/../.., and a mutant written elsewhere would reach the REAL,
# rate-limited reviewer.
mutant="$root/scripts/cr/coderabbit-gate.mutant.sh"
awk '
    index($0, "git rev-parse --verify --quiet") { drop = 1 }
    drop && $0 == "fi" { drop = 0; next }
    !drop { print }
' "$root/scripts/cr/coderabbit-gate.sh" > "$mutant"
if cmp -s "$root/scripts/cr/coderabbit-gate.sh" "$mutant"; then
    echo "FAIL: T12c control is VACUOUS - the guard-deleting mutation matched nothing, so the mutant IS the fixed script"; fail=1
elif grep -q 'does not resolve to a commit in this repo' "$mutant"; then
    echo "FAIL: T12c control is VACUOUS - the mutant still carries a guard's ABORT message"; fail=1
else
    reset_env
    write_verdicts "$repo" "VERDICT [x-1] = disproved"
    export FIXTURE_ARMED=1 STUB_RC=0 STUB_FINDINGS="finding: something"
    mutant_rc=0
    ( cd "$repo" && bash "$mutant" --head "$unresolvable_sha" --branch work --base-sha "$unresolvable_sha" \
        >"$tmp/out" 2>"$tmp/err" ) || mutant_rc=$?
    # (a) the SPECIFIC wrong value, not merely "different from 5".
    check "$mutant_rc" "0" "T12c control reproduces the exact defect (exit 0 on unresolvable pins)"
    # (b) it RAN and produced a value: the reviewer was reached and spent.
    [ -f "$STUB_MARKER" ] || { echo "FAIL: T12c control never reached the reviewer - it proves nothing about the guard"; fail=1; }
    contains "$(cat "$tmp/out")" "finding: something" \
        || { echo "FAIL: T12c control produced no findings - it did not run far enough to reproduce the defect"; fail=1; }
fi
reset_env

[ "$fail" -eq 0 ] && echo "PASS test-coderabbit-gate" || exit 1
