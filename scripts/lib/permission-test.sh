#!/usr/bin/env bash
# permission-test.sh — effective directory-write control for shell suites
# (HIMMEL-2893). Source after creating the fixture and removing write bits.
# Platform guard (gitbash-only): POSIX shell-test helper; no .ps1 twin.

# test_dir_unwritable <directory> <case label>
# A successful probe means chmod did not build the intended fixture (root or
# ACL passthrough). The caller must restore permissions even when skipping.
test_dir_unwritable() {
    local probe
    if probe="$(mktemp "$1/.write-probe.XXXXXX" 2>/dev/null)"; then
        rm -f "$probe"
        printf 'SKIP - %s: chmod did not deny directory writes (root or filesystem permissions)\n' "$2"
        return 1
    fi
    return 0
}
