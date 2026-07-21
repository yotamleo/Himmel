#!/usr/bin/env bash
# scripts/lib/test-fix-qmd-stub.sh — smoke test for fix-qmd-stub.sh (HIMMEL-163).
#
# Validates:
#   1. --dry-run reports the broken stub but touches nothing.
#   2. Patching rewrites the stub, backs up the original, keeps it executable.
#   3. Re-running is idempotent (already-patched stubs + backup untouched).
#   4. A truncated patch (marker present, exit-127 sentinel missing) is
#      detected as corrupted and re-patched, backup untouched.
#   5. An upstream in-place rewrite (marker-less, dist-less — including a
#      dist-less upstream "fix") is re-patched BY DESIGN: first backup kept,
#      differing content noted. See intended-semantics block in the fixer.
#   6. Healthy stubs (plugin dist present) are left alone.
#   7. Missing cache root is a clean no-op (rc=0); present-but-unreadable
#      cache root OR intermediate dir (root/qmd unreadable, root readable)
#      is an error (rc=1) — skipped where chmod 000 is a no-op.
#   8. A cache root containing spaces survives a full fixer cycle; a forced
#      backup failure (qmd.orig pre-created as a conflicting directory)
#      yields ERR + failed=1 + rc=1.
#   9. The patched stub dispatches: plugin dist (node via package-lock.json,
#      bun via bun.lock, node bare fallback) > bun global (with a stderr
#      notice + truthful 127 when the js exists but bun doesn't) >
#      PATH qmd > 127; the mcp arg exports the llama/ggml quiet env (and
#      ONLY the mcp arg); no exec recursion when the stub's own dir leads
#      PATH (BIN_DIR self-compare), when sibling plugin-cache version dirs
#      are on PATH (the */plugins/cache/qmd/* glob), NOR when a relocated
#      cache root defeats that glob (structural marker guard); argv passes
#      through exactly (per-line fakes — count, order, space boundaries).
#  10. Consumers (setup.sh, setup.ps1, ubuntu.sh) invoke the fixer.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXER="$SCRIPT_DIR/fix-qmd-stub.sh"

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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Fake plugin cache with an upstream-shaped broken stub (no dist/ tree).
# The root deliberately contains a plugins/cache segment so the patched
# stub's */plugins/cache/qmd/* recursion-guard glob matches the fixture
# (real layout: ~/.claude/plugins/cache).
cache="$tmpdir/plugins/cache"
verdir="$cache/qmd/qmd/0.1.0"
mkdir -p "$verdir/bin"
cat > "$verdir/bin/qmd" <<'EOF'
#!/bin/sh
DIR="$(cd -P "$(dirname "$0")/.." && pwd)"
exec bun "$DIR/dist/cli/qmd.js" "$@"
EOF
chmod +x "$verdir/bin/qmd"
orig_sum="$(cksum < "$verdir/bin/qmd")"

echo "[test-fix-qmd-stub] --dry-run reports but touches nothing"
output="$(bash "$FIXER" --cache-root "$cache" --dry-run)"
assert "dry-run reports would-patch" grep -q 'DRY would patch' <<<"$output"
assert "dry-run leaves stub unchanged" test "$(cksum < "$verdir/bin/qmd")" = "$orig_sum"
assert "dry-run writes no backup" test ! -f "$verdir/bin/qmd.orig"

echo "[test-fix-qmd-stub] broken stub gets patched"
output="$(bash "$FIXER" --cache-root "$cache")"
rc=$?
assert "fixer rc=0" test "$rc" -eq 0
assert "fixer reports patched=1" grep -q 'patched=1 ' <<<"$output"
assert "stub carries patch marker" grep -q 'himmel-qmd-stub-patch' "$verdir/bin/qmd"
assert "original backed up to qmd.orig" test -f "$verdir/bin/qmd.orig"
assert "backup preserves original content" test "$(cksum < "$verdir/bin/qmd.orig")" = "$orig_sum"
assert "patched stub is executable" test -x "$verdir/bin/qmd"

