#!/usr/bin/env bash
# wrap-subtree-check.sh — the structural wrap/halt gate (HIMMEL-2761).
#
# A leg (or judge) that declares itself closable must first prove its own
# process subtree is empty. TaskStop on an agent does NOT reap the background
# shell that agent spawned (fleet halt 2026-09-07: leg N35 reported WRAPPED with
# a poll loop still alive 2h10m later), and the console cannot kill it — so the
# closable-window banner is this script's output, never hand-typed:
#   CLOSABLE: no non-harness process under claude pid <pid>     rc 0
#     [ (<n> harness-owned children ignored) + one `ignored pid=…` row each ]
#   WITHHELD: <n> process(es) still alive under claude pid <pid>   rc 1
#     pid=<pid> ppid=<ppid> etime=<etime> cmd=<first 100 chars of argv>
#   WITHHELD: cannot …                                             rc 2
# rc 2 is fail-CLOSED: an unreadable process table, or no claude session to
# anchor on, never prints CLOSABLE. On WITHHELD, TaskStop EVERY background task
# and every agent you spawned, then re-run until it prints CLOSABLE.
#
# usage: wrap-subtree-check.sh [<claude-pid>]
# Without a pid the session is the nearest ancestor of this script whose argv0
# is `claude`. The subtree is every descendant of that session EXCEPT this
# script's own chain (its tool-call wrapper, itself, and its own children) and
# harness processes: a non-shell-wrapper process whose full argv matches
# WRAP_SUBTREE_HARNESS_RE (ERE; default: an `mcp-server*` path/word, a
# `…qmd[.ext] mcp` invocation, the session's `caffeinate` keep-awake, or the
# `claude-hud` statusline tree — a descendant of a name-matched process
# inherits the ignore by walking up to that match, the same rule that already
# carries an MCP launcher's ignore down to its children (HIMMEL-3265)), or a
# DIRECT child of the session that is not a shell-tool wrapper and forked
# within WRAP_SUBTREE_START_WINDOW seconds
# (default 10; 0 turns the rule off) of the session itself — the servers a
# session starts with it (`uv tool uvx … mcp-obsidian`, `graphify-mcp`,
# `uv run … server.py`) share no name but all fork ~1s after `claude`
# (HIMMEL-3265) — plus anything beneath one. Each ignored child is listed as an
# `ignored pid=…` row with why=, never hidden. A shell-tool wrapper
# (`<shell> -c source …/shell-snapshots/snapshot-…`) is never harness, whatever
# its command text says or however early it started: every command a leg runs
# is in one, so leg-spawned work is always counted. The session pid must itself be a `claude` process: an
# arbitrary live pid (a leaf, another tool) is refused, never called CLOSABLE.
# ponytail: only DESCENDANTS of the session are seen. A shell reparented to
# init/systemd (an intermediate process died first) is not attributed to the
# session and does not withhold CLOSABLE; attributing it would mean reading
# /proc/<pid>/environ, which is credential-adjacent, so it is deliberately not
# done. Tool-call shells are direct children of the session (the N35 leak
# class), so they stay visible; the complementary check is tick's orphans=
# field (console-kit/orphan-loops.sh), which lists such shells as owner `orphan`.
# ponytail: the start-time rule is a conjunction (direct child AND non-wrapper
# AND forked inside the window, from etime at 1s resolution). Its errors fall
# toward WITHHELD: an MCP server started lazily or after a `/mcp` reconnect is
# outside the window and withholds (the WITHHELD text says not to stop it). A
# cold `uv` cache makes that the COMMON case, not an exotic one: `uvx`/`uv run`
# may download and build for well over the window before the server forks.
# Observed delta on real sessions is 0-1s; the 10s default is chosen slack.
# The unsafe direction needs a leg-spawned process that is a non-wrapper direct
# child forked inside the window — i.e. a Bash tool call with no shell-snapshot
# wrapper AND a first tool call within seconds of session start; not observed.
# The same hole opens if a shell wrapper exec()s its command inside the window:
# pid, ppid and etime stay put but argv stops matching iswrap, so the replacement
# process and everything beneath it would read as harness (false CLOSABLE). Real
# wrappers keep the shell as parent of the command (a `source … && eval …` list
# is not exec-optimised), so it was not observed either; nothing here detects it.
# The launcher's own argv (the configured MCP commands) or the supervisor were
# not used: claude spawns MCP servers itself (ppid = the session, no
# supervisor), and the config that names them (~/.claude.json) holds tokens.
# ponytail: the default harness match is a heuristic over argv, so a leaked
# process literally named like an MCP server (`node …/mcp-server-x/y.js`) would
# be exempt; the leak class this gate exists for is a tool-call shell, which
# is never exempt. The same is true of `caffeinate` and `claude-hud`
# (HIMMEL-3712): a leg-started `caffeinate` not spawned by the session's own
# keep-awake would also be exempt by name alone, same tradeoff, no new
# mechanism to fix it here.
#
# READ-ONLY: this script never signals a process. Bash 3.2-compatible.
# WRAP_SUBTREE_SELF overrides the pid treated as "this script" (test seam).
# WRAP_SUBTREE_START_WINDOW: seconds after the session start within which a
# direct child counts as session-started (non-negative integer; default 10).
# PLATFORM GUARD: no .ps1 twin, by design — Linux-only (procps ps).
set -uo pipefail

