#!/usr/bin/env bash
# test-pr-check-run.sh -- orchestration-level invariants for /pr-check.
#
# ORIGIN AND RETARGET (HIMMEL-1944 -> HIMMEL-2226). This suite began as the S0
# acceptance net for a planned `scripts/cr/pr-check-run.sh --phase <name>`
# runner. It pinned the invariants `.claude/commands/pr-check.md` asserted in
# PROSE -- lifting the HIMMEL-1219 awk block out of the runbook at runtime and
# testing that re-derivation -- and it stubbed, behind a `--selftest` seam, the
# phases that did not exist yet.
#
# That plan never landed and is now superseded. HIMMEL-2226 extracted every
# substantive /pr-check fence into REAL scripts under scripts/cr/ (one per
# phase, each with its own suite), because `CLAUDE_PROJECT_DIR` is unset in
# Bash-tool shells and Claude Code's worktree-isolation guard refuses most of
# the shapes those fences used. `pr-check-run.sh` does not exist and is not
# coming; the runbook no longer carries an awk block to lift. So this suite now
# drives the real scripts and asserts their OBSERVABLE behaviour.
#
# Five invariants, all real cases -- no stubs, no skips, nothing lifted:
#   1  fail-closed on attempted-but-failed lanes   -> clear-cr-marker.sh
#   3  zero responders refuses                     -> clear-cr-marker.sh
#   4  the HIMMEL-1219 conservation gate           -> coderabbit-gate.sh
#   5  marker-clear authority is a chokepoint      -> structural scan
#   7  ledger single-writer                        -> structural scan
#
# RETIRED WITH THE PHASE RUNNER (deleted deliberately, recorded here so the
# next reader does not "restore" a case whose premise is gone):
#   2  "unparseable Critical/Important counts never default to 0" needed the
#      candidates schema `--phase find` was to define. No `find` phase exists.
#      Its surviving half -- an unreadable prior-blocking signal must never
#      read as a fabricated 0 -- IS asserted, against the real implementation,
#      by invariant 4's missing-file scenario below.
#   6  the Claude-only review floor (HIMMEL-1224) at the ORCHESTRATION level.
#      It has no executable home: the enforcing half is clear-cr-marker.sh
#      gate 3 (covered by scripts/cr/test-clear-cr-marker.sh), and the
#      orchestration half is the runbook's step-4.5 instruction to record
#      `avail --model claude --status ok` -- an instruction to the agent, not
#      code any script runs. HIMMEL-2226 extracted fences, not agent judgment,
#      so nothing new became testable. A stub that skips forever asserts
#      nothing; this comment is the honest replacement.
#
# RETARGETED, NOT RETIRED:
#   7  "ledger single-writer" was scoped to a `record` phase that does not
#      exist, so the ORIGINAL wiring was unrunnable -- but the predicate holds
#      against the real codebase and is now asserted there (case_inv7 below).
#      The other scripts that name the ledger (clear-cr-marker.sh,
#      critic-panel.sh, cr-scores.sh, cr-tune.sh, known-findings.sh,
#      cr-pending-audit.sh) READ it, or shell out to ledger-append.sh -- which
#      is evidence FOR the chokepoint, not against it.
#
# Each case runs in its own re-exec'd child (`--run-case <name>`) under
# `timeout`, so a hang fails loudly instead of burning wall clock unbounded
# (HIMMEL-1953: scripts/test-check-ci.sh has no such bound and that has cost
# real time). Child exit codes: 0 pass, anything else (incl. a
# `timeout`-imposed 124/137) fail.
set -uo pipefail

# An operator's shell (or an --automerge-armed launcher) must never decide a
# result here. CR_PROFILE joins the list for invariant 4: `CR_PROFILE=none`
# skips the CodeRabbit pass outright, which would make every conserve/run
# assertion below pass for the wrong reason.
unset ARMAUTOMERGE CR_MERGE_GATE_OK CR_REQUIRE_CROSS_MODEL SKIP_CR CR_PROFILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLEAR="$SCRIPT_DIR/clear-cr-marker.sh"
GATE="$SCRIPT_DIR/coderabbit-gate.sh"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"

