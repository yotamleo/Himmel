#!/usr/bin/env bash
# test-arm-resume-cron.sh — HIMMEL-3074 crontab entry: a defined, runnable
# execution shape on a TTY-less scheduler.
#
# Adopter issue himmel#774 (macOS 26): the crontab entry arm-resume.sh
# installed ran a BARE `claude` under cron's PATH=/usr/bin:/bin, so it exited
# 127 at fire time and self-removed while the arm had reported success; even
# with PATH fixed it launched an interactive claude with no stdin/log redirect
# into a job that has no TTY; and the H1 ticket-inference sed used the GNU-only
# `{p;q}` form that BSD sed rejects. macOS always takes the crontab branch (`at`
# is deliberately avoided there), so /handover-arm-resume had no working mode.
#
# Revised (fold of Goomal's fix/arm-resume-macos-cron, commit
# 122659613fe458649327075a9fbda9cc6a8ee15f): the deeper root cause is
# Vixie/BSD cron's ~1000-byte MAX_COMMAND -- inlining the whole self-clean +
# launch on the crontab line (this suite's original shape) silently truncates
# on a real macOS box once the rendered command passes that cap, and because
# self-clean and launch were part of the SAME truncated line, the entry never
# removed itself either. The crontab line now carries only a fixed, short
# `/bin/sh <runner-path> # <TASK_NAME>` command; the self-clean + launch body
# moved into a generated runner FILE under
# `${ARM_RUNNER_DIR:-$HOME/.claude/handover/arm-runners}` (mode 700). This
# suite forces ARM_TERMINAL_APP=none throughout (the headless inline runner
# shape) so self-clean and launch stay in ONE file to assert on; the headed
# `open -a`/.command-file path is covered separately in test-arm-resume.sh's
# "774 (arm-macos-cron)" section.
#
# This suite pins the fix on the ONLY part of that path provable on Linux —
# the rendered entry + runner text and the arm-time refusal:
#   (a) the dry-run entry is a short, fixed-shape `/bin/sh <runner> #
#       <TASK_NAME>` line, and the previewed runner body resolves claude
#       ABSOLUTELY, exports the arm-time PATH snapshot inline, and gives the
#       fired job an explicit stdin (`< /dev/null`) and an append-only log;
#   (b) an arm whose `claude` does not resolve refuses rc 2 (fail LOUD) instead
#       of arming an entry that would exit 127 and vanish;
#   (c) the REAL (non-dry) macOS arm installs that same shape through a
#       stateful crontab stub, writes the runner file (mode 700) and creates
#       the log directory;
#   (d) the H1 sed is the portable `{p;q;}` form, and it still infers the
#       ticket under GNU sed here.
# NOT proven here: that the entry actually fires under macOS cron (no macOS
# host in this fleet), and the headed `open -a` launch (covered in
# test-arm-resume.sh). What would prove the former: arm a throwaway resume on
# a Mac, wait for the minute, and read ~/.himmel/arm-resume/<task>.log.
#
# The crontab branch is forced on any host via OSTYPE=darwin23 + a PATH-stubbed
# at/atq/crontab/claude — the same technique as test-arm-resume.sh's mac_env()
# and test-arm-resume-proxy.sh's T5. Uses --dry-run except for (c). Harness
# shields, helpers and fixtures are copied from test-arm-resume-context.sh (do
# not invent a new hermetic pattern).
#
# Platform guard (gitbash-only): the suite itself runs under any POSIX bash
# 3.2+; its assertions target arm-resume.sh's POSIX crontab emitter
# specifically (forced via OSTYPE), so they hold on a Windows host too — the
# Windows .bat branch is never entered here. No .ps1 twin.
set -uo pipefail

ARM="$(cd "$(dirname "$0")" && pwd)/arm-resume.sh"
[ -x "$ARM" ] || chmod +x "$ARM"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/arm-resume-cron.XXXXXX") || {
    echo "ERR test-arm-resume-cron: mktemp -d failed" >&2
    exit 1
}
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Hermetic shields — copied verbatim from test-arm-resume-context.sh.
# ---------------------------------------------------------------------------
export SKILL_TELEMETRY_DIR="$TMP/telemetry-default"
unset SKILL_TELEMETRY_DISABLE 2>/dev/null || true
unset ARM_NAME_TEMPLATE 2>/dev/null || true
unset RESUME_SLOT_THRESHOLD 2>/dev/null || true
unset CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK 2>/dev/null || true
export WORKER_BRIDGE_ROOT="$TMP/worker-bridge-shield"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
export ARM_TEMP_CWD_OK=1
export ARM_RESUME_DOTENV_ROOT="$TMP/dotenv-shield"
mkdir -p "$ARM_RESUME_DOTENV_ROOT"
unset ARMAUTOMERGE CR_MERGE_GATE_OK HIMMEL_HEADROOM_PROXY 2>/dev/null || true
# The log-directory seam under test: keep every fixture log under $TMP so
# the suite never writes into the operator's real $HOME/.himmel.
export ARM_RESUME_LOG_DIR="$TMP/arm-logs"
# Runner-file seam (fold of Goomal's fix/arm-resume-macos-cron): every REAL
# (non-dry-run) arm below now writes a generated runner file under
# ${ARM_RUNNER_DIR:-$HOME/.claude/handover/arm-runners} -- point it at a
# throwaway dir so this suite never writes into the operator's real $HOME.
export ARM_RUNNER_DIR="$TMP/arm-runners"

# ---------------------------------------------------------------------------
# Helpers — same idiom as test-arm-resume-context.sh
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
# Fixtures — same shape as test-arm-resume-context.sh
# ---------------------------------------------------------------------------
WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"

HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/statedocs"

_FT_FILE="$TMP/future-time.cache"
future_time() {
    local _now _target _value
    _now=$(date +%s)
    _target=0; _value=""
    [ -s "$_FT_FILE" ] && read -r _target _value < "$_FT_FILE"
    if [ -z "$_value" ] || [ "$(( _target - _now ))" -lt 600 ]; then
        _target=$(( _now + 1800 ))
        _value=$(python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1])).strftime('%H:%M'))" "$_target")
        printf '%s %s\n' "$_target" "$_value" > "$_FT_FILE"
    fi
    printf '%s' "$_value"
}

