#!/usr/bin/env bash
# scripts/lib/timeout-bin.sh — SOURCED. Resolve a GNU-semantics `timeout` ONCE.
# HIMMEL-2589.
#
# `timeout` is a GNU coreutil: stock macOS ships neither it nor `gtimeout`
# (brew's coreutils installs the latter). Sourcing this sets:
#
#   _TIMEOUT_BIN  absolute path of the first of `timeout`, `gtimeout` that answers
#                 `--version` (rejects a Windows timeout.exe, which is a sleep
#                 with /T syntax, not a command wrapper); EMPTY when neither does.
#
# and prints ONE stderr line when it is empty. Resolved to an absolute path on
# purpose: a call that overrides PATH (`PATH=$stub:$PATH cmd`) looks a bare name
# up in the NEW PATH.
#
# Use it as a bound that degrades to unbounded:
#   ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 20} bash "$SUT" ...
# but a row whose assertion IS "this terminates" must NOT run unbounded — an
# absent bound turns that failing row into a hung suite. Guard it instead:
#   if [ -n "$_TIMEOUT_BIN" ]; then <row>; else skip "<row>: no timeout"; fi
#
# bash 3.2-safe. Sourcing is idempotent: it re-resolves against the current PATH.

_timeout_bin_resolve() {
    local _c _p
    _TIMEOUT_BIN=""
    for _c in timeout gtimeout; do
        _p="$(command -v "$_c" 2>/dev/null)" || continue
        [ -n "$_p" ] || continue
        if "$_p" --version >/dev/null 2>&1; then
            _TIMEOUT_BIN="$_p"
            return 0
        fi
    done
    echo "timeout-bin: no GNU 'timeout'/'gtimeout' on PATH (macOS: brew install coreutils) -- bounded calls run UNBOUNDED and hang-guard rows SKIP" >&2
    return 1
}
_timeout_bin_resolve || true
