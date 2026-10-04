#!/usr/bin/env bash
# Wrapper for the shared Instagram throttle tests (HIMMEL-4306). Hermetic: no
# network, no Instagram; matches the <name>.sh + <name>.py pair convention.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 || command -v python || true)"

if [ -z "$PY" ]; then
    echo "  SKIP  test-ig-throttle (no python interpreter on PATH)"
    exit 0
fi

PYTHONUTF8=1 "$PY" "$SCRIPT_DIR/test-ig-throttle.py"
