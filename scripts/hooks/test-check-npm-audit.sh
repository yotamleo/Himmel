#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-npm-audit.sh.
#
# Scope: the package-DISCOVERY logic, which is the thing the HIMMEL-179
# follow-up changed (find scripts -maxdepth 3 → git ls-files all committed
# packages). The twin of test-check-npm-licenses.sh. We do NOT run `npm audit`
# here — that needs network + npm installs and tests the vuln verdict, not the
# enumeration. We build a throwaway git repo mirroring the real package.json
# layout and assert:
#   1. the NEW source `git ls-files '*package.json' :(exclude)*/node_modules/*`
#      finds ALL committed packages (incl. the 4 formerly-missed ones), and
#   2. the OLD `find scripts -maxdepth 3` pattern would have MISSED them
#      (regression guard), and the pattern is GONE from the script, and
#   3. the node_modules exclude keeps tracked-but-nested deps out (defensive), and
#   4. the git-failure path fails closed (exit 1).
#
# It ALSO covers the self-install node_modules fallback (HIMMEL-232, twin
# parity with check-npm-licenses.sh): with a stubbed `npm` on PATH (hermetic,
# no network) we assert the install runs before `npm audit` and that an install
# failure blocks the gate fail-closed (skips audit).
#
# Usage: bash scripts/hooks/test-check-npm-audit.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
AUDIT_SH="$SCRIPT_DIR/check-npm-audit.sh"

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
# check-npm-audit.sh) finds all 6 committed packages and excludes both
# node_modules entries.
new_out=$( cd "$REPO" && git ls-files '*package.json' ':(exclude)*/node_modules/*' | sort )
assert_eq "new git-ls-files enumeration finds all 6 committed packages" "$EXPECTED_ALL" "$new_out"

# Case 2: the 4 formerly-missed packages ARE in the new output (explicit) —
# the regression the broadening fixes (packages OUTSIDE scripts/).
missed=$(printf '%s\n' \
    marketplace/plugins/obsidian-triage/tools/package.json \
    marketplace/plugins/telegram-himmel/package.json \
    plugins/himmel-gh/package.json \
    plugins/himmel-jira/package.json)
present=$( printf '%s\n' "$missed" | while IFS= read -r m; do
    printf '%s\n' "$new_out" | grep -qxF "$m" && echo "$m"
done | sort )
assert_eq "all 4 formerly-missed packages (outside scripts/) are covered now" "$(printf '%s' "$missed" | sort)" "$present"

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

# Case 5: regression guard — the OLD `find scripts -maxdepth 3` enumeration is
# GONE from the script itself (the broadening must have replaced it).
if grep -q 'find scripts -maxdepth 3' "$AUDIT_SH"; then
    echo "FAIL old 'find scripts -maxdepth 3' enumeration removed from check-npm-audit.sh"
    FAILED=$((FAILED + 1))
else
    echo "PASS old 'find scripts -maxdepth 3' enumeration removed from check-npm-audit.sh"
fi

# Case 6: the script DOES use the new git ls-files enumeration source.
if grep -q "git ls-files '\*package.json' ':(exclude)\*/node_modules/\*'" "$AUDIT_SH"; then
    echo "PASS check-npm-audit.sh uses the git ls-files enumeration source"
else
    echo "FAIL check-npm-audit.sh uses the git ls-files enumeration source"
    FAILED=$((FAILED + 1))
fi

# Case 7: git-failure path fails closed — run the script outside any git repo
# so `git ls-files` errors, and assert it exits 1 (not 0). mktemp -d is not a
# git repo; GIT_CEILING_DIRECTORIES stops git walking up into a real repo.
nongit=$(mktemp -d)
audit_rc=0
( cd "$nongit" && GIT_CEILING_DIRECTORIES="$nongit" bash "$AUDIT_SH" >/dev/null 2>&1 ) || audit_rc=$?
rm -rf "$nongit"
assert_eq "git-failure path fails closed (exit 1)" "1" "$audit_rc"

# --- self-install fallback (HIMMEL-232) -------------------------------------
# These cases exercise the NEW self-install block end-to-end. They run the real
# script against a one-package repo with NO node_modules, but with a stubbed
# `npm` first on PATH so the test is hermetic (no network, no real installs).
# The stub logs each invocation to $NPM_LOG and obeys $NPM_FAIL_ON (a regex of
# the first npm subcommand to fail on, e.g. "ci|install"); everything else
# succeeds. A real git is required and used (we build an actual repo).

# Build a tiny one-package repo with no node_modules. $1 = "lock" to also
# commit a package-lock.json (selects the `npm ci` branch).
make_install_repo() {
    local mode="$1" dir
    dir=$(mktemp -d)
    (
        cd "$dir" || exit 1
        git init -q -b main
        git config user.email t@t
        git config user.name t
        mkdir -p scripts/jira
        echo '{"name":"x","license":"MIT"}' > scripts/jira/package.json
        if [ "$mode" = "lock" ]; then
            echo '{"name":"x","lockfileVersion":3}' > scripts/jira/package-lock.json
        fi
        git add -A
        git -c commit.gpgsign=false commit -q -m "init"
    )
    echo "$dir"
}

# Create a stub-npm dir; the stub appends "$1" (subcommand) to $NPM_LOG and
# exits 1 when "$1" matches the $NPM_FAIL_ON regex.
make_npm_stub() {
    local dir
    dir=$(mktemp -d)
    cat > "$dir/npm" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$NPM_LOG"
if [ -n "${NPM_FAIL_ON:-}" ] && printf '%s' "$1" | grep -Eq "^(${NPM_FAIL_ON})$"; then
    exit 1
fi
exit 0
STUB
    chmod +x "$dir/npm"
    echo "$dir"
}

