# shellcheck shell=bash
# scripts/lib/headroom-proxy.sh -- HIMMEL_HEADROOM_PROXY flag resolution
# (HIMMEL-901).
#
# Small + sourceable (no top-level side effects, never calls exit) so both
# arm-resume.sh and its test suite can use the SAME parser instead of two
# copies drifting apart. arm-resume.sh itself is NOT safely sourceable (it
# parses "$@" and unconditionally exits at the end), so this helper was
# split out rather than testing the parser via the real script.
#
# _headroom_proxy_env_file_active <repo-root> -- rc 0 if <repo-root>/.env
# contains a HIMMEL_HEADROOM_PROXY=1 line (optional 'export ' prefix,
# comments/blank lines ignored). Only the exact value "1" activates -- any
# other value (0, true, ...) or a missing/unreadable file is rc 1. This is
# only the FILE-fallback half of flag resolution; the caller checks the
# process env first (arm-resume.sh: HIMMEL_HEADROOM_PROXY set in the
# launching shell always wins over the repo-root .env).
# Errexit-safe: every branch is a `case`/`return`, nothing unguarded.
_headroom_proxy_env_file_active() {
    local _envfile="$1/.env" _line _val
    [ -f "$_envfile" ] || return 1
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="${_line%$'\r'}"   # tolerate CRLF .env files
        case "$_line" in
            ''|'#'*) continue ;;
            'export '*) _val="${_line#export }" ;;
            *)         _val="$_line" ;;
        esac
        case "$_val" in
            HIMMEL_HEADROOM_PROXY=*) _val="${_val#HIMMEL_HEADROOM_PROXY=}" ;;
            *) continue ;;
        esac
        [ "$_val" = "1" ] && return 0
    done < "$_envfile"
    return 1
}
