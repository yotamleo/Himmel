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
# Naming-template shield (HIMMEL-716): an operator shell exporting a custom
# ARM_NAME_TEMPLATE would skew every derived-name assertion below (N/S cases);
# S8/S9 set it per-call.
unset ARM_NAME_TEMPLATE 2>/dev/null || true
# Global workspace-trust shield (HIMMEL-386): arm-resume now pre-trusts the
# resolved cwd in ~/.claude.json. The non-dry-run arm cases below (T14-T20
# bridge/channel checks, dedup-any) would otherwise write the operator's real
# config — redirect the pre-seed at a throwaway file for the whole suite.
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"

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
# HIMMEL-966: host `at` must not be a dependency; pin the posix backend with the stub.
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$PAST_HHMM" --handover "$HO" --force --dry-run 2>&1)
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
# HIMMEL-966: host `at` must not be a dependency; pin the posix backend with the stub.
out=$(RESUME_SLOT_CACHE="$SLOT_CACHE" SLOT_MAX_AGE=0 PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time smart --handover "$HO" --force --dry-run 2>&1)
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
    chmod +x "$dir/schtasks" "$dir/at" "$dir/atq" "$dir/atrm" "$dir/claude" "$dir/powershell"
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
#   HIMMEL-Resume-<TICKET>-<path-suffix>     (ticket inferable)
#   HIMMEL-Resume-[<slug>-]<path-suffix>     (no ticket; HIMMEL-716 also welds
#                                            the handover slug when derivable)
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
# The needle targets the task-NAME context (Resume-HIMMEL-540") — a bare
# 'HIMMEL-540"' now legitimately appears as the closing quote of the HIMMEL-702
# `-n "HIMMEL-540"` session-title arg on the Windows .bat launch line, so a
# whole-output match would false-fail. A leaked YAML quote would weld INTO the
# task name (HIMMEL-Resume-HIMMEL-540"…), which this still catches.
assert_not_contains "N7 no stray quote/CR welded into the task name" 'Resume-HIMMEL-540"' "$out"

# N8: malformed multi-dash ticket: value is REJECTED by _validate_key (anchored
# ^<KEY>-<NUM>$) — falls back to the path-only name, no junk segment.
HO_N8=$(make_handover_titled "No key title" "ABC-123-456")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_N8" --dry-run 2>&1)
rc=$?
assert_rc "N8 malformed multi-dash ticket: arm exits 0" 0 "$rc"
assert_not_contains "N8 malformed key is not welded into the name" "HIMMEL-Resume-ABC-123" "$out"
assert_contains "N8 falls back to the HIMMEL-Resume- path-only prefix" "HIMMEL-Resume-" "$out"

# ---------------------------------------------------------------------------
# S1-S3 (HIMMEL-702): the relaunch bakes `claude -n "<TICKET> <name>"` so an
# armed session is self-titled (scannable /resume name + terminal tab). The
# name is the canonical retitle form (HIMMEL-432): the inferred ticket plus the
# worktree-slug name-half. Platform-branched like T32 — the dry-run prints the
# Windows .bat launch line on MSYS, the crontab/at line elsewhere; -n is quoted
# for CMD on Windows and printf %q-escaped (space -> '\ ') for /bin/sh.
# ---------------------------------------------------------------------------

# S1: worktree arm -> ticket (src-2, uppercased) + name-half from the slug.
HO=$(make_handover "")
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --worktree feat/himmel-702-demo --dry-run 2>&1)
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
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
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
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
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
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --worktree feat/cleanup --dry-run 2>&1)
rc=$?
assert_rc "S5 name-only (ticketless slug) arm exits 0" 0 "$rc"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S5 win .bat bakes -n <name>" '-n "cleanup"' "$out" ;;
    *)
        assert_contains "S5 cron/at bakes -n <name>" '-n cleanup ' "$out" ;;
esac

# ---------------------------------------------------------------------------
# N9-N10 / S6-S10 (HIMMEL-716): derived naming - chain position, slug
# fallback, ARM_NAME_TEMPLATE. Chained fixtures are next-session-<N>.md files
# inside a <TICKET>-<slug>/ epic dir (the handover skill's chain layout),
# which the existing helpers don't produce - make_handover_chained supplies
# them. Same stub/dry-run discipline as N1-N8 / S1-S5.
# ---------------------------------------------------------------------------
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
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
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
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N10 chained key-less arm exits 0" 0 "$rc"
assert_contains "N10 epic-dir key + slug + chain position welded" "HIMMEL-Resume-HIMMEL-654-ws7-gates-s7-" "$out"

