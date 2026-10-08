#!/usr/bin/env bash
# ok2.sh DIR - cd inside a subshell, guarded by &&
( cd "$1" && echo "RAN in $(pwd)" )
