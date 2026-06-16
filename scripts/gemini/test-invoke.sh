#!/usr/bin/env bash
# scripts/gemini/test-invoke.sh — smoke test for invoke.sh (HIMMEL-158, Story A).
#
# Skips cleanly (exit 0, prints SKIP) when the `gemini` binary is absent, per
# the cross-story testing strategy (gated on `command -v gemini`). No CI; this
# runs on the operator machine only.
#
# When gemini IS present, exercises:
#   1. PONG round-trip (positional prompt).
#   2. --json mode returns parseable JSON.
#   3. --model override is accepted.
#
# Bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOKE="$SCRIPT_DIR/invoke.sh"

if [ ! -f "$INVOKE" ]; then
    echo "FAIL: invoke.sh not found at $INVOKE" >&2
    exit 1
fi

if ! command -v gemini >/dev/null 2>&1; then
    echo "SKIP: gemini binary not on PATH — skipping live invoke.sh smoke test." >&2
    echo "      (Run on a machine with gemini-cli installed + OAuth configured.)" >&2
    exit 0
fi

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. PONG round-trip.
echo "test: PONG round-trip" >&2
out="$(bash "$INVOKE" "Reply with exactly the single word PONG and nothing else.")" \
    || fail "invoke.sh exited non-zero on PONG round-trip"
case "$out" in
    *PONG*) echo "  ok: response contained PONG" >&2 ;;
    *) fail "PONG round-trip: response did not contain PONG (got: $out)" ;;
esac

# 2. --json mode returns parseable JSON.
echo "test: --json mode" >&2
json_out="$(bash "$INVOKE" --json "List exactly 3 fruits.")" \
    || fail "invoke.sh exited non-zero in --json mode"
if command -v node >/dev/null 2>&1; then
    printf '%s' "$json_out" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{JSON.parse(d)})' \
        || fail "--json mode: output was not parseable JSON (got: $json_out)"
    echo "  ok: --json output parsed as JSON" >&2
else
    case "$json_out" in
        \{*|\[*) echo "  ok: --json output looks like JSON (node absent, shallow check)" >&2 ;;
        *) fail "--json mode: output did not look like JSON (got: $json_out)" ;;
    esac
fi

# 3. --model override is accepted (does not error out).
echo "test: --model override" >&2
bash "$INVOKE" --model gemini-2.5-flash "Reply with exactly the single word PONG and nothing else." >/dev/null \
    || fail "invoke.sh exited non-zero with --model override"
echo "  ok: --model override accepted" >&2

echo "PASS: all invoke.sh smoke tests passed." >&2
exit 0