# S7: no-ticket slug fallback (OSS adopter, no Jira at all) - a meaningfully
# named flat handover names the session and the scheduler row from its stem.
HO_S7="$HANDOVER_DIR/nightly-refactor-notes.md"
printf -- '---\nsession_kind: test\n---\n# Adopter handover, no ticket\n' > "$HO_S7"
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_S7" --dry-run 2>&1)
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
out=$(ARM_NAME_TEMPLATE='{slug}' PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_S8" --dry-run 2>&1)
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
out=$(ARM_NAME_TEMPLATE='{session}' PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
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
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_S10" --dry-run 2>&1)
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
out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --worktree feat/himmel-654-demo --dry-run 2>&1)
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
        out=$(PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO_BS" --dry-run 2>&1)
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
out=$(ARM_NAME_TEMPLATE='{ticket}-{session}' PATH="$SCHED_STUB_T17:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "N13 mixed-template chained arm exits 0" 0 "$rc"
assert_contains "N13 template renders ticket+session into the task name" "HIMMEL-Resume-HIMMEL-654-s5-" "$out"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        assert_contains "S12 win .bat bakes the mixed template title" '-n "HIMMEL-654-s5"' "$out" ;;
    *)
        assert_contains "S12 cron/at bakes the mixed template title" '-n HIMMEL-654-s5 ' "$out" ;;
esac

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

# S4 (HIMMEL-702): the crontab/POSIX launch line also bakes -n, printf %q-escaped
# so the space in "<TICKET> <name>" survives the /bin/sh re-parse at fire time.
# Exercised on ANY host via mac_env's forced OSTYPE=darwin -> _crontab_schedule,
# so the POSIX injection is covered even when the suite runs on Windows.
S4_HO="$(make_handover "$WORK_REPO")"
out="$(mac_env bash "$ARM" --time "$FUTURE_TIME" --handover "$S4_HO" --worktree feat/himmel-702-demo --dry-run 2>&1)"; rc=$?
assert_rc "S4 macOS/cron worktree arm exits 0" 0 "$rc"
assert_contains "S4 crontab entry bakes -n <ticket> <name> (%q-escaped)" '-n HIMMEL-702\ demo' "$out"

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
win_env() { local _dir="$1"; shift; env PATH="$_dir:$WINBIN:$PATH" OSTYPE="msys" "$@"; }

# ---------------------------------------------------------------------------
# T-wsl: Windows-host schtasks backend that relaunches inside a WSL distro.
# Forced through win_env on every host; wsl.exe distinguishes the two arm-time
# login-shell preflights via WSL_STUB_MODE.
# ---------------------------------------------------------------------------
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
    win_env "$WSLBIN" bash "$ARM" --time "$FUTURE_TIME" --handover "$WSL_HO" \
    --wsl-distro ubuntu --channels 'plugin:test@local' --force --dry-run 2>&1)
rc=$?
assert_rc "T-wsl body exits 0" 0 "$rc"
assert_contains "T-wsl body uses quoted distro + login shell" 'wsl.exe -d "ubuntu" -e bash -lc' "$out"
assert_contains "T-wsl body has in-distro cd+claude" "cd '$WSL_CWD' && claude" "$out"
assert_not_contains "T-wsl no caret escapes inside CMD quotes" '^&' "$out"
assert_contains "T-wsl prompt precedes channels" "'load $WSL_HO overnight mode' --channels 'plugin:test@local'" "$out"
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
    win_env "$WSLBIN" bash "$ARM" --time "$FUTURE_TIME" --handover "$WSL_SPECIAL_HO" \
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
            win_env "$WSLBIN" bash "$ARM" --time "$FUTURE_TIME" --handover "$WSL_DQUOTE_HO" \
            --cwd "$WSL_CWD" --wsl-distro ubuntu --force --dry-run 2>&1)
        rc=$?
        assert_rc "T-wsl double-quote payload refused" 2 "$rc"
        assert_contains "T-wsl double-quote refusal is clear" "cannot carry a double quote" "$out"
        ;;
esac

out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$WSL_HO" \
    --wsl-distro 'ubuntu; rm x' --dry-run 2>&1)
rc=$?
assert_rc "T-wsl bad distro rejected" 2 "$rc"
assert_contains "T-wsl bad distro error is clear" "invalid --wsl-distro name" "$out"

out=$(bash "$ARM" --time "$FUTURE_TIME" --handover "$WSL_HO" \
    --wsl-distro "" --dry-run 2>&1)
