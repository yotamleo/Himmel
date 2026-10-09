#!/usr/bin/env bash
# shellcheck disable=SC2164
# c.sh SRC DEST - report both directories
cd "$1" || exit 1
echo "RAN src $(pwd)"
cd "$2" || exit 1
echo "RAN dest $(pwd)"
