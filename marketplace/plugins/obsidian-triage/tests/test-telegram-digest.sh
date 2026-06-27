#!/usr/bin/env bash
# Thin wrapper so the pure-node LUNA-91 promotion-digest unit test
# (test-telegram-digest.mjs) is picked up by the `bash tests/test-*.sh` runner.
set -u -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
exec node "$PLUGIN_DIR/tests/test-telegram-digest.mjs"
