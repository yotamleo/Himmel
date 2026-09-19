#!/usr/bin/env bash
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows; a
# test-fixture helper needs no .ps1 twin (WS5 T15 convention).
# Sourced by shell-test fixtures (HIMMEL-3182): capability probes for what a
# fixture is about to ASSERT, so a host that cannot express the case SKIPs it
# loudly instead of failing it (or, worse, passing it vacuously).
#
# The hosts that cannot:
#   Git Bash / NTFS   chmod is a no-op on the ACL (`chmod 600` reads back 644,
#                     `chmod 000` leaves a file readable, `mkdir -m 700` on an
#                     existing dir is "Permission denied"); MSYS `ln -s` COPIES
#                     unless the runner has the symlink privilege
#   root (CI, docker) file-mode read/write denial is not enforced against uid 0
#   macOS             BSD stat has no `-c` (the mode readback needs `-f %Lp`)
#
# Every probe MEASURES the behaviour on a scratch file under ${TMPDIR:-/tmp};
# none of them keys off `uname` or `id -u`, so a Linux host where the case IS
# expressible never skips. All return 0 = capable, 1 = not; none print.
#
#   host_mode_of <path>       octal mode, GNU or BSD stat; empty if neither works
#   host_modes_stick          chmod 0600 / 0400 / 0700 read back exactly, and
#                             `mkdir -m 700 -p` can re-secure an existing dir
#   host_can_deny_read        chmod 000 makes a file unreadable to this user
#   host_can_deny_write       chmod 555 makes a dir refuse a new file
#   host_symlinks_real        `ln -s` makes a real link (`-L`), not a copy
#   host_newline_paths        a directory name may hold a literal newline (NTFS: no)
#   host_skip <reason...>     print the one stdout line `SKIP <reason> (HIMMEL-3182)`
#
# This file sets no shell options and leaves no globals, so it is safe to source
# under `set -u` / `set -e`. A probe that cannot even make its scratch dir
# reports "not capable" (the conservative answer: the caller SKIPs, loudly).
#
# ponytail: the NTFS/MSYS behaviour cannot run on Linux/macOS - it is covered by
# PATH stubs (`chmod` no-op, `ln` copying) in test-host-caps.sh, not by a real
# Git Bash run; the extended-tier nightly is the real proof.

host_mode_of() {
    [ -n "${1-}" ] || return 1
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# _host_caps_scratch: print a fresh scratch dir the caller must rm -rf.
_host_caps_scratch() {
    mktemp -d "${TMPDIR:-/tmp}/host-caps.XXXXXX" 2>/dev/null
}

host_modes_stick() {
    local d m rc=0
    d=$(_host_caps_scratch) || return 1
    : > "$d/f" || { rm -rf "$d"; return 1; }
    for m in 600 400 700; do
        chmod "$m" "$d/f" 2>/dev/null || :
        [ "$(host_mode_of "$d/f")" = "$m" ] || { rc=1; break; }
    done
    chmod 700 "$d/f" 2>/dev/null || :
    # The directory half: `mkdir -m 700 -p` twice (create, then re-secure the
    # existing dir) -- on NTFS the second call is "Permission denied".
    # shellcheck disable=SC2174 # "$d/dir" is the deepest (only) component
    mkdir -m 700 -p "$d/dir" 2>/dev/null && mkdir -m 700 -p "$d/dir" 2>/dev/null \
        && [ "$(host_mode_of "$d/dir")" = 700 ] || rc=1
    rm -rf "$d"
    return $rc
}

host_can_deny_read() {
    local d rc=0
    d=$(_host_caps_scratch) || return 1
    printf 'x' > "$d/f" || { rm -rf "$d"; return 1; }
    chmod 000 "$d/f" 2>/dev/null || :
    if [ -r "$d/f" ] || cat "$d/f" >/dev/null 2>&1; then rc=1; fi
    chmod 600 "$d/f" 2>/dev/null || :
    rm -rf "$d"
    return $rc
}

host_can_deny_write() {
    local d rc=0
    d=$(_host_caps_scratch) || return 1
    mkdir "$d/ro" || { rm -rf "$d"; return 1; }
    chmod 555 "$d/ro" 2>/dev/null || :
    if [ -w "$d/ro" ] || { : > "$d/ro/f"; } 2>/dev/null; then rc=1; fi
    chmod 700 "$d/ro" 2>/dev/null || :
    rm -rf "$d"
    return $rc
}

host_symlinks_real() {
    local d rc=0
    d=$(_host_caps_scratch) || return 1
    : > "$d/target" || { rm -rf "$d"; return 1; }
    ln -s "$d/target" "$d/link" 2>/dev/null || rc=1
    [ "$rc" -eq 0 ] && [ -L "$d/link" ] || rc=1
    rm -rf "$d"
    return $rc
}

host_newline_paths() {
    local d rc=0
    d=$(_host_caps_scratch) || return 1
    mkdir "$d"/$'a\nb' 2>/dev/null && [ -d "$d"/$'a\nb' ] || rc=1
    rm -rf "$d"
    return $rc
}

host_skip() {
    printf 'SKIP %s (HIMMEL-3182)\n' "$*"
}
