#!/usr/bin/env bash
# Smoke / invariant tests for scripts/handover/arm-resume.sh
#
# Covers cwd resolution (--cwd flag, resume_cwd frontmatter, legacy
# fallback + discoverability warning). Uses --dry-run throughout so no
# real scheduler jobs are created.
set -uo pipefail

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
# Global workspace-trust shield (HIMMEL-386): arm-resume now pre-trusts the
# resolved cwd in ~/.claude.json. The non-dry-run arm cases below (T14-T20
# bridge/channel checks, dedup-any) would otherwise write the operator's real
# config — redirect the pre-seed at a throwaway file for the whole suite.
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"

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

# A fixed time in the future (HH:MM format) — just needs to parse.
FUTURE_TIME="23:59"

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
cat > "$SCHED_STUB_T17/schtasks" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCHED_STUB_T17/atq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCHED_STUB_T17/at" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCHED_STUB_T17/schtasks" "$SCHED_STUB_T17/atq" "$SCHED_STUB_T17/at"

# ---------------------------------------------------------------------------
# T1: --cwd <dir> overrides everything, even when resume_cwd is set
# ---------------------------------------------------------------------------
HO=$(make_handover "$HANDOVER_DIR")   # resume_cwd set to $HANDOVER_DIR itself
# $WORK_REPO is the explicit --cwd; it should win.
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --cwd "$WORK_REPO" --dry-run 2>&1)
rc=$?
assert_rc "T1 --cwd flag exits 0" 0 "$rc"
assert_contains "T1 RESUME_CWD matches --cwd arg" "RESUME_CWD=$WORK_REPO" "$out"
assert_not_contains "T1 --cwd does not resolve to statedocs" "RESUME_CWD=$HANDOVER_DIR" "$out"
# HIMMEL-386: the arm pre-trusts the resolved cwd (dry-run reports, doesn't mutate).
assert_contains "T1 dry-run pre-trusts resolved cwd" "would pre-trust workspace '$WORK_REPO'" "$out"

# ---------------------------------------------------------------------------
# T2: handover WITH resume_cwd pointing to a valid dir, NO --cwd
#     → resolved cwd is that dir
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T2 resume_cwd frontmatter exits 0" 0 "$rc"
assert_contains "T2 RESUME_CWD matches frontmatter value" "RESUME_CWD=$WORK_REPO" "$out"
# Must NOT emit the discoverability warning (resume_cwd was found).
assert_not_contains "T2 no discoverability warning when resume_cwd set" "no --cwd and no 'resume_cwd:'" "$out"

# ---------------------------------------------------------------------------
# T3: handover with resume_cwd pointing to a NON-EXISTENT dir, no --cwd
#     → emits WARN and falls back (cwd != the bogus path)
# ---------------------------------------------------------------------------
BOGUS="$TMP/does-not-exist-$(date +%s)"
HO=$(make_handover "$BOGUS")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T3 bad resume_cwd still exits 0 (warn+fallback)" 0 "$rc"
assert_contains "T3 emits WARN for bad resume_cwd" "WARN arm-resume: handover resume_cwd:" "$out"
assert_not_contains "T3 RESUME_CWD is not the bogus path" "RESUME_CWD=$BOGUS" "$out"
# resume_cwd was present (just invalid) — must NOT emit the "no resume_cwd" discoverability WARN.
assert_not_contains "T3 no spurious discoverability warning when key was present" "no --cwd and no 'resume_cwd:'" "$out"

# ---------------------------------------------------------------------------
# T4: handover with NO resume_cwd, no --cwd
#     → falls back to git-toplevel / handover dir AND emits discoverability warning
# ---------------------------------------------------------------------------
HO=$(make_handover "")   # no resume_cwd line
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T4 no-cwd fallback exits 0" 0 "$rc"
assert_contains "T4 emits discoverability warning" "no --cwd and no 'resume_cwd:' in handover frontmatter" "$out"
# RESUME_CWD should resolve to the git toplevel of $TMP/statedocs.
# Compute the expected value the same way arm-resume does (git rev-parse).
EXPECTED_T4=$(git -C "$TMP/statedocs" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$TMP/statedocs")
assert_contains "T4 RESUME_CWD resolves to statedocs git-toplevel" "RESUME_CWD=$EXPECTED_T4" "$out"

# ---------------------------------------------------------------------------
# T5: resume_cwd value with surrounding double quotes is handled correctly
# ---------------------------------------------------------------------------
HO_QUOTED="$HANDOVER_DIR/handover-quoted-$RANDOM.md"
{
    printf -- '---\n'
    printf 'session_kind: test\n'
    printf 'resume_cwd: "%s"\n' "$WORK_REPO"
    printf -- '---\n'
    printf '# Test handover\n'
} > "$HO_QUOTED"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_QUOTED" --dry-run 2>&1)
rc=$?
assert_rc "T5 double-quoted resume_cwd exits 0" 0 "$rc"
assert_contains "T5 double-quoted resume_cwd resolves correctly" "RESUME_CWD=$WORK_REPO" "$out"

# ---------------------------------------------------------------------------
# T6: resume_cwd value with surrounding single quotes is handled correctly
# ---------------------------------------------------------------------------
HO_SQ="$HANDOVER_DIR/handover-sq-$RANDOM.md"
{
    printf -- '---\n'
    printf 'session_kind: test\n'
    printf "resume_cwd: '%s'\n" "$WORK_REPO"
    printf -- '---\n'
    printf '# Test handover\n'
} > "$HO_SQ"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_SQ" --dry-run 2>&1)
rc=$?
assert_rc "T6 single-quoted resume_cwd exits 0" 0 "$rc"
assert_contains "T6 single-quoted resume_cwd resolves correctly" "RESUME_CWD=$WORK_REPO" "$out"

# ---------------------------------------------------------------------------
# T7: CRLF + double-quoted resume_cwd regression guard
#     Fixture uses \r\n line endings and `resume_cwd: "<validdir>"`.
#     Old code: quote-strip before rtrim → `\r` prevents `%\"` match →
#     rtrim leaves trailing quote → `[ -d ]` fails → wrong-repo fallback.
#     New code: rtrim first → \r gone → quote-strip works → resolves correctly.
# ---------------------------------------------------------------------------
HO_CRLF="$HANDOVER_DIR/handover-crlf-$RANDOM.md"
# Write every line with explicit CRLF (\r\n) to simulate Windows-authored YAML.
printf -- '---\r\nsession_kind: test\r\nresume_cwd: "%s"\r\n---\r\n# CRLF test handover\r\n' \
    "$WORK_REPO" > "$HO_CRLF"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_CRLF" --dry-run 2>&1)
rc=$?
assert_rc "T7 CRLF+quoted resume_cwd exits 0" 0 "$rc"
assert_contains "T7 CRLF+quoted resume_cwd resolves correctly" "RESUME_CWD=$WORK_REPO" "$out"
# Must NOT contain a trailing quote in the resolved path.
assert_not_contains "T7 no trailing quote in RESUME_CWD" "RESUME_CWD=${WORK_REPO}\"" "$out"
# Must NOT fall back to the discoverability warning (resume_cwd WAS present).
assert_not_contains "T7 no discoverability warning for CRLF handover" "no --cwd and no 'resume_cwd:'" "$out"

# ---------------------------------------------------------------------------
# T8: a past --time HH:MM rolls the scheduled DATE to tomorrow (HIMMEL-204).
#     Old code passed schtasks /st with no /sd -> defaulted to today, so a
#     past time gave "Next Run Time: N/A" and never fired. --force --dry-run
#     isolates from the live-scheduler dedup so this is deterministic.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
PAST_HHMM=$(python3 -c 'import datetime; print((datetime.datetime.now()-datetime.timedelta(minutes=2)).strftime("%H:%M"))')
out=$(bash "$ARM" --time "$PAST_HHMM" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T8 past --time exits 0 (force+dry)" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        TOM=$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(days=1)).strftime("%m/%d/%Y"))')
        assert_contains "T8 schtasks /sd is tomorrow" "/sd $TOM" "$out"
        ;;
    *)
        TOM=$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(days=1)).strftime("%Y%m%d"))')
        assert_contains "T8 at -t stamp is tomorrow" "at -t $TOM" "$out"
        ;;
