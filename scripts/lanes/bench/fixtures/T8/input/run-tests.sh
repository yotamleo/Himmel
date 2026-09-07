#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
for f in "$DIR"/tests/test_*.sh; do
    bash "$f"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail=1
    fi
done
exit "$fail"
