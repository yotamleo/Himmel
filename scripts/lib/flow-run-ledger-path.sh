#!/usr/bin/env bash
# Flow-run ledger path resolver (HIMMEL-921).
# Source this file and call `flow_run_ledger_path`. PURE - no fs mutation
# (the parent dir is created on append in flow-run-ledger.sh, not on
# resolve), so read-only callers cannot trigger filesystem mutation as a
# side effect.
#
# Resolution:
#   $HIMMEL_FLOW_RUNS_LEDGER - explicit override (absolute path to the .jsonl).
#   <else> $HOME/.himmel/flow-runs.jsonl - the single-file default.
flow_run_ledger_path() {
    if [ -n "${HIMMEL_FLOW_RUNS_LEDGER:-}" ]; then
        printf '%s\n' "$HIMMEL_FLOW_RUNS_LEDGER"
        return 0
    fi
    local home="${HOME:-}"
    printf '%s/.himmel/flow-runs.jsonl\n' "$home"
}