# make_handover [basename] [h1] — minimal valid handover; the H1 is the
# ticket-inference src-3 surface (d) exercises.
make_handover() {
    local base="${1:-handover-$RANDOM.md}" h1="${2:-# Test handover}"
    local path="$HANDOVER_DIR/$base"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        printf 'resume_cwd: %s\n' "$WORK_REPO"
        printf -- '---\n'
        printf '%s\n' "$h1"
    } > "$path"
    printf '%s' "$path"
}

# task_name_from_entry — pulls <TASK_NAME> off a rendered/installed crontab
# line shaped `<mm> <hh> * * * /bin/sh <runner-path> # <TASK_NAME>`.
task_name_from_entry() {
    printf '%s\n' "$1" | sed 's/.*# //'
}

# ---------------------------------------------------------------------------
# macOS stub bin — at MUST NOT be called (arm-resume.sh routes Darwin through
# crontab only); crontab is file-backed so (c) can read back what was
# installed; claude is a stub at a KNOWN absolute path the entry must bake.
# ---------------------------------------------------------------------------
MACBIN="$TMP/macbin"; mkdir -p "$MACBIN"
CRON_STORE="$TMP/cron.store"; : > "$CRON_STORE"
printf '#!/bin/sh\necho "at MUST NOT be called on macOS" >&2; exit 1\n' > "$MACBIN/at"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN/atq"
cat > "$MACBIN/crontab" <<CRONEOF
#!/bin/sh
case "\$1" in
  -l) if [ -s "$CRON_STORE" ]; then cat "$CRON_STORE"; exit 0; else exit 1; fi ;;
  -)  cat > "$CRON_STORE" ;;
  *)  exit 0 ;;
esac
CRONEOF
# claude stub: records that it was INVOKED (marker file, independent of any
# log redirect) and what it saw -- tty-ness and stdin byte count on stdout,
# one line on stderr -- so case (c-exec) can prove the entry's shape by
# execution, not by string-matching.
cat > "$MACBIN/claude" <<CLAUDEEOF
#!/bin/sh
printf 'STUB-CLAUDE-INVOKED argv=%s\\n' "\$*" >> "$TMP/claude-invoked"
if [ -t 0 ]; then echo "STUB-CLAUDE stdin=tty"; else echo "STUB-CLAUDE stdin=notty"; fi
echo "STUB-CLAUDE stdin-bytes=\$(cat | wc -c | tr -d ' ')"
echo "STUB-CLAUDE-STDERR" >&2
exit 0
CLAUDEEOF
printf '#!/bin/sh\nexit 1\n' > "$MACBIN/powershell"
chmod +x "$MACBIN/at" "$MACBIN/atq" "$MACBIN/crontab" "$MACBIN/claude" "$MACBIN/powershell"
# ARM_TERMINAL_APP=none: forces the headless inline runner (self-clean AND
# launch in ONE generated file) so this suite's assertions can read a single
# artifact -- the headed open -a/.command-file split is test-arm-resume.sh's
# "774" section's job.
mac_env() { env PATH="$MACBIN:$PATH" OSTYPE="darwin23" ARM_TERMINAL_APP=none "$@"; }

# Expected renderings: arm-resume.sh %q-quotes what it bakes, so compare
# against printf %q of the same values (the arm-time PATH IS "$MACBIN:$PATH").
EXPECTED_CLAUDE_Q=$(printf '%q' "$MACBIN/claude")
EXPECTED_PATH_Q=$(printf '%q' "$MACBIN:$PATH")
EXPECTED_LOGDIR_Q=$(printf '%q' "$ARM_RESUME_LOG_DIR")

# ---------------------------------------------------------------------------
# (a) dry-run: short fixed-shape entry; previewed runner resolves claude
#     absolutely, exports the inline PATH snapshot, and redirects stdin+log.
# ---------------------------------------------------------------------------
HO_A=$(make_handover)
out=$(mac_env bash "$ARM" --time "$(future_time)" --handover "$HO_A" --dry-run 2>&1)
rc=$?
assert_rc "a: macOS dry-run exits 0" 0 "$rc"
assert_contains "a: renders a crontab entry" "would add crontab entry" "$out"
entry_line=$(printf '%s\n' "$out" | sed -n 's/^    \(.*\/bin\/sh .*# HIMMEL-Resume-.*\)$/\1/p' | head -1)
assert_contains "a: crontab entry is the fixed /bin/sh <runner> shape" "/bin/sh $ARM_RUNNER_DIR/" "$entry_line"
assert_contains "a: entry keeps its trailing dedup marker" "# HIMMEL-Resume-" "$entry_line"
# Threshold is generous (500, not a tight bound) -- the entry's length rides
# on $ARM_RUNNER_DIR's own path length (here, mktemp's $TMPDIR), not on the
# handover path or prompt content, so there's no principled "exact" number;
# what matters is that it stays far under Vixie/BSD cron's ~1000-byte
# MAX_COMMAND regardless of handover length (proven independently below).
if [ -n "$entry_line" ] && [ "${#entry_line}" -lt 500 ]; then
    echo "PASS a: crontab entry stays short (${#entry_line} bytes), far under MAX_COMMAND"
else
    echo "FAIL a: crontab entry is ${#entry_line} bytes (expected a short fixed shape)"; FAILED=$((FAILED + 1))
fi
assert_contains "a: previewed runner section printed" "DRY arm-resume: runner (" "$out"
assert_contains "a: claude resolved ABSOLUTELY at arm time" "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 HIMMEL_ARMED_RELAUNCH=1 && $EXPECTED_CLAUDE_Q " "$out"
assert_not_contains "a: RED CONTROL — no bare claude left in the launch" "HIMMEL_ARMED_RELAUNCH=1 && claude " "$out"
assert_contains "a: arm-time PATH snapshot exported inline" "PATH=$EXPECTED_PATH_Q; export PATH" "$out"
assert_contains "a: stdin is explicit (/dev/null), not cron's undefined stdin" "< /dev/null" "$out"
assert_contains "a: output appended to a per-arm log under the log dir" ">> $EXPECTED_LOGDIR_Q/HIMMEL-Resume-" "$out"
assert_contains "a: log redirect captures stderr too" ".log 2>&1" "$out"
assert_contains "a: dry-run names the execution shape" "headless" "$out"
assert_contains "a: runner self-cleans via crontab -l" "crontab -l" "$out"
if [ -z "$(ls -A "$ARM_RUNNER_DIR" 2>/dev/null || true)" ]; then
    echo "PASS a: no runner file written under --dry-run"
