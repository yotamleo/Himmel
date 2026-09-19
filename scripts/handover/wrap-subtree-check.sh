#!/usr/bin/env bash
# wrap-subtree-check.sh — the structural wrap/halt gate (HIMMEL-2761).
#
# A leg (or judge) that declares itself closable must first prove its own
# process subtree is empty. TaskStop on an agent does NOT reap the background
# shell that agent spawned (fleet halt 2026-09-07: leg N35 reported WRAPPED with
# a poll loop still alive 2h10m later), and the console cannot kill it — so the
# closable-window banner is this script's output, never hand-typed:
#   CLOSABLE: no non-harness process under claude pid <pid>     rc 0
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
# harness MCP servers: a non-shell-wrapper process whose first two argv tokens
# match WRAP_SUBTREE_HARNESS_RE (ERE, default `mcp|qmd`), plus anything beneath
# one. A shell-tool wrapper (`<shell> -c source …/shell-snapshots/snapshot-…`)
# is never harness, whatever its command text says.
#
# READ-ONLY: this script never signals a process. Bash 3.2-compatible.
# WRAP_SUBTREE_SELF overrides the pid treated as "this script" (test seam).
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
harness_re="${WRAP_SUBTREE_HARNESS_RE:-mcp|qmd}"

ps_out="$(ps -eo pid=,ppid=,etime=,args= 2>/dev/null)" || ps_out=""
if [ -z "$ps_out" ]; then
    printf 'WITHHELD: cannot read the process table (ps failed) — not declaring CLOSABLE\n'
    exit 2
fi

result="$(printf '%s\n' "$ps_out" | awk -v root="$root" -v self="$self" -v hre="$harness_re" '
function iswrap(a) {
    return a ~ /^[^ ]*(bash|zsh|sh) -c (source|\.) [^ ]*shell-snapshots\/snapshot-(bash|zsh)-/
}
function isclaude(a,   t, n, b) {
    split(a, t, " ")
    n = split(t[1], b, "/")
    return b[n] == "claude"
}
function isharness(p,   t, s) {
    if (iswrap(arg[p])) return 0
    split(arg[p], t, " ")
    s = t[1] " " t[2]
    return s ~ hre
}
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
        for (h = 0; h < 64; h++) {
            p = ppid[p]
            if (p == "" || p == 0) break
            if (isclaude(arg[p])) { root = p; break }
        }
    }
    if (root == "" || !(root in ppid)) { print "NOROOT"; exit }
    # This script'"'"'s own chain: itself and every ancestor below the session.
    p = self
    for (h = 0; h < 64 && p != "" && p != 0 && p != root; h++) { chain[p] = 1; p = ppid[p] }
    n = 0
    for (i = 1; i <= np; i++) {
        pid = order[i]
        if (pid == root) continue
        p = pid; under = 0; skip = (pid in chain); harness = 0
        for (h = 0; h < 64; h++) {
            if (p == self) skip = 1
            if (isharness(p)) harness = 1
            q = ppid[p]
            if (q == root) { under = 1; break }
            if (q == "" || q == 0) break
            p = q
        }
        if (!under || skip || harness) continue
        n++
        cmd = substr(arg[pid], 1, 100)
        rows = rows sprintf("  pid=%s ppid=%s etime=%s cmd=%s\n", pid, ppid[pid], et[pid], cmd)
    }
    printf "ROOT %s\nCOUNT %d\n%s", root, n, rows
}')"

case "$result" in
    NOROOT*)
        if [ -n "$root" ]; then
            printf 'WITHHELD: claude pid %s is not in the process table — not declaring CLOSABLE\n' "$root"
        else
            printf 'WITHHELD: no claude session found above this script — pass the session pid; not declaring CLOSABLE\n'
        fi
        exit 2 ;;
esac

found="$(printf '%s\n' "$result" | sed -n 's/^ROOT //p')"
count="$(printf '%s\n' "$result" | sed -n 's/^COUNT //p')"
if [ -z "$found" ] || [ -z "$count" ]; then
    printf 'WITHHELD: cannot parse the process table — not declaring CLOSABLE\n'
    exit 2
fi
if [ "$count" -eq 0 ]; then
    printf 'CLOSABLE: no non-harness process under claude pid %s\n' "$found"
    exit 0
fi
printf 'WITHHELD: %s process(es) still alive under claude pid %s — TaskStop every background task and agent you spawned, then re-run\n' "$count" "$found"
printf '%s\n' "$result" | sed -n '/^  pid=/p'
exit 1
