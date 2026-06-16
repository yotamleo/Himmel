# shellcheck shell=bash
# scripts/lib/py-armor.sh — hang armor for python3 calls (HIMMEL-249).
#
# Extracted from scripts/hooks/auto-arm-on-cap.sh's inline _py()
# (PR #266/#269), so every script on the resume-critical path shares
# one armor instead of each carrying (or forgetting) its own copy.
#
# WHY: on Windows, `python3` can resolve to the Microsoft Store
# WindowsApps stub, which intermittently WEDGES instead of running
# (observed live 2026-06-10). Two failure modes, each needing its own
# half of the armor:
#   1. The stub IGNORES SIGTERM — plain `timeout 10` waited on it
#      forever; only `timeout -k` (SIGKILL escalation) killed it
#      (rc=137 at 15s). So: GNU `timeout -k 5 10 python3 ...`. Only
#      GNU coreutils timeout can wrap a command — Windows System32
#      timeout.exe cannot — so the flavor is probed once per process.
#      Plain python3 where GNU timeout is unavailable (macOS default).
#      That degraded mode is SILENT on macOS (no Store stub there, so
#      unbounded python is the expected/safe default) but warns ONCE per
#      process on stderr under MINGW/MSYS/CYGWIN — on Windows a failed
#      probe usually means System32 timeout.exe shadows coreutils on
#      PATH, i.e. the armor is off exactly where the wedge class lives.
#      stderr only; no adopter stdout contract is touched.
#   2. The wedged stub can spawn an ORPHAN child that inherits stdout.
#      timeout kills the stub, but the orphan keeps the pipe open and
#      `$(python3 ...)` command substitution waits on EOF forever
#      (verified live — `timeout -k` alone was not enough). So: stdout
#      goes to a FILE, never a $() pipe. py_armor_capture owns that
#      convention for callers that need the output in a variable.
#
# API:
#   py_armor [args...]
#       Armored python3; the caller owns redirection. Use ONLY when
#       stdout does NOT feed a $() pipe (direct-to-terminal callers,
#       or callers that already redirect stdout to a file).
#   py_armor_capture [args...]
#       Armored python3 with stdout routed through a temp FILE into
#       the global $PY_ARMOR_OUT (newlines preserved; trailing newline
#       stripped, same as $()). Returns python's rc — 124/137 means
#       the timeout killed a wedged interpreter. stderr is left alone
#       so callers keep their own diagnostics. Safe inside $() — the
#       python stdout fd is the temp file, not the substitution pipe.
#   py_armor_mtime <path>
#       Portable file mtime: GNU stat -c / BSD stat -f / armored
#       python fallback. Prints epoch seconds, or "" when every probe
#       fails. Always returns 0 (callers test for empty output).
#
# Knobs (env / caller-set; all optional):
#   PY_ARMOR_BIN          interpreter (default python3). E.g.
#                         `PY_ARMOR_BIN=python py_armor_capture ...`
#                         for plain-python fallback branches — the
#                         WindowsApps stub ships python.exe too.
#   PY_ARMOR_TIMEOUT      seconds before SIGTERM (default 10)
#   PY_ARMOR_KILL_AFTER   seconds after SIGTERM before SIGKILL (default 5)
#
# NOTE: when a kill fires, the orphan may still hold the temp file
# open; on Windows the rm then fails silently and the file leaks into
# $TMPDIR. Harmless — a leaked temp file beats a wedged session.
#
# bash 3.2-compatible (no mapfile / associative arrays / namerefs).

_PY_ARMOR_HAVE_GNU_TIMEOUT=""

# rc 0 iff GNU coreutils timeout is available. Probed once per process.
_py_armor_have_gnu_timeout() {
    if [ -z "$_PY_ARMOR_HAVE_GNU_TIMEOUT" ]; then
        if timeout --version 2>/dev/null | grep -qi coreutils; then
            _PY_ARMOR_HAVE_GNU_TIMEOUT=yes
        else
            _PY_ARMOR_HAVE_GNU_TIMEOUT=no
            # Degrading to bare python3 is the exact hang class this lib
            # exists for — never do it silently where the wedge lives.
            # Warn once per process (the probe result is cached), stderr
            # only. Gated to Windows-ish unames: on macOS no-coreutils is
            # the expected default and the Store-stub wedge cannot occur.
            case "$(uname -s 2>/dev/null)" in
                MINGW*|MSYS*|CYGWIN*)
                    echo "WARN py-armor: GNU timeout unavailable — python calls are UNBOUNDED (System32 timeout.exe shadowing coreutils on PATH?)" >&2
                    ;;
            esac
        fi
    fi
    [ "$_PY_ARMOR_HAVE_GNU_TIMEOUT" = "yes" ]
}

py_armor() {
    if _py_armor_have_gnu_timeout; then
        timeout -k "${PY_ARMOR_KILL_AFTER:-5}" "${PY_ARMOR_TIMEOUT:-10}" \
            "${PY_ARMOR_BIN:-python3}" "$@"
    else
        "${PY_ARMOR_BIN:-python3}" "$@"
    fi
}

py_armor_capture() {
    PY_ARMOR_OUT=""
    local _out_file _rc=0
    if ! _out_file=$(mktemp -t py-armor.out.XXXXXX 2>/dev/null); then
        echo "WARN py-armor: mktemp failed — cannot create temp file for py_armor_capture output" >&2
        return 1
    fi
    # `|| _rc=$?` keeps this errexit-safe when the caller runs set -e:
    # the rc is captured, cleanup runs, and the function's own return
    # status carries the failure.
    py_armor "$@" >"$_out_file" || _rc=$?
    # Reading a regular file never blocks on an orphan writer (unlike a
    # $() pipe) — cat reads to current EOF and returns.
    PY_ARMOR_OUT=$(cat "$_out_file" 2>/dev/null) || PY_ARMOR_OUT=""
    rm -f "$_out_file" 2>/dev/null || true
    return "$_rc"
}

py_armor_mtime() {
    local _m=""
    _m=$(stat -c %Y "$1" 2>/dev/null) || _m=""               # GNU
    if [ -z "$_m" ]; then
        _m=$(stat -f %m "$1" 2>/dev/null) || _m=""           # BSD/macOS
    fi
    if [ -z "$_m" ]; then
        if py_armor_capture -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$1" 2>/dev/null; then
            _m="$PY_ARMOR_OUT"
        fi
    fi
    printf '%s\n' "$_m"
}
