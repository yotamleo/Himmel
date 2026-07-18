#!/usr/bin/env bash
# reap-mcp-fleet.sh (HIMMEL-741; HIMMEL-840 descendant-reap primitive) -
# cross-platform twin of reap-mcp-fleet.ps1.
#
# The app-server-fleet FINGERPRINT (Win32_Process ancestry walk with codex
# path markers) is a Windows-only concern - the default (no-args) mode's
# orphan scan forwards entirely to the .ps1 on Windows; on other platforms
# Codex reaps its own app-server children, so that scan is skipped there.
#
# The HIMMEL-840 descendant-reap PRIMITIVE (--root-pid) is NOT Windows-only:
# dispatch-codex-exec.sh's own EXIT trap calls it on every platform right
# after its codex child exits. On Windows this still forwards to the .ps1
# (Win32_Process + CreationDate is the authoritative source there); on
# mac/Linux this file carries a REAL implementation (`ps -eo pid,ppid[,etimes]`
# + a pure BFS walk, mirroring Get-DescendantPids in the .ps1) - not a thin
# pwsh shim. The registry-driven maintenance scan (default mode) is likewise
# real on every platform (it is just `ps` + the job registry).
#
# USAGE:
#   scripts/codex/reap-mcp-fleet.sh                                    # report-only (default)
#   scripts/codex/reap-mcp-fleet.sh --kill                             # reap the above
#   scripts/codex/reap-mcp-fleet.sh --root-pid <pid> [--started-at <epoch>] [--kill]
#                                                                       # HIMMEL-840: report/reap descendants of one root pid
#
# ENVIRONMENT:
#   CODEX_JOBS_DIR   Override the job registry dir (tests; default
#                    $HOME/.himmel/state/codex-exec-jobs).
#
# Bash 3.2 safe. Sourcing this file (instead of executing it) defines the
# pure functions below WITHOUT running production code - the hermetic test
# seam (mirrors reap-mcp-fleet.ps1's -AsLibrary and shared-branch-lock.sh's
# own sourcing guard).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1="$SCRIPT_DIR/reap-mcp-fleet.ps1"
JOBS_DIR="${CODEX_JOBS_DIR:-$HOME/.himmel/state/codex-exec-jobs}"

_reap_platform() {
    case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
        msys*|cygwin*|win32*|MINGW*|MSYS*) echo windows ;;
        *) echo other ;;
    esac
}

# --- pure descendant walk (bash 3.2-safe; the hermetic test calls this
# directly via the sourcing seam) ---------------------------------------
# _reap_descendants <table> <root-pid> [<started-at-epoch>]
# <table>: one line per process, "<pid> <ppid> <start-epoch-or-dash>"
# (space-separated). Prints one descendant pid per line (BFS discovery
# order). $root_pid need not appear in <table> (it is typically already
# dead - that is why we are reaping); a direct child still records the dead
# root's pid as its own ppid, which is all the walk needs. <started-at>,
# when given, guards pid-reuse: a candidate whose own start predates the job
# is excluded and its subtree is NOT traversed (conservative under-reap).
_reap_descendants() {
    _rd_table="$1"
    _rd_root="$2"
    _rd_started="${3:-}"
    _rd_frontier="$_rd_root"
    _rd_seen=" $_rd_root "
    _rd_depth=0
    while [ -n "$_rd_frontier" ] && [ "$_rd_depth" -lt 64 ]; do
        _rd_depth=$((_rd_depth + 1))
        _rd_next=""
        for _rd_parent in $_rd_frontier; do
            # <<EOF (not `| while read`) - a piped while-loop runs in a
            # subshell in bash, which would lose _rd_seen/_rd_next mutations
            # once the loop ends.
            while read -r _rd_pid _rd_ppid _rd_start; do
                [ -z "$_rd_pid" ] && continue
                [ "$_rd_ppid" = "$_rd_parent" ] || continue
                case "$_rd_seen" in *" $_rd_pid "*) continue ;; esac
                if [ -n "$_rd_started" ] && [ -n "$_rd_start" ] && [ "$_rd_start" != "-" ]; then
                    if [ "$_rd_start" -lt "$_rd_started" ] 2>/dev/null; then
                        continue   # predates the job - not ours (pid-reuse guard)
                    fi
                fi
                _rd_seen="$_rd_seen$_rd_pid "
                _rd_next="$_rd_next $_rd_pid"
                printf '%s\n' "$_rd_pid"
            done <<EOF
