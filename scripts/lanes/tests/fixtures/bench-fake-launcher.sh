#!/usr/bin/env bash
# scripts/lanes/tests/fixtures/bench-fake-launcher.sh — HIMMEL-1723 P2.9 test fixture
# Stands in for scripts/claude-codex in bench-run-batch.test.mjs (via
# BENCH_CLAUDE_CODEX_BIN) so the retry-cap and bank-abort behavior can be
# exercised WITHOUT a real codex dispatch. Accepts the same argv shape
# dispatch-luna.sh invokes it with (`--permission-mode dontAsk "<prompt>"`)
# and ignores it beyond logging.
#
# Attempt tracking keys on the run-id, recovered from $PWD's basename: every
# dispatch runs with cwd = a materialize.sh scratch dir named
# "<run-id>.<timestamp>.<pid>" (run-ids themselves never contain '.'), so
# basename up to the first '.' is the run-id.
#
# Behavior is PER-RUN-ID, via FAKE_LAUNCHER_CONFIG_DIR (required): a file
# named <run-id> under that dir controls this run-id's outcome —
#   absent, or empty              -> always succeed
#   contents "always-fail"        -> always exit 1
#   contents a bare integer N     -> exit 1 on attempts 1..N, then succeed
# FAKE_LAUNCHER_STATE_DIR (required) holds the per-run-id attempt counters.
set -u
run_id="$(basename "$PWD")"
run_id="${run_id%%.*}"

state_dir="${FAKE_LAUNCHER_STATE_DIR:?FAKE_LAUNCHER_STATE_DIR required}"
config_dir="${FAKE_LAUNCHER_CONFIG_DIR:?FAKE_LAUNCHER_CONFIG_DIR required}"
mkdir -p "$state_dir"

counter_file="$state_dir/$run_id.attempts"
attempt=0
[ -f "$counter_file" ] && attempt="$(cat "$counter_file")"
attempt=$((attempt + 1))
echo "$attempt" > "$counter_file"

echo "fake-launcher: run_id=$run_id attempt=$attempt argv=$*"

config_file="$config_dir/$run_id"
content=""
[ -f "$config_file" ] && content="$(cat "$config_file")"

case "$content" in
    always-fail)
        echo "fake-launcher: forced failure for $run_id" >&2
        exit 1
        ;;
    ''|*[!0-9]*)
        exit 0
        ;;
    *)
        if [ "$attempt" -le "$content" ]; then
            echo "fake-launcher: simulated failure (attempt $attempt <= $content) for $run_id" >&2
            exit 1
        fi
        exit 0
        ;;
esac