rc=$?
assert_rc "T-wsl empty distro rejected" 2 "$rc"
assert_contains "T-wsl empty distro error is clear" "requires a non-empty value" "$out"

out=$(PATH="$SCHED_STUB_T17:$PATH" OSTYPE=linux-gnu bash "$ARM" \
    --time "$FUTURE_TIME" --handover "$WSL_HO" --wsl-distro ubuntu --dry-run 2>&1)
rc=$?
assert_rc "T-wsl non-Windows platform rejected" 2 "$rc"
assert_contains "T-wsl non-Windows error is clear" "--wsl-distro is a Windows-host flag" "$out"

out=$(HIMMEL_HEADROOM_PROXY=0 WSL_STUB_MODE=cwd-fail \
    win_env "$WSLBIN" bash "$ARM" --time "$FUTURE_TIME" --handover "$WSL_HO" \
    --cwd /missing/in/wsl --wsl-distro ubuntu --force --dry-run 2>&1)
rc=$?
assert_rc "T-wsl in-distro cwd failure exits 4" 4 "$rc"
assert_contains "T-wsl cwd error names path" "/missing/in/wsl" "$out"
assert_contains "T-wsl cwd error names distro" "distro 'ubuntu'" "$out"

out=$(HIMMEL_HEADROOM_PROXY=0 WSL_STUB_MODE=claude-fail \
    win_env "$WSLBIN" bash "$ARM" --time "$FUTURE_TIME" --handover "$WSL_HO" \
    --cwd "$WSL_CWD" --wsl-distro ubuntu --force --dry-run 2>&1)
rc=$?
assert_rc "T-wsl in-distro claude failure exits 2" 2 "$rc"
assert_contains "T-wsl claude error names distro" "not on PATH at arm time (distro 'ubuntu')" "$out"

out=$(HIMMEL_HEADROOM_PROXY=1 WSL_STUB_MODE=ok \
    win_env "$WSLBIN" bash "$ARM" --time "$FUTURE_TIME" --handover "$WSL_HO" \
    --cwd "$WSL_CWD" --wsl-distro ubuntu --force --dry-run 2>&1)
rc=$?
assert_rc "T-wsl headroom combination exits 0" 0 "$rc"
assert_contains "T-wsl headroom skip warns" "proxy gate skipped for a WSL-station arm" "$out"
assert_contains "T-wsl headroom skip emits plain launch" 'wsl.exe -d "ubuntu" -e bash -lc' "$out"
assert_not_contains "T-wsl headroom skip omits proxy gate" "livez" "$out"

# V1: DD/MM locale render. `reg` reports a dd/MM/yyyy short-date pattern;
# --dry-run so no real scheduler is touched. The expected /sd is computed
# independently here (mirroring arm-resume's own HH:MM -> today/tomorrow
# rule), so the assertion is an exact full-string match that's correct
# regardless of what day the suite happens to run on (no reliance on
# today's day-of-month differing from today's month).
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
' "$FUTURE_TIME")
out=$(win_env "$V1BIN" bash "$ARM" --time "$FUTURE_TIME" --handover "$V1_HO" --dry-run 2>&1)
rc=$?
assert_rc "V1 dd/MM/yyyy locale dry-run exits 0" 0 "$rc"
assert_contains "V1 /sd rendered day-first per machine locale" "/sd $V1_EXPECT " "$out"

# V2: registry read fails -> falls back to the pre-HIMMEL-938 MM/dd/yyyy
# (byte-identical to the old hardcoded behavior). `reg` here mimics a
# missing/inaccessible key: nonzero exit, nothing useful on stdout.
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
' "$FUTURE_TIME")
out=$(win_env "$V2BIN" bash "$ARM" --time "$FUTURE_TIME" --handover "$V2_HO" --dry-run 2>&1)
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
out=$(win_env "$V2B_BIN" bash "$ARM" --time "$FUTURE_TIME" --handover "$V2B_HO" --dry-run 2>&1)
rc=$?
assert_rc "V2b month-name pattern dry-run still exits 0" 0 "$rc"
assert_contains "V2b /sd falls back to MM/dd/yyyy on MMM pattern" "/sd $V2_EXPECT " "$out"

