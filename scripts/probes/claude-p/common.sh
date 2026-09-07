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
