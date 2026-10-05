#!/usr/bin/env bash
# Shared helpers for the claude-p P0 probe harness (HIMMEL-2179).
# Sourced by each probe script. No assertions here on purpose — probes dump
# raw artifacts/envelopes; a human reads them into RESULTS.md (verify by
# artifact, never exit code).
set -uo pipefail
PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$PROBE_DIR/tmp"
mkdir -p "$OUT_DIR"
# shellcheck disable=SC2034  # used by scripts that source this file
MODEL=haiku
# shellcheck disable=SC2034  # used by scripts that source this file
TIMEOUT_S=120

# Credential-free discovery probes (HIMMEL-4410): the 03* probes run claude under
# the fake-key harness and read skill discovery from the stream-json init event,
# so they need no login and cost nothing. Sourcing this pulls in fakekey_run.
# shellcheck source=../../testing/fakekey-claude.sh
# shellcheck disable=SC1091
. "$PROBE_DIR/../../testing/fakekey-claude.sh"

# probe_skill_discovered <outdir> <skill-name...> — one line per name, from the
# run's init event: DISCOVERED or ABSENT. Returns 1 if any is absent.
probe_skill_discovered() {
  local out="$1" name rc=0 init
  shift
  init=$(grep -m1 '"subtype":"init"' "$out/out.json" 2>/dev/null)
  if [ -z "$init" ]; then echo "no init event in $out/out.json (see $out/err.txt)"; return 1; fi
  for name in "$@"; do
    if jq -e --arg n "$name" '(.slash_commands // []) | index($n)' <<<"$init" >/dev/null 2>&1; then
      echo "skill $name: DISCOVERED"
    else
      echo "skill $name: ABSENT"; rc=1
    fi
  done
  return "$rc"
}
