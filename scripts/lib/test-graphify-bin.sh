#!/usr/bin/env bash
# scripts/lib/test-graphify-bin.sh — smoke test for graphify-bin.sh resolver
# (HIMMEL-891; de-forked to upstream PyPI in HIMMEL-1048 / issue #469).
#
# Hermetic: the operator machine already carries a REAL `uv tool install
# graphifyy` — every scenario below scrubs any PATH dir carrying a real `uv` or
# `graphify` (scripts/lib/hermetic-path.sh scrub_path) before layering in a stub
# `uv` (argv-logging to a file, behavior controlled by env vars) ahead of it.
# No network, no real installs.
#
# Validates:
#   1. graphify_install_hint emits the uv-tool-install recipe pinned to a
#      specific PyPI VERSION of graphifyy (not `latest`, not a git ref), with a
#      GRAPHIFY_VERSION override; the version-pin policy has its own assertion.
#   2. has_graphify is presence-only.
#   3. missing -> exactly one `uv tool install` call; graphify then resolvable.
#   4. idempotent re-run -> still exactly one call total (skip, adopt as
#      himmel-pin — the uv-resolved version equals the pinned version).
#   5. foreign install (uv tool list shows graphifyy at a DIFFERENT version, OR a
#      uv package whose version can't be read, OR a bare PATH-resolved graphify
#      with no uv package at all) -> adopted, ZERO install calls, every way.
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

# The pinned version the committed resolver installs (env override cleared so we
# read the committed default). Tests derive from this so a pin bump never breaks
# them: "our" install uses this version; foreign installs use a guaranteed-different one.
pinned_ver="$(env -u GRAPHIFY_VERSION bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_version')"

echo "[test-graphify-bin] graphify_install_hint (HIMMEL-1048: PyPI version pin)"
hint="$(graphify_install_hint)"
assert "hint uses uv tool install" grep -q '^uv tool install ' <<<"$hint"
assert "hint pins the graphifyy package to a specific PyPI version" \
  grep -qE 'graphifyy==[0-9]+\.[0-9]+\.[0-9]+' <<<"$hint"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "hint does NOT install from a git source (de-forked)" \
  bash -c '! grep -q "git+" <<<"$1"' _ "$hint"
assert "hint carries --with mcp (HIMMEL-996: upstream keeps the mcp dep optional)" \
  grep -q -- '--with mcp' <<<"$hint"

echo "[test-graphify-bin] pin policy (HIMMEL-1048): the configured version IS a semver, not a movable ref"
# `latest`/a branch/a bare tag would be non-reproducible; a published PyPI version
# is immutable. This pins the POLICY so a future 'bump the pin' change that swaps
# in `latest` or a non-version string fails here.
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "default GRAPHIFY_VERSION is a semver (X.Y.Z...)" \
  bash -c 'printf "%s" "$1" | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+"' _ "$pinned_ver"

echo "[test-graphify-bin] GRAPHIFY_VERSION override"
override_hint="$(GRAPHIFY_VERSION=9.9.9 graphify_install_hint)"
assert "hint honors GRAPHIFY_VERSION override" grep -q 'graphifyy==9.9.9' <<<"$override_hint"

echo "[test-graphify-bin] has_graphify is presence-only"
noreal_home="$tmpdir/noreal"; mkdir -p "$noreal_home"
rc=0
PATH="$base_path" HOME="$noreal_home" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; has_graphify' || rc=$?
assert "has_graphify=false with no graphify on PATH" test "$rc" -ne 0