case "${1:-}" in
    -h|--help)
        printf 'usage: wrap-subtree-check.sh [<claude-pid>]\n'
        exit 0 ;;
esac
root="${1:-}"
case "$root" in
    '') ;;
    *[!0-9]*) printf 'usage: wrap-subtree-check.sh [<claude-pid>]\n' >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { printf 'usage: wrap-subtree-check.sh [<claude-pid>]\n' >&2; exit 2; }

self="${WRAP_SUBTREE_SELF:-$$}"
# No backslashes: the value crosses awk -v, which processes escape sequences.
window="${WRAP_SUBTREE_START_WINDOW:-10}"
case "$window" in
    ''|*[!0-9]*)
        printf 'WITHHELD: WRAP_SUBTREE_START_WINDOW must be a non-negative integer (got %s) — not declaring CLOSABLE\n' "$window"
        exit 2 ;;
esac
harness_re="${WRAP_SUBTREE_HARNESS_RE:-(^|[ /])(mcp-server[^ ]*|[^ ]*qmd([.][a-z]+)? mcp|caffeinate|claude-hud(/[^ ]*)?)( |\$)}"

ps_out="$(ps -eo pid=,ppid=,etime=,args= 2>/dev/null)" || ps_out=""
if [ -z "$ps_out" ]; then
    printf 'WITHHELD: cannot read the process table (ps failed) — not declaring CLOSABLE\n'
    exit 2
fi

