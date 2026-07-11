#!/usr/bin/env bash
# scripts/lib/test-graphify-bin.sh — smoke test for graphify-bin.sh resolver
# (HIMMEL-891).
#
# Hermetic: the operator machine already carries a REAL `uv tool install
# graphifyy` (v0.9.10, per HIMMEL-891 context) — every scenario below scrubs
# any PATH dir carrying a real `uv` or `graphify` (scripts/lib/hermetic-path.sh
# scrub_path) before layering in a stub `uv` (argv-logging to a file, behavior
# controlled by env vars) ahead of it. No network, no real installs.
#
# Validates:
#   1. graphify_install_hint emits the uv-tool-install recipe pinned to a
#      full commit SHA, never a movable branch/tag (+ REPO/REF overrides;
#      the 40-hex pin policy has its own dedicated assertion).
#   2. has_graphify is presence-only.
#   3. missing -> exactly one `uv tool install` call; graphify then resolvable.
#   4. idempotent re-run -> still exactly one call total (skip, adopt as
#      himmel-fork).
#   5. foreign install (uv tool list shows graphifyy from elsewhere, OR the
#      same repo at a DIFFERENT ref, OR a receipt-less uv package, OR a bare
#      PATH-resolved graphify with no uv package at all) -> adopted, ZERO
#      install calls, every way.
#   6. no uv on PATH / install failure / installed-but-unresolvable -> WARN +
#      honest nonzero rc, never crashes.
#   7. consumer wiring — setup.sh/adopt.sh source graphify-bin.sh and call
#      graphify_install (regression guard for the opt-in wiring itself).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/graphify-bin.sh
# shellcheck disable=SC1091  # sourced file not in input on test-only commits
. "$SCRIPT_DIR/graphify-bin.sh"
# shellcheck source=scripts/lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hermetic-path.sh"

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

# Base PATH carrying neither a real `uv` nor a real `graphify`.
base_path="$(scrub_path "$PATH" uv graphify)"

echo "[test-graphify-bin] graphify_install_hint (HIMMEL-891)"
hint="$(graphify_install_hint)"
assert "hint uses uv tool install" grep -q '^uv tool install ' <<<"$hint"
assert "hint mentions the himmel fork repo" grep -q 'yotamleo/graphify' <<<"$hint"
assert "hint pins a full commit SHA (CR-r3), not a movable ref" grep -qE '@[0-9a-f]{40} ' <<<"$hint"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "hint does NOT install from the mutable himmel-main branch" \
  bash -c '! grep -q "@himmel-main" <<<"$1"' _ "$hint"
assert "hint mentions the graphifyy package" grep -q 'graphifyy$' <<<"$hint"

echo "[test-graphify-bin] pin policy (CR-r3): the configured ref IS a full 40-hex commit SHA"
# Tags/branches are force-movable; only a commit SHA is content-addressed.
# This pins the POLICY so a future 'bump the pin' change that swaps in a tag
# or branch name fails here. (Run with the env override cleared -- the test
# targets the committed default.)
default_ref="$(env -u GRAPHIFY_FORK_REF bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_fork_ref')"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "default GRAPHIFY_FORK_REF is a full 40-hex SHA" \
  bash -c 'printf "%s" "$1" | grep -qE "^[0-9a-f]{40}$"' _ "$default_ref"

echo "[test-graphify-bin] GRAPHIFY_FORK_REPO / GRAPHIFY_FORK_REF overrides"
override_hint="$(GRAPHIFY_FORK_REPO=https://example.test/mirror/graphify GRAPHIFY_FORK_REF=my-ref graphify_install_hint)"
assert "hint honors GRAPHIFY_FORK_REPO override" grep -q 'example.test/mirror/graphify' <<<"$override_hint"
assert "hint honors GRAPHIFY_FORK_REF override" grep -q 'my-ref' <<<"$override_hint"

echo "[test-graphify-bin] has_graphify is presence-only"
noreal_home="$tmpdir/noreal"; mkdir -p "$noreal_home"
rc=0
PATH="$base_path" HOME="$noreal_home" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; has_graphify' || rc=$?
assert "has_graphify=false with no graphify on PATH" test "$rc" -ne 0

