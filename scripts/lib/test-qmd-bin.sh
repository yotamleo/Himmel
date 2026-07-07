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

echo "[test-qmd-bin] qmd_install_hint drops --ignore-scripts (HIMMEL-752 G3)"
# shellcheck disable=SC2016
# Single quotes intentional - $1 expands inside the spawned bash -c subshell.
assert "hint does NOT contain --ignore-scripts" bash -c '! grep -q -- "--ignore-scripts" <<<"$1"' _ "$(qmd_install_hint)"

echo "[test-qmd-bin] has_qmd is presence-only (does not invoke binary)"
# Make the bun-js path point at a broken/empty script that would error on run.
mkdir -p "$tmpdir/broken-bun/install/global/node_modules/@tobilu/qmd/dist/cli"
echo "this is not valid js" > "$tmpdir/broken-bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
rc=0
HOME="$tmpdir" PATH="$tmpdir/bin:$PATH" BUN_INSTALL="$tmpdir/broken-bun" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; has_qmd' || rc=$?
assert "has_qmd=true even when bun-js is broken (presence only)" test "$rc" -eq 0

echo "[test-qmd-bin] qmd_install() happy / heal / honest-fail (HIMMEL-752 G3)"
# Hermetic stub env: a fake `bun` (tells 'add' apart from a qmd run by $1),
# a fake `npm` (drops a heal marker), a fake qmd.js so qmd_cmd resolves via bun,
# and a better-sqlite3 dir for the heal path. Lives under $tmpdir so the EXIT
# trap cleans it. Stubs read behavior from env vars so one env covers all paths.
id2="$tmpdir/install"
mkdir -p "$id2/bin" "$id2/.bun/install/global/node_modules/@tobilu/qmd/dist/cli" \
         "$id2/.bun/install/global/node_modules/better-sqlite3"
: > "$id2/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
cat > "$id2/bin/bun" <<'STUB'
#!/usr/bin/env bash
# 'bun add ...' = install; anything else = a qmd run dispatch (bun <qmd.js> ...).
if [ "$1" = "add" ]; then exit "${STUB_BUN_ADD_RC:-0}"; fi
if [ -f "${HEAL_MARKER:-}" ]; then exit 0; fi
exit "${STUB_BUN_VER_RC:-0}"
STUB
chmod +x "$id2/bin/bun"
cat > "$id2/bin/npm" <<'STUB'
#!/usr/bin/env bash
# Simulate the native build: STUB_NPM_RC=1 = build fails (no heal marker);
# default = success (drop the heal marker).
if [ "${STUB_NPM_RC:-0}" -ne 0 ]; then exit "${STUB_NPM_RC}"; fi
: > "${HEAL_MARKER:?}"
exit 0
STUB
chmod +x "$id2/bin/npm"
heal_marker="$id2/.healed"
qmd_install_rc() {
  HOME="$id2" BUN_INSTALL="$id2/.bun" HEAL_MARKER="$heal_marker" \
    PATH="$id2/bin:$PATH" \
    STUB_BUN_ADD_RC="${STUB_BUN_ADD_RC:-0}" STUB_BUN_VER_RC="${STUB_BUN_VER_RC:-0}" \
    STUB_NPM_RC="${STUB_NPM_RC:-0}" \
    bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install >/dev/null 2>&1; echo $?'
}
# happy: install ok + verify ok -> rc 0.
STUB_BUN_ADD_RC=0; STUB_BUN_VER_RC=0; rm -f "$heal_marker"
assert "qmd_install happy path returns 0" test "$(qmd_install_rc)" -eq 0
# honest-fail: bun add fails -> rc nonzero, verify never reached.
STUB_BUN_ADD_RC=1; STUB_BUN_VER_RC=0; rm -f "$heal_marker"
assert "qmd_install honest-fail returns nonzero" test "$(qmd_install_rc)" -ne 0
# heal: install ok, verify fails, npm rebuild heals, re-verify ok -> rc 0.
STUB_BUN_ADD_RC=0; STUB_BUN_VER_RC=1; STUB_NPM_RC=0; rm -f "$heal_marker"
assert "qmd_install heal path returns 0" test "$(qmd_install_rc)" -eq 0
assert "qmd_install heal path ran npm rebuild" test -f "$heal_marker"
# heal-FAIL: install ok, verify fails, npm rebuild FAILS -> honest rc nonzero
# (the core HIMMEL-752 honest-rc contract: 0 only when qmd verifiably works).
STUB_BUN_ADD_RC=0; STUB_BUN_VER_RC=1; STUB_NPM_RC=1; rm -f "$heal_marker"
assert "qmd_install heal-fail returns nonzero (honest rc)" test "$(qmd_install_rc)" -ne 0
assert "qmd_install heal-fail left no heal marker" test ! -f "$heal_marker"
STUB_NPM_RC=0

