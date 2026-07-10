#!/usr/bin/env bash
# test-preflight-adopter.sh — smoke tests for the standalone check-only adopter
# preflight (HIMMEL-842 fix-batch): scripts/preflight-adopter.sh + its shared
# lib scripts/lib/preflight-adopter.sh.
#
# Self-contained: scrubs uv/pipx/node/npm/bun off PATH and re-adds stubs per
# scenario so nothing here depends on (or mutates) the real dev machine's
# toolchain. scripts/jira/dist/index.js AND scripts/jira/node_modules in THIS
# worktree are temporarily moved aside (if present) so every scenario starts
# from a known "absent" baseline, then restored on exit — never left mutated.
#
# Covers:
#   1. standalone, fully clean env -> "0 warnings", exit 0.
#   2. standalone, pipx present (uv absent) -> clean, exit 0 (F6).
#   3. standalone, uv+pipx both absent -> WARN, exit 0 (non-strict default).
#   4. standalone, node present + npm absent -> WARN, exit 0 (non-strict).
#   5. standalone, jira dist+node_modules absent -> WARN, exit 0 (non-strict).
#   6. --strict with a WARN present -> exit 1.
#   7. --strict with a fully clean env -> exit 0.
#   8. structural: adopt.sh's require_tools() reuses the shared lib functions
#      (sources scripts/lib/preflight-adopter.sh, calls each preflight_check_*
#      function) instead of duplicating the check/warn-text logic.
#   9. F2: preflight_check_jira_dist WARNs + returns 1 when HIMMEL_ROOT unset.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
preflight="$repo_root/scripts/preflight-adopter.sh"
lib="$repo_root/scripts/lib/preflight-adopter.sh"
adopt="$repo_root/scripts/adopt.sh"
[ -f "$preflight" ] || { echo "FAIL: $preflight not found" >&2; exit 1; }
[ -f "$lib" ]       || { echo "FAIL: $lib not found" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

work=$(mktemp -d)

# scripts/jira/dist + scripts/jira/node_modules are gitignored build artifacts
# in THIS worktree — move any existing ones aside so every scenario below
# starts from a known "absent" baseline (preflight_check_jira_dist reads
# $HIMMEL_ROOT, which the standalone runner derives from its own path == this
# repo, and F3 now checks both halves). Restored unconditionally on exit,
# alongside the scratch dir.
real_jira_dist="$repo_root/scripts/jira/dist"
real_jira_node_modules="$repo_root/scripts/jira/node_modules"
dist_backup=""
node_modules_backup=""
if [ -e "$real_jira_dist" ]; then
  dist_backup="$work/dist-backup"
  mv "$real_jira_dist" "$dist_backup"
fi
if [ -e "$real_jira_node_modules" ]; then
  node_modules_backup="$work/node_modules-backup"
  mv "$real_jira_node_modules" "$node_modules_backup"
fi
cleanup() {
  rm -rf "$real_jira_dist" "$real_jira_node_modules"
  if [ -n "$dist_backup" ]; then mv "$dist_backup" "$real_jira_dist"; fi
  if [ -n "$node_modules_backup" ]; then mv "$node_modules_backup" "$real_jira_node_modules"; fi
  rm -rf "$work"
}
trap cleanup EXIT

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

# Hermeticity: scrub every dir carrying a real uv/pipx/node/npm/bun off PATH so
# no scenario below can observe (or be confused by) the real dev machine's
# toolchain. Scenarios re-add their own stubs on top of this scrubbed base.
#
# HIMMEL-880: on stock Ubuntu npm lives in /usr/bin alongside bash itself, so
# the scrub below drops bash wholesale and every `PATH="$tool_free_path" bash
# ...` invocation below fails to resolve bash before running a single line of
# the target script (the identical bug HIMMEL-874 fixed in test-adopt.sh).
# Pre-link bash + the tools preflight-adopter.sh needs into a hermetic stub
# dir BEFORE scrubbing, then prepend that stub dir on every invocation below.
mkdir -p "$work/bin"
for _tool in bash dirname sed; do
  link_hermetic_tool "$_tool"
done
tool_free_path=$(scrub_path "$PATH" uv pipx node npm bun)
PATH="$work/bin" command -v bash >/dev/null 2>&1 \
  || fail "hermetic stub dir must provide bash even if every scrubbed dir is removed"

# ── 1. standalone, fully clean env -> "0 warnings", exit 0 ───────────────────
c1bin="$work/c1bin"; mkdir -p "$c1bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$c1bin/uv"; chmod +x "$c1bin/uv"
mkdir -p "$real_jira_dist"; : > "$real_jira_dist/index.js"
mkdir -p "$real_jira_node_modules"
out=$(PATH="$c1bin:$work/bin:$tool_free_path" bash "$preflight" 2>&1); rc=$?
rm -rf "$real_jira_dist" "$real_jira_node_modules"
[ "$rc" -eq 0 ] || fail "clean env: expected exit 0, got $rc"
printf '%s' "$out" | grep -q '0 warnings' || fail "clean env: missing '0 warnings' summary (got: $out)"
if printf '%s' "$out" | grep -q 'WARN:'; then fail "clean env: unexpected WARN line (got: $out)"; fi
echo "ok: standalone clean env reports 0 warnings, exit 0"

# ── 2. pipx present (uv absent) -> clean, exit 0 (F6: the check is uv OR pipx) ─
c2bin="$work/c2bin"; mkdir -p "$c2bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$c2bin/pipx"; chmod +x "$c2bin/pipx"
mkdir -p "$real_jira_dist"; : > "$real_jira_dist/index.js"
mkdir -p "$real_jira_node_modules"
out=$(PATH="$c2bin:$work/bin:$tool_free_path" bash "$preflight" 2>&1); rc=$?
rm -rf "$real_jira_dist" "$real_jira_node_modules"
[ "$rc" -eq 0 ] || fail "pipx-only: expected exit 0, got $rc"
printf '%s' "$out" | grep -q '0 warnings' || fail "pipx-only: missing '0 warnings' summary (got: $out)"
if printf '%s' "$out" | grep -q 'WARN:'; then fail "pipx-only: unexpected WARN line (got: $out)"; fi
echo "ok: pipx present (uv absent) reports 0 warnings, exit 0"

# ── 3. uv+pipx both absent -> WARN, exit 0 (non-strict default) ──────────────
mkdir -p "$real_jira_dist"; : > "$real_jira_dist/index.js"
mkdir -p "$real_jira_node_modules"
out=$(PATH="$work/bin:$tool_free_path" bash "$preflight" 2>&1); rc=$?
rm -rf "$real_jira_dist" "$real_jira_node_modules"
[ "$rc" -eq 0 ] || fail "uv/pipx gap: non-strict should exit 0, got $rc"
printf '%s' "$out" | grep -q "neither 'uv' nor 'pipx' found" || fail "uv/pipx gap: missing WARN text (got: $out)"
printf '%s' "$out" | grep -q 'warning(s)' || fail "uv/pipx gap: missing warning-count summary (got: $out)"
echo "ok: uv+pipx absent WARNs and exits 0 (non-strict)"

# ── 4. node present + npm absent -> WARN, exit 0 (non-strict) ────────────────
c4bin="$work/c4bin"; mkdir -p "$c4bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$c4bin/uv";   chmod +x "$c4bin/uv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$c4bin/node"; chmod +x "$c4bin/node"
mkdir -p "$real_jira_dist"; : > "$real_jira_dist/index.js"
mkdir -p "$real_jira_node_modules"
out=$(PATH="$c4bin:$work/bin:$tool_free_path" bash "$preflight" 2>&1); rc=$?
rm -rf "$real_jira_dist" "$real_jira_node_modules"
[ "$rc" -eq 0 ] || fail "node-without-npm: non-strict should exit 0, got $rc"
printf '%s' "$out" | grep -q "'node' found but 'npm' is missing" || fail "node-without-npm: missing WARN text (got: $out)"
echo "ok: node-without-npm WARNs and exits 0 (non-strict)"

# ── 5. jira dist+node_modules absent -> WARN, exit 0 (non-strict) ────────────
c5bin="$work/c5bin"; mkdir -p "$c5bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$c5bin/uv"; chmod +x "$c5bin/uv"
# real_jira_dist / real_jira_node_modules stay absent (moved-aside baseline).
out=$(PATH="$c5bin:$work/bin:$tool_free_path" bash "$preflight" 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "jira-dist gap: non-strict should exit 0, got $rc"
printf '%s' "$out" | grep -q 'scripts/jira/dist/index.js not built' || fail "jira-dist gap: missing WARN text (got: $out)"
echo "ok: jira dist+node_modules absent WARNs and exits 0 (non-strict)"

# ── 6. --strict with a WARN present -> exit 1 ─────────────────────────────────
# real_jira_dist/node_modules absent -> the jira-dist gap alone trips --strict.
c6bin="$work/c6bin"; mkdir -p "$c6bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$c6bin/uv"; chmod +x "$c6bin/uv"
set +e
out=$(PATH="$c6bin:$work/bin:$tool_free_path" bash "$preflight" --strict 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || fail "--strict with a WARN present should exit 1, got $rc"
printf '%s' "$out" | grep -q 'Re-run with --strict' || true  # informational only when warns==0; not asserted here
echo "ok: --strict exits 1 when any WARN is present"

# ── 7. --strict with a fully clean env -> exit 0 ──────────────────────────────
c7bin="$work/c7bin"; mkdir -p "$c7bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$c7bin/uv"; chmod +x "$c7bin/uv"
mkdir -p "$real_jira_dist"; : > "$real_jira_dist/index.js"
mkdir -p "$real_jira_node_modules"
out=$(PATH="$c7bin:$work/bin:$tool_free_path" bash "$preflight" --strict 2>&1); rc=$?
rm -rf "$real_jira_dist" "$real_jira_node_modules"
[ "$rc" -eq 0 ] || fail "--strict with a clean env should exit 0, got $rc"
printf '%s' "$out" | grep -q '0 warnings' || fail "--strict clean env: missing '0 warnings' summary (got: $out)"
echo "ok: --strict exits 0 on a fully clean env"

# ── 8. structural: adopt.sh's require_tools() reuses the shared lib ──────────
# (no duplicated logic, per the HIMMEL-842 spec) instead of re-implementing
# the check/warn-text logic inline.
grep -q 'lib/preflight-adopter\.sh' "$adopt" \
  || fail "structural: adopt.sh does not source scripts/lib/preflight-adopter.sh"
for fn in preflight_check_uv_pipx preflight_check_npm_invocable preflight_check_jira_dist; do
  grep -q "$fn" "$adopt" \
    || fail "structural: adopt.sh's require_tools() does not call $fn (shared lib function)"
done
# The shared warn text must live in the lib, not be re-typed into adopt.sh —
# a duplicate would let the two entry points drift (the spec's stated risk).
if grep -q "neither 'uv' nor 'pipx' found" "$adopt"; then
  fail "structural: adopt.sh duplicates the uv/pipx warn text instead of reusing the shared lib"
fi
echo "ok: adopt.sh's require_tools() calls the shared preflight-adopter.sh lib functions (no duplicated logic)"

# ── 9. F2: preflight_check_jira_dist WARNs + returns 1 when HIMMEL_ROOT unset ─
# A caller bug (forgetting to set $HIMMEL_ROOT before calling the check) must
# surface, not silently pass. Source the lib directly (not via the standalone
# runner, which always sets HIMMEL_ROOT) in a subshell with it unset.
out=$(bash -c 'unset HIMMEL_ROOT; source "'"$lib"'"; preflight_check_jira_dist; echo "rc=$?"' 2>&1)
printf '%s' "$out" | grep -q 'HIMMEL_ROOT not set' || fail "F2: missing HIMMEL_ROOT-unset WARN text (got: $out)"
printf '%s' "$out" | grep -q 'rc=1' || fail "F2: preflight_check_jira_dist should return 1 when HIMMEL_ROOT unset (got: $out)"
echo "ok: preflight_check_jira_dist WARNs + returns 1 when HIMMEL_ROOT is unset (F2)"

echo "PASS"
