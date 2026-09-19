#!/usr/bin/env bash
# test-arm-resume-at-pty.sh -- HIMMEL-2534: an `at`-launched claude leg has
# stdin=/dev/null and no tty, so it exits at the first idle cross-session
# message (five fleet legs lost 2026-09-05). The at body now runs claude under
# a pty with its stdin held open (scripts/lib/pty-run.sh).
#
# Everything here uses a STUB claude -- a real arm launches a real paid
# session. The at job body comes from `arm-resume.sh --dry-run` (the same
# $launch_lines the real `at` heredoc receives) and is executed with stdin
# redirected from /dev/null, exactly as atd runs it.
#
# RED control: on the pre-fix body the stub sees stdin=no-tty and an immediate
# EOF; the P1/P2 assertions below fail there and pass only with the pty.
#
# Usage: bash scripts/handover/test-arm-resume-at-pty.sh
# Exit:  0 = all pass, 1 = one or more failures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARM="$SCRIPT_DIR/arm-resume.sh"
LIB="$SCRIPT_DIR/../lib/pty-run.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/arm-resume-at-pty.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
. "$SCRIPT_DIR/../lib/fleet-slots-shield.sh"
fleet_slots_shield "$TMP" || exit 1
export ARM_RESUME_LOG_DIR="$TMP/arm-logs"
export SKILL_TELEMETRY_DIR="$TMP/telemetry"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
unset HIMMEL_HEADROOM_PROXY HEADROOM_BIN ARMAUTOMERGE 2>/dev/null || true
# Dotenv-read shield (HIMMEL-2254): an empty root, so a host .env carrying the
# ARMAUTOMERGE=1 default cannot turn P4/P5 into a statement about the host.
mkdir -p "$TMP/dotenv-empty"
export ARM_RESUME_DOTENV_ROOT="$TMP/dotenv-empty"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then echo "PASS $label"
    else echo "FAIL $label -- expected '$expected', got '$actual'"; FAILED=$((FAILED + 1)); fi
}
assert_contains() {
    case "$3" in *"$2"*) echo "PASS $1" ;; *) echo "FAIL $1 -- missing: $2"; FAILED=$((FAILED + 1)) ;; esac
}
assert_not_contains() {
    case "$3" in *"$2"*) echo "FAIL $1 -- unexpectedly contains: $2"; FAILED=$((FAILED + 1)) ;; *) echo "PASS $1" ;; esac
}

WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"
HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/statedocs"
future_time() { python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(minutes=30)).strftime("%H:%M"))'; }
make_handover() {
    local path="$HANDOVER_DIR/handover-$RANDOM.md"
    printf -- '---\nsession_kind: test\nresume_cwd: %s\n---\n# Test handover\n' "$WORK_REPO" > "$path"
    printf '%s' "$path"
}

# Scheduler stubs: `at`/`atq` present so schedule_arm takes the at branch.
SCHED_STUB="$TMP/sched-stub"
mkdir -p "$SCHED_STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCHED_STUB/atq"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCHED_STUB/at"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SCHED_STUB/powershell"
chmod +x "$SCHED_STUB/atq" "$SCHED_STUB/at" "$SCHED_STUB/powershell"
export FLEET_PS_CMD="$SCHED_STUB/atq"

# Stub claude: report what it is running under, then idle 2s on stdin. A leg
# that sees EOF here is the HIMMEL-2534 death; a leg that times out is alive.
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<'EOF'
#!/usr/bin/env bash
{
    if [ -t 0 ]; then echo tty0=yes; else echo tty0=no; fi
    echo "size=$(stty size 2>/dev/null || echo none)"
    echo "armauto=${ARMAUTOMERGE-unset}"
    echo "argc=$#"
    for a in "$@"; do printf 'arg=%s\n' "$a"; done
    IFS= read -r -t 2 _line; rc=$?
    if [ "$rc" -gt 128 ]; then echo stdin=idle; else echo stdin=eof; fi
} > "$CLAUDE_REC"
exit 3
EOF
chmod +x "$STUB_BIN/claude"

