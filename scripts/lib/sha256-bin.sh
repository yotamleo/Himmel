#!/usr/bin/env bash
# scripts/lib/sha256-bin.sh — SOURCED. Resolve a sha256 hasher ONCE. HIMMEL-3177.
#
# `sha256sum` is a GNU coreutil: stock macOS has neither `sha256sum` nor
# `gsha256sum` (brew's coreutils installs the latter under `g`-prefixes, but
# `shasum -a 256` ships on every macOS by default, so it is the fallback, not
# a third resolver leg). Sourcing this sets:
#
#   _SHA256_CMD  the resolved hasher invocation ("sha256sum" or
#                "shasum -a 256"); EMPTY when neither is on PATH.
#
# and prints ONE stderr line when it is empty. Use the sha256_hex wrapper
# rather than $_SHA256_CMD directly — it strips the trailing "  -"/"  <file>"
# that both tools print after the hex digest:
#
#   sha256_hex "$file"          # hash of a file, one hex line
#   printf '%s' "$x" | sha256_hex   # hash of stdin, one hex line
#
# bash 3.2-safe. Sourcing is idempotent: it re-resolves against the current PATH.

_sha256_bin_resolve() {
    if command -v sha256sum >/dev/null 2>&1; then
        _SHA256_CMD="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        _SHA256_CMD="shasum -a 256"
    else
        _SHA256_CMD=""
        echo "sha256-bin: no 'sha256sum'/'shasum' on PATH -- sha256_hex fails closed" >&2
        return 1
    fi
}
_sha256_bin_resolve || true

sha256_hex() {
    [ -n "$_SHA256_CMD" ] || return 1
    local out
    if [ $# -gt 0 ]; then
        out=$($_SHA256_CMD -- "$@") || return 1
    else
        out=$($_SHA256_CMD) || return 1
    fi
    local hex
    hex=$(printf '%s\n' "$out" | awk '{print $1}')
    printf '%s\n' "${hex#\\}"
}