# ── Stub uv: logs every call to UV_LOG; `tool list` echoes UV_LIST_FILE;
#    `tool dir` echoes UV_TOOL_DIR; `tool install --from <url> graphifyy`
#    writes a matching uv-receipt.toml under UV_TOOL_DIR, appends to
#    UV_LIST_FILE, and drops a working `graphify` shim into UV_BIN_DIR
#    (simulating uv's own tool-bin-dir shim) unless STUB_UV_INSTALL_RC != 0.
stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir/bin"
cat > "$stub_dir/bin/uv" <<'STUB'
#!/usr/bin/env bash
echo "UV $*" >> "${UV_LOG:?}"
if [ "$1" = "tool" ] && [ "$2" = "list" ]; then
  [ -f "${UV_LIST_FILE:?}" ] && cat "$UV_LIST_FILE"
  exit 0
fi
if [ "$1" = "tool" ] && [ "$2" = "dir" ]; then
  printf '%s\n' "${UV_TOOL_DIR:?}"
  exit 0
fi
if [ "$1" = "tool" ] && [ "$2" = "install" ]; then
  [ "${STUB_UV_INSTALL_RC:-0}" -eq 0 ] || exit "${STUB_UV_INSTALL_RC}"
  mkdir -p "${UV_TOOL_DIR:?}/graphifyy"
  # $3=--from $4=<git+url@ref> $5=graphifyy — matches graphify_install()'s
  # exact argv shape. Write the receipt in uv's REAL serialization (git and
  # rev as SEPARATE keys, no combined git+url@ref literal) so the provenance
  # probes are exercised against what a real install leaves behind (CR-2).
  src="${4#git+}"
  printf 'requirements = [{ name = "graphifyy", git = "%s", rev = "%s" }]\n' \
    "${src%@*}" "${src##*@}" > "${UV_TOOL_DIR}/graphifyy/uv-receipt.toml"
  printf 'graphifyy v0.0.0-test\n' >> "${UV_LIST_FILE:?}"
  mkdir -p "${UV_BIN_DIR:?}"
  cat > "${UV_BIN_DIR}/graphify" <<'INNER'
#!/usr/bin/env bash
echo "GRAPHIFY STUB $*"
INNER
  chmod +x "${UV_BIN_DIR}/graphify"
  exit 0
fi
exit 0
STUB
chmod +x "$stub_dir/bin/uv"

echo "[test-graphify-bin] missing -> exactly one uv install call; then idempotent re-run"
fresh_home="$tmpdir/fresh"; mkdir -p "$fresh_home"
fresh_tools="$tmpdir/fresh-tools"; mkdir -p "$fresh_tools"
fresh_list="$tmpdir/fresh-list"; : > "$fresh_list"
fresh_bin="$tmpdir/fresh-bin"; mkdir -p "$fresh_bin"
fresh_log="$tmpdir/fresh-uvlog"; : > "$fresh_log"
fresh_path="$fresh_bin:$stub_dir/bin:$base_path"

