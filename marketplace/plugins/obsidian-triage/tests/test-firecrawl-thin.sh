#!/usr/bin/env bash
# Wrapper for the --firecrawl-thin escalation unit tests (LUNA-27 /
# HIMMEL-320). Delegates to the hermetic python test (no network, no
# FIRECRAWL_API_KEY, no credits). Matches the repo's <name>.sh + <name>.py
# test-pair convention.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python || command -v python3 || true)"

if [ -z "$PY" ]; then
    echo "  SKIP  test-firecrawl-thin (no python interpreter on PATH)"
    exit 0
fi

PYTHONUTF8=1 "$PY" "$SCRIPT_DIR/test-firecrawl-thin.py"
