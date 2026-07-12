#!/usr/bin/env bash
# test-wizard-preflight.sh — hermetic tests for the himmelctl install wizard's
# preflight-first gate (HIMMEL-887 T1). Mirrors scripts/test-adopt.sh
# conventions: a stub PATH built via scripts/lib/hermetic-path.sh, a fake HOME,
# node launched by absolute path so the wizard's tool detection sees ONLY the
# stub dir. Nothing on the real machine is read or written.
#
# Covers:
#   1. non-interactive, missing jq -> missing-tool message + exit non-zero,
#      WITHOUT asking anything (no install prompt).
#   2. all hard-gate tools present -> `install --dry-run` reaches `preflight OK`.
#   3. interactive (HIMMELCTL_INTERACTIVE=1), missing jq + a fake pkg-manager
#      stub that logs its argv and creates the missing tool -> answering `y`
#      triggers exactly ONE pkg-mgr call and the re-check reaches
#      `preflight OK`.
#   4. interactive, missing jq, stdin closed BEFORE any answer at the
#      "Install missing tools now?" confirm -> declines safely (CR r1 FIX 8:
#      the confirm used to hang forever on EOF-before-answer; it now uses the
#      same EOF-safe helper as every other confirm in this file).
#   5. `install uninstall` (two subcommands) -> hard error rc=2, nothing run
#      (CR r2 FIX 1: the later subcommand used to silently win, so
#      `himmelctl install uninstall` ran uninstall).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# node is launched by absolute path so a stub-only PATH (which node detection
# scans) can be hermetic without making node itself unlaunchable.
node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# build_path <stub_dir> <present_tools...> -- <absent_tools...>
# Hard-link/copy the named present tools off the CURRENT (real) PATH into
# <stub_dir>, then echo a PATH with the stub prepended and the named absent
# tools scrubbed from the real PATH. Mirrors test-adopt.sh's
# link-then-scrub-then-prepend pattern.
build_path() {
  local _stub="$1"; shift
  local _present=() _absent=() _stage=0 _t
  for _t in "$@"; do
    if [ "$_t" = "--" ]; then _stage=1; continue; fi
    if [ "$_stage" -eq 0 ]; then _present+=("$_t"); else _absent+=("$_t"); fi
  done
  for _t in "${_present[@]}"; do
    link_hermetic_tool "$_t" "$_stub"
  done
  local _scrubbed="$PATH"
  if [ "${#_absent[@]}" -gt 0 ]; then
    _scrubbed=$(scrub_path "$PATH" "${_absent[@]}")
  fi
  printf '%s:%s' "$_stub" "$_scrubbed"
}

# ── Case 1: non-interactive, missing jq -> message + exit non-zero, no prompt ──
stub1="$work/case1"; mkdir -p "$stub1"
c1path=$(build_path "$stub1" bash git python3 npm -- jq)
# jq must actually be unresolvable on the stub PATH.
PATH="$c1path" command -v jq >/dev/null 2>&1 \
  && fail "case1 sanity: jq should be absent on the stub PATH"
h1="$work/h1"; mkdir -p "$h1"
set +e
out=$(PATH="$c1path" HOME="$h1" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "case1: missing jq should exit non-zero (got $rc)"
printf '%s' "$out" | grep -q 'jq' \
  || fail "case1: missing-tool message should mention jq (got: $out)"
if printf '%s' "$out" | grep -q 'Install missing tools now'; then
  fail "case1: non-interactive run must NOT prompt to install (saw prompt)"
fi
echo "ok: case1 non-interactive missing jq -> message + exit non-zero, no prompt"

# ── Case 2: all hard-gate tools present -> install --dry-run reaches preflight OK ─
stub2="$work/case2"; mkdir -p "$stub2"
c2path=$(build_path "$stub2" bash git jq python3 npm -- )
h2="$work/h2"; mkdir -p "$h2"
set +e
out=$(PATH="$c2path" HOME="$h2" \
      "$node_bin" "$wizard" install --dry-run </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case2: all tools present should reach preflight OK (got rc=$rc)"
printf '%s' "$out" | grep -q 'preflight OK' \
  || fail "case2: expected 'preflight OK' (got: $out)"
echo "ok: case2 all hard-gate tools present -> install --dry-run reaches preflight OK"

# ── Case 3: interactive missing-tool -> one pkg-mgr call + recheck passes ───────
stub3="$work/case3"; mkdir -p "$stub3"
log3="$work/case3-pkgmgr.log"
# The wizard invokes a platform-specific package manager; stub whichever one it
# will reach so the same case is hermetic on win32/darwin/linux.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) pkgmgr='winget' ;;
  Darwin)              pkgmgr='brew' ;;
  Linux)               pkgmgr='sudo' ;;
  *) fail "case3: unsupported platform $(uname -s)" ;;
esac
# The stub logs its argv (so the test can count calls) and fabricates each named
# missing tool inside the stub dir, so the wizard's re-check finds it. The
# winget branch receives `install --id <ID> -e` (CR r2: one exact package id
# per invocation, never a bare-name query), so ids map back to tool names;
# apt/brew still receive bare tool names.
cat > "$stub3/$pkgmgr" <<STUB
#!/usr/bin/env bash
echo "called: \$*" >> "$log3"
for a in "\$@"; do
  case "\$a" in
    install|-y|apt-get|--id|-e) continue ;;
    Git.Git)          a=git ;;
    jqlang.jq)        a=jq ;;
    Python.Python.*)  a=python3 ;;
    OpenJS.NodeJS.*)  a=npm ;;
  esac
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub3/\$a"
  chmod +x "$stub3/\$a"
