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

echo "[test-qmd-bin] qmd_install_hint emits the fork clone+build+link recipe (HIMMEL-877)"
hint="$(qmd_install_hint)"
assert "hint mentions git clone" grep -q '^git clone ' <<<"$hint"
assert "hint mentions the himmel fork repo" grep -q 'yotamleo/qmd' <<<"$hint"
assert "hint mentions the himmel-main branch" grep -q 'himmel-main' <<<"$hint"
assert "hint mentions bun install/build" grep -q 'bun install && bun run build' <<<"$hint"
# shellcheck disable=SC2016
# Single quotes intentional — $1 expands inside the spawned bash -c subshell.
assert "hint does NOT mention upstream bun add -g" bash -c '! grep -q "bun add -g" <<<"$1"' _ "$hint"

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

echo "[test-qmd-bin] QMD_FORK_REPO / QMD_FORK_BRANCH / QMD_FORK_DIR overrides (HIMMEL-877)"
override_hint="$(QMD_FORK_REPO=https://example.test/mirror/qmd.git QMD_FORK_BRANCH=my-branch QMD_FORK_DIR=/custom/fork/dir qmd_install_hint)"
assert "hint honors QMD_FORK_REPO override" grep -q 'example.test/mirror/qmd.git' <<<"$override_hint"
assert "hint honors QMD_FORK_BRANCH override" grep -q 'my-branch' <<<"$override_hint"
assert "hint honors QMD_FORK_DIR override" grep -q '/custom/fork/dir' <<<"$override_hint"

echo "[test-qmd-bin] has_qmd is presence-only (does not invoke binary)"
# Make the bun-js path point at a broken/empty script that would error on run.
mkdir -p "$tmpdir/broken-bun/install/global/node_modules/@tobilu/qmd/dist/cli"
echo "this is not valid js" > "$tmpdir/broken-bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
rc=0
HOME="$tmpdir" PATH="$tmpdir/bin:$PATH" BUN_INSTALL="$tmpdir/broken-bun" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; has_qmd' || rc=$?
assert "has_qmd=true even when bun-js is broken (presence only)" test "$rc" -eq 0

echo "[test-qmd-bin] qmd_install() fork clone+build+link recipe (HIMMEL-877)"
# Hermetic stub env: a fake `git` (clone creates a .git marker + package.json;
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
  clone)
    [ "${STUB_GIT_CLONE_RC:-0}" -eq 0 ] || exit "$STUB_GIT_CLONE_RC"
    target="${!#}"
    mkdir -p "$target/.git"
    echo '{}' > "$target/package.json"
    exit 0
    ;;
  fetch|checkout|reset) exit "${STUB_GIT_FETCH_RC:-0}" ;;
  remote)
    # `remote get-url origin` ownership probe: default answers the default
    # fork repo URL so owned-clone scenarios pass the guard.
    printf '%s\n' "${STUB_GIT_ORIGIN_URL:-https://github.com/yotamleo/qmd.git}"
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
  install) exit "${STUB_BUN_INSTALL_RC:-0}" ;;
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

git_log="$id2/git-calls"
bun_log="$id2/bun-calls"
qmd_install_env() { # $1 = HOME dir, remaining = the command to run under it
  local home="$1"; shift
  : > "$git_log"; : > "$bun_log"
  HOME="$home" GIT_LOG="$git_log" BUN_LOG="$bun_log" PATH="$id2/bin:$PATH" \
    STUB_GIT_CLONE_RC="${STUB_GIT_CLONE_RC:-0}" STUB_GIT_FETCH_RC="${STUB_GIT_FETCH_RC:-0}" \
    STUB_GIT_ORIGIN_URL="${STUB_GIT_ORIGIN_URL:-}" STUB_GIT_DIRTY="${STUB_GIT_DIRTY:-}" \
    STUB_BUN_INSTALL_RC="${STUB_BUN_INSTALL_RC:-0}" STUB_BUN_BUILD_RC="${STUB_BUN_BUILD_RC:-0}" \
    STUB_BUN_VERSION_RC="${STUB_BUN_VERSION_RC:-0}" STUB_QMD_VERSION="${STUB_QMD_VERSION:-2.6.10}" \
    "$@"
}

# -- fresh install: clone + build + link, rc 0 --------------------------------
fresh_home="$id2/fresh"; mkdir -p "$fresh_home"
STUB_GIT_CLONE_RC=0 STUB_GIT_FETCH_RC=0 STUB_BUN_INSTALL_RC=0 STUB_BUN_BUILD_RC=0 STUB_BUN_VERSION_RC=0
out=$(qmd_install_env "$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "fresh install: rc 0" grep -q '^RC=0$' <<<"$out"
assert "fresh install: cloned the fork" grep -q 'GIT clone' "$git_log"
assert "fresh install: built with bun" grep -q 'BUN run build' "$bun_log"
assert "fresh install: linked at the bun-global @tobilu/qmd path" \
  test -e "$fresh_home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"

# -- idempotent re-run: already fork-served + version ok -> skip, clone/build
#    never re-run (the version CHECK itself legitimately invokes bun once). --
out=$(qmd_install_env "$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
assert "idempotent re-run: rc 0" grep -q '^RC=0$' <<<"$out"
assert "idempotent re-run: no git call" test ! -s "$git_log"
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

# -- clone/fetch failure on an EXISTING clone: WARN + continues (build still
#    runs against the existing, un-updated clone contents). Pre-seed the
#    clone dir directly (NOT via a first qmd_install call) so the global path
#    is NOT yet linked -- otherwise the idempotent-skip check above would
#    short-circuit this run before it ever reaches the fetch/checkout step.
stale_home="$id2/stalefetch"
mkdir -p "$stale_home/.himmel/qmd-fork/.git"
echo '{}' > "$stale_home/.himmel/qmd-fork/package.json"
STUB_GIT_CLONE_RC=0 STUB_GIT_FETCH_RC=1 STUB_BUN_INSTALL_RC=0 STUB_BUN_BUILD_RC=0 STUB_BUN_VERSION_RC=0
out=$(qmd_install_env "$stale_home" bash -c '. "'"$SCRIPT_DIR"'/qmd-bin.sh"; qmd_install; echo "RC=$?"' 2>&1)
STUB_GIT_FETCH_RC=0
assert "fetch-fail: attempted the update (fetch) on the existing clone" grep -q 'GIT fetch' "$git_log"
assert "fetch-fail: WARNs and continues" grep -qi 'fetch/checkout failed' <<<"$out"
assert "fetch-fail: still builds + verifies (rc 0)" grep -q '^RC=0$' <<<"$out"

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
