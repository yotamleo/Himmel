#!/usr/bin/env bash
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows; a
# test-fixture helper needs no .ps1 twin (WS5 T15 convention).
# Sourced by shell-test fixtures (HIMMEL-3179): canonicalise a fixture path so a
# path the test BUILT compares equal to the same path a tool REPORTED.
#
# The mismatch this closes is one directory spelled several ways:
#   macOS       mktemp -> /var/folders/../T/x   (TMPDIR ends in "/", so also "T//x")
#               git / node / `pwd -P` -> /private/var/folders/../T/x
#   Git Bash    mktemp -> /tmp/x   vs   pwd -P -> /c/<home>/AppData/Local/Temp/x
#               vs   git -> C:/<home>/../x   and RUNNER~1 (8.3) vs runneradmin
#
# Two functions, because the two kinds of partner spell the path differently:
#   canon_path <dir>          physical POSIX form (`cd && pwd -P`) - the partner is
#                             a script or a `pwd -P` of its own
#   canon_path_native <dir>   canon_path, then on a host with cygpath the
#                             long-name mixed form (D:/work/longname/..) - the
#                             partner is git, node or a Windows-native binary
#   canon_path_partial <path> canon_path_native of the deepest EXISTING ancestor,
#                             the not-yet-created tail appended verbatim
# All three print one path and return 1 (printing nothing) when <dir> does not
# exist. Callers own the `|| exit`: this file must stay safe to source under
# `set -u` / `set -e`, so it sets no shell options and defines no globals.
#
# ponytail: the Git Bash arm (cygpath -ml) cannot run on Linux/macOS - it is
# covered by a cygpath PATH stub in test-canon-path.sh, not by a real MSYS run;
# the extended-tier nightly is the real proof.

canon_path() {
    [ -n "${1-}" ] || return 1
    ( cd "$1" 2>/dev/null && pwd -P ) || return 1
}

canon_path_native() {
    local p
    p=$(canon_path "${1-}") || return 1
    if command -v cygpath >/dev/null 2>&1; then
        # -l expands 8.3 short names (RUNNER~1 -> runneradmin), which git reports
        # long while TEMP/TMPDIR carry them short.
        p=$(cygpath -ml "$p" 2>/dev/null || cygpath -m "$p" 2>/dev/null) || return 1
    fi
    printf '%s\n' "$p"
}

canon_path_partial() {
    local p="${1-}" rest="" head
    [ -n "$p" ] || return 1
    while [ ! -d "$p" ]; do
        case "$p" in */*) ;; *) return 1 ;; esac
        rest="/${p##*/}$rest"
        p="${p%/*}"
        [ -n "$p" ] || p=/
    done
    head=$(canon_path_native "$p") || return 1
    printf '%s%s\n' "${head%/}" "$rest"
}
