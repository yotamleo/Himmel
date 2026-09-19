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
# No `local`: run-node.sh sources this under whatever `sh` the hook shell has and
# ksh93 rejects it (HIMMEL-3182), so function-scope variables carry a `_rn_`
# prefix instead — they leak into a same-shell caller, but cannot collide.
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
    _rn_nvm_symlink="${NVM_SYMLINK:-}"
    if [ -n "$_rn_nvm_symlink" ]; then
        # POSIX builtins only (no tr fork) — this runs even when no node/PATH
        # is found at all, the exact minimal-utils case this file exists to
        # survive (HIMMEL-2741: a caught-by-the-widened-gate regression).
        _rn_nvmw_rest="$_rn_nvm_symlink" _rn_nvmw_out=''
        while :; do
            case "$_rn_nvmw_rest" in
                *\\*)
                    _rn_nvmw_out="${_rn_nvmw_out}${_rn_nvmw_rest%%\\*}/"
                    _rn_nvmw_rest="${_rn_nvmw_rest#*\\}"
                    ;;
                *) _rn_nvmw_out="${_rn_nvmw_out}${_rn_nvmw_rest}"; break ;;
            esac
        done
        _rn_nvm_symlink="$_rn_nvmw_out"
    fi
    case "$_rn_nvm_symlink" in
        [A-Za-z]:/*) _rn_nvm_symlink="/$(printf '%s' "${_rn_nvm_symlink%%:*}" | tr '[:upper:]' '[:lower:]')${_rn_nvm_symlink#?:}" ;;
    esac
    _rn_nvmw_dirs="${_rn_nvm_symlink}:${RESOLVE_NODE_NVM4W_DIR-/c/nvm4w/nodejs}"
    _rn_save_ifs="$IFS"
    IFS=:
    for _rn_d in $_rn_nvmw_dirs; do
        [ -n "$_rn_d" ] || continue
        if [ -x "$_rn_d/node" ]; then printf '%s\n' "$_rn_d/node"; IFS="$_rn_save_ifs"; return 0; fi
        if [ -x "$_rn_d/node.exe" ]; then printf '%s\n' "$_rn_d/node.exe"; IFS="$_rn_save_ifs"; return 0; fi
    done
    IFS="$_rn_save_ifs"

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
    #    hermetic; `_rn_dirs` is walked with IFS=:, so a bare colon in the path
    #    would split it in half.
    if [ "${RESOLVE_NODE_PROBE_DIRS+set}" = set ]; then
        _rn_dirs="$RESOLVE_NODE_PROBE_DIRS"
    else
        _rn_dirs="/opt/homebrew/bin:/usr/local/bin:/usr/bin:${HOME:-}/.local/bin:/c/Program Files/nodejs:${LOCALAPPDATA:-}/nodejs"
    fi
    IFS=:
    for _rn_d in $_rn_dirs; do
        [ -n "$_rn_d" ] || continue
        if [ -x "$_rn_d/node" ]; then printf '%s\n' "$_rn_d/node"; IFS="$_rn_save_ifs"; return 0; fi
        if [ -x "$_rn_d/node.exe" ]; then printf '%s\n' "$_rn_d/node.exe"; IFS="$_rn_save_ifs"; return 0; fi
    done
    IFS="$_rn_save_ifs"

    # 4) nvm — newest installed version. sort -V (NOT lexical: "v8" > "v20"
    #    lexically would pick an EOL node that can't run modern ESM).
    _rn_nvm_root="${RESOLVE_NODE_NVM_ROOT:-${HOME:-}/.nvm/versions/node}"
    if [ -d "$_rn_nvm_root" ]; then
        # printf-on-glob (not `ls`) so SC2012 stays quiet; a non-matching glob
        # stays literal and fails the -x test below, so no false hit.
        _rn_newest="$(printf '%s\n' "$_rn_nvm_root"/*/bin/node | sort -V | tail -1)"
        if [ -n "$_rn_newest" ] && [ -x "$_rn_newest" ]; then printf '%s\n' "$_rn_newest"; return 0; fi
    fi

    # 5) fnm — newest installed version (its layout: <dir>/node-versions/*/installation/bin/node).
    _rn_fnm_root="${FNM_DIR:-${HOME:-}/.local/share/fnm}"
    if [ -d "$_rn_fnm_root/node-versions" ]; then
        _rn_fnm_newest="$(printf '%s\n' "$_rn_fnm_root"/node-versions/*/installation/bin/node | sort -V | tail -1)"
        if [ -n "$_rn_fnm_newest" ] && [ -x "$_rn_fnm_newest" ]; then printf '%s\n' "$_rn_fnm_newest"; return 0; fi
    fi

    return 1
}
