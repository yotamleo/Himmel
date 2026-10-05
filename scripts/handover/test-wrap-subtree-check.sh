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
  207   101    01:00:00 /home/u/.bun/bin/bun /opt/qmd/dist/cli/qmd.js update
  208   101    01:00:00 node /repo/mcp-project/build.js --watch
FIX
} > "$W/dirty.txt"

run() { # run <fixture> [args...] — SUT under the hermetic seams, self = 901
    local fx="$1"; shift
    PATH="$W/bin:$PATH" PS_FIXTURE="$fx" WRAP_SUBTREE_SELF=901 bash "$SUT" "$@"
}

out="$(run "$W/clean.txt" 101 2>&1)"; rc=$?
eq 'clean subtree (explicit pid): rc 0' 0 "$rc"
contains 'clean subtree: CLOSABLE line, harness children counted' "$out" 'CLOSABLE: no non-harness process under claude pid 101 (3 harness-owned children ignored)'

out="$(run "$W/clean.txt" 2>&1)"; rc=$?
eq 'clean subtree (session found by walking up from self): rc 0' 0 "$rc"
contains 'walk-up names the session it found' "$out" 'CLOSABLE: no non-harness process under claude pid 101'

out="$(run "$W/dirty.txt" 101 2>&1)"; rc=$?
eq 'dirty subtree: rc 1' 1 "$rc"
contains 'dirty subtree withholds CLOSABLE' "$out" 'WITHHELD: 6 process(es) still alive under claude pid 101'
contains 'a qmd command that is not the MCP server is NOT exempt (codex-1)' "$out" 'pid=207'
contains 'a process merely under an mcp-named path is NOT exempt (codex-1)' "$out" 'pid=208'
lacks 'a withheld run never prints the CLOSABLE banner' "$out" 'CLOSABLE:'
contains 'lists the orphaned poll loop' "$out" 'pid=203 ppid=101 etime=02:10:05'
contains 'lists a wrapper whose command text contains mcp (wrappers are never harness)' "$out" 'pid=204'
contains 'lists the loop'"'"'s child' "$out" 'pid=205'
contains 'lists a sibling started from the same tool call as the check' "$out" 'pid=206'
lacks 'harness MCP server 110 is exempt' "$out" '  pid=110 ppid='
lacks 'a child of a harness process is exempt' "$out" '  pid=111 ppid='
lacks 'the qmd MCP server is exempt' "$out" '  pid=112 ppid='
lacks 'the check'"'"'s own wrapper/script/ps are exempt' "$out" '  pid=90'
lacks 'another session'"'"'s process is outside the subtree' "$out" 'pid=999'

out="$(WRAP_SUBTREE_START_WINDOW=0 WRAP_SUBTREE_HARNESS_RE='zzz-no-such-server' run "$W/clean.txt" 101 2>&1)"; rc=$?
eq 'a narrowed WRAP_SUBTREE_HARNESS_RE (with the start-time rule off) stops exempting MCP servers: rc 1' 1 "$rc"
contains 'narrowed regex lists all three former harness pids' "$out" 'WITHHELD: 3 process(es)'

out="$(PS_FAIL=1 run "$W/clean.txt" 101 2>&1)"; rc=$?
eq 'an unreadable process table fails CLOSED: rc 2' 2 "$rc"
lacks 'an unreadable table never prints CLOSABLE' "$out" 'CLOSABLE:'
contains 'an unreadable table says WITHHELD' "$out" 'WITHHELD: cannot read the process table'

out="$(run "$W/clean.txt" 555 2>&1)"; rc=$?
eq 'a pid that is not in the process table fails closed: rc 2' 2 "$rc"
lacks 'unknown pid never prints CLOSABLE' "$out" 'CLOSABLE:'

out="$(run "$W/clean.txt" 110 2>&1)"; rc=$?
eq 'a live pid that is not a claude session fails closed: rc 2 (codex-2)' 2 "$rc"
lacks 'a non-claude pid never prints CLOSABLE' "$out" 'CLOSABLE:'
contains 'a non-claude pid says so' "$out" 'is not a claude session'
out="$(run "$W/clean.txt" 111 2>&1)"; rc=$?
eq 'a leaf pid (no children) is refused, not called CLOSABLE (codex-2)' 2 "$rc"

