#!/usr/bin/env bash
# shellcheck disable=SC2164
# d.sh BASE - run in BASE/out
base="$1"
cd "$base/out" || exit 1
echo "RAN in $(pwd)"
