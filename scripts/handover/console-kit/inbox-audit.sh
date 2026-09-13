#!/usr/bin/env bash
# inbox-audit.sh — HIMMEL-2980. Per-shift audit for inbox-send.sh's
# judge-side sent-record: every token-quoting bullet in an inbox must have
# a matching ledger line, or it is unaccounted for — either forged (a
# console relay is barred from --token by HIMMEL-2975, so a token bullet
# with no record was never sent by this script) or lost to an exit-4
# ledger-write failure (see inbox-send.sh header). Read-only: writes
# nothing, only reports.
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight — audits the
# Linux/konsole-only ledger inbox-send.sh writes (see its own header); no
# Windows-side sent-record exists to audit.
#
# Usage: inbox-audit.sh <inbox-file> <sent-log-dir>
#   <sent-log-dir> is the base passed as HIMMEL_CONSOLE_RUNDIR to
#   inbox-send.sh (or its console.sh-convention default) — this script
#   accepts a ledger line from either <sent-log-dir>/inbox-sent.log
#   directly or <sent-log-dir>/<sender>/inbox-sent.log one level down.
#
# A token bullet matches ^- [0-9][0-9]:[0-9][0-9] \[[^]]*\] from= ; for each,
# the sha256 of the line (no trailing newline) must equal the 4th
# whitespace-separated field of some ledger line. Prints "AUDIT ok" and
# exits 0 when every token bullet is matched; otherwise prints one
# "AUDIT UNMATCHED <line>" per miss and exits 1. A missing inbox file or
# sent-log dir, an inbox that cannot be read (e.g. a permission change), or a
# sha256sum failure is a usage error, exit 2 — this audit exists to catch
# forgery, so it fails closed rather than reporting a false "AUDIT ok". A
# final inbox line with no trailing newline is still audited.
#
# bash 3.2-safe, shellcheck-clean, no arrays — matches inbox-send.sh's
# shell dialect (see its own header for why).
set -u

usage() {
    printf 'usage: inbox-audit.sh <inbox-file> <sent-log-dir>\n' >&2
    exit 2
}

[ "$#" -eq 2 ] || usage
inbox="$1"
sent_dir="$2"

[ -f "$inbox" ] || { printf 'inbox-audit: no such inbox file: %s\n' "$inbox" >&2; exit 2; }
[ -d "$sent_dir" ] || { printf 'inbox-audit: no such sent-log dir: %s\n' "$sent_dir" >&2; exit 2; }

# One combined pool of recorded sha256 values, from every inbox-sent.log
# this sent_dir holds — directly at its root, or one level down under a
# per-sender subdirectory. A dir with no ledgers yet yields an empty pool,
# so every token bullet in the inbox correctly comes up unmatched.
ledger_shas="$(cat "$sent_dir"/inbox-sent.log "$sent_dir"/*/inbox-sent.log 2>/dev/null | awk '{ print $4 }')"

unmatched=0
read_failed=0
while IFS= read -r line || [ -n "$line" ]; do
    token_bullet="$(printf '%s' "$line" | grep -E '^- [0-9][0-9]:[0-9][0-9] \[[^]]*\] from=')"
    [ -n "$token_bullet" ] || continue
    if ! sha="$(printf '%s' "$line" | sha256sum)"; then
        printf 'inbox-audit: cannot hash line, aborting: %s\n' "$line" >&2
        exit 2
    fi
    sha="${sha%% *}"
    matched_sha="$(printf '%s\n' "$ledger_shas" | grep -xF "$sha")"
    if [ -z "$matched_sha" ]; then
        printf 'AUDIT UNMATCHED %s\n' "$line"
        unmatched=1
    fi
done < "$inbox" || read_failed=1

if [ "$read_failed" -eq 1 ]; then
    printf 'inbox-audit: cannot read %s\n' "$inbox" >&2
    exit 2
fi

if [ "$unmatched" -eq 0 ]; then
    printf 'AUDIT ok\n'
    exit 0
fi
exit 1