out="$(PATH="$W/bin:$PATH" PS_FIXTURE="$W/clean.txt" WRAP_SUBTREE_SELF=999 bash "$SUT" 2>&1)"; rc=$?
eq 'no claude session above self and no pid given fails closed: rc 2' 2 "$rc"
lacks 'no session found never prints CLOSABLE' "$out" 'CLOSABLE:'

run "$W/clean.txt" not-a-pid >/dev/null 2>&1; rc=$?
eq 'a non-numeric pid is a usage error' 2 "$rc"

# A chain deeper than any fixed hop budget: the check is pid 4066, 67 tool-call
# shells below the session, and 5000 is a poll loop beside it. It must still be
# listed (a walk that runs out of hops fails closed, never "outside") and the
# check's own long chain must not be counted (codex-1, round 2).
{
    printf '    1     0 40-00:00:01 /sbin/init\n  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work\n'
    prev=101
    i=4000
    while [ "$i" -le 4066 ]; do
        printf '%5s %5s    00:30 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-%s-d.sh && eval "sleep 1"\n' "$i" "$prev" "$i"
        prev=$i
        i=$((i + 1))
    done
    printf '%5s %5s    01:00 sleep 999\n' 5000 4065
} > "$W/deep.txt"
out="$(PATH="$W/bin:$PATH" PS_FIXTURE="$W/deep.txt" WRAP_SUBTREE_SELF=4066 bash "$SUT" 101 2>&1)"; rc=$?
eq 'a process beyond the old 64-hop budget is still withheld: rc 1 (codex-1 r2)' 1 "$rc"
contains 'only the deep sibling is listed; the check'"'"'s own 67-deep chain is exempt' "$out" 'WITHHELD: 1 process(es)'
contains 'the deep sibling is named' "$out" 'pid=5000'

# HIMMEL-3265: harness-owned MCP servers that match no name pattern. The shapes
# are the real ones read off a live station (mcp-obsidian under `uv tool uvx`,
# graphify-mcp, an `uv run … server.py`, each with its python child): direct
# children of the session, forked within ~1s of it. 101's etime is 05:00:00, so
# an etime of 04:59:59 is "started 1s after the session".
cat > "$W/base.txt" <<'FIX'
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work
  900   101       00:05 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-9-z.sh && eval 'bash scripts/handover/wrap-subtree-check.sh'
  901   900       00:00 bash scripts/handover/wrap-subtree-check.sh
  902   901       00:00 ps -eo pid=,ppid=,etime=,args=
FIX
cat > "$W/mcp-children.txt" <<'FIX'
  120   101    04:59:59 /usr/bin/uv tool uvx --with mcp==1.28.1 mcp-obsidian
  121   120    04:59:59 /home/u/.cache/uv/archive-v0/x/bin/python /home/u/.cache/uv/archive-v0/x/bin/mcp-obsidian
  122   101    04:59:59 /home/u/.local/share/uv/tools/graphifyy/bin/python /home/u/.local/bin/graphify-mcp
  123   101    04:59:59 uv run --no-project --with mcp<2 python /home/u/.claude/skills/obsidian-second-brain/integrations/obsidian-mcp-server/server.py
  124   123    04:59:59 /home/u/.cache/uv/builds-v0/.tmp/bin/python /home/u/.claude/skills/obsidian-second-brain/integrations/obsidian-mcp-server/server.py
FIX
cat "$W/base.txt" "$W/mcp-children.txt" > "$W/mcp-only.txt"
# The same session, but the leg also left work behind: 203/205 a poll loop and
# its sleep (a tool-call wrapper, late), 208 a NON-wrapper direct child forked
# hours after the session, 209 a tool-call wrapper forked 2s after the session
# (inside the window — a wrapper is never harness, whenever it started).
{
    cat "$W/mcp-only.txt"
    cat <<'FIX'
  203   101    02:10:05 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-1-a.sh 2>/dev/null || true && eval 'until tail -1 x | grep OK; do sleep 10; done'
  205   203       00:10 sleep 10
  208   101    01:00:00 node /repo/loop.js --watch
  209   101    04:59:58 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-2-b.sh && eval 'sleep 999'
FIX
} > "$W/mixed.txt"