done
exit 0
STUB
chmod +x "$stub3/$pkgmgr"
c3path=$(build_path "$stub3" bash git python3 npm -- jq)
PATH="$c3path" command -v jq >/dev/null 2>&1 \
  && fail "case3 sanity: jq should be absent before the install offer"
h3="$work/h3"; mkdir -p "$h3"
set +e
out=$(PATH="$c3path" HOME="$h3" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install <<<"y" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case3: install+recheck should reach preflight OK (got rc=$rc)"
printf '%s' "$out" | grep -q 'Install missing tools now' \
  || fail "case3: interactive run should prompt to install (got: $out)"
calls=0
[ -f "$log3" ] && calls=$(wc -l < "$log3")
[ "$calls" = "1" ] \
  || fail "case3: expected exactly 1 pkg-mgr call (got $calls): $(cat "$log3" 2>/dev/null)"
printf '%s' "$out" | grep -q 'preflight OK' \
  || fail "case3: recheck should reach preflight OK (got: $out)"
echo "ok: case3 interactive -> exactly 1 $pkgmgr call + recheck passes -> preflight OK"

# ── Case 4: interactive, closed stdin at the install confirm -> no hang ────
# CR r1 FIX 8 made the confirm EOF-safe so a closed stdin declines instead of
# looping forever. This case REGRESSION-GUARDS that fix: if the EOF-safe helper
# ever regresses, the wizard would hang on the confirm and wedge CI. So the
# invocation runs under a bounded watchdog (mirroring scripts/check-plugin-dift.sh's
# probe-timeout pattern): `timeout` when present, else a bash-native setsid
# group-kill fallback. Git-Bash's `timeout` does not reap grandchildren; the
# wizard spawns none at a closed-stdin confirm, but the setsid fallback
# (process-group kill) is correct if it ever does. bash 3.2-safe (plain `wait`,
# no `wait -n`). A hang fails this case instead of wedging CI.
stub4="$work/case4"; mkdir -p "$stub4"
c4path=$(build_path "$stub4" bash git python3 npm -- jq)
h4="$work/h4"; mkdir -p "$h4"
c4_budget=15
c4_out="$work/case4.out"
set +e
if command -v timeout >/dev/null 2>&1; then
  timeout "$c4_budget" env PATH="$c4path" HOME="$h4" HIMMELCTL_INTERACTIVE=1 \
    "$node_bin" "$wizard" install </dev/null >"$c4_out" 2>&1
  rc=$?
else
  if command -v setsid >/dev/null 2>&1; then
    setsid env PATH="$c4path" HOME="$h4" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install </dev/null >"$c4_out" 2>&1 &
    c4_pid=$!; c4_grouped=1
  else
    env PATH="$c4path" HOME="$h4" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install </dev/null >"$c4_out" 2>&1 &
    c4_pid=$!; c4_grouped=0
  fi
  ( sleep "$c4_budget"
    if [ "$c4_grouped" -eq 1 ]; then kill -9 -- -"$c4_pid" 2>/dev/null
    else kill -9 "$c4_pid" 2>/dev/null; fi
  ) &
  c4_wdog=$!
  wait "$c4_pid" 2>/dev/null
  rc=$?
  kill "$c4_wdog" 2>/dev/null
  wait "$c4_wdog" 2>/dev/null
fi
set -e
# timeout(1) exits 124 on its own budget; a signal-killed child (the setsid
# fallback) leaves rc>=128. Either means the confirm HANGS -> fail, not wedge CI.
if [ "$rc" -eq 124 ] || [ "$rc" -ge 128 ]; then
  fail "case4: closed-stdin confirm HANGS (regression of the EOF-safe helper) — watchdog killed it at ${c4_budget}s (rc=$rc, out: $(cat "$c4_out" 2>/dev/null))"
fi
out="$(cat "$c4_out" 2>/dev/null)"
[ "$rc" -ne 0 ] || fail "case4: closed-stdin decline at the install confirm should exit non-zero (got rc=$rc): $out"
printf '%s' "$out" | grep -q 'Install missing tools now' \
  || fail "case4: expected the install-confirm prompt to be shown (got: $out)"
echo "ok: case4 interactive missing-tool, closed stdin at the confirm -> declines safely (no hang, ${c4_budget}s watchdog), exit non-zero"

# ── Case 5: two subcommands -> hard error rc=2, nothing runs ───────────────
stub5="$work/case5"; mkdir -p "$stub5"
c5path=$(build_path "$stub5" bash git jq python3 npm -- )
h5="$work/h5"; mkdir -p "$h5"
set +e
out=$(PATH="$c5path" HOME="$h5" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install uninstall </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "case5: 'install uninstall' should hard-error with rc=2 (got rc=$rc): $out"
printf '%s' "$out" | grep -q "multiple subcommands given ('install' and 'uninstall')" \
  || fail "case5: expected the multiple-subcommands error message (got: $out)"
printf '%s' "$out" | grep -q 'preflight OK' \
  && fail "case5: a rejected arg line must not reach the preflight gate (got: $out)"
printf '%s' "$out" | grep -q 'derived:' \
  && fail "case5: a rejected arg line must derive/run nothing (got: $out)"
echo "ok: case5 'install uninstall' -> rc=2 multiple-subcommands error, nothing derived or run"

echo "PASS"
