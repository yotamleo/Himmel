#!/usr/bin/env bash
# scripts/lib/test-qmd-bin.sh — smoke test for qmd-bin.sh resolver.
#
# Validates:
#   1. qmd_install_hint emits the bun command (no npm).
#   2. qmd_cmd prefers the bun install when both bun-qmd and PATH-qmd exist.
#   3. qmd_cmd falls through to PATH qmd when bun install is absent.
#   4. qmd_cmd returns 127 when no qmd is available.
#   5. has_qmd matches qmd_cmd --version success.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/qmd-bin.sh
. "$SCRIPT_DIR/qmd-bin.sh"

pass=0
fail=0
assert() {
  local desc="$1"; shift
  if "$@"; then
    pass=$((pass+1))
    echo "  ok: $desc"
  else
    fail=$((fail+1))
    echo "  FAIL: $desc"
  fi
}

echo "[test-qmd-bin] qmd_install_hint emits bun command"
hint="$(qmd_install_hint)"
assert "hint mentions bun add" grep -q '^bun add ' <<<"$hint"
assert "hint mentions @tobilu/qmd" grep -q '@tobilu/qmd' <<<"$hint"
# shellcheck disable=SC2016
# Single quotes intentional — $1 expands inside the spawned bash -c subshell.
assert "hint does NOT mention npm" bash -c '! grep -q "npm install" <<<"$1"' _ "$hint"

echo "[test-qmd-bin] qmd_cmd resolver — prefer bun"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Fake bun + fake bun-qmd dist file. Use HOME override to control resolution.
mkdir -p "$tmpdir/.bun/install/global/node_modules/@tobilu/qmd/dist/cli"
echo "" > "$tmpdir/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"

# Fake bun script: prints "BUN $@" so we can verify dispatch.
mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/bun" <<'EOF'
#!/usr/bin/env bash
echo "BUN $*"
EOF
chmod +x "$tmpdir/bin/bun"

# Fake PATH qmd: prints "PATH-QMD $@"
cat > "$tmpdir/bin/qmd" <<'EOF'
#!/usr/bin/env bash
echo "PATH-QMD $*"
EOF
chmod +x "$tmpdir/bin/qmd"

HOME="$tmpdir" PATH="$tmpdir/bin:$PATH" output="$(HOME="$tmpdir" PATH="$tmpdir/bin:$PATH" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_cmd --version')"
assert "bun-direct wins when both exist" grep -q '^BUN ' <<<"$output"
assert "bun output references dist/cli/qmd.js" grep -q 'qmd.js --version' <<<"$output"

echo "[test-qmd-bin] qmd_cmd resolver — fallback to PATH qmd"
rm -rf "$tmpdir/.bun"
output="$(HOME="$tmpdir" PATH="$tmpdir/bin:$PATH" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_cmd --version')"
assert "PATH qmd used when bun install absent" grep -q '^PATH-QMD --version' <<<"$output"

echo "[test-qmd-bin] qmd_cmd resolver — none available"
rm -f "$tmpdir/bin/qmd"
rc=0
HOME="$tmpdir" PATH="$tmpdir/bin" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_cmd --version' >/dev/null 2>&1 || rc=$?
assert "rc=127 when no qmd available" test "$rc" -eq 127

# Re-create fake PATH qmd for negative has_qmd assertion (no bun, no qmd present).
rc=0
HOME="$tmpdir" PATH="$tmpdir/bin" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; has_qmd' || rc=$?
assert "has_qmd=false when no qmd available" test "$rc" -ne 0

echo "[test-qmd-bin] qmd_cmd resolver — BUN_INSTALL override"
mkdir -p "$tmpdir/custom-bun/install/global/node_modules/@tobilu/qmd/dist/cli"
echo "" > "$tmpdir/custom-bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
# Ensure NO default $HOME/.bun bun-js exists.
rm -rf "$tmpdir/.bun"
# Re-add fake bun on PATH.
cat > "$tmpdir/bin/bun" <<'EOF'
#!/usr/bin/env bash
echo "BUN $*"
EOF
chmod +x "$tmpdir/bin/bun"
output="$(HOME="$tmpdir" PATH="$tmpdir/bin:$PATH" BUN_INSTALL="$tmpdir/custom-bun" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_cmd --version')"
assert "BUN_INSTALL is honored" grep -q '^BUN ' <<<"$output"
assert "BUN_INSTALL path appears in dispatch" grep -q 'custom-bun' <<<"$output"

echo "[test-qmd-bin] qmd_cmd resolver — multi-arg + spaces passthrough"
output="$(HOME="$tmpdir" PATH="$tmpdir/bin:$PATH" BUN_INSTALL="$tmpdir/custom-bun" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_cmd collection add "/path with space" --name himmel')"
assert "multi-arg dispatched intact" grep -q 'collection add ' <<<"$output"
assert "path with spaces preserved" grep -q '/path with space' <<<"$output"
assert "--name flag preserved" grep -q -- '--name himmel' <<<"$output"

echo "[test-qmd-bin] qmd_cmd resolver — exit code passthrough"
cat > "$tmpdir/bin/bun" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "$tmpdir/bin/bun"
rc=0
HOME="$tmpdir" PATH="$tmpdir/bin:$PATH" BUN_INSTALL="$tmpdir/custom-bun" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_cmd --version' >/dev/null 2>&1 || rc=$?
assert "wrapped command rc=42 propagates" test "$rc" -eq 42

echo "[test-qmd-bin] qmd_install_hint contains --ignore-scripts"
assert "hint preserves --ignore-scripts flag" grep -q -- '--ignore-scripts' <<<"$(qmd_install_hint)"

echo "[test-qmd-bin] has_qmd is presence-only (does not invoke binary)"
# Make the bun-js path point at a broken/empty script that would error on run.
mkdir -p "$tmpdir/broken-bun/install/global/node_modules/@tobilu/qmd/dist/cli"
echo "this is not valid js" > "$tmpdir/broken-bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
rc=0
HOME="$tmpdir" PATH="$tmpdir/bin:$PATH" BUN_INSTALL="$tmpdir/broken-bun" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; has_qmd' || rc=$?
assert "has_qmd=true even when bun-js is broken (presence only)" test "$rc" -eq 0

echo "[test-qmd-bin] consumer integration — scripts/setup.sh uses helpers"
# Guard against accidental reintroduction of plain `qmd` in consumers.
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
assert "setup.sh sources qmd-bin.sh" grep -q 'lib/qmd-bin.sh' "$repo_root/scripts/setup.sh"
assert "setup.sh calls qmd_cmd" grep -q 'qmd_cmd ' "$repo_root/scripts/setup.sh"
assert "ubuntu.sh sources qmd-bin.sh" grep -q 'lib/qmd-bin.sh' "$repo_root/scripts/machine-setup/ubuntu.sh"
assert "ubuntu.sh calls qmd_cmd" grep -q 'qmd_cmd ' "$repo_root/scripts/machine-setup/ubuntu.sh"

echo "[test-qmd-bin] has_qmd matches binary presence in this env"
if has_qmd; then
  echo "  has_qmd=true in this env (real qmd present)"
else
  echo "  has_qmd=false in this env (no qmd present)"
fi

echo
echo "[test-qmd-bin] pass=$pass fail=$fail"
test "$fail" -eq 0
