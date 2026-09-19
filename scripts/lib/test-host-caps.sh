#!/usr/bin/env bash
# Tests for scripts/lib/host-caps.sh (HIMMEL-3182).
# Usage: bash scripts/lib/test-host-caps.sh
# Hermetic: PATH stubs stand in for the hosts that cannot express the case -- a
# no-op `chmod` for NTFS, a copying `ln` for MSYS, a `stat` that only speaks the
# BSD dialect for macOS. None of those platforms is run here; the real-host
# expectation below is keyed on `id -u` ONLY to know what THIS host must report.
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows; a test
# fixture needs no .ps1 twin (WS5 T15 convention).
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=host-caps.sh
# shellcheck disable=SC1091
. "$LIB_DIR/host-caps.sh"

FAILED=0
assert_rc() {
    local label="$1" expected="$2"; shift 2
    "$@"; local rc=$?
    if [ "$rc" -eq "$expected" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$rc"
        FAILED=$((FAILED + 1))
    fi
}
assert_eq() {
    if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 — expected '$2', got '$3'"; FAILED=$((FAILED + 1)); fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/host-caps-test.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
REAL_PATH="$PATH"
# Every probe puts its scratch dir under TMPDIR; point that at a suite-private
# parent so T18 counts only THIS suite's leftovers, never a concurrent run's.
SCRATCH="$TMP/scratch"; mkdir -p "$SCRATCH"; export TMPDIR="$SCRATCH"

# --- the real host -----------------------------------------------------------
# A POSIX host that is not root can do all of it; uid 0 ignores read/write bits.
# Git Bash on NTFS cannot (that is what the probes exist to report), so asserting
# "capable" there would fail the suite for the very reason the library exists;
# the simulated hosts below still run everywhere. The real-host expectation is
# keyed on uname/id -u ONLY to know what THIS host must report -- measuring it
# with the probe under test would be circular.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) POSIX_HOST=0 ;;
    *) POSIX_HOST=1 ;;
esac
f="$TMP/f"; : > "$f"; chmod 640 "$f"
if [ "$POSIX_HOST" -eq 1 ]; then
    assert_rc "T1 modes stick on a POSIX host" 0 host_modes_stick
    assert_rc "T2 symlinks are real on a POSIX host" 0 host_symlinks_real
    if [ "$(id -u)" -eq 0 ]; then
        want_deny=1
    else
        want_deny=0
    fi
    assert_rc "T3 read denial matches the uid" "$want_deny" host_can_deny_read
    assert_rc "T4 write denial matches the uid" "$want_deny" host_can_deny_write
    assert_eq "T5 host_mode_of reads the octal mode" "640" "$(host_mode_of "$f")"
else
    host_skip "T1-T5 real-host POSIX capability assertions: this host is not POSIX (NTFS mode/symlink semantics)"
fi
assert_rc "T6 host_mode_of on a missing path fails" 1 host_mode_of "$TMP/absent"
assert_rc "T7 host_mode_of with no argument fails" 1 host_mode_of

assert_eq "T8 host_skip prints the one stdout SKIP line" \
    "SKIP no flock here (HIMMEL-3182)" "$(host_skip no flock here)"

# --- NTFS/MSYS: chmod is a no-op, ln -s copies -------------------------------
# A control that cannot fail is not evidence: every stub below is proven to be
# the one the probe reaches (T9 stat-only, T10 the stub really is first on PATH).
STUBS="$TMP/stubs-ntfs"; mkdir -p "$STUBS"
printf '#!/bin/sh\nexit 0\n' > "$STUBS/chmod"
# shellcheck disable=SC2016 # the stub's own $1/$2 must stay literal
printf '#!/bin/sh\n# MSYS without the symlink privilege: ln -s copies its source\nshift\nexec cp -R "$1" "$2"\n' > "$STUBS/ln"
chmod +x "$STUBS/chmod" "$STUBS/ln"
assert_eq "T9 the chmod stub is the one PATH resolves" "$STUBS/chmod" "$(PATH="$STUBS:$REAL_PATH" command -v chmod)"

PATH="$STUBS:$REAL_PATH"
assert_rc "T10 no-op chmod: modes do NOT stick" 1 host_modes_stick
assert_rc "T11 no-op chmod: read is NOT deniable" 1 host_can_deny_read
assert_rc "T12 no-op chmod: write is NOT deniable" 1 host_can_deny_write
assert_rc "T13 copying ln: symlinks are NOT real" 1 host_symlinks_real
PATH="$REAL_PATH"

# --- NTFS again: chmod is fine but `mkdir -m` on an EXISTING dir is refused ----
# The exact "mkdir: cannot change permissions ... Permission denied" of the nightly.
MK="$TMP/stubs-mkdir"; mkdir -p "$MK"
cat > "$MK/mkdir" <<'STUB'
#!/bin/sh
# re-securing an existing dir with -m fails; everything else is the real mkdir
for last; do :; done
case " $* " in *" -m "*) [ -d "$last" ] && { echo "mkdir: cannot change permissions of '$last': Permission denied" >&2; exit 1; } ;; esac
exec "$REAL_MKDIR" "$@"
STUB
chmod +x "$MK/mkdir"
REAL_MKDIR=$(command -v mkdir); export REAL_MKDIR
PATH="$MK:$REAL_PATH"
assert_rc "T19 mkdir -m refused on an existing dir: modes do NOT stick" 1 host_modes_stick
assert_rc "T20 the same stub still lets plain mkdir + a real chmod work" 0 mkdir -p "$TMP/plain/x"
PATH="$REAL_PATH"