# V3-V5 share a stateless create-ok schtasks stub (with a logged /delete) and
# an empty-scheduler /query — these are REAL (non-dry-run) arms so the
# post-arm verify block actually runs. `reg` is intentionally ABSENT from
# these stub dirs (same as a bare Linux box): the locale render falls back
# to MM/dd/yyyy, which is irrelevant to what V3-V5 exercise.
make_verify_stub() {
    local dir="$1" ps_body="$2"
    mkdir -p "$dir"
    cat > "$dir/schtasks" <<EOF
#!/usr/bin/env bash
case "\$1" in
    /query)  exit 0 ;;
    /create) exit 0 ;;
    /delete) printf '%s\n' "\$*" >> "$dir/delete.log"; exit 0 ;;
    *)       exit 0 ;;
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
V3="$TMP/v3-stub-bin"
make_verify_stub "$V3" 'python3 -c "import time; print(int(time.time()) + 180*86400)"'
V3_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V3" bash "$ARM" --time "$FUTURE_TIME" --handover "$V3_HO" 2>&1)
rc=$?
assert_rc "V3 months-out verify refuses (rc=2)" 2 "$rc"
assert_contains "V3 ERR mentions NextRunTime" "NextRunTime" "$out"
if [ -s "$V3/delete.log" ]; then
    echo "PASS V3 bad task was deleted (schtasks /delete hit)"
else
    echo "FAIL V3 expected schtasks /delete to be called"
    FAILED=$((FAILED + 1))
fi

