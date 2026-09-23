#!/usr/bin/env bash
# scripts/lib/macos-app-resolve.sh - HIMMEL-3474: shared macOS terminal-app
# resolution, factored out of konsole-macos.sh and arm-resume.sh's headed
# crontab launch, which carried byte-identical copies of this logic.
#
# macos_resolve_term_app <caller-name> - prints the resolved app name (no
# trailing .app) on stdout. Resolution order: ARM_TERMINAL_APP if set, else
# TERM_PROGRAM (iTerm.app -> iTerm, Apple_Terminal -> Terminal, anything else
# -> Terminal). ARM_APP_DIRS (colon-separated; same default list both callers
# already used) is then searched for "<name>.app" via a plain filesystem
# probe - never `open -Ra`, which reveals the app in Finder as a side effect.
# A miss WARNs (prefixed with <caller-name>, matching each caller's own
# messages) and fails open to Terminal.app, present on every Mac.
macos_resolve_term_app() {
    local _caller="$1"
    local _term_app
    if [ -n "${ARM_TERMINAL_APP:-}" ]; then
        _term_app="$ARM_TERMINAL_APP"
    else
        case "${TERM_PROGRAM:-}" in
            iTerm.app)      _term_app="iTerm" ;;
            Apple_Terminal) _term_app="Terminal" ;;
            *)              _term_app="Terminal" ;;
        esac
    fi
    local _app_dirs="${ARM_APP_DIRS:-/Applications:/Applications/Utilities:/System/Applications:/System/Applications/Utilities:$HOME/Applications}"
    local _app_found=0 _app_dir _IFS_SAVE="$IFS"
    IFS=:
    for _app_dir in $_app_dirs; do
        [ -n "$_app_dir" ] || continue
        [ -d "$_app_dir/$_term_app.app" ] && { _app_found=1; break; }
    done
    IFS="$_IFS_SAVE"
    if [ "$_app_found" -ne 1 ]; then
        echo "WARN $_caller: terminal app '$_term_app' not found under ARM_APP_DIRS; falling back to Terminal" >&2
        _term_app="Terminal"
    fi
    printf '%s\n' "$_term_app"
}
