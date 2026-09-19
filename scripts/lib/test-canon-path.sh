#!/usr/bin/env bash
# Tests for scripts/lib/canon-path.sh (HIMMEL-3179).
# Usage: bash scripts/lib/test-canon-path.sh
# Hermetic: a symlinked directory stands in for macOS /var -> /private/var, and
# a PATH-stub `cygpath` stands in for Git Bash. Neither platform is run here.
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows; a test
# fixture needs no .ps1 twin (WS5 T15 convention).
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=canon-path.sh
# shellcheck disable=SC1091
. "$LIB_DIR/canon-path.sh"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/canon-path.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Physical root first: the assertions compare against it.
REAL=$(cd "$TMP" && pwd -P)
mkdir -p "$REAL/real/sub" "$REAL/real/with space"
ln -s "$REAL/real" "$REAL/link"

# Precondition: the raw spelling really differs from the physical one, or the
# cases below could pass on an identity function.
RAW_SPELLING="$REAL/link/sub"; PHYS_SPELLING="$REAL/real/sub"
assert_eq "precondition: the symlink spelling is not the physical path" "differs" \
    "$([ "$RAW_SPELLING" != "$PHYS_SPELLING" ] && echo differs || echo same)"

# T1: a symlinked prefix resolves to the physical path.
assert_eq "T1 symlinked prefix -> physical" "$REAL/real/sub" "$(canon_path "$REAL/link/sub")"

# T2: a doubled slash (macOS TMPDIR ends in "/") normalises.
assert_eq "T2 doubled slash -> single" "$REAL/real/sub" "$(canon_path "$REAL/link//sub")"

# T3: a space in the path survives.
assert_eq "T3 space in path" "$REAL/real/with space" "$(canon_path "$REAL/link/with space")"

# T4: a missing directory and an empty argument both fail and print nothing.
out=$(canon_path "$REAL/nope"); rc=$?
assert_eq "T4a missing dir -> rc=1, no output" "1|" "$rc|$out"
out=$(canon_path ""); rc=$?
assert_eq "T4b empty arg -> rc=1, no output" "1|" "$rc|$out"

# T5: with no cygpath on PATH, native == physical.
NOCYG="$TMP/nocyg"; mkdir -p "$NOCYG"
for t in bash dirname cat; do ln -s "$(command -v "$t")" "$NOCYG/$t"; done
got=$(PATH="$NOCYG" "$NOCYG/bash" -c ". '$LIB_DIR/canon-path.sh'; command -v cygpath >/dev/null 2>&1 && echo HAS-CYGPATH || canon_path_native '$REAL/link/sub'")
assert_eq "T5 no cygpath -> native is the physical path" "$REAL/real/sub" "$got"

# T6: with a cygpath stub, native goes through `cygpath -ml` (long name).
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/cygpath" <<'EOF'
#!/usr/bin/env bash
# Git-Bash-shaped: -ml maps /x/y -> D:/work/longname/x/y, plain -m keeps 8.3.
case "$1" in
    -ml) printf 'D:/work/longname%s\n' "$2" ;;
    -m)  printf 'D:/work/SHORT~1%s\n' "$2" ;;
    *)   exit 2 ;;
esac
EOF
chmod +x "$STUB/cygpath"
assert_eq "T6 cygpath -ml is used" "D:/work/longname$REAL/real/sub" \
    "$(PATH="$STUB:$PATH" canon_path_native "$REAL/link/sub")"

# T7: a cygpath that rejects -l falls back to plain -m rather than failing.
cat > "$STUB/cygpath" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-m" ] || exit 2
printf 'D:/work/SHORT~1%s\n' "$2"
EOF
assert_eq "T7 cygpath without -l falls back to -m" "D:/work/SHORT~1$REAL/real/sub" \
    "$(PATH="$STUB:$PATH" canon_path_native "$REAL/link/sub")"

# T8: partial keeps a not-yet-created tail, resolving only the existing head.
assert_eq "T8 partial: existing head canonicalised, missing tail kept" \
    "$REAL/real/sub/cr-pending/t7-wt" "$(canon_path_partial "$REAL/link/sub/cr-pending/t7-wt")"
assert_eq "T8b partial on an existing path == native" "$REAL/real/sub" "$(canon_path_partial "$REAL/link/sub")"

# T9: a newline inside a path component round-trips (the main-ref-transaction case).
NL="$REAL/real"/$'weird\nname'
mkdir -p "$NL"
[ "$(canon_path "$REAL/link"/$'weird\nname')" = "$NL" ] && got=ok || got=mangled
assert_eq "T9 newline in a path component survives" "ok" "$got"

# T10: a relative path with no existing ancestor fails instead of looping.
out=$(canon_path_partial "no-such-relative/dir"); rc=$?
assert_eq "T10 partial with no existing ancestor -> rc=1" "1|" "$rc|$out"

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
