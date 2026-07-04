#!/usr/bin/env bash
# Quota-gauge ledger path resolver (WS9/HIMMEL-654).
# Source this file and call `quota_gauge_ledger_path`. PURE — no fs mutation
# (the parent dir is created on append in quota-gauge-ledger.sh, not on
# resolve), so read-only callers cannot trigger filesystem mutation as a
# side effect.
#
# Resolution:
#   $HIMMEL_QUOTA_GAUGE_LEDGER — explicit override (absolute path to the .jsonl).
#   <else> $HOME/.himmel/quota-gauge.jsonl — the single-file default (D2
#          primary; one file so a reader tails one path, integrity resting
#          on atomic single-line O_APPEND — AC0 gate PASSED 5/5 on Windows
#          Git Bash).
quota_gauge_ledger_path() {
    if [ -n "${HIMMEL_QUOTA_GAUGE_LEDGER:-}" ]; then
        printf '%s\n' "$HIMMEL_QUOTA_GAUGE_LEDGER"
        return 0
    fi
    local home="${HOME:-}"
    printf '%s/.himmel/quota-gauge.jsonl\n' "$home"
}
