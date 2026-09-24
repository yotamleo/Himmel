#!/usr/bin/env bash
# GREEN control: "git" appears only as a case-pattern label and inside a
# string literal / comment — never in command position, so no scrub is
# required and no hit should fire.
set -euo pipefail
thing="run git status later"  # mentions git too
echo "$thing" >/dev/null
case "$1" in
    git) echo "it's git" ;;
    other) echo "still not a call" ;;
    *) echo "default" ;;
esac
