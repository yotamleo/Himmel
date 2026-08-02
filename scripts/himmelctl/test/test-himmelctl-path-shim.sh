#!/usr/bin/env bash
# test-himmelctl-path-shim.sh — hermetic coverage for the HIMMEL-1446
# himmelctl launcher written by both `install` and `update`.
#
# Covers: checkout-targeted creation, idempotent rewrite, moved-checkout
# re-point, PATH-missing guidance without profile/PATH mutation, honest dry-run,
# Windows .cmd/.ps1 twins (including no BOM), and install self-application.

set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || fail "$wizard not found"
command -v node >/dev/null 2>&1 || fail "node required"
node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d -t himmelctl-path-shim.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

bash_bin=$(winpath "$(command -v bash)")

build_update_fixture() {
  local _d="$1"
  mkdir -p "$_d/scripts/himmelctl"
  cat > "$_d/scripts/himmel-update.sh" <<STUB
#!/usr/bin/env bash
printf 'update\n' >> "$_d/update-calls.log"
STUB
  chmod +x "$_d/scripts/himmel-update.sh"
  cat > "$_d/scripts/himmelctl/bin.js" <<'STUB'
'use strict';
const fs = require('fs');
fs.appendFileSync(process.env.SHIM_CALL_LOG, `${process.env.SHIM_LABEL}:${process.argv.slice(2).join('|')}\n`);
STUB
}

run_update() {
  local _fixture="$1" _bin="$2" _platform="$3" _path="$4"
  PATH="$_path" HIMMELCTL_BASH="$bash_bin" \
    HIMMELCTL_REPO_ROOT="$(winpath "$_fixture")" \
    HIMMELCTL_BIN_DIR="$(winpath "$_bin")" \
    HIMMELCTL_SHIM_PLATFORM="$_platform" \
    "$node_bin" "$wizard" update </dev/null 2>&1
}

# ── A: update creates a checkout-targeted POSIX launcher ────────────────────
fixtureA="$work/caseA-checkout"
binA="$work/shared-bin"
build_update_fixture "$fixtureA"
out=$(run_update "$fixtureA" "$binA" linux "$(winpath "$binA"):$PATH")
[ -f "$fixtureA/update-calls.log" ] || fail "caseA: update engine was not invoked"
[ -x "$binA/himmelctl" ] || fail "caseA: executable POSIX launcher missing"
[ -f "$binA/himmelctl.js" ] || fail "caseA: target loader missing"
grepq "$out" 'launcher ->' || fail "caseA: launcher write was not reported: $out"
SHIM_CALL_LOG="$(winpath "$work/shim-calls.log")" SHIM_LABEL=A \
  PATH="$(winpath "$binA"):$PATH" "$binA/himmelctl" alpha "two words"
[ "$(cat "$work/shim-calls.log")" = 'A:alpha|two words' ] \
  || fail "caseA: generated launcher did not dispatch to this checkout's bin.js"
echo "ok: caseA update creates a working checkout-targeted POSIX launcher"

# ── B: re-run is byte-idempotent; moved checkout re-points the loader ───────
cp "$binA/himmelctl" "$work/himmelctl.before"
cp "$binA/himmelctl.js" "$work/himmelctl-js.before"
run_update "$fixtureA" "$binA" linux "$(winpath "$binA"):$PATH" >/dev/null
cmp -s "$work/himmelctl.before" "$binA/himmelctl" \
  || fail "caseB: idempotent re-run changed the POSIX wrapper"
cmp -s "$work/himmelctl-js.before" "$binA/himmelctl.js" \
  || fail "caseB: idempotent re-run changed the target loader"

fixtureB="$work/caseB-moved-checkout"
build_update_fixture "$fixtureB"
run_update "$fixtureB" "$binA" linux "$(winpath "$binA"):$PATH" >/dev/null
: > "$work/shim-calls.log"
SHIM_CALL_LOG="$(winpath "$work/shim-calls.log")" SHIM_LABEL=B \
  PATH="$(winpath "$binA"):$PATH" "$binA/himmelctl" moved
