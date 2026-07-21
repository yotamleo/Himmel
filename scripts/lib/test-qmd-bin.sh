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
# shellcheck disable=SC1091  # sourced file not in input on test-only commits
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

echo "[test-qmd-bin] qmd_install_hint emits the fork clone+build+link recipe (HIMMEL-877)"
hint="$(qmd_install_hint)"
assert "hint mentions git clone" grep -q '^git clone ' <<<"$hint"
assert "hint mentions the himmel fork repo" grep -q 'yotamleo/qmd' <<<"$hint"
assert "hint pins a full commit SHA (HIMMEL-911), not a movable ref" grep -qE 'fetch origin [0-9a-f]{40} ' <<<"$hint"
# shellcheck disable=SC2016
# Single quotes intentional — $1 expands inside the spawned bash -c subshell.
assert "hint does NOT install from the mutable himmel-main branch" \
  bash -c '! grep -q "himmel-main" <<<"$1"' _ "$hint"
assert "hint mentions bun install/build" grep -q 'bun install && bun run build' <<<"$hint"
# shellcheck disable=SC2016
# Single quotes intentional — $1 expands inside the spawned bash -c subshell.
assert "hint does NOT mention upstream bun add -g" bash -c '! grep -q "bun add -g" <<<"$1"' _ "$hint"

echo "[test-qmd-bin] pin policy (HIMMEL-911): the configured ref IS a full 40-hex commit SHA"
# Tags/branches are force-movable; only a commit SHA is content-addressed.
# This pins the POLICY so a future 'bump the pin' change that swaps in a tag
# or branch name fails here. (Run with the env override cleared -- the test
# targets the committed default.)
default_ref="$(env -u QMD_FORK_REF bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; _qmd_fork_ref')"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "default QMD_FORK_REF is a full 40-hex SHA" \
  bash -c 'printf "%s" "$1" | grep -qE "^[0-9a-f]{40}$"' _ "$default_ref"

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

echo "[test-qmd-bin] QMD_FORK_REPO / QMD_FORK_REF / QMD_FORK_DIR overrides (HIMMEL-877/HIMMEL-911)"
override_hint="$(QMD_FORK_REPO=https://example.test/mirror/qmd.git QMD_FORK_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef QMD_FORK_DIR=/custom/fork/dir qmd_install_hint)"
assert "hint honors QMD_FORK_REPO override" grep -q 'example.test/mirror/qmd.git' <<<"$override_hint"
assert "hint honors QMD_FORK_REF override" grep -q 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' <<<"$override_hint"
assert "hint honors QMD_FORK_DIR override" grep -q '/custom/fork/dir' <<<"$override_hint"

echo "[test-qmd-bin] has_qmd is presence-only (does not invoke binary)"
# Make the bun-js path point at a broken/empty script that would error on run.
mkdir -p "$tmpdir/broken-bun/install/global/node_modules/@tobilu/qmd/dist/cli"
echo "this is not valid js" > "$tmpdir/broken-bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
rc=0
HOME="$tmpdir" PATH="$tmpdir/bin:$PATH" BUN_INSTALL="$tmpdir/broken-bun" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; has_qmd' || rc=$?
assert "has_qmd=true even when bun-js is broken (presence only)" test "$rc" -eq 0