esac

# ---------------------------------------------------------------------------
# T9: --time smart end-to-end through arm-resume (HIMMEL-204). A bank-free
#     fixture cache (injected via RESUME_SLOT_CACHE) must resolve to an ASAP
#     slot and flow a concrete date into the scheduler line. SLOT_MAX_AGE=0
#     skips the freshness guard; --force --dry-run isolates from the live
#     scheduler dedup and touches nothing.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
SLOT_CACHE="$TMP/usage-free.json"
FIVE_RESET=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')
SEVEN_RESET=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=6)).isoformat())')
printf '{"five_hour":{"utilization":0.0,"resets_at":"%s"},"seven_day":{"utilization":15.0,"resets_at":"%s"}}' \
    "$FIVE_RESET" "$SEVEN_RESET" > "$SLOT_CACHE"
out=$(RESUME_SLOT_CACHE="$SLOT_CACHE" SLOT_MAX_AGE=0 bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
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
# T10: --time smart with an exhausted-but-null-reset cache fails loud (rc 1
#      from arm-resume, surfacing resume-slot's rc 2) — never arms a bad job.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
BAD_CACHE="$TMP/usage-nullreset.json"
printf '{"five_hour":{"utilization":99.0,"resets_at":null},"seven_day":{"utilization":10.0,"resets_at":"%s"}}' \
    "$SEVEN_RESET" > "$BAD_CACHE"
out=$(RESUME_SLOT_CACHE="$BAD_CACHE" SLOT_MAX_AGE=0 bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T10 smart with unsafe cache exits 1 (no arm)" 1 "$rc"
assert_contains "T10 surfaces the slot error" "could not resolve a slot" "$out"

# ---------------------------------------------------------------------------
# T11: --channels while the bun bridge is LIVE is REFUSED (rc 5). HIMMEL-225.
#      ARM_BRIDGE_LIVE=1 forces the liveness check true without a real process.
#      --force --dry-run isolates from the live scheduler; the guard fires
#      before any scheduler touch, so nothing is created.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
out=$(ARM_BRIDGE_LIVE=1 bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T11 --channels + live bridge refused (rc 5)" 5 "$rc"
assert_contains "T11 explains the refusal" "refusing --channels" "$out"
assert_contains "T11 names the 409 hazard" "409 Conflict" "$out"

# ---------------------------------------------------------------------------
# T12: ARM_CHANNELS_OK=1 overrides the guard even with a live bridge → the arm
#      proceeds (rc 0) and the --channels passthrough flows into the dry-run.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
out=$(ARM_CHANNELS_OK=1 ARM_BRIDGE_LIVE=1 bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T12 ARM_CHANNELS_OK override exits 0" 0 "$rc"
assert_contains "T12 channels passthrough survives override" "--channels" "$out"
assert_not_contains "T12 no refusal under override" "refusing --channels" "$out"

# ---------------------------------------------------------------------------
# T13: real detection path — BRIDGE_ROOT points at a dir with NO supervisor.pid
#      (bridge not running), ARM_BRIDGE_LIVE unset → the guard does NOT fire and
#      a --channels arm proceeds (rc 0), passthrough intact.
# ---------------------------------------------------------------------------
NO_BRIDGE="$TMP/no-bridge"
mkdir -p "$NO_BRIDGE"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$NO_BRIDGE" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T13 --channels + no live bridge proceeds (rc 0)" 0 "$rc"
assert_contains "T13 channels passthrough flows into dry-run" "--channels" "$out"
assert_not_contains "T13 no spurious refusal when bridge absent" "refusing --channels" "$out"

# ---------------------------------------------------------------------------
# T14: the guard is --channels-only — a PLAIN arm with a live bridge is
#      UNAFFECTED (rc 0). Confirms the default relaunch path never regresses.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
out=$(ARM_BRIDGE_LIVE=1 bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T14 plain arm + live bridge unaffected (rc 0)" 0 "$rc"
assert_not_contains "T14 no refusal on a plain arm" "refusing --channels" "$out"

# ---------------------------------------------------------------------------
# T15: REAL detection — pidfile names a LIVE pid → guard fires (rc 5). Exercises
#      the actual pidfile-read + JSON-parse + _pid_alive path that the
#      ARM_BRIDGE_LIVE seam (T11/T12/T14) bypasses. Live pid is platform-honest:
#      POSIX uses this shell's own pid ($$, `kill -0` true); Windows uses PID 4
#      (the System process, always running) because $$ is an MSYS pid `tasklist`
#      cannot see. Requires python3 + (tasklist|kill) — a failure here is env,
#      not guard logic.
# ---------------------------------------------------------------------------
LIVE_BRIDGE="$TMP/live-bridge"
mkdir -p "$LIVE_BRIDGE"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*) LIVE_PID=4 ;;
    *)                           LIVE_PID=$$ ;;
esac
printf '{"supervisor": %d, "poller": 0}\n' "$LIVE_PID" > "$LIVE_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$LIVE_BRIDGE" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T15 real pidfile + live pid refuses (rc 5)" 5 "$rc"
assert_contains "T15 explains the refusal" "refusing --channels" "$out"

# ---------------------------------------------------------------------------
# T16: stale pidfile names a DEAD pid → guard does NOT fire (rc 0). A crashed
#      bridge leaves a pidfile; a legit --channels arm must still proceed.
#      999999 is absent on every platform (`kill -0` fails / tasklist "No tasks").
# ---------------------------------------------------------------------------
STALE_BRIDGE="$TMP/stale-bridge"
mkdir -p "$STALE_BRIDGE"
printf '{"supervisor": 999999, "poller": 0}\n' > "$STALE_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$STALE_BRIDGE" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T16 stale (dead-pid) pidfile proceeds (rc 0)" 0 "$rc"
assert_not_contains "T16 no refusal on a dead-pid pidfile" "refusing --channels" "$out"

# ---------------------------------------------------------------------------
# T17: malformed pidfile (present but unparseable) → FAIL CLOSED: treat the
#      bridge as live and refuse (rc 5) + warn. A present-but-torn pidfile most
#      likely means the bridge is up, so refusing is the safe direction (the
#      ARM_CHANNELS_OK=1 escape covers a genuinely corrupt file).
# ---------------------------------------------------------------------------
BAD_BRIDGE="$TMP/bad-bridge"
mkdir -p "$BAD_BRIDGE"
printf 'not json at all {{{\n' > "$BAD_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$BAD_BRIDGE" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T17 malformed pidfile fails closed (rc 5)" 5 "$rc"
assert_contains "T17 warns about the unreadable pidfile" "present but unreadable/empty" "$out"
assert_contains "T17 still refuses --channels" "refusing --channels" "$out"

# ---------------------------------------------------------------------------
# T18: REAL detection via the POLLER key — pidfile is {"supervisor":0,"poller":<live>}
#      so the supervisor key is dead/absent and ONLY the poller key carries a live
#      pid. Proves the JSON loop's poller branch decides liveness (T15 puts the
#      live pid under supervisor, so this is the complementary key). Guard fires
#      (rc 5). Live pid is platform-honest (see T15).
# ---------------------------------------------------------------------------
POLLER_BRIDGE="$TMP/poller-bridge"
mkdir -p "$POLLER_BRIDGE"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*) POLLER_PID=4 ;;
    *)                           POLLER_PID=$$ ;;
esac
printf '{"supervisor": 0, "poller": %d}\n' "$POLLER_PID" > "$POLLER_BRIDGE/supervisor.pid"
HO=$(make_handover "$WORK_REPO")
out=$(BRIDGE_ROOT="$POLLER_BRIDGE" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" \
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

# ---------------------------------------------------------------------------
# T19: BRIDGE_PIDFILE direct override WINS over BRIDGE_ROOT/supervisor.pid. The
#      resolver prefers $BRIDGE_PIDFILE; all other tests drive BRIDGE_ROOT only.
#      Point BRIDGE_PIDFILE at a live-pid file while BRIDGE_ROOT points at a dir
#      whose supervisor.pid is DEAD — if the override wins the guard fires (rc 5),
#      proving BRIDGE_PIDFILE took precedence over the (dead) BRIDGE_ROOT file.
# ---------------------------------------------------------------------------
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
        --time "$FUTURE_TIME" --handover "$HO" \
        --channels 'plugin:telegram@himmel' --force --dry-run 2>&1)
rc=$?
assert_rc "T19 BRIDGE_PIDFILE override (live) wins over dead BRIDGE_ROOT (rc 5)" 5 "$rc"
assert_contains "T19 explains the refusal" "refusing --channels" "$out"

# ---------------------------------------------------------------------------
# T20: wedged python3 stub (HIMMEL-249) — the --time HH:MM epoch resolution
#      must fail BOUNDED + visible (rc 2 + ERR), never hang the arm. The
#      watchdog (auto-arm-on-cap) calls this script, so a hang here would
#      wedge the whole armor chain.
# ---------------------------------------------------------------------------
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
        bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
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

# --dedup-any (HIMMEL-340): STUB_BIN fabricates a job named HIMMEL-Resume-stub
# whose name will not match this random handover's $TASK_NAME under the new
# per-handover dedup. --dedup-any restores the broad "any slot blocks" match
# so this test keeps exercising the shared dedup-block path (telemetry + rc 3).
TELEMETRY_T21="$TMP/telemetry-t21"
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$STUB_BIN:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T21" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dedup-any 2>&1)
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

# ---------------------------------------------------------------------------
# T22: telemetry honors --dry-run's "touch nothing" contract AND the
#      kill switch — neither run may append a record.
# ---------------------------------------------------------------------------
TELEMETRY_T22="$TMP/telemetry-t22"
HO=$(make_handover "$WORK_REPO")
out=$(SKILL_TELEMETRY_DIR="$TELEMETRY_T22" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T22 dry-run exits 0" 0 "$rc"
if [ -f "$TELEMETRY_T22/skill-usage.jsonl" ]; then
    echo "FAIL T22 dry-run appended telemetry (touch-nothing violated)"
    FAILED=$((FAILED + 1))
else
    echo "PASS T22 dry-run appends no telemetry"
fi
out=$(PATH="$STUB_BIN:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T22" SKILL_TELEMETRY_DISABLE=1 \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T22 kill-switched dedup still blocks (rc 3)" 3 "$rc"
if [ -f "$TELEMETRY_T22/skill-usage.jsonl" ]; then
    echo "FAIL T22 kill switch did not suppress the append"
    FAILED=$((FAILED + 1))
fi
# --dry-run WITHOUT --force hitting the dedup block (the no---force
# else-branch — the path the --force --dry-run case above bypasses):
# must still block rc 3 AND must not emit (touch-nothing contract).
out=$(PATH="$STUB_BIN:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T22" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "T22 dry-run (no --force) dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T22 dry-run dedup ERR text preserved" "already scheduled" "$out"
if [ -f "$TELEMETRY_T22/skill-usage.jsonl" ]; then
    echo "FAIL T22 dry-run dedup-block appended telemetry (touch-nothing violated)"
    FAILED=$((FAILED + 1))
else
    echo "PASS T22 no run appended telemetry (dry-run x2 + kill switch)"
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
cat > "$ARMED_STUB/schtasks" <<'EOF'
#!/usr/bin/env bash
# /query → empty scheduler (rc 0, no output); /create → success
exit 0
EOF
cat > "$ARMED_STUB/atq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$ARMED_STUB/at" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null   # consume the heredoc job body
exit 0
EOF
cat > "$ARMED_STUB/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ARMED_STUB/schtasks" "$ARMED_STUB/atq" "$ARMED_STUB/at" "$ARMED_STUB/claude"

TELEMETRY_T23="$TMP/telemetry-t23"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T23" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" 2>&1)
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
assert_contains "T23 record carries time" "\"time\":\"$FUTURE_TIME\"" "$tline"
assert_contains "T23 record carries force" '"force":"0"' "$tline"

# ---------------------------------------------------------------------------
# T23b: scheduler-create FAILURE emits NO record (HIMMEL-236) — the
#       'armed' emit sits AFTER schedule_arm, so a failed create (rc 4)
#       must leave the sink absent/empty: a failed arm is not a
#       re-launch signal. Arg-discriminating stub: /query (and atq)
#       report an empty scheduler so the arm proceeds past dedup,
#       /create (and at) fail.
# ---------------------------------------------------------------------------
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
out=$(TMPDIR="$TMP" PATH="$CREATEFAIL_STUB:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T23B" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" 2>&1)
rc=$?
assert_rc "T23b failed scheduler create exits 4" 4 "$rc"
assert_contains "T23b ERR text surfaced" "ERR arm-resume:" "$out"
if [ -s "$TELEMETRY_T23B/skill-usage.jsonl" ]; then
    echo "FAIL T23b failed create appended telemetry (no-emit invariant violated)"
    FAILED=$((FAILED + 1))
else
    echo "PASS T23b failed create appends no telemetry"
fi

# ---------------------------------------------------------------------------
# T24: caller-side fail-open (HIMMEL-236) — arm-resume must behave
#      identically when scripts/lib/telemetry.sh is ABSENT or
#      syntactically BROKEN (the `|| true` source + no-op fallback at
#      the call site). The script is copied into an isolated tree so
#      the real lib is never touched.
# ---------------------------------------------------------------------------
FAILOPEN="$TMP/failopen"
mkdir -p "$FAILOPEN/handover" "$FAILOPEN/lib"
cp "$ARM" "$FAILOPEN/handover/arm-resume.sh"
cp "$(dirname "$ARM")/../lib/py-armor.sh" "$FAILOPEN/lib/py-armor.sh"
# (a) lib ABSENT — dedup must still block rc 3 with the ERR text intact.
#     --dedup-any: STUB_BIN's fabricated HIMMEL-Resume-stub won't match this
#     random handover's $TASK_NAME under per-handover dedup (HIMMEL-340), so
#     the broad scope is what reproduces the dedup-block path under test here.
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$STUB_BIN:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T24 absent lib: dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T24 absent lib: ERR text intact" "already scheduled" "$out"
# (b) lib BROKEN (bash syntax error) — same dedup invariants, AND a
#     successful arm still completes end-to-end (rc 0, banner printed)
printf 'if [ broken\nthen (\n' > "$FAILOPEN/lib/telemetry.sh"
out=$(PATH="$STUB_BIN:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T24 broken lib: dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T24 broken lib: ERR text intact" "already scheduled" "$out"
out=$(TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" 2>&1)
rc=$?
assert_rc "T24 broken lib: successful arm still completes (rc 0)" 0 "$rc"
assert_contains "T24 broken lib: arm banner printed" "RESUME ARMED" "$out"

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
tn=""
while [ $# -gt 0 ]; do
    case "$1" in
        /tn)   tn="${2:-}"; shift 2 ;;
        /tn=*) tn="${1#/tn=}"; shift ;;
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
    /create) printf '%s\n' "$tn" >> "$db"; exit 0 ;;
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
    chmod +x "$dir/schtasks" "$dir/at" "$dir/atq" "$dir/atrm" "$dir/claude"
}

# Count armed slots in the platform's state location.
#   $1 = SCHED_DB file (windows); $2 = SCHED_DB_DIR dir (posix)
count_slots() {
    case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
        msys*|cygwin*|win32*|MINGW*)
            if [ -f "$1" ]; then grep -c . "$1" 2>/dev/null || echo 0; else echo 0; fi ;;
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
DB25="$TMP/db25.tasks"; DB25D="$TMP/db25.atdir"; : > "$DB25"; mkdir -p "$DB25D"
HO_A=$(make_handover "$WORK_REPO")
HO_B=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB25" SCHED_DB_DIR="$DB25D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_A" 2>&1)
rc=$?
assert_rc "T25a first distinct handover arms (rc 0)" 0 "$rc"
assert_contains "T25a arm banner printed" "RESUME ARMED" "$out"
out=$(TMPDIR="$TMP" SCHED_DB="$DB25" SCHED_DB_DIR="$DB25D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_B" 2>&1)
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

# ---------------------------------------------------------------------------
# T26: the SAME handover armed twice still dedups — second arm refused (rc 3),
#      one slot only. Preserves the "never two sessions for one handover"
#      invariant the original wildcard dedup enforced too broadly.
# ---------------------------------------------------------------------------
DB26="$TMP/db26.tasks"; DB26D="$TMP/db26.atdir"; : > "$DB26"; mkdir -p "$DB26D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB26" SCHED_DB_DIR="$DB26D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" 2>&1)
rc=$?
assert_rc "T26a same handover first arm (rc 0)" 0 "$rc"
out=$(TMPDIR="$TMP" SCHED_DB="$DB26" SCHED_DB_DIR="$DB26D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" 2>&1)
rc=$?
assert_rc "T26b same handover re-arm still blocks (rc 3)" 3 "$rc"
assert_contains "T26b dedup ERR text preserved" "already scheduled" "$out"
if [ "$(count_slots "$DB26" "$DB26D")" = "1" ]; then
    echo "PASS T26c same-handover dedup keeps exactly one slot"
else
    echo "FAIL T26c expected 1 slot, got $(count_slots "$DB26" "$DB26D")"
    FAILED=$((FAILED + 1))
fi

# ---------------------------------------------------------------------------
# T27: --force replaces ONLY the same-handover job — one slot before, one
#      after (delete + recreate), never a duplicate.
# ---------------------------------------------------------------------------
DB27="$TMP/db27.tasks"; DB27D="$TMP/db27.atdir"; : > "$DB27"; mkdir -p "$DB27D"
HO=$(make_handover "$WORK_REPO")
TMPDIR="$TMP" SCHED_DB="$DB27" SCHED_DB_DIR="$DB27D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" >/dev/null 2>&1
out=$(TMPDIR="$TMP" SCHED_DB="$DB27" SCHED_DB_DIR="$DB27D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --force 2>&1)
rc=$?
assert_rc "T27a same handover --force re-arms (rc 0)" 0 "$rc"
if [ "$(count_slots "$DB27" "$DB27D")" = "1" ]; then
    echo "PASS T27b --force replaces in place (still one slot)"
else
    echo "FAIL T27b expected 1 slot after --force, got $(count_slots "$DB27" "$DB27D")"
    FAILED=$((FAILED + 1))
fi

# ---------------------------------------------------------------------------
# T28: --dedup-any restores the broad "defer to ANY existing slot" semantics
#      the auto-arm watchdogs rely on — a DISTINCT handover is refused (rc 3)
#      when any HIMMEL-Resume job already exists, so safety arms never fan out.
# ---------------------------------------------------------------------------
DB28="$TMP/db28.tasks"; DB28D="$TMP/db28.atdir"; : > "$DB28"; mkdir -p "$DB28D"
HO_A=$(make_handover "$WORK_REPO")
HO_B=$(make_handover "$WORK_REPO")
TMPDIR="$TMP" SCHED_DB="$DB28" SCHED_DB_DIR="$DB28D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_A" >/dev/null 2>&1
out=$(TMPDIR="$TMP" SCHED_DB="$DB28" SCHED_DB_DIR="$DB28D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_B" --dedup-any 2>&1)
rc=$?
assert_rc "T28a --dedup-any distinct handover blocks when any slot exists (rc 3)" 3 "$rc"
assert_contains "T28a dedup ERR text preserved" "already scheduled" "$out"
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
out=$(TMPDIR="$TMP" SCHED_DB="$DB28E" SCHED_DB_DIR="$DB28ED" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dedup-any 2>&1)
rc=$?
assert_rc "T28c --dedup-any on empty scheduler arms (rc 0)" 0 "$rc"

# ---------------------------------------------------------------------------
# T29: soft slot cap (HIMMEL-340 decision: WARN, never block). With
#      ARM_MAX_SLOTS=2, arming a third distinct handover still succeeds
#      (rc 0) but emits a soft-cap WARN naming the count; arms below the cap
#      stay silent.
# ---------------------------------------------------------------------------
DB29="$TMP/db29.tasks"; DB29D="$TMP/db29.atdir"; : > "$DB29"; mkdir -p "$DB29D"
HO1=$(make_handover "$WORK_REPO")
HO2=$(make_handover "$WORK_REPO")
HO3=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" ARM_MAX_SLOTS=2 SCHED_DB="$DB29" SCHED_DB_DIR="$DB29D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO1" 2>&1)
assert_not_contains "T29a first arm below cap — no soft-cap warn" "soft cap" "$out"
out=$(TMPDIR="$TMP" ARM_MAX_SLOTS=2 SCHED_DB="$DB29" SCHED_DB_DIR="$DB29D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO2" 2>&1)
assert_not_contains "T29b arm reaching cap (2/2) — no soft-cap warn" "soft cap" "$out"
out=$(TMPDIR="$TMP" ARM_MAX_SLOTS=2 SCHED_DB="$DB29" SCHED_DB_DIR="$DB29D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO3" 2>&1)
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

# ---------------------------------------------------------------------------
# T30: --force on a GENUINE multislot scenario replaces ONLY the targeted
#      handover — two distinct slots, --force re-arm one, still TWO slots. A
#      regression to the legacy broad-scope delete (wiping siblings) would
#      pass T27 (single slot) but fail here — the precise wipe HIMMEL-340 kills.
# ---------------------------------------------------------------------------
DB30="$TMP/db30.tasks"; DB30D="$TMP/db30.atdir"; : > "$DB30"; mkdir -p "$DB30D"
HO_A=$(make_handover "$WORK_REPO")
HO_B=$(make_handover "$WORK_REPO")
TMPDIR="$TMP" SCHED_DB="$DB30" SCHED_DB_DIR="$DB30D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_A" >/dev/null 2>&1
TMPDIR="$TMP" SCHED_DB="$DB30" SCHED_DB_DIR="$DB30D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_B" >/dev/null 2>&1
out=$(TMPDIR="$TMP" SCHED_DB="$DB30" SCHED_DB_DIR="$DB30D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_A" --force 2>&1)
rc=$?
assert_rc "T30a --force re-arm of one of two distinct slots (rc 0)" 0 "$rc"
if [ "$(count_slots "$DB30" "$DB30D")" = "2" ]; then
    echo "PASS T30b --force replaced ONLY the targeted handover (sibling survived, 2 slots)"
else
    echo "FAIL T30b expected 2 slots (sibling preserved), got $(count_slots "$DB30" "$DB30D")"
    FAILED=$((FAILED + 1))
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
out=$(TMPDIR="$TMP" SCHED_DB="$DB31" SCHED_DB_DIR="$DB31D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_LONG" 2>&1)
assert_rc "T31a superset handover 'jobcollidex' arms (rc 0)" 0 "$?"
# The PREFIX name must ALSO arm — exact match means it does not collide with the
# superset already present. (Substring grep -F regression → false rc 3 here.)
out=$(TMPDIR="$TMP" SCHED_DB="$DB31" SCHED_DB_DIR="$DB31D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_SHORT" 2>&1)
assert_rc "T31b prefix handover 'jobcollide' also arms — no substring cross-match (rc 0)" 0 "$?"
if [ "$(count_slots "$DB31" "$DB31D")" = "2" ]; then
    echo "PASS T31c both prefix-related handovers coexist (2 slots)"
else
    echo "FAIL T31c expected 2 slots, got $(count_slots "$DB31" "$DB31D")"
    FAILED=$((FAILED + 1))
fi
# Re-arming the prefix name must dedup ONLY itself (rc 3), proving exact match.
out=$(TMPDIR="$TMP" SCHED_DB="$DB31" SCHED_DB_DIR="$DB31D" PATH="$STATEFUL_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_SHORT" 2>&1)
assert_rc "T31d re-arm 'jobcollide' dedups exactly itself (rc 3)" 3 "$?"

# ---------------------------------------------------------------------------
# T32: the relaunch is SELF-CLEANING — the spawned launcher deletes its own
#      scheduler entry as its first action so a fired /sc ONCE task (or a
#      recurring crontab entry) never lingers to block a same-handover re-arm
#      or fire twice. --force --dry-run isolates from the live scheduler and
#      prints the launcher body. Platform-branched: schtasks .bat carries a
#      self-/delete; the crontab fallback entry self-removes its marker line;
#      the at path needs nothing (atd auto-removes one-shot jobs).
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --force --dry-run 2>&1)
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

# ---------------------------------------------------------------------------
# W1-W5: --worktree isolation for code arms (HIMMEL-387)
# ---------------------------------------------------------------------------
# W1: --worktree dry-run computes the type+slug path, resumes there, pre-trusts it.
HO=$(make_handover "")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --worktree feat/wt-test --dry-run 2>&1)
rc=$?
assert_rc "W1 --worktree dry-run exits 0" 0 "$rc"
assert_contains "W1 announces worktree create" "would create worktree 'feat/wt-test'" "$out"
assert_contains "W1 path uses type+slug dir" ".claude/worktrees/feat+wt-test" "$out"
assert_contains "W1 RESUME_CWD set to worktree" "RESUME_CWD=" "$out"
assert_contains "W1 pre-trusts the worktree (HIMMEL-386 wiring)" "would pre-trust workspace" "$out"

# W2: invalid branch (no type/slug) → loud rc 1, no scheduler touched.
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --worktree not-valid --dry-run 2>&1)
rc=$?
assert_rc "W2 invalid worktree branch exits 1" 1 "$rc"
assert_contains "W2 explains type/slug requirement" "must be type/slug" "$out"

