#!/usr/bin/env bash
# CI queue ledger path resolver (HIMMEL-502 P2.1).
# Byte-identical twin of ledgerPath() in scripts/ci-orchestrator/src/ledger.ts.
# Source this file and call `ci_queue_ledger_path`, OR execute it directly to
# print the resolved path (the parity test shells it this way). PURE — no fs
# mutation (the parent dir is created on append in ledger.ts, not on resolve).
#
# Resolution:
#   $HIMMEL_CI_QUEUE_LEDGER — explicit override (absolute path to the .jsonl).
#   <else> $HOME/.himmel/ci-queue.jsonl — the single-file default (integrity
#          rests on atomic single-line O_APPEND, the quota-gauge contract).
ci_queue_ledger_path() {
    if [ -n "${HIMMEL_CI_QUEUE_LEDGER:-}" ]; then
        printf '%s\n' "$HIMMEL_CI_QUEUE_LEDGER"
        return 0
    fi
    local home="${HOME:-}"
    # Fail closed when HOME is unset/empty rather than emit a filesystem-root
    # path ("/.himmel/ci-queue.jsonl"). The TS twin falls back to the OS home
    # dir here; bash cannot resolve it portably, so it errors. Real hook callers
    # always have HOME set — the byte-identical contract holds for any HOME-set env.
    if [ -z "$home" ]; then
        echo "ci-queue ledger: cannot resolve path — HOME is unset/empty" >&2
        return 1
    fi
    printf '%s/.himmel/ci-queue.jsonl\n' "$home"
}

# CLI entry — only when EXECUTED (not sourced): print the resolved path.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
    ci_queue_ledger_path
fi
