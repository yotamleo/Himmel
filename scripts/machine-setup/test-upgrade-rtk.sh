#!/usr/bin/env bash
# test-upgrade-rtk.sh — hermetic suite for upgrade-rtk.sh (HIMMEL-1323).
#
# Fully offline: a fake `rtk` script (embedding its own version literal, same
# fixture shape as scripts/upstreams/test-apply-drift-bump.sh's widget-bin.sh)
# stands in for the real binary. RTK_UPGRADE_PLATFORM forces the Linux
# backup/smoke/rollback code path regardless of the host OS this suite
# actually runs on (Windows Git-Bash included) and lets the "unsupported
# platform" branch be exercised without a real Mac. RTK_DOWNLOAD_CMD replaces
# the real curl+apt install step with a fixture "installer" script, so no
# network call and no real rtk install are ever touched.
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPGRADE="$SCRIPT_DIR/upgrade-rtk.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL + 1)); }

assert_rc() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    pass "$label (rc=$got)"
  else
    fail "$label" "expected rc=$want, got rc=$got"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label" "missing: $needle" ;;
  esac
}

TMP_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
RTK_FIXTURE="$BIN_DIR/rtk"
INSTALL_DIR="$TMP_ROOT/install-scratch"
FIX_DIR="$TMP_ROOT/installers"
mkdir -p "$FIX_DIR"

# write_fake_rtk <version> <ls-ok:0|1> — a self-contained fixture: the
# version is a literal baked into the script text itself (not read from a
# side-channel state file), so "restore the backup" is provably byte-for-byte
# recoverable by a plain file copy.
write_fake_rtk() {
  local version="$1" ls_ok="$2"
  cat > "$RTK_FIXTURE" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version) echo "rtk $version"; exit 0 ;;
  ls)
    if [ "$ls_ok" = "1" ]; then command ls "\$2" >/dev/null 2>&1; exit 0; fi
    exit 1
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$RTK_FIXTURE"
}

# ---------------------------------------------------------------------------
# installer fixtures (used via RTK_DOWNLOAD_CMD — the download/install seam)
# ---------------------------------------------------------------------------

# Success: writes a newer working fixture (ls probe ok) and stamps a marker
# so a test can prove whether it was actually invoked.
cat > "$FIX_DIR/install-ok.sh" <<'EOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/invoked-ok"
cat > "$RTK_BIN_PATH" <<'INNER'
#!/usr/bin/env bash
case "$1" in
  --version) echo "rtk 0.44.0"; exit 0 ;;
  ls) command ls "$2" >/dev/null 2>&1; exit 0 ;;
  *) exit 1 ;;
esac
INNER
chmod +x "$RTK_BIN_PATH"
EOF
chmod +x "$FIX_DIR/install-ok.sh"

# Simulated failed smoke test: --version correctly reports a newer build, but
# the functional probe (`rtk ls <tmpdir>`) always fails -- exercises the
# smoke-test-fails-not-install-fails branch specifically.
cat > "$FIX_DIR/install-smoke-fail-ls.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$RTK_BIN_PATH" <<'INNER'
#!/usr/bin/env bash
case "$1" in
  --version) echo "rtk 0.44.0"; exit 0 ;;
  ls) exit 1 ;;
  *) exit 1 ;;
esac
INNER
chmod +x "$RTK_BIN_PATH"
EOF
chmod +x "$FIX_DIR/install-smoke-fail-ls.sh"

# The install step itself fails outright (e.g. apt/network failure) --
# $RTK_BIN_PATH is never touched.
cat > "$FIX_DIR/install-cmd-fail.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FIX_DIR/install-cmd-fail.sh"

reset_fixture() {
  rm -rf "$INSTALL_DIR"
  rm -f "$FIX_DIR/invoked-ok"
  write_fake_rtk "0.43.0" "1"
}

echo "[test-upgrade-rtk] --dry-run changes nothing"
reset_fixture
before="$(cat "$RTK_FIXTURE")"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0 bash "$UPGRADE" --dry-run 2>&1); rc=$?
assert_rc "dry-run exits 0" 0 "$rc"
assert_contains "dry-run reports current version" "0.43.0" "$out"
assert_contains "dry-run reports target version" "0.44.0" "$out"
after="$(cat "$RTK_FIXTURE")"
if [ "$before" = "$after" ]; then pass "dry-run left the fixture byte-identical"; else fail "dry-run modified the fixture"; fi
if [ -e "$INSTALL_DIR/rtk.pre-upgrade.bak" ]; then fail "dry-run created a backup file"; else pass "dry-run created no backup file"; fi