# W3: --cwd and --worktree together → rc 1 (the worktree IS the cwd).
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --worktree feat/wt-test --cwd "$WORK_REPO" --dry-run 2>&1)
rc=$?
assert_rc "W3 --cwd + --worktree exits 1" 1 "$rc"
assert_contains "W3 says mutually exclusive" "mutually exclusive" "$out"

# W4: resume_worktree frontmatter used when the flag is omitted.
HO_WT="$HANDOVER_DIR/handover-wt-fm.md"
{ printf -- '---\n'; printf 'resume_worktree: fix/wt-fm\n'; printf -- '---\n'; printf '# fm worktree\n'; } > "$HO_WT"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_WT" --dry-run 2>&1)
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
out=$(PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_STUB" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --worktree feat/wt-real 2>&1)
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
out=$(PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_FAIL_STUB" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --worktree feat/wt-fail 2>&1)
rc=$?
assert_rc "W6 worktree create failure exits 4" 4 "$rc"
assert_contains "W6 reports create failure" "worktree create failed" "$out"

# W7: worktree cmd returns 0 but creates no dir → post-create check exits 4.
out=$(PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_NODIR_STUB" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --worktree feat/wt-nodir 2>&1)
rc=$?
assert_rc "W7 create-but-no-dir exits 4" 4 "$rc"
assert_contains "W7 reports missing worktree dir" "expected worktree dir not found" "$out"

# W8: existing worktree dir → reused (create cmd NOT invoked), arm still succeeds.
# The stub would exit 1 IF called; rc 0 proves the reuse branch skipped it.
W8_DIR="$(cd "$(dirname "$ARM")/../.." && pwd)/.claude/worktrees/feat+wt-reuse"
mkdir -p "$W8_DIR"
out=$(PATH="$SCHED_STUB_T17:$PATH" ARM_WORKTREE_CMD="bash $WT_FAIL_STUB" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --worktree feat/wt-reuse 2>&1)
rc=$?
assert_rc "W8 reuse existing worktree exits 0 (cmd not called)" 0 "$rc"
assert_contains "W8 announces reuse" "reusing existing worktree" "$out"
rm -rf "$W8_DIR"

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
DB33=$(_collision_db); DB33D=$(_collision_dbdir); : > "$DB33"; mkdir -p "$DB33D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB33" SCHED_DB_DIR="$DB33D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T33 exact collision refuses (rc 6)" 6 "$rc"
assert_contains "T33 ERR names the collision" "time collision" "$out"
assert_contains "T33 ERR names the colliding task" "HIMMEL-Pipeline-Harvest" "$out"
assert_contains "T33 ERR mentions concurrent claude sessions" "claude sessions" "$out"
assert_contains "T33 free-slot suggestion printed" "Suggested free slots:" "$out"
assert_contains "T33 --force note printed" "--force" "$out"

# ---------------------------------------------------------------------------
# T34: NEAR collision (within window, not exact) → rc=0 + WARN.
#      Request 02:03, candidate at 02:00 (3 min away, within default 5-min window).
# ---------------------------------------------------------------------------
DB34=$(_collision_db); DB34D=$(_collision_dbdir); : > "$DB34"; mkdir -p "$DB34D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB34" SCHED_DB_DIR="$DB34D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:03" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T34 near collision still exits 0 (warn-only)" 0 "$rc"
assert_contains "T34 WARN printed for near collision" "WARN arm-resume: near time collision" "$out"
assert_contains "T34 WARN names the colliding task" "HIMMEL-Pipeline-Harvest" "$out"
assert_not_contains "T34 no ERR text on near collision" "ERR arm-resume: time collision" "$out"

# ---------------------------------------------------------------------------
# T35: OUTSIDE window → rc=0, no warn, no ERR.
#      Request 02:10, candidate at 02:00 (10 min away, outside default 5-min window).
# ---------------------------------------------------------------------------
DB35=$(_collision_db); DB35D=$(_collision_dbdir); : > "$DB35"; mkdir -p "$DB35D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB35" SCHED_DB_DIR="$DB35D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:10" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T35 outside window exits 0 silently" 0 "$rc"
assert_not_contains "T35 no collision warn outside window" "collision" "$out"

# ---------------------------------------------------------------------------
# T36: --force bypasses EXACT collision → rc=0 + override WARN (not ERR).
# ---------------------------------------------------------------------------
DB36=$(_collision_db); DB36D=$(_collision_dbdir); : > "$DB36"; mkdir -p "$DB36D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB36" SCHED_DB_DIR="$DB36D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --force --dry-run 2>&1)
rc=$?
assert_rc "T36 --force bypasses exact collision (rc 0)" 0 "$rc"
assert_not_contains "T36 no ERR on --force collision bypass" "ERR arm-resume: time collision" "$out"
assert_contains "T36 --force emits override WARN" "WARN arm-resume: --force: ignoring exact time collision" "$out"

# ---------------------------------------------------------------------------
# T37: --dedup-any (unattended watchdog) exact collision → WARN-ONLY (rc=0),
#      never refuses. Ensures unattended watchdog arms always succeed even when
#      another HIMMEL-* task fires at the same time.
# ---------------------------------------------------------------------------
DB37=$(_collision_db); DB37D=$(_collision_dbdir); : > "$DB37"; mkdir -p "$DB37D"
HO=$(make_handover "$WORK_REPO")
out=$(TMPDIR="$TMP" SCHED_DB="$DB37" SCHED_DB_DIR="$DB37D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "T37 --dedup-any exact collision is warn-only (rc 0)" 0 "$rc"
assert_not_contains "T37 no ERR on --dedup-any collision" "ERR arm-resume: time collision" "$out"
assert_contains "T37 --dedup-any emits WARN for exact collision" "WARN arm-resume: exact time collision" "$out"

# ---------------------------------------------------------------------------
# N1-N6: ticket-in-name + ticket-aware dedup/collision (HIMMEL-540)
#
# The scheduler task name now carries the inferred ticket ID:
#   HIMMEL-Resume-<TICKET>-<path-suffix>   (ticket inferable)
#   HIMMEL-Resume-<path-suffix>            (no ticket — unchanged form)
# Every dry-run name check runs with PATH="$SCHED_STUB_T17:$PATH" so
# list_existing hits the empty stub, not the real scheduler (a live armed job
# would otherwise spuriously rc 3). The asserted substring HIMMEL-Resume-HIMMEL-540-
# is interpolated whole into the dry-run scheduler line on every platform.
# make_handover STAYS ticketless — these positive cases use make_handover_titled.
# ---------------------------------------------------------------------------

# N1: ticket: front-matter (src-1) → exact HIMMEL-Resume-HIMMEL-540- segment.
HO=$(make_handover_titled "Test handover" "HIMMEL-540")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N1 ticket: frontmatter arm exits 0" 0 "$rc"
assert_contains "N1 name carries the front-matter ticket" "HIMMEL-Resume-HIMMEL-540-" "$out"

# N2: H1-title-derived (src-3), no front-matter → exact ticket segment.
HO=$(make_handover_titled "Resume: foo HIMMEL-540 (bar)")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N2 H1-title-derived arm exits 0" 0 "$rc"
assert_contains "N2 name carries the H1-title ticket" "HIMMEL-Resume-HIMMEL-540-" "$out"

# N3: worktree branch (src-2), REAL LOWERCASE form feat/himmel-540-x →
# uppercased HIMMEL-540 in the name. Proves src-2 normalizes AND that inference
# runs after the relocated TASK_NAME build (the F3 ordering guard: at the old
# line 491, the frontmatter/CLI worktree branch was resolved but the name was
# built before it). Asserts the portable substring (not a Windows-only line).
HO=$(make_handover "")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --worktree feat/himmel-540-x --dry-run 2>&1)
rc=$?
assert_rc "N3 worktree-branch arm exits 0" 0 "$rc"
assert_contains "N3 lowercase branch ticket is uppercased into the name" "HIMMEL-Resume-HIMMEL-540-" "$out"

# N4: ticketless fallback → current HIMMEL-Resume-<path-suffix> form, NO doubled
# HIMMEL-...HIMMEL- segment (no regression for arms with no inferable ticket).
HO=$(make_handover_titled "Test handover")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N4 ticketless arm exits 0" 0 "$rc"
assert_contains "N4 name keeps the HIMMEL-Resume- prefix" "HIMMEL-Resume-" "$out"
assert_not_contains "N4 no ticket segment for a ticketless handover" "HIMMEL-Resume-HIMMEL-" "$out"

# N5: body-mention-not-title — H1 has no key, a body line mentions LUNA-9. The
# H1-only scan must NOT pick up the body key (a stray reference can't be welded
# into the scheduler name). Falls back to the path-only name.
HO=$(make_handover_titled "No ticket title" "" "see LUNA-9 for context")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
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
out=$(TMPDIR="$TMP" SCHED_DB="$DBN6" SCHED_DB_DIR="$DBN6D" PATH="$STATEFUL_STUB:$PATH" \
    ARM_COLLISION_CANDIDATES="$(printf 'HIMMEL-Pipeline-Harvest\t02:00')" \
    bash "$ARM" --time "02:00" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N6 collision still HARD-REFUSES with a ticket-prefixed name (rc 6)" 6 "$rc"
assert_contains "N6 ERR names the collision" "time collision" "$out"

# N7: ticket: front-matter with surrounding quotes AND CRLF line endings — src-1
# reuses the exact rtrim-then-unquote idiom T5/T6/T7 prove fragile for resume_cwd:
# on Windows-authored YAML. A `ticket: "HIMMEL-540"\r` must still resolve.
HO_N7="$HANDOVER_DIR/ho-n7-crlf-$RANDOM.md"
printf -- '---\r\nsession_kind: test\r\nticket: "HIMMEL-540"\r\n---\r\n# No key in title\r\n' > "$HO_N7"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_N7" --dry-run 2>&1)
rc=$?
assert_rc "N7 quoted+CRLF ticket: arm exits 0" 0 "$rc"
assert_contains "N7 quoted+CRLF ticket: resolves into the name" "HIMMEL-Resume-HIMMEL-540-" "$out"
assert_not_contains "N7 no stray quote/CR welded into the name" 'HIMMEL-540"' "$out"

# N8: malformed multi-dash ticket: value is REJECTED by _validate_key (anchored
# ^<KEY>-<NUM>$) — falls back to the path-only name, no junk segment.
HO_N8=$(make_handover_titled "No key title" "ABC-123-456")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_N8" --dry-run 2>&1)
rc=$?
assert_rc "N8 malformed multi-dash ticket: arm exits 0" 0 "$rc"
assert_not_contains "N8 malformed key is not welded into the name" "HIMMEL-Resume-ABC-123" "$out"
assert_contains "N8 falls back to the HIMMEL-Resume- path-only prefix" "HIMMEL-Resume-" "$out"

# ---------------------------------------------------------------------------
# macOS backend: crontab for schedule + dedup + --force (HIMMEL-594)
# ---------------------------------------------------------------------------
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
out="$(mac_env bash "$ARM" --time "$FUTURE_TIME" --handover "$MAC_HO" --dry-run 2>&1)"; rc=$?
assert_rc "macOS schedule dry-run" 0 "$rc"
assert_contains "macOS uses crontab entry" "crontab entry" "$out"
assert_not_contains "macOS avoids at -t" "at -t" "$out"

# (b) real arm then a 2nd arm is deduped (proves list_existing reads crontab)
mac_env bash "$ARM" --time "$FUTURE_TIME" --handover "$MAC_HO" >/dev/null 2>&1
out="$(mac_env bash "$ARM" --time "$FUTURE_TIME" --handover "$MAC_HO" 2>&1)"; rc=$?
assert_rc "macOS 2nd arm deduped (rc=3)" 3 "$rc"

# (c) --force removes + replaces the crontab entry (one entry remains)
mac_env bash "$ARM" --time "$FUTURE_TIME" --handover "$MAC_HO" --force >/dev/null 2>&1
n="$(grep -c 'HIMMEL-Resume-' "$CRON_STORE" 2>/dev/null)" || n=0
if [ "$n" -eq 1 ]; then echo "PASS macOS --force keeps single entry"; else echo "FAIL macOS --force entries=$n"; FAILED=$((FAILED+1)); fi

# (d) scoped --force on macOS leaves a SIBLING handover's crontab line intact
# (HIMMEL-340 invariant on the crontab path: the full-line grep -vxF delete must
# remove ONLY handover A's marker, never B's). B uses a distinct time so the
# advisory collision check has nothing to flag.
a_line="$(grep 'HIMMEL-Resume-' "$CRON_STORE" | head -1)"
MAC_HO2="$(make_handover "$WORK_REPO")"
mac_env bash "$ARM" --time "23:58" --handover "$MAC_HO2" >/dev/null 2>&1   # arm sibling B
n="$(grep -c 'HIMMEL-Resume-' "$CRON_STORE" 2>/dev/null)" || n=0
if [ "$n" -eq 2 ]; then echo "PASS macOS two distinct handovers coexist"; else echo "FAIL macOS expected 2 slots, got $n"; FAILED=$((FAILED+1)); fi
b_line="$(grep -vF "$a_line" "$CRON_STORE" | grep 'HIMMEL-Resume-' | head -1)"
mac_env bash "$ARM" --time "$FUTURE_TIME" --handover "$MAC_HO" --force >/dev/null 2>&1   # force A
n="$(grep -c 'HIMMEL-Resume-' "$CRON_STORE" 2>/dev/null)" || n=0
if [ "$n" -eq 2 ]; then echo "PASS macOS --force on A leaves sibling B (2 slots)"; else echo "FAIL macOS sibling preserve entries=$n"; FAILED=$((FAILED+1)); fi
if [ -n "$b_line" ] && grep -qF "$b_line" "$CRON_STORE" 2>/dev/null; then echo "PASS macOS sibling B line survived --force on A"; else echo "FAIL macOS sibling B line wiped"; FAILED=$((FAILED+1)); fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
