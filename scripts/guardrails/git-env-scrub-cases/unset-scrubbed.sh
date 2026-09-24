#!/usr/bin/env bash
# GREEN: all four vars unset on one line before the first invocation.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
git -C "$1" rev-parse --git-common-dir