MCP_PIDS='120 121 122 123 124'
LEG_PIDS='203 205 208 209'
names_all() { # names_all <out> <label> <pid…>: every pid is a withheld row
    local o="$1" p; shift
    for p in "$@"; do case "$o" in *"  pid=$p ppid="*) ;; *) return 1 ;; esac; done
}
names_none() { # names_none <out> <pid…>: no pid is a withheld row
    local o="$1" p; shift
    for p in "$@"; do case "$o" in *"  pid=$p ppid="*) return 1 ;; esac; done
}

out="$(run "$W/mcp-only.txt" 101 2>&1)"; rc=$?
eq 'session whose only children are MCP servers: rc 0 (3265)' 0 "$rc"
contains 'CLOSABLE is reachable for an MCP-attached session (3265)' "$out" 'CLOSABLE: no non-harness process under claude pid 101'
contains 'the CLOSABLE line counts what it ignored (3265)' "$out" '(5 harness-owned children ignored)'
lacks 'a CLOSABLE run never prints WITHHELD' "$out" 'WITHHELD:'
for p in $MCP_PIDS; do contains "ignored MCP pid $p is reported, not hidden (3265)" "$out" "ignored pid=$p "; done
contains 'an ignored child says why' "$out" 'why=session-start'
contains 'a grandchild of a session-started MCP launcher is ignored transitively (uvx child)' "$out" 'ignored pid=121 ppid=120 etime=04:59:59 why=session-start via=120 '
contains 'a grandchild of a session-started MCP launcher is ignored transitively (uv run child)' "$out" 'ignored pid=124 ppid=123 etime=04:59:59 why=session-start via=123 '

# THE CONTROL: one run, harness-shaped and leg-spawned children side by side.
out="$(run "$W/mixed.txt" 101 2>&1)"; rc=$?
eq 'mixed run (MCP servers + leg-left loop): rc 1 (3265)' 1 "$rc"
contains 'mixed run withholds exactly the four leg-spawned processes (3265)' "$out" 'WITHHELD: 4 process(es) still alive under claude pid 101'
lacks 'a withheld run never prints CLOSABLE (3265)' "$out" 'CLOSABLE:'
# shellcheck disable=SC2086 # the pid lists are space-separated words on purpose
if names_all "$out" $LEG_PIDS; then pass 'mixed run names the leg-left loop, its child, the late direct child and the early wrapper'; else fail "mixed run must name every leg-spawned pid ($LEG_PIDS): $out"; fi
# shellcheck disable=SC2086 # the pid lists are space-separated words on purpose
if names_none "$out" $MCP_PIDS; then pass 'mixed run does not list any MCP server as a withheld process'; else fail "mixed run listed a harness MCP server as withheld: $out"; fi
for p in $MCP_PIDS; do contains "mixed run still reports ignored MCP pid $p" "$out" "ignored pid=$p "; done
contains 'the WITHHELD text says never to stop a process the leg did not start (3265)' "$out" 'did not start'

# The exemption comes from the start-time rule, not from somewhere else: switch
# it off and the same MCP-only table is withheld.
out="$(WRAP_SUBTREE_START_WINDOW=0 run "$W/mcp-only.txt" 101 2>&1)"; rc=$?
eq 'start-time rule off: the MCP-only table is withheld, rc 1 (3265)' 1 "$rc"
contains 'start-time rule off lists all five' "$out" 'WITHHELD: 5 process(es)'

# Window edge (default 10s): forked at +10s is harness-shaped, +11s is not.
{
    cat "$W/base.txt"
    cat <<'FIX'
  210   101    04:59:50 node /x/late-server.js
  211   101    04:59:49 node /x/later-server.js
FIX
} > "$W/edge.txt"
out="$(run "$W/edge.txt" 101 2>&1)"; rc=$?
eq 'window edge: only the +11s child withholds, rc 1' 1 "$rc"
contains 'window edge: +11s child is named' "$out" '  pid=211 ppid='
lacks 'window edge: +10s child is exempt' "$out" '  pid=210 ppid='