echo "[test-fix-qmd-stub] re-run is idempotent"
patched_sum="$(cksum < "$verdir/bin/qmd")"
output="$(bash "$FIXER" --cache-root "$cache")"
assert "second run reports already-patched" grep -q 'already patched' <<<"$output"
assert "second run leaves stub unchanged" test "$(cksum < "$verdir/bin/qmd")" = "$patched_sum"
assert "second run leaves backup unchanged" test "$(cksum < "$verdir/bin/qmd.orig")" = "$orig_sum"

echo "[test-fix-qmd-stub] truncated patch (marker, no sentinel) is re-patched"
# Simulate a truncated write: marker (line 2) survives, exit-127 tail lost.
head -5 "$verdir/bin/qmd" > "$verdir/bin/qmd.trunc"
mv "$verdir/bin/qmd.trunc" "$verdir/bin/qmd"
chmod +x "$verdir/bin/qmd"
assert "truncated stub still carries the marker" grep -q 'himmel-qmd-stub-patch' "$verdir/bin/qmd"
output="$(bash "$FIXER" --cache-root "$cache")"
assert "corrupted patch detected, not 'already patched'" grep -q 'corrupted patch' <<<"$output"
assert "truncated stub re-patched (sentinel restored)" grep -q '^exit 127$' "$verdir/bin/qmd"
assert "re-patched stub is executable" test -x "$verdir/bin/qmd"
assert "backup untouched by corrupt re-patch" test "$(cksum < "$verdir/bin/qmd.orig")" = "$orig_sum"

echo "[test-fix-qmd-stub] upstream in-place rewrite — re-patched, first backup kept, note printed"
# Covers BOTH CR cases at once: upstream rewrote the stub in the same
# version dir, and the rewrite is itself a dist-less "fix". Intended
# semantics (documented in the fixer header): marker-less + dist-less is
# always rewritten; the FIRST original stays in qmd.orig; the differing
# content is noted, not silently discarded.
cat > "$verdir/bin/qmd" <<'EOF'
#!/bin/sh
# upstream-fixed stub v2: dispatches without dist/ (still rewritten by design)
exec qmd-real "$@"
EOF
chmod +x "$verdir/bin/qmd"
output="$(bash "$FIXER" --cache-root "$cache")"
assert "rewritten upstream stub re-patched" grep -q 'himmel-qmd-stub-patch' "$verdir/bin/qmd"
assert "note printed about differing backup" grep -q 'differs from existing' <<<"$output"
assert "first backup kept (not overwritten)" test "$(cksum < "$verdir/bin/qmd.orig")" = "$orig_sum"

echo "[test-fix-qmd-stub] healthy stub (dist present) is left alone"
verdir2="$cache/qmd/qmd/0.2.0"
mkdir -p "$verdir2/bin" "$verdir2/dist/cli"
cat > "$verdir2/bin/qmd" <<'EOF'
#!/bin/sh
DIR="$(cd -P "$(dirname "$0")/.." && pwd)"
exec bun "$DIR/dist/cli/qmd.js" "$@"
EOF
chmod +x "$verdir2/bin/qmd"
echo "" > "$verdir2/dist/cli/qmd.js"
output="$(bash "$FIXER" --cache-root "$cache")"
assert "healthy stub reported" grep -q 'healthy (dist present' <<<"$output"
# shellcheck disable=SC2016
# Single quotes intentional — $1 expands inside the spawned bash -c subshell.
assert "healthy stub NOT marker-patched" bash -c '! grep -q himmel-qmd-stub-patch "$1"' _ "$verdir2/bin/qmd"

echo "[test-fix-qmd-stub] empty cache root is a clean no-op"
rc=0
bash "$FIXER" --cache-root "$tmpdir/no-such-cache" >/dev/null || rc=$?
assert "rc=0 when no stubs found" test "$rc" -eq 0

