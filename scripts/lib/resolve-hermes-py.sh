#!/usr/bin/env bash
# resolve-hermes-py.sh — locate the hermes venv python at RUNTIME, cross-platform.
#
# WHY: himmel persists NO absolute hermes python — consumers resolve it on every
# call so a moved/rebuilt venv (or a stale HERMES_PY left over from an old
# install) re-resolves instead of breaking. Same upgrade-moves-the-path class
# already fixed for `node` (resolve-node.sh) — HIMMEL-613. The sharp edge this
# centralises: HERMES_PY must be honoured ONLY when it still points at an
# executable; a stale value (venv relocated/rebuilt) must NOT shadow a fresh
# probe of the venv. Two consumers got this wrong inline (scripts/himmel-update.sh
# update_hermes, scripts/hermes/invoke.sh) — they took HERMES_PY unconditionally.
#
# Source this file, then call `resolve_hermes_py [CHECKOUT_DIR]`:
#   py="$(resolve_hermes_py "$src")" || { echo "no hermes py"; exit 1; }
# CHECKOUT_DIR is the hermes-agent checkout that owns venv/ (optional). When
# omitted it is derived from HERMES_HOME / %LOCALAPPDATA%/hermes (the invoke.sh
# default), tolerating HERMES_HOME pointing straight at the checkout (venv/ at
# the root). Prints the absolute path on stdout + returns 0 on success; returns
# 1 + empty stdout when no executable interpreter is found. bash 3.2-safe.

resolve_hermes_py() {
    # 1) HERMES_PY — but only if it STILL resolves to an executable. A stale
    #    value (venv moved/rebuilt) falls through to the probe below instead of
    #    shadowing it. This is the move/rebuild-safe property (HIMMEL-613).
    if [ -n "${HERMES_PY:-}" ] && [ -x "${HERMES_PY}" ]; then
        printf '%s\n' "$HERMES_PY"
        return 0
    fi

    # 2) Derive the checkout dir that owns venv/.
    local src="${1:-}"
    if [ -z "$src" ]; then
        local root="${HERMES_HOME:-}"
        [ -n "$root" ] || root="${LOCALAPPDATA:-$HOME/AppData/Local}/hermes"
        src="$root/hermes-agent"
        # Tolerate HERMES_HOME pointing straight at the checkout (venv/ at root).
        [ -d "$src/venv" ] || { [ -d "$root/venv" ] && src="$root"; }
    fi

    # 3) Probe both venv layouts (Windows Scripts/, POSIX bin/).
    if   [ -x "$src/venv/Scripts/python.exe" ]; then printf '%s\n' "$src/venv/Scripts/python.exe"; return 0
    elif [ -x "$src/venv/bin/python" ];        then printf '%s\n' "$src/venv/bin/python";        return 0
    fi
    return 1
}