# Fail closed: a bad window value, and an etime the rule cannot read, never
# produce CLOSABLE.
out="$(WRAP_SUBTREE_START_WINDOW=ten run "$W/mcp-only.txt" 101 2>&1)"; rc=$?
eq 'a non-numeric WRAP_SUBTREE_START_WINDOW fails closed: rc 2' 2 "$rc"
lacks 'a bad window never prints CLOSABLE' "$out" 'CLOSABLE:'
sed 's/04:59:59 \/usr\/bin\/uv tool/??:?? \/usr\/bin\/uv tool/' "$W/mcp-only.txt" > "$W/bad-etime.txt"
out="$(run "$W/bad-etime.txt" 101 2>&1)"; rc=$?
eq 'an unreadable child etime is not exempted (fails toward WITHHELD): rc 1' 1 "$rc"
contains 'the unreadable-etime child and the python child beneath it both withhold' "$out" 'WITHHELD: 2 process(es)'
contains 'the unreadable-etime child is pid 120' "$out" '  pid=120 ppid='
# A child that appears to predate the session (negative delta) is not exempt.
sed 's/04:59:59 \/home\/u\/.local\/share\/uv\/tools\/graphifyy/05:00:09 \/home\/u\/.local\/share\/uv\/tools\/graphifyy/' "$W/mcp-only.txt" > "$W/pre-session.txt"
out="$(run "$W/pre-session.txt" 101 2>&1)"; rc=$?
eq 'a child older than its session is not exempt: rc 1' 1 "$rc"
contains 'the older-than-session child is pid 122' "$out" '  pid=122 ppid='

# #1337: a harness-spawned tree macOS legs actually produce, that the
# HIMMEL-3265 name/session-start matcher does not catch. The session keep-awake
# (`caffeinate`) re-arms on a rolling cadence, so its etime never lands inside
# the isearly() start window (proven here by a session that has run 5h against
# a caffeinate that just (re)started); it must be exempt by name alone. A
# stray node server and a leg's own sleep sit alongside it and must still
# withhold. (#1337 also reported a claude-hud statusline false WITHHELD; a
# claude-hud-by-path exemption was tried and reverted on re-judge — see
# HIMMEL-3723 — so no claude-hud row is exempt here.)
cat > "$W/harness-trees.txt" <<'FIX'
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work
  300   101       00:05 /usr/bin/caffeinate -i -t 300
  320   101    00:10:00 node /repo/server.js
  321   101    00:05:00 sleep 999
FIX
out="$(run "$W/harness-trees.txt" 101 2>&1)"; rc=$?
eq 'harness caffeinate tree plus genuine leftovers: rc 1 (#1337)' 1 "$rc"
contains 'only the genuine leftovers withhold (#1337)' "$out" 'WITHHELD: 2 process(es) still alive under claude pid 101'
contains 'the stray node server is named (#1337)' "$out" 'pid=320 ppid='
contains 'the leg'"'"'s own sleep is named (#1337)' "$out" 'pid=321 ppid='
lacks 'a withheld run never prints CLOSABLE (#1337)' "$out" 'CLOSABLE:'
contains 'harness pid 300 is ignored, not withheld (#1337)' "$out" 'ignored pid=300 '
lacks 'harness pid 300 is not listed as withheld (#1337)' "$out" '  pid=300 ppid='
contains 'the caffeinate keep-awake is name-matched (#1337)' "$out" 'ignored pid=300 ppid=101 etime=00:05 why=name-match cmd=/usr/bin/caffeinate'

# J1355O (Opus judge, round 2): the #1337 fix above matched `caffeinate` as a
# WORD anywhere in argv, so a leg running a real job named
# `caffeinate ./long-job.sh`, or a `sleep` invocation that merely mentions the
# word, got falsely exempted too. Anchor caffeinate to the PROGRAM position
# (only flags may follow); the legit row from #1337 above (300) must stay
# exempt alongside the new decoys withholding.
cat > "$W/decoys.txt" <<'FIX'
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work
  300   101       00:05 /usr/bin/caffeinate -i -t 300
  330   101    00:10:00 caffeinate -i ./long-job.sh
  331   330    00:10:00 /bin/bash ./long-job.sh
  332   101    00:10:00 sleep 999 caffeinate
FIX
out="$(run "$W/decoys.txt" 101 2>&1)"; rc=$?
eq 'decoys withhold, legit caffeinate tree stays exempt: rc 1 (J1355O)' 1 "$rc"
contains 'exactly the three decoys withhold (J1355O)' "$out" 'WITHHELD: 3 process(es) still alive under claude pid 101'
contains 'a real job named like caffeinate withholds (J1355O)' "$out" '  pid=330 ppid='
contains "the job's own child withholds too (J1355O)" "$out" '  pid=331 ppid='
contains '"sleep 999 caffeinate" is not exempt by the word alone (J1355O)' "$out" '  pid=332 ppid='
lacks 'a withheld run never prints CLOSABLE (J1355O)' "$out" 'CLOSABLE:'
contains 'the legit caffeinate keep-awake stays exempt (J1355O)' "$out" 'ignored pid=300 '

