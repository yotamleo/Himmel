#!/usr/bin/env bash
# RED: exemption marker with no reason — must not exempt.
# git-env-ok:
set -euo pipefail
git -C "$1" rev-parse --git-common-dir
