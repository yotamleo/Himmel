#!/usr/bin/env bash
# scripts/release/check-version-tag.sh - VERSION must not be behind the X.Y.Z base
# of the highest v* tag (HIMMEL-4417). `himmelctl --version` and the config feed's
# himmel.version read VERSION; a stale one mis-attributes every build.
#
# Usage: check-version-tag.sh [--root <repo>]
# Exit: 0 match or VERSION ahead of the tag (or no tags to compare against -
# prints SKIP), 1 VERSION behind the tag, not bare X.Y.Z, or git failed, 2 usage.
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
if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "check-version-tag: VERSION must be bare X.Y.Z (got '$ver')" >&2
    exit 1
fi

# a failed lookup must not read as "no tags" (that would silently disable the check)
if ! tags=$(git -C "$ROOT" tag --list 'v[0-9]*.[0-9]*.[0-9]*' 2>&1); then
    echo "check-version-tag: git tag --list failed in $ROOT: $tags" >&2
    exit 1
fi
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

# VERSION may be AHEAD of the tag (the bump PR lands before the first tag of a
# new line - docs/release/v1-checklist.md step 1; cut-tag.sh enforces equality
# at cut time). It must never be BEHIND.
top=$(printf '%s\n%s\n' "$ver" "$base" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
if [ "$ver" != "$base" ] && [ "$top" = "$base" ]; then
    echo "check-version-tag: VERSION is $ver but the latest tag $tag is at $base - bump VERSION (and the release-tracking files, docs/release/v1-checklist.md) before tagging" >&2
    exit 1
fi
if [ "$ver" = "$base" ]; then
    echo "check-version-tag: ok - VERSION $ver matches $tag"
else
    echo "check-version-tag: ok - VERSION $ver is ahead of the latest tag $tag (bump landed, tag pending)"
fi
