#!/usr/bin/env bash
# resolve-node.sh — locate an absolute `node` binary at RUNTIME, cross-platform.
#
# WHY: GUI-launched Claude Code (macOS app, Windows) starts hooks in a shell with
# a minimal PATH that often lacks node — so a SessionStart hook wired as a bare
# `node …` (or a setup-time-substituted absolute path that a later `winget`/nvm/
# homebrew upgrade moved) fails every session. Resolving at runtime, every call,
# survives node upgrades and a PATH-less launch. See `run-node.sh` (the wrapper
# hook commands route through) and `scripts/himmel-doctor.sh`.
#
# Source this file, then call `resolve_node`:
#   node="$(resolve_node)" || { echo "no node"; exit 1; }
# Prints the absolute path on stdout + returns 0 on success; returns 1 + empty
# stdout if no node is found. bash 3.2-safe (no mapfile / associative arrays).
#
# Test seams (used only by scripts/lib/test-resolve-node.sh):
#   RESOLVE_NODE_PROBE_DIRS  colon-separated dir list that REPLACES the built-in
#                            OTHER-absolute-location candidates checked AFTER
#                            PATH (step 3) — NOT the nvm-windows candidates
#                            (NVM_SYMLINK / /c/nvm4w/nodejs) checked before
#                            PATH in step 1, which stay live under this seam
#                            (codex CR round 2, HIMMEL-2077: this seam used to
#                            also disable step 1 entirely, contradicting this
#                            very contract). Step 1 is controlled by NVM_SYMLINK
#                            directly, plus RESOLVE_NODE_NVM4W_DIR below for its
#                            hardcoded default.
#   RESOLVE_NODE_NVM4W_DIR   override /c/nvm4w/nodejs, nvm-windows' own default
#                            install location (unconditionally probed in step 1
#                            otherwise) — set to "" to disable it for a
#                            hermetic test on a machine where it is real.
#   RESOLVE_NODE_NVM_ROOT    override the nvm versions root (default ~/.nvm/versions/node).

resolve_node() {
    # 1) nvm-windows ONLY, ahead of PATH: NVM_SYMLINK (default C:\nvm4w\nodejs)
    #    is the operator's CHOSEN version, and /c/nvm4w/nodejs is that same
    #    tool's own default install location — both HIMMEL-2013 nvm-windows
    #    conventions, not a foreign version manager's choice. PATH is checked
    #    AFTER this (below), not before it, so a stale winget/MSI node sitting
    #    on PATH cannot beat nvm-windows (HIMMEL-2077: PATH used to run first,
    #    silently re-breaking HIMMEL-2013 whenever the stale install also
    #    happened to be on PATH). Scoped to ONLY these two nvm-windows paths —
    #    NOT the rest of the well-known-locations list in step 3 — because
    #    those are generic cross-platform paths (/usr/bin, homebrew, a user's
    #    ~/.local/bin) that a DIFFERENT operator may have deliberately put
    #    behind a hand-picked PATH entry (a Unix version manager, asdf shims,
    #    etc); promoting that whole list ahead of PATH regressed that case
    #    (codex CR round on HIMMEL-2077). Backslashes → slashes so the -x
    #    probe works under Git Bash, and a drive-letter prefix (C:/x) is
    #    rewritten to MSYS form (/c/x).
    local nvmw_dirs nvm_symlink="${NVM_SYMLINK:-}"
    nvm_symlink="${nvm_symlink//\\//}"
    case "$nvm_symlink" in
        [A-Za-z]:/*) nvm_symlink="/$(printf '%s' "${nvm_symlink%%:*}" | tr '[:upper:]' '[:lower:]')${nvm_symlink#?:}" ;;
    esac
    nvmw_dirs="${nvm_symlink}:${RESOLVE_NODE_NVM4W_DIR-/c/nvm4w/nodejs}"
    local d save_ifs="$IFS"
    IFS=:
    for d in $nvmw_dirs; do
        [ -n "$d" ] || continue
        if [ -x "$d/node" ]; then printf '%s\n' "$d/node"; IFS="$save_ifs"; return 0; fi
        if [ -x "$d/node.exe" ]; then printf '%s\n' "$d/node.exe"; IFS="$save_ifs"; return 0; fi
    done
    IFS="$save_ifs"

    # 2) PATH — the common case (and what setup-time invocations see) once the
    #    operator's explicitly-chosen nvm-windows install has had first look.
    if command -v node >/dev/null 2>&1; then
        command -v node
        return 0
    fi

    # 3) Other well-known absolute locations (macOS homebrew, Linux, Windows),
    #    a PATH fallback exactly as before HIMMEL-2077 — these are generic
    #    system paths, not an operator's explicit version choice, so they stay
    #    behind PATH. The test seam replaces this list wholesale so cases stay
    #    hermetic; `dirs` is walked with IFS=:, so a bare colon in the path
    #    would split it in half.
    local dirs
    if [ "${RESOLVE_NODE_PROBE_DIRS+set}" = set ]; then
        dirs="$RESOLVE_NODE_PROBE_DIRS"
    else
        dirs="/opt/homebrew/bin:/usr/local/bin:/usr/bin:${HOME:-}/.local/bin:/c/Program Files/nodejs:${LOCALAPPDATA:-}/nodejs"
    fi
    IFS=:
    for d in $dirs; do
        [ -n "$d" ] || continue
        if [ -x "$d/node" ]; then printf '%s\n' "$d/node"; IFS="$save_ifs"; return 0; fi
        if [ -x "$d/node.exe" ]; then printf '%s\n' "$d/node.exe"; IFS="$save_ifs"; return 0; fi
    done
    IFS="$save_ifs"

    # 4) nvm — newest installed version. sort -V (NOT lexical: "v8" > "v20"
    #    lexically would pick an EOL node that can't run modern ESM).
    local nvm_root="${RESOLVE_NODE_NVM_ROOT:-${HOME:-}/.nvm/versions/node}"
    if [ -d "$nvm_root" ]; then
        # printf-on-glob (not `ls`) so SC2012 stays quiet; a non-matching glob
        # stays literal and fails the -x test below, so no false hit.
        local newest
        newest="$(printf '%s\n' "$nvm_root"/*/bin/node | sort -V | tail -1)"
        if [ -n "$newest" ] && [ -x "$newest" ]; then printf '%s\n' "$newest"; return 0; fi
    fi

    # 5) fnm — newest installed version (its layout: <dir>/node-versions/*/installation/bin/node).
    local fnm_root="${FNM_DIR:-${HOME:-}/.local/share/fnm}"
    if [ -d "$fnm_root/node-versions" ]; then
        local fnm_newest
        fnm_newest="$(printf '%s\n' "$fnm_root"/node-versions/*/installation/bin/node | sort -V | tail -1)"
        if [ -n "$fnm_newest" ] && [ -x "$fnm_newest" ]; then printf '%s\n' "$fnm_newest"; return 0; fi
    fi

    return 1
}