# V4: registered NextRunTime matches the requested time exactly -> verify
# passes, arm stands (rc=0). The stub can't independently derive
# TARGET_EPOCH either, so the test computes it FIRST (mirroring arm-resume's
# own HH:MM -> epoch rule) and threads it straight into the stub script --
# simulating a scheduler that registered exactly what was asked.
V4_EPOCH=$(python3 -c '
import datetime, sys
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.datetime.now().astimezone()
cand = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(int(cand.timestamp()))
' "$FUTURE_TIME")
V4="$TMP/v4-stub-bin"
make_verify_stub "$V4" "echo $V4_EPOCH"
V4_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V4" bash "$ARM" --time "$FUTURE_TIME" --handover "$V4_HO" 2>&1)
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
out=$(TMPDIR="$TMP" win_env "$V4B" bash "$ARM" --time "$FUTURE_TIME" --handover "$V4B_HO" 2>&1)
rc=$?
assert_rc "V4b 121s NextRunTime mismatch refuses (rc=2)" 2 "$rc"
assert_contains "V4b ERR names the 120s tolerance" "120s tolerance" "$out"
if [ -s "$V4B/delete.log" ]; then
    echo "PASS V4b mistimed task was deleted (schtasks /delete hit)"
else
    echo "FAIL V4b expected schtasks /delete to be called"
    FAILED=$((FAILED + 1))
fi

# V5: the verify PROBE itself fails (powershell exits nonzero, no output)
# while locale detection WORKS -> fail-OPEN: a WARN, but the arm still
# stands (rc=0). Distinguishes the infra-failure path (V5) from the
# bad-answer path (V3): only a CONFIRMED bad answer deletes the task. The
# reg stub matters (codex-adv-8): with locale detection ALSO down this
# would be the V8 dual-failure refuse, and on Linux CI there is no real
# reg to fall back on.
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
out=$(TMPDIR="$TMP" win_env "$V5" bash "$ARM" --time "$FUTURE_TIME" --handover "$V5_HO" 2>&1)
rc=$?
assert_rc "V5 verify-infra-failure still arms (rc=0)" 0 "$rc"
assert_contains "V5 WARN surfaced for the failed probe" "WARN arm-resume: post-arm NextRunTime verify could not run" "$out"
if [ -s "$V5/delete.log" ]; then
    echo "FAIL V5 infra failure must NOT delete the task"
    FAILED=$((FAILED + 1))
else
    echo "PASS V5 infra failure leaves the task in place"
fi

# V6: NEXTRUN-NONE with a target that PASSED during the create->verify
# window -> the race guard (codex-adv-1/-2): the .bat self-deletes its task
# registration on fire, so a task missing AFTER its target time legitimately
# fired -- the arm is CONSUMED (WARN + rc=0, no delete). The powershell stub
# simulates the slow probe by sleeping until the target has passed before
# answering NEXTRUN-NONE. Target = next whole minute (lead 1-60s); if that
# crosses midnight the HH:MM -> today/tomorrow rule inflates the lead to
# ~24h -- skip rather than flake (this suite runs overnight).
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
    # Sleep past the target (lead + small margin), then report the task gone
    # -- simulating a probe that ran after the task fired and self-deleted.
    make_verify_stub "$V6" "sleep $((NEAR_LEAD + 3))
echo NEXTRUN-NONE"
    V6_HO="$(make_handover "$WORK_REPO")"
    out=$(TMPDIR="$TMP" win_env "$V6" bash "$ARM" --time "$NEAR_TIME" --handover "$V6_HO" 2>&1)
    rc=$?
    assert_rc "V6 NEXTRUN-NONE after target passed = consumed (rc=0)" 0 "$rc"
    assert_contains "V6 WARN says consumed, not failed" "treating the arm as consumed" "$out"
    if [ -s "$V6/delete.log" ]; then
        echo "FAIL V6 consumed arm must NOT trigger a delete"
        FAILED=$((FAILED + 1))
    else
        echo "PASS V6 consumed arm leaves scheduler state alone"
    fi
fi

# V6b (codex-adv-2 negative): NEXTRUN-NONE while the target is STILL FUTURE
# (~2min lead) -> a scheduler never fires early, so the task cannot have
# been consumed; this is a bad registration (e.g. a past-date /sd misparse
# also registers with no NextRunTime) -> loud refuse (rc=2) + delete.
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

# V6c (codex-adv-3): /create itself completed AFTER the target passed (slow
# setup on a tight lead) -> the ONCE task registered already-expired and can
# NEVER fire; NEXTRUN-NONE here must refuse (rc=2), never report consumed.
# The schtasks stub sleeps past the target inside /create to simulate the
# slow path; the probe answers NEXTRUN-NONE immediately.
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

# V7: NEXTRUN-NONE with a FAR target (lead > 180s) -> still the loud-refuse
# path: a task that vanished long before its fire time was never registered
# right (the original HIMMEL-938/HIMMEL-204 silent-misarm class). Skip in
# the last ~10 minutes before midnight, where FUTURE_TIME (23:59) stops
# being "far".
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
    out=$(TMPDIR="$TMP" win_env "$V7" bash "$ARM" --time "$FUTURE_TIME" --handover "$V7_HO" 2>&1)
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

# V8 (codex-adv-8): BOTH safeguards down -- locale detection fails (reg
# errors -> MM/dd/yyyy fallback) AND the verify probe fails -> on a
# day-first machine this is the original silent-misarm class again, so the
# arm must fail CLOSED: delete + rc=2, never a silent success.
V8="$TMP/v8-stub-bin"
make_verify_stub "$V8" 'echo "stub: powershell unavailable" >&2; exit 1'
cat > "$V8/reg" <<'EOF'
#!/usr/bin/env bash
echo "stub: registry unavailable" >&2
exit 1
EOF
chmod +x "$V8/reg"
V8_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V8" bash "$ARM" --time "$FUTURE_TIME" --handover "$V8_HO" 2>&1)
rc=$?
assert_rc "V8 locale-fallback + probe-failure refuses (rc=2)" 2 "$rc"
assert_contains "V8 ERR names both safeguards" "both safeguards unavailable" "$out"
if [ -s "$V8/delete.log" ]; then
    echo "PASS V8 dual-failure arm was deleted (schtasks /delete hit)"
else
    echo "FAIL V8 expected schtasks /delete to be called"
    FAILED=$((FAILED + 1))
fi

# V8b (codex-adv-9): locale fallback + probe that SUCCEEDS (rc=0) but emits
# garbage -- no usable confirmation either -> same dual-failure refuse.
V8B="$TMP/v8b-stub-bin"
make_verify_stub "$V8B" 'echo "PS banner noise: not a number"'
cat > "$V8B/reg" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$V8B/reg"
V8B_HO="$(make_handover "$WORK_REPO")"
out=$(TMPDIR="$TMP" win_env "$V8B" bash "$ARM" --time "$FUTURE_TIME" --handover "$V8B_HO" 2>&1)
rc=$?
assert_rc "V8b locale-fallback + garbage probe output refuses (rc=2)" 2 "$rc"
assert_contains "V8b ERR names the non-numeric dual failure" "non-numeric NextRunTime" "$out"
if [ -s "$V8B/delete.log" ]; then
    echo "PASS V8b dual-failure arm was deleted (schtasks /delete hit)"
else
    echo "FAIL V8b expected schtasks /delete to be called"
    FAILED=$((FAILED + 1))
fi

# V9 (codex-adv-11): the verify rejects (months-out answer) but the cleanup
# /delete FAILS -> the refusal must still exit 2 AND loudly surface that the
# known-bad task is STILL SCHEDULED (not silently claim cleanup).
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
out=$(TMPDIR="$TMP" win_env "$V9" bash "$ARM" --time "$FUTURE_TIME" --handover "$V9_HO" 2>&1)
rc=$?
assert_rc "V9 rejection with failed delete still refuses (rc=2)" 2 "$rc"
assert_contains "V9 residual-task risk surfaced loudly" "STILL SCHEDULED" "$out"

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
