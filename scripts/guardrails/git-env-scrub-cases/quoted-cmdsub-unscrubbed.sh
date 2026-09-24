#!/usr/bin/env bash
# RED: git invocation inside a command substitution NESTED in a double-quoted
# string ("$(git ...)") — strip_code used to blank the whole double-quoted
# span uniformly, which hid this `git` word from is_git_invocation entirely
# (HIMMEL-3570 CR fixup). No scrub anywhere in the file.
set -euo pipefail
out="$(git rev-parse HEAD)"
echo "$out"