# ---------------------------------------------------------------------------
# Fixture helpers -- the scripts/cr/test-clear-cr-marker.sh pattern (its
# helper block, roughly lines 28-175), reused rather than reinvented.
# clear-cr-marker.sh has NO env seams for the ledger/gh (gate integrity), so
# each case builds a REAL temp git repo, copies the script into it, and
# writes the ledger/marker at the fixed paths under the temp repo's own
# .git. `tmp`/`sha` are set as plain variables (not echoed for `read`) since
# a spaced TMPDIR would corrupt a whitespace-split read on Windows Git Bash.
# ---------------------------------------------------------------------------

# make_repo -- a temp git repo with one commit on branch `feat/x`, pushed to a
# real bare `origin`, with a copy of clear-cr-marker.sh under scripts/cr/.
make_repo() {
    tmp=$(fixture_mktemp_dir) || return 1
    (
        fixture_enter_git_init_dir "$tmp" || exit 1
        git init -q -b main .
        git config user.email t@t.t; git config user.name t
        echo hi > f.txt
        git add f.txt
        git commit -qm "base"
        git checkout -qb feat/x
        echo more >> f.txt
        git commit -qam "work"
        git init -q --bare .git/test-origin.git
        git remote add origin .git/test-origin.git
        git push -q -u origin feat/x
    ) >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
    sha=$(git -C "$tmp" rev-parse --verify refs/heads/feat/x) || { rm -rf "$tmp"; return 1; }
    [ -n "$sha" ] || { rm -rf "$tmp"; return 1; }
    mkdir -p "$tmp/scripts/cr"
    cp "$CLEAR" "$tmp/scripts/cr/clear-cr-marker.sh" || { rm -rf "$tmp"; return 1; }
}

# write_marker <tmp> <sha> [lane] [endpoint] [base] -- the 7-field HIMMEL-1540
# bound format.
write_marker() {
    local tmp="$1" sha="$2" lane="${3:-full}" endpoint="${4:-.git/test-origin.git}" base="${5:-}"
    if [ -z "$base" ]; then
        base=$(git -C "$tmp" rev-parse --verify refs/heads/main 2>/dev/null || echo deadbeef)
    fi
    mkdir -p "$tmp/.git/cr-pending/feat"
    printf '2026-07-16T10:00:00+02:00 | %s | %s | origin | refs/heads/feat/x | %s | %s\n' "$sha" "$lane" "$endpoint" "$base" > "$tmp/.git/cr-pending/feat/x"
}

# write_ledger <tmp> [jsonl-lines...] -- truncates then writes.
write_ledger() {
    local tmp="$1"; shift
    : > "$tmp/.git/cr-critic-scores.jsonl"
    local l
    for l in "$@"; do printf '%s\n' "$l" >> "$tmp/.git/cr-critic-scores.jsonl"; done
}

# avail_bad <sha> -- a lane that RAN and FAILED: status=unavailable, never ok.
avail_bad() { printf '{"kind":"avail","head":"%s","model":"coderabbit","status":"unavailable"}' "$1"; }

marker_path() { printf '%s/.git/cr-pending/feat/x' "$1"; }

# ---------------------------------------------------------------------------
# Real cases
# ---------------------------------------------------------------------------

# Invariant 1 -- fail-closed on attempted-but-failed lanes. A lane that RAN and
# failed records `unavailable`, never `ok`. As the sole evidence at HEAD the
# gate must stay CLOSED (exit 14) and never fall through to a reviewless clear.
case_inv1() {
    local tmp sha rc=0 out mp
    if ! make_repo; then
        echo "FAIL: invariant1 -- fixture repo setup failed" >&2
        return 1
    fi
    mp=$(marker_path "$tmp")
    write_marker "$tmp" "$sha"
    write_ledger "$tmp" "$(avail_bad "$sha")"
    out=$(cd "$tmp" && bash "$tmp/scripts/cr/clear-cr-marker.sh" 2>&1) || rc=$?
    if [ "$rc" -ne 14 ]; then
        echo "FAIL: invariant1 -- expected exit 14 (fail-closed; sole evidence is status=unavailable), got $rc: $out" >&2
        rm -rf "$tmp"
        return 1
    fi
    if [ ! -f "$mp" ]; then
        echo "FAIL: invariant1 -- marker was removed despite the fail-closed refusal" >&2
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    echo "PASS: invariant1 (fail-closed on attempted-but-failed lanes -- sole evidence status=unavailable => exit 14, marker intact)"
    return 0
}

