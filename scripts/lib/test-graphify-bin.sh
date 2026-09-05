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
# The stub dir also carries a pre-linked floor of bash + the utilities the target
# reaches for (HIMMEL-2530). That is not optional decoration: scrub_path drops a
# PATH dir wholesale, so on any distro that packages a scrubbed tool into
# /usr/bin the scrub takes the interpreter with it. See the tool-floor block
# below for the contract and for how the floor was measured.
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

# link_hermetic_tool() calls the sourcing suite's `fail`. Distinct from the
# `fail` COUNTER above (bash keeps functions and variables in separate
# namespaces): a missing prerequisite is not an assertion failure to be tallied,
# it means the hermetic PATH cannot be built at all, so it aborts loudly.
fail() { echo "  FATAL: $*" >&2; exit 1; }

tmpdir="$(mktemp -d -t graphify-bin.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

# ── Hermetic tool floor (HIMMEL-2530) ───────────────────────────────────────
# scrub_path drops every PATH dir carrying a scrubbed tool WHOLESALE. Where a
# distro packages the scrubbed tool into /usr/bin (Arch ships uv, node and
# python3 there; graphify installs to ~/.local/bin), that takes bash and the
# coreutils down with it and the scrubbed PATH resolves NOTHING -- not even the
# interpreter, so every hermetic `bash -c` dies at rc 127 before running a line
# of the target. hermetic-path.sh's header states the contract this suite was
# breaking: link bash + every tool the target needs into a stub dir BEFORE the
# scrub, then prepend that dir on every hermetic invocation. Same class as
# HIMMEL-2470 (node) and HIMMEL-2520 (bun).
#
# UTILS is the measured floor, not a guess: a logging-shim dir over the whole
# suite recorded which binaries each scrub site actually reaches for. Re-derive
# it the same way after adding cases that shell out -- shim every candidate to
# `printf <name> >>log; exec <real> "$@"`, point the scrub sites at the shim
# dir, and read the log.
HERMETIC_UTILS="bash env cat chmod cp dirname grep head mkdir mktemp mv rm sed uname"

# Engines are linked only where the site does not deliberately scrub them, and
# only if the host actually has them -- a box without `python` is a legitimate
# machine state, not a missing suite prerequisite.
link_engine_if_present() { # $1 = engine, $2 = dest dir
  command -v "$1" >/dev/null 2>&1 && link_hermetic_tool "$1" "$2"
  return 0
}

build_hermetic_bin() { # $1 = dest dir, $2.. = engines to admit beyond UTILS
  local _dir="$1"; shift
  local _t
  mkdir -p "$_dir"
  for _t in $HERMETIC_UTILS; do link_hermetic_tool "$_t" "$_dir"; done
  for _t in "$@"; do link_engine_if_present "$_t" "$_dir"; done
}

# Base PATH carrying neither a real `uv` nor a real `graphify`. Everything else
# the machine has stays reachable -- including the node/python engines, which
# this site does NOT scrub.
base_path="$(scrub_path "$PATH" uv graphify)"

# Two floors, because some cases need `uv` absent:
#   $stub_dir/bin — floor + the stub `uv` written further down. Prepended by
#                   every case that wants a working (stubbed) uv.
#   $utils_bin    — floor only. Prepended by the cases whose whole point is that
#                   NO uv resolves (no-uv WARN path, the mcp-probe cases).
stub_dir="$tmpdir/stub"
build_hermetic_bin "$stub_dir/bin" node python3 python
utils_bin="$tmpdir/utils-bin"
build_hermetic_bin "$utils_bin" node python3 python

# The pinned version the committed resolver installs (env override cleared so we
# read the committed default). Tests derive from this so a pin bump never breaks
# them: "our" install uses this version; foreign installs use a guaranteed-different one.
pinned_ver="$(env -u GRAPHIFY_VERSION bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_version')"

echo "[test-graphify-bin] graphify_install_hint (HIMMEL-1048: PyPI version pin)"
hint="$(graphify_install_hint)"
assert "hint uses uv tool install" grep -q '^uv tool install ' <<<"$hint"
assert "hint pins the graphifyy package to a specific PyPI version" \
  grep -qE 'graphifyy\[kimi\]==[0-9]+\.[0-9]+\.[0-9]+' <<<"$hint"
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
assert "hint honors GRAPHIFY_VERSION override" grep -q 'graphifyy\[kimi\]==9.9.9' <<<"$override_hint"

