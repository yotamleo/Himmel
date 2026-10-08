#!/usr/bin/env bash
# shellcheck disable=SC2164
# a.sh DIR - report where the job ran
d="$1"
cd "$d"
echo "RAN in $(pwd)"
