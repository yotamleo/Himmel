#!/usr/bin/env bash
# test-wizard-bootstrap.sh — hermetic tests for the himmelctl bootstrap
# shims (HIMMEL-887 T7): scripts/himmelctl/bootstrap.sh (posix: darwin
# brew / linux apt) and scripts/himmelctl/bootstrap.ps1 (win32: winget).
# Both are independent standalone entry points (unlike uninstall.sh/.ps1,
# which bin.js alternately invokes based on runtime platform), so this
# suite exercises BOTH directly and unconditionally rather than branching
# on is_win32() to pick one. A throwaway HIMMELCTL_REPO_ROOT fixture (the
# same env-var seam bin.js itself honors) carries a stub bin.js so the
# hand-off is observable without ever touching the real wizard; a stub
# PATH carries fake `sudo`/`winget.cmd` install shell-outs so a real
# node/bun install is never triggered against the real machine.
#
# Covers (per script):
#   A. node present -> short-circuits straight to the hand-off; the
#      platform installer is never invoked (T7 done-check c).
#   B. --dry-run/-DryRun, node absent -> prints the install plan + the
#      hand-off command; nothing is invoked or mutated (T7 done-check a).
#   C. node absent, non-dry-run, install does NOT make node resolvable ->
#      the installer IS invoked, but bootstrap prints exactly ONE re-run
#      line instead of chaining to bin.js (the PATH-refresh trap, T7
#      done-check b).
#   D. (bash only, bonus) node absent, non-dry-run, install DOES make node
#      resolvable -> chains to bin.js with "install".
#   F. CR r1 FIX 1/2: the package-manager install plan/line no longer asks
#      for `bun` on non-darwin apt / winget (bun is not an apt package and
#      `winget install node bun` resolves as a single bad query) — apt gets
#      `nodejs npm` only, winget gets `--id OpenJS.NodeJS.LTS -e`; a
#      bun-is-optional note is printed instead.
#   G. CR r1 FIX 1/2 (HIMMEL-935 for ps1): the platform installer itself EXITS
#      NONZERO (a genuine apt/winget failure, not just a not-yet-refreshed-PATH)
#      -> bootstrap.sh prints "node install failed" and aborts immediately (no
#      re-run line); bootstrap.ps1 prints a Write-Warning with the exit code,
#      then fail-closes with a Write-Error instead of the re-run line (the old
#      warn-not-abort implied success and looped forever re-running a known-
#      failing winget install).
#
# pwsh availability is optional on posix CI hosts: the .ps1 cases are
# skipped (not failed) when pwsh isn't found, mirroring the availability
# guard in scripts/test-luna-upgrade-vm.sh. They are ALSO skipped on
# non-Windows hosts even when pwsh exists (ubuntu-latest CI ships pwsh):
# the hermetic stubs are `winget.cmd`/`node.exe` shims that only Windows
# can execute, so on posix the stubbed `winget install` line would die
# under ErrorActionPreference=Stop and fail the cases spuriously.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
bootstrap_sh="$repo_root/scripts/himmelctl/bootstrap.sh"
bootstrap_ps1="$repo_root/scripts/himmelctl/bootstrap.ps1"
[ -f "$bootstrap_sh" ] || { echo "FAIL: $bootstrap_sh not found" >&2; exit 1; }
[ -f "$bootstrap_ps1" ] || { echo "FAIL: $bootstrap_ps1 not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v bash >/dev/null 2>&1 || { echo "FAIL: bash required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)
bash_bin=$(command -v bash)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# winpath <path> — echo <path> unchanged on posix, or its Windows form on
# git-bash/MSYS/Cygwin (node.exe/pwsh.exe misresolve MSYS /tmp-style paths).
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# build_path <stub_dir> <present_tools...> -- <absent_tools...>
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

