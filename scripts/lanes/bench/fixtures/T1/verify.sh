#!/usr/bin/env bash
set -u
FIX="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091  # verify-common.sh is sourced at runtime; linted standalone by pre-commit
. "$(cd "$(dirname "$0")/../../lib" && pwd)/verify-common.sh"
assert_only_paths_changed "$FIX/input" "$FIX/manifest.txt" || exit 1

# 1. Zero remaining hits of the old SIGPIPE-fragile idiom anywhere in the tree.
assert_no_hits "printf.*grep.*-q" . || exit 1

# 2. The helper must be present and defined exactly once, with exactly the
#    prescribed body.
def_count="$(grep -rho '^str_contains() {$' . | wc -l | tr -d ' ')"
if [ "$def_count" != "1" ]; then
    echo "verify: expected exactly one str_contains() definition, found $def_count" >&2
    exit 1
fi
if [ ! -f strcheck.sh ]; then
    echo "verify: strcheck.sh not found" >&2
    exit 1
fi
actual_body="$(grep -A2 '^str_contains() {$' strcheck.sh | head -3)"
# shellcheck disable=SC2016  # the $1/$2 are the literal prescribed body, compared — never expanded
expected_body='str_contains() {
    grep -q -- "$2" <<< "$1"
}'
if [ "$actual_body" != "$expected_body" ]; then
    echo "verify: str_contains() body does not match the prescribed form" >&2
    echo "--- expected ---" >&2
    echo "$expected_body" >&2
    echo "--- actual ---" >&2
    echo "$actual_body" >&2
    exit 1
fi

# 3. Every changed/added shell file must be syntactically valid.
for f in *.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f"; then
        echo "verify: bash -n failed for $f" >&2
        exit 1
    fi
done

# 4. The fixture's own behavioral test suite must still pass.
if ! bash run-tests.sh; then
    echo "verify: run-tests.sh failed" >&2
    exit 1
fi

exit 0