echo "[test-fix-qmd-stub] unreadable cache root is an error, not a silent no-op"
unread="$tmpdir/unreadable-root"
mkdir -p "$unread/qmd"
chmod 000 "$unread"
if [ -r "$unread" ] && [ -x "$unread" ]; then
  # Git Bash / Windows ACLs: chmod 000 on a dir is a no-op — can't exercise.
  echo "  skip: platform does not enforce directory permission drop"
  chmod 755 "$unread"
else
  rc=0
  bash "$FIXER" --cache-root "$unread" >/dev/null 2>&1 || rc=$?
  assert "rc=1 on present-but-unreadable cache root" test "$rc" -eq 1
  chmod 755 "$unread"
fi

echo "[test-fix-qmd-stub] unreadable INTERMEDIATE dir (root readable) is an error too"
# Root readable but $root/qmd untraversable: the stub glob expands empty one
# level deeper — must not masquerade as "nothing to do" rc=0.
deepunread="$tmpdir/deep-unread"
mkdir -p "$deepunread/qmd/qmd"
chmod 000 "$deepunread/qmd"
if [ -r "$deepunread/qmd" ] && [ -x "$deepunread/qmd" ]; then
  # Git Bash / Windows ACLs: chmod 000 on a dir is a no-op — can't exercise.
  echo "  skip: platform does not enforce directory permission drop"
  chmod 755 "$deepunread/qmd"
else
  rc=0
  bash "$FIXER" --cache-root "$deepunread" >/dev/null 2>&1 || rc=$?
  assert "rc=1 on unreadable intermediate (root/qmd)" test "$rc" -eq 1
  chmod 755 "$deepunread/qmd"
fi

echo "[test-fix-qmd-stub] backup failure surfaces: ERR + failed counted + rc=1"
# Force the backup cp to fail portably: qmd.orig pre-created as a directory
# CONTAINING a directory named qmd — `cp stub stub.orig` resolves to
# stub.orig/qmd, and cp cannot overwrite a directory with a non-directory
# (an EMPTY qmd.orig dir would not work: cp would happily copy into it).
failcache="$tmpdir/failcache"
fverdir="$failcache/qmd/qmd/0.9.0"
mkdir -p "$fverdir/bin"
cat > "$fverdir/bin/qmd" <<'EOF'
#!/bin/sh
DIR="$(cd -P "$(dirname "$0")/.." && pwd)"
exec bun "$DIR/dist/cli/qmd.js" "$@"
EOF
chmod +x "$fverdir/bin/qmd"
mkdir -p "$fverdir/bin/qmd.orig/qmd"
rc=0
output="$(bash "$FIXER" --cache-root "$failcache" 2>&1)" || rc=$?
assert "rc=1 when a stub fails" test "$rc" -eq 1
assert "ERR backup-failed printed" grep -q 'ERR fix-qmd-stub: backup failed' <<<"$output"
assert "summary counts failed=1" grep -q 'failed=1' <<<"$output"
# shellcheck disable=SC2016
# Single quotes intentional — $1 expands inside the spawned bash -c subshell.
assert "stub left unpatched on backup failure" bash -c '! grep -q himmel-qmd-stub-patch "$1"' _ "$fverdir/bin/qmd"

echo "[test-fix-qmd-stub] unreadable stub (grep rc=2) — ERR + failed counted, not misleading backup-failed"
# Distinguishes grep rc=2 (unreadable stub) from rc=1 (no marker): the fix
# must NOT flow into the backup/patch path and emit a confusing "backup failed".
unread_stub_cache="$tmpdir/unread-stub-cache"
uvdir="$unread_stub_cache/qmd/qmd/0.8.0"
mkdir -p "$uvdir/bin"
cat > "$uvdir/bin/qmd" <<'EOF'
#!/bin/sh
exec bun "$DIR/dist/cli/qmd.js" "$@"
EOF
chmod +x "$uvdir/bin/qmd"
chmod 000 "$uvdir/bin/qmd"
if [ -r "$uvdir/bin/qmd" ]; then
  # Git Bash / Windows: chmod 000 on a file is a no-op — skip.
  echo "  skip: platform does not enforce file permission drop"
  chmod 755 "$uvdir/bin/qmd"
