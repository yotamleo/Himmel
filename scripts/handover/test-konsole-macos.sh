#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-headed-arm.sh
# scripts/handover/test-konsole-macos.sh - suite for konsole-macos.sh (HIMMEL-2534).
#
# konsole-macos.sh is the shim that gives headed-arm.sh a TTY on macOS, where
# konsole does not exist. It accepts the EXACT konsole argv headed-arm.sh
# already builds and translates it into `open -a <App> <file>.command`. This
# suite asserts:
#   1. the argv contract: only the shapes headed-arm.sh emits are accepted,
#      everything else is a loud exit 2 rather than a silently ignored flag.
#   2. the launch genuinely runs the command, in the requested --workdir,
#      with argv elements preserved across the .command file's shell (the
#      %q quoting) - including a value containing spaces.
#   3. BLOCKING, the load-bearing property: the shim must not return before
#      the launched command exits, because headed-arm.sh backgrounds it and
#      reads a dead pid as a failed launch. A shim that returned early would
#      make every successful arm look like a failure.
#   4. the launched command's rc is the shim's rc.
#   5. app resolution mirrors arm-resume.sh: ARM_TERMINAL_APP wins, a missing
#      app WARNs and falls back to Terminal rather than refusing the launch.
#   6. a failing `open` is exit 3; a session that never reports a pid is
#      exit 4 (never a silent success).
#
# Platform guard (gitbash-only): POSIX bash 3.2+. The suite is hermetic - it
# stubs `open` on PATH with a stand-in that runs the .command itself, so no
# real terminal window is ever opened and the cases run in milliseconds.
#
# Seams used: KONSOLE_MACOS_STARTUP_TICKS shortens the pid-wait budget so the
# timeout case does not pay 20s; ARM_TERMINAL_APP / ARM_APP_DIRS are
# arm-resume.sh's app-resolution seams, which the shim reuses.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; SCRIPT="$HERE/konsole-macos.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/konsole-macos-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()        { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains()     { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
# HIMMEL-3484: only grep's rc 1 means "absent"; rc >1 is an execution error,
# which would otherwise pass every negative assertion vacuously.
not_contains() {
    local _rc=0
    grepq "$2" -F -e "$3" || _rc=$?
    case "$_rc" in
        0) echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)) ;;
        1) echo "ok - $1" ;;
        *) echo "FAIL - $1: grep itself failed (rc $_rc)"; fails=$((fails+1)) ;;
    esac
}

# A stub `open` standing in for the real terminal: it records its own argv,
# then RUNS the .command in the background exactly as a terminal window
# would, so the shim's pid-wait and blocking behaviour are exercised for
# real rather than mocked away.
mk_open_stub() { # mk_open_stub <bindir> <argv-log> [mode]
    local bindir="$1" log="$2" mode="${3:-run}"
    mkdir -p "$bindir"
    cat > "$bindir/open" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "$mode" in
    fail)   exit 1 ;;                 # \`open\` itself fails: nothing launched
    silent) exit 0 ;;                 # opens, but the body never runs (no pid)
    # env -i: a real \`open -a\` starts the body from a FRESH environment, so
    # the stub must not hand it the caller's PATH - only the body's own
    # PATH export may make 2f's bare name resolve (N357, codex-3).
    run)    for a in "\$@"; do case "\$a" in *.command) env -i "\$a" >/dev/null 2>&1 & ;; esac; done; exit 0 ;;
    # late: the body is already open (fd 3) when the shim's scratch dir is
    # removed - the timeout-cleanup race - and only then runs (N357 r2 codex-1).
    late)   for a in "\$@"; do case "\$a" in *.command) ( exec 3<"\$a"; rm -rf "\$(dirname "\$a")"; env -i sh /dev/fd/3 ) >/dev/null 2>&1 & ;; esac; done; exit 0 ;;
    # orphan (HIMMEL-3484): the body only starts once the shim has already
    # given up and exited, yet finds its scratch dir present (a cleanup that
    # lost the race with the body's own pid write). The pid write succeeds,
    # so only the startup handshake can stop the command from running.
    orphan) shim=\$PPID; for a in "\$@"; do case "\$a" in *.command) cp "\$a" "$log.body"; ( while kill -0 "\$shim" 2>/dev/null; do sleep 0.1; done; mkdir -p "\$(dirname "\$a")"; env -i sh "$log.body" ) >/dev/null 2>&1 & ;; esac; done; exit 0 ;;
esac
STUB
    chmod +x "$bindir/open"
}

