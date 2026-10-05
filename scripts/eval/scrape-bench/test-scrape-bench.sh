#!/usr/bin/env bash
# test-scrape-bench.sh — HIMMEL-4362. Runs the stubbed python unit tests for the
# scrape-provider benchmark harness (no network, no key). Needs python3.
# PLATFORM GUARD: no .ps1 twin; the bench is a Linux-station eval tool.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP - python3 not found"
    exit 0
fi
exec python3 -m unittest discover -s "$HERE" -p 'test_scrape_bench.py' -v
