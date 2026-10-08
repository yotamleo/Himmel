#!/usr/bin/env bash
# ok1.sh DIR - already checks its cd
cd "$1" || exit 1
echo "RAN in $(pwd)"