echo "[test-upgrade-rtk] unknown flag is a usage error (rc=2), nothing touched"
reset_fixture
before="$(cat "$RTK_FIXTURE")"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux bash "$UPGRADE" --bogus 2>&1); rc=$?
assert_rc "unknown flag -> rc 2" 2 "$rc"
after="$(cat "$RTK_FIXTURE")"
if [ "$before" = "$after" ]; then pass "unknown flag left the fixture untouched"; else fail "unknown flag modified the fixture"; fi

echo "[test-upgrade-rtk] missing rtk -> rc 2 (upgrader, not an installer)"
reset_fixture
out=$(env RTK_UPGRADE_PLATFORM=linux RTK_BIN=rtk-does-not-exist-xyz bash "$UPGRADE" 2>&1); rc=$?
assert_rc "no rtk installed -> rc 2" 2 "$rc"
assert_contains "message names 'not installed'" "is not installed" "$out"
assert_contains "message says upgrader-not-installer" "upgrader, not an installer" "$out"

echo "[test-upgrade-rtk] unsupported platform -> rc 2"
reset_fixture
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=macos bash "$UPGRADE" 2>&1); rc=$?
assert_rc "macos -> rc 2" 2 "$rc"
assert_contains "macos message says unsupported" "unsupported" "$out"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=some-other-os bash "$UPGRADE" 2>&1); rc=$?
assert_rc "unrecognized platform -> rc 2" 2 "$rc"

echo "[test-upgrade-rtk] already current -- no download attempted, rc 0"
reset_fixture
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.43.0 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-ok.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "same version -> rc 0" 0 "$rc"
assert_contains "already-current message" "already current" "$out"
# The marker path must match what install-ok.sh actually writes (CR codex-2):
# the fixture used to stamp "$(dirname $0)/../invoked-ok" — one level ABOVE
# $FIX_DIR — while this checked inside it, so the assertion could never fail and
# silently proved nothing. A negative assertion that cannot fail is worse than
# no assertion: it reads as coverage. Guard against the paths drifting apart
# again by proving the marker CAN appear before trusting its absence.
if [ -e "$FIX_DIR/invoked-ok" ]; then
  fail "install step ran despite already being current"
else
  pass "install step never invoked when already current"
fi
# Self-check the assertion above is live: run the same fixture directly and
# confirm it lands the marker where this test looks for it.
bash "$FIX_DIR/install-ok.sh" >/dev/null 2>&1 || true
if [ -e "$FIX_DIR/invoked-ok" ]; then
  pass "invoked-ok marker lands where the assertion looks (assertion is live)"
else
  fail "invoked-ok marker path mismatch — the 'never invoked' assertion is vacuous"
fi
rm -f "$FIX_DIR/invoked-ok"

echo "[test-upgrade-rtk] malformed release tag -> rc 2, no install attempted"
reset_fixture
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=latest RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-ok.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "malformed target tag -> rc 2" 2 "$rc"
assert_contains "malformed target tag is rejected explicitly" "invalid release tag" "$out"
if [ -e "$FIX_DIR/invoked-ok" ]; then
  fail "install step ran for a malformed target tag"
else
  pass "install step never invoked for a malformed target tag"
fi

echo "[test-upgrade-rtk] curl calls to GitHub carry a timeout (CR: an unattended cadence must fail fast, not hang)"
SRC="$(cat "$UPGRADE")"
case "$SRC" in
  *'curl -s --max-time '*'https://api.github.com/repos/rtk-ai/rtk/releases/latest'*) pass "release-tag lookup passes --max-time" ;;
  *) fail "release-tag lookup curl call is missing --max-time" ;;
esac
case "$SRC" in
  *'curl -fL --max-time '*'/releases/download/'*) pass "the .deb download passes --max-time" ;;
  *) fail "the .deb download curl call is missing --max-time" ;;
esac

echo "[test-upgrade-rtk] PowerShell twin fails closed on cmdlet and backup errors"
PS1_TWIN="$SCRIPT_DIR/upgrade-rtk.ps1"
PS1_SRC="$(cat "$PS1_TWIN")"
# PowerShell source literals must not expand as Bash variables.
# shellcheck disable=SC2016
case "$PS1_SRC" in
  *'Invoke-WebRequest $RtkUrl -OutFile $RtkZipPath -TimeoutSec 60 -ErrorAction Stop'*) pass "PowerShell download errors terminate into the handler" ;;
  *) fail "PowerShell Invoke-WebRequest is missing -ErrorAction Stop" ;;