[ "$(cat "$work/shim-calls.log")" = 'B:moved' ] \
  || fail "caseB: moved checkout did not re-point the existing launcher"
grepq "$(cat "$binA/himmelctl.js")" 'caseB-moved-checkout' \
  || fail "caseB: loader does not name the moved checkout"
echo "ok: caseB re-run is idempotent and a moved checkout re-points in place"

# ── C: missing PATH prints a copy-paste instruction and mutates no profile ──
fixtureC="$work/caseC-checkout"
binC="$work/caseC-bin"
homeC="$work/caseC-home"
mkdir -p "$homeC"
build_update_fixture "$fixtureC"
printf 'profile-sentinel\n' > "$homeC/.profile"
printf 'bashrc-sentinel\n' > "$homeC/.bashrc"
before_path="$PATH"
out=$(HOME="$(winpath "$homeC")" run_update "$fixtureC" "$binC" linux "$PATH")
[ "$PATH" = "$before_path" ] || fail "caseC: parent PATH changed"
[ "$(cat "$homeC/.profile")" = 'profile-sentinel' ] || fail "caseC: .profile was mutated"
[ "$(cat "$homeC/.bashrc")" = 'bashrc-sentinel' ] || fail "caseC: .bashrc was mutated"
grepq "$out" 'is not on PATH' || fail "caseC: missing-PATH diagnostic absent: $out"
grepq "$out" 'export PATH=' || fail "caseC: exact POSIX PATH instruction absent: $out"
[ -f "$binC/himmelctl" ] || fail "caseC: launcher should still be written when PATH is missing"
echo "ok: caseC PATH-missing prints manual guidance and mutates neither PATH nor shell profiles"

# ── C2 (win32): the missing-PATH PowerShell instruction is idempotent ────────
# Pasting the printed line twice (e.g. a second `himmelctl update` before a new
# shell) must NOT duplicate the User PATH entry. The snippet prepends binDir
# only when it is not already an element of the persisted User PATH (HIMMEL-1446
# r4 glm-3). Asserted by SHAPE (grep) — actually mutating the User PATH needs
# machine-state change the suite cannot do hermetically; the idempotence guard
# and its "safe to repeat" marker are the lockable surface.
fixtureC2="$work/caseC2-checkout"; binC2="$work/caseC2-bin"; mkdir -p "$binC2"
build_update_fixture "$fixtureC2"
out=$(run_update "$fixtureC2" "$binC2" win32 "$PATH")
grepq "$out" 'is not on PATH' || fail "caseC2: missing-PATH diagnostic absent: $out"
grepq "$out" 'safe to repeat' || fail "caseC2: idempotence marker absent from the win32 PATH instruction: $out"
grepq "$out" -- '-contains' || fail "caseC2: idempotence guard (-contains) absent from the win32 PATH instruction: $out"
grepq "$out" 'SetEnvironmentVariable' || fail "caseC2: win32 PATH instruction absent: $out"
[ -f "$binC2/himmelctl.js" ] || fail "caseC2: launcher should still be written when PATH is missing"
echo "ok: caseC2 win32 missing-PATH instruction is idempotent (guards against a duplicate PATH entry)"