# An app-dir fixture so resolution never depends on what is installed here.
appdirs="$tmp/apps"; mkdir -p "$appdirs/iTerm.app" "$appdirs/Terminal.app"

run_shim() { # run_shim <bindir> -- <args...>  (stdout+stderr merged, rc echoed last)
    local bindir="$1"; shift; [ "$1" = "--" ] && shift
    PATH="$bindir:$PATH" ARM_APP_DIRS="$appdirs" "$SCRIPT" "$@" 2>&1
}

# --- 1. argv contract -------------------------------------------------------
b1="$tmp/b1"; mk_open_stub "$b1" "$tmp/open1.log"
out="$(run_shim "$b1" -- --bogus)"; rc=$?
check "1a unsupported flag: exit 2" "$rc" "2"
contains "1a unsupported flag: names the offender" "$out" "unsupported argument '--bogus'"
out="$(run_shim "$b1" -- --separate)"; rc=$?
check "1b no -e: exit 2" "$rc" "2"
contains "1b no -e: says -e is required" "$out" "-e is required"
out="$(run_shim "$b1" -- --separate -e)"; rc=$?
check "1b2 -e with no operand: exit 2" "$rc" "2"
contains "1b2 -e with no operand: says -e is required" "$out" "-e is required"
out="$(run_shim "$b1" -- --workdir "$tmp/nope" -e true)"; rc=$?
check "1c missing --workdir dir: exit 2" "$rc" "2"
out="$(run_shim "$b1" -- --workdir -e true)"; rc=$?
check "1d --workdir with no value: exit 2" "$rc" "2"
# -p carries konsole profile properties; only tabtitle is meaningful here,
# but an UNKNOWN -p property must not be fatal - konsole ignores those too.
out="$(run_shim "$b1" -- --separate -p "somethingelse=x" -e true)"; rc=$?
check "1e unknown -p property: accepted, not fatal" "$rc" "0"

# --- 2. the launch actually runs the command --------------------------------
b2="$tmp/b2"; mk_open_stub "$b2" "$tmp/open2.log"
# $TMPDIR commonly carries a trailing slash, so "$tmp/work" can contain a
# double slash that `pwd` normalises away in the launched shell - compare
# against the normalised form, not the raw concatenation.
wd="$tmp/work"; mkdir -p "$wd"; wd="$(cd "$wd" && pwd)"
marker="$tmp/ran.txt"; rm -f "$marker"
# HIMMEL-2534 CR fix (N346): case 2c asserts the no-ARM_TERMINAL_APP default
# resolves to iTerm, but that default reads $TERM_PROGRAM - green only by
# accident, on a Mac running this suite inside iTerm. Pin it.
out="$(TERM_PROGRAM=iTerm.app run_shim "$b2" -- --separate --workdir "$wd" -p "tabtitle=probe" \
    -e /bin/sh -c "pwd > '$marker'; printf '%s\n' \"\$0\" >> '$marker'")"
rc=$?
check "2a happy path: exit 0" "$rc" "0"
check "2b ran in --workdir" "$(sed -n 1p "$marker" 2>/dev/null)" "$wd"
contains "2c open was told which app to use" "$(cat "$tmp/open2.log")" "-a iTerm"
contains "2d open was handed a .command file" "$(cat "$tmp/open2.log")" ".command"

# An argv element containing spaces (a real claude prompt) must survive the
# trip through the .command file's shell - this is what the %q quoting buys.
b3="$tmp/b3"; mk_open_stub "$b3" "$tmp/open3.log"
spaced="$tmp/spaced.txt"; rm -f "$spaced"
out="$(run_shim "$b3" -- --separate --workdir "$wd" \
    -e /bin/sh -c "printf '%s' \"\$1\" > '$spaced'" sh "load handover doc #4 now")"
check "2e argv value with spaces survives as ONE element" "$(cat "$spaced" 2>/dev/null)" "load handover doc #4 now"

# --- 2f. ENVIRONMENT: PATH must reach the launched command -------------------
# codex-review S9: `open -a` does not inherit the launching shell's env, so
# the shim exports PATH into the generated body. That is one of the two
# properties the commit calls load-bearing, and it had no test -- a
# regression dropping the export would have shipped green. Resolve a binary
# that exists ONLY on the caller's PATH, by bare name.
b2f="$tmp/b2f"; mk_open_stub "$b2f" "$tmp/open2f.log"
pathdir="$tmp/pathonly"; mkdir -p "$pathdir"
envmarker="$tmp/env-resolved.txt"; rm -f "$envmarker"
cat > "$pathdir/konsole-macos-marker" <<MARKER
#!/usr/bin/env bash
echo resolved-via-PATH > "$envmarker"
MARKER
chmod +x "$pathdir/konsole-macos-marker"
PATH="$b2f:$pathdir:$PATH" ARM_APP_DIRS="$appdirs" \
    "$SCRIPT" --separate --workdir "$wd" -e konsole-macos-marker >/dev/null 2>&1