echo "[test-graphify-bin] has_graphify is presence-only"
noreal_home="$tmpdir/noreal"; mkdir -p "$noreal_home"
# $utils_bin gives a working interpreter with no graphify (and no uv), and the
# HG sentinel PROVES has_graphify ran and returned false rather than inferring
# it from an exit code (HIMMEL-2530). This control was VACUOUS on both counts:
# bash itself was unresolvable, so the subshell died at rc 127 and the old
# `rc -ne 0` assertion passed without has_graphify ever executing. Asserting on
# rc cannot tell "has_graphify said no" from "the subshell never reached it";
# proving execution needs no enumeration of the failure modes that skip it.
noreal_out=$(PATH="$utils_bin:$base_path" HOME="$noreal_home" \
  bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; if has_graphify; then echo "HG=yes"; else echo "HG=no"; fi' 2>&1)
assert "has_graphify=false with no graphify on PATH" grep -q '^HG=no$' <<<"$noreal_out"

# ── Stub uv: logs every call to UV_LOG; `tool list` echoes UV_LIST_FILE;
#    `tool dir` echoes UV_TOOL_DIR; `tool install ... graphifyy==<ver>` appends a
#    matching "graphifyy v<ver>" line to UV_LIST_FILE (the provenance signal the
#    resolver reads after the de-fork), writes a PyPI-shaped receipt, and drops a
#    working `graphify` shim into UV_BIN_DIR unless STUB_UV_INSTALL_RC != 0.
# $stub_dir/bin already exists and carries the hermetic tool floor (built above);
# this adds the stub `uv` alongside it.
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
  grep -qE 'UV tool install --with mcp graphifyy\[kimi\]==[0-9]' "$fresh_log"
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
out=$(HOME="$nouv_home" PATH="$utils_bin:$base_path" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
# Assert the POSITIVE -- that a nonzero RC was actually printed. Two weaker
# forms were vacuous here: `grep -qv '^RC=0$'` inverted per LINE, so the
# WARNING line alone satisfied it even when RC=0 was present; and negating the
# whole match (`! grep -q '^RC=0$'`) still passed when the subshell died before
# printing any RC= marker at all, proving only that RC=0 was absent. Matching
# RC=<nonzero> proves the run reached the echo AND reported a failure.
assert "no-uv: rc nonzero" grep -qE '^RC=[1-9][0-9]*$' <<<"$out"
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
# uv's shim dir has no python; the actual tool interpreter is under the uv tool
# venv. First model an at-pin install whose Kimi imports fail there.
mkdir -p "$gup_tools/graphifyy/Scripts"
cat > "$gup_tools/graphifyy/Scripts/python.exe" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$gup_tools/graphifyy/Scripts/python.exe"
gup_log="$tmpdir/gup-atpin-log"; : > "$gup_log"
out=$(HOME="$gup_home" PATH="$gup_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gup_tools" UV_LIST_FILE="$gup_list" \
      UV_BIN_DIR="$gup_bin" UV_LOG="$gup_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "update at-pin with missing Kimi deps: rc remains 0 (WARN-not-fail)" grep -q '^RC=0$' <<<"$out"
assert "update at-pin: reports up to date" grep -qi 'up to date' <<<"$out"
assert "update at-pin: probes the real uv tool venv and WARNs on missing Kimi deps" grep -q "native Kimi backend dependencies" <<<"$out"
assert "update at-pin: WARN gives the exact force-repair command" \
  grep -qE "uv tool install --force --with mcp 'graphifyy\[kimi\]==${pinned_ver}'" <<<"$out"
# shellcheck disable=SC2016
assert "update at-pin: no install call" bash -c '! grep -q "tool install" "$1"' _ "$gup_log"

# The passing probe is silent: overwrite the same venv interpreter with a stub
# that accepts the import and re-run the already-at-pin path.
cat > "$gup_tools/graphifyy/Scripts/python.exe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$gup_tools/graphifyy/Scripts/python.exe"
out=$(HOME="$gup_home" PATH="$gup_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gup_tools" UV_LIST_FILE="$gup_list" \
      UV_BIN_DIR="$gup_bin" UV_LOG="$gup_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "update at-pin with importable Kimi deps: rc 0" grep -q '^RC=0$' <<<"$out"
# shellcheck disable=SC2016
assert "update at-pin with importable Kimi deps: no dependency WARN" \
  bash -c '! grep -q "native Kimi backend dependencies" <<<"$1"' _ "$out"

echo "[test-graphify-bin] graphify_install ADOPT path also WARNs on missing native Kimi deps (CR r5, finding 7)"
# A resolvable graphify install is ADOPTED (not freshly installed) -- the much
# more common scripts/adopt.sh path. The adopt early-return must still run the
# native-Kimi dep probe and WARN when the adopted venv cannot import
# openai/tiktoken, exactly as the fresh-install path does at graphify-bin.sh:211
# (CR r5 finding 7: previously the adopt return at :176 skipped the WARN).
adopt_k_home="$tmpdir/adopt-kimi"; mkdir -p "$adopt_k_home"
adopt_k_tools="$tmpdir/adopt-kimi-tools"; mkdir -p "$adopt_k_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$adopt_k_tools/graphifyy/uv-receipt.toml"
adopt_k_list="$tmpdir/adopt-kimi-list"; printf 'graphifyy v%s\n' "$pinned_ver" > "$adopt_k_list"
adopt_k_bin="$tmpdir/adopt-kimi-bin"; mkdir -p "$adopt_k_bin"
cat > "$adopt_k_bin/graphify" <<'EOF'
#!/usr/bin/env bash
echo ADOPT GRAPHIFY $*
EOF
chmod +x "$adopt_k_bin/graphify"
# Model the adopted venv interpreter: `import mcp` succeeds but
# `import openai, tiktoken` fails, isolating the Kimi-dep WARN from the mcp one.
mkdir -p "$adopt_k_tools/graphifyy/Scripts"
cat > "$adopt_k_tools/graphifyy/Scripts/python.exe" <<'EOF'
#!/usr/bin/env bash
case "$*" in *openai*) exit 1 ;; esac
exit 0
EOF
chmod +x "$adopt_k_tools/graphifyy/Scripts/python.exe"
adopt_k_log="$tmpdir/adopt-kimi-uvlog"; : > "$adopt_k_log"
out=$(HOME="$adopt_k_home" PATH="$adopt_k_bin:$stub_dir/bin:$base_path" \
      UV_TOOL_DIR="$adopt_k_tools" UV_LIST_FILE="$adopt_k_list" \
      UV_BIN_DIR="$adopt_k_bin" UV_LOG="$adopt_k_log" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_install; echo "RC=$?"' 2>&1)
assert "adopt path: rc 0 (adopt succeeds, WARN-not-fail)" grep -q '^RC=0$' <<<"$out"
assert "adopt path: reports the adopted himmel-pin source" grep -q 'source=himmel-pin' <<<"$out"
assert "adopt path: WARNs on missing native Kimi deps" grep -q "native Kimi backend dependencies" <<<"$out"
# shellcheck disable=SC2016
assert "adopt path: no install call (adopted, never reinstalled)" bash -c '! grep -q "tool install" "$1"' _ "$adopt_k_log"

# Shared fixture for the direct-copy skill refresh (HIMMEL-1750 redesign):
# a fake uv tool venv shaped like the real Windows install. Its python stub
# resolves the package path and importlib metadata but deliberately has NO
# graphify.__version__ response (the real 0.9.40 package has no such attribute).
# The metadata answer uses CRLF to exercise command-substitution normalization.
make_fake_graphify_venv() { # <tooldir> <version> -> echoes the fake package dir
  local tooldir="$1" ver="$2" pkg
  pkg="$tooldir/graphifyy/fake-site/graphify"
  mkdir -p "$tooldir/graphifyy/Scripts" "$pkg/skills/claude/references" "$pkg/skills/windows/references"
  printf 'FAKE POSIX SKILL BODY v%s\n' "$ver" > "$pkg/skill.md"
  printf 'FAKE WINDOWS SKILL BODY v%s\n' "$ver" > "$pkg/skill-windows.md"
  printf 'posix ref content v%s\n' "$ver" > "$pkg/skills/claude/references/quickstart.md"
  printf 'windows ref content v%s\n' "$ver" > "$pkg/skills/windows/references/quickstart.md"
  cat > "$tooldir/graphifyy/Scripts/python" <<EOF
#!/usr/bin/env bash
case "\$2" in
  *__file__*)              printf '%s\n' "$pkg" ;;
  *importlib.metadata*)    printf '%s\r\n' "$ver" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$tooldir/graphifyy/Scripts/python"
  printf '%s' "$pkg"
}

echo "[test-graphify-bin] _graphify_uv_tool_dir: prefer uv-reported directory when fallback also exists but has no Python"
srt_home="$tmpdir/sr-two-dirs"; mkdir -p "$srt_home/.local/share/uv/tools/graphifyy"
srt_tools="$tmpdir/sr-two-dirs-roaming"; mkdir -p "$srt_tools"
make_fake_graphify_venv "$srt_tools" "$pinned_ver" > /dev/null
srt_log="$tmpdir/sr-two-dirs-uvlog"; : > "$srt_log"
out=$(HOME="$srt_home" PATH="$stub_dir/bin:$base_path" \
      UV_TOOL_DIR="$srt_tools" UV_LIST_FILE="$tmpdir/sr-two-dirs-list" UV_LOG="$srt_log" \
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_skill_refresh; echo "RC=$?"' 2>&1)
assert "two tool dirs: rc 0" grep -q '^RC=0$' <<<"$out"
assert "two tool dirs: uv tool dir was queried" grep -q '^UV tool dir$' "$srt_log"
assert "two tool dirs: refresh used the uv-reported venv" grep -qi 'skill refreshed' <<<"$out"
assert "two tool dirs: copied from the uv-reported directory" \
  grep -q "FAKE .* SKILL BODY v$pinned_ver" "$srt_home/.claude/skills/graphify/SKILL.md"
assert "two tool dirs: marker came from uv-reported Python metadata" \
  test "$(cat "$srt_home/.claude/skills/graphify/.graphify_version")" = "$pinned_ver"

echo "[test-graphify-bin] _graphify_skill_refresh: resolved Python with unreadable metadata warns, never silently succeeds"
srb_home="$tmpdir/sr-bad-metadata"; mkdir -p "$srb_home/.claude/skills/graphify"
srb_tools="$tmpdir/sr-bad-metadata-tools"
srb_pkg=$(make_fake_graphify_venv "$srb_tools" "$pinned_ver")
cat > "$srb_tools/graphifyy/Scripts/python" <<EOF
#!/usr/bin/env bash
case "\$2" in
  *__file__*) printf '%s\n' "$srb_pkg" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$srb_tools/graphifyy/Scripts/python"
out=$(HOME="$srb_home" PATH="$stub_dir/bin:$base_path" \
      UV_TOOL_DIR="$srb_tools" UV_LIST_FILE="$tmpdir/sr-bad-metadata-list" UV_LOG="$tmpdir/sr-bad-metadata-uvlog" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_skill_refresh; echo "RC=$?"' 2>&1)
assert "bad metadata: rc 0 (best-effort contract)" grep -q '^RC=0$' <<<"$out"
assert "bad metadata: warning identifies graphifyy metadata" grep -qi 'cannot resolve graphifyy package metadata' <<<"$out"
assert "bad metadata: no skill copied" test ! -f "$srb_home/.claude/skills/graphify/SKILL.md"

echo "[test-graphify-bin] _graphify_skill_refresh: CURRENT marker under CLAUDE_CONFIG_DIR -> no copy (HIMMEL-1750 redirect regression)"
# A STALE marker sits in the DEFAULT root; the CURRENT marker lives in the
# redirected CLAUDE_CONFIG_DIR root. The refresh must read the redirected root
# and conclude "current" — reading ~/.claude would wrongly re-copy here.
srr_home="$tmpdir/sr-redir"; mkdir -p "$srr_home/.claude/skills/graphify"
printf '0.0.1' > "$srr_home/.claude/skills/graphify/.graphify_version"
srr_cfg="$tmpdir/sr-redir-cfg"; mkdir -p "$srr_cfg/skills/graphify/references"
printf '%s' "$pinned_ver" > "$srr_cfg/skills/graphify/.graphify_version"
printf 'existing current skill' > "$srr_cfg/skills/graphify/SKILL.md"
printf 'existing current ref' > "$srr_cfg/skills/graphify/references/quickstart.md"
srr_tools="$tmpdir/sr-redir-tools"
srr_pkg=$(make_fake_graphify_venv "$srr_tools" "$pinned_ver")
case "$(uname -s 2>/dev/null || echo)" in
  MINGW*|MSYS*|CYGWIN*)
    expected_skill="$srr_pkg/skill-windows.md"
    expected_refs="$srr_pkg/skills/windows/references/quickstart.md"
    ;;
  *)
    expected_skill="$srr_pkg/skill.md"
    expected_refs="$srr_pkg/skills/claude/references/quickstart.md"
    ;;
esac
out=$(HOME="$srr_home" CLAUDE_CONFIG_DIR="$srr_cfg" PATH="$stub_dir/bin:$base_path" \
      UV_TOOL_DIR="$srr_tools" UV_LIST_FILE="$tmpdir/sr-redir-list" UV_LOG="$tmpdir/sr-redir-uvlog" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_skill_refresh; echo "RC=$?"' 2>&1)
assert "skill-refresh redirect current: rc 0" grep -q '^RC=0$' <<<"$out"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "skill-refresh redirect current: no refresh performed" bash -c '! grep -qi "skill refreshed" <<<"$1"' _ "$out"
assert "skill-refresh redirect current: existing SKILL.md unchanged" test "$(cat "$srr_cfg/skills/graphify/SKILL.md")" = "existing current skill"

echo "[test-graphify-bin] _graphify_skill_refresh: STALE marker under a ROUTED CLAUDE_CONFIG_DIR -> refreshed IN PLACE, default profile untouched (redesign: direct copy is profile-safe)"
srs_cfg="$tmpdir/sr-stale-cfg"; mkdir -p "$srs_cfg/skills/graphify"
printf '0.0.1' > "$srs_cfg/skills/graphify/.graphify_version"
out=$(HOME="$srr_home" CLAUDE_CONFIG_DIR="$srs_cfg" PATH="$stub_dir/bin:$base_path" \
      UV_TOOL_DIR="$srr_tools" UV_LIST_FILE="$tmpdir/sr-stale-list" UV_LOG="$tmpdir/sr-stale-uvlog" \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_skill_refresh; echo "RC=$?"' 2>&1)
assert "skill-refresh routed stale: rc 0" grep -q '^RC=0$' <<<"$out"
assert "skill-refresh routed stale: refresh performed" grep -qi 'skill refreshed' <<<"$out"
assert "skill-refresh routed stale: SKILL.md copied into the ROUTED root" cmp -s "$srs_cfg/skills/graphify/SKILL.md" "$expected_skill"
assert "skill-refresh routed stale: references sidecar copied" cmp -s "$srs_cfg/skills/graphify/references/quickstart.md" "$expected_refs"
assert "skill-refresh routed stale: routed marker advanced" test "$(cat "$srs_cfg/skills/graphify/.graphify_version")" = "$pinned_ver"
assert "skill-refresh routed stale: DEFAULT profile untouched (no SKILL.md)" test ! -f "$srr_home/.claude/skills/graphify/SKILL.md"
assert "skill-refresh routed stale: DEFAULT profile marker unchanged" test "$(cat "$srr_home/.claude/skills/graphify/.graphify_version")" = "0.0.1"

echo "[test-graphify-bin] _graphify_skill_refresh: STALE marker under the DEFAULT root -> direct copy lands + marker written LAST"
srd_home="$tmpdir/sr-default"; mkdir -p "$srd_home/.claude/skills/graphify"
printf '0.0.1' > "$srd_home/.claude/skills/graphify/.graphify_version"
out=$(HOME="$srd_home" PATH="$stub_dir/bin:$base_path" \
      UV_TOOL_DIR="$srr_tools" UV_LIST_FILE="$tmpdir/sr-default-list" UV_LOG="$tmpdir/sr-default-uvlog" \
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_skill_refresh; echo "RC=$?"' 2>&1)
assert "skill-refresh default stale: rc 0" grep -q '^RC=0$' <<<"$out"
assert "skill-refresh default stale: refresh performed" grep -qi 'skill refreshed' <<<"$out"
assert "skill-refresh default stale: SKILL.md matches the platform package variant" cmp -s "$srd_home/.claude/skills/graphify/SKILL.md" "$expected_skill"
assert "skill-refresh default stale: references match the platform package variant" cmp -s "$srd_home/.claude/skills/graphify/references/quickstart.md" "$expected_refs"
assert "skill-refresh default stale: marker equals the venv-reported version" test "$(cat "$srd_home/.claude/skills/graphify/.graphify_version")" = "$pinned_ver"

echo "[test-graphify-bin] _graphify_skill_refresh: CURRENT marker with missing content triggers a repair"
src_home="$tmpdir/sr-current-missing"; mkdir -p "$src_home/.claude/skills/graphify"
printf '%s' "$pinned_ver" > "$src_home/.claude/skills/graphify/.graphify_version"
out=$(HOME="$src_home" PATH="$stub_dir/bin:$base_path" \
      UV_TOOL_DIR="$srr_tools" UV_LIST_FILE="$tmpdir/sr-current-missing-list" UV_LOG="$tmpdir/sr-current-missing-uvlog" \
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_skill_refresh; echo "RC=$?"' 2>&1)
assert "current marker missing content: rc 0" grep -q '^RC=0$' <<<"$out"
assert "current marker missing content: refresh performed" grep -qi 'skill refreshed' <<<"$out"
assert "current marker missing content: SKILL.md repaired" cmp -s "$src_home/.claude/skills/graphify/SKILL.md" "$expected_skill"
assert "current marker missing content: references repaired" cmp -s "$src_home/.claude/skills/graphify/references/quickstart.md" "$expected_refs"

echo "[test-graphify-bin] _graphify_skill_refresh: unsafe staging targets fail closed without advancing the marker"
sru_home="$tmpdir/sr-unsafe"; mkdir -p "$sru_home/.claude/skills/graphify/SKILL.md" "$sru_home/.claude/skills/graphify/SKILL.md.tmp"
printf '0.0.1' > "$sru_home/.claude/skills/graphify/.graphify_version"
out=$(HOME="$sru_home" PATH="$stub_dir/bin:$base_path" \
      UV_TOOL_DIR="$srr_tools" UV_LIST_FILE="$tmpdir/sr-unsafe-list" UV_LOG="$tmpdir/sr-unsafe-uvlog" \
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_skill_refresh; echo "RC=$?"' 2>&1)
assert "unsafe staging targets: rc 0 (best-effort contract)" grep -q '^RC=0$' <<<"$out"
assert "unsafe staging targets: warning emitted" grep -qi 'unsafe staging target' <<<"$out"
assert "unsafe staging targets: marker unchanged" test "$(cat "$sru_home/.claude/skills/graphify/.graphify_version")" = "0.0.1"
assert "unsafe staging targets: SKILL.md remains a directory" test -d "$sru_home/.claude/skills/graphify/SKILL.md"
assert "unsafe staging targets: staged directory cleaned" test ! -e "$sru_home/.claude/skills/graphify/SKILL.md.tmp"

echo "[test-graphify-bin] _graphify_skill_refresh: OTHER platforms are NEVER touched (HIMMEL-1750 redesign — no installer call at all)"
# Under the old installer-wrapping design the upstream installer falsified
# other platforms' markers and the wrapper had to snapshot/restore them (and
# still missed nested roots — CR r4/r5). The direct copy never invokes the
# installer, so a stale agents-platform skill keeps BOTH its marker and its
# content byte-identically; this test pins that invariant.
srm_home="$tmpdir/sr-markers"; mkdir -p "$srm_home/.claude/skills/graphify" "$srm_home/.agents/skills/graphify"
printf '0.0.1' > "$srm_home/.claude/skills/graphify/.graphify_version"
printf '0.0.2' > "$srm_home/.agents/skills/graphify/.graphify_version"
printf 'stale agents skill body' > "$srm_home/.agents/skills/graphify/SKILL.md"
out=$(HOME="$srm_home" PATH="$stub_dir/bin:$base_path" \
      UV_TOOL_DIR="$srr_tools" UV_LIST_FILE="$tmpdir/sr-markers-list" UV_LOG="$tmpdir/sr-markers-uvlog" \
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_skill_refresh; echo "RC=$?"' 2>&1)
assert "other-platforms: rc 0" grep -q '^RC=0$' <<<"$out"
assert "other-platforms: refresh performed" grep -qi 'skill refreshed' <<<"$out"
assert "other-platforms: claude marker advanced" test "$(cat "$srm_home/.claude/skills/graphify/.graphify_version")" = "$pinned_ver"
assert "other-platforms: agents marker untouched" test "$(cat "$srm_home/.agents/skills/graphify/.graphify_version")" = "0.0.2"
assert "other-platforms: agents skill content untouched" test "$(cat "$srm_home/.agents/skills/graphify/SKILL.md")" = "stale agents skill body"

echo "[test-graphify-bin] _graphify_skill_refresh: no uv venv python -> silent no-op (foreign installs untouched)"
srn_home="$tmpdir/sr-noviv"; mkdir -p "$srn_home/.claude/skills/graphify"
printf '0.0.1' > "$srn_home/.claude/skills/graphify/.graphify_version"
srn_tools="$tmpdir/sr-noviv-tools"; mkdir -p "$srn_tools"
out=$(HOME="$srn_home" PATH="$stub_dir/bin:$base_path" \
      UV_TOOL_DIR="$srn_tools" UV_LIST_FILE="$tmpdir/sr-noviv-list" UV_LOG="$tmpdir/sr-noviv-uvlog" \
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_skill_refresh; echo "RC=$?"' 2>&1)
assert "no-venv: rc 0" grep -q '^RC=0$' <<<"$out"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
assert "no-venv: silent no-op" bash -c '! grep -qiE "skill refreshed|WARNING" <<<"$1"' _ "$out"
assert "no-venv: marker unchanged" test "$(cat "$srn_home/.claude/skills/graphify/.graphify_version")" = "0.0.1"

echo "[test-graphify-bin] graphify_update: FRESH install also refreshes the skill (HIMMEL-1750)"
# graphify absent -> update delegates to graphify_install (uv stub drops a
# working shim) -> the skill refresh must run in the SAME update, not wait for
# a second one (CR codex-adv finding: first himmelctl update left the skill absent).
gfr_home="$tmpdir/gfr"; mkdir -p "$gfr_home"
gfr_tools="$tmpdir/gfr-tools"; mkdir -p "$gfr_tools"
# The redesigned refresh reads the venv python (not the installer) — give the
# fixture's tool dir a fake venv so the post-install refresh has a source.
make_fake_graphify_venv "$gfr_tools" "$pinned_ver" > /dev/null
gfr_list="$tmpdir/gfr-list"; : > "$gfr_list"
gfr_bin="$tmpdir/gfr-bin"; mkdir -p "$gfr_bin"
gfr_log="$tmpdir/gfr-uvlog"; : > "$gfr_log"
out=$(HOME="$gfr_home" PATH="$gfr_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gfr_tools" UV_LIST_FILE="$gfr_list" \
      UV_BIN_DIR="$gfr_bin" UV_LOG="$gfr_log" \
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "update fresh: rc 0" grep -q '^RC=0$' <<<"$out"
assert "update fresh: install happened" grep -q 'tool install' "$gfr_log"
assert "update fresh: skill refreshed in the same update" grep -qi 'skill refreshed' <<<"$out"

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
# GRAPHIFY_MCP_HOLDERS=0 (HIMMEL-1274): pin the holder probe to "clear". Without
# it this test is NOT hermetic — the real probe finds the DEVELOPER'S own live
# graphify-mcp servers (every Claude Code session spawns one) and the new
# pre-flight guard correctly skips the reinstall, so the assertion below goes
# red on a busy workstation and green on CI. Observed exactly that.
out=$(HOME="$gud_home" PATH="$gud_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gud_tools" UV_LIST_FILE="$gud_list" \
      UV_BIN_DIR="$gud_bin" UV_LOG="$gud_log" GRAPHIFY_MCP_HOLDERS=0 \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "update diff-ver: rc 0" grep -q '^RC=0$' <<<"$out"
assert "update diff-ver: force-reinstalls at pin preserving [all] extras" \
  grep -qE 'tool install --force --with mcp graphifyy\[all\]==[0-9]' "$gud_log"

# --- HIMMEL-1274: the pre-flight holder guard + verify-after ----------------
echo "[test-graphify-bin] graphify_update: live graphify-mcp holders -> SKIP the reinstall, leave the install alone"
gh_home="$tmpdir/gup-held"; mkdir -p "$gh_home"
gh_tools="$tmpdir/gup-held-tools"; mkdir -p "$gh_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy", extras = ["all"] }]\n' > "$gh_tools/graphifyy/uv-receipt.toml"
gh_list="$tmpdir/gup-held-list"; printf 'graphifyy v0.0.1\n' > "$gh_list"   # behind the pin
gh_bin="$tmpdir/gup-held-bin"; mkdir -p "$gh_bin"
printf '#!/usr/bin/env bash\necho x\n' > "$gh_bin/graphify"; chmod +x "$gh_bin/graphify"
gh_log="$tmpdir/gup-held-log"; : > "$gh_log"
out=$(HOME="$gh_home" PATH="$gh_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gh_tools" UV_LIST_FILE="$gh_list" \
      UV_BIN_DIR="$gh_bin" UV_LOG="$gh_log" GRAPHIFY_MCP_HOLDERS=3 \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
# rc 0: a deliberate, healthy skip — nothing failed and nothing is broken.
assert "held: rc 0 (a skip is not a failure)" grep -q '^RC=0$' <<<"$out"
assert "held: says SKIP with the holder count" grep -q 'SKIP: 3 graphify-mcp process' <<<"$out"
assert "held: states graphify KEEPS WORKING" grep -q 'KEEPS WORKING' <<<"$out"
assert "held: says the pin did NOT advance" grep -q 'has NOT advanced' <<<"$out"
assert "held: gives the manual repair command" grep -q "uv tool install --force --with mcp 'graphifyy" <<<"$out"
# The repair line is a COPY-PASTE instruction, and this fixture records extras
# ["all"], so the spec reads graphifyy[all]==<pin>. Unquoted, zsh — the macOS
# default shell — globs the brackets and the paste dies with "no matches found"
# instead of installing (public-PR CR). Assert the WHOLE spec is single-quoted:
# matching only the opening quote would still pass if the closing one were lost.
assert "held: the repair command single-quotes the [all] spec (zsh globs it otherwise)" \
  grep -qE "uv tool install --force --with mcp 'graphifyy\[all\]==[0-9][^']*'" <<<"$out"
# THE POINT: no uv install was attempted, so the entry points were never removed.
# shellcheck disable=SC2016
assert "held: NO uv install attempted (this is what keeps graphify working)" \
  bash -c '! grep -q "tool install" "$1"' _ "$gh_log"
# shellcheck disable=SC2016
assert "held: does NOT use the misleading 'non-fatal' wording" \
  bash -c '! grep -q "non-fatal" <<<"$1"' _ "$out"

# HIMMEL-1601: the reinstall-guard SKIP is a routine outcome on any busy
# workstation and can persist forever -- it must (a) still refresh the SKILL
# (a separate, non-locked target the package-reinstall refusal has no
# business blocking) and (b) escalate with a persisted, printed consecutive-
# skip counter instead of one advisory line indistinguishable run to run.
echo "[test-graphify-bin] graphify_update: holders>0 SKIP still refreshes the skill + tracks consecutive skips"
psc_home="$tmpdir/gup-skiptrack"; mkdir -p "$psc_home"
psc_tools="$tmpdir/gup-skiptrack-tools"; mkdir -p "$psc_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy", extras = [] }]\n' > "$psc_tools/graphifyy/uv-receipt.toml"
make_fake_graphify_venv "$psc_tools" "$pinned_ver" > /dev/null
psc_list="$tmpdir/gup-skiptrack-list"; printf 'graphifyy v0.0.1\n' > "$psc_list"   # behind the pin
psc_bin="$tmpdir/gup-skiptrack-bin"; mkdir -p "$psc_bin"
printf '#!/usr/bin/env bash\necho x\n' > "$psc_bin/graphify"; chmod +x "$psc_bin/graphify"
psc_log="$tmpdir/gup-skiptrack-log"; : > "$psc_log"
psc_marker="$psc_home/.claude/skills/graphify/.graphify_pin_skip_count"

# First SKIP: skill copied, counter created at 1.
# unset CLAUDE_CONFIG_DIR (codex-1 CR finding): _graphify_skill_refresh and
# the skip-marker helper both prioritize it over HOME, so an operator
# environment that exports it (a routed profile, per the tests above) would
# otherwise make this sandboxed test read/write REAL machine state.
out=$(HOME="$psc_home" PATH="$psc_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$psc_tools" UV_LIST_FILE="$psc_list" \
      UV_BIN_DIR="$psc_bin" UV_LOG="$psc_log" GRAPHIFY_MCP_HOLDERS=2 \
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "skip-track 1st: rc 0" grep -q '^RC=0$' <<<"$out"
assert "skip-track 1st: skill WAS refreshed despite the package skip" \
  grep -q "FAKE .* SKILL BODY v$pinned_ver" "$psc_home/.claude/skills/graphify/SKILL.md"
assert "skip-track 1st: escalated as a STANDING OPERATOR ACTION" grep -q 'STANDING OPERATOR ACTION' <<<"$out"
assert "skip-track 1st: counter reads 1 consecutive" grep -q 'SKIPPED 1 consecutive' <<<"$out"
assert "skip-track 1st: counter file persisted at 1" test "$(cat "$psc_marker" 2>/dev/null)" = "1"

# Second SKIP (same HOME): counter advances to 2, still visible without logs.
out2=$(HOME="$psc_home" PATH="$psc_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$psc_tools" UV_LIST_FILE="$psc_list" \
      UV_BIN_DIR="$psc_bin" UV_LOG="$psc_log" GRAPHIFY_MCP_HOLDERS=2 \
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "skip-track 2nd: rc 0" grep -q '^RC=0$' <<<"$out2"
assert "skip-track 2nd: counter reads 2 consecutive" grep -q 'SKIPPED 2 consecutive' <<<"$out2"
assert "skip-track 2nd: counter file persisted at 2" test "$(cat "$psc_marker" 2>/dev/null)" = "2"

# A non-skip outcome (already at pin) resets the counter.
psc_list_at_pin="$tmpdir/gup-skiptrack-list-atpin"; printf 'graphifyy v%s\n' "$pinned_ver" > "$psc_list_at_pin"
out3=$(HOME="$psc_home" PATH="$psc_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$psc_tools" UV_LIST_FILE="$psc_list_at_pin" \
      UV_BIN_DIR="$psc_bin" UV_LOG="$psc_log" GRAPHIFY_MCP_HOLDERS=2 \
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "skip-track reset: rc 0" grep -q '^RC=0$' <<<"$out3"
assert "skip-track reset: counter file removed once the pin is no longer being skipped" \
  test ! -e "$psc_marker"

# The next SKIP after a reset starts back at 1, not 3.
out4=$(HOME="$psc_home" PATH="$psc_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$psc_tools" UV_LIST_FILE="$psc_list" \
      UV_BIN_DIR="$psc_bin" UV_LOG="$psc_log" GRAPHIFY_MCP_HOLDERS=2 \
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "skip-track after reset: counter restarts at 1" grep -q 'SKIPPED 1 consecutive' <<<"$out4"

# HIMMEL-1289: a BROKEN probe must read as UNAVAILABLE, never as "0 holders".
# Both critics caught that the first attempt at this was itself fail-open:
# `pgrep … | grep -c .` always emits a digit, so the numeric validator could
# never fire and a broken pgrep reported a clear machine — letting the guarded
# reinstall proceed on exactly the platform the guard protects.
echo "[test-graphify-bin] _graphify_mcp_holders: a broken probe is UNAVAILABLE, not 0"
probe_dir="$tmpdir/broken-probe"; mkdir -p "$probe_dir"
# A fake `uname` is REQUIRED, not decoration: _graphify_mcp_holders branches on
# uname -s, and on Git Bash (MINGW*) it takes the WINDOWS branch and never
# reaches pgrep at all. Without this the assertions below pass for the wrong
# reason — the Windows branch returning 1 because no pwsh is on the stripped
# PATH — which is a false green that proves nothing about the pgrep path.
printf '#!/bin/sh
echo Linux
' > "$probe_dir/uname"; chmod +x "$probe_dir/uname"
printf '#!/bin/sh
exit 2
' > "$probe_dir/pgrep"; chmod +x "$probe_dir/pgrep"   # usage error
# Single level, absolute interpreter, PATH set INSIDE the child, SCRIPT_DIR
# passed POSITIONALLY — the shape established for the pattern assert below, and
# the reason is the same for all three of these: the earlier nested form spliced
# SCRIPT_DIR into the inner `bash -c` string (a repo path containing a quote
# breaks it) and looked its inner `bash` up under the REWRITTEN PATH.
# shellcheck disable=SC2016
assert "broken pgrep (rc 2) -> probe returns nonzero, emits no count"   "$(command -v bash)" -c 'PATH="$1:/usr/bin:/bin"; export PATH; . "$2/graphify-bin.sh"; ! _graphify_mcp_holders >/dev/null 2>&1' _ "$probe_dir" "$SCRIPT_DIR"
# And the honest zero still works: a pgrep that RAN and matched nothing (rc 1)
# is a real 0, not a failure — otherwise the guard would block every update.
printf '#!/bin/sh
exit 1
' > "$probe_dir/pgrep"; chmod +x "$probe_dir/pgrep"
# shellcheck disable=SC2016
assert "pgrep rc 1 (ran, no matches) -> a real 0"   "$(command -v bash)" -c 'PATH="$1:/usr/bin:/bin"; export PATH; . "$2/graphify-bin.sh"; out=$(_graphify_mcp_holders) && [ "$out" = "0" ]' _ "$probe_dir" "$SCRIPT_DIR"
# A pgrep that MATCHED must count the lines it printed.
printf '#!/bin/sh
printf "111\n222\n333\n"
exit 0
' > "$probe_dir/pgrep"; chmod +x "$probe_dir/pgrep"
# shellcheck disable=SC2016
assert "pgrep rc 0 with 3 matches -> 3"   "$(command -v bash)" -c 'PATH="$1:/usr/bin:/bin"; export PATH; . "$2/graphify-bin.sh"; out=$(_graphify_mcp_holders) && [ "$out" = "3" ]' _ "$probe_dir" "$SCRIPT_DIR"

# Needle PARITY with the Windows branch (public-PR CR). Two needles are
# documented above _graphify_mcp_holders — the entrypoint name AND the uv tool
# dir — and Windows matches both, but the Unix branches searched only the
# entrypoint. A uv-installed holder whose argv names the tool dir without the
# literal entrypoint string was therefore counted CLEAR on Unix and HELD on
# Windows: the same machine, two answers. Asserted on the PATTERN the probe
# hands its matcher, which is where the omission lived.
echo "[test-graphify-bin] _graphify_mcp_holders: Unix branches search BOTH needles"
pat_log="$tmpdir/probe-pattern.txt"
cat > "$probe_dir/pgrep" <<'FAKEPGREP'
#!/bin/sh
printf '%s\n' "$2" > "$PGREP_PAT_LOG"
exit 1
FAKEPGREP
chmod +x "$probe_dir/pgrep"
# The fake pgrep SHADOWS any host one (probe_dir is first on PATH), so this
# case genuinely exercises the pgrep branch on every host — unlike the ps
# fallback below, which needs pgrep absent outright.
#
# Single level, absolute interpreter, PATH set INSIDE the child and SCRIPT_DIR
# passed POSITIONALLY — the same shape as the two ps-fallback asserts below
# (CodeRabbit round). The earlier nested form interpolated SCRIPT_DIR into the
# inner `bash -c` string, so a repo path containing a quote would have broken
# the command; and its inner `bash` was looked up under the REWRITTEN PATH,
# which is the 127 trap this suite hit twice already. PGREP_PAT_LOG rides in as
# a prefix on the pinned interpreter, so the fake pgrep still inherits it.
# shellcheck disable=SC2016
PGREP_PAT_LOG="$pat_log" "$(command -v bash)" -c 'PATH="$1:/usr/bin:/bin"; export PATH; . "$2/graphify-bin.sh"; _graphify_mcp_holders' _ "$probe_dir" "$SCRIPT_DIR" >/dev/null 2>&1 || true
assert "pgrep pattern carries the entrypoint needle" grep -q 'graphify-mcp' "$pat_log"
assert "pgrep pattern carries the uv tool-dir needle too" grep -q 'uv\[' "$pat_log"

# Same parity on the `ps` FALLBACK — which needs pgrep to be genuinely absent,
# not merely missing from the fixture dir (CodeRabbit round). The first draft
# used PATH="$probe_dir:/usr/bin:/bin", which still exposes the HOST's pgrep:
# _graphify_mcp_holders would then take the pgrep branch, run the real pgrep
# against the real process table, and never reach the fake ps at all. It passed
# here only because Git Bash ships no pgrep — on a Linux CI runner, which has
# one, these assertions would have gone red. A test whose branch depends on the
# host is not testing the branch it names.
#
# So: an ISOLATED PATH containing only fakes plus a thin exec-wrapper for the
# one real tool the fallback needs (grep). Wrapper, not a copy — an MSYS binary
# copied out of /usr/bin loses its DLL neighbours and will not load.
iso_dir="$tmpdir/iso-nopgrep"; mkdir -p "$iso_dir"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v grep)" > "$iso_dir/grep"
printf '#!/bin/sh\necho Linux\n' > "$iso_dir/uname"
chmod +x "$iso_dir/grep" "$iso_dir/uname"
# shellcheck disable=SC2016
gfy_pypi="$(bash -c '. "$1/graphify-bin.sh"; _graphify_pypi_name' _ "$SCRIPT_DIR")"
cat > "$iso_dir/ps" <<FAKEPS
#!/bin/sh
printf '%s\n' "/home/u/.local/share/uv/tools/$gfy_pypi/bin/python -m server"
FAKEPS
chmod +x "$iso_dir/ps"
# The interpreter is pinned ABSOLUTELY and PATH is set INSIDE the child — the
# same trap this suite's sibling hit: `PATH=… bash -c` makes the parent look up
# `bash` under the new PATH, so an isolated dir with no bash yields 127 and the
# assertion never runs the code it claims to.
# shellcheck disable=SC2016
assert "ps fallback counts a tool-dir-only holder (was missed pre-fix)" \
  "$(command -v bash)" -c 'PATH="$1"; export PATH; out=$(. "$2/graphify-bin.sh"; _graphify_mcp_holders) && [ "$out" = "1" ]' _ "$iso_dir" "$SCRIPT_DIR"
# shellcheck disable=SC2016
assert "the isolated fixture really has no pgrep (guards the guard)" \
  bash -c '! PATH="$1" command -v pgrep >/dev/null 2>&1' _ "$iso_dir"

# A CONFIGURED uv tool dir must be covered too (codex-adv round). `uv tool dir`
# honours UV_TOOL_DIR, and this file already derives real paths from
# _graphify_uv_tool_dir elsewhere, so a custom root is a supported shape — but
# the needle was the hardcoded DEFAULT layout, so a holder under /custom/root
# matched nothing and the probe reported CLEAR on a held venv.
echo "[test-graphify-bin] _graphify_mcp_holders: a CUSTOM uv tool dir is covered"
custom_root="$tmpdir/custom-uv-root"
cat > "$iso_dir/uv" <<UVFAKE
#!/bin/sh
[ "\$1" = "tool" ] && [ "\$2" = "dir" ] && { printf '%s\n' "$custom_root"; exit 0; }
exit 1
UVFAKE
chmod +x "$iso_dir/uv"
cat > "$iso_dir/ps" <<FAKEPS2
#!/bin/sh
printf '%s\n' "$custom_root/$gfy_pypi/bin/python -m server"
FAKEPS2
chmod +x "$iso_dir/ps"
# Same isolated PATH + absolute interpreter as above.
# shellcheck disable=SC2016
assert "ps fallback counts a holder under a CUSTOM uv tool dir" \
  "$(command -v bash)" -c 'PATH="$1"; export PATH; out=$(. "$2/graphify-bin.sh"; _graphify_mcp_holders) && [ "$out" = "1" ]' _ "$iso_dir" "$SCRIPT_DIR"
rm -f "$iso_dir/ps" "$iso_dir/uv"

# The probe asks for `ps -ww` first so a long tool-dir path is not truncated out
# of the command line, then falls back to plain `ps`. Both fake `ps` stubs above
# ignore their arguments, so they exercise the -ww branch and say NOTHING about
# the fallback — and the fallback is the one that matters on Git Bash, whose
# MSYS `ps` rejects -ww outright. Without this case a regression that dropped the
# fallback would leave every such host unable to probe at all, with a green
# suite. So: a stub that FAILS on -ww and succeeds without it.
cat > "$iso_dir/ps" <<FAKEPS3
#!/bin/sh
case "\$1" in -ww) echo "ps: unknown option -- ww" >&2; exit 1 ;; esac
printf '%s\n' "/home/u/.local/share/uv/tools/$gfy_pypi/bin/python -m server"
FAKEPS3
chmod +x "$iso_dir/ps"
# shellcheck disable=SC2016
assert "ps fallback survives a ps that rejects -ww (the Git Bash shape)" \
  "$(command -v bash)" -c 'PATH="$1"; export PATH; out=$(. "$2/graphify-bin.sh"; _graphify_mcp_holders) && [ "$out" = "1" ]' _ "$iso_dir" "$SCRIPT_DIR"
rm -f "$iso_dir/ps"

# The path->pattern helper must survive regex metacharacters in a real path: an
# unbalanced paren is an ERE SYNTAX error, which would make the probe rc 2 —
# "unavailable" — on a machine that is merely oddly named.
echo "[test-graphify-bin] _graphify_pat_from_path escapes metacharacters"
# shellcheck disable=SC2016
assert "a path with parens and a dot still matches itself" \
  bash -c 'p="/opt/tools (v2)/.hidden/graphifyy"; pat=$(. "$1/graphify-bin.sh"; _graphify_pat_from_path "$p"); printf "%s\n" "$p/bin/python" | grep -qE -- "$pat"' _ "$SCRIPT_DIR"
# shellcheck disable=SC2016
assert "the dot is escaped, not a wildcard" \
  bash -c 'pat=$(. "$1/graphify-bin.sh"; _graphify_pat_from_path "/a/.local/graphifyy"); ! printf "%s\n" "/a/Xlocal/graphifyy" | grep -qE -- "$pat"' _ "$SCRIPT_DIR"

# Windows branch: an apostrophe in the resolved tool dir must not break the
# -Command string (codex-adv round). pat_dir carries a RESOLVED path now, so
# `C:\Users\O'Brien\…` — an ordinary profile — would close the PowerShell
# single-quoted string early. That is not a soft failure: the probe returns
# "unavailable", and the CALLER treats "cannot probe" as "proceed", so the
# reinstall would run against a held venv on the very platform this guard was
# written for. Asserted on the generated -Command, captured from a fake pwsh.
echo "[test-graphify-bin] Windows probe survives an apostrophe in the tool dir"
win_dir="$tmpdir/win-probe"; mkdir -p "$win_dir"
apos_root="/c/Users/O'Brien/AppData/uv/tools"
printf '#!/bin/sh\necho MINGW64_NT-10.0\n' > "$win_dir/uname"; chmod +x "$win_dir/uname"
cat > "$win_dir/uv" <<UVAPOS
#!/bin/sh
[ "\$1" = "tool" ] && [ "\$2" = "dir" ] && { printf '%s\n' "$apos_root"; exit 0; }
exit 1
UVAPOS
chmod +x "$win_dir/uv"
# Fake pwsh: log the -Command it was handed, then answer "1 holder".
cat > "$win_dir/pwsh" <<'PWSHFAKE'
#!/bin/sh
for a in "$@"; do last="$a"; done
printf '%s\n' "$last" > "$PS_CMD_LOG"
printf '1\n'
PWSHFAKE
chmod +x "$win_dir/pwsh"
ps_log="$tmpdir/ps-command.txt"
# SCRIPT_DIR goes in as a POSITIONAL arg, not interpolated into the command
# string (CodeRabbit round): a repo path containing a quote would otherwise
# break the command the same way the apostrophe this very test is about breaks
# the PowerShell one.
# shellcheck disable=SC2016
apos_out="$(PATH="$win_dir:/usr/bin:/bin" PS_CMD_LOG="$ps_log" bash -c '. "$1/graphify-bin.sh"; _graphify_mcp_holders' _ "$SCRIPT_DIR" 2>/dev/null)"
assert "apostrophe path -> probe returns a COUNT, not unavailable" test "$apos_out" = "1"
# The probe must not count ITSELF: the needles appear in this pwsh process's
# own CommandLine, so without the exclusion a machine with zero real holders
# reported 1 and the update was skipped forever.
assert "generated -Command excludes the probe's own PID" grep -q 'ProcessId -ne' "$ps_log"
# The generated command must have balanced single quotes; a lone apostrophe
# from the path is exactly what unbalances it.
apos_sq="'"
# shellcheck disable=SC2016
assert "generated -Command has balanced single quotes" \
  bash -c 'n=$(tr -cd "$2" < "$1" | wc -c); [ $((n % 2)) -eq 0 ]' _ "$ps_log" "$apos_sq"
assert "the apostrophe was doubled for PowerShell" grep -q "O''Brien" "$ps_log"

echo "[test-graphify-bin] graphify_update: install 'succeeds' but the binary does not run -> HARD failure"
gb_home="$tmpdir/gup-broken"; mkdir -p "$gb_home"
gb_tools="$tmpdir/gup-broken-tools"; mkdir -p "$gb_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$gb_tools/graphifyy/uv-receipt.toml"
gb_list="$tmpdir/gup-broken-list"; printf 'graphifyy v0.0.1\n' > "$gb_list"
gb_bin="$tmpdir/gup-broken-bin"; mkdir -p "$gb_bin"
gb_log="$tmpdir/gup-broken-log"; : > "$gb_log"
# Model the REAL sequence, not just the end state: graphify works BEFORE the
# reinstall and throws AFTER it. A stub that is broken from the start is a
# different scenario entirely — graphify_source cannot identify the install, so
# the update path is never even reached. The stub flips once the uv log shows
# an install ran, which is exactly what uv does when it removes the old entry
# points and then fails to replace the locked directory.
cat > "$gb_bin/graphify" <<'EOF'
#!/usr/bin/env bash
if grep -q "tool install" "${UV_LOG:-/nonexistent}" 2>/dev/null; then
  echo "runpy traceback: No module named graphify.__main__" >&2
  exit 1
fi
echo x
EOF
chmod +x "$gb_bin/graphify"
# UV_BIN_DIR must NOT be gb_bin: the uv stub drops a WORKING graphify shim into
# UV_BIN_DIR on a successful install, which would overwrite the flipping stub
# above and make the binary look healthy — testing the opposite of the point.
# Keep it off PATH so `command -v graphify` keeps resolving the flipping stub.
gb_uvbin="$tmpdir/gup-broken-uvbin"; mkdir -p "$gb_uvbin"
out=$(HOME="$gb_home" PATH="$gb_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gb_tools" UV_LIST_FILE="$gb_list" \
      UV_BIN_DIR="$gb_uvbin" UV_LOG="$gb_log" GRAPHIFY_MCP_HOLDERS=0 \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "broken-after-install: rc 1 (presence is not proof it runs)" grep -q '^RC=1$' <<<"$out"
assert "empty recorded extras: upgrade defaults to the managed [kimi] extra" \
  grep -qE 'tool install --force --with mcp graphifyy\[kimi\]==[0-9]' "$gb_log"
assert "broken-after-install: names it BROKEN" grep -q 'BROKEN' <<<"$out"
assert "broken-after-install: gives the repair command" grep -q "uv tool install --force --with mcp 'graphifyy" <<<"$out"
# Assert BOTH quotes, like the held scenario above (CodeRabbit round). Matching
# only the opening quote + package prefix leaves this site able to lose its
# CLOSING quote and still pass — an asymmetry between two assertions that exist
# for one reason.
#
# Deliberately NOT the held scenario's `\[all\]` pattern: this fixture's
# uv-receipt records no extras, so the managed default now supplies `[kimi]`.
# The two scenarios pin quoting for both the operator-preserved [all] shape and
# the managed empty-extras -> [kimi] shape.
assert "broken-after-install: the repair command single-quotes the whole spec" \
  grep -qE "uv tool install --force --with mcp 'graphifyy\[kimi\]==[0-9][^']*'" <<<"$out"

# The fourth corner of the state matrix (public-PR CR): install FAILED but the
# binary SURVIVED. The other three are covered above and below; without this one
# the two arms of the post-failure branch are never told apart, and the arm that
# reports a survivable state could rot into the alarming one unnoticed. The
# distinction is the whole point of that branch — "failed" alone was the blanket
# answer it was written to replace.
echo "[test-graphify-bin] graphify_update: install fails but the binary still RUNS -> WARNING, not BROKEN"
gs_home="$tmpdir/gup-survive"; mkdir -p "$gs_home"
gs_tools="$tmpdir/gup-survive-tools"; mkdir -p "$gs_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$gs_tools/graphifyy/uv-receipt.toml"
gs_list="$tmpdir/gup-survive-list"; printf 'graphifyy v0.0.1\n' > "$gs_list"
gs_bin="$tmpdir/gup-survive-bin"; mkdir -p "$gs_bin"
# Unlike the broken-after-install stub above, this one NEVER flips: the install
# fails and leaves the working entry point untouched.
printf '#!/usr/bin/env bash\necho x\n' > "$gs_bin/graphify"; chmod +x "$gs_bin/graphify"
gs_log="$tmpdir/gup-survive-log"; : > "$gs_log"
gs_uvbin="$tmpdir/gup-survive-uvbin"; mkdir -p "$gs_uvbin"
out=$(HOME="$gs_home" PATH="$gs_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gs_tools" UV_LIST_FILE="$gs_list" \
      UV_BIN_DIR="$gs_uvbin" UV_LOG="$gs_log" GRAPHIFY_MCP_HOLDERS=0 STUB_UV_INSTALL_RC=1 \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "install-failed-binary-survives: rc 1 (the pin did not advance)" grep -q '^RC=1$' <<<"$out"
assert "install-failed-binary-survives: says the install still RUNS" grep -q 'still RUNS' <<<"$out"
assert "install-failed-binary-survives: says the pin was not advanced" grep -q 'pin not advanced' <<<"$out"
gs_broken=$(grep -c 'BROKEN' <<<"$out" || true)   # counted, not negated in a subshell — no nested `bash -c`
assert "install-failed-binary-survives: does NOT cry BROKEN" [ "$gs_broken" = 0 ]
assert "install-failed-binary-survives: the install was actually attempted" grep -qE 'tool install --force --with mcp graphifyy' "$gs_log"

# --- HIMMEL-1293: an UNPROBEABLE host must fail CLOSED ----------------------
# The probe returns rc 1 for "this platform offers no probe" — NOT for "the
# machine is clear". Until HIMMEL-1293 the caller conflated the two and ran
# `uv tool install --force` anyway, which is the destructive step: uv removes
# the old entry points before replacing the tool dir, so an unprobeable host
# with a live holder went from working graphify to broken graphify. The
# post-install verify only reports that state; it cannot undo it.
echo "[test-graphify-bin] graphify_update: unprobeable platform -> SKIP (fail closed), no install attempted"
gp_home="$tmpdir/gup-probe"; mkdir -p "$gp_home"
gp_tools="$tmpdir/gup-probe-tools"; mkdir -p "$gp_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$gp_tools/graphifyy/uv-receipt.toml"
gp_list="$tmpdir/gup-probe-list"; printf 'graphifyy v0.0.1\n' > "$gp_list"
gp_bin="$tmpdir/gup-probe-bin"; mkdir -p "$gp_bin"
printf '#!/usr/bin/env bash\necho x\n' > "$gp_bin/graphify"; chmod +x "$gp_bin/graphify"
gp_log="$tmpdir/gup-probe-log"; : > "$gp_log"
out=$(HOME="$gp_home" PATH="$gp_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gp_tools" UV_LIST_FILE="$gp_list" \
      UV_BIN_DIR="$gp_bin" UV_LOG="$gp_log" GRAPHIFY_MCP_HOLDERS=unavailable \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
# rc 0 for the same reason as the holders>0 skip: a deliberate, healthy decline
# on a still-working install, not a failure worth himmel-update's generic warning.
assert "unprobeable: rc 0 (a deliberate skip is not a failure)" grep -q '^RC=0$' <<<"$out"
assert "unprobeable: says it cannot probe" grep -q 'cannot probe for graphify-mcp holders' <<<"$out"
assert "unprobeable: announces a SKIP" grep -q 'SKIP: cannot probe' <<<"$out"
assert "unprobeable: states graphify KEEPS WORKING" grep -q 'KEEPS WORKING' <<<"$out"
assert "unprobeable: says the pin did NOT advance" grep -q 'has NOT advanced' <<<"$out"
# THE POINT: no uv install ran, so the entry points were never removed.
# shellcheck disable=SC2016
assert "unprobeable: NO uv install attempted (this is the whole fix)" \
  bash -c '! grep -q "tool install" "$1"' _ "$gp_log"
# Both remedies must be printed — fail-closed is only acceptable because the
# operator is told exactly how to get unstuck. A silent decline would recreate
# the permanent-staleness failure of the HIMMEL-1274 Windows self-match bug.
assert "unprobeable: gives the manual install command" \
  grep -qE "uv tool install --force --with mcp 'graphifyy\[kimi\]==[0-9][^']*'" <<<"$out"
assert "unprobeable: names the GRAPHIFY_UNPROBED_OK override" grep -q 'GRAPHIFY_UNPROBED_OK=1' <<<"$out"

echo "[test-graphify-bin] graphify_update: unprobeable + GRAPHIFY_UNPROBED_OK=1 -> proceeds anyway"
gpo_home="$tmpdir/gup-probe-ok"; mkdir -p "$gpo_home"
gpo_tools="$tmpdir/gup-probe-ok-tools"; mkdir -p "$gpo_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$gpo_tools/graphifyy/uv-receipt.toml"
gpo_list="$tmpdir/gup-probe-ok-list"; printf 'graphifyy v0.0.1\n' > "$gpo_list"
gpo_bin="$tmpdir/gup-probe-ok-bin"; mkdir -p "$gpo_bin"
printf '#!/usr/bin/env bash\necho x\n' > "$gpo_bin/graphify"; chmod +x "$gpo_bin/graphify"
gpo_log="$tmpdir/gup-probe-ok-log"; : > "$gpo_log"
out=$(HOME="$gpo_home" PATH="$gpo_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gpo_tools" UV_LIST_FILE="$gpo_list" \
      UV_BIN_DIR="$gpo_bin" UV_LOG="$gpo_log" GRAPHIFY_MCP_HOLDERS=unavailable GRAPHIFY_UNPROBED_OK=1 \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "unprobeable+override: rc 0" grep -q '^RC=0$' <<<"$out"
assert "unprobeable+override: performs the install" grep -qE 'tool install --force --with mcp graphifyy' "$gpo_log"
# The override must not be silent — the operator opted into a real risk.
assert "unprobeable+override: still warns the install can leave graphify BROKEN" \
  grep -q 'can leave graphify BROKEN' <<<"$out"

# A live holder still wins over the override: the override says "I cannot
# probe", not "ignore a probe that came back positive". Anything else would let
# one env var disable the guard outright.
echo "[test-graphify-bin] graphify_update: holders>0 + GRAPHIFY_UNPROBED_OK=1 -> still SKIPs"
gpv_home="$tmpdir/gup-probe-veto"; mkdir -p "$gpv_home"
gpv_tools="$tmpdir/gup-probe-veto-tools"; mkdir -p "$gpv_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$gpv_tools/graphifyy/uv-receipt.toml"
gpv_list="$tmpdir/gup-probe-veto-list"; printf 'graphifyy v0.0.1\n' > "$gpv_list"
gpv_bin="$tmpdir/gup-probe-veto-bin"; mkdir -p "$gpv_bin"
printf '#!/usr/bin/env bash\necho x\n' > "$gpv_bin/graphify"; chmod +x "$gpv_bin/graphify"
gpv_log="$tmpdir/gup-probe-veto-log"; : > "$gpv_log"
out=$(HOME="$gpv_home" PATH="$gpv_bin:$stub_dir/bin:$base_path" UV_TOOL_DIR="$gpv_tools" UV_LIST_FILE="$gpv_list" \
      UV_BIN_DIR="$gpv_bin" UV_LOG="$gpv_log" GRAPHIFY_MCP_HOLDERS=2 GRAPHIFY_UNPROBED_OK=1 \
      bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "holders+override: still reports the holder SKIP" grep -q 'SKIP: 2 graphify-mcp process' <<<"$out"
# shellcheck disable=SC2016
assert "holders+override: NO uv install attempted" \
  bash -c '! grep -q "tool install" "$1"' _ "$gpv_log"

echo "[test-graphify-bin] graphify_update: uv graphifyy AHEAD of pin -> left as-is, no install (CR codex-1: never downgrade/clobber)"
gua_home="$tmpdir/gup-ahead"; mkdir -p "$gua_home"
gua_tools="$tmpdir/gup-ahead-tools"; mkdir -p "$gua_tools/graphifyy"
printf 'requirements = [{ name = "graphifyy" }]\n' > "$gua_tools/graphifyy/uv-receipt.toml"
# Fake venv matching the ahead version so the skill refresh (which keys on the
# venv-reported version, never the pin) has a source to copy from.
make_fake_graphify_venv "$gua_tools" "99.0.0" > /dev/null
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
      bash -c 'unset CLAUDE_CONFIG_DIR; . "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_update; echo "RC=$?"' 2>&1)
assert "update ahead-of-pin: rc 0" grep -q '^RC=0$' <<<"$out"
assert "update ahead-of-pin: reports not behind / leaving as-is" grep -qiE 'not behind|leaving as-is' <<<"$out"
# shellcheck disable=SC2016
assert "update ahead-of-pin: no install call (never downgrade)" bash -c '! grep -q "tool install" "$1"' _ "$gua_log"
# HIMMEL-1750 (CR codex-adv r2): the ahead-of-pin branch must still refresh a
# STALE skill to the INSTALLED version (package left untouched) — this is the
# motivating package-ahead/skill-stale case.
assert "update ahead-of-pin: stale skill refreshed to installed version" grep -qi 'skill refreshed' <<<"$out"

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
HOME="$probe_home" PATH="$probe_dir:$utils_bin:$base_path" \
  bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_mcp_import_ok' || rc=$?
assert "probe rc 0 when the shebang python imports mcp" test "$rc" -eq 0
printf '#!%s/py-fail python\n' "$probe_dir" > "$probe_dir/graphify-mcp"
rc=0
HOME="$probe_home" PATH="$probe_dir:$utils_bin:$base_path" \
  bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; _graphify_mcp_import_ok' || rc=$?
assert "probe rc 1 when the shebang python cannot import mcp" test "$rc" -eq 1
rm -f "$probe_dir/graphify-mcp"
rc=0
HOME="$probe_home" PATH="$probe_dir:$utils_bin:$base_path" \
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
se_stub="$(mktemp -d -t graphify-bin-sete.XXXXXX)"
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

# ─── graphify_price_hooks (HIMMEL-2480) ──────────────────────────────────────
# node checker: reads a fixture's .claude/settings.json + .codex/hooks.json
# and prints KEY=VALUE facts, so the shell assertions below stay plain grep/
# test comparisons instead of embedding JSON logic in bash.
price_checker="$tmpdir/price-check.js"
cat > "$price_checker" <<'PRICECHECK'
const fs = require('fs');
const root = process.argv[2];

function readJSON(p) {
  let raw;
  try { raw = fs.readFileSync(p, 'utf8'); } catch (e) { return { exists: false }; }
  try { return { exists: true, ok: true, data: JSON.parse(raw) }; }
  catch (e) { return { exists: true, ok: false }; }
}

const isGuard = (e) => {
  const s = JSON.stringify(e);
  return /graphify/i.test(s) && /hook-guard|hook-check/.test(s);
};

const c = readJSON(root + '/.claude/settings.json');
console.log('CLAUDE_EXISTS=' + c.exists);
if (c.exists) {
  console.log('CLAUDE_PARSE_OK=' + c.ok);
  if (c.ok) {
    const pre = (c.data.hooks && c.data.hooks.PreToolUse) || [];
    const guards = pre.filter(isGuard);
    console.log('CLAUDE_TOTAL=' + pre.length);
    console.log('CLAUDE_GUARD_COUNT=' + guards.length);
    console.log('CLAUDE_GUARD_INDEX=' + pre.findIndex(isGuard));
    console.log('CLAUDE_HAS_HOOKGUARD_READ=' + JSON.stringify(pre).includes('hook-guard read'));
    console.log('CLAUDE_HAS_FRESHNESS_ADVISORY=' + JSON.stringify(pre).includes('graphify-freshness-advisory.sh'));
    console.log('CLAUDE_FIRST_MATCHER=' + (pre[0] && pre[0].matcher));
    console.log('CLAUDE_LAST_MATCHER=' + (pre[pre.length - 1] && pre[pre.length - 1].matcher));
    console.log('CLAUDE_ALL_MATCHERS=' + JSON.stringify(pre.map((e) => e.matcher)));
    console.log('CLAUDE_ALL_HOOK_COMMANDS=' + JSON.stringify(pre.flatMap((e) => (e.hooks || []).map((h) => h.command))));
    if (guards.length === 1) {
      console.log('CLAUDE_GUARD_MATCHER=' + guards[0].matcher);
      console.log('CLAUDE_GUARD_TIMEOUT=' + guards[0].hooks[0].timeout);
      console.log('CLAUDE_GUARD_COMMAND=' + guards[0].hooks[0].command);
    }
  }
}

const x = readJSON(root + '/.codex/hooks.json');
console.log('CODEX_EXISTS=' + x.exists);
if (x.exists) {
  console.log('CODEX_PARSE_OK=' + x.ok);
  if (x.ok) {
    const pre = (x.data.hooks && x.data.hooks.PreToolUse) || [];
    console.log('CODEX_TOTAL=' + pre.length);
    console.log('CODEX_GRAPHIFY_COUNT=' + pre.filter((e) => /graphify/i.test(JSON.stringify(e))).length);
  }
}
PRICECHECK

price_field() { # $1 = checker output, $2 = KEY -> prints VALUE (last match)
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1
}

# price_verdict — separator-agnostic match on a "graphify hook pricing -- "
# line. node's path.join emits BACKSLASH-separated paths on native Windows
# node even when the root argv arrived forward-slash (MSYS auto-converts the
# argv to a real Windows path first), while $pos_fixture etc. stay forward-
# slash on the bash side -- so a plain full-path grep never matches on
# Windows. Match the verdict text plus the path SUFFIX, accepting either
# separator, instead of the unstable full path.
price_verdict() { # $1=output text, $2=already-regex-escaped verdict, $3=path suffix (forward-slash form)
  local ppat
  ppat="$(printf '%s' "$3" | sed 's/\./\\./g; s#/#[/\\\\]#g')"
  grep -qE "graphify hook pricing -- ${2}: .*${ppat}\$" <<< "$1"
}

expected_priced_command='command -v graphify >/dev/null 2>&1 && exec graphify hook-guard search; exit 0'

echo "[test-graphify-bin] graphify_price_hooks: POSITIVE CONTROL — reprices the stock upstream shape"
# Shaped exactly like a fresh `graphify install --platform claude` writes it
# (install.py::_claude_pretooluse_hooks): matchers Bash|Grep and Read|Glob, no
# timeout, absolute exe path -- flanked by unrelated entries that must survive
# in place. Plus the matching stock Codex hook-check entry (HIMMEL-2480).
pos_fixture="$tmpdir/price-positive"
mkdir -p "$pos_fixture/.claude" "$pos_fixture/.codex"
cat > "$pos_fixture/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/block-edit-on-main.sh" }
        ]
      },
      {
        "matcher": "Bash|Grep",
        "hooks": [
          { "type": "command", "command": "C:/Users/x/.local/bin/graphify.EXE hook-guard search" }
        ]
      },
      {
        "matcher": "Read|Glob",
        "hooks": [
          { "type": "command", "command": "C:/Users/x/.local/bin/graphify.EXE hook-guard read" }
        ]
      },
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/auto-arm-on-cap.sh" }
        ]
      }
    ]
  }
}
EOF
cat > "$pos_fixture/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": ".codex/run-hook.sh --sandbox block-read-secrets.sh" }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "graphify.EXE hook-check" }
        ]
      }
    ]
  }
}
EOF