# ── D: dry-run plans the launcher but writes and executes nothing ───────────
fixtureD="$work/caseD-checkout"
binD="$work/caseD-bin"
build_update_fixture "$fixtureD"
set +e
out=$(PATH="$PATH" HIMMELCTL_BASH="$bash_bin" \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureD")" \
  HIMMELCTL_BIN_DIR="$(winpath "$binD")" HIMMELCTL_SHIM_PLATFORM=linux \
  "$node_bin" "$wizard" update --dry-run </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseD: dry-run exited $rc: $out"
grepq "$out" 'DRY: himmelctl launcher ->' || fail "caseD: launcher plan absent: $out"
grepq "$out" '(written to' && fail "caseD: dry-run claimed the launcher was written: $out"
[ ! -e "$binD" ] || fail "caseD: dry-run created the bin directory"
[ ! -f "$fixtureD/update-calls.log" ] || fail "caseD: dry-run executed the update engine"
echo "ok: caseD dry-run plans only — no update execution and no launcher files"

# ── E: Windows writes a relative .cmd (NO .ps1) without a BOM ───────────────
# Fix 1 (codex-adv-1): no himmelctl.ps1 is written — PowerShell command
# precedence resolves a .ps1 before the .cmd of the same basename, and a clean
# Windows client defaults to ExecutionPolicy=Restricted → bare `himmelctl`
# throws PSSecurityException. Letting PowerShell resolve the .cmd avoids that.
# (A live bare-`himmelctl`-under-Restricted resolution test is NOT expressible
# hermetically: controlling ExecutionPolicy needs machine-state mutation, and
# the only per-process override is -ExecutionPolicy Bypass — the very condition
# the fix removes the need for. The structural guarantee — no .ps1 written, so
# none to precedence-resolve — is covered by the assertions below. The stale-
# marked-.ps1 removal case lives in caseG5.)
fixtureE="$work/caseE checkout with spaces"
binE="$work/caseE bin with spaces"
build_update_fixture "$fixtureE"
win_path="$(winpath "$binE");$PATH"
out=$(run_update "$fixtureE" "$binE" win32 "$win_path")
[ -f "$binE/himmelctl.cmd" ] || fail "caseE: himmelctl.cmd missing"
[ -f "$binE/himmelctl.js" ] || fail "caseE: himmelctl.js missing"
[ ! -e "$binE/himmelctl.ps1" ] || fail "caseE: himmelctl.ps1 must NOT be written (ExecutionPolicy=Restricted breaks bare himmelctl)"
grepq "$(cat "$binE/himmelctl.cmd")" '%~dp0himmelctl.js' \
  || fail "caseE: .cmd does not use %~dp0-relative indirection"
grepq "$(cat "$binE/himmelctl.cmd")" 'generated by himmelctl (HIMMEL-1446)' \
  || fail "caseE: .cmd missing the ownership marker"
grepq "$(cat "$binE/himmelctl.js")" 'caseE checkout with spaces' \
  || fail "caseE: Windows target loader does not name this checkout"
for shim in "$binE/himmelctl.cmd" "$binE/himmelctl.js"; do
  prefix=$(od -An -tx1 -N3 "$shim" | tr -d ' \n')
  [ "$prefix" != 'efbbbf' ] || fail "caseE: UTF-8 BOM found in $shim"
done
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    SHIM_CALL_LOG="$(winpath "$work/windows-shim-calls.log")" SHIM_LABEL=CMD \
      SHIM_CMD="$(winpath "$binE/himmelctl.cmd")" \
      powershell -NoProfile -Command "& \$env:SHIM_CMD winarg" >/dev/null \
      || fail "caseE: .cmd launcher failed from a path containing spaces"
    win_calls=$(cat "$work/windows-shim-calls.log")
    grepq "$win_calls" '^CMD:winarg$' || fail "caseE: .cmd did not dispatch its argument"
    ;;
esac
echo "ok: caseE Windows .cmd is relative, checkout-targeted, marker-carrying, BOM-free, space-safe (no .ps1 written)"

# ── F: install applies the same launcher after its executor succeeds ────────
fixtureF="$work/caseF-checkout"
binF="$work/caseF-bin"
homeF="$work/caseF-home"
stubF="$work/caseF-tools"
mkdir -p "$fixtureF/scripts/himmelctl" "$homeF" "$stubF"
cat > "$fixtureF/scripts/himmelctl/bin.js" <<'STUB'
'use strict';
const fs = require('fs');
fs.appendFileSync(process.env.SHIM_CALL_LOG, `install:${process.argv.slice(2).join('|')}\n`);
STUB
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    cat > "$fixtureF/scripts/setup.ps1" <<'STUB'
Add-Content -LiteralPath $env:INSTALL_CALL_LOG -Value 'setup'
exit 0
STUB
    ;;
  *)
    cat > "$fixtureF/scripts/setup.sh" <<'STUB'
