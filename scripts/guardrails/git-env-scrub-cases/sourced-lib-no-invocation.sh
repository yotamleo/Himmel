# shellcheck shell=bash
# GREEN: shebang-less, no git invocation at all — the common case, skipped
# without needing any marker.
plain_helper() {
    echo "just a function, nothing to scrub"
}