else
  rc=0
  output="$(bash "$FIXER" --cache-root "$unread_stub_cache" 2>&1)" || rc=$?
  assert "rc=1 on unreadable stub" test "$rc" -eq 1
  assert "ERR stub-unreadable printed (not backup-failed)" grep -q 'stub unreadable' <<<"$output"
  assert "summary counts failed=1" grep -q 'failed=1' <<<"$output"
  backup_failed_count=$(grep -c 'backup failed' <<<"$output" || true)
  assert "no misleading backup-failed error" test "$backup_failed_count" -eq 0
  chmod 755 "$uvdir/bin/qmd"
fi

echo "[test-fix-qmd-stub] hostile cache-root path (spaces) — full fixer cycle"
spaced_cache="$tmpdir/cache with space"
sverdir="$spaced_cache/qmd/qmd/1.0.0"
mkdir -p "$sverdir/bin"
cat > "$sverdir/bin/qmd" <<'EOF'
#!/bin/sh
DIR="$(cd -P "$(dirname "$0")/.." && pwd)"
exec bun "$DIR/dist/cli/qmd.js" "$@"
EOF
chmod +x "$sverdir/bin/qmd"
output="$(bash "$FIXER" --cache-root "$spaced_cache")"
rc=$?
assert "fixer rc=0 on spaced cache root" test "$rc" -eq 0
assert "spaced-path stub patched" grep -q 'himmel-qmd-stub-patch' "$sverdir/bin/qmd"
assert "spaced-path backup created" test -f "$sverdir/bin/qmd.orig"
assert "spaced-path stub executable" test -x "$sverdir/bin/qmd"

# --- patched stub behavior ---
# Minimal controlled PATH: fake-tool dir + system dirs the stub's sh needs.
# HOME + BUN_INSTALL overridden so bun-global resolution is fully controlled.
# Fakes print one argv element per ARG: line — `$*` joins with single spaces,
# so a word-splitting regression in the stub would be invisible to a "$*"
# echo; the ARG: lines make exact argv (count + boundaries) assertable. The
# ENV line exposes the stub's mcp-branch exports.
mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/bun" <<'EOF'
#!/usr/bin/env bash
echo "BUN $*"
echo "ENV LLAMA=${LLAMA_LOG_LEVEL:-unset} GGML=${GGML_LOG_LEVEL:-unset} SILENT=${GGML_BACKEND_SILENT:-unset}"
printf 'ARG:%s\n' "$@"
EOF
chmod +x "$tmpdir/bin/bun"
cat > "$tmpdir/bin/node" <<'EOF'
#!/usr/bin/env bash
echo "NODE $*"
printf 'ARG:%s\n' "$@"
EOF
chmod +x "$tmpdir/bin/node"
base_path="$verdir/bin:$tmpdir/bin:/usr/bin:/bin"

echo "[test-fix-qmd-stub] patched stub — plugin dist wins when present (bun.lock => bun)"
mkdir -p "$verdir/dist/cli"
echo "" > "$verdir/dist/cli/qmd.js"
touch "$verdir/bun.lock"
output="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$base_path" "$verdir/bin/qmd" --version)"
assert "plugin dist dispatched via bun (bun.lock)" grep -q '^BUN .*0\.1\.0/dist/cli/qmd\.js --version' <<<"$output"
rm -f "$verdir/bun.lock"

echo "[test-fix-qmd-stub] patched stub — plugin dist, package-lock.json => node"
touch "$verdir/package-lock.json"
output="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$base_path" "$verdir/bin/qmd" --version)"
assert "plugin dist dispatched via node (package-lock.json)" grep -q '^NODE .*0\.1\.0/dist/cli/qmd\.js --version' <<<"$output"
rm -f "$verdir/package-lock.json"

