# shellcheck shell=bash
# sourced-lib
# GREEN: shebang-less, invokes git in command position, but explicitly
# declares itself sourced-only via the marker above — whatever sources this
# owns the scrub.
git -C "$1" rev-parse --git-common-dir