else
    # shellcheck disable=SC2012  # HIMMEL-Resume-*.sh/.command names are ours (alnum); ls-over-glob is fine here
    echo "FAIL a: --dry-run wrote into $ARM_RUNNER_DIR: $(ls -A "$ARM_RUNNER_DIR" | tr '\n' ' ')"; FAILED=$((FAILED + 1))
fi

# ---------------------------------------------------------------------------
# (a-headed) CR round 3 (#780): the headed `.command` launch must NOT inherit
# the headless runner's stdin/log redirect. The `.command` file owns a real
# Terminal TTY; redirecting stdin to /dev/null gives claude immediate EOF and
# hiding stdout in the log defeats the whole point of opening the window.
# ---------------------------------------------------------------------------
HO_A2=$(make_handover)
out=$(env PATH="$MACBIN:$PATH" OSTYPE="darwin23" ARM_TERMINAL_APP=Terminal bash "$ARM" --time "$(future_time)" --handover "$HO_A2" --dry-run 2>&1)
rc=$?
assert_rc "a-headed: macOS headed dry-run exits 0" 0 "$rc"
assert_contains "a-headed: previews a command file section" "DRY arm-resume: command file (" "$out"
assert_contains "a-headed: dry-run names the headed execution shape" "headed launch via 'open -a" "$out"
assert_contains "a-headed: headed launch still resolves claude absolutely" "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 HIMMEL_ARMED_RELAUNCH=1 && $EXPECTED_CLAUDE_Q " "$out"
assert_not_contains "a-headed: RED CONTROL — headed .command body carries no stdin/log redirect" "< /dev/null" "$out"

# (a-long) empirical proof of the actual bug fix: an artificially long
# handover PATH (~950 chars, built as nested subdirs to stay under each
# filesystem's per-component NAME_MAX) would, under the OLD design
# (self-clean + launch inlined on the crontab line, including the resume
# prompt's embedded handover path -- see RESUME_PROMPT's `load $HANDOVER_PATH`
# in arm-resume.sh), push the rendered command well past Vixie/BSD cron's
# ~1000-byte MAX_COMMAND and silently truncate. The entry now stays short
# regardless -- the long path lives only in the runner FILE, which /bin/sh
# parses with no such limit.
LONGDIR="$HANDOVER_DIR"
for _seg in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    LONGDIR="$LONGDIR/$(printf 's%.0s' $(seq 1 50))$_seg"
done
mkdir -p "$LONGDIR"
HO_LONG="$LONGDIR/long.md"
{
    printf -- '---\n'
    printf 'session_kind: test\n'
    printf 'resume_cwd: %s\n' "$WORK_REPO"
    printf -- '---\n'
    printf '# Test handover\n'
} > "$HO_LONG"
if [ "${#HO_LONG}" -gt 900 ]; then
    echo "PASS a-long: PRECONDITION the fixture handover path is >900 chars (${#HO_LONG})"
else
    echo "FAIL a-long: PRECONDITION handover path only ${#HO_LONG} chars -- not long enough to prove the fix"; FAILED=$((FAILED + 1))
fi
out=$(mac_env bash "$ARM" --time "$(future_time)" --handover "$HO_LONG" --dry-run 2>&1)
rc=$?
assert_rc "a-long: dry-run with a ~950-char handover path still exits 0" 0 "$rc"
entry_line_long=$(printf '%s\n' "$out" | sed -n 's/^    \(.*\/bin\/sh .*# HIMMEL-Resume-.*\)$/\1/p' | head -1)
if [ -n "$entry_line_long" ] && [ "${#entry_line_long}" -lt 500 ]; then
    echo "PASS a-long: crontab entry stays short (${#entry_line_long} bytes) even with a ~950-char handover path"
else
    echo "FAIL a-long: crontab entry is ${#entry_line_long} bytes with a ~950-char handover path (would exceed MAX_COMMAND under the old inline design)"; FAILED=$((FAILED + 1))
fi
assert_contains "a-long: the long path DOES appear, just in the runner preview, not the entry" "$HO_LONG" "$out"
assert_not_contains "a-long: the long path is NOT on the crontab entry line itself" "$HO_LONG" "$entry_line_long"

# ---------------------------------------------------------------------------
# (a-percent) CR round on #780: ARM_RUNNER_DIR is a test seam / operator
# override, and cron reads a bare `%` as end-of-command + stdin -- `%q`
# quoting (shell metacharacters) does not cover that, so arm-resume.sh applies
# a SECOND, cron-specific escape: `q_runner=${q_runner//%/\\%}`. Assert the
# escape on the crontab ENTRY itself: executing the generated runner FILE
# would not exercise cron's percent parsing, since only the crontab line goes
# through cron's own parser.
# ---------------------------------------------------------------------------
PCTDIR="$TMP/arm%runners"; mkdir -p "$PCTDIR"
HO_PCT=$(make_handover)
out=$(ARM_RUNNER_DIR="$PCTDIR" mac_env bash "$ARM" --time "$(future_time)" --handover "$HO_PCT" --dry-run 2>&1)
rc=$?
assert_rc "a-percent: dry-run with a %-bearing ARM_RUNNER_DIR still exits 0" 0 "$rc"
entry_line_pct=$(printf '%s\n' "$out" | sed -n 's/^    \(.*\/bin\/sh .*# HIMMEL-Resume-.*\)$/\1/p' | head -1)
assert_contains "a-percent: crontab entry escapes the literal % as \\%" "arm\\%runners" "$entry_line_pct"
assert_not_contains "a-percent: RED CONTROL -- entry never carries an unescaped %" "arm%runners" "$entry_line_pct"

# ---------------------------------------------------------------------------
# (b) fail LOUD: no resolvable claude → rc 2, no entry rendered.
#     PATH = the stub bin WITHOUT claude + every arm-time PATH dir that carries
#     no claude executable, so the tools arm-resume.sh needs stay reachable
#     while claude does not.
# ---------------------------------------------------------------------------
NOCLAUDE="$TMP/noclaude"; mkdir -p "$NOCLAUDE"
cp "$MACBIN/at" "$MACBIN/atq" "$MACBIN/crontab" "$MACBIN/powershell" "$NOCLAUDE/"
_stripped=""
_oldifs=$IFS; IFS=:
for _d in $PATH; do
    [ -n "$_d" ] || continue
    [ -x "$_d/claude" ] && continue
    _stripped="${_stripped:+$_stripped:}$_d"
