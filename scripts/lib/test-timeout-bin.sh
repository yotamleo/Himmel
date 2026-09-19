#!/usr/bin/env bash
# scripts/lib/test-timeout-bin.sh — tests for scripts/lib/timeout-bin.sh
# (HIMMEL-2589). Hermetic: every PATH is a stub dir; nothing touches the host's
# real timeout except T1, which needs a GNU one to prove the bound still bites.
#
#   T1  GNU timeout present -> resolved, and a sleeping child IS killed (rc 124)
#   T2  neither timeout nor gtimeout -> empty + ONE stderr note; the
#       `${_TIMEOUT_BIN:+...}` idiom then runs the child unbounded
#   T3  only gtimeout (the macOS+brew shape) -> gtimeout is resolved
#   T4  a non-GNU `timeout` (Windows timeout.exe shape: --version fails) is
#       rejected, and does not shadow a working gtimeout behind it
#   T5  sourcing under `set -u` with an empty PATH does not error
#   T6  a relative PATH dir is stored ABSOLUTE (survives a cd); a shell function
#       named timeout (command -v prints a bare name) is rejected

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBF="$SCRIPT_DIR/timeout-bin.sh"
BASH_BIN="$(command -v bash)"   # absolute: the stub PATHs below hold no bash

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2] want [$3])"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-timeout-bin.XXXXXX")" || exit 1; trap 'rm -rf "$W"' EXIT

# stub_dir <name> [tool ...] — a dir holding symlinks to just <tool>s (found on
# the REAL path, resolved before PATH is replaced).
stub_dir() {
    local d="$W/$1" t p; shift
    mkdir -p "$d"
    for t in "$@"; do
        p="$(command -v "$t")" && ln -sf "$p" "$d/$t"
    done
    printf '%s' "$d"
}
# fake_gnu <dir> <name> — a stub that claims GNU coreutils on --version and
# otherwise runs its command (dropping the leading duration).
fake_gnu() {
    cat > "$1/$2" <<'EOF'
#!/bin/sh
case "$1" in --version) echo "timeout (GNU coreutils) 9.5"; exit 0 ;; esac
shift
exec "$@"
EOF
    chmod +x "$1/$2"
}

# resolve <PATH> — print "<_TIMEOUT_BIN>|<stderr>" from a fresh shell on that PATH.
resolve() {
    local p="$1" err
    err="$W/err.$$"
    # shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
    PATH="$p" "$BASH_BIN" -c '. "$1"; printf "%s" "$_TIMEOUT_BIN"' _ "$LIBF" 2>"$err"
    printf '|%s' "$(cat "$err")"
}

echo "[test-timeout-bin] T1 GNU timeout present: resolved AND still bounds a sleeper"
if timeout --version >/dev/null 2>&1; then
    real="$(dirname "$(command -v timeout)")"
    d1="$(stub_dir t1 sleep)"
    got="$(resolve "$d1:$real")"
    case "${got%%|*}" in */timeout) ok "T1 resolved a timeout path (${got%%|*})" ;; *) bad "T1 resolved [$got]" ;; esac
    eq "T1 no stderr note when resolved" "${got#*|}" ""
    rc=0
    # shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
    PATH="$d1:$real" "$BASH_BIN" -c '. "$1"; ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 1} sleep 30' _ "$LIBF" 2>/dev/null || rc=$?
    eq "T1 sleeping child killed by the bound (rc 124)" "$rc" "124"
else
    echo "  SKIP T1: no GNU timeout on this host (nothing to prove the bound with)"
fi

echo "[test-timeout-bin] T2 no timeout/gtimeout: empty, one note, idiom runs unbounded"
d2="$(stub_dir t2 sleep)"
got="$(resolve "$d2")"
eq "T2 _TIMEOUT_BIN empty" "${got%%|*}" ""
case "${got#*|}" in *"no GNU 'timeout'/'gtimeout'"*) ok "T2 stderr note names the miss" ;; *) bad "T2 note missing: [${got#*|}]" ;; esac
eq "T2 exactly one note line" "$(printf '%s\n' "${got#*|}" | grep -c .)" "1"
rc=0
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
PATH="$d2" "$BASH_BIN" -c '. "$1"; ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 1} sleep 0' _ "$LIBF" 2>/dev/null || rc=$?
eq "T2 idiom ran the child unbounded (rc 0, not 127)" "$rc" "0"

echo "[test-timeout-bin] T3 only gtimeout (macOS + brew coreutils)"
d3="$(stub_dir t3)"; fake_gnu "$d3" gtimeout
got="$(resolve "$d3")"
eq "T3 resolved gtimeout" "${got%%|*}" "$d3/gtimeout"

echo "[test-timeout-bin] T4 a non-GNU timeout is rejected, gtimeout behind it wins"
d4="$(stub_dir t4)"; fake_gnu "$d4" gtimeout
printf '#!/bin/sh\nexit 1\n' > "$d4/timeout"; chmod +x "$d4/timeout"
got="$(resolve "$d4")"
eq "T4 resolved gtimeout, not the fake timeout.exe" "${got%%|*}" "$d4/gtimeout"
d4b="$(stub_dir t4b)"; printf '#!/bin/sh\nexit 1\n' > "$d4b/timeout"; chmod +x "$d4b/timeout"
got="$(resolve "$d4b")"
eq "T4 a lone non-GNU timeout resolves to nothing" "${got%%|*}" ""

echo "[test-timeout-bin] T5 sourcing under set -u with an empty PATH"
rc=0
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
out="$(PATH="$W/nonexistent" "$BASH_BIN" -c 'set -u; . "$1"; printf "[%s]" "$_TIMEOUT_BIN"' _ "$LIBF" 2>/dev/null)" || rc=$?
eq "T5 rc 0" "$rc" "0"
eq "T5 empty" "$out" "[]"

echo "[test-timeout-bin] T6 relative PATH dir: stored ABSOLUTE, survives a cd; a shell function is not a binary"
d6="$W/t6"; mkdir -p "$d6/bin"; fake_gnu "$d6/bin" timeout
d6t="$(stub_dir t6tools cat)"; mkdir -p "$d6/elsewhere"
rc=0
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
out="$(cd "$d6" && PATH="bin:$d6t" "$BASH_BIN" -c '. "$1"; printf "%s" "$_TIMEOUT_BIN"; cd "$2"; "$_TIMEOUT_BIN" 5 cat /dev/null' _ "$LIBF" "$d6/elsewhere" 2>/dev/null)" || rc=$?
case "$out" in /*/t6/bin/timeout) ok "T6 relative PATH result stored as an absolute path ($out)" ;; *) bad "T6 stored [$out]" ;; esac
eq "T6 the stored path still runs after a cd (rc 0, not 127)" "$rc" "0"
# shellcheck disable=SC2016 # single quotes intentional: the child shell expands $1/$_TIMEOUT_BIN
out="$(PATH="$d2" "$BASH_BIN" -c 'timeout() { [ "$1" = "--version" ]; }; . "$1"; printf "[%s]" "$_TIMEOUT_BIN"' _ "$LIBF" 2>/dev/null)"
eq "T6 a shell function named timeout is rejected" "$out" "[]"

echo "[test-timeout-bin] $pass passed, $fail failed"
[ "$fail" -eq 0 ]