echo "[test-fix-qmd-stub] patched stub — plugin dist, no lockfile => node bare fallback"
output="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$base_path" "$verdir/bin/qmd" --version)"
assert "plugin dist bare fallback dispatched via node" grep -q '^NODE .*0\.1\.0/dist/cli/qmd\.js --version' <<<"$output"
rm -rf "$verdir/dist"

echo "[test-fix-qmd-stub] patched stub — bun global install"
mkdir -p "$tmpdir/.bun/install/global/node_modules/@tobilu/qmd/dist/cli"
echo "" > "$tmpdir/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
output="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$base_path" "$verdir/bin/qmd" --version)"
assert "bun-global dispatched" grep -q '^BUN .*@tobilu/qmd/dist/cli/qmd\.js --version' <<<"$output"

echo "[test-fix-qmd-stub] patched stub — BUN_INSTALL override honored"
mkdir -p "$tmpdir/custom-bun/install/global/node_modules/@tobilu/qmd/dist/cli"
echo "" > "$tmpdir/custom-bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
output="$(HOME="$tmpdir" BUN_INSTALL="$tmpdir/custom-bun" PATH="$base_path" "$verdir/bin/qmd" --version)"
assert "BUN_INSTALL path used" grep -q 'custom-bun' <<<"$output"

echo "[test-fix-qmd-stub] patched stub — args with spaces pass through as exact argv"
# Exact per-line argv compare: a word-splitting regression splits
# "/path with space" into three ARG: lines and fails BOTH asserts (a "$*"
# substring grep could never catch it — $* re-joins with single spaces).
output="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$base_path" "$verdir/bin/qmd" collection add "/path with space" --name himmel)"
expected_argv="$(printf 'ARG:%s\n' "$tmpdir/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js" collection add "/path with space" --name himmel)"
assert "argv count is 6 (qmd.js + 5 args)" test "$(grep -c '^ARG:' <<<"$output")" -eq 6
assert "argv lines exact (order + boundaries)" test "$(grep '^ARG:' <<<"$output")" = "$expected_argv"

echo "[test-fix-qmd-stub] patched stub — mcp arg exports quiet llama/ggml env"
# MCP stdio reserves stdout for JSON-RPC frames; the stub's mcp branch must
# export the log-silencing env before exec. Empty-string env prefixes make
# the run deterministic: the stub's ${VAR:-default} treats empty as unset.
output="$(HOME="$tmpdir" BUN_INSTALL='' LLAMA_LOG_LEVEL='' GGML_LOG_LEVEL='' GGML_BACKEND_SILENT='' PATH="$base_path" "$verdir/bin/qmd" mcp)"
assert "mcp: LLAMA_LOG_LEVEL=error exported" grep -q 'ENV LLAMA=error' <<<"$output"
assert "mcp: GGML_LOG_LEVEL=error exported" grep -q 'GGML=error' <<<"$output"
assert "mcp: GGML_BACKEND_SILENT=1 exported" grep -q 'SILENT=1' <<<"$output"
output="$(HOME="$tmpdir" BUN_INSTALL='' LLAMA_LOG_LEVEL='' GGML_LOG_LEVEL='' GGML_BACKEND_SILENT='' PATH="$base_path" "$verdir/bin/qmd" --version)"
assert "non-mcp: llama/ggml env NOT exported" grep -q 'ENV LLAMA=unset GGML=unset SILENT=unset' <<<"$output"

echo "[test-fix-qmd-stub] patched stub — bun-global js present but bun absent: notice + truthful 127"
if PATH="/usr/bin:/bin" command -v bun >/dev/null 2>&1; then
  echo "  skip: bun installed in /usr/bin or /bin on this machine"