check "2f PATH reaches the launched command (bare name resolved)" "$(cat "$envmarker" 2>/dev/null)" "resolved-via-PATH"

# --- 3. BLOCKING: must not return before the command exits ------------------
b4="$tmp/b4"; mk_open_stub "$b4" "$tmp/open4.log"
start=$(date +%s)
run_shim "$b4" -- --separate --workdir "$wd" -e /bin/sh -c 'sleep 3' >/dev/null
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -ge 3 ] && echo "ok - 3a blocks for the life of the session (${elapsed}s >= 3s)" \
    || { echo "FAIL - 3a returned early (${elapsed}s < 3s): headed-arm would read this as a failed launch"; fails=$((fails+1)); }

# --- 4. rc propagation ------------------------------------------------------
b5="$tmp/b5"; mk_open_stub "$b5" "$tmp/open5.log"
run_shim "$b5" -- --separate --workdir "$wd" -e /bin/sh -c 'exit 7' >/dev/null; rc=$?
check "4a nonzero rc propagates" "$rc" "7"
run_shim "$b5" -- --separate --workdir "$wd" -e /bin/sh -c 'exit 0' >/dev/null; rc=$?
check "4b zero rc propagates" "$rc" "0"

# --- 5. app resolution (arm-resume.sh's contract) ---------------------------
b6="$tmp/b6"; mk_open_stub "$b6" "$tmp/open6.log"
out="$(PATH="$b6:$PATH" ARM_APP_DIRS="$appdirs" ARM_TERMINAL_APP="Terminal" \
    "$SCRIPT" --separate --workdir "$wd" -e true 2>&1)"
contains "5a ARM_TERMINAL_APP wins" "$(cat "$tmp/open6.log")" "-a Terminal"
not_contains "5a ARM_TERMINAL_APP: no WARN when the app exists" "$out" "WARN"
: > "$tmp/open6.log"
# codex-review I5: this rc MUST be captured off the shim itself. Reading $?
# after the `contains` calls below asserted nothing at all -- `contains`
# returns 0 on both branches (its failure branch ends in an assignment), so
# the case passed unconditionally.
out="$(PATH="$b6:$PATH" ARM_APP_DIRS="$appdirs" ARM_TERMINAL_APP="Ghostty" \
    "$SCRIPT" --separate --workdir "$wd" -e true 2>&1)"; rc=$?
contains "5b unknown app WARNs" "$out" "WARN konsole-macos: terminal app 'Ghostty' not found"
contains "5b unknown app falls back to Terminal, never refuses" "$(cat "$tmp/open6.log")" "-a Terminal"
check "5b fallback still launches (exit 0)" "$rc" "0"

# 5c. arm-resume.sh's ARM_TERMINAL_APP=none means "headless"; this launcher
# has no headless mode, so it must refuse rather than silently open a window.
: > "$tmp/open6.log"
out="$(PATH="$b6:$PATH" ARM_APP_DIRS="$appdirs" ARM_TERMINAL_APP="none" \
    "$SCRIPT" --separate --workdir "$wd" -e true 2>&1)"; rc=$?
check "5c ARM_TERMINAL_APP=none: exit 2" "$rc" "2"
contains "5c none: names the real reason" "$out" "no headless mode"
check "5c none: nothing was launched" "$(cat "$tmp/open6.log")" ""

# --- 6. launch failures are loud -------------------------------------------
b7="$tmp/b7"; mk_open_stub "$b7" "$tmp/open7.log" fail
out="$(run_shim "$b7" -- --separate --workdir "$wd" -e true)"; rc=$?
check "6a open failure: exit 3" "$rc" "3"
contains "6a open failure: says nothing was launched" "$out" "no session was launched"
b8="$tmp/b8"; mk_open_stub "$b8" "$tmp/open8.log" silent
out="$(PATH="$b8:$PATH" ARM_APP_DIRS="$appdirs" KONSOLE_MACOS_STARTUP_TICKS=3 \
    "$SCRIPT" --separate --workdir "$wd" -e true 2>&1)"; rc=$?