# J1355P (Opus judge, round 3): a claude-hud-by-path exemption
# (`^([^ ]*/)?(node|bun) [^ ]*/claude-hud/[^ ]*`) was proposed to fix the
# claude-hud half of #1337 and rejected — it exempted ANY node/bun script
# under any directory merely NAMED claude-hud, plus its descendants, not just
# the real statusline install. That exemption was removed entirely (tracked
# as HIMMEL-3723, not fixed here); this row is the negative control proving
# it stays gone: a real service that happens to live under a `claude-hud`
# directory, with its own child, must still withhold.
cat > "$W/claude-hud-decoy.txt" <<'FIX'
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work
  340   101    00:10:00 node /repo/claude-hud/server.js
  341   340    00:10:00 node /repo/claude-hud/worker.js
FIX
out="$(run "$W/claude-hud-decoy.txt" 101 2>&1)"; rc=$?
eq 'an unrelated service under a claude-hud-named directory withholds: rc 1 (J1355P, HIMMEL-3723)' 1 "$rc"
contains 'the claude-hud-path decoy withholds (J1355P)' "$out" '  pid=340 ppid='
contains "the decoy's own child withholds too (J1355P)" "$out" '  pid=341 ppid='
lacks 'no claude-hud exemption remains (J1355P)' "$out" 'why=name-match cmd=node /repo/claude-hud'

# HIMMEL-4139 (closes the claude-hud half of #1337 / HIMMEL-3723): the real
# statusLine refresh (`sh -c [ -f P ] && exec node P || true`, so argv is
# `node <repo>/marketplace/plugins/claude-hud/dist/index.js`) re-spawns every few
# seconds under the session, with hud-custom-lines.sh, statusline-segment.sh and
# a `timeout 3 node …/provision.mjs slice` beneath it, all at etime 00:00. That
# whole subtree is harness; the path anchor is the exact install shape, not any
# directory named claude-hud (the J1355P decoy above stays withheld).
HUD=/home/u/himmel/marketplace/plugins/claude-hud/dist/index.js
cat > "$W/hud-tree.txt" <<FIX
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work
  400   101       00:00 node $HUD
  401   400       00:00 bash /home/u/himmel/scripts/statusline/hud-custom-lines.sh
  402   401       00:00 bash /home/u/himmel/scripts/where-are-we/statusline-segment.sh
  403   402       00:00 timeout 3 node /home/u/himmel/scripts/where-are-we/provision.mjs slice
  404   403       00:00 node /home/u/himmel/scripts/where-are-we/provision.mjs slice
FIX
out="$(run "$W/hud-tree.txt" 101 2>&1)"; rc=$?
eq 'a fresh claude-hud statusline subtree is harness: rc 0 (HIMMEL-4139)' 0 "$rc"
contains 'the hud subtree prints CLOSABLE, all five counted (HIMMEL-4139)' "$out" 'CLOSABLE: no non-harness process under claude pid 101 (5 harness-owned children ignored)'
contains 'the hud root is name-matched (HIMMEL-4139)' "$out" "ignored pid=400 ppid=101 etime=00:00 why=statusline-chain cmd=node $HUD"
contains 'a hud descendant inherits the ignore (HIMMEL-4139)' "$out" 'ignored pid=404 '
# The same subtree beside genuine leftovers: only the leftovers withhold.
{
    cat "$W/hud-tree.txt"
    cat <<'FIX'
  410   101    00:10:00 sleep 100
  411   101    00:10:00 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-5-e.sh && eval 'while true; do sleep 5; done'
FIX
} > "$W/hud-plus-leftovers.txt"
out="$(run "$W/hud-plus-leftovers.txt" 101 2>&1)"; rc=$?
eq 'hud subtree plus a leg sleep and loop still withholds: rc 1 (HIMMEL-4139)' 1 "$rc"
contains 'exactly the two leftovers withhold (HIMMEL-4139)' "$out" 'WITHHELD: 2 process(es) still alive under claude pid 101'
contains 'the leg sleep is named (HIMMEL-4139)' "$out" '  pid=410 ppid='
contains 'the leg loop wrapper is named (HIMMEL-4139)' "$out" '  pid=411 ppid='
lacks 'the hud root is not listed as withheld (HIMMEL-4139)' "$out" '  pid=400 ppid='
# Near-misses of the anchor must NOT be exempt: `..` segment, extra argv, a
# non-absolute path, a different plugin dir, a different file, a non-node program.
cat > "$W/hud-decoys.txt" <<'FIX'
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work
  420   101    00:10:00 node /home/u/evil/../himmel/marketplace/plugins/claude-hud/dist/index.js
  421   101    00:10:00 node /home/u/himmel/marketplace/plugins/claude-hud/dist/index.js --serve
  422   101    00:10:00 node marketplace/plugins/claude-hud/dist/index.js
  423   101    00:10:00 node /home/u/himmel/marketplace/plugins/other/dist/index.js
  424   101    00:10:00 node /home/u/himmel/marketplace/plugins/claude-hud/dist/server.js
  425   101    00:10:00 python3 /home/u/himmel/marketplace/plugins/claude-hud/dist/index.js
  426   101    00:10:00 node /home/u/himmel/x/claude-hud/dist/index.js
