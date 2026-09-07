#!/usr/bin/env bash
# Offline conversion/state-shape tests for HIMMEL-2549 youtube-state-from-chrome.
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$SCRIPT_DIR/test_youtube_state_from_chrome.py"
fi
exec python "$SCRIPT_DIR/test_youtube_state_from_chrome.py"