done
IFS=$_oldifs
HO_B=$(make_handover)
out=$(env PATH="$NOCLAUDE:$_stripped" OSTYPE="darwin23" ARM_TERMINAL_APP=none ARM_RUNNER_DIR="$ARM_RUNNER_DIR" bash "$ARM" --time "$(future_time)" --handover "$HO_B" --dry-run 2>&1)
rc=$?
assert_rc "b: unresolvable claude refuses rc 2 (not a silent self-removing entry)" 2 "$rc"
assert_contains "b: refusal names the cause" "'claude' not on PATH at arm time" "$out"
assert_not_contains "b: RED CONTROL — no entry rendered on refusal" "would add crontab entry" "$out"

# ---------------------------------------------------------------------------
# (c) REAL macOS arm through the stateful crontab stub: the installed line
#     is the short fixed shape, the runner file (mode 700) carries the launch
#     shape, and the log dir exists.
# ---------------------------------------------------------------------------
RUNNERDIR_C="$TMP/arm-runners-c"
HO_C=$(make_handover)
out=$(FLEET_CAP_OK=1 ARM_WITH_LIVE_WORKERS=1 ARM_RUNNER_DIR="$RUNNERDIR_C" mac_env bash "$ARM" --time "$(future_time)" --handover "$HO_C" 2>&1)
rc=$?
assert_rc "c: real macOS arm succeeds through the crontab stub" 0 "$rc"
installed=$(cat "$CRON_STORE" 2>/dev/null || true)
INSTALLED_LINE_C=$(printf '%s\n' "$installed" | grep -F '# HIMMEL-Resume-' | head -1)
TASK_NAME_C=$(task_name_from_entry "$INSTALLED_LINE_C")
RUNNER_PATH_C="$RUNNERDIR_C/$TASK_NAME_C.sh"
assert_contains "c: installed entry is the fixed /bin/sh <runner> shape" "/bin/sh $RUNNER_PATH_C # $TASK_NAME_C" "$installed"
if [ -f "$RUNNER_PATH_C" ]; then
    echo "PASS c: runner file exists on disk"
else
    echo "FAIL c: runner file missing: $RUNNER_PATH_C"; FAILED=$((FAILED + 1))
fi
_mode_c=$(stat -c '%a' "$RUNNER_PATH_C" 2>/dev/null || stat -f '%Lp' "$RUNNER_PATH_C" 2>/dev/null)
if [ "$_mode_c" = "700" ]; then
    echo "PASS c: runner file mode 700"
else
    echo "FAIL c: runner file mode=$_mode_c (expected 700)"; FAILED=$((FAILED + 1))
fi
RUNNER_BODY_C=$(cat "$RUNNER_PATH_C" 2>/dev/null)
assert_contains "c: runner bakes the absolute claude" "&& $EXPECTED_CLAUDE_Q " "$RUNNER_BODY_C"
assert_contains "c: runner exports the PATH snapshot" "PATH=$EXPECTED_PATH_Q; export PATH" "$RUNNER_BODY_C"
assert_contains "c: runner redirects stdin" "< /dev/null" "$RUNNER_BODY_C"
assert_contains "c: runner logs under the log dir" ">> $EXPECTED_LOGDIR_Q/" "$RUNNER_BODY_C"
assert_contains "c: runner carries HIMMEL_ARMED_RELAUNCH=1" "HIMMEL_ARMED_RELAUNCH=1" "$RUNNER_BODY_C"
if [ -d "$ARM_RESUME_LOG_DIR" ]; then
    echo "PASS c: log directory created at arm time"
else
    echo "FAIL c: log directory not created: $ARM_RESUME_LOG_DIR"; FAILED=$((FAILED + 1))
fi
assert_contains "c: success output names the log path" "$ARM_RESUME_LOG_DIR/" "$out"
# CR round 1 on #780: the arm probes the log FILE for append (`: >> $log_file`),
# not just the dir -- a dir that exists with a file that cannot be opened for
# append fails at fire time AFTER self_clean, the same silent no-op. The
# probe's artifact is the (empty) log file it leaves behind.
if ls "$ARM_RESUME_LOG_DIR"/HIMMEL-Resume-*.log >/dev/null 2>&1; then
    echo "PASS c: log file probed for append at arm time (exists after the arm)"
else
    echo "FAIL c: no log file under $ARM_RESUME_LOG_DIR after a successful arm -- append was not probed"; FAILED=$((FAILED + 1))
fi
# (c-exec) EXECUTE the generated runner FILE the way cron would (CR round 1 on
#     #780: an artifact that is only string-matched cannot fail on a quoting,
#     grouping or redirect regression). Run it under /bin/sh with cron's PATH
#     (/usr/bin:/bin) plus the stub dir WITHOUT claude in front -- so the stub
#     crontab shadows the real one, and the real claude is unreachable: the
#     launch can only be the baked absolute stub, and the tools it needs
#     beyond /usr/bin:/bin are reachable only through the runner's own inline
#     PATH export (its FIRST line, restoring the arm-time snapshot).
#     Preconditions ASSERTED, not assumed (N279: an un-stubbed arm launches a
#     REAL session). The rest of the test env (HIMMEL_FLOW_RUNS_LEDGER,
#     ARM_RESUME_LOG_DIR, ...) is kept so nothing writes outside $TMP.
EXEC_PATH="$NOCLAUDE:/usr/bin:/bin"
_pre_claude=$(env PATH="$EXEC_PATH" /bin/sh -c 'command -v claude' 2>/dev/null || true)
if [ -z "$_pre_claude" ]; then
    echo "PASS c-exec: PRECONDITION no claude resolvable on the execution PATH"
else
    echo "FAIL c-exec: PRECONDITION a claude resolves on the execution PATH ($_pre_claude) -- refusing to execute the runner"; FAILED=$((FAILED + 1))
