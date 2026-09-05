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
# Plus the npm VERSION floor (HIMMEL-2440): npm < 11 bundles a registry public
# key that expired 2025-01-29, so `npm audit signatures` fails every package
# with EEXPIREDSIGNATUREKEY on Debian/Ubuntu's apt npm (9.2.0) and refuses every
# push. The gate must name the tool and the remedy instead of surfacing the raw
# registry error — and must NOT run the signature check through a verifier that
# cannot verify (cases 6 and 7).
#
# The gate enumerates `find scripts -maxdepth 3 -name package.json` relative to
# CWD, so each case runs from a temp dir holding scripts/<pkg>/.
#
# Usage: bash scripts/hooks/test-check-npm-audit-signatures.sh
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

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
    dir=$(mktemp -d "${TMPDIR:-/tmp}/cr-npmsig-pkg.XXXXXX") || return 1
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
if grepq "$out1" 'nothing to verify'; then
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
if grepq "$out2" 'no node_modules'; then
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
if grepq "$out3" 'skipping.*bun'; then
    echo "PASS bun.lock pkg → bun skip notice printed"
else
    echo "FAIL bun.lock pkg → bun skip notice printed"
    echo "     output: $out3"
    FAILED=$((FAILED + 1))
fi
rm -rf "$d3"

# Case 4: prod deps + node_modules present → reaches `npm audit signatures`.
# Stub npm (hermetic) to log the subcommand and succeed.
# The stub answers --version from $NPM_STUB_VERSION (default: above the floor)
# and logs every other subcommand, so a case can assert both the version the
# gate saw and whether it went on to invoke `npm audit signatures`.
npm_stub=$(mktemp -d "${TMPDIR:-/tmp}/cr-npmsig-npmstub.XXXXXX") || exit 1
cat > "$npm_stub/npm" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
    printf '%s\n' "${NPM_STUB_VERSION:-11.19.1}"
    exit 0
fi
echo "$1 $2" >> "$NPM_LOG"
exit 0
STUB
chmod +x "$npm_stub/npm"

# run_with_npm <version> <pkgdir> <subcommand-log> <output-file> — run the gate
# with the stub npm reporting <version>. Sets $rc and writes the gate's combined
# output to <output-file>. Deliberately NOT an echoing helper: `x=$(fn)` runs fn
# in a subshell, so an $rc assigned inside it never reaches the caller and every
# rc assertion silently reads the PREVIOUS case's value instead.
run_with_npm() {
    rc=0
    ( cd "$2" && PATH="$npm_stub:$PATH" NPM_LOG="$3" NPM_STUB_VERSION="$1" bash "$SIG_SH" ) > "$4" 2>&1 || rc=$?
}

d4=$(make_pkg '{"name":"p","dependencies":{"leftpad":"1.0.0"}}' modules)
log4=$(mktemp)
rc=0
( cd "$d4" && PATH="$npm_stub:$PATH" NPM_LOG="$log4" bash "$SIG_SH" >/dev/null 2>&1 ) || rc=$?
got4=$(tr '\n' ' ' < "$log4" | sed 's/ *$//')
assert_eq "prod-dep pkg + node_modules → gate reaches npm audit signatures" "audit signatures" "$got4"
assert_eq "prod-dep pkg + node_modules → gate passes when signatures ok (exit 0)" "0" "$rc"
rm -rf "$d4"; rm -f "$log4"

# Case 5: optionalDependencies-only (empty/absent `dependencies`), no
# node_modules → must NOT be treated as zero-dep. npm installs optional (and
# peer) deps under --omit=dev, so they have signable tarballs. The gate must
# fall through to the fail-closed block (exit 1), NOT skip.
d5=$(make_pkg '{"name":"o","optionalDependencies":{"fsevents":"2.3.0"}}')
rc=0
out5=$( cd "$d5" && bash "$SIG_SH" 2>&1 ) || rc=$?
assert_eq "optionalDependencies-only pkg, no node_modules → gate blocks (exit 1, not skipped)" "1" "$rc"
if grepq "$out5" 'nothing to verify'; then
    echo "FAIL optionalDependencies-only pkg was wrongly skipped as zero-dep"
    echo "     output: $out5"
    FAILED=$((FAILED + 1))
else
    echo "PASS optionalDependencies-only pkg not skipped (signature gate stays active)"
fi
rm -rf "$d5"

# --- HIMMEL-2440: the npm version floor -------------------------------------

# Case 6: apt-Ubuntu npm 9.2.0 → BLOCK, naming the floor and the pinned-major
# remedy, and WITHOUT running the signature check through a verifier whose
# bundled key has expired (the subcommand log must stay empty).
d6=$(make_pkg '{"name":"p","dependencies":{"leftpad":"1.0.0"}}' modules)
log6=$(mktemp "${TMPDIR:-/tmp}/cr-npmsig-log.XXXXXX") || exit 1
of6=$(mktemp "${TMPDIR:-/tmp}/cr-npmsig-out.XXXXXX") || exit 1
run_with_npm "9.2.0" "$d6" "$log6" "$of6"
out6=$(cat "$of6")
assert_eq "npm 9.2.0 → gate blocks (exit 1)" "1" "$rc"
assert_eq "npm 9.2.0 → npm audit signatures is never invoked" "" "$(tr -d '\n' < "$log6")"
if grepq "$out6" -F 'need npm >= 11'; then
    echo "PASS npm 9.2.0 → names the version floor"
else
    echo "FAIL npm 9.2.0 → names the version floor"
    echo "     output: $out6"
    FAILED=$((FAILED + 1))
fi
if grepq "$out6" -F 'npm install -g npm@11'; then
    echo "PASS npm 9.2.0 → names the pinned-major remedy"
else
    echo "FAIL npm 9.2.0 → names the pinned-major remedy"
    echo "     output: $out6"
    FAILED=$((FAILED + 1))
fi
rm -rf "$d6"; rm -f "$log6" "$of6"

# Case 7 (control): npm 11.19.1 → the existing path runs unchanged. The floor
# must refuse old npm only, never become a second way to skip the check.
d7=$(make_pkg '{"name":"p","dependencies":{"leftpad":"1.0.0"}}' modules)
log7=$(mktemp "${TMPDIR:-/tmp}/cr-npmsig-log.XXXXXX") || exit 1
of7=$(mktemp "${TMPDIR:-/tmp}/cr-npmsig-out.XXXXXX") || exit 1
run_with_npm "11.19.1" "$d7" "$log7" "$of7"
assert_eq "npm 11.19.1 → gate passes (exit 0)" "0" "$rc"
assert_eq "npm 11.19.1 → gate still reaches npm audit signatures" "audit signatures" "$(tr '\n' ' ' < "$log7" | sed 's/ *$//')"
rm -rf "$d7"; rm -f "$log7" "$of7"

rm -rf "$npm_stub"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