out=$(HOME="$fresh_home" PATH="$fresh_path" UV_TOOL_DIR="$fresh_tools" UV_LIST_FILE="$fresh_list" \
      UV_BIN_DIR="$fresh_bin" UV_LOG="$fresh_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "missing: rc 0" grep -q '^RC=0$' <<<"$out"
assert "missing: exactly one uv tool install call" test "$(grep -c 'UV tool install' "$fresh_log")" -eq 1
assert "missing: graphify shim landed on PATH" test -x "$fresh_bin/graphify"
assert "missing: has_graphify true post-install" \
  env PATH="$fresh_path" HOME="$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; has_graphify'

out2=$(HOME="$fresh_home" PATH="$fresh_path" UV_TOOL_DIR="$fresh_tools" UV_LIST_FILE="$fresh_list" \
       UV_BIN_DIR="$fresh_bin" UV_LOG="$fresh_log" \
       bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "idempotent re-run: rc 0" grep -q '^RC=0$' <<<"$out2"
assert "idempotent re-run: reports adopted himmel-fork" grep -q 'source=himmel-fork' <<<"$out2"
assert "idempotent re-run: still exactly one install call total" test "$(grep -c 'UV tool install' "$fresh_log")" -eq 1

echo "[test-graphify-bin] foreign uv-list entry, binary NOT resolvable -> WARN + nonzero, no install (CR-r2)"
# uv metadata says graphifyy is installed (foreign receipt) but NO graphify
# resolves on PATH (stale receipt / missing shim / uv bin dir off PATH).
# Adopting that silently would report success for a broken install; the
# adopted path must require has_graphify and answer WARN + honest nonzero --
# and still never auto-reinstall over the foreign uv metadata.
funiv_home="$tmpdir/foreignuv"; mkdir -p "$funiv_home"
funiv_tools="$tmpdir/foreignuv-tools"; mkdir -p "$funiv_tools/graphifyy"
printf 'requirements = ["graphifyy==1.2.3"]\n' > "$funiv_tools/graphifyy/uv-receipt.toml"
funiv_list="$tmpdir/foreignuv-list"; printf 'graphifyy v1.2.3\n' > "$funiv_list"
funiv_log="$tmpdir/foreignuv-uvlog"; : > "$funiv_log"
funiv_path="$stub_dir/bin:$base_path"

out=$(HOME="$funiv_home" PATH="$funiv_path" UV_TOOL_DIR="$funiv_tools" UV_LIST_FILE="$funiv_list" \
      UV_BIN_DIR="$tmpdir/foreignuv-bin" UV_LOG="$funiv_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "foreign(uv-list, unresolvable): rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "foreign(uv-list, unresolvable): WARNs 'not resolvable on PATH'" grep -qi 'not resolvable on PATH' <<<"$out"
assert "foreign(uv-list, unresolvable): names source=foreign" grep -q 'source=foreign' <<<"$out"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "foreign(uv-list, unresolvable): no install call (never reinstall over uv metadata)" \
  bash -c '! grep -q "tool install" "$1"' _ "$funiv_log"

echo "[test-graphify-bin] foreign uv-list entry, binary resolvable -> adopted rc 0, no install"
# Same foreign uv metadata, but a working graphify IS on PATH -> clean adopt.
funivok_bin="$tmpdir/foreignuv-okbin"; mkdir -p "$funivok_bin"
cat > "$funivok_bin/graphify" <<'EOF'
#!/usr/bin/env bash
echo "FOREIGN UV GRAPHIFY $*"
EOF
chmod +x "$funivok_bin/graphify"
: > "$funiv_log"
out=$(HOME="$funiv_home" PATH="$funivok_bin:$funiv_path" UV_TOOL_DIR="$funiv_tools" UV_LIST_FILE="$funiv_list" \
      UV_BIN_DIR="$tmpdir/foreignuv-bin" UV_LOG="$funiv_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "foreign(uv-list, resolvable): rc 0" grep -q '^RC=0$' <<<"$out"
assert "foreign(uv-list, resolvable): reports source=foreign adopt" grep -q 'source=foreign' <<<"$out"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "foreign(uv-list, resolvable): no install call" bash -c '! grep -q "tool install" "$1"' _ "$funiv_log"

echo "[test-graphify-bin] foreign install via bare PATH graphify (no uv package) -> adopted, no install"
funpath_home="$tmpdir/foreignpath"; mkdir -p "$funpath_home"
funpath_bin="$tmpdir/foreignpath-bin"; mkdir -p "$funpath_bin"
cat > "$funpath_bin/graphify" <<'EOF'
#!/usr/bin/env bash
echo "FOREIGN GRAPHIFY $*"
EOF
chmod +x "$funpath_bin/graphify"
funpath_list="$tmpdir/foreignpath-list"; : > "$funpath_list"
funpath_log="$tmpdir/foreignpath-uvlog"; : > "$funpath_log"
funpath_path="$funpath_bin:$stub_dir/bin:$base_path"

out=$(HOME="$funpath_home" PATH="$funpath_path" UV_TOOL_DIR="$tmpdir/foreignpath-tools" UV_LIST_FILE="$funpath_list" \
      UV_BIN_DIR="$tmpdir/foreignpath-bin2" UV_LOG="$funpath_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "foreign(PATH): rc 0" grep -q '^RC=0$' <<<"$out"
assert "foreign(PATH): reports source=foreign" grep -q 'source=foreign' <<<"$out"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "foreign(PATH): no install call" bash -c '! grep -q "tool install" "$1"' _ "$funpath_log"
assert "foreign(PATH): has_graphify true (adopted binary resolvable)" \
  env PATH="$funpath_path" HOME="$funpath_home" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; has_graphify'

echo "[test-graphify-bin] graphify_source direct receipt match -> himmel-fork"
fork_home="$tmpdir/forkdirect"; mkdir -p "$fork_home"
fork_tools="$tmpdir/forkdirect-tools"; mkdir -p "$fork_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy", git = "https://github.com/yotamleo/graphify", rev = "df74ab44817d3b7f8ecafb333ec99899fe634f9d" }]\n' \
  > "$fork_tools/graphifyy/uv-receipt.toml"
fork_list="$tmpdir/forkdirect-list"; printf 'graphifyy v0.9.13\n' > "$fork_list"
src=$(UV_TOOL_DIR="$fork_tools" UV_LIST_FILE="$fork_list" UV_LOG="$tmpdir/forkdirect-log" \
      PATH="$stub_dir/bin:$base_path" HOME="$fork_home" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_source')
assert "direct receipt match (real uv git/rev serialization) -> himmel-fork" test "$src" = "himmel-fork"
# CR-r2: the SAME himmel-fork metadata with no resolvable binary must not
# report success either -- WARN + nonzero, zero install calls.
fork_log="$tmpdir/forkdirect-uvlog"; : > "$fork_log"
out=$(HOME="$fork_home" PATH="$stub_dir/bin:$base_path" UV_TOOL_DIR="$fork_tools" UV_LIST_FILE="$fork_list" \
      UV_BIN_DIR="$tmpdir/forkdirect-bin" UV_LOG="$fork_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "himmel-fork metadata, unresolvable: rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "himmel-fork metadata, unresolvable: WARNs 'not resolvable on PATH'" grep -qi 'not resolvable on PATH' <<<"$out"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "himmel-fork metadata, unresolvable: no install call" bash -c '! grep -q "tool install" "$1"' _ "$fork_log"

echo "[test-graphify-bin] same repo, DIFFERENT ref -> foreign (CR-2: provenance = exact pin)"
sameref_home="$tmpdir/samerepo"; mkdir -p "$sameref_home"
sameref_tools="$tmpdir/samerepo-tools"; mkdir -p "$sameref_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy", git = "https://github.com/yotamleo/graphify", rev = "himmel-main" }]\n' \
  > "$sameref_tools/graphifyy/uv-receipt.toml"
sameref_list="$tmpdir/samerepo-list"; printf 'graphifyy v0.9.13\n' > "$sameref_list"
src=$(UV_TOOL_DIR="$sameref_tools" UV_LIST_FILE="$sameref_list" UV_LOG="$tmpdir/samerepo-log" \
      PATH="$stub_dir/bin:$base_path" HOME="$sameref_home" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_source')
assert "same-repo-different-ref receipt -> foreign" test "$src" = "foreign"
sameref_uvlog="$tmpdir/samerepo-uvlog"; : > "$sameref_uvlog"
# A resolvable binary rides this run: the point here is CR-2 (adopt, never
# reinstall over a different-ref install) -- the unresolvable-metadata rc is
# covered by the CR-r2 scenarios above/below.
sameref_bin="$tmpdir/samerepo-okbin"; mkdir -p "$sameref_bin"
cat > "$sameref_bin/graphify" <<'EOF'
#!/usr/bin/env bash
echo "SAMEREPO GRAPHIFY $*"
EOF
chmod +x "$sameref_bin/graphify"
out=$(HOME="$sameref_home" PATH="$sameref_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$sameref_tools" \
      UV_LIST_FILE="$sameref_list" UV_BIN_DIR="$tmpdir/samerepo-bin" UV_LOG="$sameref_uvlog" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "same-repo-different-ref: install adopts (rc 0)" grep -q '^RC=0$' <<<"$out"
assert "same-repo-different-ref: reported as source=foreign" grep -q 'source=foreign' <<<"$out"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "same-repo-different-ref: no install call" bash -c '! grep -q "tool install" "$1"' _ "$sameref_uvlog"

echo "[test-graphify-bin] uv-managed package with MISSING receipt -> foreign (CR-6 pin)"
norcpt_home="$tmpdir/noreceipt"; mkdir -p "$norcpt_home"
norcpt_tools="$tmpdir/noreceipt-tools"; mkdir -p "$norcpt_tools/graphifyy"
norcpt_list="$tmpdir/noreceipt-list"; printf 'graphifyy v0.9.13\n' > "$norcpt_list"
src=$(UV_TOOL_DIR="$norcpt_tools" UV_LIST_FILE="$norcpt_list" UV_LOG="$tmpdir/noreceipt-log" \
      PATH="$stub_dir/bin:$base_path" HOME="$norcpt_home" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_source')
assert "missing receipt -> foreign (present but unprovable, never 'not installed')" test "$src" = "foreign"

echo "[test-graphify-bin] no uv on PATH -> WARN + nonzero rc"
nouv_home="$tmpdir/nouv"; mkdir -p "$nouv_home"
out=$(HOME="$nouv_home" PATH="$base_path" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "no-uv: rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "no-uv: WARNs" grep -qi 'uv not found' <<<"$out"

echo "[test-graphify-bin] uv install failure -> WARN + nonzero rc"
ufail_home="$tmpdir/ufail"; mkdir -p "$ufail_home"
ufail_tools="$tmpdir/ufail-tools"; mkdir -p "$ufail_tools"
ufail_list="$tmpdir/ufail-list"; : > "$ufail_list"
ufail_log="$tmpdir/ufail-uvlog"; : > "$ufail_log"
out=$(HOME="$ufail_home" PATH="$stub_dir/bin:$base_path" UV_TOOL_DIR="$ufail_tools" UV_LIST_FILE="$ufail_list" \
      UV_BIN_DIR="$tmpdir/ufail-bin" UV_LOG="$ufail_log" STUB_UV_INSTALL_RC=1 \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "install-fail: rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "install-fail: ERROR reported" grep -qi 'graphify install failed' <<<"$out"

echo "[test-graphify-bin] install succeeds but shim NOT on PATH -> WARN + honest nonzero rc (CR-4)"
# The stub drops the shim into UV_BIN_DIR as usual, but UV_BIN_DIR is NOT part
# of the invocation PATH -- the post-install has_graphify probe must fail, and
# graphify_install must say so honestly (WARNING + nonzero) instead of
# reporting a resolvable install.
nopath_home="$tmpdir/nopath"; mkdir -p "$nopath_home"
nopath_tools="$tmpdir/nopath-tools"; mkdir -p "$nopath_tools"
nopath_list="$tmpdir/nopath-list"; : > "$nopath_list"
nopath_bin="$tmpdir/nopath-bin"; mkdir -p "$nopath_bin"
nopath_log="$tmpdir/nopath-uvlog"; : > "$nopath_log"
out=$(HOME="$nopath_home" PATH="$stub_dir/bin:$base_path" UV_TOOL_DIR="$nopath_tools" \
      UV_LIST_FILE="$nopath_list" UV_BIN_DIR="$nopath_bin" UV_LOG="$nopath_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "unresolvable: install WAS attempted (one uv call)" test "$(grep -c 'UV tool install' "$nopath_log")" -eq 1
assert "unresolvable: rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "unresolvable: WARNs 'not resolvable on PATH'" grep -qi 'not resolvable on PATH' <<<"$out"

echo "[test-graphify-bin] consumer wiring — setup.sh/adopt.sh source graphify-bin.sh (HIMMEL-891)"
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
assert "setup.sh sources graphify-bin.sh" grep -q 'lib/graphify-bin.sh' "$repo_root/scripts/setup.sh"
assert "setup.sh calls graphify_install" grep -q 'graphify_install' "$repo_root/scripts/setup.sh"
assert "adopt.sh sources graphify-bin.sh" grep -q 'lib/graphify-bin.sh' "$repo_root/scripts/adopt.sh"
assert "adopt.sh calls graphify_install" grep -q 'graphify_install' "$repo_root/scripts/adopt.sh"

echo
echo "[test-graphify-bin] pass=$pass fail=$fail"
test "$fail" -eq 0
