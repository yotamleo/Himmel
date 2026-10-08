#!/usr/bin/env bash
# shellcheck disable=SC2164
# a.sh DIR - report where the job ran
d="$1"
cd "$d" || exit 1
echo "RAN in $(pwd)"