else
  home_nobun="$tmpdir/home-nobun"
  mkdir -p "$home_nobun/.bun/install/global/node_modules/@tobilu/qmd/dist/cli"
  echo "" > "$home_nobun/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
  rc=0
  errout="$(HOME="$home_nobun" BUN_INSTALL='' PATH="$verdir/bin:/usr/bin:/bin" "$verdir/bin/qmd" --version 2>&1 >/dev/null)" || rc=$?
  assert "rc=127 when bun binary missing" test "$rc" -eq 127
  assert "stderr notice flags the missing bun" grep -q "but 'bun' is not on PATH" <<<"$errout"
  assert "127 message truthful about bun-global state" grep -q 'bun-global qmd present but bun is not on PATH' <<<"$errout"
fi

echo "[test-fix-qmd-stub] patched stub — PATH fallback, own dir leads PATH (no recursion)"
rm -rf "$tmpdir/.bun"
mkdir -p "$tmpdir/bin2"
cat > "$tmpdir/bin2/qmd" <<'EOF'
#!/usr/bin/env bash
echo "PATH-QMD $*"
printf 'ARG:%s\n' "$@"
EOF
chmod +x "$tmpdir/bin2/qmd"
# Stub's own bin/ first on PATH = the Claude Bash tool plugin-prepend shape.
output="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$verdir/bin:$tmpdir/bin2:/usr/bin:/bin" "$verdir/bin/qmd" --version)"
assert "falls through to next PATH qmd" grep -q '^PATH-QMD --version' <<<"$output"
# Exact argv through the PATH-exec route too (spaced arg survives intact).
output="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$verdir/bin:$tmpdir/bin2:/usr/bin:/bin" "$verdir/bin/qmd" search "two words")"
expected_argv="$(printf 'ARG:%s\n' search "two words")"
assert "PATH-exec argv lines exact" test "$(grep '^ARG:' <<<"$output")" = "$expected_argv"

echo "[test-fix-qmd-stub] patched stub — sibling plugin-cache version dirs skipped (no exec loop)"
verdir3="$cache/qmd/qmd/0.3.0"
mkdir -p "$verdir3/bin"
cat > "$verdir3/bin/qmd" <<'EOF'
#!/bin/sh
DIR="$(cd -P "$(dirname "$0")/.." && pwd)"
exec bun "$DIR/dist/cli/qmd.js" "$@"
EOF
chmod +x "$verdir3/bin/qmd"
bash "$FIXER" --cache-root "$cache" >/dev/null
assert "second version dir patched" grep -q 'himmel-qmd-stub-patch' "$verdir3/bin/qmd"
# TWO patched plugin-cache version dirs lead PATH — the exec-loop shape the
# */plugins/cache/qmd/* glob exists to break (BIN_DIR self-compare alone
# would exec the sibling, which would exec back: infinite loop). timeout
# turns a guard regression into a test failure instead of a hang.
output="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$verdir/bin:$verdir3/bin:$tmpdir/bin2:/usr/bin:/bin" timeout 10 "$verdir/bin/qmd" --version)"
assert "skips sibling version dir, falls through to non-plugin qmd" grep -q '^PATH-QMD --version' <<<"$output"

echo "[test-fix-qmd-stub] patched stub — relocated cache root (no plugins/cache segment), two patched siblings: no exec loop"
# A --cache-root relocated cache defeats the */plugins/cache/qmd/* glob, so
# only the structural marker guard breaks the A-execs-B-execs-A loop between
# two patched sibling version dirs. timeout turns a guard regression into a
# test failure instead of a hang.
relroot="$tmpdir/relocated"
rverdir1="$relroot/qmd/qmd/0.1.0"
rverdir2="$relroot/qmd/qmd/0.2.0"
mkdir -p "$rverdir1/bin" "$rverdir2/bin"
for d in "$rverdir1" "$rverdir2"; do
  cat > "$d/bin/qmd" <<'EOF'
#!/bin/sh
DIR="$(cd -P "$(dirname "$0")/.." && pwd)"
exec bun "$DIR/dist/cli/qmd.js" "$@"
EOF
  chmod +x "$d/bin/qmd"
