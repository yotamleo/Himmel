# shellcheck shell=bash
# RED: shebang-less would exempt this by the OLD heuristic, but it invokes
# git in command position with no scrub and no '# sourced-lib' marker, so it
# must be scanned like an entry point.
git -C "$1" rev-parse --git-common-dir
