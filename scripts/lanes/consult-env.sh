# shellcheck shell=bash
# scripts/lanes/consult-env.sh - sourced, never run (HIMMEL-4152). The runtime
# a --consult launch runs on: a pinned PATH, an absolute bash, and the list of
# bash startup variables to strip, so nothing the caller exported picks the
# interpreter, the claude binary or code that runs before either.
#
# Sourced by headed-arm-leg.sh (before it execs headed-arm.sh under a consult),
# by leg-claude-launcher-consult.sh (the consult's launcher entry) and by
# leg-claude-launcher.sh (its consult branch). Each source names the file by a
# canonical in-repo path; the caller never chooses it.
#
# Platform: POSIX bash 3.2+ (macOS /bin/bash is 3.2).
#
# ponytail: a claude installed only outside these dirs (nvm, a custom npm
# prefix) refuses, and a tool found in none of them is unreachable from a
# consult; upgrade path = an operator-recorded binary path and tool dirs, if
# one is ever kept outside the caller's reach.

# consult_pin_path: print the pinned PATH. The home part comes from the passwd
# entry of the real user, never $HOME (which the caller sets).
consult_pin_path() {
    local _cp_user _cp_home=""
    _cp_user="$(PATH=/usr/bin:/bin; id -un 2>/dev/null)" || _cp_user=""
    case "$_cp_user" in
        ''|[-+]*|*[!A-Za-z0-9._-]*) ;;
        *) eval "_cp_home=~$_cp_user" ;;
    esac
    case "$_cp_home" in /*) ;; *) _cp_home="" ;; esac
    printf '%s\n' "${_cp_home:+$_cp_home/.local/bin:}/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
}

# consult_pin_bash: print the absolute system bash a consult runs on, or fail.
consult_pin_bash() {
    local _cp_b
    for _cp_b in /usr/bin/bash /bin/bash; do
        if [ -x "$_cp_b" ]; then
            printf '%s\n' "$_cp_b"
            return 0
        fi
    done
    return 1
}

# consult_scrub_args: set CONSULT_SCRUB to the `env -u` arguments that drop
# every bash startup input (the startup files, the option imports, the xtrace
# prompt) and every exported function from the environment. Read from the raw
# environment, not `declare -Fx`, so it also catches a function a `bash -p`
# did not import. A value line that merely looks like a name only adds a
# harmless extra -u.
consult_scrub_args() {
    local _cp_line
    CONSULT_SCRUB=(-u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u PS4 -u CDPATH -u GLOBIGNORE)
    while IFS= read -r _cp_line; do
        case "$_cp_line" in
            BASH_FUNC_*=*) CONSULT_SCRUB+=(-u "${_cp_line%%=*}") ;;
        esac
    done < <(/usr/bin/env)
}
