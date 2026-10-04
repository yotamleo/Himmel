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
# omitted it is derived from HERMES_HOME, else %LOCALAPPDATA%/hermes on Windows
# and $HOME/.hermes on POSIX (HIMMEL-2582), tolerating HERMES_HOME pointing
# straight at the checkout (venv/ or .hermes/bin/ at the root). Since HIMMEL-4307
# a PM-managed install (.hermes/bin/hermes, Python 3.14 dependency generations)
# resolves through the launcher's `--print-runtime-command`; the legacy venv is
# the fallback. Prints the absolute path on stdout + returns 0 on success; returns
# 1 + empty stdout when no executable interpreter is found. bash 3.2-safe.

resolve_hermes_py() {
    # 1) HERMES_PY — but only if it STILL resolves to an executable. A stale
    #    value (venv moved/rebuilt) falls through to the probe below instead of
    #    shadowing it. This is the move/rebuild-safe property (HIMMEL-613).
    if [ -n "${HERMES_PY:-}" ] && [ -x "${HERMES_PY}" ]; then
        printf '%s\n' "$HERMES_PY"
        return 0
    fi

    # 2) Derive the checkout dir that owns the launcher / venv/.
    local src
    src="$(_hermes_src_dir "${1:-}")"

    # 3) PM-managed layout (HIMMEL-4307): upstream's launcher prints the exact
    #    runtime argv; argv[0] is the interpreter that can load the dependency
    #    generation (Python 3.14 under ~/.hermes/tools). The legacy venv python
    #    cannot, so this beats the venv probe — which stays as the fallback for
    #    old installs and for a launcher whose reported interpreter is gone.
    #    The launcher call is bounded (5s) where `timeout` exists, so a stalled
    #    launcher cannot hang resolution before invoke.sh starts its watchdog.
    local launcher rt out
    if launcher="$(hermes_pm_launcher "$src")"; then
        if command -v timeout >/dev/null 2>&1; then
            out="$(timeout 5 "$launcher" --print-runtime-command 2>/dev/null)" || out=""
        else
            out="$("$launcher" --print-runtime-command 2>/dev/null)" || out=""
        fi
        rt="$(printf '%s\n' "$out" | sed -n '1s/^\["\(\([^"\\]\|\\.\)*\)".*/\1/p' | sed 's/\\\\/\\/g')"
        if [ -n "$rt" ] && [ -x "$rt" ]; then printf '%s\n' "$rt"; return 0; fi
    fi

    # 4) Probe both venv layouts (Windows Scripts/, POSIX bin/).
    if   [ -x "$src/venv/Scripts/python.exe" ]; then printf '%s\n' "$src/venv/Scripts/python.exe"; return 0
    elif [ -x "$src/venv/bin/python" ];        then printf '%s\n' "$src/venv/bin/python";        return 0
    fi
    return 1
}

# hermes_pm_launcher [CHECKOUT_DIR] — print the upstream launcher path and return
# 0 when this install is the PM-managed layout; return 1 + empty stdout for a
# legacy venv-only install (HIMMEL-4307). Callers use it to know that pip-managing
# the interpreter would fight hermes' own dependency manager.
hermes_pm_launcher() {
    local src
    src="$(_hermes_src_dir "${1:-}")"
    if [ -x "$src/.hermes/bin/hermes" ]; then printf '%s\n' "$src/.hermes/bin/hermes"; return 0; fi
    return 1
}

# _hermes_src_dir [CHECKOUT_DIR] — the hermes-agent checkout: the argument, else
# derived from HERMES_HOME / the per-platform default (see the header).
_hermes_src_dir() {
    local src="${1:-}"
    if [ -z "$src" ]; then
        local root="${HERMES_HOME:-}"
        # Default root, per-platform (HIMMEL-2582). This used to be
        # ${LOCALAPPDATA:-$HOME/AppData/Local}/hermes unconditionally — a
        # WINDOWS path on every host — so on any POSIX box that had not
        # exported HERMES_HOME the resolver looked under ~/AppData/Local,
        # found nothing, and returned 1. That is what made the bridge's triage
        # fail open with "hermes interpreter not found" on the Linux station
        # (2026-09-05), recovered there with an Environment=HERMES_HOME
        # drop-in that this default makes unnecessary. LOCALAPPDATA is the
        # marker of a Windows host, so keep the Windows default INSIDE that
        # branch: a Git-Bash/WSL operator with hermes under %LOCALAPPDATA%
        # resolves exactly as before. Elsewhere hermes installs to ~/.hermes.
        if [ -z "$root" ]; then
            if [ -n "${LOCALAPPDATA:-}" ]; then root="$LOCALAPPDATA/hermes"; else root="$HOME/.hermes"; fi
        fi
        src="$root/hermes-agent"
        # Tolerate HERMES_HOME pointing straight at the checkout (venv/ at root).
        [ -d "$src/venv" ] || [ -x "$src/.hermes/bin/hermes" ] \
            || { { [ -d "$root/venv" ] || [ -x "$root/.hermes/bin/hermes" ]; } && src="$root"; }
    fi
    printf '%s\n' "$src"
}
