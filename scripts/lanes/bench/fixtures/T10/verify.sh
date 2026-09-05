#!/usr/bin/env bash
set -u
FIX="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091  # verify-common.sh is sourced at runtime; linted standalone by pre-commit
. "$(cd "$(dirname "$0")/../../lib" && pwd)/verify-common.sh"
assert_only_paths_changed "$FIX/input" "$FIX/manifest.txt" || exit 1

ok=1
assert_bytes_equal "calculator.py" "$FIX/expected/calculator.py" || ok=0
assert_bytes_equal "formatter.py" "$FIX/expected/formatter.py" || ok=0
assert_bytes_equal "constants.py" "$FIX/expected/constants.py" || ok=0

[ "$ok" -eq 1 ]
