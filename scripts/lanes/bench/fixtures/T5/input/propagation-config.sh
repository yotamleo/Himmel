#!/usr/bin/env bash
# Paths excluded from the public-propagation mirror.
# Every entry is a path prefix (relative to the repo root) that the
# propagation squash-and-verify step refuses to carry into the public copy.
PRIVATE_PATHS=(
    "handovers/"
    "docs/internals/"
    ".env"
    "scripts/secrets/"
)
