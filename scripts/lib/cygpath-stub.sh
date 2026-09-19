#!/usr/bin/env bash
# cygpath-stub.sh — a deterministic fake `cygpath`, so the schtasks/Windows
# branch of the cadence scripts (cmd_arm, which refuses to run without cygpath)
# is EXECUTABLE on a POSIX host. HIMMEL-3114.
#
# Sourced by scripts/luna/test-{graphmap,pipeline,qmd}-cadence.sh. Never sourced
# on a host that already has a real cygpath (Git-Bash / MSYS / Cygwin): those
# suites run against the real one there.
#
# WHAT THIS IS NOT: a Windows validation. The stub proves what cmd_arm does with
# the STRINGS cygpath returns; it says nothing about what real schtasks.exe,
# wscript.exe or cmd.exe do with them. Anything asserted through the stub is
# "the branch logic runs on Linux", never "this works on Windows".
#
# Mapping (a fixed fake drive + root, so an emitted path is checkable against a
# known form, and provably NOT the input POSIX path):
#   cygpath -m /a/b   ->  C:/cygstub/a/b     (mixed form)
#   cygpath -w /a/b   ->  C:\cygstub\a\b     (Windows form)
#   cygpath -u <either of the two above>  ->  /a/b   (round-trips)
#   cygpath -u C:/x/y ->  /c/x/y             (any other drive path, MSYS-style)
#   cygpath -u /a/b   ->  /a/b               (POSIX passes through, like the real one)
# Like the real tool it needs no existing path and preserves a trailing slash.
# A relative or empty path, an unknown flag, or a missing operand exits nonzero
# (the real cygpath -m would resolve a relative path against the cwd; no cadence
# call site passes one, so a nonzero here flags a NEW one instead of guessing).

CYGPATH_STUB_PREFIX='C:/cygstub'

# cygpath_stub_install <dir> — write <dir>/cygpath (mode 755). The shebang is
# the absolute /bin/sh with a POSIX body, so the stub can never resolve a
# suite's fake `bash` stub through a prepended PATH and recurse into it.
cygpath_stub_install() {
    local dir="$1"
    mkdir -p "$dir"
    {
        printf '#!/bin/sh\n'
        printf "PREFIX='%s'\n" "$CYGPATH_STUB_PREFIX"
        cat <<'STUB'
mode=""
while [ $# -gt 0 ]; do
    case "$1" in
        -w|-m|-u) mode="$1"; shift ;;
        --) shift; break ;;
        -*) echo "cygpath-stub: unsupported flag: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
if [ -z "$mode" ] || [ $# -ne 1 ]; then
    echo "cygpath-stub: usage: cygpath (-w|-m|-u) PATH" >&2
    exit 2
fi
p="$1"
case "$mode" in
    -m)
        case "$p" in
            [A-Za-z]:*) printf '%s\n' "$p" | tr '\\' '/' ;;
            /*)         printf '%s%s\n' "$PREFIX" "$p" ;;
            *)          echo "cygpath-stub: not an absolute path: $p" >&2; exit 1 ;;
        esac
        ;;
    -w)
        case "$p" in
            [A-Za-z]:*) printf '%s\n' "$p" | tr '/' '\\' ;;
            /*)         printf '%s%s\n' "$PREFIX" "$p" | tr '/' '\\' ;;
            *)          echo "cygpath-stub: not an absolute path: $p" >&2; exit 1 ;;
        esac
        ;;
    -u)
        q=$(printf '%s' "$p" | tr '\\' '/')
        case "$q" in
            "$PREFIX")   printf '/\n' ;;
            "$PREFIX"/*) printf '%s\n' "${q#"$PREFIX"}" ;;
            [A-Za-z]:*)
                drive=$(printf '%s' "$q" | cut -c1 | tr 'A-Z' 'a-z')
                printf '/%s%s\n' "$drive" "$(printf '%s' "$q" | cut -c3-)"
                ;;
            /*)          printf '%s\n' "$p" ;;
            *)           echo "cygpath-stub: not an absolute path: $p" >&2; exit 1 ;;
        esac
        ;;
esac
STUB
    } > "$dir/cygpath"
    chmod +x "$dir/cygpath"
}