esac
# shellcheck disable=SC2016
case "$PS1_SRC" in
  *'Expand-Archive -Path $RtkZipPath -DestinationPath $RtkLiveDir -Force -ErrorAction Stop'*) pass "PowerShell extraction errors terminate into rollback" ;;
  *) fail "PowerShell Expand-Archive is missing -ErrorAction Stop" ;;
esac
BACKUP_GUARD=$(cat <<'EOF'
try {
    New-Item -ItemType Directory -Force $InstallDir -ErrorAction Stop | Out-Null
    $BackupPath = Join-Path $InstallDir 'rtk.pre-upgrade.bak'
    Copy-Item -Force $RtkBinPath $BackupPath -ErrorAction Stop
    if (-not (Test-Path $BackupPath)) {
        throw "backup file was not created"
    }
} catch {
EOF
)
case "$PS1_SRC" in
  *"$BACKUP_GUARD"*) pass "PowerShell backup setup is guarded, terminating, and verified" ;;
  *) fail "PowerShell backup setup does not match the fail-closed guarded block" ;;
esac
# CR glm-3: the backup/restore must operate on the rtk BINARY, never on its
# parent directory ($RtkLiveDir), which other tools can share. A recursive
# delete of that shared directory is exactly the destructive shape this guard
# rejects, regardless of which line it appears on.
# shellcheck disable=SC2016
case "$PS1_SRC" in
  *'Remove-Item -Recurse -Force $RtkLiveDir'*) fail 'PowerShell script recursively deletes the shared parent directory ($RtkLiveDir)' ;;
  *) pass "PowerShell script never recursively deletes the shared parent directory" ;;
esac
# shellcheck disable=SC2016
case "$PS1_SRC" in
  *'if (-not [regex]::IsMatch($TargetVersion, "^$VersionRegex$")) {'*) pass "PowerShell rejects malformed normalized target tags" ;;
  *) fail "PowerShell target version lacks strict VersionRegex validation" ;;
esac

echo "[test-upgrade-rtk] PowerShell twin: forced rollback failure must NOT touch a sibling file in the shared bin dir (CR glm-3, PARENT-VERIFIED)"
PS_BIN=""
for c in pwsh pwsh.exe powershell.exe; do
  if command -v "$c" >/dev/null 2>&1; then PS_BIN="$c"; break; fi
done
# Same platform-detection idiom as upgrade-rtk.sh's _platform(). pwsh ships
# preinstalled on GitHub's ubuntu runners, so a bare `command -v pwsh` check
# alone would still fire this block on Linux CI -- but the fixtures below are
# cmd.exe-native (.cmd batch files, `rd /s /q`) and only run for real under
# Windows pwsh, so gate on actually-Windows too.
IS_WINDOWS=0
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
  msys*|cygwin*|win32*|MINGW*|MSYS*) IS_WINDOWS=1 ;;
esac
if [ -z "$PS_BIN" ]; then
  echo "  SKIP: no pwsh/powershell.exe on PATH -- cannot execute the .ps1 twin"
elif [ "$IS_WINDOWS" -ne 1 ]; then
  echo "  SKIP: not running on Windows (OSTYPE=${OSTYPE:-unknown}) -- the .cmd fixtures below are cmd.exe-native and cannot run under pwsh on Linux/macOS"
else
  WIN_BIN_DIR="$TMP_ROOT/win-bin"
  WIN_INSTALL_DIR="$TMP_ROOT/win-install"
  WIN_FIX_DIR="$TMP_ROOT/win-fixtures"
  mkdir -p "$WIN_BIN_DIR" "$WIN_FIX_DIR" "$WIN_INSTALL_DIR"

  # Fake rtk.cmd -- a self-contained Windows-native fixture Get-Command can
  # resolve (version 0.43.0, ls succeeds).
  cat > "$WIN_BIN_DIR/rtk.cmd" <<'EOF'
@echo off
if "%1"=="--version" (
  echo rtk 0.43.0
  exit /b 0
)
if "%1"=="ls" (
  exit /b 0
)
exit /b 1
EOF
  # A sibling file standing in for another tool that shares the same bin
  # directory (scripts/upstreams.json's rtk note: "Installed binary at
  # ~/.local/bin/rtk" -- a directory twitter-cli et al also install into).
  SIBLING="$WIN_BIN_DIR/twitter-cli.cmd"
  echo "sibling tool payload" > "$SIBLING"

  # Invoked via RTK_DOWNLOAD_CMD, this fixture simulates the worst case the
  # review flagged: the pre-upgrade backup becomes unusable AND the new
  # binary is broken, so the smoke test fails AND the subsequent restore
  # fails too. This is the one scenario where a directory-level and a
  # file-level backup/restore actually diverge -- when the restore succeeds,
  # both approaches put the sibling right back, so only a restore-failure run
  # proves anything about the blast radius of a failed rollback.
  cat > "$WIN_FIX_DIR/break-and-nuke-backup.cmd" <<'EOF'
