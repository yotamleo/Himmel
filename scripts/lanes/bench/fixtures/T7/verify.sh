#!/usr/bin/env bash
# T7 verifier — run with cwd = the materialized fixture dir.
# exit 0 = PASS, non-zero = FAIL.
set -u
FIX="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")/../../lib" && pwd)/verify-common.sh"

fail() { echo "T7 FAIL: $1" >&2; exit 1; }

# 1. No collateral damage outside the sanctioned set.
assert_only_paths_changed "$FIX/input" "$FIX/manifest.txt" || exit 1

# 2. The old graphify version must be gone from the pin list and the installer.
# Scoped to tools/ and scripts/ ON PURPOSE: CHANGELOG.md's RELEASED 2026-07-14
# section legitimately records "Bump graphify pin to 0.12.3" as history and must
# survive untouched, so a tree-wide assert_no_hits here would fail every run.
assert_no_hits '0\.12\.3' tools scripts || fail "old version 0.12.3 still present"

# 3. The new version must be pinned in pins.env.
grep -Eq '^GRAPHIFY_VERSION=0\.13\.0$' tools/pins.env \
    || fail "tools/pins.env does not pin GRAPHIFY_VERSION=0.13.0"

# 4. The installer must carry the new version in BOTH the variable and the URL.
grep -Fq 'local version="0.13.0"' scripts/install-tools.sh \
    || fail "install-tools.sh graphify version variable not bumped"
grep -Fq 'graphify/v0.13.0/' scripts/install-tools.sh \
    || fail "install-tools.sh download URL not bumped"

# 5. The other pins must be untouched.
grep -Eq '^SHELLCHECK_VERSION=0\.10\.0$' tools/pins.env || fail "shellcheck pin altered"
grep -Eq '^RIPGREP_VERSION=14\.1\.1$'    tools/pins.env || fail "ripgrep pin altered"
grep -Eq '^JQ_VERSION=1\.7\.1$'          tools/pins.env || fail "jq pin altered"

# 6. The CHANGELOG line exists, in the exact format, inside ## Unreleased.
grep -Eq '^- Bump graphify pin to 0\.13\.0$' CHANGELOG.md \
    || fail "CHANGELOG.md missing the exact '- Bump graphify pin to 0.13.0' line"

# It must land in the Unreleased section, i.e. before the next '## ' heading.
unreleased_block="$(awk '/^## Unreleased$/{f=1;next} /^## /{f=0} f' CHANGELOG.md)"
printf '%s\n' "$unreleased_block" | grep -Eq '^- Bump graphify pin to 0\.13\.0$' \
    || fail "the graphify line is not inside the ## Unreleased section"

# The released section must be untouched.
grep -Eq '^## 2026-07-14$' CHANGELOG.md || fail "released heading altered"

echo "T7 PASS"
exit 0
