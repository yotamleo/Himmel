#!/usr/bin/env bash
# RED: entry-point script, bare git call, no scrub anywhere in the file.
set -euo pipefail
git -C "$1" rev-parse --git-common-dir
