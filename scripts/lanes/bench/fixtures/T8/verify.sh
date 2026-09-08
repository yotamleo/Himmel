#!/usr/bin/env bash
set -u
FIX="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091  # verify-common.sh is sourced at runtime; linted standalone by pre-commit
. "$(cd "$(dirname "$0")/../../lib" && pwd)/verify-common.sh"
assert_only_paths_changed "$FIX/input" "$FIX/manifest.txt" || exit 1

fail=0
EXPECTED_COUNT=10

# Expected sequence: TC-001 TC-002 ... TC-0NN
expected=""
i=1
while [ "$i" -le "$EXPECTED_COUNT" ]; do
    id="$(printf 'TC-%03d' "$i")"
    if [ -z "$expected" ]; then
        expected="$id"
    else
        expected="$expected $id"
    fi
    i=$((i + 1))
done

# 1. Source-level comment IDs, in file order (alpha, beta, gamma) then
#    top-to-bottom within each file.
comment_ids=""
for f in tests/test_alpha.sh tests/test_beta.sh tests/test_gamma.sh; do
    if [ ! -f "$f" ]; then
        echo "verify: missing test file: $f" >&2
        fail=1
        continue
    fi
    ids="$(grep -Eo '# TC-[0-9]+:' "$f" | grep -Eo 'TC-[0-9]+')"
    for id in $ids; do
        if [ -z "$comment_ids" ]; then
            comment_ids="$id"
        else
            comment_ids="$comment_ids $id"
        fi
    done
done

if [ "$comment_ids" != "$expected" ]; then
    echo "verify: comment-level IDs do not match expected sequence" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $comment_ids" >&2
    fail=1
fi

# 2. Runtime output IDs — actually run the suite and check both the
#    sequence and that it still passes.
if [ ! -f run-tests.sh ]; then
    echo "verify: missing run-tests.sh" >&2
    exit 1
fi

run_output="$(bash run-tests.sh 2>&1)"
run_rc=$?

if [ "$run_rc" -ne 0 ]; then
    echo "verify: suite did not pass (exit $run_rc)" >&2
    echo "$run_output" >&2
    fail=1
fi

runtime_ids=""
for id in $(printf '%s\n' "$run_output" | grep -Eo '(PASS|FAIL) TC-[0-9]+' | grep -Eo 'TC-[0-9]+'); do
    if [ -z "$runtime_ids" ]; then
        runtime_ids="$id"
    else
        runtime_ids="$runtime_ids $id"
    fi
done

if [ "$runtime_ids" != "$expected" ]; then
    echo "verify: runtime-reported IDs do not match expected sequence" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $runtime_ids" >&2
    fail=1
fi

[ "$fail" -eq 0 ]