echo "[test-qmd-bin] qmd_register_collection() add / idempotent-skip / warn (HIMMEL-752)"
# Hermetic stub env: a fake `qmd` on PATH (no bun-qmd.js, no bun -> qmd_cmd
# falls to the PATH qmd). Stubs read behavior from env vars.
id3="$tmpdir/register"
mkdir -p "$id3/bin"
add_log="$id3/add-calls"
cat > "$id3/bin/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "collection" ] && [ "$2" = "list" ]; then
  [ -n "${STUB_LIST_FAIL:-}" ] && { echo "boom" >&2; exit 2; }
  printf '%s\n' "${STUB_LIST:-}"
  exit 0
fi
if [ "$1" = "collection" ] && [ "$2" = "add" ]; then
  printf 'collection %s\n' "$*" >> "${ADD_LOG:?}"
  exit "${STUB_ADD_RC:-0}"
fi
exit 0
STUB
chmod +x "$id3/bin/qmd"
reg_rc() { # $1 = path, $2 = name; echoes the register rc on stdout.
  HOME="$id3" ADD_LOG="$add_log" PATH="$id3/bin:$PATH" \
    STUB_LIST="${STUB_LIST:-}" STUB_LIST_FAIL="${STUB_LIST_FAIL:-}" \
    STUB_ADD_RC="${STUB_ADD_RC:-0}" \
    bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_register_collection "'"$1"'" "'"$2"'"' >/dev/null 2>&1; echo $?
}
reg_err() { # like reg_rc but echoes the captured STDERR (for message asserts).
  # shellcheck disable=SC2069
  # 2>&1 >/dev/null is deliberate: stderr goes to the CAPTURED stdout while the
  # original stdout is discarded (we assert on the WARNING text, stderr-only).
  HOME="$id3" ADD_LOG="$add_log" PATH="$id3/bin:$PATH" \
    STUB_LIST="${STUB_LIST:-}" STUB_LIST_FAIL="${STUB_LIST_FAIL:-}" \
    STUB_ADD_RC="${STUB_ADD_RC:-0}" \
    bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_register_collection "'"$1"'" "'"$2"'"' 2>&1 >/dev/null || true
}
# add: list empty, name absent -> add called, rc 0.
STUB_LIST=""; STUB_LIST_FAIL=""; : > "$add_log"
assert "register add path returns 0" test "$(reg_rc /repo himmel)" -eq 0
assert "register add path called qmd collection add" grep -q 'collection add' "$add_log"
# idempotent skip: list contains himmel -> skip, add NOT called, rc 0.
STUB_LIST="himmel"; STUB_LIST_FAIL=""; : > "$add_log"
assert "register idempotent-skip returns 0" test "$(reg_rc /repo himmel)" -eq 0
assert "register idempotent-skip did NOT call add" test ! -s "$add_log"
# warn on list failure -> rc nonzero, add NOT called.
STUB_LIST="x"; STUB_LIST_FAIL=1; : > "$add_log"
assert "register warn-on-list-fail returns nonzero" test "$(reg_rc /repo himmel)" -ne 0
assert "register warn-on-list-fail did NOT call add" test ! -s "$add_log"
# idempotency must not false-match a prefix-only name (luna vs lunabot).
STUB_LIST="lunabot"; STUB_LIST_FAIL=""; : > "$add_log"
assert "register no prefix false-match (luna vs lunabot)" test "$(reg_rc /vault luna)" -eq 0
assert "register luna added despite lunabot in list" grep -q 'collection add' "$add_log"
# add-FAILURE: list ok, add exits nonzero -> WARN + honest rc passthrough.
STUB_LIST=""; STUB_LIST_FAIL=""; STUB_ADD_RC=3; : > "$add_log"
assert "register add-failure returns the add rc" test "$(reg_rc /repo himmel)" -eq 3
err_out=$(reg_err /repo himmel)
assert "register add-failure WARNs" grep -q 'WARNING: qmd collection add' <<<"$err_out"
# add rc=127 (resolver could not find qmd) -> the install-hint diagnostic fires.
STUB_LIST=""; STUB_LIST_FAIL=""; STUB_ADD_RC=127; : > "$add_log"
assert "register add-127 returns 127" test "$(reg_rc /repo himmel)" -eq 127
err_out=$(reg_err /repo himmel)
assert "register add-127 prints the resolver install hint" grep -q 'rc=127 means' <<<"$err_out"
STUB_ADD_RC=0

echo "[test-qmd-bin] consumer integration — scripts/setup.sh uses helpers"
# Guard against accidental reintroduction of plain `qmd` in consumers.
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
assert "setup.sh sources qmd-bin.sh" grep -q 'lib/qmd-bin.sh' "$repo_root/scripts/setup.sh"
# setup.sh [4/10] was refactored to call qmd_register_collection (HIMMEL-752),
# which wraps qmd_cmd - either helper counts as "uses the resolver, not bare qmd".
assert "setup.sh calls a qmd-bin.sh helper (qmd_cmd/qmd_register_collection)" \
  grep -qE 'qmd_cmd |qmd_register_collection ' "$repo_root/scripts/setup.sh"
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
