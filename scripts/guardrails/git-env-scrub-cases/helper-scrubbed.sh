#!/usr/bin/env bash
# GREEN: sources the shared helper and calls git_env_scrub before the first
# invocation. The nested-quoting source line below (a $(...) command
# substitution inside the outer double quotes) is a deliberate regression
# fixture for a bug the file-level stripper hit during development.
set -euo pipefail
. "$(dirname "$0")/../../lib/git-clean.sh"
git_env_scrub
git -C "$1" rev-parse --git-common-dir
