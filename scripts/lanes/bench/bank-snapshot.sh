#!/usr/bin/env bash
# scripts/lanes/bench/bank-snapshot.sh — HIMMEL-1723 P2.6
# Thin wrapper: runs `bun scripts/lanes/bank-status.ts` and pipes its output
# into bank-snapshot-core.mjs, which does all the parsing/threshold logic
# (kept there, not here, so it is unit-testable without a real bank read).
#
# Usage:
#   bank-snapshot.sh preflight    # exit 0 = proceed, 1 = refuse (spec §7.2)
#   bank-snapshot.sh check        # same contract, for the every-10-dispatch recheck
#   bank-snapshot.sh snapshot [--out <file>]        # persist a timestamped reading
#   bank-snapshot.sh delta --pre <file> --post <file>   # apply the stale-source rule
#
# CODEX_LANE / CLAUDE_LANE pick which lanes.json lane's reading represents
# each bank (default: claudex for codex, sonnet for claude — any claude-tier
# lane reads the SAME account-wide number per spec §1.1). Every env var
# bank-status.ts itself honors (LANES_REGISTRY, CODEX_BANK_CACHE,
# CLAUDE_USAGE_CACHE, LANE_FUNDED_MAX_PCT, ...) passes through untouched —
# this script sets none of them, so the same test hooks bank-status.test.mjs
# already relies on work here too.
set -u
# pipefail is load-bearing here, not hygiene (codex CR): every command below is
# `bun bank-status.ts | node core`. Without it, a bun failure is masked — node
# reads EMPTY stdin, both lanes resolve to "unmeasured", no threshold can trip,
# and preflight/check exit 0. That is a fail-OPEN on the one gate whose entire
# job is to REFUSE when a bank is exhausted. With pipefail the pipeline's status
# reflects bun's, so `exit $?` propagates the failure and the batch stops.
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
CORE="$HERE/bank-snapshot-core.mjs"
CODEX_LANE="${CODEX_LANE:-claudex}"
CLAUDE_LANE="${CLAUDE_LANE:-sonnet}"

cmd="${1:-}"
case "$cmd" in
    preflight|check)
        ( cd "$REPO_ROOT" && bun scripts/lanes/bank-status.ts ) | node "$CORE" "$cmd" --codex-lane "$CODEX_LANE" --claude-lane "$CLAUDE_LANE"
        exit $?
        ;;
    snapshot)
        shift
        ( cd "$REPO_ROOT" && bun scripts/lanes/bank-status.ts ) | node "$CORE" snapshot --codex-lane "$CODEX_LANE" --claude-lane "$CLAUDE_LANE" "$@"
        exit $?
        ;;
    delta)
        shift
        node "$CORE" delta "$@"
        exit $?
        ;;
    *)
        echo "usage: bank-snapshot.sh preflight|check|snapshot [--out <file>]|delta --pre <file> --post <file>" >&2
        exit 2
        ;;
esac