#!/usr/bin/env bash
printf 'setup\n' >> "$INSTALL_CALL_LOG"
STUB
    chmod +x "$fixtureF/scripts/setup.sh"
    ;;
esac
cat > "$work/contributor-profile.json" <<'JSON'
{
  "role": "contributor",
  "tier": "standard",
  "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON
for tool in bash git jq python3 npm; do link_hermetic_tool "$tool" "$stubF"; done
install_path="$(winpath "$binF"):$(winpath "$stubF"):$PATH"
set +e
out=$(PATH="$install_path" HOME="$(winpath "$homeF")" \
  HIMMELCTL_BASH="$bash_bin" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/caseF-cache")" \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureF")" \
  HIMMELCTL_BIN_DIR="$(winpath "$binF")" HIMMELCTL_SHIM_PLATFORM=linux \
  INSTALL_CALL_LOG="$(winpath "$work/install-calls.log")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$work/contributor-profile.json")" \
  </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseF: install exited $rc: $out"
[ "$(cat "$work/install-calls.log")" = 'setup' ] || fail "caseF: install executor did not run"
[ -x "$binF/himmelctl" ] || fail "caseF: install did not apply the launcher"
SHIM_CALL_LOG="$(winpath "$work/install-shim-calls.log")" \
  PATH="$(winpath "$binF"):$PATH" "$binF/himmelctl" status
[ "$(cat "$work/install-shim-calls.log")" = 'install:status' ] \
  || fail "caseF: install-applied launcher does not target this checkout"
echo "ok: caseF successful install self-applies the same launcher"

# ── G: ownership marker — refuse unmarked/symlink collisions, replace marked, ─
# ── atomic tmp+rename; stale marked .ps1 removed (Fix 3 + Fix 1 cleanup). ────
# Cross-platform file ops; HIMMELCTL_SHIM_PLATFORM drives which launchers write.
# These cases deliberately exercise FAILURE paths (refusals) and assert the rc
# explicitly with `[ ] || fail`, so run them under errexit OFF — caseF above
# leaves `set -e` on, under which an expected non-zero `out=$(run_update …)`
# would abort silently before the assertion (HIMMEL-1446 r2).
set +e

# G1: an unmarked third-party himmelctl.js is refused and left byte-untouched;
# no wrapper is written (the shim aborts on the first refusal). The update
# engine itself succeeded, so cmdUpdate keeps rc 0 and WARNS that the launcher
# is missing — the launcher is a best-effort rider (HIMMEL-1446 r4 glm-5).
fixG1="$work/caseG1-checkout"; binG1="$work/caseG1-bin"; mkdir -p "$binG1"
build_update_fixture "$fixG1"
printf 'third-party\n' > "$binG1/himmelctl.js"
out=$(run_update "$fixG1" "$binG1" linux "$(winpath "$binG1"):$PATH"); rc=$?
[ "$rc" -eq 0 ] || fail "caseG1: a refused launcher must not fail a successful update (rc=$rc): $out"
[ "$(cat "$binG1/himmelctl.js")" = 'third-party' ] \
  || fail "caseG1: unmarked collision must be left untouched"
[ ! -e "$binG1/himmelctl" ] || fail "caseG1: refusing the loader must abort before writing the wrapper"
grepq "$out" 'refusing to overwrite' || fail "caseG1: refusal message absent: $out"
grepq "$out" 'WARN: update succeeded' || fail "caseG1: launcher-failure WARN absent (best-effort rider): $out"
echo "ok: caseG1 unmarked third-party file refused (untouched); shim aborts; update rc stays 0 + WARN"

# G2: a symlink to an EXISTING target (a valid symlink) is refused — lstat,
# never followed/clobbered. This path already worked; it stays covered so a
# regression to an existsSync-follows-links guard is caught. The update engine
# succeeded, so rc stays 0 + WARN (HIMMEL-1446 r4 glm-5).
fixG2="$work/caseG2-checkout"; binG2="$work/caseG2-bin"; mkdir -p "$binG2"
build_update_fixture "$fixG2"
printf 'valid-target\n' > "$work/caseG2-target"
if ln -s "$work/caseG2-target" "$binG2/himmelctl.js" 2>/dev/null && [ -L "$binG2/himmelctl.js" ]; then
  out=$(run_update "$fixG2" "$binG2" linux "$(winpath "$binG2"):$PATH"); rc=$?
  [ "$rc" -eq 0 ] || fail "caseG2: a refused launcher must not fail a successful update (rc=$rc): $out"
  [ -L "$binG2/himmelctl.js" ] || fail "caseG2: valid symlink must be left intact (not followed/clobbered)"
  grepq "$out" 'refusing to overwrite symlink' || fail "caseG2: symlink refusal message absent: $out"
  grepq "$out" 'WARN: update succeeded' || fail "caseG2: launcher-failure WARN absent: $out"
  echo "ok: caseG2 valid symlink destination refused (intact); update rc stays 0 + WARN"
else
  echo "ok: caseG2 symlink refusal SKIPPED (host 'ln -s' produced no real symlink — e.g. MSYS without winsymlinks:nativestrict)"
fi

# G2b: a BROKEN (dangling) symlink — target absent — is refused too. fs.existsSync
# FOLLOWS symlinks and returns false for a dangling link, so the pre-fix guard
# skipped the symlink check and renameSync clobbered the link — violating the
# never-clobber-a-symlink contract. The lstat-based guard (HIMMEL-1446 r4 glm-2)
# refuses ANY symlink, broken included. rc stays 0 + WARN (the update engine
# succeeded; glm-5). Hosts that cannot create a real symlink (MSYS without
# winsymlinks:nativestrict) skip — this runs on Linux CI.
fixG2b="$work/caseG2b-checkout"; binG2b="$work/caseG2b-bin"; mkdir -p "$binG2b"
build_update_fixture "$fixG2b"
if ln -s "$work/caseG2b-does-not-exist" "$binG2b/himmelctl.js" 2>/dev/null && [ -L "$binG2b/himmelctl.js" ]; then
  out=$(run_update "$fixG2b" "$binG2b" linux "$(winpath "$binG2b"):$PATH"); rc=$?
  [ "$rc" -eq 0 ] || fail "caseG2b: a refused launcher must not fail a successful update (rc=$rc): $out"
  [ -L "$binG2b/himmelctl.js" ] || fail "caseG2b: broken symlink must be left intact (not clobbered)"
  grepq "$out" 'refusing to overwrite symlink' || fail "caseG2b: broken-symlink refusal message absent: $out"
  grepq "$out" 'WARN: update succeeded' || fail "caseG2b: launcher-failure WARN absent: $out"
  echo "ok: caseG2b broken (dangling) symlink destination refused (intact); update rc stays 0 + WARN"
else
  echo "ok: caseG2b broken-symlink refusal SKIPPED (host 'ln -s' produced no real symlink — e.g. MSYS without winsymlinks:nativestrict)"
fi

# G3: a MARKED file is replaced in place (re-pointed); marker preserved.
fixG3="$work/caseG3-checkout"; binG3="$work/caseG3-bin"; mkdir -p "$binG3"
build_update_fixture "$fixG3"
cat > "$binG3/himmelctl.js" <<'STUB'
'use strict';
// generated by himmelctl (HIMMEL-1446)
require('/old/target/himmelctl.js');
STUB
out=$(run_update "$fixG3" "$binG3" linux "$(winpath "$binG3"):$PATH"); rc=$?
[ "$rc" -eq 0 ] || fail "caseG3: marked file should be replaced (rc=$rc): $out"
grepq "$(cat "$binG3/himmelctl.js")" 'caseG3-checkout' \
  || fail "caseG3: marked loader was not re-pointed to this checkout"
grepq "$(cat "$binG3/himmelctl.js")" 'generated by himmelctl (HIMMEL-1446)' \
  || fail "caseG3: replacement loader lost the ownership marker"
grepq "$(cat "$binG3/himmelctl")" 'generated by himmelctl (HIMMEL-1446)' \
  || fail "caseG3: replacement wrapper lost the ownership marker"
echo "ok: caseG3 marked file replaced in place (re-pointed), marker preserved"

# G4a: a successful write leaves no orphaned tmp (rename always completes).
fixG4="$work/caseG4-checkout"; binG4="$work/caseG4-bin"
build_update_fixture "$fixG4"
run_update "$fixG4" "$binG4" linux "$(winpath "$binG4"):$PATH" >/dev/null
tmpcount=$(find "$binG4" -name '.*.tmp' 2>/dev/null | wc -l | tr -d ' ')
[ "$tmpcount" -eq 0 ] || fail "caseG4a: successful write left an orphaned tmp file"
echo "ok: caseG4a successful write leaves no orphaned tmp"

# G4b: a failed write leaves the existing marked dest untouched (no partial).
# POSIX-native only: 'chmod a-w' reliably denies node's file creation on
# Linux/macOS; on MSYS/Cygwin chmod is a no-op against NTFS ACLs, so the failure
# can't be injected there — skip with a note. The update engine succeeded, so a
# failed launcher write keeps rc 0 + WARN (HIMMEL-1446 r4 glm-5); the dest-
# untouched guarantee is the part this case actually locks.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "ok: caseG4b partial-on-failure SKIPPED (chmod is a no-op on MSYS/NTFS — can't inject a write failure)"
    ;;
  *)
    fixG4b="$work/caseG4b-checkout"; binG4b="$work/caseG4b-bin"; mkdir -p "$binG4b"
    build_update_fixture "$fixG4b"
    cat > "$binG4b/himmelctl.js" <<'STUB'