$_rd_table
EOF
        done
        _rd_frontier="$_rd_next"
    done
}

# _reap_ps_table - print the live "<pid> <ppid> <start-epoch-or-dash>" table
# from the real process list (non-Windows production path only; not used by
# the hermetic test, which feeds _reap_descendants a fixture directly).
_reap_ps_table() {
    _rpt_now="$(date +%s)"
    if _rpt_raw="$(ps -eo pid,ppid,etimes 2>/dev/null)" && [ -n "$_rpt_raw" ]; then
        printf '%s\n' "$_rpt_raw" | awk -v now="$_rpt_now" '$1+0==$1 && $2+0==$2 {print $1, $2, (now-$3)}'
        return 0
    fi
    # BSD/macOS ps has no `etimes` keyword - degrade to pid/ppid only. The
    # pid-reuse guard becomes a no-op on this platform (best-effort, not
    # load-bearing for the walk's own correctness).
    ps -eo pid,ppid 2>/dev/null | awk '$1+0==$1 && $2+0==$2 {print $1, $2, "-"}'
}

# _reap_registry_scan - non-Windows twin of the .ps1's registry-driven
# maintenance block (visibility surface, HIMMEL-840 point 4). Reads
# $JOBS_DIR/*.json (node -e, mirroring companion-liveness.sh's own JSON-
# parsing convention) and, for each entry whose codex_pid is dead, reports
# (default) / reaps (--kill) its descendants, dropping the entry under
# --kill only (a report-only pass must not mutate state). Reads $_kill (set
# by _reap_main).
_reap_registry_scan() {
    if [ ! -d "$JOBS_DIR" ]; then
        echo "[reap-mcp-fleet] registry: 0 job(s) (no job registry dir: $JOBS_DIR)."
        return 0
    fi
    _rrs_node=""
    for c in node node.exe; do
        if command -v "$c" >/dev/null 2>&1; then _rrs_node="$c"; break; fi
    done
    if [ -z "$_rrs_node" ]; then
        echo "[reap-mcp-fleet] registry: cannot scan (node not found on PATH)." >&2
        return 0
    fi
    _rrs_table="$(_reap_ps_table)"
    _rrs_live=0
    _rrs_dead=0
    _rrs_fleet_total=0
    for _rrs_jf in "$JOBS_DIR"/*.json; do
        [ -f "$_rrs_jf" ] || continue
        _rrs_line="$("$_rrs_node" -e '
            const fs = require("fs");
            let o;
            try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(0); }
            if (!o.codex_pid) process.exit(0);
            process.stdout.write(String(o.codex_pid) + "\t" + String(o.started_at || ""));
        ' "$_rrs_jf" 2>/dev/null)"
        [ -n "$_rrs_line" ] || continue
        _rrs_pid="${_rrs_line%%$'\t'*}"
        _rrs_started="${_rrs_line#*$'\t'}"
        if printf '%s\n' "$_rrs_table" | awk -v p="$_rrs_pid" '$1==p{f=1} END{exit !f}'; then
            _rrs_live=$((_rrs_live + 1))
            continue
        fi
        _rrs_dead=$((_rrs_dead + 1))
        _rrs_desc="$(_reap_descendants "$_rrs_table" "$_rrs_pid" "$_rrs_started")"
        if [ -n "$_rrs_desc" ]; then
            _rrs_dcount=$(printf '%s\n' "$_rrs_desc" | grep -c .)
            _rrs_fleet_total=$((_rrs_fleet_total + _rrs_dcount))
            echo "[reap-mcp-fleet] registry job $(basename "$_rrs_jf") (codex pid $_rrs_pid, dead): $_rrs_dcount descendant fleet process(es)"
            if [ "$_kill" -eq 1 ]; then
                printf '%s\n' "$_rrs_desc" | while read -r _rrs_d; do
                    if [ -n "$_rrs_d" ]; then kill -9 "$_rrs_d" 2>/dev/null || true; fi
                done
            fi
        fi
        [ "$_kill" -eq 1 ] && rm -f "$_rrs_jf"
    done
    echo "[reap-mcp-fleet] registry: $_rrs_live job(s) live, $_rrs_dead job(s) dead ($_rrs_fleet_total descendant fleet proc(s))."
}

_reap_main() {
    _platform="$(_reap_platform)"

    _kill=0
    _root_pid=""
    _started_at=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --kill) _kill=1; shift ;;
            --root-pid) [ $# -ge 2 ] || { echo "reap-mcp-fleet: missing value for $1" >&2; return 1; }; _root_pid="$2"; shift 2 ;;
            --root-pid=*) _root_pid="${1#--root-pid=}"; shift ;;
            --started-at) [ $# -ge 2 ] || { echo "reap-mcp-fleet: missing value for $1" >&2; return 1; }; _started_at="$2"; shift 2 ;;
            --started-at=*) _started_at="${1#--started-at=}"; shift ;;
            -h|--help) sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; return 0 ;;
            *) echo "ERR: unknown argument: $1" >&2; return 1 ;;
        esac
    done

    if [ "$_platform" = "windows" ]; then
        _pwsh_bin=""
        for c in pwsh pwsh.exe powershell.exe; do
            if command -v "$c" >/dev/null 2>&1; then _pwsh_bin="$c"; break; fi
        done
        if [ -z "$_pwsh_bin" ]; then
            echo "ERR: pwsh not found on PATH - run scripts/codex/reap-mcp-fleet.ps1 directly." >&2
            return 1
        fi
        _ps_args=()
        [ -n "$_root_pid" ] && _ps_args+=("-RootPid" "$_root_pid")
        [ -n "$_started_at" ] && _ps_args+=("-StartedAt" "$_started_at")
        [ "$_kill" -eq 1 ] && _ps_args+=("-Kill")
        "$_pwsh_bin" -NoProfile -ExecutionPolicy Bypass -File "$PS1" ${_ps_args[@]+"${_ps_args[@]}"}
        return $?
    fi

    # --- non-Windows: real descendant-reap + registry scan (no app-server
    # fingerprint - that fingerprint is Win32_Process-specific).
    if [ -n "$_root_pid" ]; then
        _table="$(_reap_ps_table)"
        # Entry-point safety parity with the registry-scan path (which skips a
        # job whose codex_pid is still present in the table): a caller-supplied
        # root pid that is itself still alive must abort, not walk descendants -
        # a live root's own fleet is legitimately in use, not a leak.
        if printf '%s\n' "$_table" | awk -v p="$_root_pid" '$1==p{f=1} END{exit !f}'; then
            echo "[reap-mcp-fleet] pid $_root_pid is still alive - skipping descendant walk (only reap descendants of a dead root)."
            return 0
        fi
        _descendants="$(_reap_descendants "$_table" "$_root_pid" "$_started_at")"
        if [ -z "$_descendants" ]; then
            echo "[reap-mcp-fleet] no live descendants of pid $_root_pid."
            return 0
        fi
        _count="$(printf '%s\n' "$_descendants" | grep -c .)"
        echo "[reap-mcp-fleet] $_count descendant process(es) of pid $_root_pid:"
        printf '%s\n' "$_descendants" | while read -r _d; do
            [ -n "$_d" ] && echo "  pid $_d"
        done
        if [ "$_kill" -ne 1 ]; then
            echo "[reap-mcp-fleet] report-only (default). Re-run with --kill to terminate the above."
            return 0
        fi
        printf '%s\n' "$_descendants" | while read -r _d; do
            if [ -n "$_d" ]; then kill -9 "$_d" 2>/dev/null || true; fi
        done
        echo "[reap-mcp-fleet] terminated descendant(s) of pid $_root_pid."
        return 0
    fi

    echo "[reap-mcp-fleet] non-Windows platform - the app-server MCP-fleet fingerprint is Windows-only; running the registry-driven job scan only."
    _reap_registry_scan
}

# Sourcing guard (bash 3.2-safe form of "is this file executed, not
# sourced"), mirroring shared-branch-lock.sh's own _sbl_main guard.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    _reap_main "$@"
    exit $?
fi