done
bash "$FIXER" --cache-root "$relroot" >/dev/null
assert "relocated 0.1.0 patched" grep -q 'himmel-qmd-stub-patch' "$rverdir1/bin/qmd"
assert "relocated 0.2.0 patched" grep -q 'himmel-qmd-stub-patch' "$rverdir2/bin/qmd"
output="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$rverdir1/bin:$rverdir2/bin:$tmpdir/bin2:/usr/bin:/bin" timeout 10 "$rverdir1/bin/qmd" --version)"
assert "relocated siblings skipped (marker guard), falls through to non-plugin qmd" grep -q '^PATH-QMD --version' <<<"$output"
# Same shape from the OTHER sibling (B leads with A ahead of it on PATH).
output="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$rverdir2/bin:$rverdir1/bin:$tmpdir/bin2:/usr/bin:/bin" timeout 10 "$rverdir2/bin/qmd" --version)"
assert "relocated siblings skipped from the other direction too" grep -q '^PATH-QMD --version' <<<"$output"

echo "[test-fix-qmd-stub] patched stub — spaced cache root (glob defeated) falls through"
# $spaced_cache has no plugins/cache segment, so the glob does NOT match:
# the marker guard (and, behind it, the BIN_DIR self-compare) must handle a
# PATH entry containing a space.
output="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$sverdir/bin:$tmpdir/bin2:/usr/bin:/bin" timeout 10 "$sverdir/bin/qmd" --version)"
assert "spaced-path stub falls through to next PATH qmd" grep -q '^PATH-QMD --version' <<<"$output"

echo "[test-fix-qmd-stub] patched stub — nothing available => rc=127 + hint"
rc=0
errout="$(HOME="$tmpdir" BUN_INSTALL='' PATH="$verdir/bin:/usr/bin:/bin" "$verdir/bin/qmd" --version 2>&1 >/dev/null)" || rc=$?
assert "rc=127 when no qmd available" test "$rc" -eq 127
assert "error mentions the qmd-bin.sh install hint" grep -q 'qmd-bin.sh install' <<<"$errout"

echo "[test-fix-qmd-stub] consumer integration — setup scripts invoke the fixer"
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
assert "setup.sh calls fix-qmd-stub.sh" grep -q 'lib/fix-qmd-stub.sh' "$repo_root/scripts/setup.sh"
assert "setup.ps1 calls fix-qmd-stub.sh" grep -q 'lib/fix-qmd-stub.sh' "$repo_root/scripts/setup.ps1"
# HIMMEL-887: ubuntu.sh delegates himmel/luna wiring to `himmelctl bootstrap`
# (the NOTICE at ubuntu.sh) -- it no longer sources lib/fix-qmd-stub.sh directly.
# Assert the delegation instead of the removed direct call.
# shellcheck disable=SC2016
assert "ubuntu.sh does NOT reference lib/fix-qmd-stub.sh (wiring delegated, HIMMEL-887)" \
  bash -c '! grep -qF -- "lib/fix-qmd-stub.sh" "$1"' _ "$repo_root/scripts/machine-setup/ubuntu.sh"
# The NOTICE alone is not the contract: assert the executable delegation
# statement too (codex-adv finding, HIMMEL-934 CR round).
# shellcheck disable=SC2016
assert "ubuntu.sh execs himmelctl bootstrap.sh (delegation is real, HIMMEL-887)" \
  grep -qE -- '^[[:space:]]*(HIMMELCTL_REPO_ROOT="\$HIMMEL_PATH"[[:space:]]+)?exec[[:space:]]+bash[[:space:]]+"\$HIMMEL_PATH/scripts/himmelctl/bootstrap\.sh"[[:space:]]*$' "$repo_root/scripts/machine-setup/ubuntu.sh"
assert "ubuntu.sh prints the himmelctl bootstrap delegation NOTICE (HIMMEL-887)" \
  grep -q 'delegating to himmelctl bootstrap' "$repo_root/scripts/machine-setup/ubuntu.sh"

echo
echo "[test-fix-qmd-stub] pass=$pass fail=$fail"
test "$fail" -eq 0