out=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$pos_fixture" 2>&1)
assert "positive control: rc 0" grep -q '^RC=0$' <<<"$out"
assert "positive control: settings reported repriced" price_verdict "$out" "repriced" ".claude/settings.json"
assert "positive control: codex reported repriced" price_verdict "$out" "repriced" ".codex/hooks.json"

check1="$(node "$price_checker" "$pos_fixture")"
assert "positive control: settings still valid JSON" test "$(price_field "$check1" CLAUDE_PARSE_OK)" = "true"
assert "positive control: codex still valid JSON" test "$(price_field "$check1" CODEX_PARSE_OK)" = "true"
assert "positive control: exactly ONE graphify entry in settings" test "$(price_field "$check1" CLAUDE_GUARD_COUNT)" = "1"
assert "positive control: priced matcher is Grep|Glob" test "$(price_field "$check1" CLAUDE_GUARD_MATCHER)" = "Grep|Glob"
assert "positive control: priced timeout is 3" test "$(price_field "$check1" CLAUDE_GUARD_TIMEOUT)" = "3"
assert "positive control: priced command matches exactly" \
  test "$(price_field "$check1" CLAUDE_GUARD_COMMAND)" = "$expected_priced_command"
assert "positive control: no entry mentions hook-guard read" test "$(price_field "$check1" CLAUDE_HAS_HOOKGUARD_READ)" = "false"
assert "positive control: unrelated entries survive in order (first)" test "$(price_field "$check1" CLAUDE_FIRST_MATCHER)" = "Edit|Write"
assert "positive control: unrelated entries survive in order (last)" test "$(price_field "$check1" CLAUDE_LAST_MATCHER)" = ".*"
assert "positive control: priced entry sits at the first graphify entry's index" test "$(price_field "$check1" CLAUDE_GUARD_INDEX)" = "1"
assert "positive control: total PreToolUse entries is unrelated(2) + priced(1)" test "$(price_field "$check1" CLAUDE_TOTAL)" = "3"
assert "positive control: codex has ZERO graphify entries" test "$(price_field "$check1" CODEX_GRAPHIFY_COUNT)" = "0"
assert "positive control: codex's unrelated entry survives" test "$(price_field "$check1" CODEX_TOTAL)" = "1"