# build_bin_js_fixture <dir> — a throwaway HIMMELCTL_REPO_ROOT target
# carrying a stub scripts/himmelctl/bin.js that logs its argv (never the
# real wizard) to bin-js-calls.log alongside it.
build_bin_js_fixture() {
  local _d="$1"
  mkdir -p "$_d/scripts/himmelctl"
  cat > "$_d/scripts/himmelctl/bin.js" <<'STUB'
const fs = require('fs');
const path = require('path');
fs.appendFileSync(
  path.join(__dirname, 'bin-js-calls.log'),
  'bin.js: ' + process.argv.slice(2).join(' ') + '\n'
);
STUB
}

# build_sudo_stub <dir> <restore_node:0|1> — a fake `sudo` that logs its
# argv to install-calls.log; when restore_node=1 it also places a WORKING
# copy of the real node binary (captured before any scrub) into <dir>,
# simulating an install that successfully refreshes PATH.
build_sudo_stub() {
  local _dir="$1" _restore="$2"
  cat > "$_dir/sudo" <<STUB
#!/usr/bin/env bash
printf 'sudo: %s\n' "\$*" >> "$_dir/install-calls.log"
STUB
  if [ "$_restore" = "1" ]; then
    cat >> "$_dir/sudo" <<STUB
ln -sf "$node_bin" "$_dir/node" 2>/dev/null || cp "$node_bin" "$_dir/node"
chmod +x "$_dir/node" 2>/dev/null || true
STUB
  fi
  echo 'exit 0' >> "$_dir/sudo"
  chmod +x "$_dir/sudo"
}

# build_aptget_stub <dir> — a no-op `apt-get` so bootstrap.sh's non-Darwin
# `command -v apt-get` presence guard (HIMMEL-935) passes on hosts that lack
# apt-get (macOS/MINGW), letting the sudo stub intercept `sudo apt-get install`
# as before. It is never actually invoked — sudo receives apt-get as an arg.
build_aptget_stub() {
  local _dir="$1"
  cat > "$_dir/apt-get" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$_dir/apt-get"
}

