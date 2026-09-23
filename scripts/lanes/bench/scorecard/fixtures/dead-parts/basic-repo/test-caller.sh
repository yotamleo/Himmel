#!/usr/bin/env bash
# test-caller.sh - fixture: a top-level test file referencing baz-testonly.sh
# and precedence-test.sh, neither of which any non-test code calls.
echo "would test: scripts/baz-testonly.sh and scripts/precedence-test.sh"
