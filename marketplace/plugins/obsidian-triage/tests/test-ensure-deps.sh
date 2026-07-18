#!/usr/bin/env bash
# marketplace/plugins/obsidian-triage/tests/test-ensure-deps.sh — smoke
# tests for tools/ensure-deps.sh (HIMMEL-1135).
#
# The bug this preflight fixes: tools/.gitignore ignores node_modules/, so
# any git-derived copy of tools/ (most critically the Claude plugin cache
# copy, populated straight from git) can never carry deps. Runbooks that
# shelled out to js-yaml-importing tools from the cache path threw
# `Cannot find package 'js-yaml'`, reverted the write, and (separately,
# HIMMEL-1136, not this ticket) still exited 0 — a whole day of enrichment
# silently doing nothing.
#
# Coverage (all hermetic — a fake `npm` on PATH stands in for the real
# installer so these tests never touch the network):
#   1. deps already present -> fast no-op success, npm never invoked.
#   2. deps missing, npm absent from PATH -> loud non-zero + remediation.
#   3. deps missing, npm install fails -> loud non-zero + remediation.
#   4. deps missing, npm install "succeeds" but leaves js-yaml absent
#      (the silent-success trap this ticket exists to kill) -> still
#      loud non-zero, never a false-positive 0.
#   5. deps missing, npm install genuinely succeeds -> installs + exits 0,
#      and PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 was set for the install.
#   6. (best-effort, real npm/network) sanity check against the REAL
#      tools/ dir — skipped if npm/network is unavailable.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
SCRIPT="$TOOLS_DIR/ensure-deps.sh"
# Resolved ONCE, before any test restricts PATH — Test 2 below runs with a
# PATH that deliberately has no npm; if we invoked plain `bash` under that
# same restricted PATH, `bash` itself would fail to resolve too (127) and
# the assertion would never reach ensure-deps.sh's own logic.
BASH_BIN="$(command -v bash)"

pass=0
fail=0
assert() {
  local desc="$1"; shift
  if "$@"; then
    pass=$((pass+1))
    echo "  PASS  $desc"
  else
    fail=$((fail+1))
    echo "  FAIL  $desc"
  fi
}

echo "Test 0: script exists and parses"
assert "ensure-deps.sh exists" test -r "$SCRIPT"
assert "ensure-deps.sh parses (bash -n)" bash -n "$SCRIPT"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# A minimal fake tools/ dir: only ensure-deps.sh + package.json copied over
# (never node_modules) so each case starts from a clean, deps-absent state.
fake_tools() {
  local dir="$tmpdir/$1/tools"
  mkdir -p "$dir"
  cp "$SCRIPT" "$dir/ensure-deps.sh"
  cp "$TOOLS_DIR/package.json" "$dir/package.json"
  printf '%s\n' "$dir"
}

# -- Test 1: deps already present -> fast no-op, npm never invoked ------
echo "Test 1: deps present -> fast no-op success"
dir1="$(fake_tools case1)"
mkdir -p "$dir1/node_modules/js-yaml"
echo '{"name":"js-yaml"}' > "$dir1/node_modules/js-yaml/package.json"

sentinel1="$tmpdir/npm-invoked-case1"
mkdir -p "$tmpdir/bin1"
cat > "$tmpdir/bin1/npm" <<EOF
#!/usr/bin/env bash
echo invoked > "$sentinel1"
exit 0
EOF
chmod +x "$tmpdir/bin1/npm"

PATH="$tmpdir/bin1:$PATH" "$BASH_BIN" "$dir1/ensure-deps.sh" >"$tmpdir/out1.log" 2>&1
rc1=$?
assert "rc=0 when js-yaml already present" test "$rc1" -eq 0
assert "npm was NEVER invoked (fast path skips install)" test ! -e "$sentinel1"

# -- Test 2: deps missing, npm absent from PATH --------------------------
# The sandbox PATH keeps `dirname` (the ONE external ensure-deps.sh needs, for
# its own TOOLS_DIR resolution) and omits only npm. A bare-empty PATH would
# also strip dirname, so TOOLS_DIR would silently resolve to $PWD and the
# npm-absent assertion below would pass for the wrong reason.
echo "Test 2: deps missing + no npm on PATH -> loud non-zero"
dir2="$(fake_tools case2)"
noop_bindir="$tmpdir/bin-empty"
mkdir -p "$noop_bindir"
dirname_bin="$(command -v dirname)"
ln -s "$dirname_bin" "$noop_bindir/dirname" 2>/dev/null \
  || cp "$dirname_bin" "$noop_bindir/dirname"
PATH="$noop_bindir" "$BASH_BIN" "$dir2/ensure-deps.sh" >"$tmpdir/out2.log" 2>&1
rc2=$?
assert "rc != 0 when npm is missing" test "$rc2" -ne 0
assert "stderr names npm as the blocker" grep -q "npm not on PATH" "$tmpdir/out2.log"
assert "js-yaml still absent (no false-positive state)" \
  test ! -f "$dir2/node_modules/js-yaml/package.json"