# Finding 2 (atomic write): the write-then-rename path leaves the target file
# intact and valid JSON (asserted above via CLAUDE_PARSE_OK/CODEX_PARSE_OK)
# and cleans up its temp file on the normal, successful path -- no stray
# "settings.json.<pid>.tmp" left behind. A real atomicity test would need to
# inject a crash/interrupt mid-write, which is out of scope here (no fixture
# harness for that exists in this suite); this is the best plain-behavior
# check available without one.
# shellcheck disable=SC2016
assert "positive control: no leftover atomic-write temp file in .claude" \
  bash -c 'out=$(ls "$1" 2>/dev/null | grep "\.tmp$"); [ -z "$out" ]' _ "$pos_fixture/.claude"
# shellcheck disable=SC2016
assert "positive control: no leftover atomic-write temp file in .codex" \
  bash -c 'out=$(ls "$1" 2>/dev/null | grep "\.tmp$"); [ -z "$out" ]' _ "$pos_fixture/.codex"

echo "[test-graphify-bin] graphify_price_hooks: idempotence — a second run is a byte-identical no-op"
settings_before="$(cat "$pos_fixture/.claude/settings.json")"
codex_before="$(cat "$pos_fixture/.codex/hooks.json")"
out2=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$pos_fixture" 2>&1)
settings_after="$(cat "$pos_fixture/.claude/settings.json")"
codex_after="$(cat "$pos_fixture/.codex/hooks.json")"
assert "idempotent re-run: rc 0" grep -q '^RC=0$' <<<"$out2"
assert "idempotent re-run: settings reported already priced" price_verdict "$out2" "already priced" ".claude/settings.json"
assert "idempotent re-run: settings byte-identical" test "$settings_before" = "$settings_after"
assert "idempotent re-run: codex byte-identical" test "$codex_before" = "$codex_after"

