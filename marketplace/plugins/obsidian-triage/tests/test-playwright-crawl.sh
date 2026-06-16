#!/usr/bin/env bash
# Smoke tests for LUNA-27 Playwright crawlers.
#
# Scope: validates that the three .mjs files parse, the package.json
# declares the right deps, the storage-state path is consistent across
# code + docs, and the crawler scripts exit rc=2 with a clear message
# when storage state is missing.
#
# Does NOT actually launch a browser or hit the network. The full
# crawl is calibration territory (manual, post-auth).

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"

pass=0
fail=0

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

# -- Test 1: all three .mjs files exist + parse via node --check ----------
echo "Test 1: .mjs files exist and parse"
for f in playwright-auth-save.mjs playwright-crawl-x.mjs playwright-crawl-youtube.mjs; do
    path="$TOOLS_DIR/$f"
    if [ ! -r "$path" ]; then
        assert "$f exists" "yes" "no"
        continue
    fi
    assert "$f exists" "yes" "yes"
    if node --check "$path" 2>/dev/null; then
        parsed=ok
    else
        parsed=fail
    fi
    assert "$f parses (node --check)" "ok" "$parsed"
done

# -- Test 2: package.json declares playwright + js-yaml deps --------------
echo "Test 2: package.json declares required deps"
pkg="$TOOLS_DIR/package.json"
if [ -r "$pkg" ]; then
    assert "package.json exists" "yes" "yes"
    if grep -q '"playwright"' "$pkg"; then has_pw=yes; else has_pw=no; fi
    assert "package.json declares playwright" "yes" "$has_pw"
    if grep -q '"js-yaml"' "$pkg"; then has_yaml=yes; else has_yaml=no; fi
    assert "package.json declares js-yaml" "yes" "$has_yaml"
    # Pin check — playwright should be pinned to 1.58.x for stability.
    if grep -qE '"playwright":[[:space:]]*"1\.58\.' "$pkg"; then pinned=yes; else pinned=no; fi
    assert "package.json pins playwright 1.58.x" "yes" "$pinned"
else
    assert "package.json exists" "yes" "no"
fi

# -- Test 3: storage-state path is consistent across code + README -------
echo "Test 3: storage-state path consistency"
# Canonical path: ~/.luna/playwright-state/<service>.json
# Each .mjs file should reference .luna/playwright-state and the service name.
auth="$TOOLS_DIR/playwright-auth-save.mjs"
cx="$TOOLS_DIR/playwright-crawl-x.mjs"
cy="$TOOLS_DIR/playwright-crawl-youtube.mjs"
readme="$TOOLS_DIR/README.md"
for f in "$auth" "$cx" "$cy" "$readme"; do
    if grep -q '\.luna' "$f" && grep -q 'playwright-state' "$f"; then
        has_path=yes
    else
        has_path=no
    fi
    assert "$(basename "$f") references ~/.luna/playwright-state/" "yes" "$has_path"
done
# crawl-x mentions x.json, crawl-youtube mentions youtube.json.
if grep -q 'x\.json' "$cx"; then x_state=yes; else x_state=no; fi
assert "crawl-x.mjs references x.json" "yes" "$x_state"
if grep -q 'youtube\.json' "$cy"; then yt_state=yes; else yt_state=no; fi
assert "crawl-youtube.mjs references youtube.json" "yes" "$yt_state"

# -- Test 4: crawler scripts exit rc=2 on missing storage_state ----------
echo "Test 4: crawler scripts exit rc=2 when storage_state missing"
# Strategy: run with a vault that exists (TOOLS_DIR is fine — Clippings/
# missing is a separate failure mode, but the storage-state check fires
# FIRST). To isolate, point HOME at a temp dir so the state path doesn't
# exist. Use --dry-run so even if the check accidentally passes, nothing
# touches the FS.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fake_vault="$tmpdir/vault"
mkdir -p "$fake_vault/Clippings"

# x crawler
HOME_SAVED="${HOME:-}"
HOME="$tmpdir" USERPROFILE="$tmpdir" node "$cx" --vault "$fake_vault" --dry-run >/dev/null 2>"$tmpdir/x.err"
x_rc=$?
HOME="$HOME_SAVED"
assert "crawl-x.mjs rc=2 on missing storage_state" "2" "$x_rc"
if grep -qi 'storage_state missing\|playwright-auth-save' "$tmpdir/x.err"; then x_msg=yes; else x_msg=no; fi
assert "crawl-x.mjs error msg mentions auth-save" "yes" "$x_msg"

HOME="$tmpdir" USERPROFILE="$tmpdir" node "$cy" --vault "$fake_vault" --dry-run >/dev/null 2>"$tmpdir/y.err"
y_rc=$?
HOME="$HOME_SAVED"
assert "crawl-youtube.mjs rc=2 on missing storage_state" "2" "$y_rc"
if grep -qi 'storage_state missing\|playwright-auth-save' "$tmpdir/y.err"; then y_msg=yes; else y_msg=no; fi
assert "crawl-youtube.mjs error msg mentions auth-save" "yes" "$y_msg"

# -- Test 5: --dry-run flag prevents write side-effects ------------------
# Verified at the code level: dryRun branch returns BEFORE any
# writeFileSync call. Smoke-check the branch is present in both crawlers.
echo "Test 5: --dry-run flag short-circuits write path"
for f in "$cx" "$cy"; do
    if grep -q 'dryRun' "$f" && grep -q 'would crawl' "$f"; then
        has_dry=yes
    else
        has_dry=no
    fi
    assert "$(basename "$f") implements --dry-run" "yes" "$has_dry"
done

# -- Test 6: G-3 + revert-on-failure machinery present -------------------
echo "Test 6: G-3 invariant + revert-on-failure present"
for f in "$cx" "$cy"; do
    if grep -q 'G-3' "$f" && grep -q 'reverted' "$f"; then
        has_g3=yes
    else
        has_g3=no
    fi
    assert "$(basename "$f") implements G-3 + revert" "yes" "$has_g3"
done

# -- Test 7: YAML parse-validate on post-write frontmatter ---------------
echo "Test 7: YAML parse-validate via js-yaml present"
for f in "$cx" "$cy"; do
    if grep -q "js-yaml" "$f"; then has_yaml=yes; else has_yaml=no; fi
    assert "$(basename "$f") uses js-yaml" "yes" "$has_yaml"
done

# -- Test 8: secrets — storage_state path never logged with contents -----
# We log the PATH (acceptable, helps debugging) but never read or log the
# file's contents. Defensive check: no `readFileSync(.*state)` patterns
# in the crawler scripts beyond passing to playwright.
echo "Test 8: storage_state never read by app code"
for f in "$cx" "$cy"; do
    # Grep for any explicit read of the state file.
    if grep -E 'readFileSync\(.*statePath' "$f" >/dev/null; then
        leak=yes
    else
        leak=no
    fi
    assert "$(basename "$f") does NOT read storage_state contents" "no" "$leak"
done

# -- Summary -------------------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
