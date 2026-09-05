#!/usr/bin/env bash
# Smoke / invariant tests for scripts/handover/arm-resume.sh
#
# Covers cwd resolution (--cwd flag, resume_cwd frontmatter, legacy
# fallback + discoverability warning). Uses --dry-run throughout so no
# real scheduler jobs are created.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# ---------------------------------------------------------------------------
# --only <section> / --list (HIMMEL-1637): a targeted-section filter so
# verifying one change doesn't cost the full 35-50 minute / ~380-assertion
# run. Every named section below (T1, V4, 1329, ...) is individually gated
# by `if _sec_selected "<alias>" ...; then ... fi`. Default (no flag): every
# gate sees an empty $ONLY_FILTERS and _sec_selected returns true
# unconditionally, so the full run's output/exit-code semantics are
# BYTE-IDENTICAL to before this flag existed — CI and the pre-push gate
# (which invoke this script with no args) are unaffected.
#
# --list matches the run-shell-tests.sh --list convention: print the plan,
# execute nothing. It exits before $TMP/$ARM are even touched.
#
# Some sections share setup fixtures that live outside any single section's
# gate (e.g. the multislot STATEFUL_STUB scheduler, the WINBIN/win_env
# Windows stubs, the ARMED_STUB/STUB_BIN telemetry stubs) — those helpers are
# deliberately left UNGATED so a filtered run of a downstream section stays
# self-contained; see the ticket for the list of sections with this coupling.
# ---------------------------------------------------------------------------
ONLY_FILTERS=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --only)
            # Empty is refused like absent (panel glm-2, PR CR): "" would make
            # ONLY_FILTERS a bare newline — non-empty, so every section gate
            # deselects and the run exits 0 having tested NOTHING, the exact
            # vacuous-green shape the unknown-section validation fails closed on.
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "test-arm-resume.sh: --only requires a non-empty argument" >&2
                exit 1
            fi
            ONLY_FILTERS="${ONLY_FILTERS}${2}
"
            shift 2
            ;;
        --list)
            LIST_ONLY=1
            shift
            ;;
        *)
            echo "test-arm-resume.sh: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Canonical section plan: <listed name>|<accepted aliases>. Both --list and
# --only validation consume this table so a displayed family name cannot drift
# into a silently vacuous filter again. Keep aliases whitespace-free.
SECTION_DEFINITIONS='T1|T1
T2|T2
T3|T3
T4|T4
T5|T5
T6|T6
T7|T7
T8|T8 T8b
T9|T9 T9b T9b2 T9c T9d
T10|T10
T11|T11
T12|T12
T13|T13
T14|T14
T15|T15
T16|T16
T17|T17
T18|T18
T19|T19
T20|T20
T21|T21
T22|T22
T23|T23
T23b|T23b
T24|T24 T24c
T25|T25
T26|T26
T27|T27
T28|T28 T28d T28e
T29|T29
T30|T30
T31|T31
T32|T32
T33|T33
T33c|T33c
T38|T38
W1-W8|W1-W8 W1 W2 W3 W4 W5 W6 W7 W8
T33-collision|T33-collision
T34|T34
T35|T35
T36|T36
T37|T37
N1-N8|N1-N8 N1 N2 N3 N4 N5 N6 N7 N8
S1-S5|S1-S5 S1 S2 S3 S4 S5
N9-N13|N9-N13 N9 N10 N11 N12 N13 S6 S7 S8 S9 S10 S11 S12
macOS|macOS
T-awkfail|T-awkfail
T-wsl|T-wsl
V1|V1
V2|V2 V2b
V3|V3
V4|V4 V4b V4c
V5|V5
V6|V6
V6b|V6b
V6c|V6c
V7|V7
V8|V8
V8b|V8b
V9|V9
FIND2|FIND2 FIND2b
1365|1365 HIMMEL-1365
1331|1331 HIMMEL-1331
1331b|1331b
1329|1329 HIMMEL-1329
1330|1330 HIMMEL-1330
1337|1337 HIMMEL-1337
1603|1603 HIMMEL-1603
T_SEAM|T_SEAM
T_PRUNE|T_PRUNE
T_PRUNE_REAL|T_PRUNE_REAL
T1287|T1287
1640|1640 HIMMEL-1640
1719|1719 HIMMEL-1719
1674|1674 HIMMEL-1674
1879|1879 HIMMEL-1879 1999 HIMMEL-1999
1879-1365|1879-1365 1998 HIMMEL-1998
812|812 HIMMEL-812
1830|1830 HIMMEL-1830
1636|1636 HIMMEL-1636
2113c|2113c HIMMEL-2113
2113d|2113d HIMMEL-2113
2113e|2113e HIMMEL-2113
2113f|2113f HIMMEL-2113
2113g|2113g HIMMEL-2113
2128|2128 HIMMEL-2128
2147|2147 HIMMEL-2147
2192|2192 HIMMEL-2192
2199|2199 HIMMEL-2199
2177|2177 HIMMEL-2177
2545|2545 HIMMEL-2545'

_section_alias_known() {
    local _candidate="$1" _label _aliases _alias
    while IFS='|' read -r _label _aliases; do
        for _alias in $_aliases; do
            [ "$_candidate" = "$_alias" ] && return 0
        done
    done <<EOF
$SECTION_DEFINITIONS
EOF
    return 1
}

_list_sections() {
    local _label _aliases
    while IFS='|' read -r _label _aliases; do
        printf '%s\n' "$_label"
    done <<EOF
$SECTION_DEFINITIONS
EOF
}

if [ -n "$ONLY_FILTERS" ]; then
    while IFS= read -r _filter; do
        [ -n "$_filter" ] || continue
        if ! _section_alias_known "$_filter"; then
            echo "test-arm-resume.sh: unknown --only section: $_filter (see --list)" >&2
            exit 1
        fi
    done <<EOF
$ONLY_FILTERS
EOF
fi

# _sec_selected <alias> [<alias> ...] — true (rc 0) when this section should
# run this pass: no --only filter was given (default full run), or at least
# one of the section's own aliases exact-matches a requested --only value.
_sec_selected() {
    [ -z "$ONLY_FILTERS" ] && return 0
    local _want _f
    for _want in "$@"; do
        while IFS= read -r _f; do
            [ -n "$_f" ] || continue
            [ "$_f" = "$_want" ] && return 0
        done <<EOF
$ONLY_FILTERS
EOF
    done
    return 1
}

if [ "$LIST_ONLY" -eq 1 ]; then
    _list_sections
    exit 0
fi

ARM="$(cd "$(dirname "$0")" && pwd)/arm-resume.sh"
[ -x "$ARM" ] || chmod +x "$ARM"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Global telemetry shield (HIMMEL-236): arm-resume emits to
# ~/.claude/telemetry/skill-usage.jsonl by default, so without a
# suite-level override every invocation below individually relies on
# --dry-run / a per-test SKILL_TELEMETRY_DIR / the kill switch / stubs
# to avoid polluting the operator's real sink. Default the sink to a
# throwaway under $TMP; telemetry tests (T21-T24) override per-call
# with their own sinks as before.
export SKILL_TELEMETRY_DIR="$TMP/telemetry-default"
# Unset the kill switch so T21/T23 (which assert a record IS written) are
# not spuriously broken by an operator shell that exports it (HIMMEL-384).
unset SKILL_TELEMETRY_DISABLE 2>/dev/null || true
# Naming-template shield (HIMMEL-716): an operator shell exporting a custom
# ARM_NAME_TEMPLATE would skew every derived-name assertion below (N/S cases);
# S8/S9 set it per-call.
unset ARM_NAME_TEMPLATE 2>/dev/null || true
# Slot-threshold shield (HIMMEL-1271): the --time smart cases assert against
# the SHIPPED default wall, and an operator shell exporting
# RESUME_SLOT_THRESHOLD reaches resume-slot.sh through this script. T9c sets
# it per-call.
unset RESUME_SLOT_THRESHOLD 2>/dev/null || true
# CR-floor-fallback advisory shield (HIMMEL-2128): 2128b/2128b2 assert on
# whether the pre-arm WARN fires for CR_REQUIRE_CROSS_MODEL/CR_FLOOR_FALLBACK;
# an operator shell exporting either would make those assertions depend on
# ambient state instead of the per-call value each case sets.
unset CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK 2>/dev/null || true
# Worker-census shield (HIMMEL-1637): arm-resume's live-lane-worker guard
# (HIMMEL-1622, rc=10) censuses reconcile-workers.sh's bridge root — default
# ~/.claude/handover/bridge — so a REAL live or unprobeable GLM/claudex worker
# meta on the MACHINE turns every non-dry-run arm below into a spurious rc=10
# (observed 2026-08-08: 27 FAILs across T25b–W8 in a gate run that overlapped
# live lane dispatches; the window closed mid-run and later sections passed).
# Point the census at an isolated, empty root under $TMP. Scope note: the
# telegram-bridge tests (T13–T19) drive supervisor.pid detection via per-call
# BRIDGE_ROOT / BRIDGE_PIDFILE, which the census does NOT read when
# WORKER_BRIDGE_ROOT is set (reconcile-workers.sh resolution:
# WORKER_BRIDGE_ROOT > BRIDGE_ROOT > default), so this shield cannot leak
# into their bridge-detection assertions.
export WORKER_BRIDGE_ROOT="$TMP/worker-bridge-shield"
# Global workspace-trust shield (HIMMEL-386): arm-resume now pre-trusts the
# resolved cwd in ~/.claude.json. The non-dry-run arm cases below (T14-T20
# bridge/channel checks, dedup-any) would otherwise write the operator's real
# config — redirect the pre-seed at a throwaway file for the whole suite.
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
# Temp-target shield (HIMMEL-1365): every fixture in this suite lives under
# $TMP (WORK_REPO="$TMP/work-repo"), which is precisely the shape arm-resume
# now refuses — a real scheduled task pointing at a throwaway directory. This
# suite means it: its scheduler is PATH-stubbed, so no real task is ever
# created. Declaring the opt-out here, alongside the other shields, keeps that
# intent explicit rather than letting a heuristic silently exempt us. The
# refusal itself is exercised below with the variable unset.
export ARM_TEMP_CWD_OK=1

# Dotenv-read shield (HIMMEL-2254). arm-resume load_dotenv's ARMAUTOMERGE /
# CR_REQUIRE_CROSS_MODEL / CR_FLOOR_FALLBACK out of a `.env` FILE, falling back
# to the PRIMARY checkout when the candidate root has none -- so the `unset`s
# above are NOT enough on their own: a host whose own .env carries the
# HIMMEL-2147 ARMAUTOMERGE=1 default re-fills the key from disk, and every
# "a default arm does not GRANT ARMAUTOMERGE" assertion below (T33b, T33c, and
# T-wsl's in-distro `&& claude` body, which grows an `ARMAUTOMERGE=1
# CR_MERGE_GATE_OK=1 ` prefix the moment the default applies) fails on exactly
# the hosts that adopted the feature and passes everywhere else. The shield
# must therefore defeat a FILE READ, not an env var. ARM_RESUME_DOTENV_ROOT
# points that read at a suite-owned directory: EMPTY by default, so every key
# is genuinely absent; the 2128/2147 cases below write a `.env` into it to
# drive the value they are actually testing.
export ARM_RESUME_DOTENV_ROOT="$TMP/dotenv-shield"
mkdir -p "$ARM_RESUME_DOTENV_ROOT"
# Defense-in-depth against ambient PROCESS env, which wins over any .env via
# load_dotenv's non-clobber contract before the file is ever consulted.
unset ARMAUTOMERGE CR_MERGE_GATE_OK 2>/dev/null || true

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label — output unexpectedly contains: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

FAILED=0

# ---------------------------------------------------------------------------
# Fixture setup
# ---------------------------------------------------------------------------
# A directory to use as a "valid work repo" that is a git repo (so
# the legacy fallback also has something to resolve to).
WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"

# A separate directory for handover files (simulates the state repo).
HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/statedocs"

# A NEAR future time (HH:MM, <=60 min out) so the HIMMEL-1475 long-gap guard
# stays silent for every fixture below that just needs a valid future HH:MM.
# Tests that deliberately arm FAR — T8 tomorrow-roll, T28d seeds, T33-T36/N6
# collision probes, the macOS multislot sibling — carry their own far times
# + --long-gap.
#
# HIMMEL-1579 (suite shelf life): this used to be computed ONCE, justified by
# "a hermetic shell suite finishes well inside the 30-min window". That is no
# longer true — the suite takes 35-50 minutes on the overlord8 box. Every test
# reached after minute 30 therefore asked for a time already in the PAST,
# arm-resume rolled it to TOMORROW (~23.5h out), and the long-gap guard
# refused with rc=9. Observed 2026-08-06: 14 failures across V3/V4/V4b/V5/V6/V6c,
# all "expected rc=N, got rc=9", none of them a real defect. The suite had
# outlived its own fixture.
#
# So: recompute on demand, but CACHE. The naive fix (a fresh timestamp at every
# one of the 118 call sites) would break the identity/verify tests, which arm
# and then re-arm or post-verify and compare the requested time against the
# scheduler's NextRunTime inside a 120s tolerance -- a minute rolling over
# between those two calls is exactly the mismatch they are written to detect.
# Caching keeps the value STABLE across the calls within a test and refreshes
# only when the target is about to go stale.
#
# The cache lives in a FILE, not in shell variables (panel r3 codex-1). Every
# one of the 118 call sites spells this `$(future_time)`, and a command
# substitution runs in a SUBSHELL: variables the function assigns die with it,
# so a variable-backed cache was write-only and each call silently recomputed
# from scratch. That is not cosmetic — V4b feeds one call's HH:MM into the
# expected epoch and another's into the arm, so a minute rolling between them
# shifted the requested target 60s and turned its deliberate 121s mistime into
# a 61s one, inside the tolerance: the case would have gone red for a fixture
# reason, intermittently, on exactly the boundary HIMMEL-1609 is settling. A
# file survives the subshell, so the cache the comment above describes is now
# the cache that actually runs.
_FT_FILE="$TMP/future-time.cache"      # "<target-epoch> <HH:MM>"
_FT_STALE_FILE="$TMP/future-time.stale"
future_time() {
    local _now _target _value
    _now=$(date +%s)
    _target=0; _value=""
    [ -s "$_FT_FILE" ] && read -r _target _value < "$_FT_FILE"
    # Refresh when unset, or when fewer than 10 minutes remain before the
    # cached target -- comfortably before it can expire mid-test, and far
    # enough from the 60-min long-gap ceiling to stay silent.
    if [ -z "$_value" ] || [ "$(( _target - _now ))" -lt 600 ]; then
        # Latch BEFORE overwriting: a target found already past is the only
        # evidence the run outlived its fixture, and the refresh erases it.
        # The teardown WARN (HIMMEL-1579 item 3) reads this marker.
        if [ -n "$_value" ] && [ "$_now" -ge "$_target" ]; then : > "$_FT_STALE_FILE"; fi
        _target=$(( _now + 1800 ))
        _value=$(python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1])).strftime('%H:%M'))" "$_target")
        printf '%s %s\n' "$_target" "$_value" > "$_FT_FILE"
    fi
    printf '%s' "$_value"
}
# Crossing midnight needs no special case: at 23:45 this yields "00:15", which
# arm-resume reads as past-for-today and rolls to the next calendar day --
# 30 minutes out from 23:45, the intended lead, not a 24h one.

# ---------------------------------------------------------------------------
# Helper: write a minimal handover file and return its path via stdout.
# Usage: make_handover [resume_cwd_value_or_empty]
# ---------------------------------------------------------------------------
make_handover() {
    local cwd_val="${1:-}"
    local path="$HANDOVER_DIR/handover-$RANDOM.md"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        [ -n "$cwd_val" ] && printf 'resume_cwd: %s\n' "$cwd_val"
        printf -- '---\n'
        printf '# Test handover\n'
    } > "$path"
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# Helper (HIMMEL-540): a TICKET-BEARING handover, dedicated + separate from
# make_handover so the dedup/collision/multislot suite stays ticketless.
#   $1 = H1 title text, $2 = optional 'ticket:' frontmatter value,
#   $3 = optional body line (printed AFTER the closing --- and H1 — i.e. body,
#        not frontmatter — so N5 can mention a ticket key OUTSIDE the H1 scan).
# ---------------------------------------------------------------------------
make_handover_titled() {
    local path="$HANDOVER_DIR/ho-titled-$RANDOM.md"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        [ -n "${2:-}" ] && printf 'ticket: %s\n' "$2"
        printf -- '---\n'
        printf '# %s\n' "$1"
        [ -n "${3:-}" ] && printf '%s\n' "$3"
    } > "$path"
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# Scheduler stub for T1-T7 (HIMMEL-380): these tests use --dry-run to probe
# cwd-resolution logic and never intend to touch the real scheduler. Without
# a stub, list_existing() calls the real schtasks/atq on a machine that may
# have a live HIMMEL-Resume job, causing rc=3 (dedup block) and spurious
# failures. Reuse the same empty-scheduler stub pattern as T23.
# ---------------------------------------------------------------------------
SCHED_STUB_T17="$TMP/sched-stub-t17"
mkdir -p "$SCHED_STUB_T17"
# HIMMEL-1879: /create REGISTERS what it was given, /query reports it back. The
# old stateless "always exit 0, never list anything" fake is internally
# inconsistent, and the post-arm EXISTENCE verify reads it (correctly) as a
# create that armed nothing -> rc 2 on every non-dry-run arm through this stub
# (W5, W8). Same treatment ARMED_STUB gets below; own state file so the two
# cannot see each other's tasks, and it still starts EMPTY.
cat > "$SCHED_STUB_T17/schtasks" <<EOF
#!/usr/bin/env bash
db="$TMP/sched-stub-t17.tasks"
cmd="\${1:-}"; shift || true
tn=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        /tn)   tn="\${2:-}"; shift 2 ;;
        /tn=*) tn="\${1#/tn=}"; shift ;;
        *)     shift ;;
    esac
done
case "\$cmd" in
    /query)
        [ -f "\$db" ] || exit 0
        while IFS= read -r t; do
            [ -n "\$t" ] && printf '"\\\\%s","2026-01-01","Ready"\\n' "\$t"
        done < "\$db"
        exit 0 ;;
    /create|/delete)
        if [ -f "\$db" ]; then
            grep -vFx "\$tn" "\$db" > "\$db.tmp" 2>/dev/null || : > "\$db.tmp"
            mv "\$db.tmp" "\$db"
        fi
        [ "\$cmd" = /create ] && printf '%s\\n' "\$tn" >> "\$db"
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$SCHED_STUB_T17/atq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCHED_STUB_T17/at" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# HIMMEL-938: schtasks /create above is a stateless "always succeeds" fake —
# it never actually registers anything with the real OS scheduler. On an
# ACTUAL Windows box (this suite runs on Windows dev machines, not just
# Linux CI), arm-resume's post-arm verify would otherwise fall through to
# the REAL powershell, query the REAL (nonexistent, since /create was
# faked) task, and correctly-but-spuriously refuse (rc=2) every non-dry-run
# arm through this stub. Stubbing powershell to echo "right now" keeps the
# fake create/verify pair internally consistent — the tests below that use
# this stub for a REAL (non-dry-run) arm care about dedup/worktree/naming
# behavior, not the verify feature itself.
cat > "$SCHED_STUB_T17/powershell" <<'EOF'
#!/usr/bin/env bash
# Probe "unavailable" -> arm-resume's verify fail-opens (WARN, arm stands).
# Faking a NextRunTime here would need the requested TARGET_EPOCH, which the
# stub can't know; the fail-open path is the honest fake for tests that
# exercise dedup/worktree/naming, not the verify feature itself.
exit 1
EOF
chmod +x "$SCHED_STUB_T17/schtasks" "$SCHED_STUB_T17/atq" "$SCHED_STUB_T17/at" "$SCHED_STUB_T17/powershell"

# ---------------------------------------------------------------------------
# T1: --cwd <dir> overrides everything, even when resume_cwd is set
# ---------------------------------------------------------------------------
if _sec_selected "T1"; then
HO=$(make_handover "$HANDOVER_DIR")   # resume_cwd set to $HANDOVER_DIR itself
# $WORK_REPO is the explicit --cwd; it should win.
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --cwd "$WORK_REPO" --dry-run 2>&1)
rc=$?
assert_rc "T1 --cwd flag exits 0" 0 "$rc"
assert_contains "T1 RESUME_CWD matches --cwd arg" "RESUME_CWD=$WORK_REPO" "$out"
assert_not_contains "T1 --cwd does not resolve to statedocs" "RESUME_CWD=$HANDOVER_DIR" "$out"
# HIMMEL-386: the arm pre-trusts the resolved cwd (dry-run reports, doesn't mutate).
assert_contains "T1 dry-run pre-trusts resolved cwd" "would pre-trust workspace '$WORK_REPO'" "$out"
fi

# ---------------------------------------------------------------------------
# T2: handover WITH resume_cwd pointing to a valid dir, NO --cwd
#     → resolved cwd is that dir
# ---------------------------------------------------------------------------
if _sec_selected "T2"; then
HO=$(make_handover "$WORK_REPO")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T2 resume_cwd frontmatter exits 0" 0 "$rc"
assert_contains "T2 RESUME_CWD matches frontmatter value" "RESUME_CWD=$WORK_REPO" "$out"
# Must NOT emit the discoverability warning (resume_cwd was found).
assert_not_contains "T2 no discoverability warning when resume_cwd set" "no --cwd and no 'resume_cwd:'" "$out"
fi

# ---------------------------------------------------------------------------
# T3: handover with resume_cwd pointing to a NON-EXISTENT dir, no --cwd
#     → emits WARN and falls back (cwd != the bogus path)
# ---------------------------------------------------------------------------
if _sec_selected "T3"; then
BOGUS="$TMP/does-not-exist-$(date +%s)"
HO=$(make_handover "$BOGUS")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T3 bad resume_cwd still exits 0 (warn+fallback)" 0 "$rc"
assert_contains "T3 emits WARN for bad resume_cwd" "WARN arm-resume: handover resume_cwd:" "$out"
assert_not_contains "T3 RESUME_CWD is not the bogus path" "RESUME_CWD=$BOGUS" "$out"
# resume_cwd was present (just invalid) — must NOT emit the "no resume_cwd" discoverability WARN.
assert_not_contains "T3 no spurious discoverability warning when key was present" "no --cwd and no 'resume_cwd:'" "$out"
fi

# ---------------------------------------------------------------------------
# T4: handover with NO resume_cwd, no --cwd
#     → falls back to git-toplevel / handover dir AND emits discoverability warning
# ---------------------------------------------------------------------------
if _sec_selected "T4"; then
HO=$(make_handover "")   # no resume_cwd line
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T4 no-cwd fallback exits 0" 0 "$rc"
assert_contains "T4 emits discoverability warning" "no --cwd and no 'resume_cwd:' in handover frontmatter" "$out"
# RESUME_CWD should resolve to the git toplevel of $TMP/statedocs.
# Compute the expected value the same way arm-resume does (git rev-parse).
EXPECTED_T4=$(git -C "$TMP/statedocs" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$TMP/statedocs")
assert_contains "T4 RESUME_CWD resolves to statedocs git-toplevel" "RESUME_CWD=$EXPECTED_T4" "$out"
fi

# ---------------------------------------------------------------------------
# T5: resume_cwd value with surrounding double quotes is handled correctly
# ---------------------------------------------------------------------------
if _sec_selected "T5"; then
HO_QUOTED="$HANDOVER_DIR/handover-quoted-$RANDOM.md"
{
    printf -- '---\n'
    printf 'session_kind: test\n'
    printf 'resume_cwd: "%s"\n' "$WORK_REPO"
    printf -- '---\n'
    printf '# Test handover\n'
} > "$HO_QUOTED"
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_QUOTED" --dry-run 2>&1)
rc=$?
assert_rc "T5 double-quoted resume_cwd exits 0" 0 "$rc"
assert_contains "T5 double-quoted resume_cwd resolves correctly" "RESUME_CWD=$WORK_REPO" "$out"
fi

# ---------------------------------------------------------------------------
# T6: resume_cwd value with surrounding single quotes is handled correctly
# ---------------------------------------------------------------------------
if _sec_selected "T6"; then
HO_SQ="$HANDOVER_DIR/handover-sq-$RANDOM.md"
{
    printf -- '---\n'
    printf 'session_kind: test\n'
    printf "resume_cwd: '%s'\n" "$WORK_REPO"
    printf -- '---\n'
    printf '# Test handover\n'
} > "$HO_SQ"
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_SQ" --dry-run 2>&1)
rc=$?
assert_rc "T6 single-quoted resume_cwd exits 0" 0 "$rc"
assert_contains "T6 single-quoted resume_cwd resolves correctly" "RESUME_CWD=$WORK_REPO" "$out"
fi

# ---------------------------------------------------------------------------
# T7: CRLF + double-quoted resume_cwd regression guard
#     Fixture uses \r\n line endings and `resume_cwd: "<validdir>"`.
#     Old code: quote-strip before rtrim → `\r` prevents `%\"` match →
#     rtrim leaves trailing quote → `[ -d ]` fails → wrong-repo fallback.
#     New code: rtrim first → \r gone → quote-strip works → resolves correctly.
# ---------------------------------------------------------------------------
if _sec_selected "T7"; then
HO_CRLF="$HANDOVER_DIR/handover-crlf-$RANDOM.md"
# Write every line with explicit CRLF (\r\n) to simulate Windows-authored YAML.
printf -- '---\r\nsession_kind: test\r\nresume_cwd: "%s"\r\n---\r\n# CRLF test handover\r\n' \
    "$WORK_REPO" > "$HO_CRLF"
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_CRLF" --dry-run 2>&1)
rc=$?
assert_rc "T7 CRLF+quoted resume_cwd exits 0" 0 "$rc"
assert_contains "T7 CRLF+quoted resume_cwd resolves correctly" "RESUME_CWD=$WORK_REPO" "$out"
# Must NOT contain a trailing quote in the resolved path.
assert_not_contains "T7 no trailing quote in RESUME_CWD" "RESUME_CWD=${WORK_REPO}\"" "$out"
# Must NOT fall back to the discoverability warning (resume_cwd WAS present).
assert_not_contains "T7 no discoverability warning for CRLF handover" "no --cwd and no 'resume_cwd:'" "$out"
fi

# ---------------------------------------------------------------------------
# T8: a past --time HH:MM rolls the scheduled DATE to tomorrow (HIMMEL-204).
#     Old code passed schtasks /st with no /sd -> defaulted to today, so a
#     past time gave "Next Run Time: N/A" and never fired. --force --dry-run
#     isolates from the live-scheduler dedup so this is deterministic.
# ---------------------------------------------------------------------------
if _sec_selected "T8"; then
# HIMMEL-1277: arm-resume renders /sd in the MACHINE's own Windows short-date
# pattern (_win_short_date_pattern + _win_render_short_date — the HIMMEL-938
# fix), so T8's old hardcoded "%m/%d/%Y" expectation was a false FAIL on every
# day-first box (win2 is dd/MM/yyyy; observed 2026-07-25 — the PRODUCT was
# right and the ASSERTION was wrong). T8's subject is the DATE ROLL, not the
# locale ORDER (V1/V2/V2b pin the order against a stubbed registry), so compare
# the /sd token's numeric groups as a SET against tomorrow's day/month/year:
# order-agnostic, still exact — a wrong date changes the set. A `y` run of <=2
# renders a 2-digit year, hence the two accepted spellings.
#
# Two couplings, both deliberate, both raised in review (panel r1):
#   - Zero-padding. The expected groups are padded (%d/%m), which is correct
#     because _win_render_short_date pads every d/M run with
#     `width = max(run_len, 2)` — a single-width `M/d/yyyy` locale (the real
#     Windows en-US default, and this box's actual registry value) still
#     renders 08/22/2026, never 8/22/2026.
#   - Transposition. A sorted set cannot tell Aug 9 from Sep 8. Accepted:
#     ORDER is not T8's subject, and V1/V2/V2b pin it exactly against stubbed
#     locales. T8 asks only whether the date ROLLED.
#
# _digit_set <string> — the string's runs of digits, sorted, space-joined.
# Also the CR scrubber: python3 under Git-Bash prints CRLF, so a \r would ride
# along into any expected value built from it; `tr -cs '0-9'` drops it as a
# non-digit, which is why BOTH sides go through here.
_digit_set() { printf '%s' "$1" | tr -cs '0-9' '\n' | grep -v '^$' | sort | tr '\n' ' '; }
_assert_sd_is_tomorrow() {   # <label> <arm-output>
    local label="$1" text="$2" sd sd_set set4 set2
    sd=$(printf '%s\n' "$text" | sed -n 's|.* /sd \(.*\)|\1|p' | head -n 1 | sed 's| /.*||')
    sd_set=$(_digit_set "$sd")
    set4=$(_digit_set "$(python3 -c 'import datetime; d=datetime.datetime.now()+datetime.timedelta(days=1); print(d.strftime("%d %m %Y"))')")
    set2=$(_digit_set "$(python3 -c 'import datetime; d=datetime.datetime.now()+datetime.timedelta(days=1); print(d.strftime("%d %m %y"))')")
    if [ "$sd_set" = "$set4" ] || [ "$sd_set" = "$set2" ]; then
        echo "PASS $label (/sd $sd)"
    else
        echo "FAIL $label -- /sd '$sd' has digit groups [$sd_set], expected [$set4] or [$set2]"
        FAILED=$((FAILED + 1))
    fi
}
HO=$(make_handover "$WORK_REPO")
PAST_HHMM=$(python3 -c 'import datetime; print((datetime.datetime.now()-datetime.timedelta(minutes=2)).strftime("%H:%M"))')
# HIMMEL-966: host `at` must not be a dependency; pin the posix backend with the stub.
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$PAST_HHMM" --handover "$HO" --long-gap --force --dry-run 2>&1)
rc=$?
assert_rc "T8 past --time exits 0 (force+dry)" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        _assert_sd_is_tomorrow "T8 schtasks /sd is tomorrow" "$out"

        # T8b (HIMMEL-1277 regression guard): the same roll on a DAY-FIRST
        # machine. This box is month-first, so T8 alone can never catch a
        # re-hardcoded US expectation — win2 would keep eating the false red.
        # Forcing `reg` to report dd/MM/yyyy makes the day-first render happen
        # HERE, so a revert to a locale-pinned assertion goes red on the box
        # that runs the suite.
        T8B_BIN="$TMP/t8b-stub-bin"; mkdir -p "$T8B_BIN"
        cp "$SCHED_STUB_T17/schtasks" "$SCHED_STUB_T17/at" "$SCHED_STUB_T17/atq" "$SCHED_STUB_T17/powershell" "$T8B_BIN/"
        cat > "$T8B_BIN/reg" <<'EOF'
#!/usr/bin/env bash
echo 'HKEY_CURRENT_USER\Control Panel\International'
echo '    sShortDate    REG_SZ    dd/MM/yyyy'
exit 0
EOF
        chmod +x "$T8B_BIN/reg"
        HO_T8B=$(make_handover "$WORK_REPO")
        out=$(SCHTASKS_CMD="$T8B_BIN/schtasks" PATH="$T8B_BIN:$PATH" bash "$ARM" --time "$PAST_HHMM" --handover "$HO_T8B" --long-gap --force --dry-run 2>&1)
        rc=$?
        assert_rc "T8b day-first locale past --time exits 0 (force+dry)" 0 "$rc"
        _assert_sd_is_tomorrow "T8b schtasks /sd is tomorrow under dd/MM/yyyy" "$out"
        ;;
    *)
        TOM=$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(days=1)).strftime("%Y%m%d"))')
        assert_contains "T8 at -t stamp is tomorrow" "at -t $TOM" "$out"
        ;;
esac
fi

# ---------------------------------------------------------------------------
# T9: --time smart end-to-end through arm-resume (HIMMEL-204). A bank-free
#     fixture cache (injected via RESUME_SLOT_CACHE) must resolve to an ASAP
#     slot and flow a concrete date into the scheduler line. SLOT_MAX_AGE=0
#     skips the freshness guard; --force --dry-run isolates from the live
#     scheduler dedup and touches nothing.
# ---------------------------------------------------------------------------
if _sec_selected "T9" "T9b" "T9b2" "T9c" "T9d"; then
HO=$(make_handover "$WORK_REPO")
SLOT_CACHE="$TMP/usage-free.json"
FIVE_RESET=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')
SEVEN_RESET=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=6)).isoformat())')
printf '{"five_hour":{"utilization":0.0,"resets_at":"%s"},"seven_day":{"utilization":15.0,"resets_at":"%s"}}' \
    "$FIVE_RESET" "$SEVEN_RESET" > "$SLOT_CACHE"
# HIMMEL-966: host `at` must not be a dependency; pin the posix backend with the stub.
out=$(RESUME_SLOT_CACHE="$SLOT_CACHE" SLOT_MAX_AGE=0 SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T9 --time smart exits 0 (force+dry)" 0 "$rc"
assert_contains "T9 smart banner shows bank-free ASAP" "smart -> " "$out"
assert_contains "T9 smart reason is bank free" "bank free" "$out"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        assert_contains "T9 smart flows a /sd date into schtasks" "/sd " "$out" ;;
    *)
        assert_contains "T9 smart flows an at -t stamp" "at -t " "$out" ;;
esac

# ---------------------------------------------------------------------------
# T9b/T9c: RESUME_SLOT_THRESHOLD reaches resume-slot.sh THROUGH arm-resume
#     (HIMMEL-1271). arm-resume deliberately does not forward a --threshold
#     flag — the child process inherits the environment — so this is the
#     end-to-end proof of that contract. One 95% seven_day fixture: EXHAUSTED
#     under the shipped 90 default (park at the reset), HEADROOM under an
#     operator-set 97 (ASAP).
#
# HIMMEL-2113 Ask A: a 6-day-out seven-day-reset park now refuses FAST
# (rc=19) instead of silently arming into it -- exactly the incident shape
# (a multi-hour/day park chosen silently deep inside a slow script). --force
# alone does NOT override this (it only sanctions the shipped-work preflight);
# --long-gap is the dedicated override, reusing the explicit-HH:MM long-gap
# guard's own flag/semantics.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
BUSY_CACHE="$TMP/usage-95.json"
printf '{"five_hour":{"utilization":10.0,"resets_at":"%s"},"seven_day":{"utilization":95.0,"resets_at":"%s"}}' \
    "$FIVE_RESET" "$SEVEN_RESET" > "$BUSY_CACHE"
out=$(RESUME_SLOT_CACHE="$BUSY_CACHE" SLOT_MAX_AGE=0 SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T9b default-wall park refuses fast (rc=19, HIMMEL-2113)" 19 "$rc"
assert_contains "T9b ERR names the park time + reason" "wait for seven-day reset" "$out"
assert_contains "T9b ERR names the --long-gap override" "--long-gap" "$out"

HO=$(make_handover "$WORK_REPO")
out=$(RESUME_SLOT_CACHE="$BUSY_CACHE" SLOT_MAX_AGE=0 SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time smart --handover "$HO" --force --long-gap --dry-run 2>&1)
rc=$?
assert_rc "T9b1 --long-gap overrides the park refusal (rc=0)" 0 "$rc"
assert_contains "T9b1 95% is exhausted under the shipped 90 default" "wait for seven-day reset" "$out"

# T9b2 (review fix): the OTHER rc=19 exemption -- ARM_RESUME_SAFETY_ARM=1 alone,
# with NEITHER --long-gap NOR --force, must also arm cleanly. This is the
# auto-arm-on-cap.sh/spawn-glm cap-respawn shape (HIMMEL-856): those automated
# callers set ARM_RESUME_SAFETY_ARM=1 in their child env and cannot pass
# --long-gap, so a future edit that dropped this exemption from the rc=19
# guard (while keeping it on rc=9) would silently strand them parked.
HO=$(make_handover "$WORK_REPO")
out=$(ARM_RESUME_SAFETY_ARM=1 RESUME_SLOT_CACHE="$BUSY_CACHE" SLOT_MAX_AGE=0 SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time smart --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T9b2 ARM_RESUME_SAFETY_ARM=1 exempts the park refusal, no --long-gap/--force (rc=0)" 0 "$rc"
assert_contains "T9b2 95% is exhausted under the shipped 90 default" "wait for seven-day reset" "$out"

HO=$(make_handover "$WORK_REPO")
out=$(RESUME_SLOT_THRESHOLD=97 RESUME_SLOT_CACHE="$BUSY_CACHE" SLOT_MAX_AGE=0 SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T9c env-97 wall exits 0" 0 "$rc"
assert_contains "T9c RESUME_SLOT_THRESHOLD=97 reaches the child -> ASAP" "bank free" "$out"
assert_contains "T9c child applied the env threshold, not 90" "< 97%" "$out"

# T9d (HIMMEL-1968): the 2026-08-19 19:37 shape — 96% weekly under an
# operator-raised 97 threshold resolves ASAP (correct by the rule), but the
# child's near-wall WARN must REACH the operator through arm-resume. A
# successful resolve used to discard the child's stderr, so the warning was
# silent exactly when it mattered.
HO=$(make_handover "$WORK_REPO")
NEAR_CACHE="$TMP/usage-96.json"
printf '{"five_hour":{"utilization":6.0,"resets_at":"%s"},"seven_day":{"utilization":96.0,"resets_at":"%s"}}'     "$FIVE_RESET" "$SEVEN_RESET" > "$NEAR_CACHE"
out=$(RESUME_SLOT_THRESHOLD=97 RESUME_SLOT_CACHE="$NEAR_CACHE" SLOT_MAX_AGE=0 SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH"     bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T9d 96% under env-97 still arms ASAP (rc 0)" 0 "$rc"
assert_contains "T9d slot is ASAP by the rule" "bank free" "$out"
assert_contains "T9d the child's near-wall WARN is relayed by arm-resume" "WARN resume-slot: seven-day=96%" "$out"
fi

# ---------------------------------------------------------------------------
# T10: --time smart with an exhausted-but-null-reset cache fails loud (rc 1
#      from arm-resume, surfacing resume-slot's rc 2) — never arms a bad job.
# ---------------------------------------------------------------------------
if _sec_selected "T10"; then
HO=$(make_handover "$WORK_REPO")
BAD_CACHE="$TMP/usage-nullreset.json"
printf '{"five_hour":{"utilization":99.0,"resets_at":null},"seven_day":{"utilization":10.0,"resets_at":"%s"}}' \
    "$SEVEN_RESET" > "$BAD_CACHE"
out=$(RESUME_SLOT_CACHE="$BAD_CACHE" SLOT_MAX_AGE=0 bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T10 smart with unsafe cache exits 1 (no arm)" 1 "$rc"
assert_contains "T10 surfaces the slot error" "could not resolve a slot" "$out"
fi

# ---------------------------------------------------------------------------
# T_1674_STALE (HIMMEL-1674 Part A): --time smart with a STRUCTURALLY-VALID
#     cache whose mtime is STALE must fail CLOSED. This is the operator's
#     exact 2026-08-10 scenario (cache 13058s old against a 3600s max): a stale
#     cache is a NORMAL expected state (idle machine / statusline not run
#     recently), NOT malformed data. resume-slot.sh exits 2 on a stale cache and
#     arm-resume relays that as rc 1 -- never rc 0 with no task. This locks the
#     closed behaviour; a regression that re-opens the fail-open (rc 0, no task)
#     fails this assertion. Distinct from T10 (a structurally-bad cache: null
#     reset, also rc 2 -> rc 1).
# ---------------------------------------------------------------------------
if _sec_selected "1674"; then
HO=$(make_handover "$WORK_REPO")
STALE_CACHE="$TMP/usage-stale.json"
# Self-contained resets_at (staleness is checked BEFORE the cache is parsed, so
# the values do not matter -- but keep them valid so a future reorder of
# resume-slot's checks does not make this test pass for the wrong reason).
printf '{"five_hour":{"utilization":10.0,"resets_at":"1785000000"},"seven_day":{"utilization":20.0,"resets_at":"1785000000"}}' > "$STALE_CACHE"
# Age the fixture far past the 3600s freshness ceiling (operator saw 13058s).
# `touch -d` runs as a child of this harness, so it is NOT subject to the
# caller's command-shape allow-list the way a direct tool invocation is.
touch -d "2020-01-01 00:00:00" "$STALE_CACHE"
out=$(RESUME_SLOT_CACHE="$STALE_CACHE" SLOT_MAX_AGE=3600 bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T_1674 stale cache -> smart fails CLOSED (rc 1, no arm)" 1 "$rc"
assert_contains "T_1674 stale surfaces the arm-resume relay error" "could not resolve a slot" "$out"
assert_contains "T_1674 stale names the staleness reason" "stale" "$out"

# ---------------------------------------------------------------------------
# T_1674_TOMORROW (HIMMEL-1674 Part B): an explicit --time HH:MM already past
#     for today rolls to TOMORROW. The roll must be reported LOUDLY when it is a
#     FAR park (the "resume in 10 min silently became resume in 24h" class), not
#     land on tomorrow with no mention. A 2-minutes-ago HH:MM rolls ~24h out, so
#     the WARN must fire. --long-gap sanctions the far park (else the long-gap
#     guard refuses rc=9); --force --dry-run isolate from the live scheduler.
#     Distinct from T8, which asserts the /sd-is-tomorrow mechanics; this
#     asserts the operator-facing roll WARN.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
PAST_HHMM=$(python3 -c 'import datetime; print((datetime.datetime.now()-datetime.timedelta(minutes=2)).strftime("%H:%M"))')
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$PAST_HHMM" --handover "$HO" --long-gap --force --dry-run 2>&1)
rc=$?
assert_rc "T_1674 past-time far roll still arms (force+long-gap+dry)" 0 "$rc"
assert_contains "T_1674 past-time roll warns LOUDLY about tomorrow" "rolled the arm to TOMORROW" "$out"
assert_contains "T_1674 past-time roll names the rolled time" "$PAST_HHMM" "$out"

# ---------------------------------------------------------------------------
# T_1674_NEAR (HIMMEL-1674 Part B negative): a NEAR arm must NOT trip the
#     far-roll WARN. A ~25-minutes-out HH:MM is either a same-day future arm
#     (no roll at all) or, across midnight, a near roll whose gap is < 3600s --
#     either way the WARN stays silent. Guards against the WARN being over-broad
#     and noising up every ordinary / midnight-crossing arm.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
NEAR_HHMM=$(python3 -c 'import datetime; n=datetime.datetime.now(); t=n.replace(second=0,microsecond=0)+datetime.timedelta(minutes=25); print(t.strftime("%H:%M"))')
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$NEAR_HHMM" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T_1674 near arm arms cleanly (rc 0, no long-gap refusal)" 0 "$rc"
assert_not_contains "T_1674 near arm emits no spurious roll WARN" "rolled the arm to TOMORROW" "$out"
fi

# ---------------------------------------------------------------------------
# T11: --channels while the bun bridge is LIVE is REFUSED (rc 5). HIMMEL-225.
#      ARM_BRIDGE_LIVE=1 forces the liveness check true without a real process.
#      --force --dry-run isolates from the live scheduler; the guard fires
#      before any scheduler touch, so nothing is created.
# ---------------------------------------------------------------------------
if _sec_selected "T11"; then
HO=$(make_handover "$WORK_REPO")
out=$(ARM_BRIDGE_LIVE=1 bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T11 --channels + live bridge refused (rc 5)" 5 "$rc"
assert_contains "T11 explains the refusal" "refusing --channels" "$out"
assert_contains "T11 names the 409 hazard" "409 Conflict" "$out"
fi

# ---------------------------------------------------------------------------
# T12: ARM_CHANNELS_OK=1 overrides the guard even with a live bridge → the arm
#      proceeds (rc 0) and the --channels passthrough flows into the dry-run.
# ---------------------------------------------------------------------------
if _sec_selected "T12"; then
HO=$(make_handover "$WORK_REPO")
out=$(ARM_CHANNELS_OK=1 ARM_BRIDGE_LIVE=1 bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T12 ARM_CHANNELS_OK override exits 0" 0 "$rc"
assert_contains "T12 channels passthrough survives override" "--channels" "$out"
assert_not_contains "T12 no refusal under override" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T13: real detection path — BRIDGE_ROOT points at a dir with NO supervisor.pid
#      (bridge not running), ARM_BRIDGE_LIVE unset → the guard does NOT fire and
#      a --channels arm proceeds (rc 0), passthrough intact.
# ---------------------------------------------------------------------------
if _sec_selected "T13"; then
NO_BRIDGE="$TMP/no-bridge"
mkdir -p "$NO_BRIDGE"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$NO_BRIDGE" bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T13 --channels + no live bridge proceeds (rc 0)" 0 "$rc"
assert_contains "T13 channels passthrough flows into dry-run" "--channels" "$out"
assert_not_contains "T13 no spurious refusal when bridge absent" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T14: the guard is --channels-only — a PLAIN arm with a live bridge is
#      UNAFFECTED (rc 0). Confirms the default relaunch path never regresses.
# ---------------------------------------------------------------------------
if _sec_selected "T14"; then
HO=$(make_handover "$WORK_REPO")
out=$(ARM_BRIDGE_LIVE=1 bash "$ARM" --time "$(future_time)" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T14 plain arm + live bridge unaffected (rc 0)" 0 "$rc"
assert_not_contains "T14 no refusal on a plain arm" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T15: REAL detection — pidfile names a LIVE pid → guard fires (rc 5). Exercises
#      the actual pidfile-read + JSON-parse + _pid_alive path that the
#      ARM_BRIDGE_LIVE seam (T11/T12/T14) bypasses. Live pid is platform-honest:
#      POSIX uses this shell's own pid ($$, `kill -0` true); Windows uses PID 4
#      (the System process, always running) because $$ is an MSYS pid `tasklist`
#      cannot see. Requires python3 + (tasklist|kill) — a failure here is env,
#      not guard logic.
# ---------------------------------------------------------------------------
if _sec_selected "T15"; then
LIVE_BRIDGE="$TMP/live-bridge"
mkdir -p "$LIVE_BRIDGE"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*) LIVE_PID=4 ;;
    *)                           LIVE_PID=$$ ;;
esac
printf '{"supervisor": %d, "poller": 0}\n' "$LIVE_PID" > "$LIVE_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$LIVE_BRIDGE" bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T15 real pidfile + live pid refuses (rc 5)" 5 "$rc"
assert_contains "T15 explains the refusal" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T16: stale pidfile names a DEAD pid → guard does NOT fire (rc 0). A crashed
#      bridge leaves a pidfile; a legit --channels arm must still proceed.
#      999999 is absent on every platform (`kill -0` fails / tasklist "No tasks").
# ---------------------------------------------------------------------------
if _sec_selected "T16"; then
STALE_BRIDGE="$TMP/stale-bridge"
mkdir -p "$STALE_BRIDGE"
printf '{"supervisor": 999999, "poller": 0}\n' > "$STALE_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$STALE_BRIDGE" bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T16 stale (dead-pid) pidfile proceeds (rc 0)" 0 "$rc"
assert_not_contains "T16 no refusal on a dead-pid pidfile" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T17: malformed pidfile (present but unparseable) → FAIL CLOSED: treat the
#      bridge as live and refuse (rc 5) + warn. A present-but-torn pidfile most
#      likely means the bridge is up, so refusing is the safe direction (the
#      ARM_CHANNELS_OK=1 escape covers a genuinely corrupt file).
# ---------------------------------------------------------------------------
if _sec_selected "T17"; then
BAD_BRIDGE="$TMP/bad-bridge"
mkdir -p "$BAD_BRIDGE"
printf 'not json at all {{{\n' > "$BAD_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$BAD_BRIDGE" bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T17 malformed pidfile fails closed (rc 5)" 5 "$rc"
assert_contains "T17 warns about the unreadable pidfile" "present but unreadable/empty" "$out"
assert_contains "T17 still refuses --channels" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T18: REAL detection via the POLLER key — pidfile is {"supervisor":0,"poller":<live>}
#      so the supervisor key is dead/absent and ONLY the poller key carries a live
#      pid. Proves the JSON loop's poller branch decides liveness (T15 puts the
#      live pid under supervisor, so this is the complementary key). Guard fires
#      (rc 5). Live pid is platform-honest (see T15).
# ---------------------------------------------------------------------------
if _sec_selected "T18"; then
POLLER_BRIDGE="$TMP/poller-bridge"
mkdir -p "$POLLER_BRIDGE"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*) POLLER_PID=4 ;;
    *)                           POLLER_PID=$$ ;;
esac
printf '{"supervisor": 0, "poller": %d}\n' "$POLLER_PID" > "$POLLER_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$POLLER_BRIDGE" bash "$ARM" --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T18 live pid under poller key refuses (rc 5)" 5 "$rc"
assert_contains "T18 explains the refusal" "refusing --channels" "$out"
# Negative assertion: the fail-closed path (empty $pids) ALSO yields rc 5 +
# "refusing --channels", so the asserts above would stay green even if the
# poller key were ignored. T17's fail-closed branch is the one that emits
# "present but unreadable/empty" — its ABSENCE here proves liveness was decided
# by the parsed poller pid, not by the unreadable-pidfile fallback (HIMMEL-228).
assert_not_contains "T18 did NOT take the fail-closed path" "present but unreadable/empty" "$out"
fi

# ---------------------------------------------------------------------------
# T19: BRIDGE_PIDFILE direct override WINS over BRIDGE_ROOT/supervisor.pid. The
#      resolver prefers $BRIDGE_PIDFILE; all other tests drive BRIDGE_ROOT only.
#      Point BRIDGE_PIDFILE at a live-pid file while BRIDGE_ROOT points at a dir
#      whose supervisor.pid is DEAD — if the override wins the guard fires (rc 5),
#      proving BRIDGE_PIDFILE took precedence over the (dead) BRIDGE_ROOT file.
# ---------------------------------------------------------------------------
if _sec_selected "T19"; then
OVERRIDE_LIVE="$TMP/override-live.pid"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*) OVERRIDE_PID=4 ;;
    *)                           OVERRIDE_PID=$$ ;;
esac
printf '{"supervisor": %d, "poller": 0}\n' "$OVERRIDE_PID" > "$OVERRIDE_LIVE"
OVERRIDE_ROOT="$TMP/override-root"        # BRIDGE_ROOT with a DEAD supervisor.pid
mkdir -p "$OVERRIDE_ROOT"
printf '{"supervisor": 999999, "poller": 0}\n' > "$OVERRIDE_ROOT/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_PIDFILE="$OVERRIDE_LIVE" BRIDGE_ROOT="$OVERRIDE_ROOT" bash "$ARM" \
        --time "$(future_time)" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T19 BRIDGE_PIDFILE override (live) wins over dead BRIDGE_ROOT (rc 5)" 5 "$rc"
assert_contains "T19 explains the refusal" "refusing --channels" "$out"
fi

# ---------------------------------------------------------------------------
# T20: wedged python3 stub (HIMMEL-249) — the --time HH:MM epoch resolution
#      must fail BOUNDED + visible (rc 2 + ERR), never hang the arm. The
#      watchdog (auto-arm-on-cap) calls this script, so a hang here would
#      wedge the whole armor chain.
# ---------------------------------------------------------------------------
if _sec_selected "T20"; then
if timeout --version 2>/dev/null | grep -qi coreutils; then
    mkdir -p "$TMP/wedged-bin"
    cat > "$TMP/wedged-bin/python3" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30
EOF
    chmod +x "$TMP/wedged-bin/python3"
    HO=$(make_handover "$WORK_REPO")
    start=$(date +%s)
    out=$(PATH="$TMP/wedged-bin:$PATH" PY_ARMOR_TIMEOUT=1 PY_ARMOR_KILL_AFTER=1 \
        bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
    rc=$?
    elapsed=$(( $(date +%s) - start ))
    assert_rc "T20 wedged stub fails the arm visibly (rc 2)" 2 "$rc"
    assert_contains "T20 surfaces a clean ERR line" "ERR arm-resume: could not resolve --time" "$out"
    if [ "$elapsed" -lt 15 ]; then
        echo "PASS T20 bounded (${elapsed}s)"
    else
        echo "FAIL T20 bounded — took ${elapsed}s"
        FAILED=$((FAILED + 1))
    fi
else
    echo "SKIP T20 (no GNU coreutils timeout on this runner)"
fi
fi

# ---------------------------------------------------------------------------
# T21: telemetry seam (HIMMEL-236) — the dedup block (rc 3) emits ONE
#      measure-during record to the side-channel sink, nothing to stdout
#      beyond the existing ERR text. Scheduler is PATH-stubbed so the
#      test fabricates an existing HIMMEL-Resume job on any platform.
# ---------------------------------------------------------------------------
STUB_BIN="$TMP/sched-stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/schtasks" <<'EOF'
#!/usr/bin/env bash
# /query → pretend one HIMMEL-Resume job exists (CSV shape of /fo CSV /nh)
printf '"\\HIMMEL-Resume-stub","2026-01-01","Ready"\n'
EOF
cat > "$STUB_BIN/atq" <<'EOF'
#!/usr/bin/env bash
printf '1\tThu Jun 11 09:00:00 2026 a user\n'
EOF
cat > "$STUB_BIN/at" <<'EOF'
#!/usr/bin/env bash
printf '# HIMMEL-Resume-stub\n'
EOF
chmod +x "$STUB_BIN/schtasks" "$STUB_BIN/atq" "$STUB_BIN/at"

if _sec_selected "T21"; then
# --dedup-any (HIMMEL-340): STUB_BIN fabricates a job named HIMMEL-Resume-stub
# whose name will not match this random handover's $TASK_NAME under the new
# per-handover dedup. --dedup-any restores the broad "any slot blocks" match
# so this test keeps exercising the shared dedup-block path (telemetry + rc 3).
TELEMETRY_T21="$TMP/telemetry-t21"
HO=$(make_handover "$WORK_REPO")
out=$(SCHTASKS_CMD="$STUB_BIN/schtasks" PATH="$STUB_BIN:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T21" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T21 dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T21 ERR text preserved" "already scheduled" "$out"
TLOG="$TELEMETRY_T21/skill-usage.jsonl"
if [ -f "$TLOG" ]; then
    echo "PASS T21 telemetry record written"
else
    echo "FAIL T21 telemetry record missing ($TLOG)"
    FAILED=$((FAILED + 1))
fi
tline=$(tail -1 "$TLOG" 2>/dev/null || true)
assert_contains "T21 record names the skill" '"skill":"handover-arm-resume"' "$tline"
assert_contains "T21 record names the event" '"event":"dedup-block"' "$tline"
if [ "$(wc -l < "$TLOG" 2>/dev/null | tr -d ' ')" = "1" ]; then
    echo "PASS T21 exactly one append"
else
    echo "FAIL T21 expected exactly one telemetry line"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T22: telemetry honors --dry-run's "touch nothing" contract AND the
#      kill switch — neither run may append a record.
# ---------------------------------------------------------------------------
if _sec_selected "T22"; then
TELEMETRY_T22="$TMP/telemetry-t22"
HO=$(make_handover "$WORK_REPO")
out=$(SKILL_TELEMETRY_DIR="$TELEMETRY_T22" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T22 dry-run exits 0" 0 "$rc"
if [ -f "$TELEMETRY_T22/skill-usage.jsonl" ]; then
    echo "FAIL T22 dry-run appended telemetry (touch-nothing violated)"
    FAILED=$((FAILED + 1))
else
    echo "PASS T22 dry-run appends no telemetry"
fi
out=$(SCHTASKS_CMD="$STUB_BIN/schtasks" PATH="$STUB_BIN:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T22" SKILL_TELEMETRY_DISABLE=1 \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T22 kill-switched dedup still blocks (rc 3)" 3 "$rc"
if [ -f "$TELEMETRY_T22/skill-usage.jsonl" ]; then
    echo "FAIL T22 kill switch did not suppress the append"
    FAILED=$((FAILED + 1))
fi
# --dry-run WITHOUT --force hitting the dedup block (the no---force
# else-branch — the path the --force --dry-run case above bypasses):
# must still block rc 3 AND must not emit (touch-nothing contract).
out=$(SCHTASKS_CMD="$STUB_BIN/schtasks" PATH="$STUB_BIN:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T22" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "T22 dry-run (no --force) dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T22 dry-run dedup ERR text preserved" "already scheduled" "$out"
if [ -f "$TELEMETRY_T22/skill-usage.jsonl" ]; then
    echo "FAIL T22 dry-run dedup-block appended telemetry (touch-nothing violated)"
    FAILED=$((FAILED + 1))
else
    echo "PASS T22 no run appended telemetry (dry-run x2 + kill switch)"
fi

fi
# ---------------------------------------------------------------------------
# T23: telemetry seam (HIMMEL-236) — a SUCCESSFUL arm (the primary
#      measure-during signal) emits exactly ONE "armed" record with the
#      time=/force= fields. Scheduler is PATH-stubbed: /query (and atq)
#      report an empty scheduler, /create (and at) succeed, so the arm
#      completes on any platform without touching the real scheduler.
#      TMPDIR is pinned so the windows-path .bat lands under $TMP.
# ---------------------------------------------------------------------------
ARMED_STUB="$TMP/armed-stub-bin"
mkdir -p "$ARMED_STUB"
# HIMMEL-1879: this stub used to answer EVERY /query with an empty scheduler
# while reporting /create success -- internally inconsistent, and the arm's new
# post-arm existence verify (correctly) reads that as "the create armed
# nothing" and refuses rc=2. Same class the HIMMEL-938 note below already
# handled for `powershell`. State is a per-$TMP file (no SCHED_DB env needed,
# unlike make_stateful_sched), with real `/create /f` overwrite-in-place
# semantics, so the scheduler still starts EMPTY for every section and only
# ever holds what this suite actually armed.
cat > "$ARMED_STUB/schtasks" <<EOF
#!/usr/bin/env bash
db="$TMP/armed-stub.tasks"
cmd="\${1:-}"; shift || true
tn=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        /tn)   tn="\${2:-}"; shift 2 ;;
        /tn=*) tn="\${1#/tn=}"; shift ;;
        *)     shift ;;
    esac
done
case "\$cmd" in
    /query)
        [ -f "\$db" ] || exit 0
        while IFS= read -r t; do
            [ -n "\$t" ] && printf '"\\\\%s","2026-01-01","Ready"\\n' "\$t"
        done < "\$db"
        exit 0 ;;
    /create|/delete)
        if [ -f "\$db" ]; then
            grep -vFx "\$tn" "\$db" > "\$db.tmp" 2>/dev/null || : > "\$db.tmp"
            mv "\$db.tmp" "\$db"
        fi
        [ "\$cmd" = /create ] && printf '%s\\n' "\$tn" >> "\$db"
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$ARMED_STUB/atq" <<EOF
#!/usr/bin/env bash
d="$TMP/armed-stub.atdir"; [ -d "\$d" ] || exit 0
for f in "\$d"/job-*; do
    [ -f "\$f" ] || continue
    printf '%s\\tThu Jun 11 09:00:00 2026 a user\\n' "\${f##*/job-}"
done
exit 0
EOF
cat > "$ARMED_STUB/at" <<EOF
#!/usr/bin/env bash
d="$TMP/armed-stub.atdir"; mkdir -p "\$d"
case "\${1:-}" in
    -c) cat "\$d/job-\${2:-}" 2>/dev/null; exit 0 ;;
    -t)
        n=\$(cat "\$d/.counter" 2>/dev/null || echo 0); n=\$((n + 1))
        printf '%s' "\$n" > "\$d/.counter"
        cat > "\$d/job-\$n"
        exit 0 ;;
    *) cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
cat > "$ARMED_STUB/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# HIMMEL-938: see the matching comment on SCHED_STUB_T17 above — /create is a
# stateless fake, so on a real Windows box the post-arm verify needs its own
# fake to stay internally consistent (else a real powershell query for a
# task that was never really created would correctly refuse the arm).
cat > "$ARMED_STUB/powershell" <<'EOF'
#!/usr/bin/env bash
# Probe "unavailable" -> verify fail-opens (see SCHED_STUB_T17 note).
exit 1
EOF
chmod +x "$ARMED_STUB/schtasks" "$ARMED_STUB/atq" "$ARMED_STUB/at" "$ARMED_STUB/claude" "$ARMED_STUB/powershell"

if _sec_selected "T23"; then
TELEMETRY_T23="$TMP/telemetry-t23"
HO=$(make_handover "$WORK_REPO")
# HIMMEL-1579: capture ONCE. This is the only test that arms at a time and then
# asserts that same time appears in the output, so it is the only place where
# two future_time() calls must agree. The helper refreshes when its cached
# target is close to expiring, and a refresh landing between the arm and the
# assertion would fail this test for a reason that has nothing to do with the
# telemetry record it is checking.
T23_TIME=$(future_time)
out=$(TMPDIR="$TMP" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T23" \
    bash "$ARM" --time "$T23_TIME" --handover "$HO" 2>&1)
rc=$?
assert_rc "T23 stubbed arm succeeds (rc 0)" 0 "$rc"
assert_contains "T23 arm banner printed" "RESUME ARMED" "$out"
TLOG23="$TELEMETRY_T23/skill-usage.jsonl"
if [ -f "$TLOG23" ] && [ "$(wc -l < "$TLOG23" | tr -d ' ')" = "1" ]; then
    echo "PASS T23 exactly one telemetry record"
else
    echo "FAIL T23 expected exactly one telemetry line ($TLOG23)"
    FAILED=$((FAILED + 1))
fi
tline=$(tail -1 "$TLOG23" 2>/dev/null || true)
assert_contains "T23 record names the skill" '"skill":"handover-arm-resume"' "$tline"
assert_contains "T23 record names the event" '"event":"armed"' "$tline"
assert_contains "T23 record carries time" "\"time\":\"$T23_TIME\"" "$tline"
assert_contains "T23 record carries force" '"force":"0"' "$tline"
# HIMMEL-1490: the measured gap (raw seconds) is emitted alongside the
# long_gap flag. FUTURE_TIME is now+30m, so a real positive integer (<3600)
# is expected — present AND numeric, not an exact value (timing-dependent).
assert_contains "T23 record carries gap_sec field" '"gap_sec":"' "$tline"
_t23_gap=${tline#*\"gap_sec\":\"}; _t23_gap=${_t23_gap%%\"*}
case "$_t23_gap" in
    ''|0|*[!0-9]*)
        # '0' is rejected too: an explicit arm 30m out MUST measure a nonzero
        # gap — 0 is the unset-_GAP_SEC default and would mask that regression.
        echo "FAIL T23 gap_sec not a strictly positive integer (got '$_t23_gap')"
        FAILED=$((FAILED + 1))
        ;;
    *)
        echo "PASS T23 gap_sec is a strictly positive integer ($_t23_gap)"
        ;;
esac
unset _t23_gap
fi

# ---------------------------------------------------------------------------
# T23b: scheduler-create FAILURE emits NO record (HIMMEL-236) — the
#       'armed' emit sits AFTER schedule_arm, so a failed create (rc 4)
#       must leave the sink absent/empty: a failed arm is not a
#       re-launch signal. Arg-discriminating stub: /query (and atq)
#       report an empty scheduler so the arm proceeds past dedup,
#       /create (and at) fail.
# ---------------------------------------------------------------------------
if _sec_selected "T23b"; then
CREATEFAIL_STUB="$TMP/createfail-stub-bin"
mkdir -p "$CREATEFAIL_STUB"
cat > "$CREATEFAIL_STUB/schtasks" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    /query)  exit 0 ;;                                   # empty scheduler
    /create) echo "stub: create refused" >&2; exit 1 ;;  # create fails
    *)       exit 1 ;;
esac
EOF
cat > "$CREATEFAIL_STUB/atq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$CREATEFAIL_STUB/at" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null   # consume the heredoc job body
echo "stub: at refused" >&2
exit 1
EOF
cat > "$CREATEFAIL_STUB/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$CREATEFAIL_STUB/schtasks" "$CREATEFAIL_STUB/atq" "$CREATEFAIL_STUB/at" "$CREATEFAIL_STUB/claude"

TELEMETRY_T23B="$TMP/telemetry-t23b"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHTASKS_CMD="$CREATEFAIL_STUB/schtasks" PATH="$CREATEFAIL_STUB:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T23B" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" 2>&1)
rc=$?
assert_rc "T23b failed scheduler create exits 4" 4 "$rc"
assert_contains "T23b ERR text surfaced" "ERR arm-resume:" "$out"
if [ -s "$TELEMETRY_T23B/skill-usage.jsonl" ]; then
    echo "FAIL T23b failed create appended telemetry (no-emit invariant violated)"
    FAILED=$((FAILED + 1))
else
    echo "PASS T23b failed create appends no telemetry"
fi
fi

# ---------------------------------------------------------------------------
# T24: caller-side fail-open (HIMMEL-236) — arm-resume must behave
#      identically when scripts/lib/telemetry.sh is ABSENT or
#      syntactically BROKEN (the `|| true` source + no-op fallback at
#      the call site). The script is copied into an isolated tree so
#      the real lib is never touched.
# ---------------------------------------------------------------------------
if _sec_selected "T24"; then
FAILOPEN="$TMP/failopen"
mkdir -p "$FAILOPEN/handover" "$FAILOPEN/lib"
# HIMMEL-1607: copy the WHOLE handover + lib pair, not just arm-resume.sh.
# The original copied arm-resume.sh plus py-armor.sh alone, which was complete
# when T24 was written and silently rotted as arm-resume grew dependencies. It
# now reaches for four siblings via $SCRIPT_DIR (cap-reset-time, queue-lock,
# reconcile-workers, resume-slot), and reconcile-workers is FAIL-CLOSED:
# arm-resume.sh:315 refuses rc=2 when it is absent, because live-worker state
# that cannot be checked must not be papered over. Every T24 case therefore died
# at rc=2 before reaching the dedup path it is actually about, while reporting
# as "the HIMMEL-236 fail-open contract is broken". Copying the directories
# wholesale means the next fail-closed sibling does not repeat this.
cp "$(dirname "$ARM")"/*.sh "$FAILOPEN/handover/" 2>/dev/null || true
cp "$(dirname "$ARM")/../lib"/*.sh "$FAILOPEN/lib/" 2>/dev/null || true
# telemetry.sh is the SUBJECT of this test — it must be the only thing missing.
rm -f "$FAILOPEN/lib/telemetry.sh"
# (a) lib ABSENT — dedup must still block rc 3 with the ERR text intact.
#     --dedup-any: STUB_BIN's fabricated HIMMEL-Resume-stub won't match this
#     random handover's $TASK_NAME under per-handover dedup (HIMMEL-340), so
#     the broad scope is what reproduces the dedup-block path under test here.
HO=$(make_handover "$WORK_REPO")
out=$(SCHTASKS_CMD="$STUB_BIN/schtasks" PATH="$STUB_BIN:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$(future_time)" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T24 absent lib: dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T24 absent lib: ERR text intact" "already scheduled" "$out"
# (b) lib BROKEN (bash syntax error) — same dedup invariants, AND a
#     successful arm still completes end-to-end (rc 0, banner printed)
printf 'if [ broken\nthen (\n' > "$FAILOPEN/lib/telemetry.sh"
out=$(SCHTASKS_CMD="$STUB_BIN/schtasks" PATH="$STUB_BIN:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$(future_time)" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T24 broken lib: dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T24 broken lib: ERR text intact" "already scheduled" "$out"
out=$(TMPDIR="$TMP" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$(future_time)" --handover "$HO" 2>&1)
rc=$?
assert_rc "T24 broken lib: successful arm still completes (rc 0)" 0 "$rc"
assert_contains "T24 broken lib: arm banner printed" "RESUME ARMED" "$out"
# The fail-open is `. lib 2>/dev/null || true` — BOTH halves. Nothing pinned
# the redirect, so bash's parse error from the broken lib could start leaking
# into the operator's arm output with every rc assertion still green.
assert_not_contains "T24 broken lib: the parse error is not leaked to the operator" "syntax error" "$out"

# T24c (HIMMEL-1576): the NEGATIVE CONTROL. Turning six FAILs into six PASSes
# does not demonstrate the test works — T24 spent months exiting 2 on a missing
# sibling while reporting as "the HIMMEL-236 fail-open contract is broken", and
# a repaired fixture that still cannot fail for its intended reason is the same
# defect wearing green. So: break the fail-open deliberately, in a SECOND copy
# tree, and assert the arm dies. If this passes while T24(b) also passes, the
# `|| true` is genuinely what is holding the arm up.
FAILOPEN_NEG="$TMP/failopen-neg"
rm -rf "$FAILOPEN_NEG"
mkdir -p "$FAILOPEN_NEG"
cp -R "$FAILOPEN/handover" "$FAILOPEN/lib" "$FAILOPEN_NEG/"
sed '\#lib/telemetry\.sh#s# 2>/dev/null || true##' "$FAILOPEN/handover/arm-resume.sh" \
    > "$FAILOPEN_NEG/handover/arm-resume.sh"
# A no-op sed would make this control vacuous — the exact class of bug the
# ticket is about — so prove the edit landed before trusting the result.
if grep -qF 'lib/telemetry.sh" 2>/dev/null || true' "$FAILOPEN_NEG/handover/arm-resume.sh"; then
    echo "FAIL T24c negative control did not strip the fail-open (sed matched nothing) — the control below is vacuous"
    FAILED=$((FAILED + 1))
else
    echo "PASS T24c negative control stripped the caller-side fail-open"
fi
# A FRESH handover, not the $HO that T24(b) just armed: if the fail-open were
# ever restored, a second arm of the same handover could return rc=3 (dedup)
# instead of rc=0, and the "rc != 0" below would read as PASS for a reason that
# has nothing to do with the fail-open — a control whose green can come from a
# second cause is the vacuous shape this whole case exists to remove.
HO_T24C=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
    bash "$FAILOPEN_NEG/handover/arm-resume.sh" --time "$(future_time)" --handover "$HO_T24C" 2>&1)
rc=$?
# "Nonzero" alone is not proof of CAUSE (panel r3 codex-2): an unrelated
# fixture or scheduler error would satisfy it and the control would pass
# without testing anything. So require the positive evidence too — with the
# 2>/dev/null gone, bash's own parse error from the broken lib must now reach
# the output, which is the same string T24(b) asserts is ABSENT while the
# fail-open stands. The pair is the control: same input, opposite verdicts.
if [ "$rc" != "0" ] && grepq "$out" -F 'syntax error'; then
    echo "PASS T24c without the fail-open the broken telemetry.sh breaks the arm and surfaces its parse error (rc=$rc) — T24 can still fail for its intended reason"
else
    echo "FAIL T24c expected a nonzero rc AND a leaked parse error with the fail-open REMOVED (got rc=$rc) — the control is not proving its cause"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# Multislot (HIMMEL-340): per-handover dedup lets N distinct handovers each
# arm their own slot, while the SAME handover still dedups. These need a
# STATEFUL scheduler stub (the empty/always-one stubs above can't model a
# growing set of jobs): /create records the task, /query lists what was
# recorded, /delete removes one. Selected by platform exactly as arm-resume
# selects it (schtasks on Windows; at/atq/atrm on POSIX), sharing one state
# location so dedup is actually exercised.
# ---------------------------------------------------------------------------
make_stateful_sched() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/schtasks" <<'EOF'
#!/usr/bin/env bash
# Stateful schtasks stub. State = $SCHED_DB (flat file, one task name/line).
db="${SCHED_DB:?SCHED_DB unset}"
cmd="${1:-}"; shift || true
tn=""; xml=0
while [ $# -gt 0 ]; do
    case "$1" in
        /tn)   tn="${2:-}"; shift 2 ;;
        /tn=*) tn="${1#/tn=}"; shift ;;
        /xml)  xml=1; shift 2 ;;
        *)     shift ;;
    esac
done
case "$cmd" in
    /query)
        [ -f "$db" ] || exit 0
        while IFS= read -r t; do
            [ -n "$t" ] && printf '"\\%s","2026-01-01","Ready"\n' "$t"
        done < "$db"
        exit 0 ;;
    /create)
        if [ "$xml" -eq 1 ] && [ "${SCHED_XML_CREATE_FAIL:-0}" = "1" ]; then
            echo "stub: schtasks /create /xml deliberately failing" >&2
            exit 9
        fi
        # Real schtasks /create /f OVERWRITES a task of the same name in
        # place (arm-resume.sh always passes /f) — a same-name re-create is
        # not a second row. Model that here (HIMMEL-1304): drop any existing
        # line for this name before appending the fresh one, so a --force
        # re-arm of the SAME handover nets zero change in row count, matching
        # a real scheduler instead of accumulating a duplicate.
        if [ -f "$db" ]; then
            grep -vFx "$tn" "$db" > "$db.tmp" 2>/dev/null || : > "$db.tmp"
            mv "$db.tmp" "$db"
        fi
        printf '%s\n' "$tn" >> "$db"; exit 0 ;;
    /delete)
        if [ -f "$db" ]; then
            grep -vFx "$tn" "$db" > "$db.tmp" 2>/dev/null || : > "$db.tmp"
            mv "$db.tmp" "$db"
        fi
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
    cat > "$dir/at" <<'EOF'
#!/usr/bin/env bash
# Stateful at stub. State = $SCHED_DB_DIR (job-<id> files + .counter).
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; mkdir -p "$d"
case "${1:-}" in
    -c) cat "$d/job-${2:-}" 2>/dev/null; exit 0 ;;
    -t)
        n=$(cat "$d/.counter" 2>/dev/null || echo 0); n=$((n + 1))
        printf '%s' "$n" > "$d/.counter"
        cat > "$d/job-$n"
        exit 0 ;;
    *) cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
    cat > "$dir/atq" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; [ -d "$d" ] || exit 0
for f in "$d"/job-*; do
    [ -f "$f" ] || continue
    printf '%s\tThu Jun 11 09:00:00 2026 a user\n' "${f##*/job-}"
done
exit 0
EOF
    cat > "$dir/atrm" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; rm -f "$d/job-${1:-}" 2>/dev/null || true
exit 0
EOF
    cat > "$dir/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    # HIMMEL-938: same reasoning as the SCHED_STUB_T17/ARMED_STUB comments
    # above — the stateful schtasks stub's /create records a task name but
    # never talks to the real scheduler, so a real Windows box's post-arm
    # verify needs its own fake or every T25+ non-dry-run arm through this
    # stub would be spuriously refused.
    cat > "$dir/powershell" <<'EOF'
#!/usr/bin/env bash
# Probe "unavailable" -> verify fail-opens (see SCHED_STUB_T17 note).
exit 1
EOF
    cat > "$dir/crontab" <<'EOF'
#!/usr/bin/env bash
# Stateful crontab stub (HIMMEL-1581, lifted from test-arm-resume-identity.sh's
# HIMMEL-1567 stub). arm-resume.sh routes macOS (Darwin) through crontab ONLY:
# list_existing()'s macos arm calls _crontab_list (`crontab -l | grep`), and
# _crontab_schedule/_crontab_delete rewrite via `| crontab -`. Without a stub
# here a Darwin run of the multislot section resolves the REAL crontab binary
# and reads -- and through _crontab_delete's rewrite, WRITES -- the operator's
# machine-wide crontab outside this suite's fixture. State lives in a fixture
# file inside $SCHED_DB_DIR; `:?` so an unset var is a LOUD failure rather than
# a silent fall-through to the real binary (mirrors the at/atq/atrm guard).
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; mkdir -p "$d"
db="$d/crontab.fixture"
case "${1:-}" in
    -l)
        # Real `crontab -l` exits 1 ("no crontab for user") with no output when
        # the crontab is empty; the arm-resume callers all guard that, so model
        # it honestly rather than always exiting 0.
        if [ -s "$db" ]; then cat "$db"; exit 0; else exit 1; fi ;;
    -)
        cat > "$db"; exit 0 ;;
    -r)
        : > "$db"; exit 0 ;;
    "")
        # Piped stdin with no flag = replace.
        cat > "$db"; exit 0 ;;
    -*)
        # Unknown flag (-e editor, -u user): NEVER touch real state. Drain any
        # piped stdin so the writer sees no spurious SIGPIPE; exit 0 so a
        # probe-by-existence sees a present binary.
        cat > /dev/null 2>&1 || true; exit 0 ;;
    *)
        # A bare file arg = install from that file (real `crontab <file>`).
        if [ -f "$1" ]; then cat "$1" > "$db"; exit 0; fi
        cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
    chmod +x "$dir/schtasks" "$dir/at" "$dir/atq" "$dir/atrm" "$dir/claude" "$dir/powershell" "$dir/crontab"
}

# Count armed slots in the platform's state location.
#   $1 = SCHED_DB file (windows); $2 = SCHED_DB_DIR dir (posix)
count_slots() {
    case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
        msys*|cygwin*|win32*|MINGW*)
            # `|| true`, NOT `|| echo 0`: grep -c ALREADY prints its count (0)
            # and exits 1 on no-match, so an `echo 0` fallback emits a SECOND
            # line and an empty DB reports "0\n0" — which no `= 1` comparison
            # ever noticed, but a `= 0` one fails on (HIMMEL-1879).
            if [ -f "$1" ]; then grep -c . "$1" 2>/dev/null || true; else echo 0; fi ;;
        darwin*)
            # macOS uses crontab ONLY (arm-resume.sh PLATFORM=macos), whose stub
            # store is $dir/crontab.fixture -- NOT $db (schtasks) or job-* (at).
            # Counting either of those here would always read 0 on Darwin and
            # make every slot assertion below vacuously pass (HIMMEL-1581).
            if [ -f "$2/crontab.fixture" ]; then grep -c . "$2/crontab.fixture" 2>/dev/null || true; else echo 0; fi ;;
        *)
            find "$2" -maxdepth 1 -name 'job-*' 2>/dev/null | wc -l | tr -d ' ' ;;
    esac
}

STATEFUL_STUB="$TMP/stateful-sched"
make_stateful_sched "$STATEFUL_STUB"

# ---------------------------------------------------------------------------
# T25: two DISTINCT handovers both arm — the multislot core. Under the old
#      HIMMEL-Resume-* wildcard dedup the second arm was refused (rc 3); with
#      per-$TASK_NAME dedup both succeed and TWO distinct jobs exist.
# ---------------------------------------------------------------------------
if _sec_selected "T25"; then
DB25="$TMP/db25.tasks"; DB25D="$TMP/db25.atdir"; : > "$DB25"; mkdir -p "$DB25D"
HO_A=$(make_handover "$WORK_REPO")
HO_B=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB25" SCHED_DB_DIR="$DB25D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_A" 2>&1)
rc=$?
assert_rc "T25a first distinct handover arms (rc 0)" 0 "$rc"
assert_contains "T25a arm banner printed" "RESUME ARMED" "$out"
out=$(TMPDIR="$TMP" SCHED_DB="$DB25" SCHED_DB_DIR="$DB25D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_B" 2>&1)
rc=$?
assert_rc "T25b second DISTINCT handover ALSO arms (rc 0, multislot)" 0 "$rc"
assert_contains "T25b arm banner printed" "RESUME ARMED" "$out"
assert_not_contains "T25b second distinct arm is NOT a dedup block" "already scheduled" "$out"
if [ "$(count_slots "$DB25" "$DB25D")" = "2" ]; then
    echo "PASS T25c two distinct slots coexist"
else
    echo "FAIL T25c expected 2 slots, got $(count_slots "$DB25" "$DB25D")"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T26: the SAME handover armed twice still dedups — second arm refused (rc 3),
#      one slot only. Preserves the "never two sessions for one handover"
#      invariant the original wildcard dedup enforced too broadly.
# ---------------------------------------------------------------------------
if _sec_selected "T26"; then
DB26="$TMP/db26.tasks"; DB26D="$TMP/db26.atdir"; : > "$DB26"; mkdir -p "$DB26D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB26" SCHED_DB_DIR="$DB26D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" 2>&1)
rc=$?
assert_rc "T26a same handover first arm (rc 0)" 0 "$rc"
out=$(TMPDIR="$TMP" SCHED_DB="$DB26" SCHED_DB_DIR="$DB26D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" 2>&1)
rc=$?
assert_rc "T26b same handover re-arm still blocks (rc 3)" 3 "$rc"
assert_contains "T26b dedup ERR text preserved" "already scheduled" "$out"
# HIMMEL-1297: the refusal must state the scope it actually enforces. A blurb
# that reads prefix-wide taught the operator to serialise independent tickets.
assert_contains "T26b refusal names the SAME-handover scope" "for the SAME handover" "$out"
assert_contains "T26b refusal says a different handover needs no flag" "arms concurrently with" "$out"
if [ "$(count_slots "$DB26" "$DB26D")" = "1" ]; then
    echo "PASS T26c same-handover dedup keeps exactly one slot"
else
    echo "FAIL T26c expected 1 slot, got $(count_slots "$DB26" "$DB26D")"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T27: --force replaces ONLY the same-handover job — one slot before, one
#      after (delete + recreate), never a duplicate.
# ---------------------------------------------------------------------------
if _sec_selected "T27"; then
DB27="$TMP/db27.tasks"; DB27D="$TMP/db27.atdir"; : > "$DB27"; mkdir -p "$DB27D"
HO=$(make_handover "$WORK_REPO")
TMPDIR="$TMP" SCHED_DB="$DB27" SCHED_DB_DIR="$DB27D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" >/dev/null 2>&1
out=$(TMPDIR="$TMP" SCHED_DB="$DB27" SCHED_DB_DIR="$DB27D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --force 2>&1)
rc=$?
assert_rc "T27a same handover --force re-arms (rc 0)" 0 "$rc"
if [ "$(count_slots "$DB27" "$DB27D")" = "1" ]; then
    echo "PASS T27b --force replaces in place (still one slot)"
else
    echo "FAIL T27b expected 1 slot after --force, got $(count_slots "$DB27" "$DB27D")"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T28: --dedup-any restores the broad "defer to ANY existing slot" semantics
#      the auto-arm watchdogs rely on — a DISTINCT handover is refused (rc 3)
#      when any HIMMEL-Resume job already exists, so safety arms never fan out.
# ---------------------------------------------------------------------------
if _sec_selected "T28"; then
DB28="$TMP/db28.tasks"; DB28D="$TMP/db28.atdir"; : > "$DB28"; mkdir -p "$DB28D"
HO_A=$(make_handover "$WORK_REPO")
HO_B=$(make_handover "$WORK_REPO")
TMPDIR="$TMP" SCHED_DB="$DB28" SCHED_DB_DIR="$DB28D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_A" >/dev/null 2>&1
out=$(TMPDIR="$TMP" SCHED_DB="$DB28" SCHED_DB_DIR="$DB28D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_B" --dedup-any 2>&1)
rc=$?
assert_rc "T28a --dedup-any distinct handover blocks when any slot exists (rc 3)" 3 "$rc"
assert_contains "T28a dedup ERR text preserved" "already scheduled" "$out"
# HIMMEL-1297: the broad scope refuses for a DIFFERENT reason than the default
# per-handover scope, so it must not claim the slot is the same handover's.
assert_contains "T28a refusal names the --dedup-any scope" "--dedup-any safety-arm semantics" "$out"
assert_not_contains "T28a refusal does not claim same-handover" "for the SAME handover" "$out"
# HIMMEL-1563: --force in THIS scope is NO LONGER multi-delete — it replaces
# only THIS handover's own job(s), so the refusal must say so rather than warn
# of a sibling-endangering wipe. (T28d proves the foreign siblings in fact
# survive.) Pre-1563 this asserted the opposite ("deletes EVERY") and T28d
# proved that was real; both flip together here.
assert_contains "T28a refusal says --force is own-only (HIMMEL-1563)" "replaces only THIS" "$out"
assert_not_contains "T28a no stale multi-delete warning (HIMMEL-1563)" "deletes EVERY" "$out"
# Sanity: WITHOUT --dedup-any the same distinct arm would succeed (T25 proves
# this), so the rc 3 here is the flag's doing, not a stuck scheduler.
if [ "$(count_slots "$DB28" "$DB28D")" = "1" ]; then
    echo "PASS T28b --dedup-any left the single slot untouched"
else
    echo "FAIL T28b expected 1 slot, got $(count_slots "$DB28" "$DB28D")"
    FAILED=$((FAILED + 1))
fi
# --dedup-any against an EMPTY scheduler still arms (rc 0).
DB28E="$TMP/db28e.tasks"; DB28ED="$TMP/db28e.atdir"; : > "$DB28E"; mkdir -p "$DB28ED"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB28E" SCHED_DB_DIR="$DB28ED" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T28c --dedup-any on empty scheduler arms (rc 0)" 0 "$rc"

# T28d (HIMMEL-1297, re-pointed by HIMMEL-1563): --dedup-any --force is NO
# LONGER destructive to foreign chains. Pre-1563 its broad dedup scope matched
# EVERY resume job, so the --force replace loop reaped every HIMMEL-Resume-*
# task on the box — two queued FOREIGN sibling arms (distinct handovers, not
# this one) collapsed into the single new arm, and on a multi-chain box that
# collateral-deleted another chain's armed resume (leg 44 deleted
# HIMMEL-Resume-trust-envelope-chain-06). HIMMEL-1563 narrows the --force reap
# to THIS invocation's own identity only, so a cancel/replace can never touch a
# task it did not create. The broad scope still governs the rc=3 refusal
# (T28a/T28c) — read-only — but the DELETE is own-identity.
#
# So under --dedup-any --force the two foreign sibling arms SURVIVE alongside
# the new arm (3 slots). Contrast T30: WITHOUT --dedup-any, --force was always
# scoped to the arming handover and siblings survived; HIMMEL-1563 makes the
# --dedup-any path agree.
#
# The TRANSACTIONAL contract (HIMMEL-1304: the replace runs only AFTER the new
# job is registered + verified, so the FAILURE half — slots survive when the
# arm refuses rc 7 / rc 8 or fails inside schedule_arm — holds for the
# own-identity markers) is covered by G3.1-G3.4 in test-arm-resume-identity.sh,
# which carries the create-failure injection seam this suite's stub lacks.
DB28F="$TMP/db28f.tasks"; DB28FD="$TMP/db28f.atdir"; : > "$DB28F"; mkdir -p "$DB28FD"
HO_F1=$(make_handover "$WORK_REPO")
HO_F2=$(make_handover "$WORK_REPO")
HO_F3=$(make_handover "$WORK_REPO")
# Seed the two siblings at DISTINCT minutes. They only need to coexist, not to
# share a minute, and giving them their own slots keeps this test independent of
# whether the backend under test implements exact-minute collision detection
# (HIMMEL-407): on one that does, same-minute seeds would refuse rc=6 and the
# test would fail during setup, before it ever exercised --dedup-any --force.
TMPDIR="$TMP" SCHED_DB="$DB28F" SCHED_DB_DIR="$DB28FD" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "23:57" --handover "$HO_F1" --long-gap >/dev/null 2>&1
TMPDIR="$TMP" SCHED_DB="$DB28F" SCHED_DB_DIR="$DB28FD" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "23:58" --handover "$HO_F2" --long-gap >/dev/null 2>&1
if [ "$(count_slots "$DB28F" "$DB28FD")" = "2" ]; then
    echo "PASS T28d two sibling slots queued before the --dedup-any --force arm"
else
    echo "FAIL T28d expected 2 slots before force, got $(count_slots "$DB28F" "$DB28FD")"
    FAILED=$((FAILED + 1))
fi
_slot_ids() {   # echo one HIMMEL-Resume-* identity per recorded slot
    case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
        msys*|cygwin*|win32*|MINGW*) grep -ho 'HIMMEL-Resume-[^[:space:]"]*' "$DB28F" 2>/dev/null || true ;;
        # Darwin: crontab, not at — same store as count_slots reads. Without
        # this branch the recursive grep below sweeps $DB28FD and would happen
        # to find crontab.fixture too, but only by accident; naming the store
        # keeps the two helpers reading the SAME place (HIMMEL-1581).
        darwin*) grep -ho 'HIMMEL-Resume-[^[:space:]"]*' "$DB28FD/crontab.fixture" 2>/dev/null || true ;;
        *) grep -rho 'HIMMEL-Resume-[^[:space:]"]*' "$DB28FD" 2>/dev/null || true ;;
    esac
}
# Snapshot the two siblings' identities BEFORE the force, so the post-check can
# prove the survivor is the new arm rather than one of them.
_ids_before=$(_slot_ids | sort -u)
out=$(TMPDIR="$TMP" SCHED_DB="$DB28F" SCHED_DB_DIR="$DB28FD" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_F3" --dedup-any --force 2>&1)
rc=$?
assert_rc "T28d --dedup-any --force arms (rc 0)" 0 "$rc"
# HIMMEL-1563: the foreign sibling arms SURVIVE. Pre-1563 the broad scope made
# --force reap every HIMMEL-Resume-* job, collapsing both siblings into the one
# new arm (1 slot). Now the force replace is scoped to THIS handover's own
# job(s), so the two FOREIGN siblings are untouched and coexist with the new
# arm: 3 slots. (On main this is 1 → FAIL; the headline 1563 regression.)
if [ "$(count_slots "$DB28F" "$DB28FD")" = "3" ]; then
    echo "PASS T28d --dedup-any --force leaves both foreign siblings + the new arm (3 slots, HIMMEL-1563)"
else
    echo "FAIL T28d expected 3 slots after --dedup-any --force (2 siblings + new arm), got $(count_slots "$DB28F" "$DB28FD")"
    FAILED=$((FAILED + 1))
fi
# Cardinality alone is not enough: assert every sibling identity captured
# BEFORE the force is STILL present (foreign arms survived), AND exactly one
# NEW identity (the HO_F3 arm) joined them. Compares recorded HIMMEL-Resume-*
# identities rather than re-deriving the task name here, so this stays correct
# if the name composition ever changes.
_ids_after=$(_slot_ids | sort -u)
_missing=0
while IFS= read -r _id; do
    [ -z "$_id" ] && continue
    grepq "$_ids_after" -xF "$_id" || _missing=$((_missing + 1))
done <<< "$_ids_before"
_new=0
while IFS= read -r _id; do
    [ -z "$_id" ] && continue
    grepq "$_ids_before" -xF "$_id" || _new=$((_new + 1))
done <<< "$_ids_after"
if [ "$_missing" = "0" ] && [ "$_new" = "1" ]; then
    echo "PASS T28d both sibling identities survived + 1 new arm identity (HIMMEL-1563)"
else
    echo "FAIL T28d identity check: missing=$_missing new=$_new (before='$(printf '%s' "$_ids_before" | tr '\n' ',')' after='$(printf '%s' "$_ids_after" | tr '\n' ',')')"
    FAILED=$((FAILED + 1))
fi

# T28e (HIMMEL-1581): a Darwin CANARY for the two helpers above, not a Darwin
# run of T28d. On macOS arm-resume schedules through crontab ONLY, so before
# this ticket count_slots/_slot_ids — which knew about the schtasks db and the
# `at` job-* store and nothing else — read 0/empty there and every slot
# assertion in this section passed VACUOUSLY. The real acceptance test is a
# macOS run, which this box cannot perform; what CAN be proven here is that the
# darwin* branches read the crontab fixture the stub actually writes. OSTYPE is
# set per-call (bash restores it after), and DB28F/DB28FD are re-pointed at
# throwaway paths — safe because every T28 assertion above is already done.
DB28F="$TMP/db28e.tasks"; DB28FD="$TMP/db28e.atdir"; mkdir -p "$DB28FD"
printf '%s\n%s\n' \
    '57 23 * * * cmd HIMMEL-Resume-canary-one' \
    '58 23 * * * cmd HIMMEL-Resume-canary-two' > "$DB28FD/crontab.fixture"
_darwin_slots=$(OSTYPE=darwin23 count_slots "$DB28F" "$DB28FD")
if [ "$_darwin_slots" = "2" ]; then
    echo "PASS T28e count_slots reads the crontab fixture on Darwin (2 slots)"
else
    echo "FAIL T28e count_slots on Darwin: expected 2 slots, got '$_darwin_slots' (vacuous-pass gap)"
    FAILED=$((FAILED + 1))
fi
_darwin_ids=$(OSTYPE=darwin23 _slot_ids | sort -u | tr '\n' ' ')
if [ "$_darwin_ids" = "HIMMEL-Resume-canary-one HIMMEL-Resume-canary-two " ]; then
    echo "PASS T28e _slot_ids reads the crontab fixture on Darwin"
else
    echo "FAIL T28e _slot_ids on Darwin: got '$_darwin_ids'"
    FAILED=$((FAILED + 1))
fi
# The stub itself must exist, or a Darwin run escapes the fixture into the
# operator's machine-wide crontab (the HIMMEL-1567 hazard, in this suite).
if [ -x "$STATEFUL_STUB/crontab" ]; then
    echo "PASS T28e make_stateful_sched installs a crontab stub"
else
    echo "FAIL T28e make_stateful_sched has no executable crontab stub — a Darwin run would touch the real crontab"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T29: soft slot cap (HIMMEL-340 decision: WARN, never block). With
#      ARM_MAX_SLOTS=2, arming a third distinct handover still succeeds
#      (rc 0) but emits a soft-cap WARN naming the count; arms below the cap
#      stay silent.
# ---------------------------------------------------------------------------
if _sec_selected "T29"; then
DB29="$TMP/db29.tasks"; DB29D="$TMP/db29.atdir"; : > "$DB29"; mkdir -p "$DB29D"
HO1=$(make_handover "$WORK_REPO")
HO2=$(make_handover "$WORK_REPO")
HO3=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" ARM_MAX_SLOTS=2 SCHED_DB="$DB29" SCHED_DB_DIR="$DB29D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO1" 2>&1)
assert_not_contains "T29a first arm below cap — no soft-cap warn" "soft cap" "$out"
out=$(TMPDIR="$TMP" ARM_MAX_SLOTS=2 SCHED_DB="$DB29" SCHED_DB_DIR="$DB29D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO2" 2>&1)
assert_not_contains "T29b arm reaching cap (2/2) — no soft-cap warn" "soft cap" "$out"
out=$(TMPDIR="$TMP" ARM_MAX_SLOTS=2 SCHED_DB="$DB29" SCHED_DB_DIR="$DB29D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO3" 2>&1)
rc=$?
assert_rc "T29c arm exceeding soft cap still succeeds (rc 0)" 0 "$rc"
assert_contains "T29c arm exceeding soft cap WARNs" "soft cap" "$out"
# The over-cap arm WARNs but must still create the slot (warn ≠ block).
if [ "$(count_slots "$DB29" "$DB29D")" = "3" ]; then
    echo "PASS T29d over-cap arm still created the slot (3 total)"
else
    echo "FAIL T29d expected 3 slots after over-cap arm, got $(count_slots "$DB29" "$DB29D")"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T30: --force on a GENUINE multislot scenario replaces ONLY the targeted
#      handover — two distinct slots, --force re-arm one, still TWO slots. A
#      regression to the legacy broad-scope delete (wiping siblings) would
#      pass T27 (single slot) but fail here — the precise wipe HIMMEL-340 kills.
# ---------------------------------------------------------------------------
if _sec_selected "T30"; then
DB30="$TMP/db30.tasks"; DB30D="$TMP/db30.atdir"; : > "$DB30"; mkdir -p "$DB30D"
HO_A=$(make_handover "$WORK_REPO")
HO_B=$(make_handover "$WORK_REPO")
TMPDIR="$TMP" SCHED_DB="$DB30" SCHED_DB_DIR="$DB30D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_A" >/dev/null 2>&1
TMPDIR="$TMP" SCHED_DB="$DB30" SCHED_DB_DIR="$DB30D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_B" >/dev/null 2>&1
out=$(TMPDIR="$TMP" SCHED_DB="$DB30" SCHED_DB_DIR="$DB30D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_A" --force 2>&1)
rc=$?
assert_rc "T30a --force re-arm of one of two distinct slots (rc 0)" 0 "$rc"
if [ "$(count_slots "$DB30" "$DB30D")" = "2" ]; then
    echo "PASS T30b --force replaced ONLY the targeted handover (sibling survived, 2 slots)"
else
    echo "FAIL T30b expected 2 slots (sibling preserved), got $(count_slots "$DB30" "$DB30D")"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T31: prefix-named task collision — the dedup match is whole-line/exact, so a
#      handover whose sanitized $TASK_NAME is a strict PREFIX of another's must
#      not cross-match. The discriminating order is LONGER-first: arm the
#      superset name, then arm the prefix name — under a regression from the
#      exact `grep -Fx` to substring `grep -F`, the prefix name's marker would
#      be found *inside* the superset's marker and falsely deduped (rc 3). With
#      the exact match it must arm (rc 0). Names are EXTENSIONLESS so the
#      sanitizer (tr -cd '[:alnum:]_-', which strips '.') can't insert a char
#      that breaks the prefix relationship (e.g. job.md→jobmd vs jobx.md→jobxmd
#      is NOT a prefix pair — the spurious-green trap a prior version fell into).
# ---------------------------------------------------------------------------
if _sec_selected "T31"; then
DB31="$TMP/db31.tasks"; DB31D="$TMP/db31.atdir"; : > "$DB31"; mkdir -p "$DB31D"
# Sanitized task names: ...pfxcollide_jobcollide  (prefix)
#                       ...pfxcollide_jobcollidex (strict superset — extra 'x')
PFX_DIR="$HANDOVER_DIR/pfxcollide"; mkdir -p "$PFX_DIR"
HO_SHORT="$PFX_DIR/jobcollide"; HO_LONG="$PFX_DIR/jobcollidex"
for _f in "$HO_SHORT" "$HO_LONG"; do
    printf -- '---\nsession_kind: test\n---\n# prefix collision handover\n' > "$_f"
done
# Arm the LONGER (superset) name first so the prefix arm below is the one a
# substring regression would falsely match.
out=$(TMPDIR="$TMP" SCHED_DB="$DB31" SCHED_DB_DIR="$DB31D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_LONG" 2>&1)
assert_rc "T31a superset handover 'jobcollidex' arms (rc 0)" 0 "$?"
# The PREFIX name must ALSO arm — exact match means it does not collide with the
# superset already present. (Substring grep -F regression → false rc 3 here.)
out=$(TMPDIR="$TMP" SCHED_DB="$DB31" SCHED_DB_DIR="$DB31D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_SHORT" 2>&1)
assert_rc "T31b prefix handover 'jobcollide' also arms — no substring cross-match (rc 0)" 0 "$?"
if [ "$(count_slots "$DB31" "$DB31D")" = "2" ]; then
    echo "PASS T31c both prefix-related handovers coexist (2 slots)"
else
    echo "FAIL T31c expected 2 slots, got $(count_slots "$DB31" "$DB31D")"
    FAILED=$((FAILED + 1))
fi
# Re-arming the prefix name must dedup ONLY itself (rc 3), proving exact match.
out=$(TMPDIR="$TMP" SCHED_DB="$DB31" SCHED_DB_DIR="$DB31D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_SHORT" 2>&1)
assert_rc "T31d re-arm 'jobcollide' dedups exactly itself (rc 3)" 3 "$?"
fi

# ---------------------------------------------------------------------------
# T32: the relaunch is SELF-CLEANING — the spawned launcher deletes its own
#      scheduler entry as its first action so a fired /sc ONCE task (or a
#      recurring crontab entry) never lingers to block a same-handover re-arm
#      or fire twice. --force --dry-run isolates from the live scheduler and
#      prints the launcher body. Platform-branched: schtasks .bat carries a
#      self-/delete; the crontab fallback entry self-removes its marker line;
#      the at path needs nothing (atd auto-removes one-shot jobs).
# ---------------------------------------------------------------------------
if _sec_selected "T32"; then
HO=$(make_handover "$WORK_REPO")
out=$(bash "$ARM" --time "$(future_time)" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T32 self-clean dry-run exits 0" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        assert_contains "T32 .bat self-deletes its own task" 'schtasks /delete /tn "HIMMEL-Resume-' "$out"
        # The delete must be the FIRST line of the .bat body (not merely
        # somewhere before cd) — extract the first body line printed after the
        # ".bat content:" header and assert it is the delete. A weaker "before
        # cd" check would still pass if a future edit inserted a command
        # between the delete and cd.
        first_bat_line=$(printf '%s\n' "$out" | awk '/\.bat content:/{getline; print; exit}')
        assert_contains "T32 self-delete is the FIRST .bat line" "schtasks /delete" "$first_bat_line"
        ;;
    *)
        if command -v at >/dev/null 2>&1; then
            # at queue auto-removes the job after it runs, so the body must
            # carry NO self-delete line — adding one would be wrong.
            assert_contains "T32 at body emitted" "would at -t" "$out"
            assert_not_contains "T32 at body has no spurious self-delete" "schtasks /delete" "$out"
        else
            # crontab fallback: the entry self-removes its own marker line
            # first, ANCHORED (grep -vE …$) so a prefix-related sibling
            # survives — must NOT regress to the unanchored grep -vF.
            assert_contains "T32 crontab entry self-removes its marker (anchored)" "grep -vE '# HIMMEL-Resume-" "$out"
            assert_not_contains "T32 crontab self-clean is not unanchored grep -vF" "grep -vF '# HIMMEL-Resume-" "$out"
            assert_contains "T32 crontab note says one-shot" "self-removes on first fire" "$out"
        fi
        ;;
esac
fi

# ---------------------------------------------------------------------------
# T33: --automerge (HIMMEL-1382) wires ARMAUTOMERGE=1 + CR_MERGE_GATE_OK=1 into
#      the relaunched session's environment BEFORE invoking claude — opt-in
#      only. Fix round: every generated launch body ALWAYS clears both vars
#      first (defense against ambient-env carryover, e.g. `at` snapshotting
#      the submitting shell's env), then conditionally re-grants them ONLY
#      when --automerge was explicit on THIS arm. So the default (no
#      --automerge) body now contains the CLEAR form but never the GRANT
#      ("=1") form.
# ---------------------------------------------------------------------------
if _sec_selected "T33"; then
HO=$(make_handover "$WORK_REPO")
out=$(bash "$ARM" --time "$(future_time)" --handover "$HO" --automerge --force --dry-run 2>&1)
rc=$?
assert_rc "T33a --automerge dry-run exits 0" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        assert_contains "T33a .bat sets ARMAUTOMERGE=1" 'set "ARMAUTOMERGE=1"' "$out"
        assert_contains "T33a .bat sets CR_MERGE_GATE_OK=1" 'set "CR_MERGE_GATE_OK=1"' "$out"
        ;;
    *)
        assert_contains "T33a launch command carries ARMAUTOMERGE=1" "ARMAUTOMERGE=1" "$out"
        assert_contains "T33a launch command carries CR_MERGE_GATE_OK=1" "CR_MERGE_GATE_OK=1" "$out"
        ;;
esac

HO=$(make_handover "$WORK_REPO")
out=$(bash "$ARM" --time "$(future_time)" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T33b default (no --automerge) dry-run exits 0" 0 "$rc"
# HIMMEL-2254: assert the GRANT FORM, not the bare substring. The
# HIMMEL-2128 advisory WARN ("will NOT set ARMAUTOMERGE=1") is printed on
# stderr on exactly this path and 2>&1 folds it into "$out", so a bare
# not-contains on "ARMAUTOMERGE=1" fails on the very behaviour it is
# supposed to confirm. What must be absent is the grant the ARMED SESSION
# would receive.
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        assert_not_contains "T33b default does not GRANT ARMAUTOMERGE=1" 'set "ARMAUTOMERGE=1"' "$out"
        assert_not_contains "T33b default does not GRANT CR_MERGE_GATE_OK=1" 'set "CR_MERGE_GATE_OK=1"' "$out"
        assert_contains "T33b default still CLEARS ARMAUTOMERGE (defense-in-depth)" 'set "ARMAUTOMERGE="' "$out"
        assert_contains "T33b default still CLEARS CR_MERGE_GATE_OK (defense-in-depth)" 'set "CR_MERGE_GATE_OK="' "$out"
        ;;
    *)
        assert_not_contains "T33b default does not GRANT ARMAUTOMERGE/CR_MERGE_GATE_OK" "ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1 claude" "$out"
        assert_contains "T33b default still CLEARS both vars (defense-in-depth)" "unset ARMAUTOMERGE CR_MERGE_GATE_OK" "$out"
        ;;
esac
fi

# ---------------------------------------------------------------------------
# T33c: two-hop cap re-arm (HIMMEL-1382 fix round). Hop 1 arms WITH
#       --automerge. Hop 2 mirrors auto-arm-on-cap.sh's own invocation shape
#       (--dedup-any, NO --automerge, a DIFFERENT handover — a cap re-arm is
#       never the arm that asked) using the SCHED_STUB_T17 empty-scheduler
#       stub so the query sees no existing job and proceeds instead of
#       dedup-blocking. The hop-2 job body must explicitly CLEAR both vars
#       and must NOT set either to "1" — the grant must not leak across the
#       automatic re-arm, regardless of what hop 1's ambient env carried.
# ---------------------------------------------------------------------------
if _sec_selected "T33c"; then
HO1=$(make_handover "$WORK_REPO")
out=$(bash "$ARM" --time "$(future_time)" --handover "$HO1" --automerge --force --dry-run 2>&1)
rc=$?
assert_rc "T33c hop-1 (--automerge) dry-run exits 0" 0 "$rc"

HO2=$(make_handover "$WORK_REPO")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --dedup-any --time "$(future_time)" --handover "$HO2" --dry-run 2>&1)
rc=$?
assert_rc "T33c hop-2 (simulated auto-arm-on-cap re-arm, no --automerge) dry-run exits 0" 0 "$rc"
# HIMMEL-2254: grant-form assertions, not bare substrings — see the T33b
# comment above for why.
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        assert_not_contains "T33c hop-2 does not GRANT ARMAUTOMERGE=1" 'set "ARMAUTOMERGE=1"' "$out"
        assert_not_contains "T33c hop-2 does not GRANT CR_MERGE_GATE_OK=1" 'set "CR_MERGE_GATE_OK=1"' "$out"
        assert_contains "T33c hop-2 CLEARS ARMAUTOMERGE" 'set "ARMAUTOMERGE="' "$out"
        assert_contains "T33c hop-2 CLEARS CR_MERGE_GATE_OK" 'set "CR_MERGE_GATE_OK="' "$out"
        ;;
    *)
        assert_not_contains "T33c hop-2 does not GRANT ARMAUTOMERGE/CR_MERGE_GATE_OK" "ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1 claude" "$out"
        assert_contains "T33c hop-2 CLEARS both vars" "unset ARMAUTOMERGE CR_MERGE_GATE_OK" "$out"
        ;;
esac
fi

# ---------------------------------------------------------------------------
# T38: ARM_RESUME_SAFETY_ARM sticky-exemption clear (HIMMEL-1475 CR-fix). The
#      automated safety callers (auto-arm-on-cap.sh, spawn-glm) set
#      ARM_RESUME_SAFETY_ARM=1 in their child env so the long-gap guard exempts
#      their multi-hour cap-reset arm. On Linux `at` snapshots the submitter
#      env, so WITHOUT a clear in the launch body the RESUMED claude session
#      inherits =1 and every later far HH:MM arm it makes silently bypasses the
#      guard. Every generated launch body must CLEAR ARM_RESUME_SAFETY_ARM
#      alongside ARMAUTOMERGE/CR_MERGE_GATE_OK — the exemption is for THIS
#      safety arm only, never a property the resumed session keeps. Mirrors how
#      the ARMAUTOMERGE unset is tested (T33b/c).
# ---------------------------------------------------------------------------
if _sec_selected "T38"; then
HO=$(make_handover "$WORK_REPO")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" ARM_RESUME_SAFETY_ARM=1 \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "T38 safety-arm dry-run exits 0" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        assert_contains "T38 .bat CLEARS ARM_RESUME_SAFETY_ARM (sticky-exemption)" 'set "ARM_RESUME_SAFETY_ARM="' "$out"
        ;;
    *)
        assert_contains "T38 launch body unsets ARM_RESUME_SAFETY_ARM (sticky-exemption)" "unset ARMAUTOMERGE CR_MERGE_GATE_OK ARM_RESUME_SAFETY_ARM" "$out"
        ;;
esac
# The exemption VALUE is never granted to the resumed session — only cleared.
assert_not_contains "T38 body does not grant ARM_RESUME_SAFETY_ARM=1" "ARM_RESUME_SAFETY_ARM=1" "$out"
fi

# ---------------------------------------------------------------------------
# W1-W5: --worktree isolation for code arms (HIMMEL-387)
# ---------------------------------------------------------------------------
if _sec_selected "W1-W8" "W1" "W2" "W3" "W4" "W5" "W6" "W7" "W8"; then
# W1: --worktree dry-run computes the type+slug path, resumes there, pre-trusts it.
HO=$(make_handover "")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-test --dry-run 2>&1)
rc=$?
assert_rc "W1 --worktree dry-run exits 0" 0 "$rc"
assert_contains "W1 announces worktree create" "would create worktree 'feat/wt-test'" "$out"
assert_contains "W1 path uses type+slug dir" ".claude/worktrees/feat+wt-test" "$out"
assert_contains "W1 RESUME_CWD set to worktree" "RESUME_CWD=" "$out"
assert_contains "W1 pre-trusts the worktree (HIMMEL-386 wiring)" "would pre-trust workspace" "$out"

# W2: invalid branch (no type/slug) → loud rc 1, no scheduler touched.
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree not-valid --dry-run 2>&1)
rc=$?
assert_rc "W2 invalid worktree branch exits 1" 1 "$rc"
assert_contains "W2 explains type/slug requirement" "must be type/slug" "$out"

# W3: --cwd and --worktree together → rc 1 (the worktree IS the cwd).
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-test --cwd "$WORK_REPO" --dry-run 2>&1)
rc=$?
assert_rc "W3 --cwd + --worktree exits 1" 1 "$rc"
assert_contains "W3 says mutually exclusive" "mutually exclusive" "$out"

# W4: resume_worktree frontmatter used when the flag is omitted.
HO_WT="$HANDOVER_DIR/handover-wt-fm.md"
{ printf -- '---\n'; printf 'resume_worktree: fix/wt-fm\n'; printf -- '---\n'; printf '# fm worktree\n'; } > "$HO_WT"
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_WT" --dry-run 2>&1)
rc=$?
assert_rc "W4 resume_worktree frontmatter exits 0" 0 "$rc"
assert_contains "W4 frontmatter worktree used" ".claude/worktrees/fix+wt-fm" "$out"

# W5: non-dry-run — a stub worktree cmd creates the dir; the arm resumes there
# and pre-trusts the worktree path in the (shielded) config.
WT_STUB="$TMP/wt-stub.sh"
# The literal $ARM_WORKTREE_PATH is intentional — the stub expands it at runtime.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nmkdir -p "$ARM_WORKTREE_PATH"\n' > "$WT_STUB"
chmod +x "$WT_STUB"
HO=$(make_handover "")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_STUB" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-real 2>&1)
rc=$?
assert_rc "W5 non-dry worktree arm exits 0" 0 "$rc"
# The non-dry arm doesn't echo RESUME_CWD (that's dry-run only); proof the
# worktree path was used as cwd is that it got pre-trusted in the config below.
if command -v node >/dev/null 2>&1; then
    trust=$(WT_F="$WORKSPACE_TRUST_CONFIG" node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.env.WT_F,"utf8"));const hit=Object.entries(j.projects||{}).some(([k,v])=>k.includes("feat+wt-real")&&v&&v.hasTrustDialogAccepted===true);process.stdout.write(String(hit))}catch(e){process.stdout.write("ERR")}')
    assert_contains "W5 worktree pre-trusted in config" "true" "$trust"
fi
# Tidy the empty stub-created worktree dir (gitignored, but don't leave litter).
rm -rf "$(cd "$(dirname "$ARM")/../.." && pwd)/.claude/worktrees/feat+wt-real" 2>/dev/null || true

# Stub worktree commands (real scripts — an inline `bash -c '...'` would be
# word-split by the seam's intentional cmd+args split, mangling the quotes).
WT_FAIL_STUB="$TMP/wt-fail-stub.sh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$WT_FAIL_STUB"; chmod +x "$WT_FAIL_STUB"
WT_NODIR_STUB="$TMP/wt-nodir-stub.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$WT_NODIR_STUB"; chmod +x "$WT_NODIR_STUB"

# W6: worktree cmd fails → arm aborts loudly with rc 4 (no silent half-arm).
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_FAIL_STUB" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-fail 2>&1)
rc=$?
assert_rc "W6 worktree create failure exits 4" 4 "$rc"
assert_contains "W6 reports create failure" "worktree create failed" "$out"

# W7: worktree cmd returns 0 but creates no dir → post-create check exits 4.
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_NODIR_STUB" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-nodir 2>&1)
rc=$?
assert_rc "W7 create-but-no-dir exits 4" 4 "$rc"
assert_contains "W7 reports missing worktree dir" "expected worktree dir not found" "$out"

# W8: existing worktree dir → reused (create cmd NOT invoked), arm still succeeds.
# The stub would exit 1 IF called; rc 0 proves the reuse branch skipped it.
W8_DIR="$(cd "$(dirname "$ARM")/../.." && pwd)/.claude/worktrees/feat+wt-reuse"
mkdir -p "$W8_DIR"
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_FAIL_STUB" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/wt-reuse 2>&1)
rc=$?
assert_rc "W8 reuse existing worktree exits 0 (cmd not called)" 0 "$rc"
assert_contains "W8 announces reuse" "reusing existing worktree" "$out"
rm -rf "$W8_DIR"
fi

# ---------------------------------------------------------------------------
# T33-T37: time-collision check (HIMMEL-407)
#
# These tests use the ARM_COLLISION_CANDIDATES seam (set to "<name>\t<HH:MM>"
# lines, empty string = no candidates) so they never touch the real scheduler
# and run on every platform. The stateful stub from T25-T31 is reused for the
# database (so the dedup block doesn't interfere with the collision check).
#
# make_stateful_sched already ran above; STATEFUL_STUB is set.
# ---------------------------------------------------------------------------

# Helper: build a stub HIMMEL-Pipeline-Harvest candidate at a given HH:MM.
# We need a fresh stateful DB per test so dedup doesn't bleed.
_collision_db() { printf '%s' "$TMP/coll-db-$RANDOM"; }
_collision_dbdir() { printf '%s' "$TMP/coll-dbdir-$RANDOM"; }

# ---------------------------------------------------------------------------
# T33: EXACT collision → rc=6 + ERR text + free-slot suggestion.
#      The stateful scheduler has an EMPTY db so the dedup block doesn't fire.
# ---------------------------------------------------------------------------
if _sec_selected "T33" "T33-collision"; then
DB33=$(_collision_db); DB33D=$(_collision_dbdir); : > "$DB33"; mkdir -p "$DB33D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB33" SCHED_DB_DIR="$DB33D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --long-gap --dry-run 2>&1)
rc=$?
assert_rc "T33 exact collision refuses (rc 6)" 6 "$rc"
assert_contains "T33 ERR names the collision" "time collision" "$out"
assert_contains "T33 ERR names the colliding task" "HIMMEL-Pipeline-Harvest" "$out"
assert_contains "T33 ERR mentions concurrent claude sessions" "claude sessions" "$out"
assert_contains "T33 free-slot suggestion printed" "Suggested free slots:" "$out"
assert_contains "T33 --force note printed" "--force" "$out"
fi

# ---------------------------------------------------------------------------
# T34: NEAR collision (within window, not exact) → rc=0 + WARN.
#      Request 02:03, candidate at 02:00 (3 min away, within default 5-min window).
# ---------------------------------------------------------------------------
if _sec_selected "T34"; then
DB34=$(_collision_db); DB34D=$(_collision_dbdir); : > "$DB34"; mkdir -p "$DB34D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB34" SCHED_DB_DIR="$DB34D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:03" --handover "$HO" --long-gap --dry-run 2>&1)
rc=$?
assert_rc "T34 near collision still exits 0 (warn-only)" 0 "$rc"
assert_contains "T34 WARN printed for near collision" "WARN arm-resume: near time collision" "$out"
assert_contains "T34 WARN names the colliding task" "HIMMEL-Pipeline-Harvest" "$out"
assert_not_contains "T34 no ERR text on near collision" "ERR arm-resume: time collision" "$out"
fi

# ---------------------------------------------------------------------------
# T35: OUTSIDE window → rc=0, no warn, no ERR.
#      Request 02:10, candidate at 02:00 (10 min away, outside default 5-min window).
# ---------------------------------------------------------------------------
if _sec_selected "T35"; then
DB35=$(_collision_db); DB35D=$(_collision_dbdir); : > "$DB35"; mkdir -p "$DB35D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB35" SCHED_DB_DIR="$DB35D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:10" --handover "$HO" --long-gap --dry-run 2>&1)
rc=$?
assert_rc "T35 outside window exits 0 silently" 0 "$rc"
assert_not_contains "T35 no collision warn outside window" "collision" "$out"
fi

# ---------------------------------------------------------------------------
# T36: --force bypasses EXACT collision → rc=0 + override WARN (not ERR).
# ---------------------------------------------------------------------------
if _sec_selected "T36"; then
DB36=$(_collision_db); DB36D=$(_collision_dbdir); : > "$DB36"; mkdir -p "$DB36D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB36" SCHED_DB_DIR="$DB36D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --long-gap --force --dry-run 2>&1)
rc=$?
assert_rc "T36 --force bypasses exact collision (rc 0)" 0 "$rc"
assert_not_contains "T36 no ERR on --force collision bypass" "ERR arm-resume: time collision" "$out"
assert_contains "T36 --force emits override WARN" "WARN arm-resume: --force: ignoring exact time collision" "$out"
fi

# ---------------------------------------------------------------------------
# T37: --dedup-any (unattended watchdog) exact collision → WARN-ONLY (rc=0),
#      never refuses. Ensures unattended watchdog arms always succeed even when
#      another HIMMEL-* task fires at the same time. ARM_RESUME_SAFETY_ARM=1 is
#      the watchdog's guard-exemption signal (HIMMEL-1475 CR-fix: --dedup-any
#      is dedup-scope only and no longer bypasses the long-gap guard, so a real
#      safety arm — auto-arm-on-cap.sh — sets this env var; this simulation
#      mirrors it). The collision check's own --dedup-any warn-only behavior is
#      what T37 actually asserts; the env var just gets it past the guard.
# ---------------------------------------------------------------------------
if _sec_selected "T37"; then
DB37=$(_collision_db); DB37D=$(_collision_dbdir); : > "$DB37"; mkdir -p "$DB37D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB37" SCHED_DB_DIR="$DB37D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    ARM_RESUME_SAFETY_ARM=1 \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "T37 --dedup-any exact collision is warn-only (rc 0)" 0 "$rc"
assert_not_contains "T37 no ERR on --dedup-any collision" "ERR arm-resume: time collision" "$out"
assert_contains "T37 --dedup-any emits WARN for exact collision" "WARN arm-resume: exact time collision" "$out"
fi

# ---------------------------------------------------------------------------
# N1-N6: ticket-in-name + ticket-aware dedup/collision (HIMMEL-540)
#
# The scheduler task name now carries the inferred ticket ID:
#   HIMMEL-Resume-<TICKET>-<path-suffix>     (ticket inferable)
#   HIMMEL-Resume-[<slug>-]<path-suffix>     (no ticket; HIMMEL-716 also welds
#                                            the handover slug when derivable)
# Every dry-run name check runs with SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" so
# list_existing hits the empty stub, not the real scheduler (a live armed job
# would otherwise spuriously rc 3). The asserted substring HIMMEL-Resume-HIMMEL-540-
# is interpolated whole into the dry-run scheduler line on every platform.
# make_handover STAYS ticketless — these positive cases use make_handover_titled.
# ---------------------------------------------------------------------------
if _sec_selected "N1-N8" "N1" "N2" "N3" "N4" "N5" "N6" "N7" "N8"; then

# N1: ticket: front-matter (src-1) → exact HIMMEL-Resume-HIMMEL-540- segment.
HO=$(make_handover_titled "Test handover" "HIMMEL-540")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N1 ticket: frontmatter arm exits 0" 0 "$rc"
assert_contains "N1 name carries the front-matter ticket" "HIMMEL-Resume-HIMMEL-540-" "$out"

# N2: H1-title-derived (src-3), no front-matter → exact ticket segment.
HO=$(make_handover_titled "Resume: foo HIMMEL-540 (bar)")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N2 H1-title-derived arm exits 0" 0 "$rc"
assert_contains "N2 name carries the H1-title ticket" "HIMMEL-Resume-HIMMEL-540-" "$out"

# N3: worktree branch (src-2), REAL LOWERCASE form feat/himmel-540-x →
# uppercased HIMMEL-540 in the name. Proves src-2 normalizes AND that inference
# runs after the relocated TASK_NAME build (the F3 ordering guard: at the old
# line 491, the frontmatter/CLI worktree branch was resolved but the name was
# built before it). Asserts the portable substring (not a Windows-only line).
HO=$(make_handover "")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/himmel-540-x --dry-run 2>&1)
rc=$?
assert_rc "N3 worktree-branch arm exits 0" 0 "$rc"
assert_contains "N3 lowercase branch ticket is uppercased into the name" "HIMMEL-Resume-HIMMEL-540-" "$out"

# N4: ticketless fallback → current HIMMEL-Resume-<path-suffix> form, NO doubled
# HIMMEL-...HIMMEL- segment (no regression for arms with no inferable ticket).
HO=$(make_handover_titled "Test handover")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N4 ticketless arm exits 0" 0 "$rc"
assert_contains "N4 name keeps the HIMMEL-Resume- prefix" "HIMMEL-Resume-" "$out"
assert_not_contains "N4 no ticket segment for a ticketless handover" "HIMMEL-Resume-HIMMEL-" "$out"

# N5: body-mention-not-title — H1 has no key, a body line mentions LUNA-9. The
# H1-only scan must NOT pick up the body key (a stray reference can't be welded
# into the scheduler name). Falls back to the path-only name.
HO=$(make_handover_titled "No ticket title" "" "see LUNA-9 for context")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N5 body-mention arm exits 0" 0 "$rc"
assert_not_contains "N5 body LUNA-9 is NOT welded into the name" "HIMMEL-Resume-LUNA-9-" "$out"
assert_not_contains "N5 no ticket segment at all (H1 had no key)" "HIMMEL-Resume-HIMMEL-" "$out"

# N6: collision (HIMMEL-407) is unbroken by the doubled-HIMMEL- name. A
# ticket-bearing handover whose TASK_NAME is HIMMEL-Resume-HIMMEL-540-... still
# HARD-REFUSES (rc 6) on an exact-minute collision with a DIFFERENT HIMMEL task.
# Stateful stub + fresh empty DB so the dedup block doesn't fire first; the
# ARM_COLLISION_CANDIDATES seam supplies a different task at the same minute.
# (Self-exclusion is NOT asserted: the seam returns verbatim BEFORE the real
# name-parse/self-exclude, so it is unreachable here by construction.)
DBN6=$(_collision_db); DBN6D=$(_collision_dbdir); : > "$DBN6"; mkdir -p "$DBN6D"
HO=$(make_handover_titled "Resume: HIMMEL-540 collision case")
out=$(TMPDIR="$TMP" SCHED_DB="$DBN6" SCHED_DB_DIR="$DBN6D" SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --long-gap --dry-run 2>&1)
rc=$?
assert_rc "N6 collision still HARD-REFUSES with a ticket-prefixed name (rc 6)" 6 "$rc"
assert_contains "N6 ERR names the collision" "time collision" "$out"

# N7: ticket: front-matter with surrounding quotes AND CRLF line endings — src-1
# reuses the exact rtrim-then-unquote idiom T5/T6/T7 prove fragile for resume_cwd:
# on Windows-authored YAML. A `ticket: "HIMMEL-540"\r` must still resolve.
HO_N7="$HANDOVER_DIR/ho-n7-crlf-$RANDOM.md"
printf -- '---\r\nsession_kind: test\r\nticket: "HIMMEL-540"\r\n---\r\n# No key in title\r\n' > "$HO_N7"
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_N7" --dry-run 2>&1)
rc=$?
assert_rc "N7 quoted+CRLF ticket: arm exits 0" 0 "$rc"
assert_contains "N7 quoted+CRLF ticket: resolves into the name" "HIMMEL-Resume-HIMMEL-540-" "$out"
# The needle targets the task-NAME context (Resume-HIMMEL-540") — a bare
# 'HIMMEL-540"' now legitimately appears as the closing quote of the HIMMEL-702
# `-n "HIMMEL-540"` session-title arg on the Windows .bat launch line, so a
# whole-output match would false-fail. A leaked YAML quote would weld INTO the
# task name (HIMMEL-Resume-HIMMEL-540"…), which this still catches.
assert_not_contains "N7 no stray quote/CR welded into the task name" 'Resume-HIMMEL-540"' "$out"

# N8: malformed multi-dash ticket: value is REJECTED by _validate_key (anchored
# ^<KEY>-<NUM>$) — falls back to the path-only name, no junk segment.
HO_N8=$(make_handover_titled "No key title" "ABC-123-456")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_N8" --dry-run 2>&1)
rc=$?
assert_rc "N8 malformed multi-dash ticket: arm exits 0" 0 "$rc"
assert_not_contains "N8 malformed key is not welded into the name" "HIMMEL-Resume-ABC-123" "$out"
assert_contains "N8 falls back to the HIMMEL-Resume- path-only prefix" "HIMMEL-Resume-" "$out"
fi

# ---------------------------------------------------------------------------
# S1-S3 (HIMMEL-702): the relaunch bakes `claude -n "<TICKET> <name>"` so an
# armed session is self-titled (scannable /resume name + terminal tab). The
# name is the canonical retitle form (HIMMEL-432): the inferred ticket plus the
# worktree-slug name-half. Platform-branched like T32 — the dry-run prints the
# Windows .bat launch line on MSYS, the crontab/at line elsewhere; -n is quoted
# for CMD on Windows and printf %q-escaped (space -> '\ ') for /bin/sh.
# ---------------------------------------------------------------------------
if _sec_selected "S1-S5" "S1" "S2" "S3" "S5"; then

# S1: worktree arm -> ticket (src-2, uppercased) + name-half from the slug.
HO=$(make_handover "")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/himmel-702-demo --dry-run 2>&1)
rc=$?
assert_rc "S1 worktree arm exits 0" 0 "$rc"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S1 win .bat bakes -n <ticket> <name>" '-n "HIMMEL-702 demo"' "$out" ;;
    *)
        assert_contains "S1 cron/at bakes -n <ticket> <name>" '-n HIMMEL-702\ demo' "$out" ;;
esac

# S2 (semantics extended by HIMMEL-716): ticketless handover, no worktree ->
# the handover-slug fallback names the session from the file stem (the
# no-Jira adopter path). Pre-716 this case was fail-open (no -n); the truly
# nothing-derivable fail-open now lives in S9 (empty template render).
HO=$(make_handover_titled "Test handover")
S2_STEM=$(basename "$HO" .md)
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "S2 ticketless arm exits 0" 0 "$rc"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S2 win .bat bakes -n <handover slug>" "-n \"$S2_STEM\"" "$out" ;;
    *)
        assert_contains "S2 cron/at bakes -n <handover slug>" "-n $S2_STEM " "$out" ;;
esac
assert_contains "S2 slug also welds into the task name" "HIMMEL-Resume-$S2_STEM-" "$out"

# S3: ticket but no name-half (frontmatter ticket, no worktree slug) -> -n with
# the bare ticket key.
HO=$(make_handover_titled "Test handover" "HIMMEL-702")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "S3 ticket-only arm exits 0" 0 "$rc"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S3 win .bat bakes -n <ticket>" '-n "HIMMEL-702"' "$out" ;;
    *)
        assert_contains "S3 cron/at bakes -n <ticket>" '-n HIMMEL-702 ' "$out" ;;
esac

# S5 (HIMMEL-702): name-half but NO inferable ticket (worktree slug carries no
# `<key>-<N>` token, e.g. feat/cleanup) -> -n with the bare slug name. Exercises
# the token-less worktree-slug branch of _compose_arm_name; a branch slug is a
# meaningful title, so this is NOT the fail-open empty case (contrast S2).
HO=$(make_handover "")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/cleanup --dry-run 2>&1)
rc=$?
assert_rc "S5 name-only (ticketless slug) arm exits 0" 0 "$rc"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S5 win .bat bakes -n <name>" '-n "cleanup"' "$out" ;;
    *)
        assert_contains "S5 cron/at bakes -n <name>" '-n cleanup ' "$out" ;;
esac
fi

# ---------------------------------------------------------------------------
# N9-N10 / S6-S10 (HIMMEL-716): derived naming - chain position, slug
# fallback, ARM_NAME_TEMPLATE. Chained fixtures are next-session-<N>.md files
# inside a <TICKET>-<slug>/ epic dir (the handover skill's chain layout),
# which the existing helpers don't produce - make_handover_chained supplies
# them. Same stub/dry-run discipline as N1-N8 / S1-S5.
# ---------------------------------------------------------------------------
if _sec_selected "N9-N13" "N9" "N10" "S6" "S7" "S8" "S9" "S10" "S11" "N11" "N12" "S12" "N13"; then
# Helper: a CHAINED handover. $1 = epic dir name, $2 = session number,
# $3 = optional ticket: frontmatter value (empty = key-less chain file).
make_handover_chained() {
    local dir="$HANDOVER_DIR/$1" path
    mkdir -p "$dir"
    path="$dir/next-session-$2.md"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        [ -n "${3:-}" ] && printf 'ticket: %s\n' "$3"
        printf -- '---\n'
        printf '# Chained test handover\n'
    } > "$path"
    printf '%s' "$path"
}

# N9/S6: chained ticketed (frontmatter ticket) -> the identity carries the
# epic slug AND the chain position on BOTH surfaces: the scheduler row gets
# ...HIMMEL-654-ws7-gates-s32... and the -n title "HIMMEL-654 ws7-gates s32".
HO=$(make_handover_chained "HIMMEL-654-ws7-gates" 32 "HIMMEL-654")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N9 chained ticketed arm exits 0" 0 "$rc"
assert_contains "N9 task name carries epic slug + chain position" "HIMMEL-Resume-HIMMEL-654-ws7-gates-s32-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S6 win .bat bakes -n <ticket> <slug> s<N>" '-n "HIMMEL-654 ws7-gates s32"' "$out" ;;
    *)
        assert_contains "S6 cron/at bakes -n <ticket> <slug> s<N>" '-n HIMMEL-654\ ws7-gates\ s32' "$out" ;;
esac

# N10: chained with NO key in frontmatter/H1 -> _infer_ticket src-4 takes the
# epic dir's leading key, so the chain identity survives a key-less chain file.
HO=$(make_handover_chained "HIMMEL-654-ws7-gates" 7 "")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N10 chained key-less arm exits 0" 0 "$rc"
assert_contains "N10 epic-dir key + slug + chain position welded" "HIMMEL-Resume-HIMMEL-654-ws7-gates-s7-" "$out"

# S7: no-ticket slug fallback (OSS adopter, no Jira at all) - a meaningfully
# named flat handover names the session and the scheduler row from its stem.
HO_S7="$HANDOVER_DIR/nightly-refactor-notes.md"
printf -- '---\nsession_kind: test\n---\n# Adopter handover, no ticket\n' > "$HO_S7"
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_S7" --dry-run 2>&1)
rc=$?
assert_rc "S7 no-ticket slug arm exits 0" 0 "$rc"
assert_contains "S7 task name carries the slug" "HIMMEL-Resume-nightly-refactor-notes-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S7 win .bat bakes -n <slug>" '-n "nightly-refactor-notes"' "$out" ;;
    *)
        assert_contains "S7 cron/at bakes -n <slug>" '-n nightly-refactor-notes ' "$out" ;;
esac

# S8: ARM_NAME_TEMPLATE override (slug-only) - the ticket IS inferable but the
# operator's template drops it from BOTH surfaces; the ticket-KEYED file stem
# renders as the bare name-half (leading <ticket>- token stripped).
HO_S8="$HANDOVER_DIR/HIMMEL-716-arm-naming.md"
printf -- '---\nsession_kind: test\nticket: HIMMEL-716\n---\n# Template case\n' > "$HO_S8"
out=$(ARM_NAME_TEMPLATE='{slug}' SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_S8" --dry-run 2>&1)
rc=$?
assert_rc "S8 template arm exits 0" 0 "$rc"
assert_contains "S8 slug-only template drives the task name" "HIMMEL-Resume-arm-naming-" "$out"
assert_not_contains "S8 template drops the ticket segment" "HIMMEL-Resume-HIMMEL-716-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S8 win .bat bakes the template title" '-n "arm-naming"' "$out" ;;
    *)
        assert_contains "S8 cron/at bakes the template title" '-n arm-naming ' "$out" ;;
esac

# S9: template renders EMPTY ({session} on a non-chained handover) -> fail-open:
# no -n (claude auto-titles) and the task name falls back to the plain
# path-only form. This is the fail-open contract S2 used to pin pre-716.
HO=$(make_handover_titled "Test handover")
out=$(ARM_NAME_TEMPLATE='{session}' SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "S9 empty-render template arm exits 0" 0 "$rc"
assert_not_contains "S9 no -n when the template renders empty" " -n " "$out"
# The task-name half of fail-open: an empty render must fall back to the plain
# path-only name, NOT leave a stray-separator segment (HIMMEL-Resume--<suffix>).
assert_not_contains "S9 empty template yields path-only task name" "HIMMEL-Resume--" "$out"

# S10: bare chain file in a GENERIC bucket (handovers/ itself, no epic dir,
# no ticket) -> the generic parent must NOT become the slug (it would name
# every slot alike); the chain position alone remains as the identity.
HO_S10="$HANDOVER_DIR/next-session-3.md"
printf -- '---\nsession_kind: test\n---\n# Bare chain file\n' > "$HO_S10"
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_S10" --dry-run 2>&1)
rc=$?
assert_rc "S10 generic-bucket chain arm exits 0" 0 "$rc"
assert_not_contains "S10 generic parent dir is not welded as slug" "HIMMEL-Resume-handovers-" "$out"
assert_contains "S10 chain position alone is the identity" "HIMMEL-Resume-s3-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S10 win .bat bakes -n s<N>" '-n "s3"' "$out" ;;
    *)
        assert_contains "S10 cron/at bakes -n s<N>" '-n s3 ' "$out" ;;
esac

# S11/N11 (HIMMEL-716 CR gap 1): worktree name-half AND chain session number
# COMBINED - the one branch where `_name` is worktree-derived (priority 1) AND
# `_sess` is non-empty. All other S/N cases exercise only ONE of the two. The
# worktree slug (feat/himmel-654-demo -> name-half "demo") WINS over the epic-dir
# slug ("x"), so the identity is HIMMEL-654 + demo + s5, NOT ...ws7-gates...
HO=$(make_handover_chained "HIMMEL-654-x" 5 "HIMMEL-654")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --worktree feat/himmel-654-demo --dry-run 2>&1)
rc=$?
assert_rc "N11 worktree+chain arm exits 0" 0 "$rc"
assert_contains "N11 task name carries worktree name-half + chain position" "HIMMEL-Resume-HIMMEL-654-demo-s5-" "$out"
assert_not_contains "N11 epic-dir slug is NOT used (worktree half wins)" "HIMMEL-Resume-HIMMEL-654-x-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S11 win .bat bakes -n <ticket> <wt-name> s<N>" '-n "HIMMEL-654 demo s5"' "$out" ;;
    *)
        assert_contains "S11 cron/at bakes -n <ticket> <wt-name> s<N>" '-n HIMMEL-654\ demo\ s5' "$out" ;;
esac

# N12 (HIMMEL-716 CR gap 2): backslash-path normalization in ALL THREE new
# helpers (${_ho//\\//} at arm-resume.sh ~576/593/608). This is Windows-primary
# code, so a Windows-style backslash --handover path must still split into
# basename + parent dir correctly. Ticketless on purpose: _infer_ticket src-4
# (epic-dir key via a backslash-normalized dirname), _infer_session_number, AND
# _infer_slug are ALL exercised, so a full HIMMEL-654-ws7-gates-s9 identity
# derived from a backslash path proves every helper normalized. Windows-only: on
# MSYS `cygpath -w` yields the backslash form and `[ -f ]` still resolves it.
# Skips cleanly elsewhere (no backslash paths off Windows).
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        HO=$(make_handover_chained "HIMMEL-654-ws7-gates" 9 "")
        HO_BS=$(cygpath -w "$HO")
        out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO_BS" --dry-run 2>&1)
        rc=$?
        assert_rc "N12 backslash --handover path arm exits 0" 0 "$rc"
        assert_contains "N12 full chain identity derived after backslash normalization" "HIMMEL-Resume-HIMMEL-654-ws7-gates-s9-" "$out"
        ;;
    *)
        echo "PASS N12 backslash-path normalization (skipped off Windows)" ;;
esac

# S12/N13 (HIMMEL-716 CR gap 4): non-empty MIXED template on an actually-chained
# ticketed file - {session} renders sN (non-empty) and the task-surface sanitizer
# folds the '-' literal. ARM_NAME_TEMPLATE='{ticket}-{session}' -> HIMMEL-654-s5
# on BOTH surfaces.
HO=$(make_handover_chained "HIMMEL-654-x" 5 "HIMMEL-654")
out=$(ARM_NAME_TEMPLATE='{ticket}-{session}' SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N13 mixed-template chained arm exits 0" 0 "$rc"
assert_contains "N13 template renders ticket+session into the task name" "HIMMEL-Resume-HIMMEL-654-s5-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S12 win .bat bakes the mixed template title" '-n "HIMMEL-654-s5"' "$out" ;;
    *)
        assert_contains "S12 cron/at bakes the mixed template title" '-n HIMMEL-654-s5 ' "$out" ;;
esac
fi

# ---------------------------------------------------------------------------
# macOS backend: crontab for schedule + dedup + --force (HIMMEL-594)
# ---------------------------------------------------------------------------
if _sec_selected "macOS" "S1-S5" "S4"; then
# at/atq present but must NOT be used on macOS — arm-resume picks crontab there
# (atrun is off-by-default / SIP-fragile). Shim at/atq present so the
# at-vs-crontab mismatch is actually exercised, plus a file-backed crontab.
MACBIN="$TMP/macbin"; mkdir -p "$MACBIN"
CRON_STORE="$TMP/cron.store"; : > "$CRON_STORE"
printf '#!/bin/sh\necho "at MUST NOT be called on macOS" >&2; exit 1\n' > "$MACBIN/at";  chmod +x "$MACBIN/at"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN/atq"; chmod +x "$MACBIN/atq"
cat > "$MACBIN/crontab" <<CRONEOF
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE" 2>/dev/null ;;
  -) cat > "$CRON_STORE" ;;
  *) exit 0 ;;
esac
CRONEOF
chmod +x "$MACBIN/crontab"

MAC_HO="$(make_handover "$WORK_REPO")"
mac_env() { env PATH="$MACBIN:$PATH" OSTYPE="darwin23" "$@"; }

# (a) schedule emits a crontab entry, not at -t
out="$(mac_env bash "$ARM" --time "$(future_time)" --handover "$MAC_HO" --dry-run 2>&1)"; rc=$?
assert_rc "macOS schedule dry-run" 0 "$rc"
assert_contains "macOS uses crontab entry" "crontab entry" "$out"
assert_not_contains "macOS avoids at -t" "at -t" "$out"

# S4 (HIMMEL-702): the crontab/POSIX launch line also bakes -n, printf %q-escaped
# so the space in "<TICKET> <name>" survives the /bin/sh re-parse at fire time.
# Exercised on ANY host via mac_env's forced OSTYPE=darwin -> _crontab_schedule,
# so the POSIX injection is covered even when the suite runs on Windows.
S4_HO="$(make_handover "$WORK_REPO")"
out="$(mac_env bash "$ARM" --time "$(future_time)" --handover "$S4_HO" --worktree feat/himmel-702-demo --dry-run 2>&1)"; rc=$?
assert_rc "S4 macOS/cron worktree arm exits 0" 0 "$rc"
assert_contains "S4 crontab entry bakes -n <ticket> <name> (%q-escaped)" '-n HIMMEL-702\ demo' "$out"

# (b) real arm then a 2nd arm is deduped (proves list_existing reads crontab)
mac_env bash "$ARM" --time "$(future_time)" --handover "$MAC_HO" >/dev/null 2>&1
out="$(mac_env bash "$ARM" --time "$(future_time)" --handover "$MAC_HO" 2>&1)"; rc=$?
assert_rc "macOS 2nd arm deduped (rc=3)" 3 "$rc"

# (c) --force removes + replaces the crontab entry (one entry remains)
mac_env bash "$ARM" --time "$(future_time)" --handover "$MAC_HO" --force >/dev/null 2>&1
n="$(grep -c 'HIMMEL-Resume-' "$CRON_STORE" 2>/dev/null)" || n=0
if [ "$n" -eq 1 ]; then echo "PASS macOS --force keeps single entry"; else echo "FAIL macOS --force entries=$n"; FAILED=$((FAILED+1)); fi

# (d) scoped --force on macOS leaves a SIBLING handover's crontab line intact
# (HIMMEL-340 invariant on the crontab path: the full-line grep -vxF delete must
# remove ONLY handover A's marker, never B's). B uses a distinct time so the
# advisory collision check has nothing to flag.
a_line="$(grep 'HIMMEL-Resume-' "$CRON_STORE" | head -1)"
MAC_HO2="$(make_handover "$WORK_REPO")"
mac_env bash "$ARM" --time "23:58" --handover "$MAC_HO2" --long-gap >/dev/null 2>&1   # arm sibling B
n="$(grep -c 'HIMMEL-Resume-' "$CRON_STORE" 2>/dev/null)" || n=0
if [ "$n" -eq 2 ]; then echo "PASS macOS two distinct handovers coexist"; else echo "FAIL macOS expected 2 slots, got $n"; FAILED=$((FAILED+1)); fi
b_line="$(grep -vF "$a_line" "$CRON_STORE" | grep 'HIMMEL-Resume-' | head -1)"
mac_env bash "$ARM" --time "$(future_time)" --handover "$MAC_HO" --force >/dev/null 2>&1   # force A
n="$(grep -c 'HIMMEL-Resume-' "$CRON_STORE" 2>/dev/null)" || n=0
if [ "$n" -eq 2 ]; then echo "PASS macOS --force on A leaves sibling B (2 slots)"; else echo "FAIL macOS sibling preserve entries=$n"; FAILED=$((FAILED+1)); fi
if [ -n "$b_line" ] && grep -qF "$b_line" "$CRON_STORE" 2>/dev/null; then echo "PASS macOS sibling B line survived --force on A"; else echo "FAIL macOS sibling B line wiped"; FAILED=$((FAILED+1)); fi
fi

# ---------------------------------------------------------------------------
# T-awkfail (HIMMEL-1304 CR): _crontab_delete must never fall through to
# `crontab -` with empty input just because its OWN awk filter failed
# (missing binary, runtime error, unreadable snapshot). Pre-fix, an unchecked
# awk rc left $filtered empty on ANY awk failure, `[ -z "$filtered" ]` read
# that as "the crontab is now correctly empty", and installed an EMPTY
# crontab -- wiping every entry, himmel's and the operator's unrelated ones
# alike -- and because that write "succeeded", the $snap backup made for
# exactly this recovery case was then deleted too. A legitimately-empty
# $filtered (the removed line was the only one queued) must stay a valid,
# non-fatal outcome -- only awk itself failing is the abort condition.
#
# Forces the failure with an `awk` shim that intercepts ONLY the specific
# one-shot-delete program `_crontab_delete` runs (matched on its
# `ENVIRON["MARKER"]` literal) and delegates every other awk invocation
# (frontmatter parsing, etc.) to the real binary, so nothing upstream of the
# delete step is disturbed by the injected failure.
#
# The --force below reaps the superseded slot through the post-commit sweep
# (delete_existing ... soft — see :1714-1722 / :1424-1430), which is SOFT
# mode: the new arm is already registered and verified by the time this awk
# failure hits, so per HIMMEL-1304 finding 1 it must WARN + keep the arm
# (rc=0), never exit 2 -- pre-fix, both crontab call sites in delete_existing
# ignored the soft flag and always hard-exited here, which is what this case
# used to assert (rc=2) before the fix landed.
# ---------------------------------------------------------------------------
if _sec_selected "T-awkfail"; then
AWKFAIL_REAL_AWK="$(command -v awk)"
AWKFAIL_DIR="$TMP/awkfail-bin"; mkdir -p "$AWKFAIL_DIR"
cat > "$AWKFAIL_DIR/awk" <<AWKEOF
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in
        *'ENVIRON["MARKER"]'*) echo "stub: awk forced failure (test)" >&2; exit 2 ;;
    esac
done
exec "$AWKFAIL_REAL_AWK" "\$@"
AWKEOF
chmod +x "$AWKFAIL_DIR/awk"
AWKFAIL_MACBIN="$TMP/awkfail-macbin"; mkdir -p "$AWKFAIL_MACBIN"
AWKFAIL_CRON_STORE="$TMP/awkfail-cron.store"; : > "$AWKFAIL_CRON_STORE"
printf '#!/bin/sh\nexit 1\n' > "$AWKFAIL_MACBIN/at"; chmod +x "$AWKFAIL_MACBIN/at"
printf '#!/bin/sh\nexit 0\n' > "$AWKFAIL_MACBIN/atq"; chmod +x "$AWKFAIL_MACBIN/atq"
cat > "$AWKFAIL_MACBIN/crontab" <<CRONEOF3
#!/bin/sh
case "\$1" in
  -l) cat "$AWKFAIL_CRON_STORE" 2>/dev/null ;;
  -) cat > "$AWKFAIL_CRON_STORE" ;;
  *) exit 0 ;;
esac
CRONEOF3
chmod +x "$AWKFAIL_MACBIN/crontab"
awkfail_env() { env PATH="$AWKFAIL_DIR:$AWKFAIL_MACBIN:$PATH" OSTYPE="darwin23" "$@"; }

AWKFAIL_HO="$(make_handover "$WORK_REPO")"
awkfail_env bash "$ARM" --time "$(future_time)" --handover "$AWKFAIL_HO" >/dev/null 2>&1   # seed (real awk; no ENVIRON["MARKER"] call yet)
seed_n="$(grep -c 'HIMMEL-Resume-' "$AWKFAIL_CRON_STORE" 2>/dev/null)" || seed_n=0
if [ "$seed_n" -eq 1 ]; then echo "PASS T-awkfail seed: pre-existing slot armed"; else echo "FAIL T-awkfail seed left $seed_n slot(s) (expected 1)"; FAILED=$((FAILED+1)); fi

out=$(awkfail_env bash "$ARM" --time "$(future_time)" --handover "$AWKFAIL_HO" --force 2>&1)
rc=$?
assert_rc "T-awkfail soft-mode awk failure does NOT kill the script (rc=0)" 0 "$rc"
assert_contains "T-awkfail WARN names the awk failure" "could NOT be removed (awk rc=" "$out"
assert_contains "T-awkfail WARN says the sibling is still queued" "STILL QUEUED" "$out"
assert_contains "T-awkfail WARN surfaces the un-reaped count" "superseded job(s) could not be reaped" "$out"
assert_contains "T-awkfail the new arm still stands" "RESUME ARMED" "$out"
assert_not_contains "T-awkfail does NOT print the misleading success line" "removed crontab entry" "$out"
n="$(grep -c 'HIMMEL-Resume-' "$AWKFAIL_CRON_STORE" 2>/dev/null)" || n=0
if [ "$n" -eq 2 ]; then echo "PASS T-awkfail both the un-reaped old entry and the new arm remain (2 entries)"; else echo "FAIL T-awkfail expected 2 entries (old un-reaped + new), got $n"; FAILED=$((FAILED+1)); fi
snap_path=$(printf '%s' "$out" | grep -oE '/[^ ]*crontab\.snap\.[A-Za-z0-9]+' | head -1)
if [ -n "$snap_path" ] && [ -s "$snap_path" ]; then
    echo "PASS T-awkfail snapshot preserved ($snap_path)"
else
    echo "FAIL T-awkfail snapshot missing or empty (path='$snap_path')"
    FAILED=$((FAILED+1))
fi

fi
# ---------------------------------------------------------------------------
# V1-V5 (HIMMEL-938): Windows /sd locale-aware render + post-arm NextRunTime
# verify. arm-resume selects PLATFORM from OSTYPE (falling back to uname -s),
# so — exactly like mac_env above forces OSTYPE=darwin23 to exercise the
# macOS/crontab branch from any host — win_env forces OSTYPE=msys to exercise
# the Windows/schtasks branch here, even when this suite runs on ubuntu CI.
# WINBIN carries the two stubs every case below needs no matter which
# schtasks/reg/powershell stub it's paired with: `claude` (schedule_arm
# resolves it via `command -v claude` before writing the .bat, even under
# --dry-run) and `cygpath` (converts the .bat/claude/cwd paths for the
# schtasks /tr line; a real Linux box has neither, so both must exist for
# the Windows branch to get past its own tool-missing guards).
# ---------------------------------------------------------------------------
WINBIN="$TMP/win-stub-bin"
mkdir -p "$WINBIN"
cat > "$WINBIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$WINBIN/cygpath" <<'EOF'
#!/usr/bin/env bash
# Minimal stub: echo each non-flag (path) argument on its own line,
# unchanged. schedule_arm only needs 3 non-empty lines back in argument
# order -- these tests never inspect the ACTUAL Windows-path form.
for a in "$@"; do
    case "$a" in
        -*) ;;
        *) printf '%s\n' "$a" ;;
    esac
done
EOF
# No-op schtasks stub: only satisfies arm-resume's `command -v schtasks`
# preflight (~line 491) for the dry-run V1/V2/V2b cases below, which return
# before any create call ever reaches schtasks. On a real Linux box (no
# System32 schtasks) this preflight would otherwise kill those tests before
# they reach the locale-render logic under test.
cat > "$WINBIN/schtasks" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WINBIN/claude" "$WINBIN/cygpath" "$WINBIN/schtasks"
win_env() {
    local _dir="$1"; shift
    # schtasks via the SCHTASKS_CMD seam (HIMMEL-1610): pin the stub by absolute
    # path so the call no longer depends on PATH resolution order. Prefer this
    # dir's schtasks (V3-V9/FIND2 carry test-specific /create+/delete behavior);
    # fall back to WINBIN's no-op when _dir has none (T-wsl's WSLBIN carries only
    # wsl.exe; the V1/V2 dry-run dirs only need the preflight satisfied).
    # claude/cygpath still resolve via PATH as before.
    local _sc="$_dir/schtasks"; [ -x "$_sc" ] || _sc="$WINBIN/schtasks"
    env PATH="$_dir:$WINBIN:$PATH" SCHTASKS_CMD="$_sc" OSTYPE="msys" "$@"
}

# ---------------------------------------------------------------------------
# T-wsl: Windows-host schtasks backend that relaunches inside a WSL distro.
# Forced through win_env on every host; wsl.exe distinguishes the two arm-time
# login-shell preflights via WSL_STUB_MODE.
# ---------------------------------------------------------------------------
if _sec_selected "T-wsl"; then
echo "--- T-wsl ---"
WSLBIN="$TMP/wsl-stub-bin"
mkdir -p "$WSLBIN"
cat > "$WSLBIN/wsl.exe" <<'EOF'
#!/usr/bin/env bash
if [ "${MSYS_NO_PATHCONV:-}" != "1" ] || [ "${MSYS2_ARG_CONV_EXCL:-}" != "*" ]; then
    exit 9
fi
if [ "${WSL_STUB_MODE:-ok}" = "cwd-fail" ]; then
    case "$*" in *"test -d "*) exit 1 ;; esac
fi
if [ "${WSL_STUB_MODE:-ok}" = "claude-fail" ]; then
    case "$*" in *"command -v claude"*) exit 1 ;; esac
fi
exit 0
EOF
chmod +x "$WSLBIN/wsl.exe"

WSL_CWD="/home/u/repos/himmel"
WSL_HO="$(make_handover "$WSL_CWD")"
out=$(HIMMEL_HEADROOM_PROXY=0 ARM_BRIDGE_LIVE=0 WSL_STUB_MODE=ok \
    win_env "$WSLBIN" bash "$ARM" --time "$(future_time)" --handover "$WSL_HO" \
    --wsl-distro ubuntu --channels 'plugin:test@local' --force --dry-run 2>&1)
rc=$?
assert_rc "T-wsl body exits 0" 0 "$rc"
assert_contains "T-wsl body uses unquoted distro + login shell" 'wsl.exe -d ubuntu -e bash -lc' "$out"
# HIMMEL-998: a quoted -d value reaches wsl.exe verbatim from the .bat (cmd
# does not strip it, wsl.exe does not either) -> WSL_E_DISTRO_NOT_FOUND.
assert_not_contains "T-wsl body never quotes the -d value" 'wsl.exe -d "' "$out"
# HIMMEL-1382 fix round: the launch body now unsets ARMAUTOMERGE/
# CR_MERGE_GATE_OK unconditionally between cd and claude (always-clear
# contract — see arm-resume.sh's schedule_arm WSL branch comment). HIMMEL-1475:
# the same unset also drops ARM_RESUME_SAFETY_ARM so a resumed in-distro session
# does not inherit a leaked long-gap exemption. HIMMEL-812: AUTO_ARM_SAFETY_CHILD
# joins the same list — a .bat `set` cannot cross into the distro, so the
# in-distro command is the only place the safety-child mark can be cleared.
# HIMMEL-2545 round-6: the in-distro unset list now also clears
# CLAUDE_CODE_SESSION_ID (the arming session's id must not leak into the
# relaunched claude process's own environ) — this literal-string assertion
# is genuinely invalidated by that addition, so it is updated in place
# rather than left to assert a launch line arm-resume.sh no longer emits.
assert_contains "T-wsl body has in-distro cd+unset+claude" "cd '$WSL_CWD' && unset ARMAUTOMERGE CR_MERGE_GATE_OK ARM_RESUME_SAFETY_ARM AUTO_ARM_SAFETY_CHILD CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID && export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 && claude" "$out"
assert_not_contains "T-wsl no caret escapes inside CMD quotes" '^&' "$out"
assert_contains "T-wsl prompt precedes channels" "'load $WSL_HO overnight mode. Apply the Launch preamble standing instructions in docs/handover/overnight-mode.md before Phase 1.' --channels 'plugin:test@local'" "$out"
assert_not_contains "T-wsl body drops Windows cd" "cd /d" "$out"
# Regression (s52/s53 live fire): the flow-run tmp path must carry a LITERAL
# backslash-f — a mangled printf escape (\f form feed) makes an invalid
# Windows filename and the capture silently no-ops on a real fire.
assert_contains "T-wsl bat carries the flow-run tmp path verbatim" 'FLOW_RUN_TMP=%TEMP%\flow-run-' "$out"

# Prompt escaping is driven by the handover path: bash-single-quote per
# field, then %->%% for the .bat — & and ^ stay LITERAL inside the CMD
# quotes (caret-escaping there reaches bash verbatim and shatters the
# command; verified against a live .bat fire).
WSL_SPECIAL_HO="$HANDOVER_DIR/wsl-prompt-'-%-&.md"
{
    printf -- '---\n'
    printf 'session_kind: test\n'
    printf -- '---\n'
    printf '# WSL escaping test\n'
} > "$WSL_SPECIAL_HO"
out=$(HIMMEL_HEADROOM_PROXY=0 WSL_STUB_MODE=ok \
    win_env "$WSLBIN" bash "$ARM" --time "$(future_time)" --handover "$WSL_SPECIAL_HO" \
    --cwd "$WSL_CWD" --wsl-distro ubuntu --force --dry-run 2>&1)
rc=$?
assert_rc "T-wsl prompt metachar escaping exits 0" 0 "$rc"
assert_contains "T-wsl prompt survives bash+CMD escaping" "wsl-prompt-'\\''-%%-&.md" "$out"

# A double quote in the payload cannot be escaped inside the .bat line's CMD
# quotes (CMD toggles on every unescaped quote) — the arm must REFUSE, never
# emit an injectable line. NTFS forbids " in filenames, so the fixture runs
# on POSIX hosts exercising the forced-Windows branch and follows the suite
# SKIP style on native Windows.
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        echo 'SKIP T-wsl double-quote refusal fixture (NTFS forbids " in filenames)'
        ;;
    *)
        WSL_DQUOTE_HO="$HANDOVER_DIR/wsl-prompt-\".md"
        {
            printf -- '---\n'
            printf 'session_kind: test\n'
            printf -- '---\n'
            printf '# WSL double-quote refusal test\n'
        } > "$WSL_DQUOTE_HO"
        out=$(HIMMEL_HEADROOM_PROXY=0 WSL_STUB_MODE=ok \
            win_env "$WSLBIN" bash "$ARM" --time "$(future_time)" --handover "$WSL_DQUOTE_HO" \
            --cwd "$WSL_CWD" --wsl-distro ubuntu --force --dry-run 2>&1)
        rc=$?
        assert_rc "T-wsl double-quote payload refused" 2 "$rc"
        assert_contains "T-wsl double-quote refusal is clear" "cannot carry a double quote" "$out"
        ;;
esac

out=$(bash "$ARM" --time "$(future_time)" --handover "$WSL_HO" \
    --wsl-distro 'ubuntu; rm x' --dry-run 2>&1)
rc=$?
assert_rc "T-wsl bad distro rejected" 2 "$rc"
assert_contains "T-wsl bad distro error is clear" "invalid --wsl-distro name" "$out"

out=$(bash "$ARM" --time "$(future_time)" --handover "$WSL_HO" \
    --wsl-distro "" --dry-run 2>&1)
rc=$?
assert_rc "T-wsl empty distro rejected" 2 "$rc"
assert_contains "T-wsl empty distro error is clear" "requires a non-empty value" "$out"

out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" OSTYPE=linux-gnu bash "$ARM" \
    --time "$(future_time)" --handover "$WSL_HO" --wsl-distro ubuntu --dry-run 2>&1)
rc=$?
assert_rc "T-wsl non-Windows platform rejected" 2 "$rc"
assert_contains "T-wsl non-Windows error is clear" "--wsl-distro is a Windows-host flag" "$out"

out=$(HIMMEL_HEADROOM_PROXY=0 WSL_STUB_MODE=cwd-fail \
    win_env "$WSLBIN" bash "$ARM" --time "$(future_time)" --handover "$WSL_HO" \
    --cwd /missing/in/wsl --wsl-distro ubuntu --force --dry-run 2>&1)
rc=$?
assert_rc "T-wsl in-distro cwd failure exits 4" 4 "$rc"
assert_contains "T-wsl cwd error names path" "/missing/in/wsl" "$out"
assert_contains "T-wsl cwd error names distro" "distro 'ubuntu'" "$out"

out=$(HIMMEL_HEADROOM_PROXY=0 WSL_STUB_MODE=claude-fail \
    win_env "$WSLBIN" bash "$ARM" --time "$(future_time)" --handover "$WSL_HO" \
    --cwd "$WSL_CWD" --wsl-distro ubuntu --force --dry-run 2>&1)
rc=$?
assert_rc "T-wsl in-distro claude failure exits 2" 2 "$rc"
assert_contains "T-wsl claude error names distro" "not on PATH at arm time (distro 'ubuntu')" "$out"

out=$(HIMMEL_HEADROOM_PROXY=1 WSL_STUB_MODE=ok \
    win_env "$WSLBIN" bash "$ARM" --time "$(future_time)" --handover "$WSL_HO" \
    --cwd "$WSL_CWD" --wsl-distro ubuntu --force --dry-run 2>&1)
rc=$?
assert_rc "T-wsl headroom combination exits 0" 0 "$rc"
assert_contains "T-wsl headroom skip warns" "proxy gate skipped for a WSL-station arm" "$out"
assert_contains "T-wsl headroom skip emits plain launch" 'wsl.exe -d ubuntu -e bash -lc' "$out"
assert_not_contains "T-wsl headroom skip omits proxy gate" "livez" "$out"

fi
# V1: DD/MM locale render. `reg` reports a dd/MM/yyyy short-date pattern;
# --dry-run so no real scheduler is touched. The expected /sd is computed
# independently here (mirroring arm-resume's own HH:MM -> today/tomorrow
# rule), so the assertion is an exact full-string match that's correct
# regardless of what day the suite happens to run on (no reliance on
# today's day-of-month differing from today's month).
if _sec_selected "V1"; then
V1BIN="$TMP/v1-stub-bin"; mkdir -p "$V1BIN"
cat > "$V1BIN/reg" <<'EOF'
#!/usr/bin/env bash
echo "HKEY_CURRENT_USER\\Control Panel\\International"
echo "    sShortDate    REG_SZ    dd/MM/yyyy"
exit 0
EOF
chmod +x "$V1BIN/reg"
V1_HO="$(make_handover "$WORK_REPO")"
V1_EXPECT=$(python3 -c '
import datetime, sys
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.datetime.now().astimezone()
cand = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(cand.strftime("%d/%m/%Y"))
' "$(future_time)")
out=$(win_env "$V1BIN" bash "$ARM" --time "$(future_time)" --handover "$V1_HO" --dry-run 2>&1)
rc=$?
assert_rc "V1 dd/MM/yyyy locale dry-run exits 0" 0 "$rc"
assert_contains "V1 /sd rendered day-first per machine locale" "/sd $V1_EXPECT " "$out"
fi

# V2: registry read fails -> falls back to the pre-HIMMEL-938 MM/dd/yyyy
# (byte-identical to the old hardcoded behavior). `reg` here mimics a
# missing/inaccessible key: nonzero exit, nothing useful on stdout.
if _sec_selected "V2" "V2b"; then
V2BIN="$TMP/v2-stub-bin"; mkdir -p "$V2BIN"
cat > "$V2BIN/reg" <<'EOF'
#!/usr/bin/env bash
echo "ERROR: The system was unable to find the specified registry key." >&2
exit 1
EOF
chmod +x "$V2BIN/reg"
V2_HO="$(make_handover "$WORK_REPO")"
V2_EXPECT=$(python3 -c '
import datetime, sys
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.datetime.now().astimezone()
cand = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(cand.strftime("%m/%d/%Y"))
' "$(future_time)")
out=$(win_env "$V2BIN" bash "$ARM" --time "$(future_time)" --handover "$V2_HO" --dry-run 2>&1)
rc=$?
assert_rc "V2 reg-failure dry-run still exits 0" 0 "$rc"
assert_contains "V2 /sd falls back to MM/dd/yyyy" "/sd $V2_EXPECT " "$out"

# V2b (coderabbit-4): a month-NAME pattern (dd-MMM-yy) cannot be rendered
# numerically -- the render must refuse and fall back to MM/dd/yyyy (and
# mark the locale path degraded; the fallback value is what the dry-run
# print shows).
V2B_BIN="$TMP/v2b-stub-bin"; mkdir -p "$V2B_BIN"
cat > "$V2B_BIN/reg" <<'EOF'
#!/usr/bin/env bash
echo "HKEY_CURRENT_USER\\Control Panel\\International"
echo "    sShortDate    REG_SZ    dd-MMM-yy"
exit 0
EOF
chmod +x "$V2B_BIN/reg"
V2B_HO="$(make_handover "$WORK_REPO")"
out=$(win_env "$V2B_BIN" bash "$ARM" --time "$(future_time)" --handover "$V2B_HO" --dry-run 2>&1)
rc=$?
assert_rc "V2b month-name pattern dry-run still exits 0" 0 "$rc"
assert_contains "V2b /sd falls back to MM/dd/yyyy on MMM pattern" "/sd $V2_EXPECT " "$out"
fi

# V3-V5 share a stateless create-ok schtasks stub (with a logged /delete) and
# an empty-scheduler /query — these are REAL (non-dry-run) arms so the
# post-arm verify block actually runs. `reg` is intentionally ABSENT from
# these stub dirs (same as a bare Linux box): the locale render falls back
# to MM/dd/yyyy, which is irrelevant to what V3-V5 exercise.
make_verify_stub() {
    local dir="$1" ps_body="$2"
    mkdir -p "$dir"
    # HIMMEL-1879: /query must report back what /create registered. These stubs
    # exist to drive the NextRunTime verify (the powershell body above), but the
    # EXISTENCE verify runs too, and an always-empty /query reads as "the create
    # armed nothing" -> rc 2 on the cases that expect a clean arm (V4, V5).
    # /delete still logs, and still removes, so the delete-log assertions and
    # the "verify pass leaves the task in place" checks both stay honest.
    cat > "$dir/schtasks" <<EOF
#!/usr/bin/env bash
db="$dir/tasks"
cmd="\$1"; shift || true
tn=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        /tn)   tn="\${2:-}"; shift 2 ;;
        /tn=*) tn="\${1#/tn=}"; shift ;;
        *)     shift ;;
    esac
done
case "\$cmd" in
    /query)
        [ -f "\$db" ] || exit 0
        while IFS= read -r t; do
            [ -n "\$t" ] && printf '"\\\\%s","2026-01-01","Ready"\\n' "\$t"
        done < "\$db"
        exit 0 ;;
    /create)
        printf '%s\\n' "\$tn" >> "\$db"; exit 0 ;;
    /delete)
        printf '%s\\n' "\$tn" >> "$dir/delete.log"
        if [ -f "\$db" ]; then
            grep -vFx "\$tn" "\$db" > "\$db.tmp" 2>/dev/null || : > "\$db.tmp"
            mv "\$db.tmp" "\$db"
        fi
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
    cat > "$dir/powershell" <<EOF
#!/usr/bin/env bash
$ps_body
EOF
    chmod +x "$dir/schtasks" "$dir/powershell"
}

# V3: registered NextRunTime is ~180 days from now -> the exact HIMMEL-938
# months-out class. The powershell stub can't see arm-resume's TARGET_EPOCH,
# so it computes "now (at verify time) + 180 days" itself -- verify runs
# moments after arm-resume derived TARGET_EPOCH from the same wall clock, so
# the two land on the same calendar day and the ~180d gap is unambiguous
# (far past the 24h OK/ERR threshold either way).
if _sec_selected "V3"; then
V3="$TMP/v3-stub-bin"
make_verify_stub "$V3" 'python3 -c "import time; print(int(time.time()) + 180*86400)"'
V3_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V3" bash "$ARM" --time "$(future_time)" --handover "$V3_HO" 2>&1)
rc=$?
assert_rc "V3 months-out verify refuses (rc=2)" 2 "$rc"
assert_contains "V3 ERR mentions NextRunTime" "NextRunTime" "$out"
if [ -s "$V3/delete.log" ]; then
    echo "PASS V3 bad task was deleted (schtasks /delete hit)"
else
    echo "FAIL V3 expected schtasks /delete to be called"
    FAILED=$((FAILED + 1))
fi
fi

# V4: registered NextRunTime matches the requested time exactly -> verify
# passes, arm stands (rc=0). The stub can't independently derive
# TARGET_EPOCH either, so the test computes it FIRST (mirroring arm-resume's
# own HH:MM -> epoch rule) and threads it straight into the stub script --
# simulating a scheduler that registered exactly what was asked.
if _sec_selected "V4" "V4b"; then
V4_EPOCH=$(python3 -c '
import datetime, sys
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.datetime.now().astimezone()
cand = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(int(cand.timestamp()))
' "$(future_time)")
V4="$TMP/v4-stub-bin"
make_verify_stub "$V4" "echo $V4_EPOCH"
V4_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V4" bash "$ARM" --time "$(future_time)" --handover "$V4_HO" 2>&1)
rc=$?
assert_rc "V4 exact NextRunTime match arms cleanly (rc=0)" 0 "$rc"
assert_contains "V4 arm banner printed" "RESUME ARMED" "$out"
if [ -s "$V4/delete.log" ]; then
    echo "FAIL V4 verify pass must NOT delete the task"
    FAILED=$((FAILED + 1))
else
    echo "PASS V4 verify pass leaves the task in place"
fi

# V4b (codex-adv-5 boundary): registered NextRunTime is 121s past the
# request -- just beyond scheduler resolution -> refuse (rc=2) + delete. A
# healthy arm lands on the exact requested minute, so 121s is already a
# real mistime (the old 24h tolerance let an exactly-one-day-late
# registration pass with only a WARN).
V4B="$TMP/v4b-stub-bin"
make_verify_stub "$V4B" "echo $((V4_EPOCH + 121))"
V4B_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V4B" bash "$ARM" --time "$(future_time)" --handover "$V4B_HO" 2>&1)
rc=$?
assert_rc "V4b 121s NextRunTime mismatch refuses (rc=2)" 2 "$rc"
assert_contains "V4b ERR names the 120s tolerance" "120s tolerance" "$out"
if [ -s "$V4B/delete.log" ]; then
    echo "PASS V4b mistimed task was deleted (schtasks /delete hit)"
else
    echo "FAIL V4b expected schtasks /delete to be called"
    FAILED=$((FAILED + 1))
fi

# V4c (HIMMEL-1609): the ACCEPT side of the same boundary. V4 pins an exact
# match and V4b pins 121s -> refuse, but until now nothing pinned the last
# value the advertised tolerance is supposed to ACCEPT — so a comparison that
# had quietly tightened (>=120, or a smaller constant) would have kept both
# neighbours green while refusing arms the ERR text promises are fine. The
# contract is arm-resume.sh's `[ "$_diff" -gt 120 ]` and the "120s tolerance"
# it names: 120 stands, 121 does not. This case is the 120.
V4C="$TMP/v4c-stub-bin"
make_verify_stub "$V4C" "echo $((V4_EPOCH + 120))"
V4C_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V4C" bash "$ARM" --time "$(future_time)" --handover "$V4C_HO" 2>&1)
rc=$?
assert_rc "V4c 120s NextRunTime diff is inside the tolerance (rc=0)" 0 "$rc"
assert_contains "V4c arm banner printed" "RESUME ARMED" "$out"
if [ -s "$V4C/delete.log" ]; then
    echo "FAIL V4c a within-tolerance arm must NOT be deleted"
    FAILED=$((FAILED + 1))
else
    echo "PASS V4c within-tolerance arm leaves the task in place"
fi
fi

# V5: the verify PROBE itself fails (powershell exits nonzero, no output)
# while locale detection WORKS -> fail-OPEN: a WARN, but the arm still
# stands (rc=0). Distinguishes the infra-failure path (V5) from the
# bad-answer path (V3): only a CONFIRMED bad answer deletes the task. The
# reg stub matters (codex-adv-8): with locale detection ALSO down this
# would be the V8 dual-failure refuse, and on Linux CI there is no real
# reg to fall back on.
if _sec_selected "V5"; then
V5="$TMP/v5-stub-bin"
make_verify_stub "$V5" 'echo "stub: powershell unavailable" >&2; exit 1'
cat > "$V5/reg" <<'EOF'
#!/usr/bin/env bash
echo "HKEY_CURRENT_USER\\Control Panel\\International"
echo "    sShortDate    REG_SZ    M/d/yyyy"
exit 0
EOF
chmod +x "$V5/reg"
V5_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V5" bash "$ARM" --time "$(future_time)" --handover "$V5_HO" 2>&1)
rc=$?
assert_rc "V5 verify-infra-failure still arms (rc=0)" 0 "$rc"
assert_contains "V5 WARN surfaced for the failed probe" "WARN arm-resume: post-arm NextRunTime verify could not run" "$out"
# HIMMEL-1879 (r5): the fail-open stands -- an unreachable probe is not evidence
# of a bad arm -- but the banner must not then claim an EARNED success. Plain
# "RESUME ARMED" is reserved for an arm that was queried back and confirmed.
assert_contains "V5 the arm is still reported (rc unchanged, banner printed)" "RESUME ARMED" "$out"
assert_contains "V5 but the banner does NOT claim a verified arm (HIMMEL-1879)" "UNVERIFIED" "$out"
if [ -s "$V5/delete.log" ]; then
    echo "FAIL V5 infra failure must NOT delete the task"
    FAILED=$((FAILED + 1))
else
    echo "PASS V5 infra failure leaves the task in place"
fi
fi

# V6: NEXTRUN-NONE with a target that PASSED during the create->verify
# window -> the race guard (codex-adv-1/-2): the .bat self-deletes its task
# registration on fire, so a task missing AFTER its target time legitimately
# fired -- the arm is CONSUMED (WARN + rc=0, no delete). The powershell stub
# simulates the slow probe by sleeping until the target has passed before
# answering NEXTRUN-NONE. Target = next whole minute (lead 1-60s); if that
# crosses midnight the HH:MM -> today/tomorrow rule inflates the lead to
# ~24h -- skip rather than flake (this suite runs overnight).
if _sec_selected "V6"; then
V6_PROBE=$(python3 -c '
import datetime
now = datetime.datetime.now().astimezone()
cand = (now + datetime.timedelta(seconds=60)).replace(second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(cand.strftime("%H:%M"), int((cand - now).total_seconds()))
')
NEAR_TIME=${V6_PROBE% *}
NEAR_LEAD=${V6_PROBE#* }
if [ "$NEAR_LEAD" -gt 60 ] || [ "$NEAR_LEAD" -lt 10 ]; then
    # >60 = midnight edge; <10 = arm-resume's own pre-create work could
    # overshoot the target before /create, flipping the case into
    # create-after-target (V6c territory) and flaking (coderabbit-5).
    echo "SKIP V6 consumed-arm race guard (lead ${NEAR_LEAD}s outside the 10-60s reliable window)"
else
    V6="$TMP/v6-stub-bin"
    # A first, trivial stub -- just enough for the --dry-run probe below to
    # yield the derived task name. The real body is written once that name is
    # known (the stub has to embed it).
    make_verify_stub "$V6" 'echo NEXTRUN-NONE'
    V6_HO="$(make_handover "$WORK_REPO")"
    # HIMMEL-1879 made CONSUMED evidence-based: the banner is only earned when
    # the flow-run ledger holds THIS task's own `armed-resume` start row,
    # stamped at or after this arm began (_arm_fired_evidence). "No task and
    # the target has passed" otherwise means the create registered NOTHING,
    # which must refuse rc=2 -- telling an operator CONSUMED when nothing fired
    # leaves them waiting forever for a session that never started.
    #
    # The task name comes from the HANDOVER, not the time, so a --dry-run probe
    # is enough to learn it -- and unlike 1879f's throwaway arm it registers
    # nothing, leaving no scheduler row or arms-registry record behind for the
    # real arm below to trip over.
    V6_DRY=$(TMPDIR="$TMP" win_env "$V6" bash "$ARM" --time "$(future_time)"         --handover "$V6_HO" --force --dry-run 2>&1)
    V6_TASK=$(printf '%s\n' "$V6_DRY" | awk -F' /tn ' 'NF>1{split($2,a," "); print a[1]; exit}' | tr -d '\r')
    V6_TARGET_EPOCH=$(python3 -c '
import datetime, sys
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.datetime.now().astimezone()
cand = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(int(cand.timestamp()))
' "$NEAR_TIME")
    # fired_at = the TARGET minute, not "now": a real runner stamps its start
    # row when the task FIRES, necessarily after the arm that scheduled it
    # began. Stamping "now" would land a second or two BEFORE the arm starts
    # and lose the recency test on a second boundary (1879f says the same).
    V6_FIRED_AT=$(python3 -c 'import datetime, sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$V6_TARGET_EPOCH")
    LEDGER_V6="$TMP/v6.jsonl"; : > "$LEDGER_V6"
    if [ -z "$V6_TASK" ]; then
        echo "FAIL V6 could not read the task name from the dry-run probe -- the evidence row below would be seeded under the wrong name"
        FAILED=$((FAILED + 1))
    else
        echo "PASS V6 dry-run probe yielded the task name to seed ($V6_TASK)"
        # HIMMEL-2254: the evidence row is appended BY THE STUB, mid-arm --
        # NOT written to the ledger before arm-resume is invoked. HIMMEL-1999
        # item 2 snapshots this task's newest armed-resume row into
        # _ARM_PRIOR_FIRED_ROW immediately BEFORE schedule_arm and then refuses
        # to read that exact row as this arm's fire, so a row seeded up front is
        # discarded by construction and the case refused rc=2 on every host.
        # Appending it here, from the same stub call that reports the task gone,
        # reproduces production's real sequence: the task fires, deletes its own
        # registration, appends its start row, and only then does the probe
        # answer NEXTRUN-NONE.
        make_verify_stub "$V6" "sleep $((NEAR_LEAD + 3))
HIMMEL_FLOW_RUNS_LEDGER='$LEDGER_V6' bash '$(dirname "$ARM")/../lib/flow-run-ledger.sh' --append-start 'armed-resume' '$V6_FIRED_AT' 'testhost' 'claude' '' '$V6_TASK' '' 4247 >/dev/null 2>&1
echo NEXTRUN-NONE"
        # --force for the same reason 1879f/f2 needs it: the row the stub
        # appends is exactly what the rc 15 already-fired guard refuses on, and
        # that refusal would fire before the post-arm verify this case is about.
        out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_V6" win_env "$V6"         bash "$ARM" --time "$NEAR_TIME" --handover "$V6_HO" --force 2>&1)
        rc=$?
        # ONE defect, not three (HIMMEL-2254). The WARN text and the
        # leave-the-scheduler-alone check are both CONSEQUENCES of the consumed
        # verdict on this single invocation -- reported separately they
        # triple-counted one failure and made the suite's red count read as
        # three independent regressions.
        if [ "$rc" -ne 0 ]; then
            echo "FAIL V6 NEXTRUN-NONE after target passed = consumed -- expected rc=0, got rc=$rc (its WARN-text and no-delete consequences were not evaluated)"
            FAILED=$((FAILED + 1))
        else
            echo "PASS V6 NEXTRUN-NONE after target passed = consumed (rc=0)"
            assert_contains "V6 WARN says consumed, not failed" "treating the arm as consumed" "$out"
            if [ -s "$V6/delete.log" ]; then
                echo "FAIL V6 consumed arm must NOT trigger a delete"
                FAILED=$((FAILED + 1))
            else
                echo "PASS V6 consumed arm leaves scheduler state alone"
            fi
        fi
    fi
fi
fi

# V6b (codex-adv-2 negative): NEXTRUN-NONE while the target is STILL FUTURE
# (~2min lead) -> a scheduler never fires early, so the task cannot have
# been consumed; this is a bad registration (e.g. a past-date /sd misparse
# also registers with no NextRunTime) -> loud refuse (rc=2) + delete.
if _sec_selected "V6b"; then
V6B_PROBE=$(python3 -c '
import datetime
now = datetime.datetime.now().astimezone()
cand = (now + datetime.timedelta(seconds=150)).replace(second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(cand.strftime("%H:%M"), int((cand - now).total_seconds()))
')
V6B_TIME=${V6B_PROBE% *}
V6B_LEAD=${V6B_PROBE#* }
if [ "$V6B_LEAD" -lt 60 ] || [ "$V6B_LEAD" -gt 180 ]; then
    echo "SKIP V6b future-target NEXTRUN-NONE (midnight edge: computed lead ${V6B_LEAD}s)"
else
    V6B="$TMP/v6b-stub-bin"
    make_verify_stub "$V6B" 'echo NEXTRUN-NONE'
    V6B_HO="$(make_handover "$WORK_REPO")"
    out=$(TMPDIR="$TMP" win_env "$V6B" bash "$ARM" --time "$V6B_TIME" --handover "$V6B_HO" 2>&1)
    rc=$?
    assert_rc "V6b NEXTRUN-NONE with future target refuses (rc=2)" 2 "$rc"
    assert_contains "V6b ERR says a still-future target cannot have fired" "cannot have fired" "$out"
    if [ -s "$V6B/delete.log" ]; then
        echo "PASS V6b bad task was deleted (schtasks /delete hit)"
    else
        echo "FAIL V6b expected schtasks /delete to be called"
        FAILED=$((FAILED + 1))
    fi
fi
fi

# V6c (codex-adv-3): /create itself completed AFTER the target passed (slow
# setup on a tight lead) -> the ONCE task registered already-expired and can
# NEVER fire; NEXTRUN-NONE here must refuse (rc=2), never report consumed.
# The schtasks stub sleeps past the target inside /create to simulate the
# slow path; the probe answers NEXTRUN-NONE immediately.
if _sec_selected "V6c"; then
V6C_PROBE=$(python3 -c '
import datetime
now = datetime.datetime.now().astimezone()
cand = (now + datetime.timedelta(seconds=60)).replace(second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(cand.strftime("%H:%M"), int((cand - now).total_seconds()))
')
V6C_TIME=${V6C_PROBE% *}
V6C_LEAD=${V6C_PROBE#* }
if [ "$V6C_LEAD" -gt 60 ]; then
    echo "SKIP V6c create-after-target (midnight edge: computed lead ${V6C_LEAD}s)"
else
    V6C="$TMP/v6c-stub-bin"
    mkdir -p "$V6C"
    cat > "$V6C/schtasks" <<EOF
#!/usr/bin/env bash
case "\$1" in
    /query)  exit 0 ;;
    /create) sleep $((V6C_LEAD + 3)); exit 0 ;;
    /delete) printf '%s\n' "\$*" >> "$V6C/delete.log"; exit 0 ;;
    *)       exit 0 ;;
esac
EOF
    cat > "$V6C/powershell" <<'EOF'
#!/usr/bin/env bash
echo NEXTRUN-NONE
EOF
    chmod +x "$V6C/schtasks" "$V6C/powershell"
    V6C_HO="$(make_handover "$WORK_REPO")"
    out=$(TMPDIR="$TMP" win_env "$V6C" bash "$ARM" --time "$V6C_TIME" --handover "$V6C_HO" 2>&1)
    rc=$?
    assert_rc "V6c create-after-target NEXTRUN-NONE refuses (rc=2)" 2 "$rc"
    assert_contains "V6c ERR notes created-after-target never fires" "created after its target never fires" "$out"
    if [ -s "$V6C/delete.log" ]; then
        echo "PASS V6c dead task was deleted (schtasks /delete hit)"
    else
        echo "FAIL V6c expected schtasks /delete to be called"
        FAILED=$((FAILED + 1))
    fi
fi
fi

# V7: NEXTRUN-NONE with a FAR target (lead > 180s) -> still the loud-refuse
# path: a task that vanished long before its fire time was never registered
# right (the original HIMMEL-938/HIMMEL-204 silent-misarm class). Skip in
# the last ~10 minutes before midnight, where FUTURE_TIME (23:59) stops
# being "far".
if _sec_selected "V7"; then
V7_LEAD=$(python3 -c '
import datetime
now = datetime.datetime.now().astimezone()
cand = now.replace(hour=23, minute=59, second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(int((cand - now).total_seconds()))
')
if [ "$V7_LEAD" -le 600 ]; then
    echo "SKIP V7 far-target NEXTRUN-NONE (too close to midnight: lead ${V7_LEAD}s)"
else
    V7="$TMP/v7-stub-bin"
    make_verify_stub "$V7" 'echo NEXTRUN-NONE'
    V7_HO="$(make_handover "$WORK_REPO")"
    out=$(TMPDIR="$TMP" win_env "$V7" bash "$ARM" --time "$(future_time)" --handover "$V7_HO" 2>&1)
    rc=$?
    assert_rc "V7 NEXTRUN-NONE far target refuses (rc=2)" 2 "$rc"
    assert_contains "V7 ERR names the silent-misarm class" "silent-misarm" "$out"
    if [ -s "$V7/delete.log" ]; then
        echo "PASS V7 bad task was deleted (schtasks /delete hit)"
    else
        echo "FAIL V7 expected schtasks /delete to be called"
        FAILED=$((FAILED + 1))
    fi
fi
fi

# V8 (codex-adv-8): BOTH safeguards down -- locale detection fails (reg
# errors -> MM/dd/yyyy fallback) AND the verify probe fails -> on a
# day-first machine this is the original silent-misarm class again, so the
# arm must fail CLOSED: delete + rc=2, never a silent success.
if _sec_selected "V8"; then
V8="$TMP/v8-stub-bin"
make_verify_stub "$V8" 'echo "stub: powershell unavailable" >&2; exit 1'
cat > "$V8/reg" <<'EOF'
#!/usr/bin/env bash
echo "stub: registry unavailable" >&2
exit 1
EOF
chmod +x "$V8/reg"
V8_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V8" bash "$ARM" --time "$(future_time)" --handover "$V8_HO" 2>&1)
rc=$?
assert_rc "V8 locale-fallback + probe-failure refuses (rc=2)" 2 "$rc"
assert_contains "V8 ERR names both safeguards" "both safeguards unavailable" "$out"
if [ -s "$V8/delete.log" ]; then
    echo "PASS V8 dual-failure arm was deleted (schtasks /delete hit)"
else
    echo "FAIL V8 expected schtasks /delete to be called"
    FAILED=$((FAILED + 1))
fi
fi

# V8b (codex-adv-9): locale fallback + probe that SUCCEEDS (rc=0) but emits
# garbage -- no usable confirmation either -> same dual-failure refuse.
if _sec_selected "V8b"; then
V8B="$TMP/v8b-stub-bin"
make_verify_stub "$V8B" 'echo "PS banner noise: not a number"'
cat > "$V8B/reg" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$V8B/reg"
V8B_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V8B" bash "$ARM" --time "$(future_time)" --handover "$V8B_HO" 2>&1)
rc=$?
assert_rc "V8b locale-fallback + garbage probe output refuses (rc=2)" 2 "$rc"
assert_contains "V8b ERR names the non-numeric dual failure" "non-numeric NextRunTime" "$out"
if [ -s "$V8B/delete.log" ]; then
    echo "PASS V8b dual-failure arm was deleted (schtasks /delete hit)"
else
    echo "FAIL V8b expected schtasks /delete to be called"
    FAILED=$((FAILED + 1))
fi
fi

# V9 (codex-adv-11): the verify rejects (months-out answer) but the cleanup
# /delete FAILS -> the refusal must still exit 2 AND loudly surface that the
# known-bad task is STILL SCHEDULED (not silently claim cleanup).
if _sec_selected "V9"; then
V9="$TMP/v9-stub-bin"
mkdir -p "$V9"
cat > "$V9/schtasks" <<EOF
#!/usr/bin/env bash
case "\$1" in
    /query)  exit 0 ;;
    /create) exit 0 ;;
    /delete) printf '%s\n' "\$*" >> "$V9/delete.log"; exit 1 ;;
    *)       exit 0 ;;
esac
EOF
cat > "$V9/powershell" <<'EOF'
#!/usr/bin/env bash
python3 -c "import time; print(int(time.time()) + 180*86400)"
EOF
chmod +x "$V9/schtasks" "$V9/powershell"
V9_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V9" bash "$ARM" --time "$(future_time)" --handover "$V9_HO" 2>&1)
rc=$?
assert_rc "V9 rejection with failed delete still refuses (rc=2)" 2 "$rc"
assert_contains "V9 residual-task risk surfaced loudly" "STILL SCHEDULED" "$out"
fi

# ---------------------------------------------------------------------------
# FIND2 (HIMMEL-1304 round-4 finding 2): `schtasks /create /f` overwrites a
# same-identity task IN PLACE, so a --force re-arm of the SAME handover
# leaves no separate old row for the post-commit reap sweep to defer
# deleting (_arm_marker_is_new_arm treats it as "nothing to reap" -- see the
# comment above the sweep near schedule_arm). If the post-arm verify then
# rejects the overwritten registration, _win_delete_bad_task deletes it --
# and pre-fix that left NO arm at all, contradicting the :1714-1722 "old arm
# only given up once a new one demonstrably exists" guarantee for this one
# path. Reuses make_stateful_sched (SCHED_DB-backed schtasks, already proven
# for real dedup flows in T25+) with a counter-based powershell stub: call 1
# (the real first arm) reports the exact matching epoch and stands; call 2
# (the --force re-arm, same handover -> same TASK_NAME -> same-identity
# overwrite) reports a mismatched epoch, forcing the HIMMEL-938 fail-closed
# delete.
# ---------------------------------------------------------------------------
if _sec_selected "FIND2" "FIND2b"; then
FIND2_EPOCH=$(python3 -c '
import datetime, sys
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.datetime.now().astimezone()
cand = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(int(cand.timestamp()))
' "$(future_time)")
FIND2="$TMP/find2-stub-bin"
make_stateful_sched "$FIND2"
cat > "$FIND2/powershell" <<EOF
#!/usr/bin/env bash
n=\$(cat "$FIND2/.pscount" 2>/dev/null || echo 0); n=\$((n + 1))
printf '%s' "\$n" > "$FIND2/.pscount"
if [ "\$n" -eq 1 ]; then
    echo $FIND2_EPOCH
else
    echo $((FIND2_EPOCH + 10000))
fi
EOF
chmod +x "$FIND2/powershell"
DB_F2="$TMP/find2.tasks"; DBD_F2="$TMP/find2.atdir"; : > "$DB_F2"; mkdir -p "$DBD_F2"

FIND2_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" SCHED_DB="$DB_F2" SCHED_DB_DIR="$DBD_F2" win_env "$FIND2" bash "$ARM" --time "$(future_time)" --handover "$FIND2_HO" 2>&1)
rc=$?
assert_rc "FIND2 first arm succeeds (rc=0)" 0 "$rc"
# count_slots reads the CALLER's own $OSTYPE to pick which state location to
# count (SCHED_DB file vs SCHED_DB_DIR job-* files) -- but win_env above only
# forces OSTYPE=msys for the ARM SUBPROCESS, so arm-resume.sh took the
# schtasks/Windows path (recording into $DB_F2) while an unforced count_slots
# call, on a host whose real $OSTYPE isn't msys/cygwin/win32/MINGW (i.e. any
# Linux CI runner), would read the POSIX at/atq side ($DBD_F2) instead --
# always empty here -- and report 0 slots regardless of what actually got
# armed. This test deliberately exercises the Windows/schtasks-overwrite
# behavior on ANY host (that's the whole point of win_env), so count_slots
# must be told the same forced perspective, not the real host OS.
if [ "$(OSTYPE=msys count_slots "$DB_F2" "$DBD_F2")" = "1" ]; then
    echo "PASS FIND2 first arm registered (1 slot)"
else
    echo "FAIL FIND2 first arm did not register ($(OSTYPE=msys count_slots "$DB_F2" "$DBD_F2") slots)"
    FAILED=$((FAILED+1))
fi

out=$(TMPDIR="$TMP" SCHED_DB="$DB_F2" SCHED_DB_DIR="$DBD_F2" win_env "$FIND2" bash "$ARM" --time "$(future_time)" --handover "$FIND2_HO" --force 2>&1)
rc=$?
assert_rc "FIND2 same-identity --force whose verify rejects still refuses (rc=2)" 2 "$rc"
assert_contains "FIND2 ERR names the mismatch" "120s tolerance" "$out"
assert_contains "FIND2 previous arm was restored" "restored the previous arm" "$out"
if [ "$(OSTYPE=msys count_slots "$DB_F2" "$DBD_F2")" = "1" ]; then
    echo "PASS FIND2 previous arm survives the rejected re-arm (1 slot, not 0)"
else
    echo "FAIL FIND2 previous arm was LOST after the rejected re-arm ($(OSTYPE=msys count_slots "$DB_F2" "$DBD_F2") slots, expected 1)"
    FAILED=$((FAILED+1))
fi

# FIND2b (HIMMEL-1304 round-5): if restoring that backup itself fails, the
# refusal must surface the failure and retain the XML as the operator's sole
# recovery artifact. SCHED_XML_CREATE_FAIL affects only `/create /xml`, so the
# replacement registration still succeeds and reaches the rejected-verify path.
out=$(SCHED_XML_CREATE_FAIL=1 TMPDIR="$TMP" SCHED_DB="$DB_F2" SCHED_DB_DIR="$DBD_F2" \
    win_env "$FIND2" bash "$ARM" --time "$(future_time)" --handover "$FIND2_HO" --force 2>&1)
rc=$?
assert_rc "FIND2b failed backup restore still refuses (rc=2)" 2 "$rc"
assert_contains "FIND2b restore failure is surfaced" "FAILED to restore the previous arm" "$out"
assert_contains "FIND2b error names the retained recovery XML" "Backup XML retained at" "$out"
FIND2_BACKUP=$(printf '%s\n' "$out" | sed -n "s/.*Backup XML retained at '\([^']*\)'.*/\1/p")
if [ -n "$FIND2_BACKUP" ] && [ -s "$FIND2_BACKUP" ]; then
    echo "PASS FIND2b failed restore preserves the named backup XML ($FIND2_BACKUP)"
else
    echo "FAIL FIND2b failed restore lost the named backup XML (path='$FIND2_BACKUP')"
    FAILED=$((FAILED+1))
fi
fi

# ---------------------------------------------------------------------------
# HIMMEL-1365 — refuse to arm a REAL task against a TEMP/scratch target.
#
# The 2026-07 incident: a hand-run repro created a real schtasks entry pointing
# at a scratchpad fixture, firing at 23:59 into an unattended session. The whole
# suite arms $TMP fixtures deliberately (see the ARM_TEMP_CWD_OK shield above),
# so these cases unset it to exercise the guard itself.
# ---------------------------------------------------------------------------
if _sec_selected "1365" "HIMMEL-1365"; then
R1365="$TMP/h1365"
mkdir -p "$R1365/handovers"
printf -- '---\nresume_cwd: %s\n---\n\n# temp target\n' "$WORK_REPO" \
    > "$R1365/handovers/temp-target.md"

out=$(env -u ARM_TEMP_CWD_OK TMPDIR="$TMP" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$R1365/handovers/temp-target.md" 2>&1)
assert_rc "1365 temp work dir refuses (rc=12)" 12 "$?"
assert_contains "1365 ERR names the temp path" "TEMP/scratch path" "$out"
assert_contains "1365 ERR names the override" "ARM_TEMP_CWD_OK=1" "$out"

# The declared opt-out lets a harness arm its own fixture.
out=$(ARM_TEMP_CWD_OK=1 TMPDIR="$TMP" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$R1365/handovers/temp-target.md" 2>&1)
rc=$?
if [ "$rc" -eq 12 ]; then
    echo "FAIL 1365 ARM_TEMP_CWD_OK=1 did not override the temp refusal"
    FAILED=$((FAILED + 1))
else
    echo "PASS 1365 ARM_TEMP_CWD_OK=1 overrides the temp refusal (rc=$rc)"
fi

# --dry-run is exempt: it creates no scheduled task, so there is nothing to
# protect against, and the suite's own dry-run cases must keep working.
out=$(env -u ARM_TEMP_CWD_OK TMPDIR="$TMP" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$R1365/handovers/temp-target.md" --dry-run 2>&1)
rc=$?
if [ "$rc" -eq 12 ]; then
    echo "FAIL 1365 --dry-run must be exempt from the temp refusal"
    FAILED=$((FAILED + 1))
else
    echo "PASS 1365 --dry-run is exempt from the temp refusal (rc=$rc)"
fi

# A NON-temp target must be unaffected — the guard keys on the target path, so
# this is what proves it is not simply refusing everything.
R1365_REAL="$TMP/h1365-real"   # under $TMP, but the RESUME_CWD below is not
mkdir -p "$R1365_REAL"
printf -- '---\nresume_cwd: %s\n---\n\n# real target\n' "$PWD" \
    > "$R1365_REAL/real-target.md"
out=$(env -u ARM_TEMP_CWD_OK -u ARM_FIXTURE_OK TMPDIR="$TMP" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$R1365_REAL/real-target.md" 2>&1)
rc=$?
# HIMMEL-1879 widened the guard from cwd-only to BOTH halves of the fired
# session's identity, so this fixture (temp HANDOVER, real cwd) now refuses --
# and it should: arming a REAL unattended session that loads throwaway
# instructions INTO a real repo is the worse half of the 2026-07 incident
# shape, not the safe half. What still has to hold is that the guard stays
# DISCRIMINATING rather than blanket, which the ERR proves by naming which half
# tripped: the handover file, and NOT the (real) work directory.
assert_rc "1365 a temp HANDOVER refuses even with a real work dir (rc=12)" 12 "$rc"
assert_contains "1365 the ERR names the handover half" "handover file:" "$out"
assert_not_contains "1365 the ERR does NOT blame the real work dir" "target work directory:" "$out"
fi

# ---------------------------------------------------------------------------
# HIMMEL-1331 — refuse to re-arm work that already shipped.
#
# Two real instances on 2026-07-28: HIMMEL-1296 re-armed at 23:40 after merging
# at 21:25; HIMMEL-1286 re-armed while PR #1428 was open and mergeable. Each
# burns a full autonomous session and produces rework.
#
# Hermetic: gh is a PATH stub whose output is scripted per case, so nothing
# reaches the network. The stub also stands in for "gh is present" — its
# ABSENCE is what the fail-open case exercises.
# ---------------------------------------------------------------------------
# assert_not_11 <label> <rc> -- the invariant for every non-refusing case.
# Downstream codes vary (0/1/3) as scheduler + registry state accumulates
# across these reruns; what each case pins is that the SHIPPED preflight did
# not fire.
assert_not_11() {
    if [ "$2" -eq 11 ]; then
        echo "FAIL $1 — shipped preflight fired (rc=11)"; FAILED=$((FAILED + 1))
    else
        echo "PASS $1 (rc=$2)"
    fi
}

if _sec_selected "1331" "HIMMEL-1331"; then
R1331="$TMP/h1331"
mkdir -p "$R1331/bin" "$R1331/repo" "$R1331/state/handovers"
( cd "$R1331/repo" && git init -q -b feat/shipped-thing . \
    && git config user.email t@t.t && git config user.name t \
    && git config commit.gpgsign false \
    && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
printf -- '---\nresume_cwd: %s\n---\n\n# HIMMEL-9001 shipped thing\n' "$R1331/repo" \
    > "$R1331/state/handovers/shipped.md"

# The stub is reached through GH_CMD, NOT through PATH. On Windows a PATH
# stub does not work here: an extensionless `gh` script loses to gh.exe even
# when its directory comes first, so a PATH-stubbed test silently exercises the
# REAL gh (verified while writing these). GH_CMD is the house seam for exactly
# this -- see scripts/graphify/graph-publish.sh and scripts/cr/*.
GH_FAKE="$R1331/bin/ghfake"
mk_gh_stub() { # <tsv-payload: number \t state \t mergeable>
    {
        printf '#!/usr/bin/env bash\n'
        printf 'case "$*" in *"pr list"*) printf "%%s\\n" "%s";; *) exit 0;; esac\n' "$1"
    } > "$GH_FAKE"
    chmod +x "$GH_FAKE"
}

# Sets $out and RETURNS the rc. Deliberately NOT `rc=$(_a1331)`: command
# substitution runs the function in a SUBSHELL, so $out is assigned there and
# lost here -- which leaves every message assertion comparing against an EMPTY
# string while the rc assertions still pass. That is exactly how the first cut
# of these tests reported "ERR names the merged PR: output missing" for a
# refusal that had in fact printed it.
_a1331() {
    out=$(TMPDIR="$TMP" GH_CMD="${GHC_1331:-$GH_FAKE}" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" \
        --handover "$R1331/state/handovers/shipped.md" "$@" 2>&1)
}

# (a) MERGED PR on the branch -> refuse rc=11, naming the PR.
mk_gh_stub '1428	MERGED	UNKNOWN'
_a1331; rc=$?
assert_rc "1331 merged PR refuses (rc=11)" 11 "$rc"
assert_contains "1331 ERR names the merged PR" "PR #1428" "$out"
assert_contains "1331 ERR names the branch" "feat/shipped-thing" "$out"
assert_contains "1331 ERR points at the override" "ARM_SHIPPED_OK=1" "$out"

# (b) OPEN + MERGEABLE -> the HIMMEL-1286 shape (work finished, waiting on a
# human), also refuses.
mk_gh_stub '1428	OPEN	MERGEABLE'
_a1331; rc=$?
assert_rc "1331 open+mergeable PR refuses (rc=11)" 11 "$rc"
assert_contains "1331 ERR says OPEN and MERGEABLE" "OPEN and MERGEABLE" "$out"

# (c) OPEN but CONFLICTING -> real unfinished work, must NOT refuse.
mk_gh_stub '1428	OPEN	CONFLICTING'
_a1331; assert_not_11 "1331 conflicting PR does not trip the preflight" "$?"

# (d) CLOSED unmerged -> abandoned, not shipped; must NOT refuse.
mk_gh_stub '1428	CLOSED	UNKNOWN'
_a1331; assert_not_11 "1331 closed-unmerged PR does not trip the preflight" "$?"

# (e) --force overrides a MERGED PR (the ticket's documented escape hatch).
mk_gh_stub '1428	MERGED	UNKNOWN'
_a1331 --force; assert_not_11 "1331 --force overrides the shipped refusal" "$?"

# (f) ARM_SHIPPED_OK=1 is the env twin of --force.
ARM_SHIPPED_OK=1 _a1331
assert_not_11 "1331 ARM_SHIPPED_OK=1 overrides the shipped refusal" "$?"

# (g) FAIL-OPEN: gh unavailable. A machine that cannot answer the question must
# still arm -- refusing because the box is offline would be a worse failure than
# the one this check prevents.
GHC_1331=/nonexistent/gh _a1331
assert_not_11 "1331 fails open when gh is unavailable" "$?"

# (h) --dry-run must stay side-effect-free: it skips the network probes.
mk_gh_stub '1428	MERGED	UNKNOWN'
_a1331 --dry-run; assert_not_11 "1331 --dry-run skips the shipped preflight" "$?"
fi

# ---------------------------------------------------------------------------
# HIMMEL-1331 (bug fix, part of the 1329/1330/1331 trio) — the TICKET-STATUS
# half of the shipped preflight ((a) in _arm_shipped_preflight) was dead code:
# _ho_ticket was `unset` right after TASK_NAME derivation but read again later
# via `${_ho_ticket:-}`, so it was always empty and the Done/Closed/wont-do/
# wont-fix check never ran. Confirmed before this fix: none of the (a)-(h)
# cases above exercise it — every one only drives the PR/branch half. Fixed
# by keeping _ho_ticket alive. ARM_JIRA_CLI is a new test seam (added
# alongside the fix, same shape as GH_CMD/SCHTASKS_CMD) pointing the probe at
# a fixture CLI — this worktree has no built scripts/jira/dist/index.js to
# test against otherwise.
# ---------------------------------------------------------------------------
if _sec_selected "1331b" "1331" "HIMMEL-1331"; then
if command -v node >/dev/null 2>&1; then
    R1331B="$TMP/h1331b"
    mkdir -p "$R1331B/repo"
    ( cd "$R1331B/repo" && git init -q -b feat/ticket-status-thing . \
        && git config user.email t@t.t && git config user.name t \
        && git config commit.gpgsign false \
        && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
    JIRA_FAKE="$TMP/h1331b/jira-fake.js"
    cat > "$JIRA_FAKE" <<'EOF'
#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'get') {
    console.log(args[1] + '\tsome summary\t' + (process.env.FAKE_JIRA_STATUS || 'Open'));
}
EOF
    HO_1331B="$R1331B/repo-handover.md"
    printf -- '---\nticket: HIMMEL-9002\nresume_cwd: %s\n---\n\n# HIMMEL-9002 ticket-status thing\n' \
        "$R1331B/repo" > "$HO_1331B"

    _a1331b() {
        local status="$1"; shift
        out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh ARM_JIRA_CLI="$JIRA_FAKE" \
            FAKE_JIRA_STATUS="$status" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
            bash "$ARM" --time "$(future_time)" --handover "$HO_1331B" "$@" 2>&1)
    }

    _a1331b Done; rc=$?
    assert_rc "1331b Done ticket status refuses (rc=11)" 11 "$rc"
    assert_contains "1331b ERR names the ticket" "HIMMEL-9002" "$out"

    _a1331b "In Progress"; assert_not_11 "1331b In-Progress ticket does not trip the preflight" "$?"

    _a1331b Done --force; assert_not_11 "1331b --force overrides the ticket-status refusal" "$?"

    ARM_SHIPPED_OK=1 _a1331b Done; assert_not_11 "1331b ARM_SHIPPED_OK=1 overrides the ticket-status refusal" "$?"
else
    echo "PASS 1331b skipped — node not available on this host"
fi
fi

# ---------------------------------------------------------------------------
# HIMMEL-2113c — leg-header false positive: a chained handover's H1 follows
# the epic's own "# Next Session — <leg-header>" convention (see
# make_handover_chained / N9-N13 above), and when a project happens to have
# an unrelated Done ticket numbered like the leg, _infer_ticket's src-3 (H1
# scan) used to weld THAT ticket into $_ho_ticket, false-tripping the
# HIMMEL-1331 shipped-work preflight (rc=11) against a handover that never
# referenced the real ticket at all. Fix: (1) the preflight now reads
# $_ho_ticket_strict (frontmatter-only), never the loose $_ho_ticket; (2)
# src-3 itself now skips H1 scanning for chain files (basename
# next-session-<N>.md) as defense-in-depth, so the loose ticket inference
# doesn't carry the leg-header key either. Both effects are asserted below.
# ---------------------------------------------------------------------------
if _sec_selected "2113c" "HIMMEL-2113"; then
if command -v node >/dev/null 2>&1; then
    R2113C="$TMP/h2113c"
    mkdir -p "$R2113C/repo"
    ( cd "$R2113C/repo" && git init -q -b feat/leg-header-thing . \
        && git config user.email t@t.t && git config user.name t \
        && git config commit.gpgsign false \
        && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
    JIRA_FAKE_2113C="$R2113C/jira-fake.js"
    cat > "$JIRA_FAKE_2113C" <<'EOF'
#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'get') {
    console.log(args[1] + '\tsome summary\tDone');
}
EOF
    # Chain file whose H1 is a leg header, NOT a ticket reference -- no
    # frontmatter ticket, generic (non-ticket-prefixed) epic dir so src-4
    # cannot supply a key either. LUNA-64 here stands in for the incident's
    # unrelated Done ticket that happens to share the leg number.
    mkdir -p "$R2113C/epic-notes"
    HO_2113C="$R2113C/epic-notes/next-session-64.md"
    printf -- '---\nresume_cwd: %s\n---\n\n# Next Session — LUNA-64\n' "$R2113C/repo" > "$HO_2113C"

    # ARM_PROFILE=1 (HIMMEL-2113 Ask B seam, reused here per codex-2): this
    # fixture's ticket resolves to EMPTY (that's the whole point -- the
    # leg-header must NOT supply one), so the preflight's own Jira-status
    # branch never prints anything either way, refusal or not. Without an
    # independent "the preflight code path actually ran" signal, a rc=10
    # live-worker-census refusal upstream of the preflight would still read
    # as rc!=11 and pass VACUOUSLY. The "shipped-work-preflight=" phase-timing
    # line is emitted unconditionally the instant _arm_shipped_preflight
    # returns (see the call site), regardless of what it found -- exactly the
    # deterministic-under-these-stubs marker this needs.
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh ARM_JIRA_CLI="$JIRA_FAKE_2113C" ARM_PROFILE=1 \
        SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$HO_2113C" 2>&1)
    rc=$?
    if printf '%s' "$out" | grep -q "shipped-work-preflight="; then
        # codex-3: deliberately not tightened to `assert_rc 0` -- this is a
        # REAL (non-dry-run) arm, so it runs the UNSTUBBED live worker census
        # (reconcile-workers.sh against this actual host's real lane workers,
        # same as the sibling 1331/1331b real-arm cases above). A live/
        # unprobeable worker on the box would legitimately rc=10 BEFORE
        # reaching the preflight -- caught by the branch below, not here. The
        # one invariant this case actually pins, now that we KNOW the
        # preflight ran, is "never rc=11" (the leg-header false positive).
        assert_not_11 "2113c leg-header false positive no longer refuses (rc!=11)" "$rc"
        assert_not_contains "2113c leg-header key not welded into the task name" "LUNA-64" "$out"
    else
        echo "PASS 2113c skipped — shipped-work preflight never ran (blocked upstream, e.g. a live/unprobeable worker on this host, rc=$rc); host state, not a fixture bug"
    fi
else
    echo "PASS 2113c skipped — node not available on this host"
fi
fi

# ---------------------------------------------------------------------------
# HIMMEL-2113d — explicit-time outrun WARN, printed at PARSE time (right
# after the --time HH:MM python resolve, before any slow phase runs) instead
# of only being discoverable via the end-of-script rollover guard. Purely
# advisory: rc stays 0 either way; --dry-run is fine since the check is one
# arithmetic compare against already-computed values.
# ---------------------------------------------------------------------------
if _sec_selected "2113d" "HIMMEL-2113"; then
NEAR_2113D=$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(minutes=2)).strftime("%H:%M"))')
HO_2113D=$(make_handover "$WORK_REPO")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$NEAR_2113D" --handover "$HO_2113D" --dry-run 2>&1)
rc=$?
assert_rc "2113d near --time still arms (rc=0, advisory only)" 0 "$rc"
assert_contains "2113d WARN fires early for a near --time" "outrun that lead" "$out"

HO_2113D2=$(make_handover "$WORK_REPO")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2113D2" --dry-run 2>&1)
rc=$?
assert_rc "2113d far --time arms (rc=0)" 0 "$rc"
assert_not_contains "2113d no outrun WARN for a far --time" "outrun that lead" "$out"
fi

# ---------------------------------------------------------------------------
# HIMMEL-2113e — ARM_PROFILE=1 emits a "PROFILE arm-resume: ..." line naming a
# known phase, on a plain success/dry-run exit AND on a REFUSAL exit. The
# refusal case pins the review-round EXIT-trap fix: the profile reporter is
# registered on a `trap ... EXIT` at the top of the script (not a hand-picked
# print before each success exit), so a mid-script refusal (rc=19 here, the
# Ask A quota-park guard) must still print it. Without that fix a refusal
# printed no PROFILE line at all.
# ---------------------------------------------------------------------------
if _sec_selected "2113e" "HIMMEL-2113"; then
HO_2113E=$(make_handover "$WORK_REPO")
out=$(ARM_PROFILE=1 SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2113E" --dry-run 2>&1)
rc=$?
assert_rc "2113e ARM_PROFILE dry-run still arms (rc=0)" 0 "$rc"
assert_contains "2113e PROFILE line names a known phase" "PROFILE arm-resume: queue-lock-probe" "$out"

FIVE_RESET_2113E=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')
SEVEN_RESET_2113E=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=6)).isoformat())')
BUSY_CACHE_2113E="$TMP/usage-95-2113e.json"
printf '{"five_hour":{"utilization":10.0,"resets_at":"%s"},"seven_day":{"utilization":95.0,"resets_at":"%s"}}' \
    "$FIVE_RESET_2113E" "$SEVEN_RESET_2113E" > "$BUSY_CACHE_2113E"
HO_2113E2=$(make_handover "$WORK_REPO")
out=$(ARM_PROFILE=1 RESUME_SLOT_CACHE="$BUSY_CACHE_2113E" SLOT_MAX_AGE=0 SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time smart --handover "$HO_2113E2" --force --dry-run 2>&1)
rc=$?
assert_rc "2113e refusal path still exits 19" 19 "$rc"
assert_contains "2113e PROFILE line fires on the EXIT-trap refusal path too" "PROFILE arm-resume: usage-cache-slot-resolve" "$out"
fi

# ---------------------------------------------------------------------------
# HIMMEL-2113f (codex-1 CONFIRMED fix) — a chain handover with NO frontmatter
# `ticket:` must still resolve its ticket from the PARENT DIR name (src-4) for
# the shipped-work preflight. The strict frontmatter-only narrowing (2113c)
# over-corrected: it closed the H1 leg-header false positive but also dropped
# this UNAMBIGUOUS signal, silently disabling the Jira-status half of the
# preflight for every no-frontmatter chain handover. Parent dir here IS
# ticket-shaped (HIMMEL-9004-slug) -- the opposite of 2113c's deliberately
# generic "epic-notes" dir -- so this pins the fallback without reopening the
# leg-header false positive (2113c already pins that H1 stays ignored).
# ---------------------------------------------------------------------------
if _sec_selected "2113f" "HIMMEL-2113"; then
if command -v node >/dev/null 2>&1; then
    R2113F="$TMP/h2113f"
    mkdir -p "$R2113F/repo"
    ( cd "$R2113F/repo" && git init -q -b feat/parent-dir-ticket-thing . \
        && git config user.email t@t.t && git config user.name t \
        && git config commit.gpgsign false \
        && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
    JIRA_FAKE_2113F="$R2113F/jira-fake.js"
    cat > "$JIRA_FAKE_2113F" <<'EOF'
#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'get') {
    console.log(args[1] + '\tsome summary\tDone');
}
EOF
    # No `ticket:` frontmatter -- only the ticket-shaped parent dir name
    # (src-4) names HIMMEL-9004. H1 is a plain leg header, same convention as
    # 2113c, to prove this is the parent-dir fallback firing, not a stray H1
    # match (src-3 already skips H1 for chain files regardless).
    mkdir -p "$R2113F/HIMMEL-9004-parent-dir-thing"
    HO_2113F="$R2113F/HIMMEL-9004-parent-dir-thing/next-session-1.md"
    printf -- '---\nresume_cwd: %s\n---\n\n# Next Session — leg 1\n' "$R2113F/repo" > "$HO_2113F"

    # ARM_PROFILE=1 + a marker check (codex-1, same guard 2113c got): closes
    # the vacuous-pass hole where a live/unprobeable host worker rc=10s the
    # UNSTUBBED census before the preflight ever runs, and "rc=11" (or "not
    # 11") would otherwise be asserted against a run that never reached it.
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh ARM_JIRA_CLI="$JIRA_FAKE_2113F" ARM_PROFILE=1 \
        SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$HO_2113F" 2>&1)
    rc=$?
    if printf '%s' "$out" | grep -q "shipped-work-preflight="; then
        assert_rc "2113f parent-dir ticket (no frontmatter) still trips the Done refusal (rc=11)" 11 "$rc"
        assert_contains "2113f ERR names the parent-dir ticket" "HIMMEL-9004" "$out"
    else
        echo "PASS 2113f skipped — shipped-work preflight never ran (blocked upstream, e.g. a live/unprobeable worker on this host, rc=$rc); host state, not a fixture bug"
    fi

    # Second case: ARM_SHIPPED_OK=1 takes arm-resume's FIRST if-branch (a
    # no-op ":"), so _arm_shipped_preflight is NEVER called here even on a
    # correctly-working override -- "shipped-work-preflight=" would never
    # appear and would wrongly skip every run. The marker that instead proves
    # this run reached that decision point (regardless of which branch fires)
    # is "arms-registry-cross-host=", the phase immediately BEFORE it and
    # common to every branch.
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh ARM_JIRA_CLI="$JIRA_FAKE_2113F" ARM_SHIPPED_OK=1 ARM_PROFILE=1 \
        SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$HO_2113F" 2>&1)
    rc=$?
    if printf '%s' "$out" | grep -q "arms-registry-cross-host="; then
        assert_not_11 "2113f ARM_SHIPPED_OK=1 overrides the parent-dir ticket-status refusal" "$rc"
    else
        echo "PASS 2113f (ARM_SHIPPED_OK case) skipped — run never reached the shipped-work decision point (blocked upstream, e.g. a live/unprobeable worker on this host, rc=$rc); host state, not a fixture bug"
    fi
else
    echo "PASS 2113f skipped — node not available on this host"
fi
fi

# ---------------------------------------------------------------------------
# HIMMEL-2113g (codex-3) — the parent-dir fallback must NOT prefix-match: a
# dir named HIMMEL-9004foo is NOT the ticket HIMMEL-9004 (no delimiter after
# the digit run), even though a fake Jira would report HIMMEL-9004 as Done.
# The old bare `grep -oiE '^KEY-[0-9]+'` welded the prefix out regardless of
# what followed; this must resolve to NO ticket at all, so the preflight has
# nothing to check and the arm proceeds (rc != 11).
# ---------------------------------------------------------------------------
if _sec_selected "2113g" "HIMMEL-2113"; then
if command -v node >/dev/null 2>&1; then
    R2113G="$TMP/h2113g"
    mkdir -p "$R2113G/repo"
    ( cd "$R2113G/repo" && git init -q -b feat/parent-dir-prefix-thing . \
        && git config user.email t@t.t && git config user.name t \
        && git config commit.gpgsign false \
        && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
    JIRA_FAKE_2113G="$R2113G/jira-fake.js"
    cat > "$JIRA_FAKE_2113G" <<'EOF'
#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'get') {
    console.log(args[1] + '\tsome summary\tDone');
}
EOF
    # Parent dir is HIMMEL-9004foo -- NOT delimited after the digits, so this
    # must NOT resolve to ticket HIMMEL-9004 even though the fake Jira would
    # report it Done.
    mkdir -p "$R2113G/HIMMEL-9004foo"
    HO_2113G="$R2113G/HIMMEL-9004foo/next-session-1.md"
    printf -- '---\nresume_cwd: %s\n---\n\n# Next Session — leg 1\n' "$R2113G/repo" > "$HO_2113G"

    # ARM_PROFILE=1 + marker check (codex-1, same guard 2113c/2113f got): no
    # --force/ARM_SHIPPED_OK here, so this always takes the preflight-calling
    # branch on a clean run -- but a live/unprobeable host worker still rc=10s
    # the UNSTUBBED census first, which would make "rc!=11" pass vacuously.
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh ARM_JIRA_CLI="$JIRA_FAKE_2113G" ARM_PROFILE=1 \
        SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$HO_2113G" 2>&1)
    rc=$?
    if printf '%s' "$out" | grep -q "shipped-work-preflight="; then
        assert_not_11 "2113g undelimited parent-dir prefix does not false-trip the preflight (rc!=11)" "$rc"
        assert_not_contains "2113g HIMMEL-9004 never gets welded out of HIMMEL-9004foo" "HIMMEL-9004 is 'Done'" "$out"
    else
        echo "PASS 2113g skipped — shipped-work preflight never ran (blocked upstream, e.g. a live/unprobeable worker on this host, rc=$rc); host state, not a fixture bug"
    fi
else
    echo "PASS 2113g skipped — node not available on this host"
fi
fi

# ---------------------------------------------------------------------------
# HIMMEL-2128 — two ADVISORY pre-arm WARNs, printed at PARSE time (same
# "before any slow phase" placement as the 2113d outrun WARN above). Purely
# advisory: rc stays 0 (or whatever it already was) either way, so --dry-run
# is fine — the cheapest honest pin, same shape as 2113d.
# ---------------------------------------------------------------------------
if _sec_selected "2128" "HIMMEL-2128"; then
# (a) --automerge NOT passed -> WARN that the chain stops at green PRs.
# HIMMEL-2168: ambient ARMAUTOMERGE=1 (e.g. an armed himmel session's own
# exported env) would otherwise win over the absent .env value via
# load_dotenv's non-clobber contract and suppress the WARN. `env -u` alone
# handles the ambient-PROCESS-env case; the .env FILE half is handled by the
# top-of-suite ARM_RESUME_DOTENV_ROOT shield (HIMMEL-2254) -- on a host whose
# own .env sets ARMAUTOMERGE=1 (the HIMMEL-2147 default) `env -u` alone is
# NOT enough, because the key is re-read from disk.
#
# (a2) --automerge passed -> no WARN. Explicit --automerge always wins over
# both ambient env and .env (arm-resume.sh:955), so this case needs no
# shield.
HO_2128A2=$(make_handover "$WORK_REPO")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2128A2" --dry-run --automerge 2>&1)
rc=$?
assert_rc "2128a2 --automerge passed still arms (rc=0)" 0 "$rc"
assert_not_contains "2128a2 no WARN when --automerge is passed" "will NOT set ARMAUTOMERGE" "$out"

# (b) CR_REQUIRE_CROSS_MODEL truthy + CR_FLOOR_FALLBACK unset -> WARN that a
# mid-chain bank exhaustion parks the whole armed chain. Process env is
# authoritative over any .env for CR_REQUIRE_CROSS_MODEL=1 here — but
# CR_FLOOR_FALLBACK is NOT: load_dotenv treats an empty value as absent and
# reloads it from .env (HIMMEL-1922's own documented contract), so a bare
# `CR_FLOOR_FALLBACK=` on the invocation does NOT force genuine absence when
# the PRIMARY checkout's own .env already sets this key (this host's does).
# codex-4 (HIMMEL-2128): the previous version of this test SKIPPED the
# assertion whenever ambient .env set the key, which would let the WARN path
# regress unnoticed on exactly such a host and never exercised the typo case
# at all. So this suite controls CR_FLOOR_FALLBACK itself (and, per
# HIMMEL-2168 above, ARMAUTOMERGE for case (a)).
# HIMMEL-2254: ARM_RESUME_DOTENV_ROOT (top-of-suite shield) already points the
# dotenv READ at an EMPTY suite-owned dir, so ARMAUTOMERGE and CR_FLOOR_FALLBACK
# are genuinely absent here with no repo write and no skip branch -- the old
# worktree-`.env` trick skipped this whole group whenever the checkout it ran
# from already had a `.env`, i.e. always on a primary checkout.

# `env -u` is defense-in-depth against ambient PROCESS env on top of the
# .env shield above (load_dotenv's non-clobber contract would otherwise
# let a live ambient ARMAUTOMERGE win before .env is ever consulted).
HO_2128A=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2128A" --dry-run 2>&1)
rc=$?
assert_rc "2128a no --automerge still arms (rc=0, advisory only)" 0 "$rc"
assert_contains "2128a WARN fires when --automerge is not passed" "will NOT set ARMAUTOMERGE" "$out"

HO_2128B=$(make_handover "$WORK_REPO")
out=$(CR_REQUIRE_CROSS_MODEL=1 SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2128B" --dry-run 2>&1)
rc=$?
assert_rc "2128b cross-model + no fallback still arms (rc=0, advisory only)" 0 "$rc"
assert_contains "2128b WARN fires when CR_REQUIRE_CROSS_MODEL is on and CR_FLOOR_FALLBACK is unset" "PARKING the whole armed chain" "$out"

# (b3) CR_FLOOR_FALLBACK set to an UNRECOGNIZED value ("claude_only" typo,
# underscore not hyphen) -> WARN still fires. It never actually enables the
# fallback (clear-cr-marker.sh only recognizes the exact "claude-only"
# string), so production SHOULD warn here too. Non-empty process env wins
# over any .env regardless of which .env is in play, so this case needs no
# worktree-.env trick.
HO_2128B3=$(make_handover "$WORK_REPO")
out=$(CR_REQUIRE_CROSS_MODEL=1 CR_FLOOR_FALLBACK=claude_only SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2128B3" --dry-run 2>&1)
rc=$?
assert_rc "2128b3 cross-model + typo'd fallback value still arms (rc=0)" 0 "$rc"
assert_contains "2128b3 WARN fires when CR_FLOOR_FALLBACK does not match the recognized claude-only value" "PARKING the whole armed chain" "$out"

# (b2) CR_FLOOR_FALLBACK set to the recognized value -> no WARN. Non-empty
# process env wins over any .env, so this case is deterministic with no
# worktree-.env trick needed.
HO_2128B2=$(make_handover "$WORK_REPO")
out=$(CR_REQUIRE_CROSS_MODEL=1 CR_FLOOR_FALLBACK=claude-only SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2128B2" --dry-run 2>&1)
rc=$?
assert_rc "2128b2 cross-model + fallback set still arms (rc=0)" 0 "$rc"
assert_not_contains "2128b2 no WARN when CR_FLOOR_FALLBACK is set" "PARKING the whole armed chain" "$out"
fi

# ---------------------------------------------------------------------------
# HIMMEL-2147 — ARMAUTOMERGE .env default. When --automerge is not passed on
# this invocation, arm-resume.sh reads ARMAUTOMERGE from the PRIMARY
# checkout's .env (accepted truthy values: 1/true/on/yes, case-insensitive,
# arm-resume.sh:965) and treats it as if --automerge had been passed. An
# explicit --automerge on the invocation always wins regardless of .env
# (arm-resume.sh:955). Same worktree-local `.env` trick as 2128b above, so
# this suite controls the value with no change to the actual resolution code.
# ---------------------------------------------------------------------------
if _sec_selected "2147" "HIMMEL-2147"; then
# HIMMEL-2254: this section drives the .env value through the suite-owned
# ARM_RESUME_DOTENV_ROOT dir (declared with the other shields at the top),
# not through a throwaway `.env` written at the repo root. The old trick
# short-circuited `_load_dotenv_primary_for` on the FIRST dir that has a
# `.env` -- which meant it SKIPPED itself entirely whenever the checkout it
# ran from already had one (always, on a primary checkout), so the whole
# section was a vacuous PASS on exactly the hosts running it. The seam needs
# no repo write, no EXIT-trap backstop, and no skip branch.

# Ambient ARMAUTOMERGE (e.g. an operator shell that exports it for its own
# overnight-arm convenience) would otherwise win over the .env value under
# test via load_dotenv's own non-clobber contract (a live non-empty value
# is never overwritten, HIMMEL-1922) -- `env -u` makes every sub-case below
# hermetic to that ambient state, matching what it is actually testing.

# (a) .env ARMAUTOMERGE=1, no --automerge flag -> default applies: no WARN,
# launch text carries the grant.
printf 'ARMAUTOMERGE=1\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_2147A=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147A" --dry-run 2>&1)
rc=$?
assert_rc "2147a .env ARMAUTOMERGE=1 (no --automerge flag) still arms (rc=0)" 0 "$rc"
assert_not_contains "2147a no WARN -- .env default applied" "will NOT set ARMAUTOMERGE" "$out"
assert_contains "2147a launch carries ARMAUTOMERGE=1 from the .env default" "ARMAUTOMERGE=1" "$out"

# (b) .env ARMAUTOMERGE=TRUE (mixed-case truthy) -> same as (a).
printf 'ARMAUTOMERGE=TRUE\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_2147B=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147B" --dry-run 2>&1)
rc=$?
assert_rc "2147b .env ARMAUTOMERGE=TRUE still arms (rc=0)" 0 "$rc"
assert_not_contains "2147b no WARN -- truthy .env value is case-insensitive" "will NOT set ARMAUTOMERGE" "$out"

# (c) .env ARMAUTOMERGE=nope (unrecognized value) -> WARN still fires, no
# default applied.
printf 'ARMAUTOMERGE=nope\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_2147C=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147C" --dry-run 2>&1)
rc=$?
assert_rc "2147c .env ARMAUTOMERGE=nope still arms (rc=0)" 0 "$rc"
assert_contains "2147c WARN fires -- unrecognized .env value is not truthy" "will NOT set ARMAUTOMERGE" "$out"

# (d) explicit --automerge flag wins even when .env holds a falsy value.
printf 'ARMAUTOMERGE=0\n' > "$ARM_RESUME_DOTENV_ROOT/.env"
HO_2147D=$(make_handover "$WORK_REPO")
out=$(env -u ARMAUTOMERGE SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147D" --dry-run --automerge 2>&1)
rc=$?
assert_rc "2147d --automerge flag wins over a falsy .env value (rc=0)" 0 "$rc"
assert_not_contains "2147d no WARN when --automerge is explicit" "will NOT set ARMAUTOMERGE" "$out"
assert_contains "2147d launch carries ARMAUTOMERGE=1 from the explicit flag" "ARMAUTOMERGE=1" "$out"

# Restore the shield dir to its EMPTY default for any later section.
rm -f "$ARM_RESUME_DOTENV_ROOT/.env"
fi

# ---------------------------------------------------------------------------
# HIMMEL-1329 — ticket-level mutex: the SAME ticket armed twice via TWO
# DIFFERENT handover files must be refused, even though each handover's own
# derived TASK_NAME differs (so the per-handover dedup above, rc 3, never
# sees it).
# ---------------------------------------------------------------------------
if _sec_selected "1329" "HIMMEL-1329"; then
R1329="$TMP/h1329"
mkdir -p "$R1329/repo"
( cd "$R1329/repo" && git init -q . \
    && git config user.email t@t.t && git config user.name t \
    && git config commit.gpgsign false \
    && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
SCHED_DB_1329="$TMP/h1329-sched.db"; SCHED_DB_DIR_1329="$TMP/h1329-sched.atdir"
: > "$SCHED_DB_1329"; mkdir -p "$SCHED_DB_DIR_1329"
# Each sub-case below gets its OWN handover file for the SAME ticket: re-
# arming the SAME file would hit the per-handover dedup (rc 3) first and
# never reach the ticket-level check this section is testing.
HO_1329_A="$R1329/leg-a.md"
HO_1329_B="$R1329/leg-b.md"
HO_1329_D="$R1329/leg-d-force.md"
HO_1329_E="$R1329/leg-e-env-override.md"
HO_1329_C="$R1329/leg-c-unrelated.md"
printf -- '---\nticket: HIMMEL-9003\nresume_cwd: %s\n---\n\n# HIMMEL-9003 leg A\n' "$R1329/repo" > "$HO_1329_A"
printf -- '---\nticket: HIMMEL-9003\nresume_cwd: %s\n---\n\n# HIMMEL-9003 leg B\n' "$R1329/repo" > "$HO_1329_B"
printf -- '---\nticket: HIMMEL-9003\nresume_cwd: %s\n---\n\n# HIMMEL-9003 leg D\n' "$R1329/repo" > "$HO_1329_D"
printf -- '---\nticket: HIMMEL-9003\nresume_cwd: %s\n---\n\n# HIMMEL-9003 leg E\n' "$R1329/repo" > "$HO_1329_E"
printf -- '---\nticket: HIMMEL-9004\nresume_cwd: %s\n---\n\n# HIMMEL-9004 unrelated\n' "$R1329/repo" > "$HO_1329_C"

_a1329() {
    local ho="$1"; shift
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh SCHED_DB="$SCHED_DB_1329" SCHED_DB_DIR="$SCHED_DB_DIR_1329" \
        SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$ho" "$@" 2>&1)
}

_a1329 "$HO_1329_A"; rc=$?
assert_rc "1329 first leg (handover A) arms cleanly (rc=0)" 0 "$rc"

_a1329 "$HO_1329_B"; rc=$?
assert_rc "1329 second leg (handover B, SAME ticket) refuses (rc=13)" 13 "$rc"
assert_contains "1329 ERR names the ticket" "HIMMEL-9003" "$out"
assert_contains "1329 ERR points at the override" "ARM_TICKET_DUP_OK=1" "$out"

_a1329 "$HO_1329_D" --force; rc=$?
assert_rc "1329 --force overrides the ticket-dup refusal" 0 "$rc"

out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh SCHED_DB="$SCHED_DB_1329" SCHED_DB_DIR="$SCHED_DB_DIR_1329" \
    ARM_TICKET_DUP_OK=1 SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1329_E" 2>&1)
rc=$?
assert_rc "1329 ARM_TICKET_DUP_OK=1 overrides the ticket-dup refusal" 0 "$rc"

_a1329 "$HO_1329_C"; rc=$?
assert_rc "1329 leaves an unrelated ticket alone" 0 "$rc"
fi

# ---------------------------------------------------------------------------
# HIMMEL-1640 (item 2) — inferticketstrict frontmatter window must CLOSE. A
# handover whose YAML frontmatter never closes (only the opening `---`, no
# trailing `---`) must yield NO frontmatter ticket, so a `ticket:` line that
# lives in the BODY of that file is not parsed as frontmatter. Under the old
# one-pass `c==1` filter the unclosed block swallowed the whole body as
# frontmatter, so a body `ticket:` keyed the ticket mutex (HIMMEL-1329) and
# could spuriously refuse (rc 13) an unrelated handover that armed the same
# ticket for real. Failure direction is spurious refusal only; --force /
# ARM_TICKET_DUP_OK override still exists. This fix removes the noise.
# Leg C (codex-adv r2): OPENED-but-UNTERMINATED frontmatter is a hard parse
# error (rc 1, no arm) — silently yielding no ticket would let a REAL
# frontmatter ticket whose closing `---` was lost bypass the mutex (fail-open),
# the exact duplicate-resume race the mutex prevents.
# ---------------------------------------------------------------------------
if _sec_selected "1640" "HIMMEL-1640"; then
R1640="$TMP/h1640"
mkdir -p "$R1640/repo"
( cd "$R1640/repo" && git init -q . \
    && git config user.email t@t.t && git config user.name t \
    && git config commit.gpgsign false \
    && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
SCHED_DB_1640="$TMP/h1640-sched.db"; SCHED_DB_DIR_1640="$TMP/h1640-sched.atdir"
: > "$SCHED_DB_1640"; mkdir -p "$SCHED_DB_DIR_1640"
# Leg A: a WELL-FORMED (closed) frontmatter that really carries the ticket —
# arms HIMMEL-9999 for real, so the ticket mutex records an armed slot for it.
HO_1640_A="$R1640/leg-a-closed.md"
printf -- '---\nticket: HIMMEL-9999\nresume_cwd: %s\n---\n\n# HIMMEL-9999 leg A (closed frontmatter)\n' \
    "$R1640/repo" > "$HO_1640_A"
# Leg B: an UNCLOSED frontmatter block (only the opening `---`) whose BODY —
# not frontmatter — mentions the SAME ticket. With the bug this body line was
# treated as frontmatter and the mutex keyed HIMMEL-9999 onto leg B too (rc 13).
# --cwd is passed because an unclosed frontmatter also defeats resume_cwd:
# parsing (out of scope for item 2); it isolates this test to ticket inference.
HO_1640_B="$R1640/leg-b-unclosed.md"
printf -- '---\nsession_kind: test\nresume_cwd: %s\n\n# leg B (frontmatter never closes)\n\nticket: HIMMEL-9999\nsome unrelated body line\n' \
    "$R1640/repo" > "$HO_1640_B"

_a1640() {
    local ho="$1"; shift
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh SCHED_DB="$SCHED_DB_1640" SCHED_DB_DIR="$SCHED_DB_DIR_1640" \
        SCHTASKS_CMD="$STATEFUL_STUB/schtasks" PATH="$STATEFUL_STUB:$PATH" \
        bash "$ARM" --time "$(future_time)" --handover "$ho" "$@" 2>&1)
}

_a1640 "$HO_1640_A"; rc=$?
assert_rc "1640 leg A (closed frontmatter, real ticket) arms cleanly (rc=0)" 0 "$rc"
assert_contains "1640 leg A arm banner printed" "RESUME ARMED" "$out"

_a1640 "$HO_1640_B" --cwd "$R1640/repo"; rc=$?
assert_rc "1640 leg B (unclosed frontmatter) refuses with a parse error (rc=1), not a ticket-dup" 1 "$rc"
assert_contains "1640 leg B names the unclosed frontmatter" "unclosed YAML frontmatter" "$out"
assert_not_contains "1640 leg B is not refused as a ticket dup" "already has another armed resume slot" "$out"
assert_not_contains "1640 leg B did not arm" "RESUME ARMED" "$out"

# Leg C (codex-adv r2): a REAL frontmatter ticket whose closing `---` was
# truncated. Silently yielding no strict ticket here would bypass the
# HIMMEL-1329 mutex (leg A already holds an armed slot for HIMMEL-9999) and
# schedule a duplicate resume — the fail-open direction. Must hard-refuse
# (rc 1) with the parse error, before any scheduler mutation.
HO_1640_C="$R1640/leg-c-truncated.md"
printf -- '---\nticket: HIMMEL-9999\nresume_cwd: %s\n\n# HIMMEL-9999 leg C (closer lost)\n' \
    "$R1640/repo" > "$HO_1640_C"
_a1640 "$HO_1640_C" --cwd "$R1640/repo"; rc=$?
assert_rc "1640 leg C (truncated REAL frontmatter ticket) hard-refuses (rc=1), never silently bypasses the mutex" 1 "$rc"
assert_contains "1640 leg C names the unclosed frontmatter" "unclosed YAML frontmatter" "$out"
assert_not_contains "1640 leg C did not arm" "RESUME ARMED" "$out"

# Leg D (codex-adv r3): a frontmatter-LESS handover (first line is a `#`
# heading, not a `---` opener) whose BODY contains exactly ONE `---`
# horizontal rule. Under the pre-r3 code the unanchored opener entered
# frontmatter mode at that lone body rule and, never closing, tripped the
# round-2 unclosed-frontmatter hard error (rc 1) -- a REGRESSION that blocked
# perfectly valid plain-markdown handovers. With the line-1 anchor the body
# rule is ordinary text: no frontmatter is entered, so no parse error.
HO_1640_D="$R1640/leg-d-no-frontmatter-one-rule.md"
printf -- '# leg D (no frontmatter, one body rule)\n\nIntro before the rule.\n\n---\n\nBody after the rule.\n' \
    > "$HO_1640_D"
_a1640 "$HO_1640_D" --cwd "$R1640/repo"; rc=$?
assert_rc "1640 leg D (no frontmatter, one body --- rule) arms cleanly (rc=0), no false unclosed-block error" 0 "$rc"
assert_contains "1640 leg D arm banner printed" "RESUME ARMED" "$out"
assert_not_contains "1640 leg D not refused as unclosed frontmatter" "unclosed YAML frontmatter" "$out"

# Leg E (codex-adv r3): a frontmatter-LESS handover whose BODY carries TWO
# `---` horizontal rules surrounding `ticket: HIMMEL-9999` -- the SAME ticket
# leg A armed for real. Under the pre-r3 code the unanchored opener parsed
# these two body rules as a CLOSED frontmatter, inferred HIMMEL-9999 as a
# STRICT ticket, and the mutex (HIMMEL-1329) refused leg E as a duplicate of
# leg A's slot (rc 13). With the line-1 anchor no frontmatter is inferred,
# _ho_ticket_strict stays empty, the mutex gate is skipped, and leg E arms its
# own slot. --cwd isolates cwd resolution (there is no resume_cwd: to parse).
HO_1640_E="$R1640/leg-e-no-frontmatter-two-rules.md"
printf -- '# leg E (no frontmatter, two body rules)\n\nIntro.\n\n---\n\nticket: HIMMEL-9999\n\n---\n\nTrailer.\n' \
    > "$HO_1640_E"
_a1640 "$HO_1640_E" --cwd "$R1640/repo"; rc=$?
assert_rc "1640 leg E (no frontmatter, two body --- rules around a ticket) arms cleanly (rc=0), not a ticket dup" 0 "$rc"
assert_contains "1640 leg E arm banner printed" "RESUME ARMED" "$out"
assert_not_contains "1640 leg E not refused as a ticket dup" "already has another armed resume slot" "$out"
assert_not_contains "1640 leg E not refused as unclosed frontmatter" "unclosed YAML frontmatter" "$out"
fi

# ---------------------------------------------------------------------------
# HIMMEL-1330 — refuse to auto-detect a SINGLE-WRITER repo as the launch cwd.
# A handover with no --cwd/--worktree/resume_cwd:, sitting inside a repo
# marked `.single-writer` (the luna vault shape), must not silently arm
# INSIDE that repo.
# ---------------------------------------------------------------------------
if _sec_selected "1330" "HIMMEL-1330"; then
R1330="$TMP/h1330"
mkdir -p "$R1330/vault/handovers"
git init -q "$R1330/vault" >/dev/null 2>&1
touch "$R1330/vault/.single-writer"
HO_1330="$R1330/vault/handovers/no-resume-cwd.md"
printf -- '---\nsession_kind: test\n---\n\n# no resume_cwd handover\n' > "$HO_1330"

out=$(bash "$ARM" --time "$(future_time)" --handover "$HO_1330" --dry-run 2>&1)
rc=$?
assert_rc "1330 dry-run does not hard-fail (preview only)" 0 "$rc"
assert_contains "1330 dry-run warns about the vault refusal" "would REFUSE to arm" "$out"

out=$(bash "$ARM" --time "$(future_time)" --handover "$HO_1330" 2>&1)
rc=$?
assert_rc "1330 real arm refuses into a single-writer repo (rc=14)" 14 "$rc"
# The ERR text names the cwd as the script resolved it, which on Git-Bash is
# the Windows form (C:/Users/.../AppData/Local/Temp/tmp.X/h1330/vault) while
# $R1330 holds the MSYS form (/tmp/tmp.X/h1330/vault) -- and `realpath -m`
# here converts NEITHER into the other, so reconstructing the expected string
# is host-specific either way. Assert the distinctive tail instead: it is
# present verbatim in both spellings, on any host.
assert_contains "1330 ERR names the vault path" "h1330/vault" "$out"
assert_contains "1330 ERR points at the override" "ARM_VAULT_CWD_OK=1" "$out"

out=$(ARM_VAULT_CWD_OK=1 GH_CMD=/nonexistent/gh TMPDIR="$TMP" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1330" 2>&1)
rc=$?
assert_rc "1330 ARM_VAULT_CWD_OK=1 overrides the vault refusal" 0 "$rc"

# The arm above registered THIS handover's task in the (now stateful,
# HIMMEL-1879) stub scheduler, and --cwd does not change the derived task name,
# so without a reset the next arm of the SAME handover is a legitimate rc 3
# dedup hit rather than the vault-guard bypass under test. Clear the stub's
# scheduler, which is what "a fresh box" meant back when /create registered
# nothing.
: > "$TMP/armed-stub.tasks"
out=$(GH_CMD=/nonexistent/gh TMPDIR="$TMP" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1330" --cwd "$WORK_REPO" 2>&1)
rc=$?
assert_rc "1330 explicit --cwd bypasses the vault guard" 0 "$rc"

HO_1330B="$R1330/vault/handovers/with-resume-cwd.md"
printf -- '---\nsession_kind: test\nresume_cwd: %s\n---\n\n# has resume_cwd\n' "$WORK_REPO" > "$HO_1330B"
out=$(GH_CMD=/nonexistent/gh TMPDIR="$TMP" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1330B" 2>&1)
rc=$?
assert_rc "1330 resume_cwd: frontmatter bypasses the vault guard" 0 "$rc"

NORMAL_HO_1330=$(make_handover)
out=$(GH_CMD=/nonexistent/gh TMPDIR="$TMP" SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$NORMAL_HO_1330" 2>&1)
rc=$?
assert_rc "1330 leaves a normal auto-detected cwd alone" 0 "$rc"
fi

# ---------------------------------------------------------------------------
# HIMMEL-2147 — registry-bucket cwd fallback (arm-resume.sh ~2048), a
# pre-refusal fallback inside the same HIMMEL-1330 single-writer guard above
# (own section gate so `--only 2147` and `--only 1330` each pull exactly what
# they name). A handover parked under the bucket layout
# (handovers/<user>/<repo-bucket>/...) with no --cwd/--worktree/resume_cwd:,
# sitting inside a single-writer repo, looks up <repo-bucket> in the handover
# registry BEFORE refusing. Fail-closed by construction: no match, no
# registry file, or the resolved repo is ITSELF single-writer all fall
# through to the unchanged HIMMEL-1330 refusal.
# ---------------------------------------------------------------------------
if _sec_selected "2147" "HIMMEL-2147"; then
R2147="$TMP/h2147"
mkdir -p "$R2147/vault/handovers/testuser/myrepo-bucket"
git init -q "$R2147/vault" >/dev/null 2>&1
touch "$R2147/vault/.single-writer"
HO_2147_FB="$R2147/vault/handovers/testuser/myrepo-bucket/leg.md"
printf -- '---\nsession_kind: test\n---\n\n# bucket-shaped handover, no resume_cwd\n' > "$HO_2147_FB"

mkdir -p "$R2147/regwork"
git init -q "$R2147/regwork" >/dev/null 2>&1

REG_2147="$TMP/registry-2147.json"
printf '{"repos":{"himmel":{"bucket_name":"myrepo-bucket","path":"%s"}}}\n' "$R2147/regwork" > "$REG_2147"

# (e) success: bucket matches a registry entry whose path is NOT single-writer
# -> WARN names the fallback, real arm succeeds (rc=0) using that cwd.
out=$(HANDOVER_REGISTRY="$REG_2147" GH_CMD=/nonexistent/gh TMPDIR="$TMP" \
    SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147_FB" 2>&1)
rc=$?
assert_rc "2147e registry-bucket fallback resolves and arms (rc=0)" 0 "$rc"
assert_contains "2147e WARN names the bucket fallback" "falling back to the handover registry" "$out"
assert_contains "2147e WARN names the matched bucket" "myrepo-bucket" "$out"
: > "$TMP/armed-stub.tasks"

# (f) fail-closed: the registry-resolved path is ITSELF single-writer -> never
# resolves into it, falls through to the unchanged refusal (rc=14).
touch "$R2147/regwork/.single-writer"
out=$(HANDOVER_REGISTRY="$REG_2147" GH_CMD=/nonexistent/gh TMPDIR="$TMP" \
    SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147_FB" 2>&1)
rc=$?
assert_rc "2147f resolved-but-single-writer bucket falls through to refusal (rc=14)" 14 "$rc"
rm -f "$R2147/regwork/.single-writer"

# (g) fail-closed: registry file exists but has no matching bucket entry.
REG_2147_NOMATCH="$TMP/registry-2147-nomatch.json"
printf '{"repos":{"other":{"bucket_name":"unrelated-bucket","path":"%s"}}}\n' "$R2147/regwork" > "$REG_2147_NOMATCH"
out=$(HANDOVER_REGISTRY="$REG_2147_NOMATCH" GH_CMD=/nonexistent/gh TMPDIR="$TMP" \
    SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147_FB" 2>&1)
rc=$?
assert_rc "2147g no matching bucket in registry falls through to refusal (rc=14)" 14 "$rc"

# (h) fail-closed: no registry file at the resolved HANDOVER_REGISTRY path.
out=$(HANDOVER_REGISTRY="$TMP/registry-2147-missing.json" GH_CMD=/nonexistent/gh TMPDIR="$TMP" \
    SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2147_FB" 2>&1)
rc=$?
assert_rc "2147h missing registry file falls through to refusal (rc=14)" 14 "$rc"
fi

# ---------------------------------------------------------------------------
# HIMMEL-1337 — dedup/listing must not enumerate the ENTIRE Task Scheduler
# library. On Windows, arm-resume now tries a wildcard-filtered PowerShell
# listing FIRST (when SCHTASKS_CMD is left at its untouched default) and only
# falls back to the full `schtasks /query` scan if that is unavailable.
# Proven here by fabricating a job through the PowerShell stub ONLY — if the
# fast path is not wired up, the dedup-any check below would see an EMPTY
# scheduler (the trap schtasks stub, invoked only as a fallback, returns
# nothing) and rc would be 0, not 3.
# ---------------------------------------------------------------------------
if _sec_selected "1337" "HIMMEL-1337"; then
FAST1337="$TMP/fast1337-bin"
mkdir -p "$FAST1337"
SCHTASKS_CALL_LOG_1337="$TMP/fast1337-schtasks.log"; rm -f "$SCHTASKS_CALL_LOG_1337"
cat > "$FAST1337/schtasks" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SCHTASKS_CALL_LOG_1337"
exit 0
EOF
cat > "$FAST1337/powershell" <<'EOF'
#!/usr/bin/env bash
printf '"\\HIMMEL-Resume-fast1337-marker","1/1/2026 12:00:00 AM","Ready"\n'
EOF
chmod +x "$FAST1337/schtasks" "$FAST1337/powershell"

HO_1337=$(make_handover "$WORK_REPO")
out=$(env -u SCHTASKS_CMD PATH="$FAST1337:$PATH" OSTYPE=msys \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1337" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "1337 dedup-any dry-run sees the powershell-sourced job (rc=3)" 3 "$rc"
assert_contains "1337 ERR names the powershell-sourced job" "HIMMEL-Resume-fast1337-marker" "$out"
if [ -s "$SCHTASKS_CALL_LOG_1337" ]; then
    echo "FAIL 1337 the slow full schtasks /query path was still invoked"
    FAILED=$((FAILED + 1))
else
    echo "PASS 1337 the slow full schtasks /query path was bypassed (fast PowerShell path used)"
fi

# Regression: with SCHTASKS_CMD explicitly pinned (the pattern every OTHER
# test in this suite uses), the fast path must NOT intercept — the schtasks
# stub's own CSV is what gets read, byte-identical to pre-1337 behavior.
out=$(SCHTASKS_CMD="$FAST1337/schtasks" PATH="$FAST1337:$PATH" OSTYPE=msys \
    bash "$ARM" --time "$(future_time)" --handover "$(make_handover "$WORK_REPO")" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "1337 pinned SCHTASKS_CMD arms cleanly (its stub CSV is empty)" 0 "$rc"
if [ -s "$SCHTASKS_CALL_LOG_1337" ]; then
    echo "PASS 1337 pinned SCHTASKS_CMD still routes through the schtasks stub"
else
    echo "FAIL 1337 pinned SCHTASKS_CMD unexpectedly bypassed its own stub"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# HIMMEL-1603 — an arm must never be created without a registry record just
# because the CWD does not map to a handover root.
#
# handover_root() answers from HANDOVER_DIR or <cwd's git root>/handovers, i.e.
# from where we ARE, never from what we are ARMING. Arming from a cwd that maps
# to neither used to skip the queue-lock check, the cross-host dedup AND the
# registry write in one silent branch. Caught live 2026-08-06: an arm fired at
# 08:12 with no arms.jsonl record, ever.
#
# All three cases run --dry-run (no scheduler job) from a NON-git cwd with
# HANDOVER_DIR unset — the exact shape that used to fail open.
# ---------------------------------------------------------------------------
if _sec_selected "1603" "HIMMEL-1603"; then
R1603="$TMP/h1603"
mkdir -p "$R1603/state/handovers/yotamleo/himmel" "$R1603/notgit" "$R1603/loose"
printf -- '---\nresume_cwd: %s\n---\n\n# t\n' "$R1603/notgit" \
    > "$R1603/state/handovers/yotamleo/himmel/x.md"
# A handover deliberately NOT under any `handovers/` dir — the supported
# repo-root HANDOVER.md shape, which has no fallback to find.
printf -- '---\nresume_cwd: %s\n---\n\n# t\n' "$R1603/notgit" > "$R1603/loose/HANDOVER.md"

out=$(cd "$R1603/notgit" && env -u HANDOVER_DIR bash "$ARM" --time 23:58 --long-gap \
    --handover "$R1603/state/handovers/yotamleo/himmel/x.md" --dry-run 2>&1)
assert_contains "1603 derives the root from the handover path when the cwd cannot" \
    "using the root derived from the handover path instead" "$out"
assert_contains "1603 names the derived root" "$R1603/state/handovers" "$out"
assert_not_contains "1603 does not fall through to the unregistered-arm branch" \
    "invisible to the census" "$out"
# The whole point of deriving the root: queue-lock must now resolve, so its
# own "could not resolve" degradation must be gone.
assert_not_contains "1603 queue-lock receives the derived root" \
    "queue-lock: could not resolve handover root" "$out"

# Residual case: no `handovers/` ancestor exists, so there is genuinely nothing
# to derive. That still arms (fail-open is deliberate — an arm that already
# succeeded must not be undone), but it must say so LOUDLY and durably rather
# than emitting the old bland WARN that nobody could act on after the fact.
T1603="$R1603/tele"
out=$(cd "$R1603/notgit" && env -u HANDOVER_DIR SKILL_TELEMETRY_DIR="$T1603" bash "$ARM" \
    --time 23:58 --long-gap --handover "$R1603/loose/HANDOVER.md" --dry-run 2>&1)
assert_contains "1603 unresolvable root warns that the arm is unregistered" \
    "invisible to the census" "$out"
assert_contains "1603 unresolvable root names the remedy" "set HANDOVER_DIR" "$out"
fi

# ---------------------------------------------------------------------------
# T_SEAM (HIMMEL-1610): the SCHTASKS_CMD seam. arm-resume must route its
#       schtasks call through ${SCHTASKS_CMD:-schtasks}: a RECORDING stub
#       pinned by ABSOLUTE path (and NOT on PATH) is what runs, while
#       WINBIN's no-op schtasks -- which IS on PATH here -- is never reached.
#       Regression catch: against UNSEAMED code (a bare `schtasks`) PATH
#       resolution hits WINBIN's no-op, the recording stub is never invoked,
#       and the marker stays absent (verified out-of-band against a
#       seam-reverted copy: PASS-with here, FAIL-without there). OSTYPE=msys
#       is forced so the Windows/schtasks branch runs on any host (POSIX arms
#       use `at`, never schtasks). --dry-run with no --force is the safe way
#       to force a real schtasks /query: the dedup check invokes the
#       scheduler, /query is read-only, and /create is only printed -- nothing
#       is ever created.
# ---------------------------------------------------------------------------
if _sec_selected "T_SEAM"; then
SEAM_STUB_DIR="$TMP/seam-stub"          # recording stub -- deliberately NOT on PATH
mkdir -p "$SEAM_STUB_DIR"
cat > "$SEAM_STUB_DIR/schtasks" <<'EOF'
#!/usr/bin/env bash
# Marker file => this stub was the binary the seam routed the call to.
[ -n "${SEAM_MARKER_FILE:-}" ] && printf 'schtasks %s\n' "$*" >> "$SEAM_MARKER_FILE"
exit 0
EOF
chmod +x "$SEAM_STUB_DIR/schtasks"
SEAM_MARKER="$TMP/seam-marker.log"; rm -f "$SEAM_MARKER"
HO=$(make_handover "$WORK_REPO")
out=$(SCHTASKS_CMD="$SEAM_STUB_DIR/schtasks" SEAM_MARKER_FILE="$SEAM_MARKER" \
    GH_CMD=/no/such/gh-binary PATH="$WINBIN:$PATH" OSTYPE=msys \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T_SEAM seamed dry-run exits 0" 0 "$rc"
if [ -s "$SEAM_MARKER" ]; then
    echo "PASS T_SEAM SCHTASKS_CMD stub ran (seam honoured)"
else
    echo "FAIL T_SEAM SCHTASKS_CMD stub did NOT run -- seam not honoured"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T_PRUNE (HIMMEL-1624): the .bat age-prune lives in the .bat-builder, BEFORE
#       the DRY_RUN early-return, so without the DRY_RUN gate a --dry-run arm
#       would delete leaked himmel-resume.*.bat siblings -- a real side effect
#       that breaks the side-effect-free dry-run contract. arm-resume's
#       `mktemp -t` honors TMPDIR (and never overrides it), so pointing TMPDIR
#       at a sandbox places its own .bat next to a stale fixture and makes the
#       prune observable. TMPDIR is an env-prefix on the arm call only (never
#       exported), so it cannot leak into any other case. OSTYPE=msys + WINBIN
#       force the Windows/schtasks branch on any host (POSIX arms use `at`,
#       never a .bat) -- the same shape T_SEAM uses. The real-arm counterpart
#       (the prune STILL runs on the non-dry-run path) is verified by the
#       focused probe transcript; it is not asserted here because the post-arm
#       verify differs across hosts and is not what this regression is about.
# ---------------------------------------------------------------------------
if _sec_selected "T_PRUNE"; then
HO=$(make_handover "$WORK_REPO")
PRUNE_DIR="$TMP/prune-sandbox-$RANDOM"
mkdir -p "$PRUNE_DIR"
FIX="$PRUNE_DIR/himmel-resume.leaked.bat"
printf '@echo off\nrem stale leaked sibling\n' > "$FIX"
touch -t 200001010000 "$FIX"   # >7 days old so -mtime +7 would match it
out=$(TMPDIR="$PRUNE_DIR" SCHTASKS_CMD="$WINBIN/schtasks" \
    GH_CMD=/no/such/gh-binary PATH="$WINBIN:$PATH" OSTYPE=msys \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T_PRUNE dry-run exits 0" 0 "$rc"
# The fixture survival check only means something on the Windows/.bat path —
# assert the scheduler marker so a run that fell through to the POSIX arm
# (where no .bat prune exists at all) cannot pass vacuously (CR round 2).
assert_contains "T_PRUNE exercised the schtasks path" "would schtasks" "$out"
if [ -f "$FIX" ]; then
    echo "PASS T_PRUNE dry-run leaves a stale leaked .bat in place (no side effect)"
else
    echo "FAIL T_PRUNE dry-run pruned a stale .bat -- side effect under --dry-run"
    echo "     output: $out"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# T_PRUNE_REAL (HIMMEL-1606): the age-prune T_PRUNE above only exercises the
# --dry-run no-op path (the prune must NOT run there). This exercises the
# REAL prune on a real (non-dry-run) arm: a stale (>7d) sibling is deleted,
# a recent (1d) sibling and this arm's own freshly-minted .bat both survive.
# Reuses the ARMED_STUB scheduler stub (T23) so the arm completes without
# touching the real scheduler, and points TMPDIR at a sandbox (same seam
# T_PRUNE uses) so arm-resume's own `mktemp -t himmel-resume.XXXXXX.bat`
# lands next to the fixtures and the prune actually sees them.
# ---------------------------------------------------------------------------
if _sec_selected "T_PRUNE_REAL"; then
PRUNE1606_DIR="$TMP/prune1606-sandbox-$RANDOM"
mkdir -p "$PRUNE1606_DIR"
SIB_STALE_1606="$PRUNE1606_DIR/himmel-resume.stale1606.bat"
SIB_RECENT_1606="$PRUNE1606_DIR/himmel-resume.recent1606.bat"
printf '@echo off\nrem stale leaked sibling\n' > "$SIB_STALE_1606"
printf '@echo off\nrem recent leaked sibling\n' > "$SIB_RECENT_1606"
touch -t 200001010000 "$SIB_STALE_1606"   # >7 days old -- must be pruned
touch -t "$(python3 -c 'import datetime;print((datetime.datetime.now()-datetime.timedelta(days=1)).strftime("%Y%m%d%H%M"))')" \
    "$SIB_RECENT_1606"   # 1 day old -- must survive (portable: touch -d is GNU-only, BSD/macOS touch rejects it)

HO=$(make_handover "$WORK_REPO")
# win_env forces the WINDOWS arm path (OSTYPE=msys + WINBIN stubs): the .bat
# mint + prune under test are Windows-only code, so a bare invocation on a
# POSIX host would take the at/crontab path and fail the stale-pruned
# assertion without ever exercising the prune (codex-adv, 1606 CR round).
# win_env prefers $ARMED_STUB's schtasks, so the arm still completes.
out=$(TMPDIR="$PRUNE1606_DIR" win_env "$ARMED_STUB" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" 2>&1)
rc=$?
assert_rc "T_PRUNE_REAL real arm succeeds (rc 0)" 0 "$rc"

if [ -f "$SIB_STALE_1606" ]; then
    echo "FAIL T_PRUNE_REAL stale (>7d) sibling survived a real arm"
    FAILED=$((FAILED + 1))
else
    echo "PASS T_PRUNE_REAL stale (>7d) sibling was pruned"
fi

if [ -f "$SIB_RECENT_1606" ]; then
    echo "PASS T_PRUNE_REAL recent (1d) sibling survived"
else
    echo "FAIL T_PRUNE_REAL recent (1d) sibling was wrongly pruned"
    FAILED=$((FAILED + 1))
fi

_fresh_1606=$(find "$PRUNE1606_DIR" -maxdepth 1 -type f -name 'himmel-resume.*.bat' \
    ! -name "$(basename "$SIB_RECENT_1606")" 2>/dev/null)
if [ -n "$_fresh_1606" ]; then
    echo "PASS T_PRUNE_REAL this arm's own fresh .bat survives"
else
    echo "FAIL T_PRUNE_REAL this arm's own fresh .bat is missing after the arm"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# --- HIMMEL-1287 ---
# arm-resume.sh carried a FIFTH copy of the HIMMEL-1281 cmd.exe
# over-escaping bug: _cmd_metachar_escape() and two inlined copies (the
# prompt/cd-path pair, and the --channels spec) all caret-escaped
# ^ & < > | before HIMMEL-1281's shared cadence_cmd_escape existed. Every
# one of these sites interpolates INSIDE the double quotes the generated
# .bat wraps the value in, where cmd.exe treats ^ as a LITERAL character —
# caret-escaping there corrupts the value instead of protecting it
# (C:\some&dir becomes C:\some^&dir, a path that does not exist). The fix
# routes all of them through cadence_cmd_escape (scripts/lib/cadence-format.sh)
# and removes the now-orphaned _cmd_metachar_escape. These cases assert the
# generated .bat names the REAL value: % doubled, and & ^ < > | left
# completely alone (no inserted carets).
# ---------------------------------------------------------------------------

if _sec_selected "T1287"; then
# T1287a: cd-path site (`c`, --cwd) — the Windows-legal subset of hostile
# characters (%, &, ^; <>|"?* are illegal in real path components, the same
# constraint documented above the escape calls in arm-resume.sh).
HOSTILE_DIR="$TMP/hostile-cwd-$RANDOM/some&dir^100%"
mkdir -p "$HOSTILE_DIR"
HO=$(make_handover "$WORK_REPO")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --cwd "$HOSTILE_DIR" --force --dry-run 2>&1)
rc=$?
assert_rc "T1287a hostile --cwd dry-run exits 0" 0 "$rc"
assert_contains "T1287a cd /d names the real value (% doubled, & ^ literal)" 'some&dir^100%%' "$out"
assert_not_contains "T1287a no caret inserted before &" '^&dir' "$out"
assert_not_contains "T1287a no caret doubled for literal ^" '^^100' "$out"

# T1287b: prompt site (`p`) — RESUME_PROMPT is derived from the handover
# PATH ("load $HANDOVER_PATH overnight mode"), so a handover FILENAME
# carrying the same Windows-legal hostile subset exercises the prompt escape.
HOSTILE_HO="$HANDOVER_DIR/note&caret^100%.md"
printf -- '---\nsession_kind: test\n---\n# hostile prompt handover\n' > "$HOSTILE_HO"
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HOSTILE_HO" --cwd "$WORK_REPO" --force --dry-run 2>&1)
rc=$?
assert_rc "T1287b hostile prompt dry-run exits 0" 0 "$rc"
assert_contains "T1287b prompt names the real value (% doubled, & ^ literal)" 'note&caret^100%%.md overnight mode' "$out"
assert_not_contains "T1287b no caret inserted before &" '^&caret' "$out"
assert_not_contains "T1287b no caret doubled for literal ^" '^^100' "$out"

# T1287c: --channels free-text site (`cs`) — unlike a filesystem path, the
# --channels spec is unconstrained operator text and can carry the FULL
# hostile set, including < > | (illegal in real Windows path components).
# ARM_BRIDGE_LIVE=0 is the existing test seam that keeps the unrelated
# live-Telegram-bridge refusal (HIMMEL-225) out of the way.
HO=$(make_handover "$WORK_REPO")
out=$(ARM_BRIDGE_LIVE=0 SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --channels 'a%b&c^d<e>f|g' --force --dry-run 2>&1)
rc=$?
assert_rc "T1287c hostile --channels dry-run exits 0" 0 "$rc"
assert_contains "T1287c channels spec names the real value (% doubled, rest literal)" '--channels "a%%b&c^d<e>f|g"' "$out"
assert_not_contains "T1287c no caret inserted before &" '^&c' "$out"
assert_not_contains "T1287c no caret doubled for literal ^" '^^d' "$out"
assert_not_contains "T1287c no caret inserted before <" '^<e' "$out"
assert_not_contains "T1287c no caret inserted before >" '^>f' "$out"
assert_not_contains "T1287c no caret inserted before |" '^|g' "$out"
fi

# ---------------------------------------------------------------------------
# --- HIMMEL-1719 ---
# C1 delivery fix: RESUME_PROMPT carries a single-line pointer clause naming
# § Launch preamble in docs/handover/overnight-mode.md, so every armed
# relaunch names the standing instructions (the template preamble copies are
# retired — the doc is the single source). Guards: exactly one line (the
# prompt is re-quoted via printf %q / _bash_single_quote into schtasks .bat
# and cron lines, where an embedded newline is the documented Windows
# quoting-mangling trap), no double quote (the WSL branch refuses those,
# rc 2), and printf %q round-trip fidelity.
# ---------------------------------------------------------------------------

if _sec_selected "1719" "HIMMEL-1719"; then
echo "--- 1719 ---"
HO=$(make_handover "$WORK_REPO")
EXPECTED_1719="load $HO overnight mode. Apply the Launch preamble standing instructions in docs/handover/overnight-mode.md before Phase 1."

# Single-line + charset invariants on the fixture itself (pins the contract
# any future rewording must keep).
case "$EXPECTED_1719" in
    *$'\n'*) echo "FAIL 1719a expected prompt contains a newline"; FAILED=$((FAILED + 1)) ;;
    *) echo "PASS 1719a expected prompt is a single line" ;;
esac
case "$EXPECTED_1719" in
    *[\"\'%\&^\<\>\|\$\`]*) echo "FAIL 1719b expected prompt carries a quoting-hostile character"; FAILED=$((FAILED + 1)) ;;
    *) echo "PASS 1719b expected prompt is quoting-safe (no \" ' % & ^ < > | \$ \`)" ;;
esac

# printf %q round-trip (the cron/at path re-quotes the prompt exactly so).
q_1719=$(printf '%q' "$EXPECTED_1719")
rt_1719=""
eval "rt_1719=$q_1719"
if [ "$rt_1719" = "$EXPECTED_1719" ]; then
    echo "PASS 1719c prompt survives printf %q round-trip"
else
    echo "FAIL 1719c printf %q round-trip mangled the prompt"
    FAILED=$((FAILED + 1))
fi

# The built artifact: a Windows dry-run .bat must carry the full prompt —
# trigger phrase AND pointer clause — as ONE line.
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO" --cwd "$WORK_REPO" --force --dry-run 2>&1)
rc=$?
assert_rc "1719d pointer-clause dry-run exits 0" 0 "$rc"
assert_contains "1719d .bat carries the full prompt incl. pointer clause" "$EXPECTED_1719" "$out"
if grepq "$out" -E 'overnight mode\. Apply the Launch preamble standing instructions in docs/handover/overnight-mode\.md before Phase 1\.'; then
    echo "PASS 1719e trigger phrase and pointer clause share one line"
else
    echo "FAIL 1719e pointer clause split from the trigger phrase (embedded newline?)"
    FAILED=$((FAILED + 1))
fi

# Parity: both prompt builders (arm-resume.sh + schedule-resume.sh) carry
# the identical clause — a divergent pair is the drift class this retires.
# Count each builder SEPARATELY: a summed count over both files passes when
# one file carries both matches and the other carries none — the exact
# divergence this check exists to catch. Per-file also sidesteps `grep -c`'s
# `file:count` prefix, which an `awk -F:` split mis-parses on a Windows
# `C:/...` path. -F keeps the literal dots literal.
_clause_1719="overnight mode. Apply the Launch preamble standing instructions in docs/handover/overnight-mode.md before Phase 1."
# `|| true`, NOT `|| echo 0`: grep -c ALREADY prints its count (0) and exits 1
# on no-match, so an `echo 0` fallback appends a SECOND line and the numeric
# test below dies with "integer expected" instead of failing cleanly. The
# empty-guard covers a missing file (grep prints nothing, exits 2).
n_arm_1719=$(grep -cF "$_clause_1719" "$ARM" 2>/dev/null || true)
[ -n "$n_arm_1719" ] || n_arm_1719=0
n_sched_1719=$(grep -cF "$_clause_1719" "$(dirname "$ARM")/schedule-resume.sh" 2>/dev/null || true)
[ -n "$n_sched_1719" ] || n_sched_1719=0
if [ "$n_arm_1719" -ge 1 ] && [ "$n_sched_1719" -ge 1 ]; then
    echo "PASS 1719f arm-resume.sh and schedule-resume.sh build the identical clause"
else
    echo "FAIL 1719f prompt-builder parity broken (arm-resume=$n_arm_1719 schedule-resume=$n_sched_1719; each must be >=1)"
    FAILED=$((FAILED + 1))
fi
fi

# ---------------------------------------------------------------------------
# 1879 (HIMMEL-1879): the SUCCESS line must be EARNED.
#
# Three failures the ticket measured, each with its own case below:
#   a/b  --time smart picks ASAP (+4 min) but ARMING ITSELF can take longer than
#        that, so the task registers already-expired and the past-fire guard
#        deletes it -- net zero arms after an encouraging trail. Fixed by an
#        elapsed-aware lead floor applied at the LAST moment before /create.
#   c    schtasks /create rc=0 is not proof anything is scheduled. The arm is
#        queried BACK before the banner; nothing there = FAILURE, never SUCCESS.
#   d    a FIRED arm deletes its own registration, so the scheduler-based dedup
#        reads clean and a second invocation double-fires. The flow-run ledger
#        remembers the fire; it is consulted before arming.
#
# NOT covered here, deliberately: the "target lapsed mid-arm" branch of the
# post-arm verify. Reaching it needs wall-clock to cross a target during the
# run, and the only honest seam for that would be a fake `date` on PATH -- which
# every other helper in this suite also calls. It shares its refusal block (and
# its assertions) with case c; the elapsed-aware floor in a/b is what actually
# prevents it.
# ---------------------------------------------------------------------------
if _sec_selected "1879" "HIMMEL-1879" "1999" "HIMMEL-1999"; then
echo "--- 1879 ---"

# --- 1879a/b: elapsed-aware lead floor on a SENTINEL slot -------------------
# The bank-free fixture resolves --time smart to ASAP = now + 4 min (240s).
# ARM_MIN_LEAD_SEC=900 > 240 forces the bump deterministically without having to
# make the arm genuinely slow; =60 < 240 proves a comfortable lead is untouched.
S1879="$TMP/s1879-stub-bin"
make_stateful_sched "$S1879"
DB_1879="$TMP/s1879.tasks"; DBD_1879="$TMP/s1879.atdir"
SLOT_FREE_1879="$TMP/usage-free-1879.json"
printf '{"five_hour":{"utilization":0.0,"resets_at":"%s"},"seven_day":{"utilization":5.0,"resets_at":"%s"}}' \
    "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')" \
    "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=6)).isoformat())')" \
    > "$SLOT_FREE_1879"

: > "$DB_1879"; mkdir -p "$DBD_1879"
HO_1879A="$(make_handover "$WORK_REPO")"
out=$(ARM_MIN_LEAD_SEC=900 RESUME_SLOT_CACHE="$SLOT_FREE_1879" SLOT_MAX_AGE=0 \
    HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879a.jsonl" TMPDIR="$TMP" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" win_env "$S1879" \
    bash "$ARM" --time smart --handover "$HO_1879A" 2>&1)
rc=$?
assert_rc "1879a smart arm under a raised lead floor still succeeds (rc=0)" 0 "$rc"
assert_contains "1879a the sentinel target was pushed past the floor" "pushed the target forward" "$out"
assert_contains "1879a the WARN names the never-fires consequence" "never fires" "$out"
assert_contains "1879a it still reports an armed slot" "RESUME ARMED" "$out"

# The negative twin. Deliberately NOT the bank-free (ASAP, +4 min) cache: an arm
# on a loaded box can eat most of a 4-minute lead, so "no push happened" would be
# asserting about this machine's speed rather than about the guard. An EXHAUSTED
# seven_day window makes smart resolve to that window's RESET instead -- days
# out, still a SENTINEL, and far beyond any floor however slow the run.
: > "$DB_1879"
SLOT_BUSY_1879="$TMP/usage-busy-1879.json"
printf '{"five_hour":{"utilization":10.0,"resets_at":"%s"},"seven_day":{"utilization":95.0,"resets_at":"%s"}}' \
    "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')" \
    "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=6)).isoformat())')" \
    > "$SLOT_BUSY_1879"
# HIMMEL-2254: --long-gap is REQUIRED here, and says nothing about the lead
# floor this case is pinning. The exhausted-seven_day fixture above is what
# makes the target far out; HIMMEL-2113 later taught the `--time smart`
# branch to refuse a >1h park up front (rc=19) unless the operator accepts it
# with --long-gap. Without the flag this case died at that refusal and never
# reached the "no needless push" assertion it exists for -- a stale fixture,
# not a live-cap-state flake: TARGET_EPOCH comes from RESUME_SLOT_CACHE, so
# the ~6-day park is deterministic on every host.
HO_1879B="$(make_handover "$WORK_REPO")"
out=$(ARM_MIN_LEAD_SEC=120 RESUME_SLOT_CACHE="$SLOT_BUSY_1879" SLOT_MAX_AGE=0 \
    HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879b.jsonl" TMPDIR="$TMP" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" win_env "$S1879" \
    bash "$ARM" --time smart --handover "$HO_1879B" --long-gap 2>&1)
rc=$?
assert_rc "1879b a comfortable sentinel lead arms untouched (rc=0)" 0 "$rc"
assert_not_contains "1879b no needless push when the lead is fine" "pushed the target forward" "$out"

# --- 1879c: a reported-successful create that armed NOTHING -----------------
# /create returns 0 and records nothing; /query is therefore empty. Pre-fix the
# banner printed RESUME ARMED over an empty scheduler.
LIAR="$TMP/liar-stub-bin"
mkdir -p "$LIAR"
cat > "$LIAR/schtasks" <<'EOF'
#!/usr/bin/env bash
# /create claims success but registers nothing; every /query is empty.
case "${1:-}" in
    /create) exit 0 ;;
    *)       exit 0 ;;
esac
EOF
cat > "$LIAR/at" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null 2>&1 || true
exit 0
EOF
cat > "$LIAR/atq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$LIAR/powershell" <<'EOF'
#!/usr/bin/env bash
# Probe unavailable -> the HIMMEL-938 NextRunTime verify fail-opens, so this
# case exercises the HIMMEL-1879 existence verify specifically.
exit 1
EOF
cat > "$LIAR/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$LIAR/schtasks" "$LIAR/at" "$LIAR/atq" "$LIAR/powershell" "$LIAR/claude"
HO_1879C="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879c.jsonl" win_env "$LIAR" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879C" 2>&1)
rc=$?
assert_rc "1879c create-said-yes but nothing is scheduled -> FAILURE (rc=2)" 2 "$rc"
assert_contains "1879c the ERR names the missing entry" "post-arm verify found NO scheduler entry" "$out"
assert_not_contains "1879c no SUCCESS banner over an empty scheduler" "RESUME ARMED" "$out"

# --- 1879d: idempotency against an arm that already FIRED -------------------
# Arm for real, then reproduce the fired state exactly: the runner deletes its
# own registration (empty SCHED_DB) and appends its `armed-resume` start row to
# the flow-run ledger. The scheduler now reads clean; only the ledger remembers.
LEDGER_1879="$TMP/1879d.jsonl"
: > "$DB_1879"; : > "$LEDGER_1879"
HO_1879D="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" win_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D" 2>&1)
rc=$?
assert_rc "1879d first arm of this handover succeeds (rc=0)" 0 "$rc"
TASK_1879=$(printf '%s\n' "$out" | sed -n 's/^ *Task name: //p' | head -1 | tr -d '\r')
if [ -n "$TASK_1879" ]; then
    echo "PASS 1879d the arm reported a task name ($TASK_1879)"
else
    echo "FAIL 1879d could not read the derived task name from the banner"
    FAILED=$((FAILED + 1))
fi
# Fire it: self-delete + the ledger row the emitted runner writes.
: > "$DB_1879"
HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" bash "$(dirname "$ARM")/../lib/flow-run-ledger.sh" \
    --append-start "armed-resume" "" "testhost" "claude" "" "$TASK_1879" "" 4242 >/dev/null

out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" win_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D" 2>&1)
rc=$?
assert_rc "1879d re-arming a FIRED, still-unfinished handover is refused (rc=15)" 15 "$rc"
assert_contains "1879d the ERR names the already-fired state" "ALREADY FIRED" "$out"
assert_contains "1879d the ERR explains why the scheduler looks clean" "deletes its own" "$out"
if [ "$(OSTYPE=msys count_slots "$DB_1879" "$DBD_1879")" = "0" ]; then
    echo "PASS 1879d the refusal armed nothing (0 slots)"
else
    echo "FAIL 1879d the refusal still armed something ($(OSTYPE=msys count_slots "$DB_1879" "$DBD_1879") slots)"
    FAILED=$((FAILED + 1))
fi

out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" win_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D" --force 2>&1)
rc=$?
assert_rc "1879d --force overrides the fired-arm refusal (rc=0)" 0 "$rc"

# An automated safety arm is exempt (same carve-out as the HIMMEL-1475 long-gap
# guard): auto-arm-on-cap.sh cannot pass --force, and a watchdog that parks the
# machine is worse than the double-fire it is guarding against.
: > "$DB_1879"
out=$(ARM_RESUME_SAFETY_ARM=1 TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" win_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D" 2>&1)
rc=$?
assert_rc "1879d ARM_RESUME_SAFETY_ARM=1 is exempt from the fired-arm refusal (rc=0)" 0 "$rc"

# A run that ENDED is not a held seat. This is what keeps every stable-handover
# caller working -- auto-arm-on-cap.sh re-arms the operator's same status.md all
# day, and "fired once, refuse forever" would escalate it to MALFUNCTION.
LEDGER_1879B="$TMP/1879d-ended.jsonl"
: > "$DB_1879"; : > "$LEDGER_1879B"
HO_1879D3="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879B" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" win_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D3" 2>&1)
rc=$?
assert_rc "1879d seed: first arm of the completed-run fixture (rc=0)" 0 "$rc"
TASK_1879B=$(printf '%s\n' "$out" | sed -n 's/^ *Task name: //p' | head -1 | tr -d '\r')
: > "$DB_1879"
FR_LIB="$(dirname "$ARM")/../lib/flow-run-ledger.sh"
RUN_1879B=$(HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879B" bash "$FR_LIB" \
    --append-start "armed-resume" "" "testhost" "claude" "" "$TASK_1879B" "" 4243)
HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879B" bash "$FR_LIB" \
    --append-end "armed-resume" "$RUN_1879B" "" 0 "complete" "" "session finished" >/dev/null

out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879B" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" win_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D3" 2>&1)
rc=$?
assert_rc "1879d a fired run that COMPLETED re-arms freely (rc=0)" 0 "$rc"
assert_not_contains "1879d no refusal once the run ended" "ALREADY FIRED" "$out"

# A DIFFERENT handover is untouched by another handover's fire -- the normal
# chain (leg N arms handover N+1) must never trip this guard.
: > "$DB_1879"
HO_1879D2="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" win_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879D2" 2>&1)
rc=$?
assert_rc "1879d a different handover still arms freely (rc=0)" 0 "$rc"
assert_not_contains "1879d no cross-handover fired-block" "ALREADY FIRED" "$out"

# --- 1879e: the post-arm existence verify on the POSIX at backend -----------
# The verify asks list_existing, which is per-platform. Windows is covered by
# every case above (win_env); force the `at` backend once so a POSIX host is not
# discovering this path for the first time in CI. Both directions: a real at-job
# is FOUND (arms clean), and an at queue that swallowed the job REFUSES.
: > "$DB_1879"; rm -rf "$DBD_1879"; mkdir -p "$DBD_1879"
HO_1879E="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879e.jsonl" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" \
    PATH="$S1879:$PATH" OSTYPE=linux-gnu bash "$ARM" \
    --time "$(future_time)" --handover "$HO_1879E" 2>&1)
rc=$?
assert_rc "1879e a real at-job passes the existence verify (rc=0)" 0 "$rc"
assert_contains "1879e the at arm reports armed" "RESUME ARMED" "$out"

: > "$DB_1879"; rm -rf "$DBD_1879"; mkdir -p "$DBD_1879"
HO_1879E2="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879e2.jsonl" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" \
    PATH="$LIAR:$PATH" OSTYPE=linux-gnu bash "$ARM" \
    --time "$(future_time)" --handover "$HO_1879E2" 2>&1)
rc=$?
assert_rc "1879e an at queue that swallowed the job -> FAILURE (rc=2)" 2 "$rc"
assert_contains "1879e the POSIX ERR names the missing entry" "post-arm verify found NO scheduler entry" "$out"

# --- 1879f: "no task + the target has passed" is AMBIGUOUS -------------------
# Two causes produce that identical scheduler picture: the arm FIRED and deleted
# its own registration, or the create registered nothing and the clock ran out
# while we armed. Calling the second one CONSUMED tells the operator a session
# is already running -- they wait forever and nobody re-arms, which is the exact
# silent death this ticket exists to end. Only a fire leaves evidence: the
# runner's own `armed-resume` start row for this task name. Both directions are
# pinned below.
#
# Determinism without a fake clock: the stub's /create BLOCKS until a
# pre-computed absolute epoch (the requested minute, plus a margin) has gone
# past, then reports success having registered nothing. An explicit --time HH:MM
# is never pushed forward by the lead floor, so the target stays where the case
# put it however slow the box is. Each direction gets its OWN minute -- a spent
# one would re-resolve to TOMORROW and never lapse.
make_lapse_stub() { # <dir> <deadline-epoch> [<ledger> <task-name> <row-delay-sec>]
    local _d="$1" _deadline="$2" _ledger="${3:-}" _task="${4:-}" _delay="${5:-0}"
    local _fire=""
    # With the optional trailing args the stub also plays the FIRED RUNNER: it
    # appends that runner's own armed-resume start row <row-delay-sec> after
    # /create returns. That is the real ordering (HIMMEL-1999) -- the runner
    # deletes its registration first and writes its start row afterwards -- and
    # it is why these fixtures no longer pre-seed the row: a row that already
    # existed when the arm began is a PREVIOUS run's, and the verify must not
    # read it as this arm's fire.
    if [ -n "$_ledger" ]; then
        _fire="( sleep $_delay; HIMMEL_FLOW_RUNS_LEDGER='$_ledger' bash '$(dirname "$ARM")/../lib/flow-run-ledger.sh' --append-start 'armed-resume' '' 'testhost' 'claude' '' '$_task' '' 4247 >/dev/null 2>&1 ) &"
    fi
    mkdir -p "$_d"
    cat > "$_d/schtasks" <<EOF
#!/usr/bin/env bash
# /create: wait out the requested minute, then claim success having registered
# NOTHING. /query: always empty. Net picture at verify time = no task, target
# passed -- the ambiguous state, with (only when armed with a ledger above) the
# runner's own start row landing behind it.
case "\${1:-}" in
    /create) while [ "\$(date +%s)" -le $_deadline ]; do sleep 1; done; $_fire exit 0 ;;
    *)       exit 0 ;;
esac
EOF
    # Probe unavailable -> the HIMMEL-938 NextRunTime verify fail-opens, so the
    # EXISTENCE verify is what these cases exercise.
    printf '#!/usr/bin/env bash\nexit 1\n' > "$_d/powershell"
    chmod +x "$_d/schtasks" "$_d/powershell"
}
lapse_hhmm() { python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(minutes=2)).strftime("%H:%M"))'; }
lapse_epoch() { python3 -c '
import datetime, sys
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.datetime.now().astimezone()
cand = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(int(cand.timestamp()))
' "$1"; }

# The task name is derived from the handover, not the time, so a throwaway arm
# through the honest stub is the cheapest way to learn it (same trick as 1879d).
: > "$DB_1879"
HO_1879F="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$TMP/1879f-seed.jsonl" \
    SCHED_DB="$DB_1879" SCHED_DB_DIR="$DBD_1879" win_env "$S1879" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_1879F" 2>&1)
TASK_1879F=$(printf '%s\n' "$out" | sed -n 's/^ *Task name: //p' | head -1 | tr -d '\r')

# f1 (the regression this round is about): NO start row -> nothing fired.
LAPSE_HHMM=$(lapse_hhmm); LAPSE_EPOCH=$(lapse_epoch "$LAPSE_HHMM")
make_lapse_stub "$TMP/lapse1-stub-bin" "$((LAPSE_EPOCH + 3))"
LEDGER_1879F="$TMP/1879f.jsonl"; : > "$LEDGER_1879F"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" \
    win_env "$TMP/lapse1-stub-bin" \
    bash "$ARM" --time "$LAPSE_HHMM" --handover "$HO_1879F" 2>&1)
rc=$?
assert_rc "1879f no task + lapsed target + NO ledger row -> FAILURE (rc=2)" 2 "$rc"
assert_contains "1879f the ERR says the create registered nothing" "REGISTERED NOTHING" "$out"
assert_not_contains "1879f an arm that never fired is NEVER reported consumed" "RESUME CONSUMED" "$out"
assert_not_contains "1879f and never reported armed" "RESUME ARMED" "$out"

# f2: the SAME scheduler picture with the runner's own start row present -> it
# really did fire. --force skips the rc 15 already-fired refusal (which the row
# would otherwise trip before arming), leaving the post-arm verify as the thing
# under test.
LAPSE_HHMM2=$(lapse_hhmm); LAPSE_EPOCH2=$(lapse_epoch "$LAPSE_HHMM2")
# The start row is written BY THE STUB, after /create returns -- not pre-seeded.
# A row that already existed when the arm began belongs to a PREVIOUS run of the
# same task name (HIMMEL-1999 item 2), so pre-seeding would now describe the
# wrong scenario as well as failing.
make_lapse_stub "$TMP/lapse2-stub-bin" "$((LAPSE_EPOCH2 + 3))" "$LEDGER_1879F" "$TASK_1879F" 0
: > "$LEDGER_1879F"
utc_of() { python3 -c 'import datetime, sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
# HIMMEL-1879 (r5): a consumed arm must exit BEFORE the arms-registry
# publication. The task already fired, and queue-lock's HIMMEL-882 consume
# dropped its record when that session started -- republishing an "armed" row
# resurrects a stale PENDING entry that no fire will ever clear, i.e. a
# permanent rc 8 cross-host refusal for the next host to try this handover.
find "$TMP" -name arms.jsonl -delete 2>/dev/null || true
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" \
    win_env "$TMP/lapse2-stub-bin" \
    bash "$ARM" --time "$LAPSE_HHMM2" --handover "$HO_1879F" --force 2>&1)
rc=$?
assert_rc "1879f the same picture WITH a start row is CONSUMED, not failed (rc=0)" 0 "$rc"
assert_contains "1879f the CONSUMED banner is printed" "RESUME CONSUMED" "$out"
assert_not_contains "1879f a consumed arm never claims to be armed" "RESUME ARMED" "$out"
REG_1879F=$(find "$TMP" -name arms.jsonl -exec grep -lF "$TASK_1879F" {} + 2>/dev/null || true)
if [ -z "$REG_1879F" ]; then
    echo "PASS 1879f a consumed arm publishes NO arms-registry record"
else
    echo "FAIL 1879f a consumed arm left a stale armed record in: $REG_1879F"
    FAILED=$((FAILED + 1))
fi

# --- 1879g: schedule_arm's OWN consumed branch needs the same evidence ------
# The Windows NextRunTime probe reaches the identical ambiguity one layer
# earlier: NEXTRUN-NONE, the create finished BEFORE the target, and the target
# passed before the probe answered. Timing alone still cannot tell a
# self-deleted fire from a create that registered nothing, so with no ledger row
# this must refuse -- a CONSUMED banner here reports a session that never began.
# Determinism: /create returns instantly (so create-done < target, the branch's
# own precondition) and the POWERSHELL probe is what blocks past the minute --
# exactly the create->verify window the branch describes.
LAPSE_HHMM3=$(lapse_hhmm); LAPSE_EPOCH3=$(lapse_epoch "$LAPSE_HHMM3")
G1879="$TMP/lapse3-stub-bin"; mkdir -p "$G1879"
printf '#!/usr/bin/env bash\nexit 0\n' > "$G1879/schtasks"   # creates nothing, lists nothing
cat > "$G1879/powershell" <<EOF
#!/usr/bin/env bash
# Only the NextRunTime probe blocks; any other powershell use stays instant, or
# it could eat the lead BEFORE /create and land in the wrong branch.
case "\$*" in
    *NextRunTime*)
        while [ "\$(date +%s)" -le $((LAPSE_EPOCH3 + 3)) ]; do sleep 1; done
        echo NEXTRUN-NONE ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$G1879/schtasks" "$G1879/powershell"
: > "$LEDGER_1879F"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" win_env "$G1879" \
    bash "$ARM" --time "$LAPSE_HHMM3" --handover "$HO_1879F" 2>&1)
rc=$?
assert_rc "1879g NEXTRUN-NONE + lapsed target + NO ledger row -> FAILURE (rc=2)" 2 "$rc"
assert_contains "1879g the ERR names the missing NextRunTime" "found NO NextRunTime" "$out"
assert_not_contains "1879g timing alone never buys a CONSUMED banner" "RESUME CONSUMED" "$out"
assert_not_contains "1879g and never an ARMED one" "RESUME ARMED" "$out"

# --- 1879h: an OLD completed run is not evidence of THIS arm's fire ---------
# rc 15 deliberately lets a handover whose previous run ENDED re-arm (that is
# what keeps auto-arm-on-cap re-arming one status.md all day), so a stale start
# row for the same task name is the NORMAL steady state, not an anomaly.
# Without correlating the row to this arm's own start, that ancient row would be
# read as proof that a brand-new no-op create had fired.
LAPSE_HHMM4=$(lapse_hhmm); LAPSE_EPOCH4=$(lapse_epoch "$LAPSE_HHMM4")
make_lapse_stub "$TMP/lapse4-stub-bin" "$((LAPSE_EPOCH4 + 3))"
: > "$LEDGER_1879F"
RUN_1879OLD=$(HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" bash "$FR_LIB" \
    --append-start "armed-resume" "2020-01-01T00:00:00Z" "testhost" "claude" "" "$TASK_1879F" "" 4245)
HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" bash "$FR_LIB" \
    --append-end "armed-resume" "$RUN_1879OLD" "" 0 "complete" "" "old run finished" >/dev/null
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" \
    win_env "$TMP/lapse4-stub-bin" \
    bash "$ARM" --time "$LAPSE_HHMM4" --handover "$HO_1879F" 2>&1)
rc=$?
assert_rc "1879h an OLD completed start row is not THIS arm's fire (rc=2)" 2 "$rc"
assert_contains "1879h the ERR still says the create registered nothing" "REGISTERED NOTHING" "$out"
assert_not_contains "1879h a stale row never buys a CONSUMED banner" "RESUME CONSUMED" "$out"

# --- 1879j: the query's listing is a SNAPSHOT ------------------------------
# A scheduler read can list a task that then fires DURING the query, leaving
# found=non-empty AND the target passed. That used to read as a dead
# registered-but-expired entry: reap it and refuse -- sending the operator to
# re-arm a seat a live session already holds. With this arm's own start row
# present it is CONSUMED, and the registration is left alone, because the fired
# runner deletes its own as its first action.
LAPSE_HHMM5=$(lapse_hhmm); LAPSE_EPOCH5=$(lapse_epoch "$LAPSE_HHMM5")
J1879="$TMP/lapse5-stub-bin"; mkdir -p "$J1879"
J1879_DB="$TMP/lapse5.tasks"; : > "$J1879_DB"
cat > "$J1879/schtasks" <<EOF
#!/usr/bin/env bash
# /create REGISTERS and then blocks past the requested minute, so the target has
# lapsed by verify time; /query keeps listing it -- the stale snapshot a real
# query returns when the task fires mid-read. /delete only LOGS, so the case can
# prove the consumed path reaped nothing.
db="$J1879_DB"
cmd="\${1:-}"; shift || true
tn=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        /tn)   tn="\${2:-}"; shift 2 ;;
        /tn=*) tn="\${1#/tn=}"; shift ;;
        *)     shift ;;
    esac
done
case "\$cmd" in
    /query)
        [ -f "\$db" ] || exit 0
        while IFS= read -r t; do
            [ -n "\$t" ] && printf '"\\\\%s","2026-01-01","Ready"\\n' "\$t"
        done < "\$db"
        exit 0 ;;
    /create)
        printf '%s\\n' "\$tn" >> "\$db"
        while [ "\$(date +%s)" -le $((LAPSE_EPOCH5 + 3)) ]; do sleep 1; done
        # The fired runner's OWN start row, written after /create returns --
        # never pre-seeded (HIMMEL-1999 item 2: a row that predates the arm is
        # a previous run's and is not this arm's fire).
        ( HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" bash "$FR_LIB" \\
            --append-start "armed-resume" "" "testhost" "claude" "" "$TASK_1879F" "" 4246 >/dev/null 2>&1 ) &
        exit 0 ;;
    /delete) printf '%s\\n' "\$tn" >> "$J1879/delete.log"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$J1879/powershell"
chmod +x "$J1879/schtasks" "$J1879/powershell"
: > "$LEDGER_1879F"
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" win_env "$J1879" \
    bash "$ARM" --time "$LAPSE_HHMM5" --handover "$HO_1879F" --force 2>&1)
rc=$?
assert_rc "1879j a listing that fired mid-query is CONSUMED, not expired (rc=0)" 0 "$rc"
assert_contains "1879j the CONSUMED banner is printed" "RESUME CONSUMED" "$out"
assert_not_contains "1879j and never an ARMED banner" "RESUME ARMED" "$out"
if [ ! -s "$J1879/delete.log" ]; then
    echo "PASS 1879j the consumed path left the task's own registration alone"
else
    echo "FAIL 1879j the consumed path reaped a registration it should not have ($(tr '\n' ' ' < "$J1879/delete.log"))"
    FAILED=$((FAILED + 1))
fi

# --- 1999a: the evidence read is a WINDOW, not one look ---------------------
# The fired runner deletes its own registration as its FIRST action and appends
# its armed-resume start row only afterwards. A verify landing in that gap sees
# no task AND no row -- pre-fix it concluded REGISTERED NOTHING (rc 2) and sent
# the operator to re-arm a seat the session starting right then already held.
# The stub reproduces exactly that ordering: /create registers nothing and the
# row lands a second after it returns.
LAPSE_HHMM6=$(lapse_hhmm); LAPSE_EPOCH6=$(lapse_epoch "$LAPSE_HHMM6")
make_lapse_stub "$TMP/lapse6-stub-bin" "$((LAPSE_EPOCH6 + 3))" "$LEDGER_1879F" "$TASK_1879F" 1
: > "$LEDGER_1879F"
find "$TMP" -name arms.jsonl -delete 2>/dev/null || true
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" \
    win_env "$TMP/lapse6-stub-bin" \
    bash "$ARM" --time "$LAPSE_HHMM6" --handover "$HO_1879F" 2>&1)
rc=$?
assert_rc "1999a a start row that lands after the verify's FIRST look is still this arm's fire (rc=0)" 0 "$rc"
assert_contains "1999a the CONSUMED banner is printed" "RESUME CONSUMED" "$out"
assert_not_contains "1999a no REGISTERED NOTHING inside the runner's own start-row gap" "REGISTERED NOTHING" "$out"
assert_not_contains "1999a a consumed arm never claims to be armed" "RESUME ARMED" "$out"

# --- 1999b: a PRIOR run's row is never this arm's fire, whatever it stamps --
# The recency test compares second-resolution stamps INCLUSIVELY, so a completed
# earlier run whose start row is stamped at or after this arm's start second
# passed it -- and rc 15 deliberately lets a handover whose previous run ENDED
# re-arm all day, which makes such a row the steady state, not an anomaly. 1879h
# pins the same rule for an OLD row; this is the one an inclusive compare cannot
# reject on timing, so it is settled by the pre-arm snapshot instead: the row was
# already there before anything of ours was registered.
LAPSE_HHMM7=$(lapse_hhmm); LAPSE_EPOCH7=$(lapse_epoch "$LAPSE_HHMM7")
make_lapse_stub "$TMP/lapse7-stub-bin" "$((LAPSE_EPOCH7 + 3))"
: > "$LEDGER_1879F"
RUN_1999B=$(HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" bash "$FR_LIB" \
    --append-start "armed-resume" "$(utc_of "$LAPSE_EPOCH7")" "testhost" "claude" "" "$TASK_1879F" "" 4248)
HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" bash "$FR_LIB" \
    --append-end "armed-resume" "$RUN_1999B" "" 0 "complete" "" "prior run finished" >/dev/null
out=$(TMPDIR="$TMP" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER_1879F" \
    win_env "$TMP/lapse7-stub-bin" \
    bash "$ARM" --time "$LAPSE_HHMM7" --handover "$HO_1879F" 2>&1)
rc=$?
assert_rc "1999b a completed PRIOR run stamped after this arm's start is not its fire (rc=2)" 2 "$rc"
assert_contains "1999b the ERR still says the create registered nothing" "REGISTERED NOTHING" "$out"
assert_not_contains "1999b a pre-existing row never buys a CONSUMED banner" "RESUME CONSUMED" "$out"
fi

# ---------------------------------------------------------------------------
# 1879-1365: the HIMMEL-1365 guard now keys on BOTH halves of the fired
# session's identity (cwd AND handover), and answers a read-only sweep.
# ---------------------------------------------------------------------------
if _sec_selected "1879-1365" "1365" "HIMMEL-1365" "1998" "HIMMEL-1998"; then
echo "--- 1879-1365 ---"
HO_T1365="$(make_handover "$WORK_REPO")"
out=$(env -u ARM_TEMP_CWD_OK -u ARM_FIXTURE_OK TMPDIR="$TMP" \
    SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$HO_T1365" 2>&1)
rc=$?
assert_rc "1879-1365 a temp-rooted fixture is refused (rc=12)" 12 "$rc"
assert_contains "1879-1365 the ERR names the handover file, not just the cwd" "handover file:" "$out"
assert_contains "1879-1365 the ERR names the ticket's opt-in spelling" "ARM_FIXTURE_OK=1" "$out"

out=$(env -u ARM_TEMP_CWD_OK ARM_FIXTURE_OK=1 TMPDIR="$TMP" \
    SCHTASKS_CMD="$ARMED_STUB/schtasks" PATH="$ARMED_STUB:$PATH" bash "$ARM" \
    --time "$(future_time)" --handover "$HO_T1365" --dry-run 2>&1)
rc=$?
assert_rc "1879-1365 ARM_FIXTURE_OK=1 opts in (rc=0)" 0 "$rc"

# --- --list-temp-arms: read-only sweep --------------------------------------
LTA="$TMP/lta-stub-bin"
mkdir -p "$LTA"
LTA_BAT="$TMP/lta-runner.bat"
printf 'cd /d "C:\\Users\\test\\AppData\\Local\\Temp\\scratchpad\\work2"\r\n' > "$LTA_BAT"
# HIMMEL-1998: the stub answers `/fo LIST /v` with a NON-ENGLISH label
# ("Tarea a ejecutar:" — the localized spelling of "Task To Run:"), and carries
# the runner path only in the locale-invariant `/xml` <Command> element. A
# sweep that regresses to label parsing therefore reads an EMPTY runner path
# and reports this temp-targeted arm as clean, which is what the cases below
# fail on. LTA_NO_XML=1 makes the XML query itself fail (access denied / task
# vanished) to pin the degraded-not-clean report.
cat > "$LTA/schtasks" <<EOF
#!/usr/bin/env bash
# /query /fo CSV /nh -> the armed roster; /query /tn .. /xml ONE -> its runner.
case "\$*" in
    *"/xml"*)
        # The second roster entry (LTA_TWO=1) is the one the scheduler refuses
        # to describe, so a sweep can carry a hit AND a blind spot at once.
        if [ "\${LTA_NO_XML:-0}" = "1" ]; then exit 1; fi
        case "\$*" in *unreadable*) exit 1 ;; esac
        printf '<?xml version="1.0" encoding="UTF-16"?>\r\n<Task version="1.4">\r\n  <Actions Context="Author">\r\n    <Exec>\r\n      <Command>%s</Command>\r\n    </Exec>\r\n  </Actions>\r\n</Task>\r\n' "\${LTA_RUNNER:-$LTA_BAT}"
        exit 0 ;;
    *"/fo LIST"*) printf 'Tarea a ejecutar:   %s\r\n' "\${LTA_RUNNER:-$LTA_BAT}"; exit 0 ;;
esac
if [ "\${LTA_EMPTY:-0}" = "1" ]; then exit 0; fi
printf '"\\\\HIMMEL-Resume-fixture-repro","2026-01-01","Ready"\n'
[ "\${LTA_TWO:-0}" = "1" ] && printf '"\\\\HIMMEL-Resume-unreadable-one","2026-01-01","Ready"\n'
exit 0
EOF
chmod +x "$LTA/schtasks"

out=$(TMPDIR="$TMP" win_env "$LTA" bash "$ARM" --list-temp-arms 2>&1)
rc=$?
assert_rc "1879-1365 --list-temp-arms reports a temp-targeted arm on a NON-ENGLISH Windows (rc=16)" 16 "$rc"
assert_contains "1879-1365 the sweep names the offending task" "HIMMEL-Resume-fixture-repro" "$out"
assert_contains "1879-1365 the sweep names the temp target" "scratchpad" "$out"
assert_contains "1879-1365 the sweep is report-only" "REPORT ONLY" "$out"

out=$(LTA_EMPTY=1 TMPDIR="$TMP" win_env "$LTA" bash "$ARM" --list-temp-arms 2>&1)
rc=$?
assert_rc "1879-1365 a clean scheduler sweeps clean (rc=0)" 0 "$rc"
assert_contains "1879-1365 clean sweep says so" "none" "$out"

# HIMMEL-1998: an entry the scheduler refuses to describe is NOT a clean bill
# of health. Pre-fix the loop `continue`d past it and the sweep printed the
# same "none" line as a genuinely empty scheduler.
out=$(LTA_NO_XML=1 TMPDIR="$TMP" win_env "$LTA" bash "$ARM" --list-temp-arms 2>&1)
rc=$?
assert_rc "1998 a degraded sweep gets its OWN exit code, never the clean 0 (rc=18)" 18 "$rc"
assert_contains "1998 an uninspectable entry is named" "UNREADABLE" "$out"
assert_contains "1998 and the summary refuses to call the sweep clean" "NOT a clean sweep" "$out"
assert_not_contains "1998 no bare clean line over an uninspectable entry" "none — no armed resume entry" "$out"

# A sweep can carry BOTH a hit and a blind spot. 16 outranks 18 there -- the hit
# is the actionable half -- but the report still has to say it was not
# exhaustive, or the operator reads a partial sweep as a complete one.
out=$(LTA_TWO=1 TMPDIR="$TMP" win_env "$LTA" bash "$ARM" --list-temp-arms 2>&1)
rc=$?
assert_rc "1998 hit + uninspectable entry keeps the louder rc 16" 16 "$rc"
assert_contains "1998 the hit is still reported" "TEMP-ARM" "$out"
assert_contains "1998 and the blind spot is named too" "NOT exhaustive" "$out"

# The bare scratch ROOTS count, not just their children (r6 round). `/tmp`
# always carried both forms; `/var/tmp` and `/var/folders` matched only
# descendants, so either as a literal target walked past a guard that catches
# every directory beneath it. Pinned through the SWEEP rather than through an
# arm: _arm_is_temp_path is the shared predicate for both, and the sweep feeds
# it the runner's path verbatim, whereas an arm resolves resume_cwd first --
# on Git-Bash `/var/tmp` resolves to a Windows path, so an arm-shaped case
# would assert about this host's path mapping instead of about the guard.
for _root_1365 in /var/tmp /var/folders 'C:\Users\otheruser\AppData\Local\Temp'; do
    LTA_BAT_ROOT="$TMP/lta-runner-bare-root.bat"
    printf 'cd /d "%s"\r\n' "$_root_1365" > "$LTA_BAT_ROOT"
    out=$(LTA_RUNNER="$LTA_BAT_ROOT" TMPDIR="$TMP" win_env "$LTA" bash "$ARM" --list-temp-arms 2>&1)
    rc=$?
    assert_rc "1879-1365 the bare scratch root $_root_1365 is a sweep hit (rc=16)" 16 "$rc"
    assert_contains "1879-1365 the sweep names the bare root $_root_1365" "target: $_root_1365" "$out"
done
fi

# ---------------------------------------------------------------------------
# HIMMEL-1830 — one file per leg: arming the second half of a split leg is
# refused (rc 17).
#
# The 2026-08-17 incident: one leg wrote session-25 (state) AND session-26
# (orders) and armed on 26, so the relaunch loaded the orders half and the
# state was orphaned. Refusal needs BOTH conditions — a sibling written inside
# this leg window AND no relaunch ever made from it — so the allow cases below
# pin one condition each; without them the check would refuse every short leg.
# ---------------------------------------------------------------------------
if _sec_selected "1830" "HIMMEL-1830"; then
echo "--- 1830 ---"
R1830="$TMP/h1830"
mkdir -p "$R1830/repo" "$R1830/chain"
( cd "$R1830/repo" && git init -q . \
    && git config user.email t@t.t && git config user.name t \
    && git config commit.gpgsign false \
    && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
_mk1830() {  # <path> <title>
    printf -- '---\nticket: HIMMEL-9830\nresume_cwd: %s\n---\n\n# %s\n' "$R1830/repo" "$2" > "$1"
}
HO_1830_A="$R1830/chain/EPIC-9830-dispatch-session-4.md"
HO_1830_B="$R1830/chain/EPIC-9830-dispatch-session-5.md"
_mk1830 "$HO_1830_A" "leg state half"
_mk1830 "$HO_1830_B" "leg orders half"
_a1830() {  # <ledger> <handover>
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh HIMMEL_FLOW_RUNS_LEDGER="$1" \
        win_env "$SCHED_STUB_T17" bash "$ARM" --time "$(future_time)" --handover "$2" --dry-run 2>&1)
}
# An EXISTING but empty ledger. A ledger that is absent entirely proves nothing
# about the sibling, so the guard fails open there — the refusal needs a ledger
# that could have carried the evidence and does not.
E1830="$TMP/1830-empty.jsonl"; : > "$E1830"

# (a) REFUSAL: both files just written, nothing ever relaunched from session-4.
_a1830 "$E1830" "$HO_1830_B"; rc=$?
assert_rc "1830 arming the second half of a split leg refuses (rc=17)" 17 "$rc"
assert_contains "1830 the ERR names the sibling it would orphan" "EPIC-9830-dispatch-session-4.md" "$out"
assert_contains "1830 the ERR names the opt-out" "ARM_SPLIT_LEG_OK=1" "$out"

# (b) ALLOW: same pair, but a relaunch WAS made from session-4 — i.e. it was a
# real leg's file, and this is a normal chain that simply moved fast. The
# ledger row carries session-4's REAL arm identity, taken from arm-resume's own
# banner: the evidence is matched on the sibling's canonical-path hash, so a
# hand-written task name would prove nothing about this fixture.
_a1830 "$E1830" "$HO_1830_A"; rc=$?
assert_rc "1830 seed: the sibling itself arms cleanly (rc=0)" 0 "$rc"
TASK_1830_A=$(printf '%s\n' "$out" | sed -n 's|.*would schtasks /create /tn \([^ ]*\) .*|\1|p' | head -1 | tr -d '\r')
L1830="$TMP/1830-launched.jsonl"
printf '{"flow":"armed-resume","ev":"start","run_id":"r1","task_name":"%s"}\n' "$TASK_1830_A" > "$L1830"
_a1830 "$L1830" "$HO_1830_B"; rc=$?
assert_rc "1830 a sibling that WAS a relaunch point still arms (rc=0)" 0 "$rc"

# (b2) …but ANOTHER chain's row must not clear it (panel r1 [codex-1]): same
# ticket, same leg number, different handover file. Evidence is per-path.
L1830F="$TMP/1830-foreign.jsonl"
printf '{"flow":"armed-resume","ev":"start","run_id":"r1","task_name":"HIMMEL-Resume-HIMMEL-9830-other-chain-s4-other_chain_session_4-h0123456789ab"}\n' > "$L1830F"
_a1830 "$L1830F" "$HO_1830_B"; rc=$?
assert_rc "1830 a DIFFERENT chain's leg-4 row does not clear the refusal (rc=17)" 17 "$rc"

# (c) ALLOW: no ledger evidence either, but the sibling is old — a previous
# leg's file, not something this session just wrote.
touch -t 202601010000 "$HO_1830_A"
_a1830 "$E1830" "$HO_1830_B"; rc=$?
assert_rc "1830 an OLD sibling is a previous leg, not a split (rc=0)" 0 "$rc"

# (d) The escape hatch is real: re-make the sibling fresh, opt out explicitly.
_mk1830 "$HO_1830_A" "leg state half"
out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh HIMMEL_FLOW_RUNS_LEDGER="$E1830" \
    ARM_SPLIT_LEG_OK=1 win_env "$SCHED_STUB_T17" bash "$ARM" \
    --time "$(future_time)" --handover "$HO_1830_B" --dry-run 2>&1)
rc=$?
assert_rc "1830 ARM_SPLIT_LEG_OK=1 opts out of the refusal (rc=0)" 0 "$rc"

# (e) A ZERO-PADDED chain (panel r3 [codex-1]): `session-08.md` is a legal
# filename but octal to bash arithmetic — `$((08 - 1))` is a fatal "value too
# great for base" that aborted the whole arm under set -e. The sibling lookup
# must also find the same-width `-07.md`, not only a bare `-7.md`.
HO_1830_P7="$R1830/chain/EPIC-9830-dispatch-session-07.md"
HO_1830_P8="$R1830/chain/EPIC-9830-dispatch-session-08.md"
_mk1830 "$HO_1830_P7" "padded state half"
_mk1830 "$HO_1830_P8" "padded orders half"
_a1830 "$E1830" "$HO_1830_P8"; rc=$?
assert_rc "1830 a zero-padded split leg refuses cleanly (rc=17, not an arithmetic abort)" 17 "$rc"
assert_contains "1830 the padded sibling is the one named" "EPIC-9830-dispatch-session-07.md" "$out"
fi

# ---------------------------------------------------------------------------
# HIMMEL-812 — --safety-child marks the RELAUNCH env, on every runner.
#
# auto-arm-on-cap.sh's stale escalation passes this flag; the relaunched
# session reads AUTO_ARM_SAFETY_CHILD out of its own env and refuses to
# escalate again, which is what bounds the self-sustaining +5h chain. If the
# mark never reaches the child the whole depth limit is inert, so each runner's
# emitted text is asserted here — with the flag AND without it (the negative is
# what makes the injection conditional rather than always-on).
# ---------------------------------------------------------------------------
if _sec_selected "812" "HIMMEL-812"; then
echo "--- 812 ---"
HO_812="$(make_handover "$WORK_REPO")"
_SC812='AUTO_ARM_SAFETY_CHILD=1'

# windows: the schtasks runner is a .bat, so the mark is a `set` line.
out=$(win_env "$SCHED_STUB_T17" bash "$ARM" --time "$(future_time)" --handover "$HO_812" --safety-child --dry-run 2>&1)
rc=$?
assert_rc "812 win: --safety-child dry-run exits 0" 0 "$rc"
assert_contains "812 win: the .bat sets the mark" "set \"$_SC812\"" "$out"
out=$(win_env "$SCHED_STUB_T17" bash "$ARM" --time "$(future_time)" --handover "$HO_812" --dry-run 2>&1)
assert_not_contains "812 win: no mark without the flag" "$_SC812" "$out"
assert_contains "812 win: the .bat CLEARS an ambient mark first" 'set "AUTO_ARM_SAFETY_CHILD="' "$out"

# macOS/crontab: one line, so the mark is an export ahead of the launch body.
MACBIN_812="$TMP/macbin-812"; mkdir -p "$MACBIN_812"
CRON_STORE_812="$TMP/cron-812.store"; : > "$CRON_STORE_812"
printf '#!/bin/sh\nexit 1\n' > "$MACBIN_812/at"; chmod +x "$MACBIN_812/at"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN_812/atq"; chmod +x "$MACBIN_812/atq"
cat > "$MACBIN_812/crontab" <<CRONEOF812
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE_812" 2>/dev/null ;;
  -) cat > "$CRON_STORE_812" ;;
  *) exit 0 ;;
esac
CRONEOF812
chmod +x "$MACBIN_812/crontab"
out=$(env PATH="$MACBIN_812:$PATH" OSTYPE=darwin23 bash "$ARM" --time "$(future_time)" --handover "$HO_812" --safety-child --dry-run 2>&1)
rc=$?
assert_rc "812 cron: --safety-child dry-run exits 0" 0 "$rc"
assert_contains "812 cron: the crontab entry exports the mark" "export $_SC812" "$out"
out=$(env PATH="$MACBIN_812:$PATH" OSTYPE=darwin23 bash "$ARM" --time "$(future_time)" --handover "$HO_812" --dry-run 2>&1)
assert_not_contains "812 cron: no mark without the flag" "$_SC812" "$out"
assert_contains "812 cron: the entry CLEARS an ambient mark" "unset AUTO_ARM_SAFETY_CHILD" "$out"

# linux/at: the job body is a script, so the mark is its own export line.
DBD_812="$TMP/h812.atdir"; rm -rf "$DBD_812"; mkdir -p "$DBD_812"
out=$(SCHED_DB="$TMP/h812-sched.db" SCHED_DB_DIR="$DBD_812" PATH="$STATEFUL_STUB:$PATH" OSTYPE=linux-gnu \
    bash "$ARM" --time "$(future_time)" --handover "$HO_812" --safety-child --dry-run 2>&1)
rc=$?
assert_rc "812 at: --safety-child dry-run exits 0" 0 "$rc"
assert_contains "812 at: the at job body exports the mark" "export $_SC812" "$out"
out=$(SCHED_DB="$TMP/h812-sched.db" SCHED_DB_DIR="$DBD_812" PATH="$STATEFUL_STUB:$PATH" OSTYPE=linux-gnu \
    bash "$ARM" --time "$(future_time)" --handover "$HO_812" --dry-run 2>&1)
assert_not_contains "812 at: no mark without the flag" "$_SC812" "$out"
# `at` snapshots the SUBMITTING env, so the clear is load-bearing here, not
# cosmetic: an ordinary arm made from a safety-child session must not relaunch
# still carrying the mark (panel r3 [codex-2]).
assert_contains "812 at: the job body CLEARS an ambient mark" "unset AUTO_ARM_SAFETY_CHILD" "$out"
fi

# ---------------------------------------------------------------------------
# HIMMEL-1636 — own-identity exclusion in the ticket-mutex scan is per-backend.
#
# list_existing returns a task NAME on schtasks, a whole crontab LINE on cron
# and an opaque `at-job-N` on at. The mutex's exclusion compared the marker to
# $TASK_NAME, which can only ever be true on schtasks — so on POSIX a --force
# re-arm of the SAME handover saw its own slot and WARNed that a DIFFERENT
# handover holds the ticket. Both POSIX backends are forced from any host
# (OSTYPE + a PATH stub), exactly as the macOS/1879e sections do: a
# Windows-green says nothing about the two branches this fixes.
# ---------------------------------------------------------------------------
if _sec_selected "1636" "HIMMEL-1636"; then
echo "--- 1636 ---"
R1636="$TMP/h1636"
mkdir -p "$R1636/repo"
( cd "$R1636/repo" && git init -q . \
    && git config user.email t@t.t && git config user.name t \
    && git config commit.gpgsign false \
    && git commit -q --allow-empty -m seed ) >/dev/null 2>&1
# Leg B is a SECOND file for the same ticket: it is the positive control that
# keeps every assert_not_contains below honest (the scan does find genuinely
# foreign slots on this backend), and re-arming leg A would hit the rc-3
# per-handover dedup before the ticket scan is ever reached.
HO_1636_A="$R1636/leg-a.md"
HO_1636_B="$R1636/leg-b.md"
printf -- '---\nticket: HIMMEL-9636\nresume_cwd: %s\n---\n\n# HIMMEL-9636 leg A\n' "$R1636/repo" > "$HO_1636_A"
printf -- '---\nticket: HIMMEL-9636\nresume_cwd: %s\n---\n\n# HIMMEL-9636 leg B\n' "$R1636/repo" > "$HO_1636_B"
_1636_WARN="already has another armed resume slot"

# --- at backend (linux): list_existing returns `at-job-N` -------------------
DBD_1636="$TMP/h1636.atdir"; rm -rf "$DBD_1636"; mkdir -p "$DBD_1636"
_a1636_at() {
    local ho="$1"; shift
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh HIMMEL_FLOW_RUNS_LEDGER="$TMP/1636-at.jsonl" \
        SCHED_DB="$TMP/h1636-sched.db" SCHED_DB_DIR="$DBD_1636" \
        PATH="$STATEFUL_STUB:$PATH" OSTYPE=linux-gnu \
        bash "$ARM" --time "$(future_time)" --handover "$ho" "$@" 2>&1)
}
_a1636_at "$HO_1636_A"; rc=$?
assert_rc "1636 at: leg A arms cleanly (rc=0)" 0 "$rc"
_a1636_at "$HO_1636_A" --force; rc=$?
assert_rc "1636 at: --force re-arm of the SAME handover succeeds (rc=0)" 0 "$rc"
assert_not_contains "1636 at: own at-job is NOT misread as a DIFFERENT handover" "$_1636_WARN" "$out"
_a1636_at "$HO_1636_B"; rc=$?
assert_rc "1636 at: a genuinely DIFFERENT handover on the same ticket still refuses (rc=13)" 13 "$rc"
assert_contains "1636 at: that refusal is the ticket mutex" "$_1636_WARN" "$out"

# --- crontab backend (macOS): list_existing returns the whole LINE ----------
MACBIN_1636="$TMP/macbin-1636"; mkdir -p "$MACBIN_1636"
CRON_STORE_1636="$TMP/cron-1636.store"; : > "$CRON_STORE_1636"
# at/atq must never be reached on macOS (arm-resume picks crontab there); a
# loud-failing `at` proves it, exactly as the macOS section's stub does.
printf '#!/bin/sh\necho "at MUST NOT be called on macOS" >&2; exit 1\n' > "$MACBIN_1636/at"; chmod +x "$MACBIN_1636/at"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN_1636/atq"; chmod +x "$MACBIN_1636/atq"
cat > "$MACBIN_1636/crontab" <<CRONEOF1636
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE_1636" 2>/dev/null ;;
  -) cat > "$CRON_STORE_1636" ;;
  *) exit 0 ;;
esac
CRONEOF1636
chmod +x "$MACBIN_1636/crontab"
_a1636_cron() {
    local ho="$1"; shift
    out=$(TMPDIR="$TMP" GH_CMD=/nonexistent/gh HIMMEL_FLOW_RUNS_LEDGER="$TMP/1636-cron.jsonl" \
        PATH="$MACBIN_1636:$PATH" OSTYPE=darwin23 \
        bash "$ARM" --time "$(future_time)" --handover "$ho" "$@" 2>&1)
}
_a1636_cron "$HO_1636_A"; rc=$?
assert_rc "1636 cron: leg A arms cleanly (rc=0)" 0 "$rc"
_a1636_cron "$HO_1636_A" --force; rc=$?
assert_rc "1636 cron: --force re-arm of the SAME handover succeeds (rc=0)" 0 "$rc"
assert_not_contains "1636 cron: own crontab LINE is NOT misread as a DIFFERENT handover" "$_1636_WARN" "$out"
_a1636_cron "$HO_1636_B"; rc=$?
assert_rc "1636 cron: a genuinely DIFFERENT handover on the same ticket still refuses (rc=13)" 13 "$rc"
assert_contains "1636 cron: that refusal is the ticket mutex" "$_1636_WARN" "$out"
fi

# ---------------------------------------------------------------------------
# HIMMEL-2192 — optional --model passthrough into the relaunch payload.
#   Present -> flows into the generated .bat as `--model "<name>"`, right
#   after the prompt/--channels, mirroring the --channels passthrough shape
#   (T12/T13 above). Absent -> no --model token anywhere in the output, i.e.
#   byte-identical to the pre-2192 launch line (operator default model).
# ---------------------------------------------------------------------------
if _sec_selected "2192" "HIMMEL-2192"; then
HO_2192=$(make_handover "$WORK_REPO")
out=$(win_env "$SCHED_STUB_T17" bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model opus --dry-run 2>&1)
rc=$?
assert_rc "2192 --model dry-run exits 0" 0 "$rc"
assert_contains "2192 --model flows into the .bat payload" '--model "opus"' "$out"

out=$(win_env "$SCHED_STUB_T17" bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --force --dry-run 2>&1)
rc=$?
assert_rc "2192 no-flag dry-run exits 0" 0 "$rc"
assert_not_contains "2192 no --model token when the flag is omitted" "--model" "$out"

# CR round 2 finding: crontab treats an unescaped % as end-of-command +
# stdin even inside %q-quoting, so a MODEL containing % must be \%-escaped
# in the emitted crontab entry. Forced through the crontab backend the same
# way the "macOS backend" section above does (OSTYPE=darwin23 + a stub
# crontab binary) -- a proven pattern in this suite for deterministic
# crontab coverage.
CRONBIN2192="$TMP/cronbin2192"; mkdir -p "$CRONBIN2192"
CRON_STORE_2192="$TMP/cron2192.store"; : > "$CRON_STORE_2192"
cat > "$CRONBIN2192/crontab" <<CRONEOF
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE_2192" 2>/dev/null ;;
  -) cat > "$CRON_STORE_2192" ;;
  *) exit 0 ;;
esac
CRONEOF
chmod +x "$CRONBIN2192/crontab"
HO_2192_PCT=$(make_handover "$WORK_REPO")
out=$(env PATH="$CRONBIN2192:$PATH" OSTYPE="darwin23" bash "$ARM" --time "$(future_time)" --handover "$HO_2192_PCT" --model 'a%b' --dry-run 2>&1)
rc=$?
assert_rc "2192 crontab --model with percent dry-run exits 0" 0 "$rc"
assert_contains "2192 crontab entry escapes percent in --model" '--model a\%b' "$out"

# Value-less --model must ERROR, not consume the next option as the model
# name (CR finding codex-1: `--model --dry-run` would otherwise swallow
# --dry-run and arm the real scheduler).
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model --dry-run 2>&1)
rc=$?
assert_rc "2192 --model followed by an option exits 2" 2 "$rc"
assert_contains "2192 value-less --model error names the flag" "--model requires a non-empty" "$out"

out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model= --dry-run 2>&1)
rc=$?
assert_rc "2192 empty --model= exits 2" 2 "$rc"

# --model=--dry-run must ERROR too (same option-like-value gap as the
# space-separated form above, CR round 2 finding).
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model=--dry-run 2>&1)
rc=$?
assert_rc "2192 --model=--dry-run exits 2" 2 "$rc"
assert_contains "2192 --model= option-like value error names the flag" "--model requires a non-empty" "$out"

# A MODEL containing a double quote must ERROR: cmd.exe treats " as a
# delimiter even through cadence_cmd_escape's backslash-escaping, so it
# could split the generated .bat command (CR round 2 finding).
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model 'op"us' --dry-run 2>&1)
rc=$?
assert_rc "2192 --model with a double quote exits 2" 2 "$rc"
assert_contains "2192 double-quote --model error names the reason" "--model must not contain a double quote" "$out"

# A MODEL containing a CR/LF must ERROR: embedded verbatim into the .bat
# launch line, a CR/LF could inject an extra batch command (CR round 3
# finding). LF, not CR: a lone CR does not survive the command-substitution
# subshell boundary under this MSYS bash (silently stripped en route), which
# would make a CR-based test pass for the wrong reason.
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2192" --model $'opus\necho-x' --dry-run 2>&1)
rc=$?
assert_rc "2192 --model with an LF exits 2" 2 "$rc"
assert_contains "2192 control-char --model error names the reason" "--model must contain only printable, non-whitespace characters" "$out"
fi

# ---------------------------------------------------------------------------
# HIMMEL-2199 — crontab tails: q_prompt/q_channels lack %-escaping.
# _crontab_schedule() %q-quotes q_prompt/q_channels but (pre-fix) never
# followed up with the \%-escape 2192 already applies to q_model -- crontab
# (unlike /bin/sh) reads an unescaped % as end-of-command + stdin even inside
# %q-quoting, so a handover path or --channels value containing % silently
# truncated the scheduled command at fire time. Forced through the crontab
# backend the same way 2192's own %-in---model test above does (OSTYPE=darwin23
# + a stub crontab); RESUME_PROMPT always embeds the handover PATH verbatim
# ("load $HANDOVER_PATH overnight mode. ..."), so a %-bearing handover path is
# the natural vector for q_prompt specifically.
# ---------------------------------------------------------------------------
if _sec_selected "2199" "HIMMEL-2199"; then
CRONBIN2199="$TMP/cronbin2199"; mkdir -p "$CRONBIN2199"
CRON_STORE_2199="$TMP/cron2199.store"; : > "$CRON_STORE_2199"
cat > "$CRONBIN2199/crontab" <<CRONEOF
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE_2199" 2>/dev/null ;;
  -) cat > "$CRON_STORE_2199" ;;
  *) exit 0 ;;
esac
CRONEOF
chmod +x "$CRONBIN2199/crontab"

HO_2199_PCT="$HANDOVER_DIR/handover-100%.md"
{
    printf -- '---\n'
    printf 'session_kind: test\n'
    printf 'resume_cwd: %s\n' "$WORK_REPO"
    printf -- '---\n'
    printf '# Test handover\n'
} > "$HO_2199_PCT"

out=$(env PATH="$CRONBIN2199:$PATH" OSTYPE="darwin23" bash "$ARM" --time "$(future_time)" --handover "$HO_2199_PCT" --channels 'a%b' --long-gap --dry-run 2>&1)
rc=$?
assert_rc "2199 crontab %-in-prompt/channels dry-run exits 0" 0 "$rc"
# Content AFTER the escaped % in each field proves the entry was not
# truncated there -- a bare (unescaped) % would have dropped everything
# past it when crontab actually parsed the real entry.
assert_contains "2199 crontab entry escapes percent in the prompt (from the %-bearing handover path)" 'handover-100\%.md\ overnight\ mode' "$out"
assert_contains "2199 crontab entry escapes percent in --channels" '--channels a\%b' "$out"
assert_contains "2199 crontab entry's trailing marker survives past both escapes (nothing truncated)" '# HIMMEL-Resume-handover-100' "$out"

# CR round on this ticket (critic-panel [codex-1]): q_cwd sits in the SAME
# crontab entry (`cd $q_cwd && ...`) as q_prompt/q_channels but was missed by
# the first pass -- a % in RESUME_CWD (the git-toplevel-derived working
# directory) truncates the entry exactly the same way.
CWD_PCT="$TMP/work%repo"; mkdir -p "$CWD_PCT"
HO_2199_CWD=$(make_handover "$CWD_PCT")
out=$(env PATH="$CRONBIN2199:$PATH" OSTYPE="darwin23" bash "$ARM" --time "$(future_time)" --handover "$HO_2199_CWD" --long-gap --dry-run 2>&1)
rc=$?
assert_rc "2199 crontab %-in-cwd dry-run exits 0" 0 "$rc"
assert_contains "2199 crontab entry escapes percent in cwd" 'work\%repo && unset' "$out"
fi

# ---------------------------------------------------------------------------
# HIMMEL-2177 — arithmetic syntax error spam from _minutes_from_midnight().
# Root cause (NOT an empty comparand, despite the ticket's original hunch):
# py_armor_capture's python round-trip writes through a Windows-native
# python.exe to a redirected FILE (not a console), which text-mode-translates
# \n to \r\n; cat reads those bytes back raw, so a trailing \r rides along on
# each HH:MM line list_collision_candidates()'s windows branch reads out of
# $PY_ARMOR_OUT. _minutes_from_midnight() then glues that \r onto `mm`
# (t="00:40\r" -> mm="40\r"), and `$(( hh * 60 + mm ))` chokes on the embedded
# CR. Repro needs >=1 OTHER HIMMEL-* scheduled task so check_collision()'s
# candidate loop actually runs; win_env forces the windows/schtasks branch
# (the real CSV-parsing + python round-trip path -- NOT the ARM_COLLISION_
# CANDIDATES test seam, which bypasses that parsing entirely and would not
# have caught this). Covers BOTH --time smart and an explicit --time HH:MM
# (the mission's corrected repro note: this is not smart-only).
# ---------------------------------------------------------------------------
if _sec_selected "2177" "HIMMEL-2177"; then
STUB2177="$TMP/stub2177"; mkdir -p "$STUB2177"
cat > "$STUB2177/schtasks" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    /query)
        printf '"\\HIMMEL-Resume-other-x","N/A","Ready"\n'
        printf '"\\HIMMEL-A","1/1/2027 12:40:00 AM","Ready"\n'
        printf '"\\HIMMEL-B","1/1/2027 12:20:00 AM","Ready"\n'
        printf '"\\HIMMEL-C","1/1/2027 12:00:00 AM","Ready"\n'
        printf '"\\HIMMEL-D","1/1/2027 12:15:00 AM","Ready"\n'
        printf '"\\HIMMEL-E","1/1/2027 12:05:00 AM","Ready"\n'
        exit 0 ;;
    /create|/delete) exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$STUB2177/schtasks"

HO_2177=$(make_handover "$WORK_REPO")
SLOT_CACHE_2177="$TMP/usage-free-2177.json"
FIVE_RESET_2177=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')
SEVEN_RESET_2177=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=6)).isoformat())')
printf '{"five_hour":{"utilization":0.0,"resets_at":"%s"},"seven_day":{"utilization":15.0,"resets_at":"%s"}}' \
    "$FIVE_RESET_2177" "$SEVEN_RESET_2177" > "$SLOT_CACHE_2177"

# (a) --time smart
out=$(RESUME_SLOT_CACHE="$SLOT_CACHE_2177" SLOT_MAX_AGE=0 win_env "$STUB2177" bash "$ARM" --time smart --handover "$HO_2177" --dry-run 2>&1)
rc=$?
assert_rc "2177a --time smart with near-midnight candidates exits 0" 0 "$rc"
assert_not_contains "2177a no arithmetic syntax error on --time smart" "arithmetic syntax error" "$out"

# (b) explicit --time HH:MM -- the mission's corrected repro: this is NOT
# smart-only, so the regression case must cover both paths.
HO_2177B=$(make_handover "$WORK_REPO")
out=$(win_env "$STUB2177" bash "$ARM" --time "$(future_time)" --handover "$HO_2177B" --dry-run 2>&1)
rc=$?
assert_rc "2177b explicit --time with near-midnight candidates exits 0" 0 "$rc"
assert_not_contains "2177b no arithmetic syntax error on explicit --time" "arithmetic syntax error" "$out"
fi

# ---------------------------------------------------------------------------
# HIMMEL-2545 — a relaunched session must NOT inherit CLAUDE_CODE_CHILD_SESSION.
#   claude exports CLAUDE_CODE_CHILD_SESSION=1 (and CLAUDE_PID) into every
#   process it spawns, so a claude started from inside a claude tool call is
#   treated as a throwaway child: transcript saving OFF, context-fill rc=4
#   ("blind fill"), nothing for /handover-resume-armed or the luna
#   session-capture hook. An ARMED resume is the opposite of a throwaway — it
#   is the session that most needs its transcript. Every generated launch body
#   must therefore CLEAR both vars and FORCE persistence on, on the same
#   always-clear contract as ARMAUTOMERGE/ARM_RESUME_SAFETY_ARM (T33b/c, T38).
#   Asserted on each backend separately because each builds its own launch
#   body: the POSIX `at` body, the crontab entry, and the Windows .bat.
#   CLAUDE_PID is the HIMMEL-2514 sibling — the relaunch must not inherit the
#   arming session's pid either.
#   Round-6 addition: CLAUDE_CODE_SESSION_ID joins the same clear. claude
#   generates its own id and exports the CORRECT one to its own tool
#   subprocesses regardless, so context-fill.sh and anything reading its own
#   env are unaffected — the impact is narrower than it looks. What is
#   polluted without this clear is the relaunched claude PROCESS's own
#   environ, which is exactly the surface this ticket taught people to
#   inspect (/proc/<claude pid>/environ): a stale id there actively misleads
#   the diagnostics HIMMEL-2545 introduced. Asserted on the plain AND the
#   headroom-proxy variant of every backend that has one (cron, at) — the
#   headroom branch builds a completely separate launch string, so a fix
#   proven only against the plain string would leave the proxied path still
#   leaking the arming session's id.
# ---------------------------------------------------------------------------
if _sec_selected "2545" "HIMMEL-2545"; then
_2545_UNSET='unset ARMAUTOMERGE CR_MERGE_GATE_OK ARM_RESUME_SAFETY_ARM CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID'
_2545_EXPORT='export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1'

# (a) the default POSIX backend (`at` on Linux; the .bat on a Windows host).
HO_2545=$(make_handover "$WORK_REPO")
out=$(SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2545" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "2545a default-backend dry-run exits 0" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        assert_contains "2545a .bat CLEARS CLAUDE_CODE_CHILD_SESSION" 'set "CLAUDE_CODE_CHILD_SESSION="' "$out"
        assert_contains "2545a .bat CLEARS CLAUDE_PID" 'set "CLAUDE_PID="' "$out"
        assert_contains "2545a .bat CLEARS CLAUDE_CODE_SESSION_ID" 'set "CLAUDE_CODE_SESSION_ID="' "$out"
        assert_contains "2545a .bat FORCES session persistence" 'set "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"' "$out"
        ;;
    *)
        assert_contains "2545a at body clears the child-session marker + CLAUDE_PID" "$_2545_UNSET" "$out"
        assert_contains "2545a at body forces session persistence" "$_2545_EXPORT" "$out"
        ;;
esac
# The marker is only ever CLEARED, never granted to the relaunched session.
assert_not_contains "2545a body never grants CLAUDE_CODE_CHILD_SESSION=1" "CLAUDE_CODE_CHILD_SESSION=1" "$out"

# (b) the cron backend builds its own single-LINE $tail — forced the way the
# "macOS backend" and 2192 sections do it (OSTYPE=darwin23 + a stub scheduler
# binary), because a one-line entry could easily have been patched only on
# the multi-line POSIX twin.
CRONBIN2545="$TMP/cronbin2545"; mkdir -p "$CRONBIN2545"
CRON_STORE_2545="$TMP/cron2545.store"; : > "$CRON_STORE_2545"
cat > "$CRONBIN2545/crontab" <<CRONEOF
#!/bin/sh
case "\$1" in
  -l) cat "$CRON_STORE_2545" 2>/dev/null ;;
  -) cat > "$CRON_STORE_2545" ;;
  *) exit 0 ;;
esac
CRONEOF
chmod +x "$CRONBIN2545/crontab"
HO_2545_CRON=$(make_handover "$WORK_REPO")
out=$(env PATH="$CRONBIN2545:$PATH" OSTYPE="darwin23" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2545_CRON" --dry-run 2>&1)
rc=$?
assert_rc "2545b cron dry-run exits 0" 0 "$rc"
assert_contains "2545b cron entry clears the child-session marker + CLAUDE_PID" "$_2545_UNSET" "$out"
assert_contains "2545b cron entry forces session persistence" "$_2545_EXPORT" "$out"

# (c) the Windows .bat backend — a separate emitter (CMD `set "VAR="`), so a
# POSIX-only patch would leave the schtasks path still launching children.
HO_2545_WIN=$(make_handover "$WORK_REPO")
out=$(win_env "$SCHED_STUB_T17" bash "$ARM" --time "$(future_time)" --handover "$HO_2545_WIN" --dry-run 2>&1)
rc=$?
assert_rc "2545c .bat dry-run exits 0" 0 "$rc"
assert_contains "2545c .bat CLEARS CLAUDE_CODE_CHILD_SESSION" 'set "CLAUDE_CODE_CHILD_SESSION="' "$out"
assert_contains "2545c .bat CLEARS CLAUDE_PID" 'set "CLAUDE_PID="' "$out"
assert_contains "2545c .bat CLEARS CLAUDE_CODE_SESSION_ID" 'set "CLAUDE_CODE_SESSION_ID="' "$out"
assert_contains "2545c .bat FORCES session persistence" 'set "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"' "$out"

# (d) the cron backend's HEADROOM-PROXY variant — a completely separate
# launch string (HIMMEL-901), built only when HIMMEL_HEADROOM_PROXY=1 is
# active. A fix proven only against the plain $tail (case b) would leave
# this branch still handing the relaunch the arming session's stale id.
HO_2545_CRON_HP=$(make_handover "$WORK_REPO")
: > "$CRON_STORE_2545"
out=$(HIMMEL_HEADROOM_PROXY=1 env PATH="$CRONBIN2545:$PATH" OSTYPE="darwin23" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2545_CRON_HP" --dry-run 2>&1)
rc=$?
assert_rc "2545d cron headroom-proxy dry-run exits 0" 0 "$rc"
assert_contains "2545d cron headroom-proxy entry clears the child-session marker + CLAUDE_PID + CLAUDE_CODE_SESSION_ID" "$_2545_UNSET" "$out"
assert_contains "2545d cron headroom-proxy entry forces session persistence" "$_2545_EXPORT" "$out"

# (e) the `at` backend's HEADROOM-PROXY variant — same rationale as (d), for
# the other plain-vs-proxied pair of launch strings (HIMMEL-901).
HO_2545_AT_HP=$(make_handover "$WORK_REPO")
out=$(HIMMEL_HEADROOM_PROXY=1 SCHTASKS_CMD="$SCHED_STUB_T17/schtasks" PATH="$SCHED_STUB_T17:$PATH" \
    bash "$ARM" --time "$(future_time)" --handover "$HO_2545_AT_HP" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "2545e at headroom-proxy dry-run exits 0" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        assert_contains "2545e .bat headroom-proxy CLEARS CLAUDE_CODE_SESSION_ID" 'set "CLAUDE_CODE_SESSION_ID="' "$out"
        ;;
    *)
        assert_contains "2545e at headroom-proxy body clears the child-session marker + CLAUDE_PID + CLAUDE_CODE_SESSION_ID" "$_2545_UNSET" "$out"
        assert_contains "2545e at headroom-proxy body forces session persistence" "$_2545_EXPORT" "$out"
        ;;
esac
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
# HIMMEL-1579 (3): a stale-fixture run must ANNOUNCE ITSELF rather than hand
# back a plausible failure list. future_time() refreshes with >=600s of its
# target left, so this is unreachable in a healthy run — the last value it
# handed out is still in the future. If wall-clock HAS passed it, some late arm
# asked for a time already in the past, arm-resume rolled it to TOMORROW, and
# the long-gap guard refused it rc=9: every "expected rc=N, got rc=9" above is
# then fixture rot, not a defect in the code under test. Deliberately not a
# FAIL — the run's real verdict stands; this only labels it.
# Two conditions, because neither alone covers the whole run: a target that
# expired MID-run is erased by the next refresh, so future_time() latches a
# marker file at that moment (panel r2 codex-2), while the second half catches
# a target that expired after the LAST handout and so was never refreshed away.
# Both read the cache FILE — the function runs in a command-substitution
# subshell, so nothing it assigns to a variable is visible here (r3 codex-1).
_ft_last_target=0; _ft_last_value=""
[ -s "$_FT_FILE" ] && read -r _ft_last_target _ft_last_value < "$_FT_FILE"
if [ -f "$_FT_STALE_FILE" ] || { [ -n "$_ft_last_value" ] && [ "$(date +%s)" -ge "$_ft_last_target" ]; }; then
    echo "WARN test-arm-resume.sh: the run outlived its own fixture window -- a future_time() target (last: $_ft_last_value) went PAST during the run, so any rc=9 above is suite shelf life (HIMMEL-1579), not a code defect. Re-run on an idle box before believing this list."
fi
if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