echo "[test-graphify-bin] graphify_price_hooks: never eats a non-guard graphify hook (himmel's own chain member)"
survive_fixture="$tmpdir/price-survive"
mkdir -p "$survive_fixture/.claude"
cat > "$survive_fixture/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "SessionStart",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/graphify-freshness-advisory.sh" }
        ]
      },
      {
        "matcher": "Bash|Grep",
        "hooks": [
          { "type": "command", "command": "graphify.EXE hook-guard search" }
        ]
      },
      {
        "matcher": "Read|Glob",
        "hooks": [
          { "type": "command", "command": "graphify.EXE hook-guard read" }
        ]
      }
    ]
  }
}
EOF
out=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$survive_fixture" 2>&1)
assert "survive: rc 0" grep -q '^RC=0$' <<<"$out"
check2="$(node "$price_checker" "$survive_fixture")"
assert "survive: graphify-freshness-advisory.sh entry survives" test "$(price_field "$check2" CLAUDE_HAS_FRESHNESS_ADVISORY)" = "true"
assert "survive: exactly one guard entry left (the priced one)" test "$(price_field "$check2" CLAUDE_GUARD_COUNT)" = "1"
assert "survive: total is advisory(1) + priced(1)" test "$(price_field "$check2" CLAUDE_TOTAL)" = "2"

echo "[test-graphify-bin] graphify_price_hooks: HOOK-level filtering — a mixed entry keeps its unrelated hook, a pure-guard entry is dropped entirely (HIMMEL-2480 CR finding 1)"
# One matcher can legitimately bundle SEVERAL hooks. "Grep" bundles a graphify
# guard with an unrelated hook (must survive); "Read|Glob" holds ONLY a guard
# hook (its entry must be removed entirely once emptied, not left as {}).
write_mixed_hook_fixture() { # $1 = target dir
  local dir="$1"
  mkdir -p "$dir/.claude"
  cat > "$dir/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Grep",
        "hooks": [
          { "type": "command", "command": "graphify.EXE hook-guard search" },
          { "type": "command", "command": "bash scripts/hooks/my-other-hook.sh" }
        ]
      },
      {
        "matcher": "Read|Glob",
        "hooks": [
          { "type": "command", "command": "graphify.EXE hook-guard read" }
        ]
      },
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/auto-arm-on-cap.sh" }
        ]
      }
    ]
  }
}
EOF
}

mixed_fixture="$tmpdir/price-mixed-hooks"
write_mixed_hook_fixture "$mixed_fixture"
mixed_out=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$mixed_fixture" 2>&1)
assert "mixed: rc 0" grep -q '^RC=0$' <<<"$mixed_out"
check_mixed="$(node "$price_checker" "$mixed_fixture")"
assert "mixed: settings still valid JSON" test "$(price_field "$check_mixed" CLAUDE_PARSE_OK)" = "true"
assert "mixed: total is priced(1) + surviving-mixed(1) + unrelated(1) = 3" test "$(price_field "$check_mixed" CLAUDE_TOTAL)" = "3"
assert "mixed: exactly one guard entry left (the priced one)" test "$(price_field "$check_mixed" CLAUDE_GUARD_COUNT)" = "1"
# shellcheck disable=SC2016
assert "mixed: the Read|Glob pure-guard entry was removed entirely" \
  bash -c '! grep -q "Read|Glob" <<<"$1"' _ "$(price_field "$check_mixed" CLAUDE_ALL_MATCHERS)"