@echo off
rd /s /q "%RTK_INSTALL_DIR%" 2>nul
(
  echo @echo off
  echo exit /b 1
)>"%RTK_BIN_PATH%"
EOF

  # Driver: sets up PATH + env vars inside a real pwsh process (so PATH
  # resolution and env passthrough to the nested cmd.exe /c call are genuine,
  # not simulated) and invokes the actual .ps1 twin under test.
  cat > "$TMP_ROOT/win-driver.ps1" <<'EOF'
param([string]$BinDir, [string]$InstallDir, [string]$BreakCmd, [string]$Twin)
$env:PATH = "$BinDir;$env:PATH"
$env:RTK_INSTALL_DIR = $InstallDir
$env:RTK_LATEST_TAG = 'v0.44.0'
$env:RTK_DOWNLOAD_CMD = $BreakCmd
& $Twin
exit $LASTEXITCODE
EOF

  out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$TMP_ROOT/win-driver.ps1" \
    -BinDir "$WIN_BIN_DIR" -InstallDir "$WIN_INSTALL_DIR" \
    -BreakCmd "$WIN_FIX_DIR/break-and-nuke-backup.cmd" \
    -Twin "$PS1_TWIN" 2>&1); rc=$?
  assert_rc "forced-restore-failure run -> rc 4" 4 "$rc"
  assert_contains "output announces ROLLBACK FAILED" "ROLLBACK FAILED" "$out"
  if [ -e "$SIBLING" ]; then
    pass "sibling file in the shared bin dir SURVIVED the forced rollback failure"
  else
    fail "sibling file in the shared bin dir was WIPED by the forced rollback failure" "$out"
  fi
  if [ -e "$WIN_INSTALL_DIR.lock" ]; then
    fail "lock left behind after a failed (forced-rollback) .ps1 run"
  else
    pass "lock released after a failed (forced-rollback) .ps1 run"
  fi

  echo "[test-upgrade-rtk] PowerShell twin: a held lock refuses fast (rc=3), touches nothing (CR round 4)"
  # The prior forced-rollback test's fixture overwrites rtk.cmd itself with a
  # broken "always exit 1" stub as part of its own scenario -- restore the
  # working fixture before reusing WIN_BIN_DIR here.
  cat > "$WIN_BIN_DIR/rtk.cmd" <<'EOF'
@echo off
if "%1"=="--version" (
  echo rtk 0.43.0
  exit /b 0
)
if "%1"=="ls" (
  exit /b 0
)
exit /b 1
EOF
  WIN_LOCK_DIR="$WIN_INSTALL_DIR.lock"
  mkdir -p "$WIN_LOCK_DIR"
  printf 'pid=999999\nhost=held-by-this-test\nstarted=%s\n' "$(date +%s)" > "$WIN_LOCK_DIR/owner"
  before="$(cat "$WIN_BIN_DIR/rtk.cmd")"
  out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$TMP_ROOT/win-driver.ps1" \
    -BinDir "$WIN_BIN_DIR" -InstallDir "$WIN_INSTALL_DIR" \
    -BreakCmd "$WIN_FIX_DIR/break-and-nuke-backup.cmd" \
    -Twin "$PS1_TWIN" 2>&1); rc=$?
  assert_rc "lock held -> rc 3" 3 "$rc"
  # Not the exact lock path: MSYS auto-converts a POSIX-style argument when it
  # crosses into a native pwsh.exe process, so the path string PowerShell sees
  # (and echoes) differs textually from $WIN_LOCK_DIR even though it names the
  # same directory (same idiom the sibling ROLLBACK FAILED assertion above
  # uses -- assert stable message text, not a path rendering).
  assert_contains "lock-held message explains the refusal" "already holds the lock" "$out"
  after="$(cat "$WIN_BIN_DIR/rtk.cmd")"
  if [ "$before" = "$after" ]; then
    pass "held lock left the live rtk.cmd untouched"
  else
    fail "held lock did NOT prevent the live binary from being modified"
  fi
  if [ -e "$WIN_INSTALL_DIR/rtk.pre-upgrade.bak" ]; then
    fail "held lock did NOT prevent a backup from being written"
  else
    pass "held lock left no backup file"
  fi
  rm -rf "$WIN_LOCK_DIR"