fi
_pre_crontab=$(env PATH="$EXEC_PATH" /bin/sh -c 'command -v crontab' 2>/dev/null || true)
if [ "$_pre_crontab" = "$NOCLAUDE/crontab" ]; then
    echo "PASS c-exec: PRECONDITION the stub crontab shadows the real one on the execution PATH"
else
    echo "FAIL c-exec: PRECONDITION crontab on the execution PATH is '$_pre_crontab', not the stub -- refusing to execute the runner"; FAILED=$((FAILED + 1))
fi
if [ ! -e "$TMP/claude-invoked" ]; then
    echo "PASS c-exec: PRECONDITION stub marker absent before execution"
else
    echo "FAIL c-exec: PRECONDITION stub marker already present before execution"; FAILED=$((FAILED + 1))
fi
if [ -z "$_pre_claude" ] && [ "$_pre_crontab" = "$NOCLAUDE/crontab" ] && [ -f "$RUNNER_PATH_C" ]; then
    exec_out=$(env PATH="$EXEC_PATH" HIMMEL_FLOW_RUNS_LEDGER="$HIMMEL_FLOW_RUNS_LEDGER" /bin/sh "$RUNNER_PATH_C" 2>&1)
    rc=$?
    assert_rc "c-exec: the runner file runs to completion under cron's PATH" 0 "$rc"
    if [ "$exec_out" = "" ]; then
        echo "PASS c-exec: nothing escaped the redirects onto cron's stdout/stderr (no cron mail)"
    else
        echo "FAIL c-exec: output escaped the redirects: $exec_out"; FAILED=$((FAILED + 1))
    fi
    if [ -s "$TMP/claude-invoked" ]; then
        echo "PASS c-exec: the runner INVOKED claude (stub marker written)"
    else
        echo "FAIL c-exec: the runner ran rc=$rc but claude was never invoked -- a passing no-op"; FAILED=$((FAILED + 1))
    fi
    assert_contains "c-exec: claude received the resume prompt" "STUB-CLAUDE-INVOKED argv=" "$(cat "$TMP/claude-invoked" 2>/dev/null)"
    exec_log=$(cat "$ARM_RESUME_LOG_DIR"/HIMMEL-Resume-*.log 2>/dev/null || true)
    assert_contains "c-exec: claude ran with NO tty" "STUB-CLAUDE stdin=notty" "$exec_log"
    assert_contains "c-exec: claude's stdin was /dev/null (0 bytes)" "STUB-CLAUDE stdin-bytes=0" "$exec_log"
    assert_contains "c-exec: claude's stderr landed in the task log (2>&1)" "STUB-CLAUDE-STDERR" "$exec_log"
    assert_not_contains "c-exec: one-shot: the entry self-removed from the crontab" "# HIMMEL-Resume-" "$(cat "$CRON_STORE" 2>/dev/null)"
    assert_contains "c-exec: the flow-ledger group ran (armed-resume row in the pinned ledger)" "armed-resume" "$(cat "$HIMMEL_FLOW_RUNS_LEDGER" 2>/dev/null)"
else
    echo "FAIL c-exec: preconditions not met -- runner NOT executed"; FAILED=$((FAILED + 1))
fi
# (c2) fail LOUD when the log file cannot be opened for append: plant a
#      DIRECTORY at the log path (deterministic, works as root too) and expect
#      rc 4 with no entry installed.
: > "$CRON_STORE"
LOGDIR_C2="$TMP/arm-logs-c2"
RUNNERDIR_C2="$TMP/arm-runners-c2"
HO_C2=$(make_handover)
dry=$(ARM_RESUME_LOG_DIR="$LOGDIR_C2" ARM_RUNNER_DIR="$RUNNERDIR_C2" mac_env bash "$ARM" --time "$(future_time)" --handover "$HO_C2" --dry-run 2>&1)
log_c2=$(printf '%s\n' "$dry" | sed -n 's/.*output appended to \(.*\))\.$/\1/p' | head -1)
assert_contains "c2: dry-run NOTE names a log file under the override dir" "$LOGDIR_C2/" "$log_c2"
mkdir -p "$log_c2"
out=$(FLEET_CAP_OK=1 ARM_WITH_LIVE_WORKERS=1 ARM_RESUME_LOG_DIR="$LOGDIR_C2" ARM_RUNNER_DIR="$RUNNERDIR_C2" mac_env bash "$ARM" --time "$(future_time)" --handover "$HO_C2" 2>&1)
rc=$?
assert_rc "c2: unappendable log file refuses rc 4" 4 "$rc"
assert_contains "c2: refusal names the log file" "cannot create or append the arm log $log_c2" "$out"
installed=$(cat "$CRON_STORE" 2>/dev/null || true)
assert_not_contains "c2: RED CONTROL -- no entry installed on refusal" "# HIMMEL-Resume-" "$installed"

# ---------------------------------------------------------------------------
# (e) CR round 2 on #780: a `crontab -l` failure that is NOT the trusted
#     "no crontab yet" signature must never be treated as an empty crontab,
#     at arm time OR at fire time -- either would wipe every unrelated cron
#     job. Two sub-cases, each with its own stub so the failure is genuinely
#     exercised (not a blanket fixture):
#       (e1) arm-time snapshot (_crontab_schedule): crontab -l fails with a
#            real error (permission denied) -> abort rc 4 BEFORE the rewrite,
#            unrelated job untouched. Runs before any runner file is written,
#            so the runner-file split does not change this half.
#       (e2) fire-time self_clean: the SAME crontab binary baked into the
#            runner's own PATH= (so a real PATH cannot mask the failure)
#            starts failing -l only after arm time, simulating a transient
#            read failure at the moment cron actually fires the runner -> the
#            runner's self_clean `if`/`else`/`exit 1` block must refuse to
#            launch claude this tick, and must not wipe the unrelated job.
# ---------------------------------------------------------------------------
: > "$CRON_STORE"
echo "0 3 * * * /usr/bin/true # unrelated-job" > "$CRON_STORE"
FAILREAD="$TMP/failread"; mkdir -p "$FAILREAD"
cp "$MACBIN/at" "$MACBIN/atq" "$MACBIN/powershell" "$MACBIN/claude" "$FAILREAD/"
cat > "$FAILREAD/crontab" <<'CRONEOF'
#!/bin/sh
case "$1" in
  -l) echo "crontab: permission denied reading crontab" >&2; exit 1 ;;
  *)  exit 0 ;;
