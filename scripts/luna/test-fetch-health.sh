#!/usr/bin/env bash
# Offline classifier/auth/state tests for HIMMEL-1449 fetch-health probes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$SCRIPT_DIR/test_fetch_health.py"
fi
exec python "$SCRIPT_DIR/test_fetch_health.py"