# Extract the at job body from a dry-run and run it the way atd does.
at_body() {
    env PATH="$SCHED_STUB:$PATH" OSTYPE=linux-gnu bash "$ARM" --time "$(future_time)" \
        --handover "$(make_handover)" --dry-run "$@" 2>&1 \
      | awk '/^DRY arm-resume: would at -t/{on=1; next} /^    CMD$/{on=0} on{sub(/^    /,""); print}'
}
run_body() {  # $1 = shell binary, $2 = body, $3 = rec file
    env PATH="$STUB_BIN:$PATH" CLAUDE_REC="$3" "$1" -c "$2" </dev/null >"$TMP/job.out" 2>&1
}

HAVE_SCRIPT=0; command -v script >/dev/null 2>&1 && HAVE_SCRIPT=1

BODY=$(at_body)
assert_contains "P0 dry-run yields an at body" "cd " "$BODY"
assert_contains "P0 body still launches claude with the leg argv" "--autocompact" "$BODY"

if [ "$HAVE_SCRIPT" -eq 1 ]; then
    REC="$TMP/rec1"; run_body sh "$BODY" "$REC"; rc=$?
    R=$(cat "$REC" 2>/dev/null)
    assert_contains "P1 claude sees a tty on stdin under an at-shaped job" "tty0=yes" "$R"
    assert_contains "P2 claude idles instead of reading EOF (survives an idle message)" "stdin=idle" "$R"
    assert_eq "P3 claude's exit code is the job's exit code" "3" "$rc"
    assert_not_contains "P3b pty size is not 0x0" "size=0 0" "$R"
    assert_contains "P4 the leg argv (-n <name> ...) reaches claude" "arg=-n" "$R"
    assert_contains "P4 no ARMAUTOMERGE leaks into a default arm" "armauto=unset" "$R"

    BODY_AM=$(at_body --automerge)
    REC="$TMP/rec2"; run_body sh "$BODY_AM" "$REC"
    assert_contains "P5 env-prefix grant reaches claude through the pty function" "armauto=1" "$(cat "$REC" 2>/dev/null)"

    if command -v dash >/dev/null 2>&1; then
        REC="$TMP/rec3"; run_body dash "$BODY" "$REC"
        assert_contains "P6 the body is POSIX-sh clean: dash also gets a live pty" "stdin=idle" "$(cat "$REC" 2>/dev/null)"
    fi
else
    echo "SKIP P1-P6: script(1) not on PATH"
fi

# ---- the lib itself: quoting + fallback ------------------------------------
if [ -r "$LIB" ]; then
    # shellcheck disable=SC1090
    . "$LIB"
    ARGS_REC="$TMP/args-rec"
    # shellcheck disable=SC2016  # the stub's own $@/$a must stay literal here
    printf '#!/usr/bin/env bash\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done > "$CLAUDE_REC"\nexit 0\n' > "$STUB_BIN/claude"
    export CLAUDE_REC="$ARGS_REC" PATH="$STUB_BIN:$PATH"
    if [ "$HAVE_SCRIPT" -eq 1 ]; then
        EVIL="\$(touch $TMP/pwned)"
        _himmel_pty_run claude "it's" 'a "b"' "$EVIL" '' 'x y  z' </dev/null
        GOT=$(cat "$ARGS_REC")
        WANT=$(printf '[%s]\n' "it's" 'a "b"' "$EVIL" '' 'x y  z')
        assert_eq "Q1 hostile/empty/spaced args survive the pty hop verbatim" "$WANT" "$GOT"
        if [ -e "$TMP/pwned" ]; then
            echo "FAIL Q2 an arg was executed"; FAILED=$((FAILED + 1))
        else
            echo "PASS Q2 no arg was executed"
        fi
    fi
    if [ "$HAVE_SCRIPT" -eq 1 ]; then
        # The fifo is the session's stdin: create it owner-only, whatever the umask.
        MKF_STUB="$TMP/mkfifo-stub"; mkdir -p "$MKF_STUB"
        export REAL_MKFIFO STUB_LOG="$TMP/mkfifo"
        REAL_MKFIFO=$(command -v mkfifo)
        cat > "$MKF_STUB/mkfifo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG.args"