# ── Stub uv: logs every call to UV_LOG; `tool list` echoes UV_LIST_FILE;
#    `tool dir` echoes UV_TOOL_DIR; `tool install ... graphifyy==<ver>` appends a
#    matching "graphifyy v<ver>" line to UV_LIST_FILE (the provenance signal the
#    resolver reads after the de-fork), writes a PyPI-shaped receipt, and drops a
#    working `graphify` shim into UV_BIN_DIR unless STUB_UV_INSTALL_RC != 0.
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
  # Scan argv for the graphifyy==<ver> package spec (after the de-fork the
  # install has no --from; the package spec IS the source). Echo the resolved
  # version back into `uv tool list` exactly as a real uv install would, so the
  # resolver's version-based provenance probe is exercised against real output.
  ver="0.0.0"
  for a in "$@"; do
    case "$a" in
      graphifyy==*)       ver="${a#graphifyy==}" ;;     # bare pin: graphifyy==X
      graphifyy\[*\]==*)  ver="${a##*==}" ;;            # extras pin: graphifyy[all]==X
    esac
  done
  mkdir -p "${UV_TOOL_DIR:?}/graphifyy"
  printf 'requirements = [{ name = "graphifyy" }]\n' > "${UV_TOOL_DIR}/graphifyy/uv-receipt.toml"
  printf 'graphifyy v%s\n' "$ver" >> "${UV_LIST_FILE:?}"
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
assert "missing: install argv carries --with mcp + the graphifyy version pin" \
  grep -qE 'UV tool install --with mcp graphifyy==[0-9]' "$fresh_log"
assert "missing: graphify shim landed on PATH" test -x "$fresh_bin/graphify"
assert "missing: has_graphify true post-install" \
  env PATH="$fresh_path" HOME="$fresh_home" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; has_graphify'

