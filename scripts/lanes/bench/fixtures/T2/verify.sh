#!/usr/bin/env bash
set -u
FIX="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091  # verify-common.sh is sourced at runtime; linted standalone by pre-commit
. "$(cd "$(dirname "$0")/../../lib" && pwd)/verify-common.sh"
assert_only_paths_changed "$FIX/input" "$FIX/manifest.txt" || exit 1

fail=0

# 1. The old two-stage `grep ... | grep -q ...` pipeline must have zero hits.
assert_no_hits '\|[[:space:]]*grep[[:space:]]+-q' . || fail=1

# 2. Every shell file must still be syntactically valid.
for f in check-alpha.sh check-beta.sh check-gamma.sh check-delta.sh \
         check-epsilon.sh check-zeta.sh check-eta.sh check-theta.sh \
         run-tests.sh; do
    if [ ! -f "$f" ]; then
        echo "verify: missing expected file: $f" >&2
        fail=1
        continue
    fi
    if ! bash -n "$f"; then
        echo "verify: bash -n failed on $f" >&2
        fail=1
    fi
done

# 3. The fixture's own behavioral test script must still pass.
if ! bash ./run-tests.sh; then
    echo "verify: run-tests.sh failed" >&2
    fail=1
fi

[ "$fail" -eq 0 ]
exit $?