esac
CRONEOF
chmod +x "$FAILREAD/crontab"
HO_E1=$(make_handover)
out=$(FLEET_CAP_OK=1 ARM_WITH_LIVE_WORKERS=1 env PATH="$FAILREAD:$PATH" OSTYPE="darwin23" ARM_TERMINAL_APP=none ARM_RUNNER_DIR="$TMP/arm-runners-e1" bash "$ARM" --time "$(future_time)" --handover "$HO_E1" 2>&1)
rc=$?
assert_rc "e1: arm-time crontab -l failure (not 'no crontab') refuses rc 4" 4 "$rc"
assert_contains "e1: refusal names the read failure, not an assumed-empty crontab" "refusing to treat as empty crontab" "$out"
assert_contains "e1: RED CONTROL -- unrelated job untouched on refusal" "unrelated-job" "$(cat "$CRON_STORE" 2>/dev/null)"

: > "$CRON_STORE"
echo "0 3 * * * /usr/bin/true # unrelated-job" > "$CRON_STORE"
rm -f "$TMP/claude-invoked"
TOGGLE="$TMP/toggle"; mkdir -p "$TOGGLE"
TOGGLE_RUNNER_DIR="$TMP/toggle-arm-runners"
FAIL_FLAG="$TMP/toggle-fail-l"; rm -f "$FAIL_FLAG"
cat > "$TOGGLE/crontab" <<CRONEOF
#!/bin/sh
if [ -e "$FAIL_FLAG" ] && [ "\$1" = "-l" ]; then
  echo "crontab: permission denied reading crontab" >&2
  exit 1
fi
case "\$1" in
  -l) if [ -s "$CRON_STORE" ]; then cat "$CRON_STORE"; exit 0; else exit 1; fi ;;
  -)  cat > "$CRON_STORE" ;;
  *)  exit 0 ;;
esac
CRONEOF
chmod +x "$TOGGLE/crontab"
HO_E2=$(make_handover)
out=$(FLEET_CAP_OK=1 ARM_WITH_LIVE_WORKERS=1 env PATH="$TOGGLE:$MACBIN:$PATH" OSTYPE="darwin23" ARM_TERMINAL_APP=none ARM_RUNNER_DIR="$TOGGLE_RUNNER_DIR" bash "$ARM" --time "$(future_time)" --handover "$HO_E2" 2>&1)
rc=$?
assert_rc "e2: arm through the toggle stub succeeds (flag not yet set)" 0 "$rc"
installed=$(cat "$CRON_STORE" 2>/dev/null || true)
INSTALLED_LINE_E2=$(printf '%s\n' "$installed" | grep -F '# HIMMEL-Resume-' | head -1)
TASK_NAME_E2=$(task_name_from_entry "$INSTALLED_LINE_E2")
RUNNER_PATH_E2="$TOGGLE_RUNNER_DIR/$TASK_NAME_E2.sh"
if [ -f "$RUNNER_PATH_E2" ]; then
    echo "PASS e2: PRECONDITION a runner file installed to exercise self_clean"
else
    echo "FAIL e2: PRECONDITION runner file missing: $RUNNER_PATH_E2"; FAILED=$((FAILED + 1))
fi
touch "$FAIL_FLAG"
# The runner's OWN first line resets PATH to its arm-time snapshot (which
# already includes $TOGGLE), so the toggle's failure is exercised through the
# runner's own baked PATH, not this outer env override.
exec_out=$(env HIMMEL_FLOW_RUNS_LEDGER="$HIMMEL_FLOW_RUNS_LEDGER" /bin/sh "$RUNNER_PATH_E2" 2>&1)
if [ -s "$TMP/claude-invoked" ]; then
    echo "FAIL e2: claude was invoked despite the fire-time crontab -l failure -- self_clean fails open"; FAILED=$((FAILED + 1))
else
    echo "PASS e2: self_clean's fail-closed if/else/exit block refused to launch claude on a fire-time read failure"
fi
assert_contains "e2: RED CONTROL -- unrelated job survives a failed self-clean" "unrelated-job" "$(cat "$CRON_STORE" 2>/dev/null)"

# ---------------------------------------------------------------------------
# (f) HIMMEL-3122: the age-gated stale-runner prune (HIMMEL-Resume-*.sh/
#     .command, mtime +7) ran BEFORE the runner write. A --force re-arm of a
#     task whose OWN prior runner had gone stale (parked, not yet fired)
#     pruned that file first; if the replacement write then failed for a
#     reason unrelated to the prune, schedule_arm exited 4 having already
#     deleted the runner -- and because HIMMEL-1304 defers the old crontab
#     entry's replacement until the NEW job is registered, that untouched old
#     entry is left installed pointing at a now-missing file.
#
# Reproduced with a stubbed `rm` -- found first on PATH, the exact external
# command find's `-exec rm -f` in the prune loop shells out to -- that
# performs the REAL delete and only THEN (so the delete itself still
# happens, exactly as it would on main) revokes write on the runner dir.
# NOT a blanket read-only ARM_RUNNER_DIR (that would block the FIRST,
# unforced arm's own write too, and is a vacuous control): the stub only
# trips once armed via a flag file set right before the second call, so it
# strikes only the prune's own delete, nothing earlier. The stub also only
# ever acts on the ONE path it targets (compared by exact string, never a
# blind `dirname` of every argument): arm-resume.sh's own bank-preflight
# call shells out to `rm` too (fleet-reservation cleanup), so a stub that
# chmods any rm'd path's parent would reach into that reservation dir --
# which lives under the REAL $XDG_RUNTIME_DIR unless overridden, not $TMP.
# A dedicated throwaway XDG_RUNTIME_DIR keeps that reservation path (and
# every other real-host runtime path bank-preflight touches) off the host
# filesystem entirely, so the stub has nothing but the runner file to see.
# ---------------------------------------------------------------------------
: > "$CRON_STORE"
REAL_RM=$(command -v rm)
RUNNERDIR_F="$TMP/arm-runners-f"
XDG_F="$TMP/xdg-f"; mkdir -p "$XDG_F"
RMSTUB="$TMP/rmstub"; mkdir -p "$RMSTUB"
RM_TRIP_FLAG="$TMP/rm-trip-armed"
RUNNER_PATH_F_FLAG="$TMP/runner-path-f"
cat > "$RMSTUB/rm" <<RMEOF
#!/bin/sh
$REAL_RM "\$@"
_rc=\$?
if [ -e "$RM_TRIP_FLAG" ]; then
    _target=\$(cat "$RUNNER_PATH_F_FLAG" 2>/dev/null)
    for _a in "\$@"; do
        if [ -n "\$_target" ] && [ "\$_a" = "\$_target" ]; then
            chmod 555 "\$(dirname "\$_a")" 2>/dev/null || true
        fi
    done
