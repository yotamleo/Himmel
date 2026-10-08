#!/usr/bin/env bash
# shellcheck disable=SC2164
# b.sh DIR - report where the job ran
cd "$1" || exit 1
echo "RAN in $(pwd)"