# Invariant 3 -- zero responders refuses. No critic responded is a MISSING
# signal, not a clean one. A present-but-empty ledger at HEAD => exit 14.
case_inv3() {
    local tmp sha rc=0 out mp
    if ! make_repo; then
        echo "FAIL: invariant3 -- fixture repo setup failed" >&2
        return 1
    fi
    mp=$(marker_path "$tmp")
    write_marker "$tmp" "$sha"
    write_ledger "$tmp"
    out=$(cd "$tmp" && bash "$tmp/scripts/cr/clear-cr-marker.sh" 2>&1) || rc=$?
    if [ "$rc" -ne 14 ]; then
        echo "FAIL: invariant3 -- expected exit 14 (present-but-empty ledger, zero responders), got $rc: $out" >&2
        rm -rf "$tmp"
        return 1
    fi
    if [ ! -f "$mp" ]; then
        echo "FAIL: invariant3 -- marker was removed despite zero responders" >&2
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    echo "PASS: invariant3 (zero responders refuses -- present-but-empty ledger => exit 14, marker intact)"
    return 0
}

# ---------------------------------------------------------------------------
# Invariant 4 -- the HIMMEL-1219 conservation gate, driven against its real
# implementation: scripts/cr/coderabbit-gate.sh (HIMMEL-2226 phase B).
#
# THE REVIEWER IS STUBBED AT ITS BOUNDARY, AND MUST STAY THAT WAY. CodeRabbit
# is the rate-limited scarce lane; a test that reaches the real CLI spends the
# operator's quota. coderabbit-gate.sh resolves its own HIMMEL_ROOT from the
# location of the copy being run, so the fixture below is a throwaway root
# whose scripts/cr/coderabbit-review.sh is a marker-writing stub -- no
# test-only env seam is added to the production script (a seam in a gate is a
# bypass). The other collaborators it sources (default_branch, load_dotenv,
# the nwo / armed predicates) are fixture stand-ins with their own suites;
# this case is scoped to the conserve-or-run DERIVATION.
#
# What is asserted here that scripts/cr/test-coderabbit-gate.sh does not
# already assert: the `conflict` and `unaddressed` verdict values, a disproved
# id not masking a surviving one, the multi-id COUNT (two surviving => "left 2
# surviving", not merely "conserved"), and a genuinely EMPTY verdicts file
# deriving a real 0 rather than the UNKNOWN fail-open. That sibling covers the
# all-disproved, single-agreed, {disproved,unaddressed}, missing-file and
# rc/usage branches; the overlap is kept because the scenarios below only mean
# something as a set -- the exclusion rule is one rule, and half a truth table
# does not pin it.
# ---------------------------------------------------------------------------

GATE_ROOT=""
GATE_REPO=""
GATE_MARKER=""
GATE_OUT=""
GATE_ERR=""
# HIMMEL-2542: coderabbit-gate.sh now verifies that --head/--base-sha name real
# commits in the repo it runs in, so these scenarios pin to the fixture repo's
# own commit instead of the placeholder strings they used before.
GATE_SHA=""
PRIOR_OK=1

