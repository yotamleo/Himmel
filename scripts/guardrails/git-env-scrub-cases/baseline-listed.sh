#!/usr/bin/env bash
# GREEN only under a baseline that lists SHELL:<this-path> — otherwise RED,
# same shape as unscrubbed-entry.sh.
set -euo pipefail
git -C "$1" rev-parse --git-common-dir
