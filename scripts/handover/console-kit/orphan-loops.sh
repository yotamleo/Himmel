#!/usr/bin/env bash
# orphan-loops.sh — read-only inventory of long-lived shell-tool wrappers
# (HIMMEL-2761), joined to the owning claude session.
#
# Claude Code runs every Bash-tool call as `<shell> -c source
# ~/.claude/shell-snapshots/snapshot-<shell>-….sh … && eval '<command>'`.
# TaskStop on an agent does NOT reap the background shell that agent spawned
# (fleet halt 2026-09-07: a poll loop outlived its wrapped leg by 2h10m), and a
# console cannot kill it, so the only defence is to SEE it at the next tick
# instead of at reboot time. Default output is one line, `orphans=<summary>`:
#   orphans=none                         no wrapper older than the floor
#   orphans=<owner>:<count>/<oldest>m,…  wrappers per owning session name
#   orphans=?                            the process table could not be read
# <owner> is the session name (claude_sessions census, `pid<N>` when a session
# has no -n) reached by walking the wrapper's ppid chain, or the literal
# `orphan` when the chain never reaches a live claude session (reparented to
# init/systemd). The age floor is 30 minutes: a live tool call is normal, so
# only a wrapper older than TICK_ORPHAN_MIN (or --min) counts.
#
# --list prints one `pid=<pid> owner=<name> age=<n>m` row per counted wrapper
# instead of the summary, so the console has a pid to hand to the leg.
#
# READ-ONLY: this script never signals a process. Bash 3.2-compatible.
# PLATFORM GUARD: no .ps1 twin, by design — Linux-only (procps ps, /proc), like
# the rest of the console kit.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$(cd "$HERE/../../.." && pwd)}"

usage() {
    cat <<'USAGE'
usage: orphan-loops.sh [--list] [--min MINUTES]

env: TICK_ORPHAN_MIN (default 30), REPO, CLAUDE_SESSIONS_PROC
USAGE
}

min="${TICK_ORPHAN_MIN:-30}"
list=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --list) list=1; shift ;;
        --min)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            min="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
case "$min" in ''|*[!0-9]*) min=30 ;; esac

# shellcheck source=../../lanes/lib/claude-sessions.sh
. "$REPO/scripts/lanes/lib/claude-sessions.sh"

# pid=name pairs for every live claude session; names sanitized so they can
# neither break the pair encoding nor forge an output field.
#
# A failed or empty census cannot tell a session-owned wrapper from an orphan:
# known=0 then reads every unresolved owner as `?`, never `orphan`.
known=1
census="$(claude_sessions 2>/dev/null)" || known=0
[ -n "$census" ] || known=0
sessmap="$(printf '%s\n' "$census" | awk -F'\t' '
$1 ~ /^#/ || $1 == "" { next }
{
    name = $2
    if (name == "") name = "pid" $1
    gsub(/[^A-Za-z0-9_.-]/, "_", name)
    printf "%s%s=%s", (n++ ? "," : ""), $1, name
}')"

ps_out="$(ps -eo pid=,ppid=,etime=,args= 2>/dev/null)" || ps_out=""
if [ -z "$ps_out" ]; then
    [ "$list" -eq 1 ] || printf 'orphans=?\n'
    exit 0
fi

printf '%s\n' "$ps_out" | awk -v sessmap="$sessmap" -v min="$min" -v list="$list" -v known="$known" '
function mins(e,   d, t, n, x) {
    d = 0
    if (index(e, "-")) { split(e, x, "-"); d = x[1]; e = x[2] }
    n = split(e, t, ":")
    if (n == 3) return d * 1440 + t[1] * 60 + t[2]
    return d * 1440 + t[1]
}
BEGIN {
    n = split(sessmap, pairs, ",")
    for (i = 1; i <= n; i++) {
        eq = index(pairs[i], "=")
        if (eq > 0) sess[substr(pairs[i], 1, eq - 1)] = substr(pairs[i], eq + 1)
    }
}
{
    pid = $1; ppid[pid] = $2; age[pid] = mins($3)
    a = $0
    for (i = 0; i < 3; i++) sub(/^[ \t]*[^ \t]+[ \t]+/, "", a)
    # Anchored on the wrapper shape so a command that merely MENTIONS a
    # snapshot path (a grep for this very thing) is not counted.
    if (a ~ /^[^ ]*(bash|zsh|sh) -c (source|\.) [^ ]*shell-snapshots\/snapshot-(bash|zsh)-/) wrap[++nw] = pid
}
END {
    for (i = 1; i <= nw; i++) {
        pid = wrap[i]
        if (age[pid] < min) continue
        owner = (known ? "orphan" : "?"); p = pid
        for (hops = 0; hops < 64; hops++) {
            p = ppid[p]
            if (p == "" || p == 0) break
            if (p in sess) { owner = sess[p]; break }
        }
        if (list) { printf "pid=%s owner=%s age=%dm\n", pid, owner, age[pid]; continue }
        if (!(owner in cnt)) order[++no] = owner
        cnt[owner]++
        if (age[pid] > oldest[owner]) oldest[owner] = age[pid]
    }
    if (list) exit
    if ("?" in cnt) { print "orphans=?"; exit }
    out = ""
    for (i = 1; i <= no; i++) out = out (i > 1 ? "," : "") order[i] ":" cnt[order[i]] "/" oldest[order[i]] "m"
    print "orphans=" (out == "" ? "none" : out)
}'