fail_prior() { echo "FAIL: invariant4 $1" >&2; PRIOR_OK=0; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# build_gate_fixture <root> -- the throwaway himmel root coderabbit-gate.sh's
# own SCRIPT_DIR/HIMMEL_ROOT derivation resolves into.
build_gate_fixture() {
    local root="$1"
    mkdir -p "$root/scripts/cr" "$root/scripts/guardrails" "$root/scripts/lib" || return 1
    cp "$GATE" "$root/scripts/cr/coderabbit-gate.sh" || return 1

    # The ONLY component under test that would otherwise cost a real,
    # rate-limited CodeRabbit call. Writes STUB_MARKER so a case can assert
    # the conserved path never invoked it.
    cat > "$root/scripts/cr/coderabbit-review.sh" <<'STUB_REVIEWER' || return 1
#!/usr/bin/env bash
: > "${STUB_MARKER:?}"
exit 0
STUB_REVIEWER

    cat > "$root/scripts/guardrails/lib.sh" <<'STUB_GUARDRAILS' || return 1
default_branch() { echo main; }
STUB_GUARDRAILS

    cat > "$root/scripts/lib/load-dotenv.sh" <<'STUB_DOTENV' || return 1
_load_dotenv_primary_for() { echo "$1"; }
load_dotenv() { return 0; }
STUB_DOTENV

    cat > "$root/scripts/lib/nwo.sh" <<'STUB_NWO' || return 1
_cmg_local_nwo() { echo github.com/fixture/repo; }
_cmg_canon_nwo() { _CMG_CANON="github.com/fixture/repo"; }
STUB_NWO
    # Armed: the unarmed branch short-circuits before the CodeRabbit call and
    # would make every "runs" assertion below pass for the wrong reason.
    cat > "$root/scripts/lib/cr-trigger-ledger.sh" <<'STUB_ARMED' || return 1
cr_trigger_repo_armed() { return 0; }
STUB_ARMED
}

# assert_prior <label> <want_count> <run|conserve> <--no-file|--empty|verdict...>
# want_count is the DERIVED surviving-blocker count the gate must report; an
# empty want_count means the signal must come back UNKNOWN.
assert_prior() {
    local label="$1" want_count="$2" want_action="$3"; shift 3
    local rc=0 err

    rm -f "$GATE_MARKER"
    mkdir -p "$GATE_REPO/.git/cr-prior-blocking"
    case "${1:-}" in
        --no-file) rm -f "$GATE_REPO/.git/cr-prior-blocking/work" ;;
        --empty)   : > "$GATE_REPO/.git/cr-prior-blocking/work" ;;
        *)         printf '%s\n' "$@" > "$GATE_REPO/.git/cr-prior-blocking/work" ;;
    esac

    (
        cd "$GATE_REPO" || exit 99
        STUB_MARKER="$GATE_MARKER" bash "$GATE_ROOT/scripts/cr/coderabbit-gate.sh" \
            --head "$GATE_SHA" --branch work --base-sha "$GATE_SHA"
    ) >"$GATE_OUT" 2>"$GATE_ERR" || rc=$?
    err=$(cat "$GATE_ERR")

    if [ "$rc" -ne 0 ]; then
        fail_prior "$label -- coderabbit-gate.sh exited $rc, want 0; stderr: $err"
        return
    fi

    if [ "$want_action" = conserve ]; then
        if [ -f "$GATE_MARKER" ]; then
            fail_prior "$label -- CodeRabbit RAN; a surviving blocker must conserve the scarce call"
        fi
        if ! contains "$err" "coderabbit pass CONSERVED"; then
            fail_prior "$label -- no CONSERVED message; stderr: $err"
        fi
        if ! contains "$err" "left $want_count surviving"; then
            fail_prior "$label -- want derived count $want_count ('left $want_count surviving'); stderr: $err"
        fi
        return
    fi

    if [ ! -f "$GATE_MARKER" ]; then
        fail_prior "$label -- CodeRabbit did NOT run; stderr: $err"
    fi
    if contains "$err" "coderabbit pass CONSERVED"; then
        fail_prior "$label -- conserved when it must run; stderr: $err"
    fi
    if [ -n "$want_count" ]; then
        # A DERIVED zero: the file was read and parsed, so the UNKNOWN
        # fail-open message must NOT appear. This is what keeps "genuinely
        # zero surviving candidates" distinguishable from "unreadable".
        if contains "$err" "prior-blocking signal UNKNOWN"; then
            fail_prior "$label -- reported UNKNOWN for a readable $want_count-blocker file; stderr: $err"
        fi
    else
        if ! contains "$err" "prior-blocking signal UNKNOWN"; then
            fail_prior "$label -- want the UNKNOWN fail-open message; stderr: $err"
        fi
        # ...and the count it reports must be EMPTY, never a fabricated 0.
        if ! contains "$err" "'<empty>'"; then
            fail_prior "$label -- want an EMPTY count, never a fabricated 0; stderr: $err"
        fi
    fi
}