FIX
out="$(run "$W/hud-decoys.txt" 101 2>&1)"; rc=$?
eq 'near-miss hud paths all withhold: rc 1 (HIMMEL-4139)' 1 "$rc"
contains 'all seven near-misses withhold (HIMMEL-4139)' "$out" 'WITHHELD: 7 process(es) still alive under claude pid 101'
lacks 'a decoy never prints CLOSABLE (HIMMEL-4139)' "$out" 'CLOSABLE:'
# The WITHHELD text does not order a leg to stop what it did not start.
out="$(run "$W/dirty.txt" 101 2>&1)"
lacks 'WITHHELD text does not tell the leg to TaskStop every process listed (HIMMEL-4139)' "$out" 'still alive under claude pid 101 — TaskStop every'
contains 'WITHHELD text limits TaskStop to what the leg started (HIMMEL-4139)' "$out" 'TaskStop only what you started'

# HIMMEL-4161: the whole per-render statusline chain is exempt as a subtree whose
# EVERY member matches a tight install-path anchor — also when the claude-hud node
# is not in the table (a render caught mid-way), and real `timeout N` / `$(…)`
# subshell shapes. A non-chain process anywhere in the subtree still withholds.
SL=/home/u/himmel/scripts
one_row() { # <name> <row>: fixture of the session plus one row under it
    printf '    1     0 40-00:00:01 /sbin/init\n  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work\n%s\n' "$2" > "$W/$1.txt"
}
# (a) each chain member alone, directly under the session.
one_row chain-a1 "  500   101       00:00 node $HUD"
one_row chain-a2 "  500   101       00:00 bash $SL/statusline/hud-custom-lines.sh"
one_row chain-a3 "  500   101       00:00 bash $SL/where-are-we/statusline-segment.sh --cwd /home/u/himmel/.claude/worktrees/fix+x"
one_row chain-a4 "  500   101       00:00 timeout 3 bash $SL/where-are-we/statusline-segment.sh --cwd /home/u/w"
one_row chain-a5 "  500   101       00:00 /usr/bin/node $SL/where-are-we/provision.mjs slice --ledger /home/u/himmel/.where-are-we/ledger.jsonl --for HIMMEL-4161"
one_row chain-a6 "  500   101       00:00 timeout 3 /usr/bin/node $SL/where-are-we/provision.mjs slice --ledger /l --for K-1"
for n in a1 a2 a3 a4 a5 a6; do
    out="$(run "$W/chain-$n.txt" 101 2>&1)"; rc=$?
    eq "chain member $n alone is exempt: rc 0 (HIMMEL-4161)" 0 "$rc"
    contains "chain member $n alone prints CLOSABLE (HIMMEL-4161)" "$out" 'CLOSABLE: no non-harness process under claude pid 101 (1 harness-owned children ignored)'