result="$(printf '%s\n' "$ps_out" | awk -v root="$root" -v self="$self" -v hre="$harness_re" -v win="$window" '
function iswrap(a) {
    return a ~ /^[^ ]*(bash|zsh|sh) -c (source|\.) [^ ]*shell-snapshots\/snapshot-(bash|zsh)-/
}
function isclaude(a,   t, n, b) {
    split(a, t, " ")
    n = split(t[1], b, "/")
    return b[n] == "claude"
}
function isharness(p) {
    if (iswrap(arg[p])) return 0
    return arg[p] ~ hre
}
# [[DD-]HH:]MM:SS -> seconds; -1 for anything else (fails closed in isearly)
function secs(e,   x, t, n, s, k, d) {
    if (e !~ /^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9]+$/) return -1
    d = 0
    if (index(e, "-")) { split(e, x, "-"); d = x[1]; e = x[2] }
    n = split(e, t, ":"); s = 0
    for (k = 1; k <= n; k++) s = s * 60 + t[k]
    return d * 86400 + s
}
# A direct child of the session (the caller checks that), not a tool-call
# wrapper, forked within win seconds of the session itself.
function isearly(p,   a, b, d) {
    if (win + 0 == 0 || iswrap(arg[p])) return 0
    a = secs(et[root]); b = secs(et[p])
    if (a < 0 || b < 0) return 0
    d = a - b
    return d >= 0 && d <= win + 0
}
BEGIN { maxh = 4096 }
{
    pid = $1; ppid[pid] = $2; et[pid] = $3
    a = $0
    for (i = 0; i < 3; i++) sub(/^[ \t]*[^ \t]+[ \t]+/, "", a)
    arg[pid] = a
    order[++np] = pid
}
END {
    if (root == "") {
        p = self
        for (h = 0; h < maxh; h++) {
            p = ppid[p]
            if (p == "" || p == 0) break
            if (isclaude(arg[p])) { root = p; break }
        }
    }
    if (root == "" || !(root in ppid)) { print "NOROOT"; exit }
    if (!isclaude(arg[root])) { print "NOTCLAUDE"; exit }
    # This script'"'"'s own chain: itself and every ancestor below the session.
    p = self
    for (h = 0; h < maxh && p != "" && p != 0 && p != root; h++) { chain[p] = 1; p = ppid[p] }
    n = 0
    for (i = 1; i <= np; i++) {
        pid = order[i]
        if (pid == root) continue
        p = pid; under = 0; skip = (pid in chain); harness = 0; why = ""; via = ""
        for (h = 0; h < maxh; h++) {
            if (p == self) skip = 1
            if (!harness && isharness(p)) { harness = 1; why = "name-match"; via = p }
            q = ppid[p]
            if (q == root && !harness && isearly(p)) { harness = 1; why = "session-start"; via = p }
            if (q == root) { under = 1; break }
            if (q == "" || q == 0) break
            p = q
        }
        # Ran out of hops without reaching the session or init: cannot prove this
        # process is outside the subtree, so count it (fail closed).
        if (h >= maxh) under = 1
        if (!under || skip) continue
        cmd = substr(arg[pid], 1, 100)
        if (harness) {
            m++
            irows = irows sprintf("  ignored pid=%s ppid=%s etime=%s why=%s%s cmd=%s\n", pid, ppid[pid], et[pid], why, (via == pid ? "" : " via=" via), cmd)
            continue
        }
        n++
        rows = rows sprintf("  pid=%s ppid=%s etime=%s cmd=%s\n", pid, ppid[pid], et[pid], cmd)
    }
    printf "ROOT %s\nCOUNT %d\nIGNORED %d\n%s%s", root, n, m, rows, irows
}')"

case "$result" in
    NOROOT*)
        if [ -n "$root" ]; then
            printf 'WITHHELD: claude pid %s is not in the process table — not declaring CLOSABLE\n' "$root"
        else
            printf 'WITHHELD: no claude session found above this script — pass the session pid; not declaring CLOSABLE\n'
        fi
        exit 2 ;;
    NOTCLAUDE*)
        printf 'WITHHELD: pid %s is not a claude session — pass the session pid; not declaring CLOSABLE\n' "$root"
        exit 2 ;;
esac

found="$(printf '%s\n' "$result" | sed -n 's/^ROOT //p')"
count="$(printf '%s\n' "$result" | sed -n 's/^COUNT //p')"
ignored="$(printf '%s\n' "$result" | sed -n 's/^IGNORED //p')"
if [ -z "$found" ] || [ -z "$count" ] || [ -z "$ignored" ]; then
    printf 'WITHHELD: cannot parse the process table — not declaring CLOSABLE\n'
    exit 2
fi
if [ "$count" -eq 0 ]; then
    if [ "$ignored" -eq 0 ]; then
        printf 'CLOSABLE: no non-harness process under claude pid %s\n' "$found"
    else
        printf 'CLOSABLE: no non-harness process under claude pid %s (%s harness-owned children ignored)\n' "$found" "$ignored"
        printf '%s\n' "$result" | sed -n '/^  ignored pid=/p'
    fi
    exit 0
fi
printf 'WITHHELD: %s process(es) still alive under claude pid %s — TaskStop every background task and agent you spawned, then re-run (never stop a process you did not start, e.g. a session MCP server: report it to the console instead)\n' "$count" "$found"
printf '%s\n' "$result" | sed -n '/^  pid=/p'
printf '%s\n' "$result" | sed -n '/^  ignored pid=/p'
exit 1
