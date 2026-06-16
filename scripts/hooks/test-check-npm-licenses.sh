#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-npm-licenses.sh.
#
# Scope: the package-DISCOVERY logic, which is the thing the HIMMEL-179 fix
# changed (find scripts -maxdepth 3 → git ls-files all committed packages).
# We do NOT run npx license-checker here — that needs network + npm installs
# and tests the license verdict, not the enumeration. We build a throwaway git
# repo mirroring the real package.json layout and assert:
#   1. the NEW source `git ls-files '*package.json' :(exclude)*/node_modules/*`
#      finds ALL committed packages (incl. the 4 formerly-missed ones), and
#   2. the OLD `find scripts -maxdepth 3` pattern would have MISSED them
#      (regression guard), and
#   3. the node_modules exclude keeps tracked-but-nested deps out (defensive).
#
# Usage: bash scripts/hooks/test-check-npm-licenses.sh
set -uo pipefail

FAILED=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        echo "     expected: $expected"
        echo "     actual:   $actual"
        FAILED=$((FAILED + 1))
    fi
}

# Build a temp git repo whose tracked package.json layout mirrors himmel's:
# 2 under scripts/ + 4 elsewhere, plus an UNTRACKED node_modules package.json
# and a TRACKED-but-nested node_modules package.json (defensive-exclude case).
make_repo() {
    local dir
    dir=$(mktemp -d)
    (
        cd "$dir" || exit 1
        git init -q -b main
        git config user.email t@t
        git config user.name t
        local pkgs=(
            scripts/himmel-run/package.json
            scripts/jira/package.json
            marketplace/plugins/obsidian-triage/tools/package.json
            marketplace/plugins/telegram-himmel/package.json
            plugins/himmel-gh/package.json
            plugins/himmel-jira/package.json
        )
        local p
        for p in "${pkgs[@]}"; do
            mkdir -p "$(dirname "$p")"
            echo '{"name":"x","license":"MIT"}' > "$p"
        done
        git add -A
        git -c commit.gpgsign=false commit -q -m "init packages"
        # Untracked node_modules package.json — git ls-files must ignore it.
        mkdir -p scripts/jira/node_modules/dep
        echo '{"name":"dep"}' > scripts/jira/node_modules/dep/package.json
        # Tracked-but-nested node_modules package.json — the defensive
        # :(exclude)*/node_modules/* pathspec must keep it out.
        mkdir -p vendor/node_modules/forced
        echo '{"name":"forced"}' > vendor/node_modules/forced/package.json
        git add -f vendor/node_modules/forced/package.json
        git -c commit.gpgsign=false commit -q -m "add nested node_modules pkg"
    )
    echo "$dir"
}

REPO=$(make_repo)
trap 'rm -rf "$REPO"' EXIT

EXPECTED_ALL=$(printf '%s\n' \
    marketplace/plugins/obsidian-triage/tools/package.json \
    marketplace/plugins/telegram-himmel/package.json \
    plugins/himmel-gh/package.json \
    plugins/himmel-jira/package.json \
    scripts/himmel-run/package.json \
    scripts/jira/package.json | sort)

# Case 1: NEW enumeration (the `git ls-files` enumeration line in
# check-npm-licenses.sh) finds all 6 committed packages and excludes both
# node_modules entries.
new_out=$( cd "$REPO" && git ls-files '*package.json' ':(exclude)*/node_modules/*' | sort )
assert_eq "new git-ls-files enumeration finds all 6 committed packages" "$EXPECTED_ALL" "$new_out"

# Case 2: the 4 formerly-missed packages ARE in the new output (explicit).
missed=$(printf '%s\n' \
    marketplace/plugins/obsidian-triage/tools/package.json \
    marketplace/plugins/telegram-himmel/package.json \
    plugins/himmel-gh/package.json \
    plugins/himmel-jira/package.json)
present=$( printf '%s\n' "$missed" | while IFS= read -r m; do
    printf '%s\n' "$new_out" | grep -qxF "$m" && echo "$m"
done | sort )
assert_eq "all 4 formerly-missed packages are covered now" "$(printf '%s' "$missed" | sort)" "$present"

# Case 3: regression guard — the OLD `find scripts -maxdepth 3` pattern finds
# only the 2 scripts/ packages and MISSES the 4 others.
old_out=$( cd "$REPO" && find scripts -maxdepth 3 -name package.json -not -path '*/node_modules/*' | sort )
EXPECTED_OLD=$(printf '%s\n' scripts/himmel-run/package.json scripts/jira/package.json | sort)
assert_eq "old find-scripts pattern catches only the 2 scripts/ packages" "$EXPECTED_OLD" "$old_out"

# Case 4: node_modules exclusion holds — neither the untracked nor the
# force-tracked nested package.json appears in the new enumeration.
if printf '%s\n' "$new_out" | grep -q 'node_modules'; then
    echo "FAIL node_modules package.json excluded from enumeration"
    FAILED=$((FAILED + 1))
else
    echo "PASS node_modules package.json excluded from enumeration"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