done
# (b) the chain nested as it really nests, with `timeout` and `$(…)` subshells
# (same argv as their parent), and the hud node absent from the table.
cat > "$W/chain-full.txt" <<FIX
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work
  500   101       00:00 node $HUD
  501   500       00:00 bash $SL/statusline/hud-custom-lines.sh
  502   501       00:00 bash $SL/statusline/hud-custom-lines.sh
  503   502       00:00 timeout 3 bash $SL/where-are-we/statusline-segment.sh --cwd /home/u/w
  504   503       00:00 bash $SL/where-are-we/statusline-segment.sh --cwd /home/u/w
  505   504       00:00 bash $SL/where-are-we/statusline-segment.sh --cwd /home/u/w
  506   505       00:00 timeout 3 /usr/bin/node $SL/where-are-we/provision.mjs slice --ledger /l --for K-1
  507   506       00:00 /usr/bin/node $SL/where-are-we/provision.mjs slice --ledger /l --for K-1
FIX
out="$(run "$W/chain-full.txt" 101 2>&1)"; rc=$?
eq 'the full nested statusline chain is exempt: rc 0 (HIMMEL-4161)' 0 "$rc"
contains 'the full chain prints CLOSABLE, all eight counted (HIMMEL-4161)' "$out" 'CLOSABLE: no non-harness process under claude pid 101 (8 harness-owned children ignored)'
grep -v ' node /home/u/himmel/marketplace' "$W/chain-full.txt" | sed 's/^  501   500/  501   101/' > "$W/chain-nohud.txt"
out="$(run "$W/chain-nohud.txt" 101 2>&1)"; rc=$?
eq 'the chain without its hud node is exempt too: rc 0 (HIMMEL-4161)' 0 "$rc"
# (c) a non-chain child anywhere withholds, and only it (plus anything under it).
{ cat "$W/chain-full.txt"; printf '  510   500       00:00 sleep 100\n'; } > "$W/chain-extra-under-hud.txt"
out="$(run "$W/chain-extra-under-hud.txt" 101 2>&1)"; rc=$?
eq 'a non-chain child of the hud node withholds: rc 1 (HIMMEL-4161)' 1 "$rc"
contains 'exactly the extra child withholds (HIMMEL-4161)' "$out" 'WITHHELD: 1 process(es) still alive under claude pid 101'
contains 'the extra child is named (HIMMEL-4161)' "$out" '  pid=510 ppid='
{ cat "$W/chain-full.txt"; printf '  511   505       00:00 sleep 100\n'; } > "$W/chain-extra-deep.txt"
out="$(run "$W/chain-extra-deep.txt" 101 2>&1)"; rc=$?
eq 'a non-chain child deep in the chain withholds: rc 1 (HIMMEL-4161)' 1 "$rc"
contains 'the deep extra child is named (HIMMEL-4161)' "$out" '  pid=511 ppid='
# A chain member beneath a non-chain parent: the parent withholds, the member is
# NOT laundered by its own shape.
printf '  520   101    00:10:00 sleep 100\n  521   520       00:00 bash %s/statusline/hud-custom-lines.sh\n' "$SL" > "$W/chain-under-sleep.rows"
{ printf '    1     0 40-00:00:01 /sbin/init\n  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work\n'; cat "$W/chain-under-sleep.rows"; } > "$W/chain-under-sleep.txt"
out="$(run "$W/chain-under-sleep.txt" 101 2>&1)"; rc=$?
eq 'a chain member under a non-chain parent withholds: rc 1 (HIMMEL-4161)' 1 "$rc"
contains 'both the parent and the member are named (HIMMEL-4161)' "$out" 'WITHHELD: 2 process(es)'
# (d) look-alike paths all withhold.
cat > "$W/chain-decoys.txt" <<'FIX'
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work
  530   101    00:10:00 bash /tmp/statusline-segment.sh
  531   101    00:10:00 bash /home/u/x/where-are-we/statusline-segment.sh --cwd /w
  532   101    00:10:00 bash /home/u/himmel/scripts/statusline/hud-custom-lines.sh --serve
  533   101    00:10:00 bash /home/u/evil/../himmel/scripts/statusline/hud-custom-lines.sh
  534   101    00:10:00 node /home/u/himmel/scripts/where-are-we/provision.mjs ledger
  535   101    00:10:00 node /home/u/himmel/scripts/where-are-we/provision.mjs
  536   101    00:10:00 python3 /home/u/himmel/scripts/where-are-we/provision.mjs slice
  537   101    00:10:00 bash scripts/statusline/hud-custom-lines.sh
  538   101    00:10:00 bash /home/u/himmel/scripts/where-are-we/statusline-segment.sh.bak