# --- NTFS: a directory name cannot hold a newline -----------------------------
if [ "$POSIX_HOST" -eq 1 ]; then
    assert_rc "T21 a POSIX host can name a dir with a newline" 0 host_newline_paths
else
    host_skip "T21 real-host newline-name assertion: this host is not POSIX (NTFS cannot hold a newline in a name)"
fi
NL="$TMP/stubs-nl"; mkdir -p "$NL"
cat > "$NL/mkdir" <<'STUB'
#!/bin/sh
for a; do case "$a" in *'
'*) echo "mkdir: cannot create directory: Invalid argument" >&2; exit 1 ;; esac; done
exec "$REAL_MKDIR" "$@"
STUB
chmod +x "$NL/mkdir"
PATH="$NL:$REAL_PATH"
assert_rc "T22 newline-refusing mkdir: newline paths are NOT nameable" 1 host_newline_paths
assert_rc "T23 the same stub still lets an ordinary mkdir work" 0 mkdir -p "$TMP/plain2/x"
PATH="$REAL_PATH"

# --- macOS: BSD stat only ----------------------------------------------------
# GNU `stat -c` is rejected; `stat -f %Lp` answers. The probe must fall back.
BSD="$TMP/stubs-bsd"; mkdir -p "$BSD"
cat > "$BSD/stat" <<'STUB'
#!/bin/sh
[ "$1" = "-f" ] || { echo "stat: illegal option -- $1" >&2; exit 1; }
"$REAL_STAT" -c '%a' "$3" 2>/dev/null || exec "$REAL_STAT" -f '%Lp' "$3"
STUB
chmod +x "$BSD/stat"
REAL_STAT=$(command -v stat); export REAL_STAT
want_mode=$(host_mode_of "$f")
PATH="$BSD:$REAL_PATH"
assert_eq "T14 BSD stat: host_mode_of falls back to -f %Lp" "$want_mode" "$(host_mode_of "$f")"
if [ "$POSIX_HOST" -eq 1 ]; then
    assert_rc "T15 BSD stat: modes still stick" 0 host_modes_stick
else
    host_skip "T15 BSD-stat modes-stick assertion: this host is not POSIX (chmod does not stick on NTFS)"
fi
PATH="$REAL_PATH"

# --- scratch is always cleaned ----------------------------------------------
# An unwritable TMPDIR must read as "not capable", never crash the sourcing suite.
assert_rc "T16 no scratch dir: modes_stick reports incapable" 1 env TMPDIR="$TMP/no/such/dir" bash -c ". '$LIB_DIR/host-caps.sh'; host_modes_stick"
assert_rc "T17 no scratch dir: symlinks_real reports incapable" 1 env TMPDIR="$TMP/no/such/dir" bash -c ". '$LIB_DIR/host-caps.sh'; host_symlinks_real"
leftover=0
for p in "$SCRATCH"/*; do [ -e "$p" ] && leftover=$((leftover + 1)); done
assert_eq "T18 probes leave no scratch dir behind" "0" "$leftover"

if [ "$FAILED" -ne 0 ]; then echo "SOME FAILED ($FAILED)"; exit 1; fi
echo "ALL PASSED"