echo "[test-qmd-bin] qmd_install() fork clone+build+link recipe (HIMMEL-877/HIMMEL-911)"
# Hermetic stub env: a fake `git` (init creates a .git marker + package.json,
# matching what a real `git init` + first fetch/checkout leaves behind;
# fetch/checkout/reset are individually controllable) and a fake `bun`
# (install/run-build individually controllable; any other invocation is the
# qmd_cmd dispatch `bun <qmd.js> --version`, which prints a fake version).
# Both stubs append every call to a log file so tests can assert on call
# counts (e.g. the idempotent-skip case must invoke NEITHER). Lives under
# $tmpdir so the EXIT trap cleans it up.
id2="$tmpdir/install"
mkdir -p "$id2/bin"
cat > "$id2/bin/git" <<'STUB'
#!/usr/bin/env bash
# The owned-dir guard probes run as `git -C <dir> remote|status ...` --
# strip the -C pair so the verb lands in $1 for the case dispatch.
if [ "$1" = "-C" ]; then shift 2; fi
echo "GIT $*" >> "${GIT_LOG:?}"
case "$1" in
  init)
    # `git init <fork_dir>` (HIMMEL-911: a SHA can't be `git clone --branch`ed,
    # so the fresh-install path is init + fetch-by-sha + checkout).
    [ "${STUB_GIT_CLONE_RC:-0}" -eq 0 ] || exit "$STUB_GIT_CLONE_RC"
    target="$2"
    mkdir -p "$target/.git"
    echo '{}' > "$target/package.json"
    exit 0
    ;;
  remote)
    if [ "$2" = "add" ]; then
      # `remote add origin <url>` -- nothing to simulate, just succeed.
      exit 0
    fi
    # `remote get-url origin` ownership probe: default answers the default
    # fork repo URL so owned-clone scenarios pass the guard.
    printf '%s\n' "${STUB_GIT_ORIGIN_URL:-https://github.com/yotamleo/qmd.git}"
    exit 0
    ;;
  fetch|reset) exit "${STUB_GIT_FETCH_RC:-0}" ;;
  checkout)
    # A successful checkout moves HEAD to the requested commit -- mirror it
    # into the head-state file (when the scenario tracks one) so rev-parse
    # answers realistically after a re-pin (HIMMEL-911).
    if [ "${STUB_GIT_FETCH_RC:-0}" -eq 0 ] && [ -n "${STUB_GIT_HEAD_FILE:-}" ]; then
      printf '%s\n' "$2" > "$STUB_GIT_HEAD_FILE"
    fi
    exit "${STUB_GIT_FETCH_RC:-0}"
    ;;
  rev-parse)
    # HEAD probe (qmd_fork_served pin gate + qmd_install post-checkout
    # verify, HIMMEL-911): the head-state file when tracked, else the
    # STUB_GIT_HEAD env (qmd_install_env defaults it to the pinned ref).
    if [ -n "${STUB_GIT_HEAD_FILE:-}" ] && [ -f "$STUB_GIT_HEAD_FILE" ]; then
      cat "$STUB_GIT_HEAD_FILE"
    else
      printf '%s\n' "${STUB_GIT_HEAD:-}"
    fi
    exit 0
    ;;
  status)
    # `status --porcelain` dirty probe: empty default = clean worktree.
    printf '%s' "${STUB_GIT_DIRTY:-}"
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$id2/bin/git"
cat > "$id2/bin/bun" <<'STUB'
#!/usr/bin/env bash
echo "BUN $*" >> "${BUN_LOG:?}"
case "$1" in
  install)
    [ "${STUB_BUN_INSTALL_RC:-0}" -eq 0 ] || exit "$STUB_BUN_INSTALL_RC"
    # Mirror what a real `bun install` materializes for the HIMMEL-928
    # binding step: the better-sqlite3 + prebuild-install package dirs --
    # but NOT the compiled binding (bun blocks that postinstall; the
    # binding only appears via the node-run prebuild fetch, stubbed in
    # $id2/bin/node).
    mkdir -p node_modules/better-sqlite3 node_modules/prebuild-install
    : > node_modules/prebuild-install/bin.js
    exit 0
    ;;
  run)
    [ "$2" = "build" ] || exit 0
    [ "${STUB_BUN_BUILD_RC:-0}" -eq 0 ] || exit "$STUB_BUN_BUILD_RC"
    mkdir -p dist/cli
    : > dist/cli/qmd.js
    exit 0
    ;;
  *)
    [ "${STUB_BUN_VERSION_RC:-0}" -eq 0 ] && printf 'qmd %s\n' "${STUB_QMD_VERSION:-2.6.10}"
    exit "${STUB_BUN_VERSION_RC:-0}"
    ;;
