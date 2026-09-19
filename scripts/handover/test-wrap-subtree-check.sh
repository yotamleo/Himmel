#!/usr/bin/env bash
# test-wrap-subtree-check.sh — HIMMEL-2761. Hermetic tests for
# wrap-subtree-check.sh, the wrap/halt gate that prints CLOSABLE only when the
# session's own process subtree holds nothing but harness (MCP) processes. The
# process table is a PATH `ps` stub over a fixture; nothing live is read and
# nothing is signalled.
#
# PLATFORM GUARD: no .ps1 twin, by design — Linux-only (procps `ps`), like the
# rest of the handover wrap tooling it gates; this Bash 3.2 suite exercises
# that platform-specific script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/wrap-subtree-check.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/wrap-subtree-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (unexpected '$3' in '$2')" ;; *) pass "$1" ;; esac; }

mkdir -p "$W/bin"
# The ONE argv the SUT may use, answered from $PS_FIXTURE; PS_FAIL=1 fails it.
cat > "$W/bin/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-eo pid=,ppid=,etime=,args=" ]; then
  [ "${PS_FAIL:-0}" -eq 0 ] || exit 1
  cat "$PS_FIXTURE"
  exit 0
fi
exec /bin/ps "$@"
STUB
chmod +x "$W/bin/ps"

# 101 = the session. 110/112 are harness MCP servers (111 is a child of one).
# 900 is the tool-call wrapper running this check, 901 the check itself, 902
# its own `ps`: none of those may withhold their own banner.
cat > "$W/clean.txt" <<'FIX'
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work
  110   101    05:00:00 node /home/u/.npm/mcp-server-foo/index.js
  111   110    05:00:00 sleep 1
  112   101    05:00:00 /home/u/.bun/bin/bun /opt/qmd/dist/cli/qmd.js mcp
  900   101       00:05 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-9-z.sh && eval 'bash scripts/handover/wrap-subtree-check.sh'
  901   900       00:00 bash scripts/handover/wrap-subtree-check.sh
  902   901       00:00 ps -eo pid=,ppid=,etime=,args=
  999     1    01:00:00 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-8-y.sh && eval 'sleep 5'
FIX
# 203 is a poll loop that outlived its agent (205 its sleep), 204 a wrapper
# whose command text merely CONTAINS "mcp" (a wrapper is never harness), 206 a
# sibling backgrounded from the SAME tool call as the check (900's child).
# 999 above is another session's process: outside the subtree, never listed.
{
    cat "$W/clean.txt"
    cat <<'FIX'
  203   101    02:10:05 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-1-a.sh 2>/dev/null || true && eval 'until tail -1 x | grep OK; do sleep 10; done'
  204   101    00:40 /usr/bin/bash -c source /home/u/.claude/shell-snapshots/snapshot-bash-3-c.sh && eval 'echo mcp; sleep 999'
  205   203       00:10 sleep 10
  206   900    00:04 sleep 999
FIX
} > "$W/dirty.txt"

run() { # run <fixture> [args...] — SUT under the hermetic seams, self = 901
    local fx="$1"; shift
    PATH="$W/bin:$PATH" PS_FIXTURE="$fx" WRAP_SUBTREE_SELF=901 bash "$SUT" "$@"
}

out="$(run "$W/clean.txt" 101 2>&1)"; rc=$?
eq 'clean subtree (explicit pid): rc 0' 0 "$rc"
eq 'clean subtree: exact CLOSABLE line' 'CLOSABLE: no non-harness process under claude pid 101' "$out"

out="$(run "$W/clean.txt" 2>&1)"; rc=$?
eq 'clean subtree (session found by walking up from self): rc 0' 0 "$rc"
contains 'walk-up names the session it found' "$out" 'CLOSABLE: no non-harness process under claude pid 101'