# Guards the above: prove the sandbox PATH did not break the script's own
# path resolution, i.e. that it really reached the npm check (codex-1).
assert "dirname stayed resolvable (test failed for the RIGHT reason)" \
  test -z "$(grep -i 'dirname: .*not found' "$tmpdir/out2.log" || true)"
assert "remediation cites the real tools dir, not \$PWD" \
  grep -q "$dir2" "$tmpdir/out2.log"

# -- Test 3: deps missing, npm install fails ------------------------------
echo "Test 3: deps missing + npm install fails -> loud non-zero"
dir3="$(fake_tools case3)"
mkdir -p "$tmpdir/bin3"
cat > "$tmpdir/bin3/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm ERR! simulated failure" >&2
exit 1
EOF
chmod +x "$tmpdir/bin3/npm"
PATH="$tmpdir/bin3:$PATH" "$BASH_BIN" "$dir3/ensure-deps.sh" >"$tmpdir/out3.log" 2>&1
rc3=$?
assert "rc != 0 when npm install fails" test "$rc3" -ne 0
assert "stderr gives an actionable remediation command" grep -q "npm install" "$tmpdir/out3.log"

# -- Test 4: npm install "succeeds" but js-yaml still absent -------------
# The exact defect class this ticket targets: never bless success on
# existence alone -- a rc=0 from npm that didn't actually deliver the
# package must still fail loud.
echo "Test 4: npm install exits 0 but js-yaml missing -> STILL non-zero (no silent success)"
dir4="$(fake_tools case4)"
mkdir -p "$tmpdir/bin4"
cat > "$tmpdir/bin4/npm" <<'EOF'
#!/usr/bin/env bash
# Pretend to succeed without actually installing anything.
exit 0
EOF
chmod +x "$tmpdir/bin4/npm"
PATH="$tmpdir/bin4:$PATH" "$BASH_BIN" "$dir4/ensure-deps.sh" >"$tmpdir/out4.log" 2>&1
rc4=$?
assert "rc != 0 when the marker is missing post-install (never silent-success)" test "$rc4" -ne 0
assert "stderr flags the still-missing package" grep -q "still missing" "$tmpdir/out4.log"

# -- Test 5: npm install genuinely succeeds ------------------------------
echo "Test 5: npm install succeeds -> installs + exits 0, browser download skipped"
dir5="$(fake_tools case5)"
mkdir -p "$tmpdir/bin5"
cat > "$tmpdir/bin5/npm" <<'EOF'
#!/usr/bin/env bash
echo "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=${PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD:-unset}" >> "$(dirname "$0")/../npm-env.log"
# Simulate a real install: materialize the js-yaml package dir.
target="$PWD/node_modules/js-yaml"
mkdir -p "$target"
echo '{"name":"js-yaml"}' > "$target/package.json"
exit 0
EOF
chmod +x "$tmpdir/bin5/npm"
PATH="$tmpdir/bin5:$PATH" "$BASH_BIN" "$dir5/ensure-deps.sh" >"$tmpdir/out5.log" 2>&1
rc5=$?
assert "rc=0 when install genuinely succeeds" test "$rc5" -eq 0
assert "js-yaml marker now present" test -f "$dir5/node_modules/js-yaml/package.json"
assert "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 was set for the install" \
  grep -q "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1" "$tmpdir/npm-env.log"
assert "install lock released after a successful run (trap cleanup)" \
  test ! -d "$dir5/.ensure-deps.lock"

# -- Test 6 (opt-in): real npm/network sanity check against the ACTUAL -----
# tools/ dir. OFF by default (needs network + mutates the real
# tools/node_modules) so the suite stays hermetic + green offline -- the
# fake-npm tests above already cover the contract. Opt in with
# RUN_REAL_NPM_TEST=1; still skipped (not failed) if npm is unavailable.
echo "Test 6: real-npm sanity check against the actual tools/ dir (opt-in)"
if [ "${RUN_REAL_NPM_TEST:-0}" != "1" ]; then
  echo "  SKIP  set RUN_REAL_NPM_TEST=1 to run the real npm integration check"
elif ! command -v npm >/dev/null 2>&1; then
  echo "  SKIP  npm not on PATH in this environment"
else
  "$BASH_BIN" "$SCRIPT" >"$tmpdir/out6.log" 2>&1
  rc6=$?
  # Opted in + npm present: a failure is a real failure, not a skip.
  assert "real ensure-deps.sh exits successfully (opted in)" test "$rc6" -eq 0
  assert "real ensure-deps.sh leaves js-yaml resolvable" \
    test -f "$TOOLS_DIR/node_modules/js-yaml/package.json"
fi

echo ""
echo "Results: $pass passed, $fail failed."
test "$fail" -eq 0
