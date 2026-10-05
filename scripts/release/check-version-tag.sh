#!/usr/bin/env bash
# scripts/release/check-version-tag.sh - VERSION must equal the X.Y.Z base of the
# highest v* tag (HIMMEL-4417). `himmelctl --version` and the config feed's
# himmel.version read VERSION; a stale one mis-attributes every build.
#
# Usage: check-version-tag.sh [--root <repo>]
# Exit: 0 match (or no tags to compare against - prints SKIP), 1 mismatch or a
# VERSION that is not bare X.Y.Z, 2 usage.
#
# Tags are compared by their X.Y.Z base, numerically: a bare vX.Y.Z sorts
# BEFORE its own -pre tags under git's version sort, so `--sort` is not used.
# Platform guard: Linux/macOS bash 3.2+ (git, sed, sort only).
set -u

ROOT="."
case "${1:-}" in
    "") ;;
    --root) [ "$#" -eq 2 ] || { echo "usage: check-version-tag.sh [--root <repo>]" >&2; exit 2; }; ROOT="$2" ;;
    *) echo "usage: check-version-tag.sh [--root <repo>]" >&2; exit 2 ;;
esac

ver=$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null)
if ! printf '%s\n' "$ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "check-version-tag: VERSION must be bare X.Y.Z (got '$ver')" >&2
    exit 1
fi

tags=$(git -C "$ROOT" tag --list 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null)
if [ -z "$tags" ]; then
    echo "check-version-tag: SKIP - no v* tags in this checkout, cannot compare VERSION ($ver)"
    exit 0
fi

# "<base> <tag>" per tag, highest base last; ties (a bare tag and its -pre tags) are the same base.
latest=$(printf '%s\n' "$tags" \
    | sed -E 's/^v([0-9]+\.[0-9]+\.[0-9]+).*$/\1 &/' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
base="${latest%% *}"
tag="${latest#* }"

if [ "$ver" != "$base" ]; then
    echo "check-version-tag: VERSION is $ver but the latest tag $tag is at $base - bump VERSION (and the release-tracking files, docs/release/v1-checklist.md) before tagging" >&2
    exit 1
fi
echo "check-version-tag: ok - VERSION $ver matches $tag"