case_inv4() {
    local tmp
    tmp=$(fixture_mktemp_dir) || {
        echo "FAIL: invariant4 -- fixture tempdir setup failed" >&2
        return 1
    }
    PRIOR_OK=1
    GATE_ROOT="$tmp/root"
    GATE_REPO="$tmp/repo"
    GATE_MARKER="$tmp/coderabbit-ran"
    GATE_OUT="$tmp/out"
    GATE_ERR="$tmp/err"

    if ! build_gate_fixture "$GATE_ROOT"; then
        echo "FAIL: invariant4 -- could not build the coderabbit-gate.sh fixture root" >&2
        rm -rf "$tmp"
        return 1
    fi
    mkdir -p "$GATE_REPO"
    if ! (
        fixture_enter_git_init_dir "$GATE_REPO" || exit 1
        git init -q -b work .
        git config user.email t@t.t
        git config user.name t
        git commit -q --allow-empty -m init
    ) >/dev/null 2>&1; then
        echo "FAIL: invariant4 -- fixture git repo setup failed" >&2
        rm -rf "$tmp"
        return 1
    fi
    GATE_SHA=$(git -C "$GATE_REPO" rev-parse work 2>/dev/null)
    if [ -z "$GATE_SHA" ]; then
        echo "FAIL: invariant4 -- could not resolve the fixture repo's commit for the gate's --head/--base-sha pins" >&2
        rm -rf "$tmp"
        return 1
    fi

    # The exclusion rule, one scenario per row: a candidate is EXCLUDED only
    # when EVERY verdict for its id is `disproved`.
    assert_prior "all-disproved -> 0 (runs CodeRabbit)" 0 run \
        "VERDICT [a-1] = disproved" "VERDICT [a-2] = disproved"
    assert_prior "single agreed -> conserves" 1 conserve \
        "VERDICT [a-1] = agreed"
    assert_prior "single conflict -> conserves" 1 conserve \
        "VERDICT [a-1] = conflict"
    assert_prior "single unaddressed -> conserves" 1 conserve \
        "VERDICT [a-1] = unaddressed"
    assert_prior "{disproved,unaddressed} on one id -> still blocks" 1 conserve \
        "VERDICT [a-1] = disproved" "VERDICT [a-1] = unaddressed"
    assert_prior "a disproved id must not mask a surviving one" 1 conserve \
        "VERDICT [a-1] = disproved" "VERDICT [a-2] = agreed"
    assert_prior "two surviving ids count as two" 2 conserve \
        "VERDICT [a-1] = agreed" "VERDICT [a-2] = conflict"
    assert_prior "empty verdicts file -> 0 (fail-open)" 0 run --empty
    assert_prior "missing file -> UNKNOWN (empty count), fail-open, never a fabricated 0" "" run --no-file

    if [ ! -f "$GATE_ROOT/scripts/cr/coderabbit-review.sh" ]; then
        fail_prior "the stubbed reviewer vanished from the fixture -- a real CodeRabbit call may have been made"
    fi

    rm -rf "$tmp"
    if [ "$PRIOR_OK" -ne 1 ]; then
        return 1
    fi
    echo "PASS: invariant4 (HIMMEL-1219 conservation gate -- 9 fixture scenarios against scripts/cr/coderabbit-gate.sh, reviewer stubbed)"
    return 0
}