esac
STUB
chmod +x "$id2/bin/bun"
# Fake node for the HIMMEL-928 better-sqlite3 binding step. Two verbs:
#   node <...>/prebuild-install/bin.js   -> the prebuild fetch: create the
#     binding file in cwd (qmd_install runs it from node_modules/
#     better-sqlite3), controllable via STUB_NODE_FETCH_RC.
#   node <...>/.himmel-binding-probe.cjs -> the load-probe: print the
#     success marker iff the binding file exists next to the probe (i.e.
#     the fetch really ran) AND STUB_NODE_PROBE_RC does not force a
#     wrong-ABI/corrupt simulation.
cat > "$id2/bin/node" <<'STUB'
#!/usr/bin/env bash
echo "NODE $*" >> "${NODE_LOG:?}"
case "$1" in
  */prebuild-install/bin.js)
    [ "${STUB_NODE_FETCH_RC:-0}" -eq 0 ] || exit "$STUB_NODE_FETCH_RC"
    mkdir -p build/Release
    : > build/Release/better_sqlite3.node
    exit 0
    ;;
  *.himmel-binding-probe.cjs)
    [ "${STUB_NODE_PROBE_RC:-0}" -eq 0 ] || exit "$STUB_NODE_PROBE_RC"
    if [ -f "$(dirname "$1")/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
      echo "qmd-binding-ok"
      exit 0
    fi
    exit 1
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$id2/bin/node"

git_log="$id2/git-calls"
bun_log="$id2/bun-calls"
node_log="$id2/node-calls"
qmd_install_env() { # $1 = HOME dir, remaining = the command to run under it
  local home="$1"; shift
  : > "$git_log"; : > "$bun_log"; : > "$node_log"
  HOME="$home" GIT_LOG="$git_log" BUN_LOG="$bun_log" NODE_LOG="$node_log" PATH="$id2/bin:$PATH" \
    STUB_GIT_CLONE_RC="${STUB_GIT_CLONE_RC:-0}" STUB_GIT_FETCH_RC="${STUB_GIT_FETCH_RC:-0}" \
    STUB_GIT_ORIGIN_URL="${STUB_GIT_ORIGIN_URL:-}" STUB_GIT_DIRTY="${STUB_GIT_DIRTY:-}" \
    STUB_GIT_HEAD="${STUB_GIT_HEAD:-$default_ref}" STUB_GIT_HEAD_FILE="${STUB_GIT_HEAD_FILE:-}" \
    STUB_BUN_INSTALL_RC="${STUB_BUN_INSTALL_RC:-0}" STUB_BUN_BUILD_RC="${STUB_BUN_BUILD_RC:-0}" \
    STUB_BUN_VERSION_RC="${STUB_BUN_VERSION_RC:-0}" STUB_QMD_VERSION="${STUB_QMD_VERSION:-2.6.10}" \
    STUB_NODE_FETCH_RC="${STUB_NODE_FETCH_RC:-0}" STUB_NODE_PROBE_RC="${STUB_NODE_PROBE_RC:-0}" \
    "$@"
}

# -- fresh install: clone + build + link, rc 0 --------------------------------
fresh_home="$id2/fresh"; mkdir -p "$fresh_home"
STUB_GIT_CLONE_RC=0 STUB_GIT_FETCH_RC=0 STUB_BUN_INSTALL_RC=0 STUB_BUN_BUILD_RC=0 STUB_BUN_VERSION_RC=0
out=$(qmd_install_env "$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "fresh install: rc 0" grep -q '^RC=0$' <<<"$out"
assert "fresh install: initialized the fork clone" grep -q 'GIT init' "$git_log"
assert "fresh install: added the fork as origin" grep -q 'GIT remote add origin' "$git_log"
assert "fresh install: fetched the pinned SHA" grep -qE 'GIT fetch --depth 1 origin [0-9a-f]{40}' "$git_log"
assert "fresh install: checked out the pinned SHA" grep -qE 'GIT checkout [0-9a-f]{40}' "$git_log"
assert "fresh install: built with bun" grep -q 'BUN run build' "$bun_log"
assert "fresh install: linked at the bun-global @tobilu/qmd path" \
  test -e "$fresh_home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "fresh install: no git call references the mutable himmel-main branch" \
  bash -c '! grep -q "himmel-main" "$1"' _ "$git_log"

# -- idempotent re-run: already fork-served (link + pinned HEAD + version ok)
#    -> skip, clone/build never re-run (the pin gate legitimately runs ONE
#    read-only `git rev-parse HEAD`, and the version CHECK invokes bun once).
out=$(qmd_install_env "$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "idempotent re-run: rc 0" grep -q '^RC=0$' <<<"$out"
assert "idempotent re-run: pin gate probed HEAD (read-only rev-parse, HIMMEL-911)" \
  grep -q 'GIT rev-parse HEAD' "$git_log"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "idempotent re-run: no mutating git call (fetch/checkout/reset/init)" \
  bash -c '! grep -qE "GIT (fetch|checkout|reset|init|clone|remote add)" "$1"' _ "$git_log"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "idempotent re-run: did not re-run bun install" bash -c '! grep -q "BUN install" "$1"' _ "$bun_log"
# shellcheck disable=SC2016
assert "idempotent re-run: did not re-run bun build" bash -c '! grep -q "BUN run build" "$1"' _ "$bun_log"

# -- qmd_fork_served / `fork-served` CLI verb (the caller-side install gate,
#    HIMMEL-877 CR codex-adv-1) ------------------------------------------------
assert "fork-served CLI verb: rc 0 when the fork is served" \
  qmd_install_env "$fresh_home" bash "$SCRIPT_DIR/qmd-bin.sh" fork-served
noserve_home="$id2/noserve"
mkdir -p "$noserve_home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli"
: > "$noserve_home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
rc=0
qmd_install_env "$noserve_home" bash "$SCRIPT_DIR/qmd-bin.sh" fork-served >/dev/null 2>&1 || rc=$?
assert "fork-served CLI verb: nonzero on an upstream REAL-dir install (qmd present)" test "$rc" -ne 0

# -- pin-drift (HIMMEL-911 CR r1 codex-adv-1): a linked, version-compatible
#    clone checked out at a DIFFERENT commit must NOT count as served -- that
#    is exactly the pre-pin population (built from the mutable himmel-main
#    head) this change migrates. qmd_install must fall through to the update
#    path and re-pin, never skip. ----------------------------------------------
drift_head="$id2/drift-head"
printf '%s\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$drift_head"
STUB_GIT_HEAD_FILE="$drift_head"
rc=0
qmd_install_env "$fresh_home" bash "$SCRIPT_DIR/qmd-bin.sh" fork-served >/dev/null 2>&1 || rc=$?
assert "pin-drift: fork-served nonzero on a drifted HEAD" test "$rc" -ne 0
out=$(qmd_install_env "$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "pin-drift: qmd_install did NOT skip (update-path fetch ran)" grep -q 'GIT fetch' "$git_log"
assert "pin-drift: re-pinned successfully (rc 0)" grep -q '^RC=0$' <<<"$out"
assert "pin-drift: clone HEAD is the pinned SHA afterward" grep -q "$default_ref" "$drift_head"

# -- pinned-update failure on a SERVED-but-drifted install: FAIL CLOSED
#    (HIMMEL-911 CR r1 codex-adv-2). The old fallback (WARN + build the clone
#    contents as-is) silently served an UNPINNED commit while reporting
#    success. Now: honest nonzero, ERROR names the pinned SHA, and the
#    previously served installation is left untouched (no rebuild, no
#    re-link, clone HEAD not half-updated). ------------------------------------
printf '%s\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$drift_head"
STUB_GIT_FETCH_RC=1
out=$(qmd_install_env "$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
STUB_GIT_FETCH_RC=0
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "served-drift update-fail: rc nonzero (fail closed)" \
  bash -c '! grep -q "^RC=0$" <<<"$1"' _ "$out"
assert "served-drift update-fail: ERROR names the pinned SHA" \
  grep -q "pinned commit $default_ref" <<<"$out"
assert "served-drift update-fail: no rebuild (bun never invoked)" test ! -s "$bun_log"
assert "served-drift update-fail: served link left untouched" \
  test -e "$fresh_home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
assert "served-drift update-fail: clone HEAD untouched (still drifted)" \
  grep -q 'deadbeef' "$drift_head"

# -- build failure DURING a drifted upgrade must not mint a served pin
#    (HIMMEL-911 CR r3 codex-adv): checkout moves HEAD to the pin BEFORE bun
#    runs, so a build failure leaves HEAD==pin while the OLD dist (built from
#    the mutable commit) keeps serving. Without the build-success stamp a
#    RETRY would see HEAD==pin + version>=min -> served -> skip silently
#    forever, reporting a valid pinned install over stale artifacts. ------------
printf '%s\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$drift_head"
STUB_BUN_BUILD_RC=1
out=$(qmd_install_env "$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
STUB_BUN_BUILD_RC=0
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "drift+build-fail: rc nonzero" bash -c '! grep -q "^RC=0$" <<<"$1"' _ "$out"
assert "drift+build-fail: HEAD did move to the pin (the trap precondition)" \
  grep -q "$default_ref" "$drift_head"
# RETRY with bun healthy again: must NOT skip -- the stamp is missing, so
# fork_served stays false despite HEAD==pin; it must rebuild and succeed.
out=$(qmd_install_env "$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "drift+build-fail retry: did NOT skip (update path ran)" grep -q 'GIT fetch' "$git_log"
assert "drift+build-fail retry: rebuilt" grep -q 'BUN run build' "$bun_log"
assert "drift+build-fail retry: rc 0" grep -q '^RC=0$' <<<"$out"
STUB_GIT_HEAD_FILE=""

# -- legacy migration (HIMMEL-911 CR r3): a pre-stamp machine (linked, pinned
#    HEAD, version ok -- but no .himmel-build-ok stamp) intentionally reads
#    as NOT-served, so it converges onto a stamped pinned build on its next
#    install pass. Desired migration behavior, not a bug.
rm -f "$fresh_home/.himmel/qmd-fork/.himmel-build-ok"
rc=0
qmd_install_env "$fresh_home" bash "$SCRIPT_DIR/qmd-bin.sh" fork-served >/dev/null 2>&1 || rc=$?
assert "legacy no-stamp install: fork-served nonzero (converges onto the stamped pin)" test "$rc" -ne 0

# Absolute path to bash (not a bare `bash` PATH lookup): the no-git/no-bun
# isolation cases below need a PATH that carries ONLY the surviving stub (no
# fallback to the outer $PATH, or the real git/bun on this dev box would leak
# in and mask the scenario) -- but a bare `bash -c` would then fail to find
# bash ITSELF via that same restricted PATH. Resolve it once, outside the
# restriction.
bash_bin="$(command -v bash)"

# -- no git on PATH: WARN + rc nonzero, bun never invoked (PATH carries ONLY
#    the bun stub) -------------------------------------------------------------
nogit_home="$id2/nogit"; mkdir -p "$nogit_home" "$id2/bin-bun-only"
cp "$id2/bin/bun" "$id2/bin-bun-only/bun"
: > "$git_log"; : > "$bun_log"
out=$(HOME="$nogit_home" GIT_LOG="$git_log" BUN_LOG="$bun_log" \
      PATH="$id2/bin-bun-only" "$bash_bin" -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "no-git: rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "no-git: WARNs" grep -qi 'git not found' <<<"$out"
assert "no-git: bun never invoked" test ! -s "$bun_log"

# -- no bun on PATH (git present): WARN + rc nonzero (PATH carries ONLY the
#    git stub) -----------------------------------------------------------------
nobun_home="$id2/nobun"; mkdir -p "$nobun_home" "$id2/bin-git-only"
cp "$id2/bin/git" "$id2/bin-git-only/git"
: > "$git_log"; : > "$bun_log"
out=$(HOME="$nobun_home" GIT_LOG="$git_log" BUN_LOG="$bun_log" PATH="$id2/bin-git-only" \
      "$bash_bin" -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "no-bun: rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "no-bun: WARNs" grep -qi 'bun not found' <<<"$out"

# -- pinned-update failure on an EXISTING unlinked clone: FAIL CLOSED
#    (HIMMEL-911 CR r1 codex-adv-2) -- never build/link contents that could
#    not be brought to the pinned SHA. Pre-seed the clone dir directly (NOT
#    via a first qmd_install call) so the global path is NOT yet linked --
#    otherwise the idempotent-skip check above would short-circuit this run
#    before it ever reaches the fetch/checkout step.
stale_home="$id2/stalefetch"
mkdir -p "$stale_home/.himmel/qmd-fork/.git"
echo '{}' > "$stale_home/.himmel/qmd-fork/package.json"
STUB_GIT_CLONE_RC=0 STUB_GIT_FETCH_RC=1 STUB_BUN_INSTALL_RC=0 STUB_BUN_BUILD_RC=0 STUB_BUN_VERSION_RC=0
out=$(qmd_install_env "$stale_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
STUB_GIT_FETCH_RC=0
assert "fetch-fail: attempted the update (fetch) on the existing clone" grep -q 'GIT fetch' "$git_log"
assert "fetch-fail: fetched the pinned SHA, not a branch name" grep -qE 'GIT fetch origin [0-9a-f]{40}' "$git_log"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "fetch-fail: fails closed (rc nonzero, no as-is fallback build)" \
  bash -c '! grep -q "^RC=0$" <<<"$1"' _ "$out"
assert "fetch-fail: ERROR names the pinned SHA" grep -q "pinned commit $default_ref" <<<"$out"
# shellcheck disable=SC2016
assert "fetch-fail: did NOT build the unpinned clone" \
  bash -c '! grep -qE "BUN (install|run build)" "$1"' _ "$bun_log"
assert "fetch-fail: did NOT link the global path" \
  test ! -e "$stale_home/.bun/install/global/node_modules/@tobilu/qmd"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "update path: no git call references the mutable himmel-main branch" \
  bash -c '! grep -q "himmel-main" "$1"' _ "$git_log"

# -- owned-dir guard (HIMMEL-877 CR codex-adv-2): never hard-reset a repo
#    the installer does not own -------------------------------------------------
# unrelated origin at QMD_FORK_DIR -> refused untouched, rc nonzero, no fetch.
unrel_home="$id2/unrelorigin"
mkdir -p "$unrel_home/.himmel/qmd-fork/.git"
echo "precious local work" > "$unrel_home/.himmel/qmd-fork/work.txt"
STUB_GIT_ORIGIN_URL="https://github.com/someone/unrelated.git"
out=$(qmd_install_env "$unrel_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
STUB_GIT_ORIGIN_URL=""
assert "unrelated-origin: rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "unrelated-origin: refuses with the origin mismatch WARNING" grep -qi 'refusing to touch' <<<"$out"
# shellcheck disable=SC2016
assert "unrelated-origin: never fetch/checkout/reset" bash -c '! grep -qE "GIT (fetch|checkout|reset)" "$1"' _ "$git_log"
assert "unrelated-origin: dir contents untouched" grep -q 'precious local work' "$unrel_home/.himmel/qmd-fork/work.txt"

# dirty owned clone -> refused untouched, rc nonzero.
dirty_home="$id2/dirtyclone"
mkdir -p "$dirty_home/.himmel/qmd-fork/.git"
echo "uncommitted edit" > "$dirty_home/.himmel/qmd-fork/wip.txt"
STUB_GIT_DIRTY=" M wip.txt"
out=$(qmd_install_env "$dirty_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "dirty-clone: rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "dirty-clone: refuses with the uncommitted-changes WARNING" grep -qi 'uncommitted changes' <<<"$out"
# shellcheck disable=SC2016
assert "dirty-clone: never fetch/checkout/reset" bash -c '! grep -qE "GIT (fetch|checkout|reset)" "$1"' _ "$git_log"
assert "dirty-clone: dir contents untouched" grep -q 'uncommitted edit' "$dirty_home/.himmel/qmd-fork/wip.txt"

# QMD_FORK_FORCE=1 on the same dirty clone -> proceeds (fetch runs, rc 0).
out=$(qmd_install_env "$dirty_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; QMD_FORK_FORCE=1 qmd_install; echo "RC=$?"' 2>&1)
STUB_GIT_DIRTY=""
assert "dirty+FORCE: proceeds to fetch" grep -q 'GIT fetch' "$git_log"
assert "dirty+FORCE: rc 0" grep -q '^RC=0$' <<<"$out"

# -- populated NON-git dir at QMD_FORK_DIR (HIMMEL-911 CR r2 codex-adv):
#    refused untouched. QMD_FORK_DIR is operator-overridable, so a populated
#    non-git dir here is USER DATA that predates the installer -- an
#    init-in-place followed by the clone-failure `rm -rf` cleanup would
#    destroy it. Even under a forced fetch failure nothing may be created,
#    fetched, or deleted. --------------------------------------------------------
nongit_home="$id2/nongitdir"
mkdir -p "$nongit_home/.himmel/qmd-fork"
echo "predates the installer" > "$nongit_home/.himmel/qmd-fork/user-data.txt"
STUB_GIT_FETCH_RC=1
out=$(qmd_install_env "$nongit_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
STUB_GIT_FETCH_RC=0
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "non-git dir: rc nonzero" bash -c '! grep -q "^RC=0$" <<<"$1"' _ "$out"
assert "non-git dir: refuses with the not-a-git-clone WARNING" grep -qi 'not a git clone' <<<"$out"
assert "non-git dir: no git call at all (never init'ed in place)" test ! -s "$git_log"
assert "non-git dir: pre-existing contents byte-untouched" \
  grep -q 'predates the installer' "$nongit_home/.himmel/qmd-fork/user-data.txt"
assert "non-git dir: no .git dir injected" test ! -e "$nongit_home/.himmel/qmd-fork/.git"

# -- fresh-create failure cleanup stays scoped to the dir THIS invocation
#    created (the non-git refusal above must not break it): NO pre-existing
#    fork_dir + a fetch failure -> the newly init'ed dir is removed again,
#    rc nonzero. ----------------------------------------------------------------
freshfail_home="$id2/freshfail"; mkdir -p "$freshfail_home"
STUB_GIT_FETCH_RC=1
out=$(qmd_install_env "$freshfail_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
STUB_GIT_FETCH_RC=0
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "fresh-create fail: rc nonzero" bash -c '! grep -q "^RC=0$" <<<"$1"' _ "$out"
assert "fresh-create fail: cleaned up ONLY its own newly created dir" \
  test ! -e "$freshfail_home/.himmel/qmd-fork"

# -- build failure: WARN + manual command, rc nonzero --------------------------
buildfail_home="$id2/buildfail"; mkdir -p "$buildfail_home"
STUB_GIT_CLONE_RC=0 STUB_GIT_FETCH_RC=0 STUB_BUN_INSTALL_RC=0 STUB_BUN_BUILD_RC=1
out=$(qmd_install_env "$buildfail_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
STUB_BUN_BUILD_RC=0
assert "build-fail: rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "build-fail: WARNs with the manual command" grep -qi 'build failed' <<<"$out"

# -- existing REAL directory at the global path: moved aside (never deleted),
#    named deterministically -------------------------------------------------
realdir_home="$id2/realdir"
mkdir -p "$realdir_home/.bun/install/global/node_modules/@tobilu/qmd"
echo "upstream content" > "$realdir_home/.bun/install/global/node_modules/@tobilu/qmd/marker.txt"
STUB_GIT_CLONE_RC=0 STUB_GIT_FETCH_RC=0 STUB_BUN_INSTALL_RC=0 STUB_BUN_BUILD_RC=0 STUB_BUN_VERSION_RC=0
out=$(qmd_install_env "$realdir_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
backup="$realdir_home/.bun/install/global/node_modules/@tobilu/qmd.pre-fork-backup"
assert "real-dir: rc 0" grep -q '^RC=0$' <<<"$out"
assert "real-dir: moved aside to the deterministic backup name" test -d "$backup"
assert "real-dir: backup content preserved" grep -q 'upstream content' "$backup/marker.txt"
assert "real-dir: global path now links to the fork" \
  test -e "$realdir_home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"

# -- existing STALE LINK (pointing elsewhere): removed + replaced, the old
#    target's contents survive (link-only removal, never recursive). Reuse
#    the module's OWN _qmd_link (junction on Windows / symlink on POSIX) to
#    create the fixture, so the test stays correct on either platform without
#    reimplementing the OS branch. -------------------------------------------
stalelink_home="$id2/stalelink"
mkdir -p "$stalelink_home/.bun/install/global/node_modules/@tobilu" "$stalelink_home/elsewhere"
echo "elsewhere content" > "$stalelink_home/elsewhere/marker.txt"
bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; _qmd_link "$1" "$2"' _ \
  "$stalelink_home/elsewhere" "$stalelink_home/.bun/install/global/node_modules/@tobilu/qmd"
STUB_GIT_CLONE_RC=0 STUB_GIT_FETCH_RC=0 STUB_BUN_INSTALL_RC=0 STUB_BUN_BUILD_RC=0 STUB_BUN_VERSION_RC=0
out=$(qmd_install_env "$stalelink_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "stale-link: rc 0" grep -q '^RC=0$' <<<"$out"
assert "stale-link: replaced with a link to the fork" \
  test -e "$stalelink_home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
assert "stale-link: old target's contents untouched" grep -q 'elsewhere content' "$stalelink_home/elsewhere/marker.txt"

# -- link failure AFTER a real-dir backup: the backup is RESTORED to the
#    global path (CR rollback: the old install must keep resolving; the
#    locked-path failure this recipe exists for must not strand it) -----------
rollback_home="$id2/rollback"
mkdir -p "$rollback_home/.bun/install/global/node_modules/@tobilu/qmd"
echo "upstream content" > "$rollback_home/.bun/install/global/node_modules/@tobilu/qmd/marker.txt"
STUB_GIT_CLONE_RC=0 STUB_GIT_FETCH_RC=0 STUB_BUN_INSTALL_RC=0 STUB_BUN_BUILD_RC=0 STUB_BUN_VERSION_RC=0
out=$(qmd_install_env "$rollback_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"
  _qmd_link() { _QMD_LINK_ERR="stub link failure"; return 1; }
  qmd_install; echo "RC=$?"' 2>&1)
assert "link-fail rollback: rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "link-fail rollback: ERROR carries the captured link diagnostics" grep -q 'stub link failure' <<<"$out"
assert "link-fail rollback: announces the restore" grep -qi 'Restored the previous directory' <<<"$out"
assert "link-fail rollback: original dir is BACK at the global path" \
  grep -q 'upstream content' "$rollback_home/.bun/install/global/node_modules/@tobilu/qmd/marker.txt"
assert "link-fail rollback: no stranded backup left behind" \
  test ! -e "$rollback_home/.bun/install/global/node_modules/@tobilu/qmd.pre-fork-backup"

# -- successful migration prints the backup location (operator affordance) ----
note_home="$id2/backupnote"
mkdir -p "$note_home/.bun/install/global/node_modules/@tobilu/qmd"
echo "upstream content" > "$note_home/.bun/install/global/node_modules/@tobilu/qmd/marker.txt"
out=$(qmd_install_env "$note_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "backup-note: rc 0" grep -q '^RC=0$' <<<"$out"
assert "backup-note: names the preserved backup dir" grep -q 'preserved at' <<<"$out"

echo "[test-qmd-bin] better-sqlite3 node-binding gate (HIMMEL-928 / CR codex-adv)"
# The binding is node-only (bun takes the bun:sqlite branch), bun install
# never produces it, and existence alone must never bless it -- the gate
# load-probes and the installer repairs. Uses the $id2/bin/node stub.
binding="$fresh_home/.himmel/qmd-fork/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
assert "binding gate: fresh install fetched the binding via node prebuild-install" test -f "$binding"
# present-but-unloadable (wrong-ABI/corrupt simulation): probe forced to fail
# -> fork-served must read NOT served despite the file existing.
rc=0
STUB_NODE_PROBE_RC=1 qmd_install_env "$fresh_home" bash "$SCRIPT_DIR/qmd-bin.sh" fork-served >/dev/null 2>&1 || rc=$?
assert "binding gate: present-but-unloadable binding = not served" test "$rc" -ne 0
# missing binding -> not served.
rm -f "$binding"
rc=0
qmd_install_env "$fresh_home" bash "$SCRIPT_DIR/qmd-bin.sh" fork-served >/dev/null 2>&1 || rc=$?
assert "binding gate: missing binding = not served" test "$rc" -ne 0
# repair: qmd_install re-fetches under node and converges back to served.
out=$(qmd_install_env "$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "binding repair: rc 0" grep -q '^RC=0$' <<<"$out"
assert "binding repair: prebuild fetch ran under node" grep -q 'prebuild-install/bin.js' "$node_log"
assert "binding repair: binding restored" test -f "$binding"
rc=0
qmd_install_env "$fresh_home" bash "$SCRIPT_DIR/qmd-bin.sh" fork-served >/dev/null 2>&1 || rc=$?
assert "binding repair: fork-served again afterward" test "$rc" -eq 0
# fetch failure -> fail closed with the not-loadable WARNING.
rm -f "$binding"
STUB_NODE_FETCH_RC=1
out=$(qmd_install_env "$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
STUB_NODE_FETCH_RC=0
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "binding fetch-fail: rc nonzero (fail closed)" bash -c '! grep -q "^RC=0$" <<<"$1"' _ "$out"
assert "binding fetch-fail: WARNs not-loadable with the manual command" grep -qi 'not loadable under node' <<<"$out"
# leave fresh_home converged for any later assertions.
out=$(qmd_install_env "$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "binding gate: fresh_home re-converged" grep -q '^RC=0$' <<<"$out"

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
# HIMMEL-887: ubuntu.sh no longer sources lib/qmd-bin.sh or calls qmd_cmd
# directly -- himmel/luna wiring delegates to `himmelctl bootstrap` (the NOTICE
# at ubuntu.sh). Assert the delegation instead of the removed direct wiring.
# shellcheck disable=SC2016
assert "ubuntu.sh does NOT reference lib/qmd-bin.sh (wiring delegated, HIMMEL-887)" \
  bash -c '! grep -qF -- "lib/qmd-bin.sh" "$1"' _ "$repo_root/scripts/machine-setup/ubuntu.sh"
# shellcheck disable=SC2016
assert "ubuntu.sh does NOT call qmd_cmd (wiring delegated, HIMMEL-887)" \
  bash -c '! grep -qF -- "qmd_cmd " "$1"' _ "$repo_root/scripts/machine-setup/ubuntu.sh"
# The NOTICE alone is not the contract: assert the executable delegation
# statement too, so removing the exec while keeping the NOTICE fails
# (codex-adv finding, HIMMEL-934 CR round).
# shellcheck disable=SC2016
assert "ubuntu.sh execs himmelctl bootstrap.sh (delegation is real, HIMMEL-887)" \
  grep -qE -- '^[[:space:]]*(HIMMELCTL_REPO_ROOT="\$HIMMEL_PATH"[[:space:]]+)?exec[[:space:]]+bash[[:space:]]+"\$HIMMEL_PATH/scripts/himmelctl/bootstrap\.sh"[[:space:]]*$' "$repo_root/scripts/machine-setup/ubuntu.sh"
assert "ubuntu.sh prints the himmelctl bootstrap delegation NOTICE (HIMMEL-887)" \
  grep -q 'delegating to himmelctl bootstrap' "$repo_root/scripts/machine-setup/ubuntu.sh"

echo "[test-qmd-bin] has_qmd matches binary presence in this env"
if has_qmd; then
  echo "  has_qmd=true in this env (real qmd present)"
else
  echo "  has_qmd=false in this env (no qmd present)"
fi

echo
echo "[test-qmd-bin] pass=$pass fail=$fail"
test "$fail" -eq 0