'use strict';
// generated by himmelctl (HIMMEL-1446)
require('/old/target');
STUB
    marked_before=$(cat "$binG4b/himmelctl.js")
    chmod a-w "$binG4b"
    out=$(run_update "$fixG4b" "$binG4b" linux "$(winpath "$binG4b"):$PATH"); rc=$?
    chmod u+w "$binG4b"   # restore so the EXIT trap's rm -rf can clean up
    [ "$rc" -eq 0 ] || fail "caseG4b: a failed launcher write must not fail a successful update (rc=$rc): $out"
    [ "$(cat "$binG4b/himmelctl.js")" = "$marked_before" ] \
      || fail "caseG4b: a failed write must leave the existing marked dest untouched (no partial)"
    grepq "$out" 'WARN: update succeeded' || fail "caseG4b: launcher-failure WARN absent: $out"
    echo "ok: caseG4b failed write leaves the marked dest untouched (no partial); update rc stays 0 + WARN"
    ;;
esac

# G5: a stale MARKED .ps1 is removed on a win32 update; an unmarked .ps1 is kept.
fixG5m="$work/caseG5-marked"; binG5m="$work/caseG5m-bin"; mkdir -p "$binG5m"
build_update_fixture "$fixG5m"
printf '# generated by himmelctl (HIMMEL-1446)\nstale\n' > "$binG5m/himmelctl.ps1"
run_update "$fixG5m" "$binG5m" win32 "$(winpath "$binG5m"):$PATH" >/dev/null
[ ! -e "$binG5m/himmelctl.ps1" ] || fail "caseG5: stale MARKED .ps1 should be removed on win32 update"
fixG5u="$work/caseG5-unmarked"; binG5u="$work/caseG5u-bin"; mkdir -p "$binG5u"
build_update_fixture "$fixG5u"
printf 'third-party ps1\n' > "$binG5u/himmelctl.ps1"
run_update "$fixG5u" "$binG5u" win32 "$(winpath "$binG5u"):$PATH" >/dev/null
[ -f "$binG5u/himmelctl.ps1" ] || fail "caseG5: unmarked .ps1 must NOT be removed"
[ "$(cat "$binG5u/himmelctl.ps1")" = 'third-party ps1' ] || fail "caseG5: unmarked .ps1 was mutated"
echo "ok: caseG5 stale marked .ps1 removed; unmarked .ps1 left untouched"