check "6b session never reports a pid: exit 4" "$rc" "4"
contains "6b no-pid: names the startup budget" "$out" "never reported a pid"

# HIMMEL-2534 CR fix (N346): a malformed KONSOLE_MACOS_STARTUP_TICKS must fail
# bounded, not spin `[ -ge ]` forever on a non-numeric comparison.
b9="$tmp/b9"; mk_open_stub "$b9" "$tmp/open9.log" silent
out="$(PATH="$b9:$PATH" ARM_APP_DIRS="$appdirs" KONSOLE_MACOS_STARTUP_TICKS=abc \
    "$SCRIPT" --separate --workdir "$wd" -e true 2>&1)"; rc=$?
check "6c malformed KONSOLE_MACOS_STARTUP_TICKS: exit 5, not a hang" "$rc" "5"
contains "6c malformed ticks: names the bad value" "$out" "KONSOLE_MACOS_STARTUP_TICKS must be a plain decimal integer, got 'abc'"
# N357 (codex-1): the refusal happens BEFORE `open -a`, so no session is left
# running untracked behind a shim that already exited 5.
check "6c malformed ticks: open was never invoked" "$(cat "$tmp/open9.log" 2>/dev/null)" ""

# N357 r2 (codex-1): a body the terminal opened before the shim's scratch dir
# was removed must not run its command once it cannot record its pid - the
# shim has already given up on it, so nothing would track that session.
b10="$tmp/b10"; mk_open_stub "$b10" "$tmp/open10.log" late
PATH="$b10:$PATH" ARM_APP_DIRS="$appdirs" KONSOLE_MACOS_STARTUP_TICKS=3 \
    "$SCRIPT" --separate --workdir "$wd" -e touch "$tmp/late-ran" >/dev/null 2>&1
sleep 1
check "6d unrecordable pid: the command never runs" "$([ -e "$tmp/late-ran" ] && echo ran)" ""

# HIMMEL-3484: the body that DID record its pid, but only after the shim
# reported failure (exit 4), must not run either: it waits for the shim's
# go/ack, and exits once the shim that would send it is gone.
b11="$tmp/b11"; mk_open_stub "$b11" "$tmp/open11.log" orphan
PATH="$b11:$PATH" ARM_APP_DIRS="$appdirs" KONSOLE_MACOS_STARTUP_TICKS=3 \
    "$SCRIPT" --separate --workdir "$wd" -e touch "$tmp/orphan-ran" >/dev/null 2>&1; rc=$?
check "6e orphaned body: the shim still reports exit 4" "$rc" "4"
sleep 2
check "6e orphaned body: the command never runs without the shim's ack" "$([ -e "$tmp/orphan-ran" ] && echo ran)" ""

# --- 7. HIMMEL-3484: the fan-out caps reach a Mac leg ------------------------
# `open -a` starts the body from a fresh environment, so the subagent caps an
# operator set in the launching shell were silently dropped - a Mac leg ran
# uncapped. They are forwarded explicitly, like PATH; nothing else is.
b12="$tmp/b12"; mk_open_stub "$b12" "$tmp/open12.log"
envdump="$tmp/env12.txt"; rm -f "$envdump"
CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=3 CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2 FLEET_CAP=7 KONSOLE_MACOS_UNRELATED=x \
    PATH="$b12:$PATH" ARM_APP_DIRS="$appdirs" \
    "$SCRIPT" --separate --workdir "$wd" -e /bin/sh -c "env > '$envdump'" >/dev/null 2>&1
envout="$(cat "$envdump" 2>/dev/null)"
contains "7a CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS reaches the session" "$envout" "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=3"
contains "7a CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH reaches the session" "$envout" "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2"
contains "7a FLEET_CAP reaches the session" "$envout" "FLEET_CAP=7"
not_contains "7b an unrelated launching-shell var still does not" "$envout" "KONSOLE_MACOS_UNRELATED"

# --- 8. HIMMEL-3484: not_contains must not read a grep EXECUTION error (rc 2)
# as "absent" - that would pass every negative assertion above vacuously.
# shellcheck disable=SC2317,SC2329  # grep() is invoked indirectly, through grepq
nc8=$( grep() { return 2; }; not_contains "8 probe" "x" "y" )
check "8 not_contains reports a grep error as a failure, not as absence" "$nc8" "FAIL - 8 probe: grep itself failed (rc 2)"

echo
[ "$fails" -eq 0 ] && { echo "All konsole-macos.sh cases passed."; exit 0; }
echo "$fails FAILED"; exit 1