# Invariant 5 -- marker-clear authority stays with clear-cr-marker.sh
# (structural, HIMMEL-1064). A bare removal of the marker is byte-identical to
# self-declaring the review clean, which is why the chokepoint exists.
#
# Scope, stated honestly because a structural scan that overclaims is worse
# than one that does not run: this flags any line in a non-test scripts/cr
# script that names cr-pending next to a DESTRUCTIVE verb -- rm, unlink, shred,
# `find -delete`, `mv`, or `>`/`:>` truncation. It is a chokepoint tripwire,
# not a dataflow proof: a removal that reaches the path through a variable
# assigned elsewhere, or through a helper in another directory, is out of its
# reach. Widening it further costs more than the guard is worth; what matters
# is that the PASS line below claims only what was actually checked.
INV5_DESTRUCTIVE='rm|unlink|shred|-delete|mv'
case_inv5() {
    local f base violation=0 hit
    for f in "$ROOT"/scripts/cr/*.sh; do
        base=$(basename "$f")
        case "$base" in
            clear-cr-marker.sh|test-*.sh) continue ;;
        esac
        hit=$(grep -nE "cr-pending" "$f" 2>/dev/null             | grep -E "(^|[^[:alnum:]_])($INV5_DESTRUCTIVE)([^[:alnum:]_]|$)|(^|[[:space:]]):?>[[:space:]]*[^|&]*cr-pending") || true
        if [ -n "$hit" ]; then
            echo "FAIL: invariant5 -- $f names cr-pending/ beside a destructive verb outside clear-cr-marker.sh:" >&2
            printf '%s
' "$hit" >&2
            violation=1
        fi
    done
    if [ "$violation" -ne 0 ]; then
        return 1
    fi
    echo "PASS: invariant5 (marker-clear authority stays with clear-cr-marker.sh -- no non-test scripts/cr/*.sh names cr-pending/ beside rm/unlink/shred/-delete/mv/truncation)"
    return 0
}

# ---------------------------------------------------------------------------
# Invariant 7 -- ledger single-writer (structural, HIMMEL-1944 -> HIMMEL-2226).
# EXACTLY ONE file in the repo appends to the CR critic ledger, and it is
# scripts/cr/ledger-append.sh. Every other script that names the ledger reads
# it, or shells out to ledger-append.sh; a second appender would fork the
# record schema and silently corrupt every consumer (cr-scores, cr-tune,
# known-findings, and clear-cr-marker's gate evidence).
#
# Two-stage scan, so an unrelated ledger elsewhere in the tree cannot be
# mistaken for this one: a file is a CANDIDATE only if it can resolve the CR
# ledger path at all (names cr-critic-scores.jsonl, CR_LEDGER or PANEL_LEDGER);
# only candidates are then scanned for append sites (fs.appendFileSync, or a
# `>>` redirect aimed at the ledger path or at a variable resolved from it).
#
# Scope, stated honestly: this is a chokepoint tripwire, not a dataflow proof.
# An append reaching the ledger through a path handed in from another directory
# under a name this scan does not know is out of its reach.
#
# The set of appending FILES is what is asserted -- never the line numbers,
# which drift on the next edit of ledger-append.sh and would produce a spurious
# red. NON-VACUITY is asserted alongside it: a scan that matched nothing at all
# would otherwise read as "single writer confirmed" while proving nothing.
#
# The exclusion below is deliberately narrow -- ONLY test suites, which write
# throwaway FIXTURE ledgers by design (this file's own write_ledger is one).
# Do not widen it: every pattern added here is a hole in the guard.
# ---------------------------------------------------------------------------
INV7_OWNER='scripts/cr/ledger-append.sh'
INV7_RESOLVES='cr-critic-scores\.jsonl|CR_LEDGER|PANEL_LEDGER'
INV7_APPEND='appendFileSync|>>[[:space:]]*"?\$\{?(CR_LEDGER|PANEL_LEDGER|LEDGER|ledger|led)([^[:alnum:]_]|$)|>>[[:space:]]*[^|&]*cr-critic-scores\.jsonl'
case_inv7() {
    local rel hits listing owner_sites=0 violation=0
    listing=$(cd "$ROOT" && git ls-files -- scripts 2>/dev/null)
    if [ -z "$listing" ]; then
        echo "FAIL: invariant7 -- could not list tracked files under scripts/ (not a git checkout?)" >&2
        return 1
    fi
    while IFS= read -r rel; do
        case "$rel" in
            *.sh|*.mjs|*.js) ;;
            *) continue ;;
        esac
        case "$rel" in
            scripts/cr/test-*.sh|scripts/handover/test-*.sh|*.test.mjs) continue ;;
        esac
        [ -f "$ROOT/$rel" ] || continue
        grep -qE "$INV7_RESOLVES" "$ROOT/$rel" 2>/dev/null || continue
        hits=$(grep -nE "$INV7_APPEND" "$ROOT/$rel" 2>/dev/null) || continue
        [ -n "$hits" ] || continue
        if [ "$rel" = "$INV7_OWNER" ]; then
            owner_sites=$(printf '%s\n' "$hits" | wc -l | tr -d '[:space:]')
            continue
        fi
        echo "FAIL: invariant7 -- $rel appends to the CR critic ledger; only $INV7_OWNER may:" >&2
        printf '%s\n' "$hits" >&2
        violation=1
    done <<INV7_LIST
$listing
INV7_LIST
    if [ "$owner_sites" -eq 0 ]; then
        echo "FAIL: invariant7 -- the append scan matched ZERO sites in $INV7_OWNER. The scan is broken; this is NOT evidence of a single writer." >&2
        violation=1
    fi
    if [ "$violation" -ne 0 ]; then
        return 1
    fi
    echo "PASS: invariant7 (ledger single-writer -- $owner_sites append sites, all in $INV7_OWNER; no other non-test scripts/ source appends to the CR critic ledger)"
    return 0
}

dispatch_case() {
    case "$1" in
        inv1) case_inv1 ;;
        inv3) case_inv3 ;;
        inv4) case_inv4 ;;
        inv5) case_inv5 ;;
        inv7) case_inv7 ;;
        *) echo "test-pr-check-run: unknown case '$1'" >&2; return 10 ;;
    esac
}

if [ "${1:-}" = "--run-case" ]; then
    if [ -z "${2:-}" ]; then
        echo "test-pr-check-run: --run-case requires a case name" >&2
        exit 10
    fi
    dispatch_case "$2"
    exit $?
fi

# ---------------------------------------------------------------------------
# Parent mode: re-exec each case under a per-case timeout so a hang FAILS
# loudly instead of running unbounded (HIMMEL-1953). Overridable, validated.
# ---------------------------------------------------------------------------
CASE_TIMEOUT="${CASE_TIMEOUT_SECS:-120}"
# Zero is rejected alongside the non-numeric shapes on purpose: GNU `timeout 0`
# means "no timeout", so accepting it would silently remove the per-case bound
# this suite was built to have from the start (HIMMEL-1953). The zero test is
# arithmetic, not a glob, so `0`, `00` and `000` are all caught.
if case "$CASE_TIMEOUT" in ''|*[!0-9]*) true ;; *) [ "$CASE_TIMEOUT" -eq 0 ] ;; esac; then
    echo "test-pr-check-run: CASE_TIMEOUT_SECS must be a positive integer (got '${CASE_TIMEOUT_SECS:-}') -- using default 120" >&2
    CASE_TIMEOUT=120
fi

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD=gtimeout
else
    echo "test-pr-check-run: a GNU-compatible timeout command is required (timeout or gtimeout; on macOS: brew install coreutils)" >&2
    exit 1
fi

# The scripts every case drives must be present. Without this a rename turns
# the whole suite into a quiet green -- exactly the vacuous pass the retired
# stub cases used to hide behind.
for required in "$CLEAR" "$GATE"; do
    if [ ! -f "$required" ]; then
        echo "test-pr-check-run: missing script under test: $required" >&2
        exit 1
    fi
done

CASES=(inv1 inv3 inv4 inv5 inv7)

echo "== /pr-check orchestration invariants (HIMMEL-1944, retargeted by HIMMEL-2226) =="

PASSED=0
FAIL=0

for c in "${CASES[@]}"; do
    rc=0
    "$TIMEOUT_CMD" "$CASE_TIMEOUT" bash "$0" --run-case "$c"
    rc=$?
    case "$rc" in
        0) PASSED=$((PASSED + 1)) ;;
        124|137)
            FAIL=$((FAIL + 1))
            echo "FAIL: $c timed out after ${CASE_TIMEOUT}s" >&2
            ;;
        *)
            FAIL=$((FAIL + 1))
            ;;
    esac
done

echo "test-pr-check-run: $PASSED passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