out="$(run "$W/dirty.txt" 101 2>&1)"; rc=$?
eq 'dirty subtree: rc 1' 1 "$rc"
contains 'dirty subtree withholds CLOSABLE' "$out" 'WITHHELD: 4 process(es) still alive under claude pid 101'
lacks 'a withheld run never prints the CLOSABLE banner' "$out" 'CLOSABLE:'
contains 'lists the orphaned poll loop' "$out" 'pid=203 ppid=101 etime=02:10:05'
contains 'lists a wrapper whose command text contains mcp (wrappers are never harness)' "$out" 'pid=204'
contains 'lists the loop'"'"'s child' "$out" 'pid=205'
contains 'lists a sibling started from the same tool call as the check' "$out" 'pid=206'
lacks 'harness MCP server 110 is exempt' "$out" 'pid=110'
lacks 'a child of a harness process is exempt' "$out" 'pid=111'
lacks 'the qmd MCP server is exempt' "$out" 'pid=112'
lacks 'the check'"'"'s own wrapper/script/ps are exempt' "$out" '  pid=90'
lacks 'another session'"'"'s process is outside the subtree' "$out" 'pid=999'

out="$(WRAP_SUBTREE_HARNESS_RE='zzz-no-such-server' run "$W/clean.txt" 101 2>&1)"; rc=$?
eq 'a narrowed WRAP_SUBTREE_HARNESS_RE stops exempting MCP servers: rc 1' 1 "$rc"
contains 'narrowed regex lists all three former harness pids' "$out" 'WITHHELD: 3 process(es)'

out="$(PS_FAIL=1 run "$W/clean.txt" 101 2>&1)"; rc=$?
eq 'an unreadable process table fails CLOSED: rc 2' 2 "$rc"
lacks 'an unreadable table never prints CLOSABLE' "$out" 'CLOSABLE:'
contains 'an unreadable table says WITHHELD' "$out" 'WITHHELD: cannot read the process table'

out="$(run "$W/clean.txt" 555 2>&1)"; rc=$?
eq 'a pid that is not in the process table fails closed: rc 2' 2 "$rc"
lacks 'unknown pid never prints CLOSABLE' "$out" 'CLOSABLE:'

out="$(PATH="$W/bin:$PATH" PS_FIXTURE="$W/clean.txt" WRAP_SUBTREE_SELF=999 bash "$SUT" 2>&1)"; rc=$?
eq 'no claude session above self and no pid given fails closed: rc 2' 2 "$rc"
lacks 'no session found never prints CLOSABLE' "$out" 'CLOSABLE:'

run "$W/clean.txt" not-a-pid >/dev/null 2>&1; rc=$?
eq 'a non-numeric pid is a usage error' 2 "$rc"

# The wrap step points every leg/judge at this script instead of a hand-typed
# banner (HIMMEL-2761): pin the three docs that carry the HALT/WRAP line.
DOCS="$HERE/../../docs/handover"
for f in leg-preface.md judge-preface.md leg-brief-template.md; do
    if grep -q 'wrap-subtree-check.sh' "$DOCS/$f"; then
        pass "$f names wrap-subtree-check.sh"
    else
        fail "$f must name wrap-subtree-check.sh (HALT/WRAP line)"
    fi
done
for f in leg-preface.md leg-brief-template.md; do
    if grep -q 'TaskStop EVERY background' "$DOCS/$f"; then
        pass "$f carries the TaskStop-every-background-task line"
    else
        fail "$f must say TaskStop EVERY background task"
    fi
done

if grep -v '^[[:space:]]*#' "$SUT" | grep -Eq '(^|[[:space:];&|(])(kill|pkill|killall)[[:space:]]'; then
    fail 'wrap-subtree-check.sh must be read-only (found a kill)'
else
    pass 'wrap-subtree-check.sh contains no kill'
fi

if [ "$fails" -eq 0 ]; then
    printf 'test-wrap-subtree-check: all passed\n'
    exit 0
fi
printf 'test-wrap-subtree-check: %s FAILED\n' "$fails"
exit 1