for _a in "$@"; do _last=$_a; done
ls -ld "$(dirname "$_last")" | cut -c1-10 >> "$STUB_LOG.dirmode"
exec "$REAL_MKFIFO" "$@"
EOF
        chmod +x "$MKF_STUB/mkfifo"
        (umask 000; TMPDIR="$TMP" PATH="$MKF_STUB:$PATH" _himmel_pty_run claude one </dev/null)
        assert_contains "Q4 the pty fifo is created mode 600 regardless of umask" "-m 600" "$(cat "$TMP/mkfifo.args" 2>/dev/null)"
        assert_eq "Q5 the fifo sits in a private 0700 directory, not bare in a shared TMPDIR" "drwx------" "$(cat "$TMP/mkfifo.dirmode" 2>/dev/null)"
        assert_eq "Q5b no private fifo dir is left behind" "0" "$(find "$TMP" -maxdepth 1 -name 'himmel-pty.*' | wc -l | tr -d ' ')"

        # BSD/macOS dialect (no util-linux in --version): a stub `script` that
        # takes `-q[e] FILE cmd...`, exits with the child's status only under -e.
        BSD_DIR="$TMP/bsd-script"; mkdir -p "$BSD_DIR"
        cat > "$BSD_DIR/script" <<'EOF'
#!/bin/sh
case $1 in --version) echo "script: illegal option -- -" >&2; exit 1 ;; esac
flags=$1; shift
case $flags in *e*) [ -n "${BSD_NO_E-}" ] && { echo "script: illegal option -- e" >&2; exit 1; } ;; esac
shift
echo "flags=$flags" >> "$BSD_LOG"
"$@"; rc=$?
case $flags in *e*) exit "$rc" ;; *) exit 0 ;; esac
EOF
        chmod +x "$BSD_DIR/script"
        export BSD_LOG="$TMP/bsd.log"; : > "$BSD_LOG"
        printf '#!/bin/sh\nexit 7\n' > "$BSD_DIR/claude"; chmod +x "$BSD_DIR/claude"
        PATH="$BSD_DIR:$PATH" HIMMEL_PTY_SCRIPT_CMD="$BSD_DIR/script" _himmel_pty_run claude one </dev/null; rc=$?
        assert_eq "Q6 BSD dialect passes the child's exit status through (-e)" "7" "$rc"
        assert_contains "Q6 BSD dialect was invoked with -qe" "flags=-qe" "$(cat "$BSD_LOG")"
        : > "$BSD_LOG"
        PATH="$BSD_DIR:$PATH" BSD_NO_E=1 HIMMEL_PTY_SCRIPT_CMD="$BSD_DIR/script" _himmel_pty_run claude one </dev/null; rc=$?
        assert_eq "Q7 BSD script without -e still launches (falls back to -q)" "0" "$rc"
        assert_contains "Q7 fallback invocation is plain -q" "flags=-q" "$(cat "$BSD_LOG")"
    fi
    : > "$ARGS_REC"
    HIMMEL_PTY_SCRIPT_CMD="$TMP/no-such-script" _himmel_pty_run claude one 'two words' </dev/null 2>"$TMP/fb.err"; rc=$?
    assert_eq "Q3 no script(1): claude still launches bare, rc passes through" "0" "$rc"
    assert_eq "Q3 no script(1): argv intact" "$(printf '[one]\n[two words]')" "$(cat "$ARGS_REC")"
    assert_contains "Q3 no script(1): says the leg is un-messageable" "WITHOUT a pty" "$(cat "$TMP/fb.err")"
else
    echo "FAIL Q0 scripts/lib/pty-run.sh missing"; FAILED=$((FAILED + 1))
fi

echo "---"
if [ "$FAILED" -gt 0 ]; then echo "FAILED: $FAILED case(s)"; exit 1; fi
echo "PASS all cases"
exit 0