NPM_STUB=$(make_npm_stub)

# Case 8: node_modules missing + package-lock.json present → self-install
# triggers via `npm ci`, then `npm audit` runs; gate passes (exit 0).
repo_lock=$(make_install_repo lock)
log_lock=$(mktemp)
rc=0
( cd "$repo_lock" && PATH="$NPM_STUB:$PATH" NPM_LOG="$log_lock" NPM_FAIL_ON="" bash "$AUDIT_SH" >/dev/null 2>&1 ) || rc=$?
got_lock=$(tr '\n' ' ' < "$log_lock" | sed 's/ *$//')
assert_eq "self-install (lockfile) runs npm ci then npm audit" "ci audit" "$got_lock"
assert_eq "self-install (lockfile) gate passes when install+audit ok (exit 0)" "0" "$rc"
rm -rf "$repo_lock"; rm -f "$log_lock"

# Case 9: node_modules + package-lock.json BOTH missing, no bun signals →
# gate FAILS LOUD (exit 1) with an actionable ENOLOCK message. No npm
# operations should run (no install, no audit). Fail-closed.
repo_nolock=$(make_install_repo nolock)
rc=0
out_nolock=$( cd "$repo_nolock" && PATH="$NPM_STUB:$PATH" NPM_LOG="/dev/null" bash "$AUDIT_SH" 2>&1 ) || rc=$?
assert_eq "no-lockfile npm pkg → gate blocks (exit 1)" "1" "$rc"
if printf '%s' "$out_nolock" | grep -q 'package-lock.json\|package-lock-only'; then
    echo "PASS no-lockfile npm pkg → ENOLOCK message mentions package-lock.json and fix"
else
    echo "FAIL no-lockfile npm pkg → ENOLOCK message mentions package-lock.json and fix"
    echo "     output: $out_nolock"
    FAILED=$((FAILED + 1))
fi
rm -rf "$repo_nolock"

# Case 10: install FAILS (npm ci errors) → gate blocks (exit 1) and `npm audit`
# is NEVER reached (continue skips it). Fail-closed parity with the license twin.
repo_fail=$(make_install_repo lock)
log_fail=$(mktemp)
rc=0
( cd "$repo_fail" && PATH="$NPM_STUB:$PATH" NPM_LOG="$log_fail" NPM_FAIL_ON="ci|install" bash "$AUDIT_SH" >/dev/null 2>&1 ) || rc=$?
got_fail=$(tr '\n' ' ' < "$log_fail" | sed 's/ *$//')
assert_eq "install failure → gate blocks (exit 1)" "1" "$rc"
assert_eq "install failure → npm audit skipped (continue), only ci attempted" "ci" "$got_fail"
rm -rf "$repo_fail"; rm -f "$log_fail"

rm -rf "$NPM_STUB"

# --- bun-package skip (HIMMEL-296) ------------------------------------------
# Build a one-package repo where the package is a bun package. Two variants:
# (a) bun.lock present (runtime bun.lock signal); (b) no bun.lock but
# package.json scripts use `bun install` (fresh-checkout signal).

make_bun_repo() {
    local mode="$1" dir  # mode: "lockfile" | "scripts"
    dir=$(mktemp -d)
    (
        cd "$dir" || exit 1
        git init -q -b main
        git config user.email t@t
        git config user.name t
        mkdir -p mypkg
        if [ "$mode" = "scripts" ]; then
            printf '{"name":"bun-pkg","scripts":{"start":"bun install --no-summary && bun server.ts"},"dependencies":{}}\n' > mypkg/package.json
        else
            printf '{"name":"bun-pkg","scripts":{"start":"bun server.ts"},"dependencies":{}}\n' > mypkg/package.json
            touch mypkg/bun.lock
        fi
        git add -A
        git -c commit.gpgsign=false commit -q -m "init"
    )
    echo "$dir"
}

# Case 11: bun.lock present → gate prints skip notice, exits 0 (not an npm error).
repo_bun_lock=$(make_bun_repo lockfile)
rc=0
out_bun_lock=$( cd "$repo_bun_lock" && bash "$AUDIT_SH" 2>&1 ) || rc=$?
assert_eq "bun.lock present → gate exits 0 (skip, not error)" "0" "$rc"
if printf '%s' "$out_bun_lock" | grep -q 'skipping.*bun'; then
    echo "PASS bun.lock present → skip notice printed"
else
    echo "FAIL bun.lock present → skip notice printed"
    echo "     output: $out_bun_lock"
    FAILED=$((FAILED + 1))
fi
rm -rf "$repo_bun_lock"

# Case 12: no bun.lock but package.json scripts use 'bun install' → skip notice,
# exits 0. Covers fresh-checkout where bun.lock is gitignored.
repo_bun_scripts=$(make_bun_repo scripts)
rc=0
out_bun_scripts=$( cd "$repo_bun_scripts" && bash "$AUDIT_SH" 2>&1 ) || rc=$?
assert_eq "bun-install-scripts, no bun.lock → gate exits 0 (skip, not error)" "0" "$rc"
if printf '%s' "$out_bun_scripts" | grep -q 'skipping.*bun'; then
    echo "PASS bun-install-scripts → skip notice printed"
else
    echo "FAIL bun-install-scripts → skip notice printed"
    echo "     output: $out_bun_scripts"
    FAILED=$((FAILED + 1))
fi
rm -rf "$repo_bun_scripts"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
