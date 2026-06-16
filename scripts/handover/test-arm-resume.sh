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

# A separate directory for handover files (simulates yotam_docs).
HANDOVER_DIR="$TMP/yotam-docs/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/yotam-docs"

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
assert_not_contains "T1 --cwd does not resolve to yotam-docs" "RESUME_CWD=$HANDOVER_DIR" "$out"

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
# RESUME_CWD should resolve to the git toplevel of $TMP/yotam-docs.
# Compute the expected value the same way arm-resume does (git rev-parse).
EXPECTED_T4=$(git -C "$TMP/yotam-docs" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$TMP/yotam-docs")
assert_contains "T4 RESUME_CWD resolves to yotam-docs git-toplevel" "RESUME_CWD=$EXPECTED_T4" "$out"

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

TELEMETRY_T21="$TMP/telemetry-t21"
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$STUB_BIN:$PATH" SKILL_TELEMETRY_DIR="$TELEMETRY_T21" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" 2>&1)
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
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" 2>&1)
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
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
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
# (a) lib ABSENT — dedup must still block rc 3 with the ERR text intact
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$STUB_BIN:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" 2>&1)
rc=$?
assert_rc "T24 absent lib: dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T24 absent lib: ERR text intact" "already scheduled" "$out"
# (b) lib BROKEN (bash syntax error) — same dedup invariants, AND a
#     successful arm still completes end-to-end (rc 0, banner printed)
printf 'if [ broken\nthen (\n' > "$FAILOPEN/lib/telemetry.sh"
out=$(PATH="$STUB_BIN:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" 2>&1)
rc=$?
assert_rc "T24 broken lib: dedup still blocks (rc 3)" 3 "$rc"
assert_contains "T24 broken lib: ERR text intact" "already scheduled" "$out"
out=$(TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" \
    bash "$FAILOPEN/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" 2>&1)
rc=$?
assert_rc "T24 broken lib: successful arm still completes (rc 0)" 0 "$rc"
assert_contains "T24 broken lib: arm banner printed" "RESUME ARMED" "$out"

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
