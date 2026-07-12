#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-npm-audit-signatures.sh.
#
# Scope: the SKIP/BLOCK branching logic (hermetic — no network, no real
# `npm audit signatures`). Focus is the HIMMEL-502 zero-prod-dep carve-out and
# the guarantee it did NOT weaken the real block:
#   1. zero-prod-dep package (devDeps only)     → SKIP (exit 0), nothing to verify.
#   2. prod-dep package, node_modules MISSING   → BLOCK (exit 1) — the gate still
#      fails closed when a signable tree was never materialized.
#   3. bun package (bun.lock)                    → SKIP (exit 0) — existing behavior.
#   4. prod-dep package + node_modules present   → reaches `npm audit signatures`
#      (asserted via a stubbed npm; hermetic).
#
# The gate enumerates `find scripts -maxdepth 3 -name package.json` relative to
# CWD, so each case runs from a temp dir holding scripts/<pkg>/.
#
# Usage: bash scripts/hooks/test-check-npm-audit-signatures.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SIG_SH="$SCRIPT_DIR/check-npm-audit-signatures.sh"

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

# Build a temp dir with one scripts/<pkg>/package.json. $1 = package.json body.
# $2 (optional) = "modules" to also create a node_modules dir; "bunlock" to add
# a bun.lock.
make_pkg() {
    local body="$1" extra="${2:-}" dir
    dir=$(mktemp -d)
    mkdir -p "$dir/scripts/testpkg"
    printf '%s\n' "$body" > "$dir/scripts/testpkg/package.json"
    if [ "$extra" = "modules" ]; then
        mkdir -p "$dir/scripts/testpkg/node_modules"
    elif [ "$extra" = "bunlock" ]; then
        touch "$dir/scripts/testpkg/bun.lock"
    fi
    echo "$dir"
}

# Case 1: zero-prod-dep (devDeps only), no node_modules → SKIP (exit 0).
d1=$(make_pkg '{"name":"z","devDependencies":{"typescript":"^6.0.0"}}')
rc=0
out1=$( cd "$d1" && bash "$SIG_SH" 2>&1 ) || rc=$?
assert_eq "zero-prod-dep pkg → gate exits 0 (skip)" "0" "$rc"
if printf '%s' "$out1" | grep -q 'nothing to verify'; then
    echo "PASS zero-prod-dep pkg → 'nothing to verify' skip notice"
else
    echo "FAIL zero-prod-dep pkg → skip notice"
    echo "     output: $out1"
    FAILED=$((FAILED + 1))
fi
rm -rf "$d1"

# Case 2: prod deps present, node_modules MISSING → BLOCK (exit 1). Proves the
# carve-out did not weaken the fail-closed block.
d2=$(make_pkg '{"name":"p","dependencies":{"leftpad":"1.0.0"}}')
rc=0
out2=$( cd "$d2" && bash "$SIG_SH" 2>&1 ) || rc=$?
assert_eq "prod-dep pkg, no node_modules → gate blocks (exit 1)" "1" "$rc"
if printf '%s' "$out2" | grep -q 'no node_modules'; then
    echo "PASS prod-dep pkg, no node_modules → block message printed"
else
    echo "FAIL prod-dep pkg, no node_modules → block message printed"
    echo "     output: $out2"
    FAILED=$((FAILED + 1))
fi
rm -rf "$d2"

# Case 3: bun package (bun.lock) → SKIP (exit 0), existing behavior preserved.
d3=$(make_pkg '{"name":"b","dependencies":{"x":"1.0.0"}}' bunlock)
rc=0
out3=$( cd "$d3" && bash "$SIG_SH" 2>&1 ) || rc=$?
assert_eq "bun.lock pkg → gate exits 0 (skip)" "0" "$rc"
if printf '%s' "$out3" | grep -q 'skipping.*bun'; then
    echo "PASS bun.lock pkg → bun skip notice printed"
else
    echo "FAIL bun.lock pkg → bun skip notice printed"
    echo "     output: $out3"
    FAILED=$((FAILED + 1))
fi
rm -rf "$d3"

# Case 4: prod deps + node_modules present → reaches `npm audit signatures`.
# Stub npm (hermetic) to log the subcommand and succeed.
npm_stub=$(mktemp -d)
cat > "$npm_stub/npm" <<'STUB'
#!/usr/bin/env bash
echo "$1 $2" >> "$NPM_LOG"
exit 0
STUB
chmod +x "$npm_stub/npm"
d4=$(make_pkg '{"name":"p","dependencies":{"leftpad":"1.0.0"}}' modules)
log4=$(mktemp)
rc=0
( cd "$d4" && PATH="$npm_stub:$PATH" NPM_LOG="$log4" bash "$SIG_SH" >/dev/null 2>&1 ) || rc=$?
got4=$(tr '\n' ' ' < "$log4" | sed 's/ *$//')
assert_eq "prod-dep pkg + node_modules → gate reaches npm audit signatures" "audit signatures" "$got4"
assert_eq "prod-dep pkg + node_modules → gate passes when signatures ok (exit 0)" "0" "$rc"
rm -rf "$d4" "$npm_stub"; rm -f "$log4"

# Case 5: optionalDependencies-only (empty/absent `dependencies`), no
# node_modules → must NOT be treated as zero-dep. npm installs optional (and
# peer) deps under --omit=dev, so they have signable tarballs. The gate must
# fall through to the fail-closed block (exit 1), NOT skip.
d5=$(make_pkg '{"name":"o","optionalDependencies":{"fsevents":"2.3.0"}}')
rc=0
out5=$( cd "$d5" && bash "$SIG_SH" 2>&1 ) || rc=$?
assert_eq "optionalDependencies-only pkg, no node_modules → gate blocks (exit 1, not skipped)" "1" "$rc"
if printf '%s' "$out5" | grep -q 'nothing to verify'; then
    echo "FAIL optionalDependencies-only pkg was wrongly skipped as zero-dep"
    echo "     output: $out5"
    FAILED=$((FAILED + 1))
else
    echo "PASS optionalDependencies-only pkg not skipped (signature gate stays active)"
fi
rm -rf "$d5"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
