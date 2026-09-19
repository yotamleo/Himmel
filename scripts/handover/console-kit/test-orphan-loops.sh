#!/usr/bin/env bash
# test-orphan-loops.sh — HIMMEL-2761. Hermetic tests for orphan-loops.sh, the
# read-only inventory of long-lived Claude Code shell-tool wrappers
# (`<shell> -c source …/shell-snapshots/snapshot-<shell>-….sh …`) joined to the
# owning session name. The process table is a PATH `ps` stub over a fixture and
# the session census is a fake /proc root (CLAUDE_SESSIONS_PROC) + a pgrep stub:
# no live process is read, signalled or started.
#
# PLATFORM GUARD: no .ps1 twin, by design — the console kit is Linux-only
# (procps `ps`, /proc); this Bash 3.2 suite exercises that platform-specific
# script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/orphan-loops.sh"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/orphan-loops-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { # eq <label> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (unexpected '$3' in '$2')" ;; *) pass "$1" ;; esac; }

mkdir -p "$W/bin" "$W/proc/101"
printf '%s\0' claude --model claude-sonnet-5 -n HIMMEL-111-N61 work > "$W/proc/101/cmdline"
# shellcheck disable=SC2016  # $1 must reach the generated stub literally
printf '#!/usr/bin/env bash\nif [ "$1" = "-x" ]; then printf "%%s\\n" 101; exit 0; fi\nexit 1\n' > "$W/bin/pgrep"
# `ps` stub: the ONE argv the SUT is allowed to use, answered from $PS_FIXTURE;
# PS_FAIL=1 makes it fail. Anything else falls through to the real ps.
cat > "$W/bin/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-eo pid=,ppid=,etime=,args=" ]; then
  [ "${PS_FAIL:-0}" -eq 0 ] || exit 1
  cat "$PS_FIXTURE"
  exit 0
fi
exec /bin/ps "$@"
STUB
chmod +x "$W/bin/pgrep" "$W/bin/ps"

# 201 old wrapper directly under the session (130m); 203 young (excluded at the
# default threshold); 204 parent 999 is not in the table -> unowned; 205 is
# >1 day old; 207 sits under a nested shell 300 whose parent is the session;
# 206 merely MENTIONS a snapshot path inside a bash -c string -> not a wrapper.
cat > "$W/ps.txt" <<'FIX'
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work
  201   101    02:10:05 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-1-a.sh 2>/dev/null || true && eval 'until tail -1 x | grep OK; do sleep 10; done'
  202   201    02:10:05 sleep 10
  203   101       00:03 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-2-b.sh 2>/dev/null || true && eval 'ls'
  204   999    05:00:00 /usr/bin/bash -c source /home/u/.claude/shell-snapshots/snapshot-bash-3-c.sh 2>/dev/null || true && eval 'sleep 99999'
  205   101  1-02:00:00 bash -c source /home/u/.claude/shell-snapshots/snapshot-bash-4-d.sh && eval 'sleep 99999'
  206   101    99:00:00 bash -c echo 'ps | grep shell-snapshots/snapshot-zsh-x'
  300   101    46:00:00 /usr/bin/zsh
  207   300       45:00 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-5-e.sh && eval 'sleep 99999'
FIX

run() { # run [args...] — stdout of the SUT under the hermetic seams
    PATH="$W/bin:$PATH" PS_FIXTURE="$W/ps.txt" CLAUDE_SESSIONS_PROC="$W/proc" \
        REPO="$REPO_ROOT" bash "$SUT" "$@"
}

out="$(run)"; rc=$?
eq 'default: exact one-line inventory joined to owner names (>=30m)' \
    'orphans=HIMMEL-111-N61:3/1560m,orphan:1/300m' "$out"
eq 'default: rc 0' 0 "$rc"

out="$(TICK_ORPHAN_MIN=200 run)"
eq 'TICK_ORPHAN_MIN raises the age floor' 'orphans=orphan:1/300m,HIMMEL-111-N61:1/1560m' "$out"

out="$(run --min 2000)"
eq '--min above every age reads none' 'orphans=none' "$out"

out="$(run --list)"
contains '--list names a wrapper pid' "$out" 'pid=201 owner=HIMMEL-111-N61 age=130m'
contains '--list names the unowned wrapper' "$out" 'pid=204 owner=orphan age=300m'
contains '--list joins a nested-shell wrapper to the session' "$out" 'pid=207 owner=HIMMEL-111-N61 age=45m'
lacks '--list omits a young wrapper' "$out" 'pid=203'
lacks '--list omits a process that only mentions a snapshot path' "$out" 'pid=206'
lacks '--list omits the sleep child and the session itself' "$out" 'pid=202'

out="$(PS_FAIL=1 run)"; rc=$?
eq 'a failing ps reads orphans=? and never fails the caller' 'orphans=?' "$out"
eq 'a failing ps: rc 0' 0 "$rc"

run --bogus >/dev/null 2>&1; rc=$?
eq 'an unknown flag is a usage error' 2 "$rc"

# Read-only: the SUT must not signal anything.
if grep -v '^[[:space:]]*#' "$SUT" | grep -Eq '(^|[[:space:];&|(])(kill|pkill|killall)[[:space:]]'; then
    fail 'orphan-loops.sh must be read-only (found a kill)'
else
    pass 'orphan-loops.sh contains no kill'
fi

if [ "$fails" -eq 0 ]; then
    printf 'test-orphan-loops: all passed\n'
    exit 0
fi
printf 'test-orphan-loops: %s FAILED\n' "$fails"
exit 1
