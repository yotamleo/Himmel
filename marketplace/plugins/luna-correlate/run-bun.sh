#!/usr/bin/env bash
# run-bun.sh — runtime bun launcher for this plugin's MCP server. Resolves an
# absolute `bun` at spawn time and execs it, so the server starts even on a
# PATH-less GUI launch (macOS dock / Windows shortcut) where a bare `bun`
# command silently fails to start and the server's tools vanish with no error
# (issue #121 C6). Mirrors the himmel C1/P4 wrapper model
# (scripts/lib/run-node.sh, run-pwsh.sh).
#
# Shipped PER-PLUGIN (not in the himmel repo's scripts/lib) on purpose: a
# .mcp.json installed to the plugin cache can only anchor on
# ${CLAUDE_PLUGIN_ROOT} and cannot reach the himmel checkout. Wired from
# .mcp.json as: command "bash", args ["${CLAUDE_PLUGIN_ROOT}/run-bun.sh", …].
# A trailing-token `bash` is not PATH-fragile (it is in the base GUI PATH on
# every platform), so /himmel-doctor C6 no longer flags the server.
#
# FAIL-CLOSED: unlike the fail-open hook wrappers, an MCP server that cannot
# find its interpreter genuinely cannot run — so on a missing bun we write ONE
# breadcrumb and exit 127, surfacing the server as failed-to-start (honest)
# rather than pretending success. bash 3.2-safe.
#
# Test seam (scripts/lib/test-run-bun.sh): RESOLVE_BUN_PROBE_DIRS — a
# colon-separated dir list that REPLACES the built-in candidates (PATH first).
set -u

_resolve_bun() {
    # 1) PATH — the common case (and what a terminal launch sees).
    if command -v bun >/dev/null 2>&1; then command -v bun; return 0; fi

    # 2) Well-known absolute locations. `~/.bun/bin` is bun's default install on
    #    every platform incl. Windows (Git Bash $HOME), so it covers the GUI-PATH
    #    case there too. (No `$LOCALAPPDATA` candidate: its `C:\…` colon is eaten
    #    by the `IFS=:` split below, so it could never match anyway.)
    local dirs d save_ifs="$IFS"
    if [ "${RESOLVE_BUN_PROBE_DIRS+set}" = set ]; then
        dirs="$RESOLVE_BUN_PROBE_DIRS"
    else
        dirs="${BUN_INSTALL:-${HOME:-}/.bun}/bin:${HOME:-}/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin"
    fi
    IFS=:
    for d in $dirs; do
        [ -n "$d" ] || continue
        if [ -x "$d/bun" ]; then printf '%s\n' "$d/bun"; IFS="$save_ifs"; return 0; fi
        if [ -x "$d/bun.exe" ]; then printf '%s\n' "$d/bun.exe"; IFS="$save_ifs"; return 0; fi
    done
    IFS="$save_ifs"
    return 1
}

_bun="$(_resolve_bun)" || _bun=""
if [ -n "$_bun" ]; then
    exec "$_bun" "$@"
fi

# No bun: fail-closed with a breadcrumb for /himmel-doctor C6 / a curious operator.
_log_dir="${CLAUDE_DIR:-${HOME:-.}/.claude}"
mkdir -p "$_log_dir" 2>/dev/null || true
printf '%s bun not found; MCP server not started: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '?')" "$*" \
    >> "$_log_dir/himmel-bun.log" 2>/dev/null || true
exit 127
