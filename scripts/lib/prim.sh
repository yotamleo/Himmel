#!/usr/bin/env bash
# Portable, sourced bash 3.2+ primitives. No shell options are changed.
# Only prim_-prefixed state and the four public functions are installed.
# Paths must be in caller-controlled directories on one local host.

prim_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1

# atomic_write FILE: stdin is published by a same-directory rename. Readers
# see the old or new file, never an incomplete write. Existing permissions are
# replaced by mktemp's private permissions; this is not an fsync/durability API.
atomic_write() (
    [ "$#" -eq 1 ] && [ -n "$1" ] || exit 2
    local prim_file="$1" prim_dir prim_temp
    case "$prim_file" in /*) ;; *) prim_file="./$prim_file" ;; esac
    [ ! -d "$prim_file" ] || exit 1
    prim_dir=${prim_file%/*}
    [ -n "$prim_dir" ] || prim_dir=/
    prim_temp=$(mktemp "${prim_dir%/}/.prim-write.XXXXXX") || exit 1
    trap 'rm -f -- "$prim_temp"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cat >| "$prim_temp" || exit "$?"
    mv -f -- "$prim_temp" "$prim_file" || exit "$?"
)

# with_lock LOCKFILE CMD...: synchronous command, argv/stdout/status preserved.
# flock blocks and leaves its lockfile in place (unlinking it would split locks).
# Without flock, noclobber creates a PID file exclusively; live owners are
# waited on. Dead/invalid owners fail closed: stop contenders and remove the
# stale file explicitly. Never steal by check-then-unlink, which races another
# acquirer. An empty record may be mid-write, so it is waited on too. Callers
# needing a deadline wrap the call in timeout. Do not mix backends for one path;
# remove a leftover flock file only with all users stopped before switching.
# Commands must not daemonize; SIGKILL can leave a fallback file for recovery.
with_lock() (
    [ "$#" -ge 2 ] && [ -n "$1" ] || exit 2
    local prim_lock="$1" prim_pid prim_owner prim_probe prim_current
    shift
    case "$prim_lock" in /*) ;; *) prim_lock="$(pwd -P)/$prim_lock" || exit 1 ;; esac
    if command -v flock >/dev/null 2>&1; then
        exec 9>> "$prim_lock" || exit 1
        flock -x 9 || exit "$?"
        "$@"
        exit "$?"
    fi

    # $$ does not change in a bash subshell; a child's PPID does, even on 3.2.
    prim_pid=$(sh -c 'printf "%s\n" "$PPID"') || exit 1
    while ! ( set -C; printf '%s\n' "$prim_pid" > "$prim_lock" ) 2>/dev/null; do
        if [ ! -f "$prim_lock" ]; then
            [ ! -d "$prim_lock" ] && [ ! -L "$prim_lock" ] || exit 1
            # Release may race inspection. Probe the parent to distinguish that
            # harmless disappearance from inability to create any file there.
            prim_probe=$(mktemp "${prim_lock%/*}/.prim-lock.XXXXXX") || exit 1
            rm -f -- "$prim_probe" || exit 1
            continue
        fi
        prim_owner=''
        IFS= read -r prim_owner 2>/dev/null < "$prim_lock" || prim_owner=''
        case "$prim_owner" in
            '') sleep 0.1 || exit 1; continue ;;
            *[!0-9]*|0) printf 'with_lock: invalid owner in %s\n' "$prim_lock" >&2; exit 1 ;;
        esac
        if ! kill -0 "$prim_owner" 2>/dev/null; then
            # A normal release removes the file before the owner exits. Only a
            # record still naming that dead PID is stale; a new owner or absent
            # record means retry, not an acquisition failure.
            prim_current=''
            IFS= read -r prim_current 2>/dev/null < "$prim_lock" || continue
            [ "$prim_current" = "$prim_owner" ] || continue
            printf 'with_lock: dead or inaccessible owner in %s; explicit recovery required\n' "$prim_lock" >&2
            exit 1
        fi
        sleep 0.1 || exit 1
    done
    trap 'rm -f -- "$prim_lock"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@"
    exit "$?"
)

# Source the existing implementation privately, so its other public helpers do
# not leak into the caller and the path semantics retain one implementation.
canon_path() (
    [ -r "$prim_lib_dir/canon-path.sh" ] || exit 1
    # shellcheck source=canon-path.sh
    . "$prim_lib_dir/canon-path.sh" || exit 1
    canon_path "$@"
)

# tmpdir: caller owns cleanup, e.g. t=$(tmpdir) || exit 1;
# trap 'rm -rf "$t"' EXIT. Strip trailing slashes, including TMPDIR=/.
tmpdir() {
    local prim_root="${TMPDIR:-/tmp}"
    while [ "${prim_root%/}" != "$prim_root" ]; do prim_root=${prim_root%/}; done
    mktemp -d "$prim_root/prim.XXXXXX"
}
