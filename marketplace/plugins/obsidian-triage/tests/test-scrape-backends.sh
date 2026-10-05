#!/usr/bin/env bash
# Wrapper for the thin-body scrape backend chain + ledger unit tests
# (HIMMEL-4335). Delegates to the hermetic python test (no network, no
# FIRECRAWL_API_KEY, no credits). Matches the repo's <name>.sh + <name>.py
# test-pair convention.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python || command -v python3 || true)"

if [ -z "$PY" ]; then
    echo "  SKIP  test-scrape-backends (no python interpreter on PATH)"
    exit 0
fi

PYTHONUTF8=1 "$PY" "$SCRIPT_DIR/test-scrape-backends.py"