# G6: a stale-.ps1 REMOVAL error does not fail the shim write or misattribute
# (HIMMEL-1446 r4 glm-4). removeMarkedLauncher('himmelctl.ps1') runs inside the
# shim's write step; pre-fix its I/O errors were caught by the surrounding
# try/catch and reported as "failed to write PATH launcher" + a failed rc, even
# though the .js/.cmd launchers HAD already been written. A directory named
# himmelctl.ps1 injects the removal error hermetically (readFileSync on a
# directory throws EISDIR inside fileCarriesMarker) on every platform. The fix
# gives the removal its own try/catch: WARN accurately + keep rc 0 + launchers
# present.
fixG6="$work/caseG6-checkout"; binG6="$work/caseG6-bin"; mkdir -p "$binG6"
build_update_fixture "$fixG6"
mkdir "$binG6/himmelctl.ps1"   # a directory at the .ps1 name -> removeMarkedLauncher throws EISDIR
out=$(run_update "$fixG6" "$binG6" win32 "$(winpath "$binG6"):$PATH"); rc=$?
[ "$rc" -eq 0 ] || fail "caseG6: a stale-.ps1 removal error must not fail the shim write (rc=$rc): $out"
[ -f "$binG6/himmelctl.js" ] || fail "caseG6: himmelctl.js should be written despite the .ps1 removal error"
[ -f "$binG6/himmelctl.cmd" ] || fail "caseG6: himmelctl.cmd should be written despite the .ps1 removal error"
grepq "$out" 'could not remove stale launcher' || fail "caseG6: accurate stale-.ps1 WARN absent: $out"
case "$out" in
  *"failed to write PATH launcher"*) fail "caseG6: removal error must NOT misattribute as 'failed to write PATH launcher': $out" ;;