assert "mixed: the Grep entry (with its surviving unrelated hook) is still present" \
  grep -q '"Grep"' <<<"$(price_field "$check_mixed" CLAUDE_ALL_MATCHERS)"
assert "mixed: the unrelated hook survived" grep -qF "my-other-hook.sh" <<<"$(price_field "$check_mixed" CLAUDE_ALL_HOOK_COMMANDS)"
assert "mixed: 'hook-guard' now appears in exactly ONE surviving hook command (the priced one)" \
  test "$(grep -o 'hook-guard' <<<"$(price_field "$check_mixed" CLAUDE_ALL_HOOK_COMMANDS)" | wc -l)" -eq 1

# Mutation check (per task instructions, run by hand and reported separately):
# the OLD entry-level filter (`pre.filter(e => !isGuard(e))`, isGuard on the
# WHOLE entry) deletes the entire mixed "Grep" entry -- including
# my-other-hook.sh -- because the entry AS A WHOLE matches /graphify/ +
# /hook-guard/. The "unrelated hook survived" assertion above is the one that
# fails under that old behavior.

echo "[test-graphify-bin] graphify_price_hooks: fail-safe — no settings/hooks files at all"
absent_fixture="$tmpdir/price-absent"; mkdir -p "$absent_fixture"
out=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$absent_fixture" 2>&1)
assert "absent: rc 0" grep -q '^RC=0$' <<<"$out"
assert "absent: settings reported absent" price_verdict "$out" 'absent \(nothing to price\)' ".claude/settings.json"
assert "absent: codex reported absent" price_verdict "$out" 'absent \(nothing to price\)' ".codex/hooks.json"

echo "[test-graphify-bin] graphify_price_hooks: fail-safe — unparseable settings.json is left byte-identical"
bad_fixture="$tmpdir/price-badjson"; mkdir -p "$bad_fixture/.claude"
printf '{ this is not json' > "$bad_fixture/.claude/settings.json"
bad_before="$(cat "$bad_fixture/.claude/settings.json")"
out=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$bad_fixture" 2>&1)
bad_after="$(cat "$bad_fixture/.claude/settings.json")"
assert "unparseable: rc 0" grep -q '^RC=0$' <<<"$out"
assert "unparseable: reported UNPARSEABLE" price_verdict "$out" "UNPARSEABLE, left untouched" ".claude/settings.json"
assert "unparseable: file left byte-identical" test "$bad_before" = "$bad_after"

echo "[test-graphify-bin] graphify_price_hooks: dispatcher (executed, not sourced)"
disp_fixture="$tmpdir/price-dispatch"; mkdir -p "$disp_fixture"
disp_out=$(bash "$SCRIPT_DIR/graphify-bin.sh" price-hooks "$disp_fixture" 2>&1); disp_rc=$?
assert "dispatcher: rc 0" test "$disp_rc" -eq 0
assert "dispatcher: reaches graphify_price_hooks (reports absent)" grep -q "absent (nothing to price)" <<<"$disp_out"

bogus_out=$(bash "$SCRIPT_DIR/graphify-bin.sh" bogus-verb 2>&1); bogus_rc=$?
assert "dispatcher: bogus verb exits 2" test "$bogus_rc" -eq 2
assert "dispatcher: bogus verb prints usage" grep -qi '^Usage:' <<<"$bogus_out"
assert "dispatcher: usage mentions price-hooks" grep -q 'price-hooks' <<<"$bogus_out"

echo "[test-graphify-bin] graphify_price_hooks: consumer wiring regression guard (HIMMEL-2480)"
assert "setup.sh calls graphify_price_hooks" grep -q 'graphify_price_hooks' "$repo_root/scripts/setup.sh"
assert "adopt.sh calls graphify_price_hooks" grep -q 'graphify_price_hooks' "$repo_root/scripts/adopt.sh"
assert "himmel-update.sh calls graphify_price_hooks" grep -q 'graphify_price_hooks' "$repo_root/scripts/himmel-update.sh"
assert "setup.ps1 references price-hooks" grep -q 'price-hooks' "$repo_root/scripts/setup.ps1"
assert "adopt.ps1 references price-hooks" grep -q 'price-hooks' "$repo_root/scripts/adopt.ps1"

echo "[test-graphify-bin] graphify_price_hooks: operator hints are copy-pasteable (HIMMEL-2480 CR finding 3)"
# ' -- then ' in a pasted shell line ends option parsing for `graphify install`
# and turns "then re-price the hooks: ..." into junk positional argv -- the
# re-price command never runs. None of the four skill-refresh hints (and the
# CLAUDE.md-budget hint) may contain that sequence any more.
# shellcheck disable=SC2016
assert "graphify-bin.sh: no ' -- then ' copy-paste trap in any hint" \
  bash -c '! grep -q -- " -- then " "$1"' _ "$SCRIPT_DIR/graphify-bin.sh"
assert "graphify-bin.sh: still has 4 'Run by hand'/'run by hand' install hints" \
  test "$(grep -ic 'run by hand: graphify install --platform claude' "$SCRIPT_DIR/graphify-bin.sh")" = "4"
assert "graphify-bin.sh: each install hint is followed by its own re-price echo" \
  test "$(grep -c 'Then re-price the hooks: bash scripts/lib/graphify-bin.sh price-hooks' "$SCRIPT_DIR/graphify-bin.sh")" = "4"
# shellcheck disable=SC2016
assert "check-claude-md-budget.sh: no ' -- then ' copy-paste trap" \
  bash -c '! grep -q -- " -- then " "$1"' _ "$repo_root/scripts/ci/check-claude-md-budget.sh"

# ─── graphify_price_hooks: node vs python engine parity (HIMMEL-2480 follow-up) ──
# Shared fixture writer -- same stock-upstream shape as pos_fixture above
# (unrelated entry, hook-guard search, hook-guard read, unrelated entry; plus
# a .codex/hooks.json unrelated entry + hook-check), but the first unrelated
# entry's command carries a LITERAL non-ASCII character (an em-dash). That is
# the regression guard for the python engine's ensure_ascii divergence:
# json.dumps defaults to ensure_ascii=True and \uXXXX-escapes non-ASCII, while
# the node engine's JSON.stringify writes it raw -- without ensure_ascii=False
# on the python side these two fixture trees would NOT come out byte-identical.
write_price_identity_fixture() { # $1 = target dir
  local dir="$1"
  mkdir -p "$dir/.claude" "$dir/.codex"
  cat > "$dir/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": "echo — keep me" }
        ]
      },
      {
        "matcher": "Bash|Grep",
        "hooks": [
          { "type": "command", "command": "C:/Users/x/.local/bin/graphify.EXE hook-guard search" }
        ]
      },
      {
        "matcher": "Read|Glob",
        "hooks": [
          { "type": "command", "command": "C:/Users/x/.local/bin/graphify.EXE hook-guard read" }
        ]
      },
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/auto-arm-on-cap.sh" }
        ]
      }
    ]
  }
}
EOF
  cat > "$dir/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": ".codex/run-hook.sh --sandbox block-read-secrets.sh" }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "graphify.EXE hook-check" }
        ]
      }
    ]
  }
}
EOF
}

# Forcing the python engine hermetically: scrub node off PATH AND neutralize
# resolve_node's own probes via its documented test seams (resolve-node.sh
# header) -- otherwise a real nvm-windows / other-well-known-location install
# on the test machine would still resolve node and this would silently run
# the node engine twice, proving nothing (the exact failure mode a positive
# control below guards against). $novm/$nofnm are nonexistent dirs, not "".
novm="$tmpdir/no-such-nvm-root"
nofnm="$tmpdir/no-such-fnm-root"
# HIMMEL-2530: prepend a tool floor that admits the python engines but NOT node,
# so scrubbing node cannot also take bash/coreutils out with /usr/bin.
nonode_bin="$tmpdir/nonode-bin"
build_hermetic_bin "$nonode_bin" python3 python
node_scrubbed_path="$nonode_bin:$(scrub_path "$PATH" node)"
force_python_env=(PATH="$node_scrubbed_path" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$novm" FNM_DIR="$nofnm")

echo "[test-graphify-bin] graphify_price_hooks: POSITIVE CONTROL -- node is genuinely unresolvable under the forced-python env"
# shellcheck disable=SC2016
node_probe_out=$(env "${force_python_env[@]}" bash -c '. "'"$SCRIPT_DIR"'/resolve-node.sh"; if resolve_node >/dev/null 2>&1; then echo "NODE_RESOLVED=yes"; else echo "NODE_RESOLVED=no"; fi; command -v node >/dev/null 2>&1 && echo "NODE_ON_PATH=yes" || echo "NODE_ON_PATH=no"')
assert "positive control: resolve_node fails under the forced-python env" grep -q '^NODE_RESOLVED=no$' <<<"$node_probe_out"
assert "positive control: command -v node finds nothing under the forced-python env" grep -q '^NODE_ON_PATH=no$' <<<"$node_probe_out"

echo "[test-graphify-bin] graphify_price_hooks: node vs python engines are byte-identical, non-ASCII included (HIMMEL-2480 follow-up)"
id_node_fixture="$tmpdir/price-identity-node"
id_py_fixture="$tmpdir/price-identity-python"
write_price_identity_fixture "$id_node_fixture"
write_price_identity_fixture "$id_py_fixture"

id_node_out=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$id_node_fixture" 2>&1)
assert "identity: node engine run rc 0" grep -q '^RC=0$' <<<"$id_node_out"
assert "identity: node engine reported repriced (settings)" price_verdict "$id_node_out" "repriced" ".claude/settings.json"
assert "identity: node engine reported repriced (codex)" price_verdict "$id_node_out" "repriced" ".codex/hooks.json"

# shellcheck disable=SC2016
id_py_out=$(env "${force_python_env[@]}" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$id_py_fixture" 2>&1)
assert "identity: python engine run rc 0" grep -q '^RC=0$' <<<"$id_py_out"
# shellcheck disable=SC2016
assert "identity: python engine run did not fall through to the no-engine WARNING" bash -c '! grep -q "WARNING" <<<"$1"' _ "$id_py_out"
assert "identity: python engine reported repriced (settings)" price_verdict "$id_py_out" "repriced" ".claude/settings.json"
assert "identity: python engine reported repriced (codex)" price_verdict "$id_py_out" "repriced" ".codex/hooks.json"

assert "identity: settings.json byte-identical between node and python engines" cmp -s "$id_node_fixture/.claude/settings.json" "$id_py_fixture/.claude/settings.json"
assert "identity: hooks.json byte-identical between node and python engines" cmp -s "$id_node_fixture/.codex/hooks.json" "$id_py_fixture/.codex/hooks.json"
assert "identity: node engine kept the em-dash raw (unescaped)" grep -qF "—" "$id_node_fixture/.claude/settings.json"
assert "identity: python engine kept the em-dash raw too (TASK 1 regression guard: ensure_ascii=False)" grep -qF "—" "$id_py_fixture/.claude/settings.json"
# shellcheck disable=SC2016
assert "identity: python engine did NOT \\u-escape the em-dash" bash -c '! grep -qF "\u2014" "$1"' _ "$id_py_fixture/.claude/settings.json"

echo "[test-graphify-bin] graphify_price_hooks: forced-python-engine idempotence (HIMMEL-2480 follow-up)"
idem_py_fixture="$tmpdir/price-python-idempotence"
write_price_identity_fixture "$idem_py_fixture"

# shellcheck disable=SC2016
idem_first_out=$(env "${force_python_env[@]}" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$idem_py_fixture" 2>&1)
assert "python idempotence: first run rc 0" grep -q '^RC=0$' <<<"$idem_first_out"
assert "python idempotence: first run reports repriced" price_verdict "$idem_first_out" "repriced" ".claude/settings.json"

cp "$idem_py_fixture/.claude/settings.json" "$tmpdir/idem-py-settings-mid.json"
cp "$idem_py_fixture/.codex/hooks.json" "$tmpdir/idem-py-codex-mid.json"

# shellcheck disable=SC2016
idem_second_out=$(env "${force_python_env[@]}" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$idem_py_fixture" 2>&1)
assert "python idempotence: second run rc 0" grep -q '^RC=0$' <<<"$idem_second_out"
assert "python idempotence: second run reports already priced" price_verdict "$idem_second_out" "already priced" ".claude/settings.json"
assert "python idempotence: settings.json byte-identical after the second run" cmp -s "$tmpdir/idem-py-settings-mid.json" "$idem_py_fixture/.claude/settings.json"
assert "python idempotence: hooks.json byte-identical after the second run" cmp -s "$tmpdir/idem-py-codex-mid.json" "$idem_py_fixture/.codex/hooks.json"

echo "[test-graphify-bin] graphify_price_hooks: HOOK-level filtering under the forced-python engine (HIMMEL-2480 CR finding 1)"
mixed_py_fixture="$tmpdir/price-mixed-hooks-python"
write_mixed_hook_fixture "$mixed_py_fixture"
# shellcheck disable=SC2016
mixed_py_out=$(env "${force_python_env[@]}" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$mixed_py_fixture" 2>&1)
assert "mixed (python): rc 0" grep -q '^RC=0$' <<<"$mixed_py_out"
check_mixed_py="$(node "$price_checker" "$mixed_py_fixture")"
assert "mixed (python): total is priced(1) + surviving-mixed(1) + unrelated(1) = 3" test "$(price_field "$check_mixed_py" CLAUDE_TOTAL)" = "3"
# shellcheck disable=SC2016
assert "mixed (python): the Read|Glob pure-guard entry was removed entirely" \
  bash -c '! grep -q "Read|Glob" <<<"$1"' _ "$(price_field "$check_mixed_py" CLAUDE_ALL_MATCHERS)"
assert "mixed (python): the unrelated hook survived" grep -qF "my-other-hook.sh" <<<"$(price_field "$check_mixed_py" CLAUDE_ALL_HOOK_COMMANDS)"
assert "mixed (python): output is byte-identical to the node engine's" cmp -s "$mixed_fixture/.claude/settings.json" "$mixed_py_fixture/.claude/settings.json"

echo "[test-graphify-bin] graphify_price_hooks: neither engine resolvable -> loud WARNING, rc 0, files untouched (HIMMEL-2480 follow-up)"
no_engine_fixture="$tmpdir/price-no-engine"
write_price_identity_fixture "$no_engine_fixture"
cp "$no_engine_fixture/.claude/settings.json" "$tmpdir/no-engine-settings-before.json"
cp "$no_engine_fixture/.codex/hooks.json" "$tmpdir/no-engine-codex-before.json"

# HIMMEL-2530: tool floor only -- no engine is admitted here, which is the point
# of the case, but bash and the coreutils must still resolve.
noengine_bin="$tmpdir/noengine-bin"
build_hermetic_bin "$noengine_bin"
no_engine_path="$noengine_bin:$(scrub_path "$PATH" node python3 python)"
no_engine_out=$(PATH="$no_engine_path" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$novm" FNM_DIR="$nofnm" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$no_engine_fixture" 2>&1)
assert "no engine: rc 0" grep -q '^RC=0$' <<<"$no_engine_out"
assert "no engine: emits a loud WARNING" grep -q 'WARNING' <<<"$no_engine_out"
# shellcheck disable=SC2016
assert "no engine: does NOT downgrade to the old soft NOTE" bash -c '! grep -q "NOTE:" <<<"$1"' _ "$no_engine_out"
assert "no engine: message names price-hooks" grep -q 'price-hooks' <<<"$no_engine_out"
assert "no engine: settings.json left byte-identical" cmp -s "$tmpdir/no-engine-settings-before.json" "$no_engine_fixture/.claude/settings.json"
assert "no engine: hooks.json left byte-identical" cmp -s "$tmpdir/no-engine-codex-before.json" "$no_engine_fixture/.codex/hooks.json"

# ─── graphify_price_hooks: Finding B (guard detection matches command only) ──
echo "[test-graphify-bin] graphify_price_hooks: Finding B — a hook whose OTHER fields mention graphify/hook-guard, but whose command does not, must SURVIVE (HIMMEL-2480 follow-up)"
# Old behavior (JSON.stringify(hook) / json.dumps(hook)) matched the WHOLE
# hook object, so an unrelated hook's metadata field mentioning "graphify"
# and "hook-guard" was enough to get it deleted even though its actual
# `command` has nothing to do with graphify. Mutation-checked by hand (see
# verification report): reverting isGuard/is_guard to the old whole-object
# match makes this fixture's unrelated hook disappear.
write_unrelated_fields_fixture() { # $1 = target dir
  local dir="$1"
  mkdir -p "$dir/.claude"
  cat > "$dir/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash scripts/hooks/unrelated-safety-net.sh",
            "description": "graphify hook-guard style safety net, but NOT graphify itself"
          }
        ]
      }
    ]
  }
}
EOF
}