out2=$(HOME="$fresh_home" PATH="$fresh_path" UV_TOOL_DIR="$fresh_tools" UV_LIST_FILE="$fresh_list" \
       UV_BIN_DIR="$fresh_bin" UV_LOG="$fresh_log" \
       bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "idempotent re-run: rc 0" grep -q '^RC=0$' <<<"$out2"
assert "idempotent re-run: reports adopted himmel-pin" grep -q 'source=himmel-pin' <<<"$out2"
assert "idempotent re-run: still exactly one install call total" test "$(grep -c 'UV tool install' "$fresh_log")" -eq 1

echo "[test-graphify-bin] foreign uv-list entry (different version), binary NOT resolvable -> WARN + nonzero, no install (CR-r2)"
# uv metadata says graphifyy is installed but at a DIFFERENT version than we pin
# (a foreign/operator install), and NO graphify resolves on PATH (stale receipt /
# missing shim / uv bin dir off PATH). Adopting that silently would report success
# for a broken install; the adopted path must require has_graphify and answer WARN
# + honest nonzero -- and still never auto-reinstall over the foreign uv metadata.
funiv_home="$tmpdir/foreignuv"; mkdir -p "$funiv_home"
funiv_tools="$tmpdir/foreignuv-tools"; mkdir -p "$funiv_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$funiv_tools/graphifyy/uv-receipt.toml"
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

echo "[test-graphify-bin] foreign uv-list entry (different version), binary resolvable -> adopted rc 0, no install"
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

echo "[test-graphify-bin] graphify_source: uv graphifyy at the PINNED version -> himmel-pin"
pin_home="$tmpdir/pindirect"; mkdir -p "$pin_home"
pin_tools="$tmpdir/pindirect-tools"; mkdir -p "$pin_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$pin_tools/graphifyy/uv-receipt.toml"
pin_list="$tmpdir/pindirect-list"; printf 'graphifyy v%s\n' "$pinned_ver" > "$pin_list"
src=$(UV_TOOL_DIR="$pin_tools" UV_LIST_FILE="$pin_list" UV_LOG="$tmpdir/pindirect-log" \
      PATH="$stub_dir/bin:$base_path" HOME="$pin_home" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_source')
assert "uv graphifyy at the pinned version -> himmel-pin" test "$src" = "himmel-pin"
# CR-r2: the SAME himmel-pin metadata with no resolvable binary must not report
# success either -- WARN + nonzero, zero install calls.
pin_log="$tmpdir/pindirect-uvlog"; : > "$pin_log"
out=$(HOME="$pin_home" PATH="$stub_dir/bin:$base_path" UV_TOOL_DIR="$pin_tools" UV_LIST_FILE="$pin_list" \
      UV_BIN_DIR="$tmpdir/pindirect-bin" UV_LOG="$pin_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "himmel-pin metadata, unresolvable: rc nonzero" grep -qv '^RC=0$' <<<"$out"
assert "himmel-pin metadata, unresolvable: WARNs 'not resolvable on PATH'" grep -qi 'not resolvable on PATH' <<<"$out"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "himmel-pin metadata, unresolvable: no install call" bash -c '! grep -q "tool install" "$1"' _ "$pin_log"

echo "[test-graphify-bin] uv graphifyy whose version can't be read -> foreign (present but unprovable)"
# uv lists the package but the version token is unparseable (odd `uv tool list`
# output shape). Provenance can't confirm it's ours -> foreign, never 'not installed'.
badver_home="$tmpdir/badver"; mkdir -p "$badver_home"
badver_tools="$tmpdir/badver-tools"; mkdir -p "$badver_tools/graphifyy"
badver_list="$tmpdir/badver-list"; printf 'graphifyy vunknown\n' > "$badver_list"
src=$(UV_TOOL_DIR="$badver_tools" UV_LIST_FILE="$badver_list" UV_LOG="$tmpdir/badver-log" \
      PATH="$stub_dir/bin:$base_path" HOME="$badver_home" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_source')
assert "unreadable version -> foreign (present but unprovable, never 'not installed')" test "$src" = "foreign"

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

echo "[test-graphify-bin] graphify_update: uv graphifyy AT the pin -> up to date, no install"
gup_home="$tmpdir/gup-atpin"; mkdir -p "$gup_home"
gup_tools="$tmpdir/gup-atpin-tools"; mkdir -p "$gup_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$gup_tools/graphifyy/uv-receipt.toml"
gup_list="$tmpdir/gup-atpin-list"; printf 'graphifyy v%s\n' "$pinned_ver" > "$gup_list"
gup_bin="$tmpdir/gup-atpin-bin"; mkdir -p "$gup_bin"
cat > "$gup_bin/graphify" <<'EOF'
#!/usr/bin/env bash
echo x
EOF
chmod +x "$gup_bin/graphify"
gup_log="$tmpdir/gup-atpin-log"; : > "$gup_log"
out=$(HOME="$gup_home" PATH="$gup_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gup_tools" UV_LIST_FILE="$gup_list" \
      UV_BIN_DIR="$gup_bin" UV_LOG="$gup_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "update at-pin: rc 0" grep -q '^RC=0$' <<<"$out"
assert "update at-pin: reports up to date" grep -qi 'up to date' <<<"$out"
# shellcheck disable=SC2016
assert "update at-pin: no install call" bash -c '! grep -q "tool install" "$1"' _ "$gup_log"

echo "[test-graphify-bin] graphify_update: uv graphifyy at DIFFERENT version + [all] extras -> reinstall at pin, extras preserved"
gud_home="$tmpdir/gup-diff"; mkdir -p "$gud_home"
gud_tools="$tmpdir/gup-diff-tools"; mkdir -p "$gud_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy", extras = ["all"] }]\n' > "$gud_tools/graphifyy/uv-receipt.toml"
gud_list="$tmpdir/gup-diff-list"; printf 'graphifyy v0.0.1\n' > "$gud_list"   # != pin
gud_bin="$tmpdir/gup-diff-bin"; mkdir -p "$gud_bin"
cat > "$gud_bin/graphify" <<'EOF'
#!/usr/bin/env bash
echo x
EOF
chmod +x "$gud_bin/graphify"
gud_log="$tmpdir/gup-diff-log"; : > "$gud_log"
out=$(HOME="$gud_home" PATH="$gud_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gud_tools" UV_LIST_FILE="$gud_list" \
      UV_BIN_DIR="$gud_bin" UV_LOG="$gud_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "update diff-ver: rc 0" grep -q '^RC=0$' <<<"$out"
assert "update diff-ver: force-reinstalls at pin preserving [all] extras" \
  grep -qE 'tool install --force --with mcp graphifyy\[all\]==[0-9]' "$gud_log"

echo "[test-graphify-bin] graphify_update: uv graphifyy AHEAD of pin -> left as-is, no install (CR codex-1: never downgrade/clobber)"
gua_home="$tmpdir/gup-ahead"; mkdir -p "$gua_home"
gua_tools="$tmpdir/gup-ahead-tools"; mkdir -p "$gua_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$gua_tools/graphifyy/uv-receipt.toml"
# 99.0.0 is guaranteed ahead of any real pin -> update must NOT touch it.
gua_list="$tmpdir/gup-ahead-list"; printf 'graphifyy v99.0.0\n' > "$gua_list"
gua_bin="$tmpdir/gup-ahead-bin"; mkdir -p "$gua_bin"
cat > "$gua_bin/graphify" <<'EOF'
#!/usr/bin/env bash
echo x
EOF
chmod +x "$gua_bin/graphify"
gua_log="$tmpdir/gup-ahead-log"; : > "$gua_log"
out=$(HOME="$gua_home" PATH="$gua_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gua_tools" UV_LIST_FILE="$gua_list" \
      UV_BIN_DIR="$gua_bin" UV_LOG="$gua_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "update ahead-of-pin: rc 0" grep -q '^RC=0$' <<<"$out"
assert "update ahead-of-pin: reports not behind / leaving as-is" grep -qiE 'not behind|leaving as-is' <<<"$out"
# shellcheck disable=SC2016
assert "update ahead-of-pin: no install call (never downgrade)" bash -c '! grep -q "tool install" "$1"' _ "$gua_log"

echo "[test-graphify-bin] _graphify_version_lt fails safe on empty/unparseable input (CR HIMMEL-1048)"
# Empty or non-numeric version must return 1 (NOT lower), never 0 — else
# graphify_update force-reinstalls an unreadable-version install (clobber).
# shellcheck disable=SC2016
assert "version_lt: empty installed -> NOT lower (rc 1)" \
  bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; ! _graphify_version_lt "" "0.9.22"'
assert "version_lt: genuine behind -> lower (rc 0)" \
  bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_version_lt "0.9.1" "0.9.22"'

echo "[test-graphify-bin] graphify_update: uv graphifyy with UNPARSEABLE version -> left as-is, no install (CR HIMMEL-1048)"
guu_home="$tmpdir/gup-unparse"; mkdir -p "$guu_home"
guu_tools="$tmpdir/gup-unparse-tools"; mkdir -p "$guu_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$guu_tools/graphifyy/uv-receipt.toml"
guu_list="$tmpdir/gup-unparse-list"; printf 'graphifyy vunknown\n' > "$guu_list"   # version unreadable
guu_bin="$tmpdir/gup-unparse-bin"; mkdir -p "$guu_bin"
cat > "$guu_bin/graphify" <<'EOF'
#!/usr/bin/env bash
echo x
EOF
chmod +x "$guu_bin/graphify"
guu_log="$tmpdir/gup-unparse-log"; : > "$guu_log"
out=$(HOME="$guu_home" PATH="$guu_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$guu_tools" UV_LIST_FILE="$guu_list" \
      UV_BIN_DIR="$guu_bin" UV_LOG="$guu_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "update unparseable-ver: rc 0" grep -q '^RC=0$' <<<"$out"
# shellcheck disable=SC2016
assert "update unparseable-ver: no install call (never clobber on uncertainty)" \
  bash -c '! grep -q "tool install" "$1"' _ "$guu_log"

echo "[test-graphify-bin] graphify_update: not installed -> fresh install at pin"
gun_home="$tmpdir/gup-none"; mkdir -p "$gun_home"
gun_tools="$tmpdir/gup-none-tools"; mkdir -p "$gun_tools"
gun_list="$tmpdir/gup-none-list"; : > "$gun_list"
gun_bin="$tmpdir/gup-none-bin"; mkdir -p "$gun_bin"
gun_log="$tmpdir/gup-none-log"; : > "$gun_log"
out=$(HOME="$gun_home" PATH="$gun_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gun_tools" UV_LIST_FILE="$gun_list" \
      UV_BIN_DIR="$gun_bin" UV_LOG="$gun_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "update missing: exactly one install call (fresh at pin)" test "$(grep -c 'UV tool install' "$gun_log")" -eq 1

echo "[test-graphify-bin] graphify_update: foreign NON-uv install -> left as-is, no install"
guf_home="$tmpdir/gup-foreign"; mkdir -p "$guf_home"
guf_bin="$tmpdir/gup-foreign-bin"; mkdir -p "$guf_bin"
cat > "$guf_bin/graphify" <<'EOF'
#!/usr/bin/env bash
echo x
EOF
chmod +x "$guf_bin/graphify"
guf_list="$tmpdir/gup-foreign-list"; : > "$guf_list"   # empty: NO uv graphifyy package
guf_log="$tmpdir/gup-foreign-log"; : > "$guf_log"
out=$(HOME="$guf_home" PATH="$guf_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$tmpdir/gup-foreign-tools" UV_LIST_FILE="$guf_list" \
      UV_BIN_DIR="$tmpdir/gup-foreign-bin2" UV_LOG="$guf_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "update foreign non-uv: rc 0" grep -q '^RC=0$' <<<"$out"
assert "update foreign non-uv: left as-is" grep -qi 'leaves it as-is' <<<"$out"
# shellcheck disable=SC2016
assert "update foreign non-uv: no install call" bash -c '! grep -q "tool install" "$1"' _ "$guf_log"

echo "[test-graphify-bin] _graphify_mcp_import_ok probes the ENTRYPOINT's interpreter (HIMMEL-996)"
# A console script's shebang python is the most-specific env (covers pip/
# pipx foreign installs, not just the uv venv). Fake pythons: exit 0 = mcp
# importable, exit 1 = the missing-dep defect. rc 2 = nothing resolvable.
probe_dir="$tmpdir/mcp-probe"; mkdir -p "$probe_dir"
cat > "$probe_dir/py-ok" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$probe_dir/py-fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$probe_dir/py-ok" "$probe_dir/py-fail"
# HOME redirected: the venv-fallback probe path derives a default under
# $HOME when uv is absent -- the real operator HOME must never leak in.
probe_home="$tmpdir/probe-home"; mkdir -p "$probe_home"
printf '#!%s/py-ok python\n' "$probe_dir" > "$probe_dir/graphify-mcp"
chmod +x "$probe_dir/graphify-mcp"
rc=0
HOME="$probe_home" PATH="$probe_dir:$base_path" \
  bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_mcp_import_ok' || rc=$?
assert "probe rc 0 when the shebang python imports mcp" test "$rc" -eq 0
printf '#!%s/py-fail python\n' "$probe_dir" > "$probe_dir/graphify-mcp"
rc=0
HOME="$probe_home" PATH="$probe_dir:$base_path" \
  bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_mcp_import_ok' || rc=$?
assert "probe rc 1 when the shebang python cannot import mcp" test "$rc" -eq 1
rm -f "$probe_dir/graphify-mcp"
rc=0
HOME="$probe_home" PATH="$probe_dir:$base_path" \
  bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_mcp_import_ok' || rc=$?
assert "probe rc 2 (unvalidated) when no interpreter is resolvable" test "$rc" -eq 2

echo "[test-graphify-bin] consumer wiring — setup.sh/adopt.sh source graphify-bin.sh (HIMMEL-891)"
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
assert "setup.sh sources graphify-bin.sh" grep -q 'lib/graphify-bin.sh' "$repo_root/scripts/setup.sh"
assert "setup.sh calls graphify_install" grep -q 'graphify_install' "$repo_root/scripts/setup.sh"
assert "adopt.sh sources graphify-bin.sh" grep -q 'lib/graphify-bin.sh' "$repo_root/scripts/adopt.sh"
assert "adopt.sh calls graphify_install" grep -q 'graphify_install' "$repo_root/scripts/adopt.sh"

# HIMMEL-1047: MCP registration is the shared graphify_register_mcp impl, exposed
# via the `register-mcp` CLI case, called by both installers (adopt at its scope,
# setup at user scope) and delegated to by the pwsh mirrors.
assert "graphify-bin.sh defines graphify_register_mcp" grep -q 'graphify_register_mcp()' "$SCRIPT_DIR/graphify-bin.sh"
assert "graphify-bin.sh CLI exposes register-mcp" grep -q 'register-mcp) graphify_register_mcp' "$SCRIPT_DIR/graphify-bin.sh"
# Scope forwarding (HIMMEL-1047 CR): setup.sh pins user scope; adopt.sh forwards
# its own $SCOPE (project|user) — not a hardcoded scope.
assert "setup.sh registers at user scope" grep -q 'graphify_register_mcp user' "$repo_root/scripts/setup.sh"
# The grep pattern intentionally matches the LITERAL string graphify_register_mcp "$SCOPE"
# in adopt.sh (\$ = a literal $ in the BRE); it is not meant to expand here.
# shellcheck disable=SC2016
assert "adopt.sh forwards its SCOPE to register" grep -q 'graphify_register_mcp "\$SCOPE"' "$repo_root/scripts/adopt.sh"
# Project scope must NOT embed a machine-specific absolute path in the committed
# .mcp.json — the helper branches to the bare name for project scope (CR C14).
assert "graphify_register_mcp uses bare name for project scope" grep -q 'mcp_arg="graphify-mcp"' "$SCRIPT_DIR/graphify-bin.sh"
assert "setup.ps1 delegates register-mcp to bash" grep -q 'graphify-bin.sh" register-mcp' "$repo_root/scripts/setup.ps1"
assert "adopt.ps1 delegates register-mcp to bash" grep -q 'graphify-bin.sh" register-mcp' "$repo_root/scripts/adopt.ps1"

# set -e regression (HIMMEL-1047 CR, codex): a nonzero `claude mcp add` — the
# COMMON "already exists" idempotent case (rc=1) — must NOT abort a set -e caller
# (adopt.sh is `set -euo pipefail`). Hermetic: a stub claude returns exists/rc1;
# project scope avoids any uv/graphify-mcp dependency (bare name).
se_stub="$(mktemp -d)"
cat > "$se_stub/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"mcp add"*) echo "MCP server graphify already exists in project config" >&2; exit 1 ;;
esac
exit 0
STUB
chmod +x "$se_stub/claude"
se_out="$(PATH="$se_stub:$PATH" bash -c 'set -euo pipefail; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_register_mcp project; echo SE-REACHED-END' 2>&1 || true)"
# $1 is the INNER bash's positional (the passed "$se_out"), intentionally literal.
# shellcheck disable=SC2016
assert "set -e caller: nonzero mcp add (already-exists) does not abort" \
  bash -c 'printf "%s" "$1" | grep -q SE-REACHED-END' _ "$se_out"
# shellcheck disable=SC2016
assert "already-exists rc!=0 handled as idempotent skip" \
  bash -c 'printf "%s" "$1" | grep -qi "already registered at project scope"' _ "$se_out"
rm -rf "$se_stub"

echo
echo "[test-graphify-bin] pass=$pass fail=$fail"
test "$fail" -eq 0
