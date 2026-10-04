#!/usr/bin/env bash
# scripts/judge-dir.sh <PR> [suffix] (HIMMEL-4325) - create a judge scratch dir
# /tmp/claude-<uid>/j<PR>[a-z] and write its holder file, so tmp-reap.sh can tell a
# live judge from a dead one. Prints the dir on stdout; on ANY failure prints
# nothing on stdout, a reason on stderr, and exits non-zero.
#   .holder = "<pid> <starttime>": pid = the nearest ancestor with a
#   ~/.claude/sessions/<pid>.json (the judge's claude process; falls back to the
#   parent shell), starttime = /proc/<pid>/stat field 22, or "-" when /proc is
#   unreadable (macOS): tmp-reap reads that as unknown, never as dead.
# Overrides (tests): TMP_REAP_TMP_ROOT, TMP_REAP_SESSIONS_DIR.
# Platform guard: POSIX bash 3.2+.
# shellcheck disable=SC2015,SC2086  # A && B || C guards; positional split of /proc stat
set -uo pipefail

die() { echo "judge-dir: $*" >&2; exit "${2:-1}"; }
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "usage: judge-dir.sh <PR-number> [suffix a-z]" 2
PR="$1"; SUF="${2:-}"
case "$PR" in ''|*[!0-9]*) die "PR must be a number, got [$PR]" 2 ;; esac
case "$SUF" in ''|[a-z]) ;; *) die "suffix must be one letter a-z, got [$SUF]" 2 ;; esac

TMP_ROOT="${TMP_REAP_TMP_ROOT:-/tmp}"
SESSIONS="${TMP_REAP_SESSIONS_DIR:-$HOME/.claude/sessions}"
DIR="$TMP_ROOT/claude-$(id -u)/j$PR$SUF"

# /proc/<pid>/stat field 22 (after the last ')'), empty when unreadable
pstart() {
    local s
    s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    s="${s##*) }"
    set -f; set -- $s; set +f
    [ "$#" -ge 20 ] || return 1
    shift 19
    echo "$1"
}
ppid_of() { # parent pid, empty when unreadable
    local s
    s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    s="${s##*) }"
    set -f; set -- $s; set +f
    [ "$#" -ge 2 ] || return 1
    echo "$2"
}

# nearest ancestor that is a registered claude session; else the parent shell
holder=""; p="$PPID"; n=0
while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 32 ]; do
    if [ -f "$SESSIONS/$p.json" ]; then holder="$p"; break; fi
    p="$(ppid_of "$p")" || break
    n=$((n+1))
done
[ -n "$holder" ] || holder="$PPID"
start="$(pstart "$holder")" || start="-"
[ -n "$start" ] || start="-"

mkdir -p "$DIR" 2>/dev/null && [ -d "$DIR" ] || die "cannot create $DIR"
# a dir someone else pre-created, or a symlinked holder, would turn the write below
# into a write through their link
[ -O "$DIR" ] && [ ! -L "$DIR" ] && [ ! -L "$DIR/.holder" ] || die "refusing $DIR: not ours or a symlink"
# a live judge of another process already holds this dir: pick another suffix
if [ -s "$DIR/.holder" ]; then
    read -r op os < "$DIR/.holder" 2>/dev/null
    case "$op" in ''|*[!0-9]*) ;; *)
        [ "$op" != "$holder" ] && [ "$os" != "-" ] && [ "$(pstart "$op")" = "$os" ] \
            && die "$DIR is held by live pid $op; use another suffix"
    ;; esac
fi
printf '%s %s\n' "$holder" "$start" > "$DIR/.holder" 2>/dev/null || die "cannot write $DIR/.holder"
[ -s "$DIR/.holder" ] || die "holder file empty: $DIR/.holder"
printf '%s\n' "$DIR"
