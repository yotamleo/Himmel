#!/usr/bin/env bash
set -u
FIX="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091  # verify-common.sh is sourced at runtime; linted standalone by pre-commit
. "$(cd "$(dirname "$0")/../../lib" && pwd)/verify-common.sh"
assert_only_paths_changed "$FIX/input" "$FIX/manifest.txt" || exit 1

NEW_VERSION="1.3.0"

PKG_FILES="package.json packages/core/package.json packages/utils/package.json tools/codegen/scripts/package.json examples/demo-app/package.json"
ALL_JSON_FILES="$PKG_FILES package-lock.json"

fail=0

# Every JSON file must still parse.
for f in $ALL_JSON_FILES; do
    if [ ! -f "$f" ]; then
        echo "verify: missing file: $f" >&2
        fail=1
        continue
    fi
    assert_json_parses "$f" || fail=1
done

# Every one of the 5 package.json files must declare left-pad at the new
# version (also guards against the dependency being deleted outright).
for f in $PKG_FILES; do
    if [ ! -f "$f" ]; then
        continue
    fi
    if ! grep -Eq '"left-pad"[[:space:]]*:[[:space:]]*"1\.3\.0"' "$f"; then
        echo "verify: $f does not declare left-pad at $NEW_VERSION" >&2
        fail=1
    fi
done

# The lockfile must still reference left-pad, and at the new version.
if [ -f package-lock.json ]; then
    if ! grep -Eq '"left-pad"' package-lock.json; then
        echo "verify: left-pad entries removed from package-lock.json" >&2
        fail=1
    fi
    if ! grep -Eq '"1\.3\.0"' package-lock.json; then
        echo "verify: package-lock.json has no $NEW_VERSION stanza for left-pad" >&2
        fail=1
    fi
fi

# Zero remaining references to the old version anywhere in the tree.
assert_no_hits '1\.1\.0' . || fail=1

[ "$fail" -eq 0 ]