unrelated_fixture="$tmpdir/price-unrelated-fields"
write_unrelated_fields_fixture "$unrelated_fixture"
out=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$unrelated_fixture" 2>&1)
assert "unrelated fields: rc 0" grep -q '^RC=0$' <<<"$out"
assert "unrelated fields: settings reported repriced (the priced entry gets appended)" price_verdict "$out" "repriced" ".claude/settings.json"
assert "unrelated fields: the unrelated hook's command survives verbatim" grep -qF "unrelated-safety-net.sh" "$unrelated_fixture/.claude/settings.json"
assert "unrelated fields: the unrelated hook's own entry+description survive untouched" grep -qF "graphify hook-guard style safety net" "$unrelated_fixture/.claude/settings.json"
check_unrelated="$(node "$price_checker" "$unrelated_fixture")"
assert "unrelated fields: total is unrelated(1) + priced(1) = 2" test "$(price_field "$check_unrelated" CLAUDE_TOTAL)" = "2"

unrelated_py_fixture="$tmpdir/price-unrelated-fields-python"
write_unrelated_fields_fixture "$unrelated_py_fixture"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
unrelated_py_out=$(env "${force_python_env[@]}" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$unrelated_py_fixture" 2>&1)
assert "unrelated fields (python): rc 0" grep -q '^RC=0$' <<<"$unrelated_py_out"
assert "unrelated fields (python): settings reported repriced" price_verdict "$unrelated_py_out" "repriced" ".claude/settings.json"
assert "unrelated fields (python): the unrelated hook's command survives verbatim" grep -qF "unrelated-safety-net.sh" "$unrelated_py_fixture/.claude/settings.json"
assert "unrelated fields (python): output is byte-identical to the node engine's" cmp -s "$unrelated_fixture/.claude/settings.json" "$unrelated_py_fixture/.claude/settings.json"

echo "[test-graphify-bin] graphify_price_hooks: Finding B regression guard — command-field matching still detects all three positive shapes plus survives the freshness advisory (HIMMEL-2480 follow-up)"
write_guard_shapes_fixture() { # $1 = target dir
  local dir="$1"
  mkdir -p "$dir/.claude"
  cat > "$dir/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "SessionStart",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/graphify-freshness-advisory.sh" }
        ]
      },
      {
        "matcher": "Bash|Grep",
        "hooks": [
          { "type": "command", "command": "C:/Users/x/.local/bin/graphify.EXE hook-guard search" }
        ]
      },
      {
        "matcher": "Read",
        "hooks": [
          { "type": "command", "command": "\"C:/Users/x/.local/bin/graphify.EXE\" hook-guard read" }
        ]
      },
      {
        "matcher": "Glob",
        "hooks": [
          { "type": "command", "command": "graphify hook-guard read" }
        ]
      }
    ]
  }
}
EOF
}

shapes_fixture="$tmpdir/price-guard-shapes"
write_guard_shapes_fixture "$shapes_fixture"
shapes_out=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$shapes_fixture" 2>&1)
assert "shapes: rc 0" grep -q '^RC=0$' <<<"$shapes_out"
assert "shapes: settings reported repriced" price_verdict "$shapes_out" "repriced" ".claude/settings.json"
check_shapes="$(node "$price_checker" "$shapes_fixture")"
assert "shapes: graphify-freshness-advisory.sh survives" test "$(price_field "$check_shapes" CLAUDE_HAS_FRESHNESS_ADVISORY)" = "true"
assert "shapes: absolute-path, quoted and bare exe all detected -> collapsed into ONE priced entry" test "$(price_field "$check_shapes" CLAUDE_GUARD_COUNT)" = "1"
assert "shapes: total is freshness(1) + priced(1) = 2" test "$(price_field "$check_shapes" CLAUDE_TOTAL)" = "2"

shapes_py_fixture="$tmpdir/price-guard-shapes-python"
write_guard_shapes_fixture "$shapes_py_fixture"
# shellcheck disable=SC2016
# Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
shapes_py_out=$(env "${force_python_env[@]}" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$shapes_py_fixture" 2>&1)
assert "shapes (python): rc 0" grep -q '^RC=0$' <<<"$shapes_py_out"
assert "shapes (python): settings reported repriced" price_verdict "$shapes_py_out" "repriced" ".claude/settings.json"
assert "shapes (python): output is byte-identical to the node engine's" cmp -s "$shapes_fixture/.claude/settings.json" "$shapes_py_fixture/.claude/settings.json"

# ─── graphify_price_hooks: Finding A (path-translation silent no-op) ─────────
# Only meaningful on MSYS/Cygwin, where MSYS_NO_PATHCONV/MSYS2_ARG_CONV_EXCL
# disable the implicit POSIX->Windows argv rewrite that the fix now performs
# EXPLICITLY via cygpath -- gate on BOTH `cygpath` being present (the
# translator the fix uses) and `uname -s` reporting an MSYS/MINGW/Cygwin
# kernel (the only platform where that env var pair has this effect at all;
# on Linux/macOS the vars are meaningless and $root is already native). A
# machine with neither (Linux CI, some containers) skips cleanly rather than
# failing.
case "$(uname -s 2>/dev/null || echo)" in
  MINGW*|MSYS*|CYGWIN*) _pconv_platform_ok=1 ;;
  *) _pconv_platform_ok=0 ;;
esac

if [ "$_pconv_platform_ok" = 1 ] && command -v cygpath >/dev/null 2>&1; then
  echo "[test-graphify-bin] graphify_price_hooks: Finding A — MSYS_NO_PATHCONV / MSYS2_ARG_CONV_EXCL no longer produces a silent no-op (HIMMEL-2480 follow-up)"
  pconv_node_fixture="$tmpdir/price-pathconv-node"
  pconv_py_fixture="$tmpdir/price-pathconv-python"
  write_price_identity_fixture "$pconv_node_fixture"
  write_price_identity_fixture "$pconv_py_fixture"

  pconv_node_out=$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$pconv_node_fixture" 2>&1)
  assert "pathconv (node): rc 0" grep -q '^RC=0$' <<<"$pconv_node_out"
  assert "pathconv (node): settings reported repriced (not silently absent)" price_verdict "$pconv_node_out" "repriced" ".claude/settings.json"
  assert "pathconv (node): the priced matcher is actually IN THE FILE" grep -qF '"Grep|Glob"' "$pconv_node_fixture/.claude/settings.json"
  assert "pathconv (node): the priced command is actually IN THE FILE" grep -qF "$expected_priced_command" "$pconv_node_fixture/.claude/settings.json"

  # shellcheck disable=SC2016
  pconv_py_out=$(env "${force_python_env[@]}" MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$pconv_py_fixture" 2>&1)
  assert "pathconv (python): rc 0" grep -q '^RC=0$' <<<"$pconv_py_out"
  assert "pathconv (python): settings reported repriced (not silently absent)" price_verdict "$pconv_py_out" "repriced" ".claude/settings.json"
  assert "pathconv (python): the priced matcher is actually IN THE FILE" grep -qF '"Grep|Glob"' "$pconv_py_fixture/.claude/settings.json"
  assert "pathconv (python): the priced command is actually IN THE FILE" grep -qF "$expected_priced_command" "$pconv_py_fixture/.claude/settings.json"

  echo "[test-graphify-bin] graphify_price_hooks: Finding A class guard — bash sees a file the engine reports absent -> loud WARNING, never a quiet success (HIMMEL-2480 follow-up)"
  # Honest construction: stub `cygpath -w` to always return a bogus,
  # nonexistent native path, so the engine is handed a root that resolves to
  # nothing on disk while bash's OWN [-f] check (against the REAL,
  # untranslated root) still sees the real file. That is exactly the
  # disagreement the guard exists to catch -- without needing an actually
  # broken MSYS shell to reproduce it. Prepended ahead of the real PATH so
  # `command -v cygpath` picks up the stub first.
  stub_cygpath_dir="$tmpdir/stub-cygpath"
  mkdir -p "$stub_cygpath_dir"
  cat > "$stub_cygpath_dir/cygpath" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "-w" ]; then
  printf '%s\n' 'C:\nonexistent-pathconv-guard-fixture'
  exit 0
fi
exit 1
STUB
  chmod +x "$stub_cygpath_dir/cygpath"

  guard_fixture="$tmpdir/price-disagreement-guard"
  mkdir -p "$guard_fixture/.claude"
  cat > "$guard_fixture/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Grep",
        "hooks": [
          { "type": "command", "command": "C:/Users/x/.local/bin/graphify.EXE hook-guard search" }
        ]
      }
    ]
  }
}
EOF
  guard_before="$(cat "$guard_fixture/.claude/settings.json")"
  guard_out=$(PATH="$stub_cygpath_dir:$PATH" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$guard_fixture" 2>&1)
  guard_after="$(cat "$guard_fixture/.claude/settings.json")"
  assert "disagreement guard: rc 0 (WARN-not-fail contract preserved)" grep -q '^RC=0$' <<<"$guard_out"
  assert "disagreement guard: engine (fed the bogus stub path) reported settings absent" price_verdict "$guard_out" 'absent \(nothing to price\)' ".claude/settings.json"
  assert "disagreement guard: emits a loud WARNING naming settings.json" grep -qE 'WARNING:.*\.claude/settings\.json' <<<"$guard_out"
  assert "disagreement guard: WARNING names MSYS_NO_PATHCONV as the usual cause" grep -q 'MSYS_NO_PATHCONV' <<<"$guard_out"
  # shellcheck disable=SC2016
  # Single quotes intentional -- $1 expands inside the spawned bash -c subshell.
  assert "disagreement guard: does NOT downgrade to a quiet success (still says absent, not repriced)" \
    bash -c '! grep -q "graphify hook pricing -- repriced: .*settings" <<<"$1"' _ "$guard_out"
  assert "disagreement guard: file was left byte-identical (never actually reached)" test "$guard_before" = "$guard_after"
else
  echo "[test-graphify-bin] SKIP: Finding A pathconv + disagreement-guard tests need an MSYS/MINGW/Cygwin uname AND cygpath on PATH -- neither present, or not applicable, on this platform."
fi

# ─── graphify_price_hooks: Finding 1 (anchored guard matcher) ────────────────
echo "[test-graphify-bin] graphify_price_hooks: Finding 1 -- anchored guard matcher, all 23 shapes, both engines (HIMMEL-2480 CR round 3, third and final narrowing)"
# Table-driven regression guard that ends the narrowing sequence (whole-entry
# -> whole-hook-object -> command field -> anchored-token, this round). Each
# row gets its OWN single-hook fixture rather than packing them all into one
# entry: case 5 IS our own priced command, so after repricing its substrings
# would also appear (again) inside the newly-inserted priced entry, making a
# shared-fixture post-hoc substring grep ambiguous about which occurrence is
# which. One command per fixture keeps the assertion unambiguous instead:
#   - a POSITIVE command is the fixture's ONLY hook, so recognizing it as a
#     guard empties that entry, which then gets replaced in place -> exactly
#     ONE surviving PreToolUse entry (the priced one).
#   - a NEGATIVE command's entry is never touched -- but graphify_price_hooks
#     unconditionally ensures the priced entry exists (see the "unrelated
#     fields" case above), so it still gets APPENDED -> exactly TWO entries,
#     with the original hook's command surviving verbatim.
run_finding1_case() {  # $1=slug $2=hook-json-fragment $3=guard|survive $4=engine("" | python)
  local slug="$1" hook_json="$2" expect="$3" engine="${4:-}"
  local dir="$tmpdir/f1-$slug"
  mkdir -p "$dir/.claude"
  cat > "$dir/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Finding1Case",
        "hooks": [ $hook_json ]
      }
    ]
  }
}
EOF
  local out
  if [ -n "$engine" ]; then
    # shellcheck disable=SC2016
    out=$(env "${force_python_env[@]}" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$dir" 2>&1)
  else
    out=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$dir" 2>&1)
  fi
  assert "finding1 $slug: rc 0" grep -q '^RC=0$' <<<"$out"
  local check; check="$(node "$price_checker" "$dir")"
  if [ "$expect" = "guard" ]; then
    assert "finding1 $slug: recognized as a guard -- lone entry collapsed into just the priced one" \
      test "$(price_field "$check" CLAUDE_TOTAL)" = "1"
    assert "finding1 $slug: the survivor is exactly the standard priced entry" \
      test "$(price_field "$check" CLAUDE_GUARD_COMMAND)" = "$expected_priced_command"
  else
    assert "finding1 $slug: NOT recognized as a guard -- original entry survives alongside the appended priced entry" \
      test "$(price_field "$check" CLAUDE_TOTAL)" = "2"
  fi
}