esac
echo "ok: caseG6 stale-.ps1 removal error WARNs accurately, never fails/misattributes the shim write"

# ── H: launcher binds to the PRIMARY checkout, not the running worktree (Fix 2)
# A real git fixture: install from a linked worktree must target the PRIMARY
# root; install from a non-worktree primary targets itself (unchanged).

# H1: linked worktree — loader targets the primary, never the worktree.
primaryH="$work/caseH-primary"
mkdir -p "$primaryH"
build_update_fixture "$primaryH"
( cd "$primaryH" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init )
wtH="$work/caseH-worktree"
if git -C "$primaryH" worktree add -q "$wtH" 2>/dev/null; then
  binH1="$work/caseH1-bin"
  # repoRoot = the WORKTREE; the loader must target the PRIMARY checkout.
  run_update "$wtH" "$binH1" linux "$(winpath "$binH1"):$PATH" >/dev/null
  loader=$(cat "$binH1/himmelctl.js")
  grepq "$loader" 'caseH-primary' || fail "caseH1: worktree-installed loader must target the PRIMARY checkout"
  case "$loader" in *caseH-worktree*) fail "caseH1: loader must not target the disposable worktree ($loader)" ;; esac
  echo "ok: caseH1 linked-worktree install targets the PRIMARY checkout"
else
  echo "ok: caseH1 linked-worktree SKIPPED (git worktree add unavailable on this host)"
fi

# H2: non-worktree primary — loader targets repoRoot itself (unchanged).
primaryH2="$work/caseH2-repo"
mkdir -p "$primaryH2"
build_update_fixture "$primaryH2"
( cd "$primaryH2" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init )
binH2="$work/caseH2-bin"
run_update "$primaryH2" "$binH2" linux "$(winpath "$binH2"):$PATH" >/dev/null
grepq "$(cat "$binH2/himmelctl.js")" 'caseH2-repo' \
  || fail "caseH2: non-worktree install must target repoRoot (primary == self)"
echo "ok: caseH2 non-worktree primary install targets repoRoot unchanged"

echo "PASS"