fi
exit "\$_rc"
RMEOF
chmod +x "$RMSTUB/rm"

HO_F=$(make_handover)
out=$(FLEET_CAP_OK=1 ARM_WITH_LIVE_WORKERS=1 XDG_RUNTIME_DIR="$XDG_F" ARM_RUNNER_DIR="$RUNNERDIR_F" mac_env bash "$ARM" --time "$(future_time)" --handover "$HO_F" 2>&1)
rc=$?
assert_rc "f: PRECONDITION first (real) arm succeeds" 0 "$rc"
installed=$(cat "$CRON_STORE" 2>/dev/null || true)
INSTALLED_LINE_F=$(printf '%s\n' "$installed" | grep -F '# HIMMEL-Resume-' | head -1)
TASK_NAME_F=$(task_name_from_entry "$INSTALLED_LINE_F")
RUNNER_PATH_F="$RUNNERDIR_F/$TASK_NAME_F.sh"
if [ -f "$RUNNER_PATH_F" ]; then
    echo "PASS f: PRECONDITION runner file exists after the first arm"
else
    echo "FAIL f: PRECONDITION runner file missing after the first arm: $RUNNER_PATH_F"; FAILED=$((FAILED + 1))
fi
# Backdate the runner past the 7-day prune gate (portable: touch -d is
# GNU-only, BSD/macOS touch rejects it -- same fallback idiom as test-cap-
# reset-time.sh and test-arm-resume.sh's 1606 sibling fixture).
touch -d "8 days ago" "$RUNNER_PATH_F" 2>/dev/null \
    || touch -t "$(date -v -8d +%Y%m%d%H%M 2>/dev/null)" "$RUNNER_PATH_F"
printf '%s' "$RUNNER_PATH_F" > "$RUNNER_PATH_F_FLAG"
touch "$RM_TRIP_FLAG"
out2=$(FLEET_CAP_OK=1 ARM_WITH_LIVE_WORKERS=1 env PATH="$RMSTUB:$MACBIN:$PATH" OSTYPE="darwin23" ARM_TERMINAL_APP=none XDG_RUNTIME_DIR="$XDG_F" ARM_RUNNER_DIR="$RUNNERDIR_F" bash "$ARM" --time "$(future_time)" --handover "$HO_F" --force 2>&1)
rc2=$?
chmod -R u+w "$RUNNERDIR_F" 2>/dev/null || true
rm -f "$RM_TRIP_FLAG" "$RUNNER_PATH_F_FLAG"
assert_rc "f: forced re-arm of a task whose own runner had gone stale survives a write that races the prune" 0 "$rc2"
if [ -f "$RUNNER_PATH_F" ]; then
    echo "PASS f: runner file exists after the forced re-arm (not pruned out from under its own replacement write)"
else
    echo "FAIL f: HIMMEL-3122 -- runner file is GONE after the forced re-arm ($RUNNER_PATH_F); rc=$rc2, output: $out2"; FAILED=$((FAILED + 1))
fi
installed2=$(cat "$CRON_STORE" 2>/dev/null || true)
if printf '%s\n' "$installed2" | grep -qF "# $TASK_NAME_F"; then
    if [ -f "$RUNNER_PATH_F" ]; then
        echo "PASS f: the installed crontab entry's runner exists (not dangling)"
    else
        echo "FAIL f: HIMMEL-3122 RED CONTROL -- crontab entry for $TASK_NAME_F is installed but its runner is MISSING (the exact dangling-entry bug)"; FAILED=$((FAILED + 1))
    fi
else
    echo "FAIL f: no crontab entry for $TASK_NAME_F survives the forced re-arm attempt"; FAILED=$((FAILED + 1))
fi

# ---------------------------------------------------------------------------
# (d) sed portability: no GNU-only `{p;q}` left in the script; the portable
#     form works under the sed on THIS host; H1 ticket inference still works.
# ---------------------------------------------------------------------------
gnu_only=$(grep -c '{p;q}' "$ARM" || true)
if [ "${gnu_only:-0}" = "0" ]; then
    echo "PASS d: no GNU-only sed '{p;q}' left in arm-resume.sh"
else
    echo "FAIL d: arm-resume.sh still carries $gnu_only GNU-only sed '{p;q}' (BSD sed rejects it)"; FAILED=$((FAILED + 1))
fi
printf '# ABC-1 title\nbody\n' > "$TMP/h1.md"
h1=$(sed -n '/^# /{p;q;}' "$TMP/h1.md" 2>&1); rc=$?
assert_rc "d: portable '{p;q;}' form runs under this host's sed" 0 "$rc"
assert_contains "d: portable form prints the H1" "# ABC-1 title" "$h1"
# `notes.md`: a basename with no key, no ticket: frontmatter, no --worktree —
# so ONLY src-3 (the H1 sed) can supply the ticket in the task name.
# Case (c) left a real entry at future_time in the crontab store; the HIMMEL-407
# exact-minute collision check (rc 6) would refuse this dry-run on that seat,
# which is not what (d) measures — empty the store first.
: > "$CRON_STORE"
HO_D=$(make_handover "notes.md" "# ABC-1 cron portability fixture")
out=$(mac_env bash "$ARM" --time "$(future_time)" --handover "$HO_D" --dry-run 2>&1)
rc=$?
assert_rc "d: H1-keyed dry-run exits 0" 0 "$rc"
assert_contains "d: ticket inferred from the H1 via the portable sed" "HIMMEL-Resume-ABC-1" "$out"
assert_not_contains "d: no sed diagnostic on stderr" "extra characters at the end of q command" "$out"

