#!/usr/bin/env bash
# resolve-node.sh — locate an absolute `node` binary at RUNTIME, cross-platform.
#
# WHY: GUI-launched Claude Code (macOS app, Windows) starts hooks in a shell with
# a minimal PATH that often lacks node — so a SessionStart hook wired as a bare
# `node …` (or a setup-time-substituted absolute path that a later `winget`/nvm/
# homebrew upgrade moved) fails every session. Resolving at runtime, every call,
# survives node upgrades and a PATH-less launch. See `run-node.sh` (the wrapper
# the caveman hooks route through) and `scripts/himmel-doctor.sh` C1.
#
# Source this file, then call `resolve_node`:
#   node="$(resolve_node)" || { echo "no node"; exit 1; }
# Prints the absolute path on stdout + returns 0 on success; returns 1 + empty
# stdout if no node is found. bash 3.2-safe (no mapfile / associative arrays).
#
# Test seams (used only by scripts/lib/test-resolve-node.sh):
#   RESOLVE_NODE_PROBE_DIRS  colon-separated dir list that REPLACES the built-in
#                            absolute-location candidates (PATH is still tried first).
#   RESOLVE_NODE_NVM_ROOT    override the nvm versions root (default ~/.nvm/versions/node).

resolve_node() {
    # 1) PATH — the common case (and what setup-time invocations see).
    if command -v node >/dev/null 2>&1; then
        command -v node
        return 0
    fi

    # 2) Well-known absolute locations (macOS homebrew, Linux, Windows). The
    #    test seam replaces this list wholesale so cases stay hermetic.
    local dirs
    if [ "${RESOLVE_NODE_PROBE_DIRS+set}" = set ]; then
        dirs="$RESOLVE_NODE_PROBE_DIRS"
    else
        dirs="/opt/homebrew/bin:/usr/local/bin:/usr/bin:${HOME:-}/.local/bin:/c/Program Files/nodejs:${LOCALAPPDATA:-}/nodejs"
    fi
    local d save_ifs="$IFS"
    IFS=:
    for d in $dirs; do
        [ -n "$d" ] || continue
        if [ -x "$d/node" ]; then printf '%s\n' "$d/node"; IFS="$save_ifs"; return 0; fi
        if [ -x "$d/node.exe" ]; then printf '%s\n' "$d/node.exe"; IFS="$save_ifs"; return 0; fi
    done
    IFS="$save_ifs"

    # 3) nvm — newest installed version. sort -V (NOT lexical: "v8" > "v20"
    #    lexically would pick an EOL node that can't run modern ESM).
    local nvm_root="${RESOLVE_NODE_NVM_ROOT:-${HOME:-}/.nvm/versions/node}"
    if [ -d "$nvm_root" ]; then
        # printf-on-glob (not `ls`) so SC2012 stays quiet; a non-matching glob
        # stays literal and fails the -x test below, so no false hit.
        local newest
        newest="$(printf '%s\n' "$nvm_root"/*/bin/node | sort -V | tail -1)"
        if [ -n "$newest" ] && [ -x "$newest" ]; then printf '%s\n' "$newest"; return 0; fi
    fi

    # 4) fnm — newest installed version (its layout: <dir>/node-versions/*/installation/bin/node).
    local fnm_root="${FNM_DIR:-${HOME:-}/.local/share/fnm}"
    if [ -d "$fnm_root/node-versions" ]; then
        local fnm_newest
        fnm_newest="$(printf '%s\n' "$fnm_root"/node-versions/*/installation/bin/node | sort -V | tail -1)"
        if [ -n "$fnm_newest" ] && [ -x "$fnm_newest" ]; then printf '%s\n' "$fnm_newest"; return 0; fi
    fi

    return 1
}