FIX
out="$(run "$W/chain-decoys.txt" 101 2>&1)"; rc=$?
eq 'look-alike chain paths all withhold: rc 1 (HIMMEL-4161)' 1 "$rc"
contains 'all nine look-alikes withhold (HIMMEL-4161)' "$out" 'WITHHELD: 9 process(es) still alive under claude pid 101'
lacks 'a look-alike never prints CLOSABLE (HIMMEL-4161)' "$out" 'CLOSABLE:'

# fx3: the SAME tool call that starts a background job also runs the check —
# a shell wrapper backgrounds `caffeinate -i ./long-job.sh` and the check
# itself with `&`, both children of one wrapper. The job must withhold even
# though it shares a wrapper with the check being run.
cat > "$W/same-tool-call.txt" <<'FIX'
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-N61 work
  950   101       00:05 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-9-z.sh && eval 'caffeinate -i ./long-job.sh & bash scripts/handover/wrap-subtree-check.sh'
  951   950       00:05 caffeinate -i ./long-job.sh
  952   951       00:05 /bin/bash ./long-job.sh
  953   950       00:00 bash scripts/handover/wrap-subtree-check.sh
  954   953       00:00 ps -eo pid=,ppid=,etime=,args=
FIX
out="$(PATH="$W/bin:$PATH" PS_FIXTURE="$W/same-tool-call.txt" WRAP_SUBTREE_SELF=953 bash "$SUT" 101 2>&1)"; rc=$?
eq 'a caffeinate job started in the SAME tool call as the check still withholds: rc 1 (J1355O, fx3)' 1 "$rc"
contains 'the same-tool-call caffeinate job withholds (fx3)' "$out" '  pid=951 ppid='
contains "the job's own child withholds too (fx3)" "$out" '  pid=952 ppid='
lacks 'a withheld run never prints CLOSABLE (fx3)' "$out" 'CLOSABLE:'

# Weakening controls (HIMMEL-3265, contract item 3). Each weakened check must RUN
# and lose the leg-left loop for the specific reason — a check that merely
# crashes would "fail" every assertion and prove nothing.
# shellcheck disable=SC2086 # the pid lists are space-separated words on purpose
leg_loop_kept() { names_all "$1" $LEG_PIDS && ! case "$1" in *'CLOSABLE:'*) true ;; *) false ;; esac; }
out="$(run "$W/mixed.txt" 101 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && leg_loop_kept "$out"; then pass 'control baseline: the real check keeps the leg-left loop'; else fail 'control baseline broken'; fi

# (a) A start window wide enough to swallow the late direct child (208) drops it
# — and only it: the wrappers (203 205 209) stay, so the check RAN.
out="$(WRAP_SUBTREE_START_WINDOW=99999999 run "$W/mixed.txt" 101 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && names_all "$out" 203 205 209 && names_none "$out" 208; then
    pass 'control (a): an over-wide start window loses the late direct child, and only it'
else
    fail "control (a) did not fail for the predicted reason (rc=$rc): $out"
fi
if leg_loop_kept "$out"; then fail 'control (a): the leg-loop assertion could not catch an over-wide window'; else pass 'control (a): the leg-loop assertion catches an over-wide window'; fi

# (b) A check that never counts anything prints CLOSABLE over the same table.
sed 's/^        n++$/        n += 0/' "$SUT" > "$W/never-counts.sh"
if cmp -s "$SUT" "$W/never-counts.sh"; then
    fail 'control (b): mutation did not apply (n++ line moved) — the control is vacuous'
else
    out="$(PATH="$W/bin:$PATH" PS_FIXTURE="$W/mixed.txt" WRAP_SUBTREE_SELF=901 bash "$W/never-counts.sh" 101 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && case "$out" in 'CLOSABLE: no non-harness process'*) true ;; *) false ;; esac; then
        pass 'control (b): a never-counting check runs and prints CLOSABLE over the mixed table'
    else
        fail "control (b) did not fail for the predicted reason (rc=$rc): $out"
    fi
    if leg_loop_kept "$out"; then fail 'control (b): the leg-loop assertion could not catch an always-CLOSABLE check'; else pass 'control (b): the leg-loop assertion catches an always-CLOSABLE check'; fi
fi

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

kill_hits="$(grep -v '^[[:space:]]*#' "$SUT" | grep -E '(^|[[:space:];&|(])(kill|pkill|killall)[[:space:]]')"
if [ -n "$kill_hits" ]; then
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