# ---------------------------------------------------------------------------
# (g) HIMMEL-3121: `--time` defaults to `smart`, and the post-arm banner states
#     only what is true.
#
#   g1  --handover with NO --time reaches the smart path (dry-run, bank-free
#       fixture cache -> the ASAP slot). Pre-fix this died on the
#       "--time and --handover are required" refusal (rc=1).
#   g2  a missing --handover still refuses rc=1 -- the default covers --time only.
#   g3  regression control: an explicit past HH:MM is NEVER routed to smart.
#       It rolls to tomorrow and the >60-min guard refuses it (rc=9), exactly as
#       before this ticket.
#   g4  a REAL arm (stateful crontab stub, never a real scheduler) prints the
#       self-resume NOTE and no longer orders /exit. Pre-fix it printed
#       "PLEASE /exit YOUR CURRENT CLAUDE SESSION NOW." on every platform.
#
# Hermetic: a throwaway HOME + CLAUDE_CONFIG_DIR so nothing under the real
# ~/.claude is read or written; the usage cache is the RESUME_SLOT_CACHE fixture.
# ---------------------------------------------------------------------------
G_HOME="$TMP/g-home"; mkdir -p "$G_HOME/.claude"
g_env() { mac_env HOME="$G_HOME" CLAUDE_CONFIG_DIR="$G_HOME/.claude" "$@"; }
SLOT_FREE_3121="$TMP/usage-free-3121.json"
printf '{"five_hour":{"utilization":0.0,"resets_at":"%s"},"seven_day":{"utilization":5.0,"resets_at":"%s"}}' \
    "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')" \
    "$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=6)).isoformat())')" \
    > "$SLOT_FREE_3121"

: > "$CRON_STORE"
HO_G1=$(make_handover)
out=$(RESUME_SLOT_CACHE="$SLOT_FREE_3121" SLOT_MAX_AGE=0 g_env bash "$ARM" --handover "$HO_G1" --dry-run 2>&1)
rc=$?
assert_rc "g1: no --time (dry-run) exits 0 via the smart default" 0 "$rc"
assert_contains "g1: the omitted --time resolved through smart" "--time smart -> " "$out"
assert_contains "g1: smart reason is the bank-free ASAP slot" "bank free" "$out"
assert_not_contains "g1: RED CONTROL -- no --time/--handover required refusal" "are required" "$out"

out=$(RESUME_SLOT_CACHE="$SLOT_FREE_3121" SLOT_MAX_AGE=0 g_env bash "$ARM" --dry-run 2>&1)
rc=$?
assert_rc "g2: no --handover still refuses rc=1" 1 "$rc"
assert_contains "g2: the refusal names --handover" "--handover is required" "$out"
assert_not_contains "g2: RED CONTROL -- a missing --handover never reaches smart" "--time smart -> " "$out"

# An explicit-but-empty --time is malformed, not "omitted": it keeps refusing.
out=$(RESUME_SLOT_CACHE="$SLOT_FREE_3121" SLOT_MAX_AGE=0 g_env bash "$ARM" --time "" --handover "$HO_G1" --dry-run 2>&1)
rc=$?
assert_rc "g2b: an explicit empty --time still refuses rc=1" 1 "$rc"
assert_not_contains "g2b: RED CONTROL -- an empty --time never falls into smart" "--time smart -> " "$out"

# g3: a HH:MM that is already past today (1 minute ago) -- the exact minute
# rolls to tomorrow, ~24h out, which the long-gap guard refuses.
_past_hhmm=$(python3 -c "import datetime; print((datetime.datetime.now()-datetime.timedelta(minutes=1)).strftime('%H:%M'))")
out=$(RESUME_SLOT_CACHE="$SLOT_FREE_3121" SLOT_MAX_AGE=0 g_env bash "$ARM" --time "$_past_hhmm" --handover "$HO_G1" --dry-run 2>&1)
rc=$?
assert_rc "g3: an explicit past HH:MM is refused, not defaulted (rc=9 long-gap)" 9 "$rc"
assert_contains "g3: the refusal is the long-gap guard, not a smart resolution" "Refusing without --long-gap (rc=9)" "$out"
assert_not_contains "g3: RED CONTROL -- an explicit HH:MM never reaches smart" "--time smart -> " "$out"

# g4: REAL arm, no --time. Self-resume NOTE present; the imperative /exit gone.
: > "$CRON_STORE"
HO_G4=$(make_handover)
out=$(FLEET_CAP_OK=1 ARM_WITH_LIVE_WORKERS=1 ARM_RUNNER_DIR="$TMP/arm-runners-g" \
    RESUME_SLOT_CACHE="$SLOT_FREE_3121" SLOT_MAX_AGE=0 g_env bash "$ARM" --handover "$HO_G4" 2>&1)
rc=$?
assert_rc "g4: a real arm without --time succeeds through the crontab stub" 0 "$rc"
assert_contains "g4: the omitted --time resolved through smart" "--time smart -> " "$out"
assert_contains "g4: the arm registered" "RESUME ARMED" "$out"
assert_contains "g4: crontab stub holds the armed entry" "# HIMMEL-Resume-" "$(cat "$CRON_STORE" 2>/dev/null || true)"
assert_not_contains "g4: the imperative /exit order is gone" "PLEASE /exit YOUR CURRENT CLAUDE SESSION NOW." "$out"
assert_contains "g4: the self-resume NOTE replaces it" "NOTE (self-resume only):" "$out"
assert_contains "g4: the NOTE names the different-handover case" "different handover" "$out"

# g5: the same banner on an EXPLICIT-time real arm -- the imperative is gone
# there too. This is the assertion that is RED on the pre-fix banner even on a
# tree where g4's default cannot arm at all.
: > "$CRON_STORE"
HO_G5=$(make_handover)
out=$(FLEET_CAP_OK=1 ARM_WITH_LIVE_WORKERS=1 ARM_RUNNER_DIR="$TMP/arm-runners-g" g_env \
    bash "$ARM" --time "$(future_time)" --handover "$HO_G5" 2>&1)
rc=$?
assert_rc "g5: a real explicit-time arm succeeds through the crontab stub" 0 "$rc"
assert_contains "g5: it armed" "RESUME ARMED" "$out"
assert_not_contains "g5: the imperative /exit order is gone" "PLEASE /exit YOUR CURRENT CLAUDE SESSION NOW." "$out"
assert_contains "g5: the self-resume NOTE is present" "NOTE (self-resume only):" "$out"

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