# ── bootstrap.sh — Case A: node present -> short-circuit, no installer ─────
stubA="$work/shA"; mkdir -p "$stubA"
cA=$(build_path "$stubA" uname node -- )
fixtureA="$work/shA-fixture"; build_bin_js_fixture "$fixtureA"
set +e
out=$(PATH="$cA" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureA")" \
      "$bash_bin" "$bootstrap_sh" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseA(sh): node-present should exit 0 (got rc=$rc): $out"
printf '%s' "$out" | grep -q 'node found' \
  || fail "caseA(sh): expected the node-found hand-off message (got: $out)"
[ -f "$fixtureA/scripts/himmelctl/bin-js-calls.log" ] \
  || fail "caseA(sh): expected bin.js to be invoked (out: $out)"
grep -q 'install' "$fixtureA/scripts/himmelctl/bin-js-calls.log" \
  || fail "caseA(sh): expected bin.js invoked with the 'install' arg"
[ -f "$stubA/install-calls.log" ] \
  && fail "caseA(sh): node-present short-circuit must NOT invoke the platform installer"
echo "ok: caseA(sh) node present -> short-circuits straight to hand-off, installer never invoked"

# ── bootstrap.sh — Case B: --dry-run, node absent -> plan+hand-off only ────
stubB="$work/shB"; mkdir -p "$stubB"
build_sudo_stub "$stubB" 0
cB=$(build_path "$stubB" uname -- node)
fixtureB="$work/shB-fixture"; build_bin_js_fixture "$fixtureB"
set +e
out=$(PATH="$cB" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureB")" \
      "$bash_bin" "$bootstrap_sh" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseB(sh): --dry-run should exit 0 (got rc=$rc): $out"
printf '%s' "$out" | grep -q 'install plan' \
  || fail "caseB(sh): expected the install-plan line (got: $out)"
printf '%s' "$out" | grep -q 'hand-off after install' \
  || fail "caseB(sh): expected the hand-off line (got: $out)"
[ -f "$stubB/install-calls.log" ] \
  && fail "caseB(sh): --dry-run must NOT invoke the installer"
[ -f "$fixtureB/scripts/himmelctl/bin-js-calls.log" ] \
  && fail "caseB(sh): --dry-run must NOT invoke bin.js"
echo "ok: caseB(sh) --dry-run node-absent -> plan+hand-off printed, nothing mutated"

# ── bootstrap.sh — Case C: node absent, install doesn't refresh PATH ───────
stubC="$work/shC"; mkdir -p "$stubC"
build_sudo_stub "$stubC" 0
build_aptget_stub "$stubC"
cC=$(build_path "$stubC" uname -- node)
fixtureC="$work/shC-fixture"; build_bin_js_fixture "$fixtureC"
set +e
out=$(PATH="$cC" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureC")" \
      "$bash_bin" "$bootstrap_sh" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "caseC(sh): node-still-absent-after-install should exit nonzero (got rc=$rc): $out"
[ -f "$stubC/install-calls.log" ] \
  || fail "caseC(sh): expected the installer to have been invoked (out: $out)"
reruns=$(printf '%s' "$out" | grep -c 're-run')
[ "$reruns" -eq 1 ] \
  || fail "caseC(sh): expected exactly ONE re-run line, got $reruns (out: $out)"
[ -f "$fixtureC/scripts/himmelctl/bin-js-calls.log" ] \
  && fail "caseC(sh): must NOT chain to bin.js when node is still unresolvable"
echo "ok: caseC(sh) node absent, install doesn't refresh PATH -> single re-run line, no blind chain"

# ── bootstrap.sh — Case D (bonus): install DOES refresh PATH -> chains ─────
stubD="$work/shD"; mkdir -p "$stubD"
build_sudo_stub "$stubD" 1
build_aptget_stub "$stubD"
cD=$(build_path "$stubD" uname -- node)
fixtureD="$work/shD-fixture"; build_bin_js_fixture "$fixtureD"
set +e
out=$(PATH="$cD" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureD")" \
      "$bash_bin" "$bootstrap_sh" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseD(sh): should exit 0 once node becomes resolvable (got rc=$rc): $out"
[ -f "$stubD/install-calls.log" ] \
  || fail "caseD(sh): expected the installer to have been invoked (out: $out)"
[ -f "$fixtureD/scripts/himmelctl/bin-js-calls.log" ] \
  || fail "caseD(sh): expected bin.js to be chained to once node is resolvable (out: $out)"
grep -q 'install' "$fixtureD/scripts/himmelctl/bin-js-calls.log" \
  || fail "caseD(sh): expected bin.js invoked with the 'install' arg"
echo "ok: caseD(sh) node absent, install refreshes PATH -> chains to bin.js"

# ── bootstrap.sh — Case F: FIX 1 -- apt plan no longer asks for bun ────────
stubF="$work/shF"; mkdir -p "$stubF"
build_sudo_stub "$stubF" 0
cF=$(build_path "$stubF" uname -- node)
fixtureF="$work/shF-fixture"; build_bin_js_fixture "$fixtureF"
set +e
out=$(PATH="$cF" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureF")" \
      "$bash_bin" "$bootstrap_sh" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseF(sh): --dry-run should exit 0 (got rc=$rc): $out"
case "$(uname -s)" in
  Darwin)
    printf '%s' "$out" | grep -qE 'install plan: brew install node bun' \
      || fail "caseF(sh,darwin): expected 'brew install node bun' in the plan (got: $out)"
    ;;
  *)
    printf '%s' "$out" | grep -qE 'install plan: sudo apt-get install -y nodejs npm$' \
      || fail "caseF(sh,non-darwin): expected 'sudo apt-get install -y nodejs npm' in the plan (got: $out)"
    printf '%s' "$out" | grep -qi 'bun' \
      && fail "caseF(sh,non-darwin): the apt plan/dry-run preview must NOT mention bun (got: $out)"
    ;;
esac
echo "ok: caseF(sh) install plan no longer asks apt for a nonexistent bun package"

# ── bootstrap.sh — Case G: FIX 1 -- a genuine install failure aborts loud ──
stubG="$work/shG"; mkdir -p "$stubG"
build_aptget_stub "$stubG"
cat > "$stubG/sudo" <<STUB
#!/usr/bin/env bash
printf 'sudo: %s\n' "\$*" >> "$stubG/install-calls.log"
exit 1
STUB
chmod +x "$stubG/sudo"
cG=$(build_path "$stubG" uname -- node)
fixtureG="$work/shG-fixture"; build_bin_js_fixture "$fixtureG"
set +e
out=$(PATH="$cG" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureG")" \
      "$bash_bin" "$bootstrap_sh" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "caseG(sh): a genuinely failed install should exit non-zero (got rc=$rc): $out"
[ -f "$stubG/install-calls.log" ] \
  || fail "caseG(sh): expected the installer to have been invoked (out: $out)"
printf '%s' "$out" | grep -q 'node install failed' \
  || fail "caseG(sh): expected the 'node install failed' message (got: $out)"
printf '%s' "$out" | grep -q 're-run' \
  && fail "caseG(sh): a genuine install failure must abort BEFORE the re-run/PATH-refresh message (got: $out)"
[ -f "$fixtureG/scripts/himmelctl/bin-js-calls.log" ] \
  && fail "caseG(sh): a genuine install failure must NOT chain to bin.js"
echo "ok: caseG(sh) a genuinely failed apt/brew install -> 'node install failed' printed, aborts immediately, no chain"

# ── bootstrap.sh — Case H: non-Darwin host WITHOUT apt-get fails closed ─────
# HIMMEL-935 / CR #1126: the non-Darwin branch assumes apt. A host that is
# neither Darwin nor apt-based must fail closed with a manual-install pointer
# naming the detected platform, not silently mis-run `sudo apt-get`. A fake
# `uname` (reporting Linux) forces the non-Darwin branch even on a Darwin/macOS
# test host; apt-get is scrubbed so run_install hits the no-apt-get guard.
stubH="$work/shH"; mkdir -p "$stubH"
build_sudo_stub "$stubH" 0
cH=$(build_path "$stubH" -- node apt-get)
cat > "$stubH/uname" <<STUB
#!/usr/bin/env bash
[ "\$1" = "-s" ] && { echo "Linux"; exit 0; }
[ "\$1" = "-r" ] && { echo "99.0-fake"; exit 0; }
exec /usr/bin/uname "\$@"
STUB
chmod +x "$stubH/uname"
fixtureH="$work/shH-fixture"; build_bin_js_fixture "$fixtureH"
set +e
out=$(PATH="$cH" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureH")" \
      "$bash_bin" "$bootstrap_sh" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "caseH(sh): a non-Darwin host without apt-get should fail closed (got rc=$rc): $out"
printf '%s' "$out" | grep -qi 'install Node.js' \
  || fail "caseH(sh): expected the 'install Node.js >=18 manually' pointer (got: $out)"
printf '%s' "$out" | grep -qi 'Linux' \
  || fail "caseH(sh): expected the detected platform named in the message (got: $out)"
[ -f "$stubH/install-calls.log" ] \
  && fail "caseH(sh): the installer (sudo apt-get) must NOT be invoked when apt-get is absent (got: $out)"
echo "ok: caseH(sh) non-Darwin host without apt-get -> fail-closed manual-install pointer, no sudo apt-get"

# ── bootstrap.ps1 cases (skipped if pwsh isn't on this host, or when the
# host isn't Windows — the winget.cmd/node.exe stubs are Windows-only) ─────
# Prefer Windows PowerShell 5.1 (powershell.exe, always present on stock
# Windows) over pwsh (PowerShell 7, a separate install) so the .ps1 cases run
# on a stock Windows host; fall back to pwsh (HIMMEL-935 / CR #1126). The
# variable keeps the pwsh_bin name for minimal churn; it holds whichever
# interpreter was chosen.
pwsh_bin=""
if command -v powershell >/dev/null 2>&1; then
  pwsh_bin=$(command -v powershell)
elif command -v pwsh >/dev/null 2>&1; then
  pwsh_bin=$(command -v pwsh)
fi
win_host=0
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) win_host=1 ;;
esac

if [ -z "$pwsh_bin" ]; then
  echo "skip: no PowerShell interpreter (powershell/pwsh) found -- bootstrap.ps1 hermetic cases skipped"
elif [ "$win_host" -ne 1 ]; then
  echo "skip: non-Windows host -- bootstrap.ps1 hermetic cases need Windows-only winget.cmd/node.exe stubs"
else
  # ── bootstrap.ps1 — Case A: node present -> short-circuit, no winget ─────
  stubA2="$work/psA"; mkdir -p "$stubA2"
  cp "$node_bin" "$stubA2/node.exe"
  fixtureA2="$work/psA-fixture"; build_bin_js_fixture "$fixtureA2"
  set +e
  out=$(PATH="$stubA2:$PATH" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureA2")" \
        "$pwsh_bin" -NoProfile -File "$(winpath "$bootstrap_ps1")" 2>&1); rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "caseA(ps1): node-present should exit 0 (got rc=$rc): $out"
  printf '%s' "$out" | grep -q 'node found' \
    || fail "caseA(ps1): expected the node-found hand-off message (got: $out)"
  [ -f "$fixtureA2/scripts/himmelctl/bin-js-calls.log" ] \
    || fail "caseA(ps1): expected bin.js to be invoked (out: $out)"
  [ -f "$stubA2/install-calls.log" ] \
    && fail "caseA(ps1): node-present short-circuit must NOT invoke winget"
  echo "ok: caseA(ps1) node present -> short-circuits straight to hand-off, winget never invoked"

  # ── bootstrap.ps1 — Case B: -DryRun, node absent -> plan+hand-off only ───
  stubB2="$work/psB"; mkdir -p "$stubB2"
  cat > "$stubB2/winget.cmd" <<'STUB'
@echo off
echo winget: %* >> "%~dp0install-calls.log"
STUB
  scrubbedB2=$(scrub_path "$PATH" node)
  fixtureB2="$work/psB-fixture"; build_bin_js_fixture "$fixtureB2"
  set +e
  out=$(PATH="$stubB2:$scrubbedB2" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureB2")" \
        "$pwsh_bin" -NoProfile -File "$(winpath "$bootstrap_ps1")" -DryRun 2>&1); rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "caseB(ps1): -DryRun should exit 0 (got rc=$rc): $out"
  printf '%s' "$out" | grep -q 'install plan' \
    || fail "caseB(ps1): expected the install-plan line (got: $out)"
  printf '%s' "$out" | grep -q 'hand-off after install' \
    || fail "caseB(ps1): expected the hand-off line (got: $out)"
  [ -f "$stubB2/install-calls.log" ] \
    && fail "caseB(ps1): -DryRun must NOT invoke winget"
  [ -f "$fixtureB2/scripts/himmelctl/bin-js-calls.log" ] \
    && fail "caseB(ps1): -DryRun must NOT invoke bin.js"
  echo "ok: caseB(ps1) -DryRun node-absent -> plan+hand-off printed, nothing mutated"

  # ── bootstrap.ps1 — Case C: node absent, winget doesn't refresh PATH ─────
  stubC2="$work/psC"; mkdir -p "$stubC2"
  cat > "$stubC2/winget.cmd" <<'STUB'
@echo off
echo winget: %* >> "%~dp0install-calls.log"
STUB
  scrubbedC2=$(scrub_path "$PATH" node)
  fixtureC2="$work/psC-fixture"; build_bin_js_fixture "$fixtureC2"
  set +e
  out=$(PATH="$stubC2:$scrubbedC2" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureC2")" \
        "$pwsh_bin" -NoProfile -File "$(winpath "$bootstrap_ps1")" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "caseC(ps1): node-still-absent-after-install should exit nonzero (got rc=$rc): $out"
  [ -f "$stubC2/install-calls.log" ] \
    || fail "caseC(ps1): expected winget to have been invoked (out: $out)"
  reruns2=$(printf '%s' "$out" | grep -c 're-run')
  [ "$reruns2" -eq 1 ] \
    || fail "caseC(ps1): expected exactly ONE re-run line, got $reruns2 (out: $out)"
  [ -f "$fixtureC2/scripts/himmelctl/bin-js-calls.log" ] \
    && fail "caseC(ps1): must NOT chain to bin.js when node is still unresolvable"
  echo "ok: caseC(ps1) node absent, winget doesn't refresh PATH -> single re-run line, no blind chain"

  # ── bootstrap.ps1 — Case F: FIX 2 -- winget plan targets the explicit id ─
  stubF2="$work/psF"; mkdir -p "$stubF2"
  cat > "$stubF2/winget.cmd" <<'STUB'
@echo off
echo winget: %* >> "%~dp0install-calls.log"
STUB
  scrubbedF2=$(scrub_path "$PATH" node)
  fixtureF2="$work/psF-fixture"; build_bin_js_fixture "$fixtureF2"
  set +e
  out=$(PATH="$stubF2:$scrubbedF2" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureF2")" \
        "$pwsh_bin" -NoProfile -File "$(winpath "$bootstrap_ps1")" -DryRun 2>&1); rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "caseF(ps1): -DryRun should exit 0 (got rc=$rc): $out"
  printf '%s' "$out" | grep -qF -- '--id OpenJS.NodeJS.LTS -e' \
    || fail "caseF(ps1): expected the explicit '--id OpenJS.NodeJS.LTS -e' winget plan (got: $out)"
  printf '%s' "$out" | grep -qi 'bun' \
    && fail "caseF(ps1): the winget plan/dry-run preview must NOT mention bun (got: $out)"
  echo "ok: caseF(ps1) winget plan targets --id OpenJS.NodeJS.LTS -e, no bare 'node bun' query"

  # ── bootstrap.ps1 — Case G: FIX 2/HIMMEL-935 -- winget nonzero exit fail-closes ─
  stubG2="$work/psG"; mkdir -p "$stubG2"
  cat > "$stubG2/winget.cmd" <<'STUB'
@echo off
echo winget: %* >> "%~dp0install-calls.log"
exit /b 1
STUB
  scrubbedG2=$(scrub_path "$PATH" node)
  fixtureG2="$work/psG-fixture"; build_bin_js_fixture "$fixtureG2"
  set +e
  out=$(PATH="$stubG2:$scrubbedG2" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureG2")" \
        "$pwsh_bin" -NoProfile -File "$(winpath "$bootstrap_ps1")" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "caseG(ps1): a genuinely failed winget should exit non-zero (got rc=$rc): $out"
  [ -f "$stubG2/install-calls.log" ] \
    || fail "caseG(ps1): expected winget to have been invoked (out: $out)"
  printf '%s' "$out" | grep -qi 'exited 1' \
    || fail "caseG(ps1): expected the Write-Warning 'exited 1' message (got: $out)"
  printf '%s' "$out" | grep -qi 'winget install failed' \
    || fail "caseG(ps1): expected the fail-closed 'winget install failed' message (HIMMEL-935) (got: $out)"
  printf '%s' "$out" | grep -q 'open a new terminal' \
    && fail "caseG(ps1): a genuine winget failure must NOT print the PATH-refresh re-run line (would loop forever) (got: $out)"
  [ -f "$fixtureG2/scripts/himmelctl/bin-js-calls.log" ] \
    && fail "caseG(ps1): must NOT chain to bin.js when node is still unresolvable after a failed winget"
  echo "ok: caseG(ps1) a failed winget install -> Write-Warning + fail-closed Write-Error, NO re-run/PATH-refresh loop (HIMMEL-935)"
fi

echo "PASS"