fi

echo "[test-upgrade-rtk] concurrency lock: a held lock refuses fast (rc=3), touches nothing (CR round 4)"
reset_fixture
LOCK_DIR="$INSTALL_DIR.lock"
mkdir -p "$LOCK_DIR"
printf 'pid=%s\nhost=held-by-this-test\nstarted=%s\n' "$$" "$(date +%s)" > "$LOCK_DIR/owner"
before="$(cat "$RTK_FIXTURE")"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-ok.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "lock held -> rc 3" 3 "$rc"
assert_contains "lock-held message names the lock path" "$LOCK_DIR" "$out"
after="$(cat "$RTK_FIXTURE")"
if [ "$before" = "$after" ]; then pass "held lock left the live binary untouched"; else fail "held lock did NOT prevent the live binary from being overwritten"; fi
if [ -e "$INSTALL_DIR/rtk.pre-upgrade.bak" ]; then fail "held lock did NOT prevent a backup from being written"; else pass "held lock left no backup file"; fi
if [ -e "$FIX_DIR/invoked-ok" ]; then fail "held lock did NOT prevent the install step from running"; else pass "held lock never invoked the install step"; fi
rm -rf "$LOCK_DIR"

echo "[test-upgrade-rtk] is_newer ignores a suffix (CR: was sort -V, diverged from the .ps1 twin)"
reset_fixture
write_fake_rtk "0.44.0" "1"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0-rc1 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-ok.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "suffixed target vs same plain installed version -> rc 0 (no upgrade)" 0 "$rc"
assert_contains "treats 0.44.0-rc1 and 0.44.0 as the same leading version" "already current" "$out"
if [ -e "$FIX_DIR/invoked-ok" ]; then
  fail "install step ran even though the leading dotted-numeric run was unchanged"
else
  pass "install step never invoked for a suffix-only difference"
fi
rm -f "$FIX_DIR/invoked-ok"

echo "[test-upgrade-rtk] simulated failed smoke test -> rc 4, backup restored byte-identical"
reset_fixture
original="$(cat "$RTK_FIXTURE")"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-smoke-fail-ls.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "failed functional probe -> rc 4" 4 "$rc"
assert_contains "output announces rollback" "ROLLED BACK" "$out"
restored="$(cat "$RTK_FIXTURE")"
if [ "$restored" = "$original" ]; then
  pass "fixture restored byte-identical to the pre-upgrade original"
else
  fail "fixture NOT byte-identical after rollback"
fi
if [ -e "$INSTALL_DIR/rtk.pre-upgrade.bak" ]; then
  pass "backup file left in the install scratch dir"
else
  fail "no backup file found in the install scratch dir"
fi
post_version=$("$RTK_FIXTURE" --version 2>&1)
assert_contains "restored fixture reports the original version again" "0.43.0" "$post_version"
if [ -e "$INSTALL_DIR.lock" ]; then
  fail "lock left behind after a failed (rolled-back) run"
else
  pass "lock released after a failed (rolled-back) run"
fi

echo "[test-upgrade-rtk] install step itself failing -> rc 4, fixture untouched (never replaced)"
reset_fixture
original="$(cat "$RTK_FIXTURE")"
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-cmd-fail.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "install command failure -> rc 4" 4 "$rc"
restored="$(cat "$RTK_FIXTURE")"
if [ "$restored" = "$original" ]; then
  pass "fixture unchanged when the install step itself failed"
else
  fail "fixture was modified despite the install step failing"
fi

echo "[test-upgrade-rtk] happy path -- rc 0, version bumped, backup left behind"
reset_fixture
out=$(env PATH="$BIN_DIR:$PATH" RTK_UPGRADE_PLATFORM=linux RTK_INSTALL_DIR="$INSTALL_DIR" \
      RTK_LATEST_TAG=v0.44.0 RTK_DOWNLOAD_CMD="bash '$FIX_DIR/install-ok.sh'" \
      bash "$UPGRADE" 2>&1); rc=$?
assert_rc "happy path -> rc 0" 0 "$rc"
assert_contains "success line reports the version bump" "0.43.0 -> 0.44.0" "$out"
new_version=$("$RTK_FIXTURE" --version 2>&1)
assert_contains "fixture now reports the new version" "0.44.0" "$new_version"

echo ""
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