# The 5 MUST-match shapes from the ticket.
run_finding1_case pos1-bare '{ "type": "command", "command": "graphify hook-guard search" }' guard
run_finding1_case pos2-abspath '{ "type": "command", "command": "C:/Users/x/.local/bin/graphify.EXE hook-guard search" }' guard
run_finding1_case pos3-quoted '{ "type": "command", "command": "\"C:/Program Files/x/graphify.exe\" hook-guard read" }' guard
run_finding1_case pos4-hookcheck '{ "type": "command", "command": "graphify.EXE hook-check" }' guard
run_finding1_case pos5-ourown '{ "type": "command", "command": "command -v graphify >/dev/null 2>&1 && exec graphify hook-guard search; exit 0" }' guard
# The 3 MUST-NOT-match shapes.
run_finding1_case neg1-advisory '{ "type": "command", "command": "bash scripts/hooks/graphify-freshness-advisory.sh" }' survive
run_finding1_case neg2-shim '{ "type": "command", "command": "bash scripts/hooks/my-graphify-hook-guard-shim.sh" }' survive
run_finding1_case neg3-nocommand '{ "type": "command" }' survive
# HIMMEL-2489: the trailing boundary must also reject a LONGER hyphenated
# subcommand. Under the shipped \b these two NEGATIVES matched ("-" is a
# non-word char, so \b sits right after "hook-guard"), and an operator hook
# for an unrelated subcommand was silently deleted on reprice. The bare
# end-of-string positive pins the other side of (?![\w-]).
run_finding1_case neg4-wrapper '{ "type": "command", "command": "graphify hook-guard-wrapper search" }' survive
run_finding1_case neg5-checkfoo '{ "type": "command", "command": "graphify hook-check-foo" }' survive
run_finding1_case pos6-eos '{ "type": "command", "command": "graphify hook-guard" }' guard
# #2125 CR rounds 1-2: `hook-guard<non-ascii>` is ONE shell argument naming a
# different subcommand, so it must SURVIVE -- and must do so in BOTH engines.
# It did neither before: with [\w-] node matched (JS \w is ASCII-only) while
# python did not (its \w is Unicode-aware), so one engine deleted a hook the
# other kept. \u00e9 is JSON-escaped so this file stays pure ASCII.
run_finding1_case neg6-nonascii '{ "type": "command", "command": "graphify hook-guard\u00e9" }' survive
# #2125 CR round 2: a command ending in a newline is a real shape, and the
# newline IS a token boundary -- so this one stays a guard, in both engines.
run_finding1_case pos8-trailing-nl '{ "type": "command", "command": "graphify hook-guard\n" }' guard
# #2125 CR round 2: the row that pins the boundary SPELLING. A tidy-up to the
# shorter (?!\S) or (?=\s|$) passes every other row and breaks HERE: both read
# \s, and JS \s matches U+FEFF while Python's does not (the mirror cases are
# U+0085 and U+001C, where Python matches and JS does not). Under either
# spelling node deletes this hook and python keeps it. U+FEFF is not a shell
# separator, so the correct answer is SURVIVE in both.
run_finding1_case neg7-bom '{ "type": "command", "command": "graphify hook-guard\ufeff" }' survive
# HIMMEL-2489 CR round 2 follow-up: the LEADING boundary has the identical
# \s cross-engine split as the trailing one above, just mirrored -- JS \s
# matches U+FEFF where Python's does not, and Python's \s matches U+0085
# (NEL) and U+001C (FS) where JS's does not. A leading \s would let one
# engine treat a stray BOM/NEL/FS glued onto the front of an unrelated
# command as a token boundary and start a match there, wrongly recognizing
# it as a guard in one engine and not the other. None of the three are real
# shell token separators, so the correct answer is SURVIVE in both engines
# for all three.
run_finding1_case neg8-lead-bom '{ "type": "command", "command": "\ufeffgraphify hook-guard search" }' survive
run_finding1_case neg9-lead-nel '{ "type": "command", "command": "\u0085graphify hook-guard search" }' survive
run_finding1_case neg10-lead-fs '{ "type": "command", "command": "\u001cgraphify hook-guard search" }' survive
# [codex-1] CR round 3 (HIMMEL-2489 follow-up): the SEPARATOR between the
# executable and the subcommand had the identical \s cross-engine split --
# JS \s matches U+FEFF, Python's matches U+0085 (NEL) / U+001C (FS) -- so
# `graphify<U+FEFF>hook-guard` (ONE unrelated argv token, not two words) was
# a guard in node and not python. None of the three are real shell token
# separators, so the correct answer is SURVIVE in both engines for all
# three, same as the leading-boundary rows above.
run_finding1_case neg11-mid-bom '{ "type": "command", "command": "graphify\ufeffhook-guard search" }' survive
run_finding1_case neg12-mid-nel '{ "type": "command", "command": "graphify\u0085hook-guard search" }' survive
run_finding1_case neg13-mid-fs '{ "type": "command", "command": "graphify\u001chook-guard search" }' survive
# HIMMEL-2489 panel finding (post-merge follow-up): a raw CARRIAGE RETURN is
# NOT a shell token separator -- unlike the BOM/NEL/FS rows above, a bare CR
# is not even whitespace the shell treats as an argument separator; the shell
# passes `<CR>graphify`, `graphify<CR>hook-guard` and `hook-guard<CR>-wrapper`
# each as ONE argv token. Treating \r as a boundary character (as all three
# classes did before this fix) is the "too-wide" direction the comments above
# explicitly warn against -- it would wrongly recognize these as guards (and
# on the trailing side, wrongly reject a legitimate longer subcommand). The
# correct answer is SURVIVE in both engines for all three.
run_finding1_case neg14-lead-cr '{ "type": "command", "command": "\rgraphify hook-guard search" }' survive
run_finding1_case neg15-mid-cr '{ "type": "command", "command": "graphify\rhook-guard search" }' survive
run_finding1_case neg16-trail-cr '{ "type": "command", "command": "graphify hook-guard\r-wrapper" }' survive

echo "[test-graphify-bin] graphify_price_hooks: Finding 1 -- same 23 shapes under the forced-python engine"
run_finding1_case py-pos1-bare '{ "type": "command", "command": "graphify hook-guard search" }' guard python
run_finding1_case py-pos2-abspath '{ "type": "command", "command": "C:/Users/x/.local/bin/graphify.EXE hook-guard search" }' guard python
run_finding1_case py-pos3-quoted '{ "type": "command", "command": "\"C:/Program Files/x/graphify.exe\" hook-guard read" }' guard python
run_finding1_case py-pos4-hookcheck '{ "type": "command", "command": "graphify.EXE hook-check" }' guard python
run_finding1_case py-pos5-ourown '{ "type": "command", "command": "command -v graphify >/dev/null 2>&1 && exec graphify hook-guard search; exit 0" }' guard python
run_finding1_case py-neg1-advisory '{ "type": "command", "command": "bash scripts/hooks/graphify-freshness-advisory.sh" }' survive python
run_finding1_case py-neg2-shim '{ "type": "command", "command": "bash scripts/hooks/my-graphify-hook-guard-shim.sh" }' survive python
run_finding1_case py-neg3-nocommand '{ "type": "command" }' survive python
# HIMMEL-2489: the trailing boundary must also reject a LONGER hyphenated
# subcommand. Under the shipped \b these two NEGATIVES matched ("-" is a
# non-word char, so \b sits right after "hook-guard"), and an operator hook
# for an unrelated subcommand was silently deleted on reprice. The bare
# end-of-string positive pins the other side of (?![\w-]).
run_finding1_case py-neg4-wrapper '{ "type": "command", "command": "graphify hook-guard-wrapper search" }' survive python
run_finding1_case py-neg5-checkfoo '{ "type": "command", "command": "graphify hook-check-foo" }' survive python
run_finding1_case py-pos6-eos '{ "type": "command", "command": "graphify hook-guard" }' guard python
# #2125 CR rounds 1-2: `hook-guard<non-ascii>` is ONE shell argument naming a
# different subcommand, so it must SURVIVE -- and must do so in BOTH engines.
# It did neither before: with [\w-] node matched (JS \w is ASCII-only) while
# python did not (its \w is Unicode-aware), so one engine deleted a hook the
# other kept. \u00e9 is JSON-escaped so this file stays pure ASCII.
run_finding1_case py-neg6-nonascii '{ "type": "command", "command": "graphify hook-guard\u00e9" }' survive python
# #2125 CR round 2: a command ending in a newline is a real shape, and the
# newline IS a token boundary -- so this one stays a guard, in both engines.
run_finding1_case py-pos8-trailing-nl '{ "type": "command", "command": "graphify hook-guard\n" }' guard python
# #2125 CR round 2: the row that pins the boundary SPELLING. A tidy-up to the
# shorter (?!\S) or (?=\s|$) passes every other row and breaks HERE: both read
# \s, and JS \s matches U+FEFF while Python's does not (the mirror cases are
# U+0085 and U+001C, where Python matches and JS does not). Under either
# spelling node deletes this hook and python keeps it. U+FEFF is not a shell
# separator, so the correct answer is SURVIVE in both.
run_finding1_case py-neg7-bom '{ "type": "command", "command": "graphify hook-guard\ufeff" }' survive python
# HIMMEL-2489 CR round 2 follow-up: the LEADING boundary has the identical
# \s cross-engine split as the trailing one above, just mirrored -- JS \s
# matches U+FEFF where Python's does not, and Python's \s matches U+0085
# (NEL) and U+001C (FS) where JS's does not. A leading \s would let one
# engine treat a stray BOM/NEL/FS glued onto the front of an unrelated
# command as a token boundary and start a match there, wrongly recognizing
# it as a guard in one engine and not the other. None of the three are real
# shell token separators, so the correct answer is SURVIVE in both engines
# for all three.
run_finding1_case py-neg8-lead-bom '{ "type": "command", "command": "\ufeffgraphify hook-guard search" }' survive python
run_finding1_case py-neg9-lead-nel '{ "type": "command", "command": "\u0085graphify hook-guard search" }' survive python
run_finding1_case py-neg10-lead-fs '{ "type": "command", "command": "\u001cgraphify hook-guard search" }' survive python
# [codex-1] CR round 3 (HIMMEL-2489 follow-up): the SEPARATOR between the
# executable and the subcommand had the identical \s cross-engine split --
# JS \s matches U+FEFF, Python's matches U+0085 (NEL) / U+001C (FS) -- so
# `graphify<U+FEFF>hook-guard` (ONE unrelated argv token, not two words) was
# a guard in node and not python. None of the three are real shell token
# separators, so the correct answer is SURVIVE in both engines for all
# three, same as the leading-boundary rows above.
run_finding1_case py-neg11-mid-bom '{ "type": "command", "command": "graphify\ufeffhook-guard search" }' survive python
run_finding1_case py-neg12-mid-nel '{ "type": "command", "command": "graphify\u0085hook-guard search" }' survive python
run_finding1_case py-neg13-mid-fs '{ "type": "command", "command": "graphify\u001chook-guard search" }' survive python
# HIMMEL-2489 panel finding (post-merge follow-up): same CR rows as the node
# block above, run under the forced-python engine -- a raw CR is one argv
# token in the shell, not a separator, so all three must SURVIVE in python
# too.
run_finding1_case py-neg14-lead-cr '{ "type": "command", "command": "\rgraphify hook-guard search" }' survive python
run_finding1_case py-neg15-mid-cr '{ "type": "command", "command": "graphify\rhook-guard search" }' survive python
run_finding1_case py-neg16-trail-cr '{ "type": "command", "command": "graphify hook-guard\r-wrapper" }' survive python

# ─── graphify_price_hooks: Finding 2 (symlinked config survives repricing) ───
echo "[test-graphify-bin] graphify_price_hooks: Finding 2 -- atomic write follows a symlinked settings.json (HIMMEL-2480 CR round 3)"
# Probe symlink support by actually attempting one, not by platform-sniffing
# (same pattern as scripts/test-propagate-public.sh's C6 case): Windows
# needs Developer Mode or admin for a REAL symlink, and this repo's git-bash
# has been observed to make `ln -s` report rc=0 while silently falling back
# to a plain COPY (bash's own `[ -L ]` then correctly reports false) --
# `&& [ -L ... ]` catches that fallback and skips cleanly instead of
# "passing" against a file that was never actually a symlink.
f2_probe_dir="$tmpdir/f2-symlink-probe"; mkdir -p "$f2_probe_dir"
if ln -s "$f2_probe_dir" "$f2_probe_dir/probe-link" 2>/dev/null && [ -L "$f2_probe_dir/probe-link" ]; then
  rm -f "$f2_probe_dir/probe-link"

  run_finding2_case() {  # $1=slug $2=engine("" | python)
    local slug="$1" engine="${2:-}"
    local dir="$tmpdir/f2-$slug"
    mkdir -p "$dir/.claude" "$dir/f2-real-$slug"
    local real="$dir/f2-real-$slug/settings.json"
    cat > "$real" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/auto-arm-on-cap.sh" }
        ]
      }
    ]
  }
}
EOF
    ln -s "$real" "$dir/.claude/settings.json"
    local out
    if [ -n "$engine" ]; then
      # shellcheck disable=SC2016
      out=$(env "${force_python_env[@]}" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$dir" 2>&1)
    else
      out=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$dir" 2>&1)
    fi
    assert "symlink ($slug): rc 0" grep -q '^RC=0$' <<<"$out"
    assert "symlink ($slug): settings.json is STILL a symlink after repricing" test -L "$dir/.claude/settings.json"
    # shellcheck disable=SC2016
    # Single quotes intentional -- $1/$2 expand inside the spawned bash -c subshell.
    assert "symlink ($slug): the link target still resolves to the real file" \
      bash -c 'test "$(readlink "$1")" = "$2"' _ "$dir/.claude/settings.json" "$real"
    assert "symlink ($slug): the REAL file (link target) now carries the priced entry" \
      grep -qF "$expected_priced_command" "$real"
  }

  run_finding2_case node
  run_finding2_case python python
else
  echo "[test-graphify-bin] SKIP: Finding 2 symlink test needs real symlink support (\`ln -s\` creating an ACTUAL symlink, verified via [ -L ]) -- not available on this box (Windows without Developer Mode/admin, most likely)."
fi

# ─── graphify_price_hooks: Finding 3 (mode preservation) ─────────────────────
echo "[test-graphify-bin] graphify_price_hooks: Finding 3 -- repricing preserves an existing 0600 mode (HIMMEL-2480 CR round 3)"
# POSIX only: Windows has no POSIX permission bits for chmod/stat to round-trip
# through, so this is moot there (the finding itself says so) -- gate on uname
# rather than skip silently on a failed chmod assertion.
case "$(uname -s 2>/dev/null || echo)" in
  Linux*|Darwin*) _mode_platform_ok=1 ;;
  *) _mode_platform_ok=0 ;;
esac

if [ "$_mode_platform_ok" = 1 ]; then
  run_finding3_case() {  # $1=slug $2=engine("" | python)
    local slug="$1" engine="${2:-}"
    local dir="$tmpdir/f3-$slug"; mkdir -p "$dir/.claude"
    cat > "$dir/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/auto-arm-on-cap.sh" }
        ]
      }
    ]
  }
}
EOF
    chmod 0600 "$dir/.claude/settings.json"
    local out
    if [ -n "$engine" ]; then
      # shellcheck disable=SC2016
      out=$(env "${force_python_env[@]}" bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$dir" 2>&1)
    else
      out=$(bash -c '. "'"$SCRIPT_DIR"'/graphify-bin.sh"; graphify_price_hooks "$1"; echo "RC=$?"' _ "$dir" 2>&1)
    fi
    assert "mode ($slug): rc 0" grep -q '^RC=0$' <<<"$out"
    assert "mode ($slug): settings reported repriced" price_verdict "$out" "repriced" ".claude/settings.json"
    assert "mode ($slug): mode is still 0600 after repricing" \
      test "$(stat -c '%a' "$dir/.claude/settings.json" 2>/dev/null || stat -f '%Lp' "$dir/.claude/settings.json")" = "600"  # gnu-ok: GNU stat -c is paired with the BSD stat -f fallback on this same line
  }

  run_finding3_case node
  run_finding3_case python python
else
  echo "[test-graphify-bin] SKIP: Finding 3 mode-preservation test is POSIX-only (uname reports neither Linux nor Darwin) -- moot on Windows, which has no POSIX permission bits here."
fi

echo
echo "[test-graphify-bin] pass=$pass fail=$fail"
test "$fail" -eq 0
