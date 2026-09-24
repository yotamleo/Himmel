#!/usr/bin/env bash
# GREEN: the four vars unset across separate lines before the first invocation.
set -euo pipefail
unset GIT_DIR
unset GIT_WORK_TREE
unset GIT_COMMON_DIR
unset GIT_INDEX_FILE
git -C "$1" rev-parse --git-common-dir
