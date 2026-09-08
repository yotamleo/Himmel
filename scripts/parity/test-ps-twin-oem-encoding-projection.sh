#!/usr/bin/env bash
# HIMMEL-2743/2803: run the real OEM guard in disposable private/public trees.
# Projected generators now converge and stay checked; synthetic preserved-path
# cases retain marker/path gating and preserve-list drift controls. Archive files
# remain out of scope. bash 3.2-safe; discovered by run-shell-tests.sh.
# Platform guard: pure Bash structural fixtures run in Git Bash on Windows;
# pwsh behavioural coverage belongs to test-ps-twin-oem-encoding.ps1 instead.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUITE=scripts/parity/test-ps-twin-oem-encoding.sh
TMP="$(mktemp -d "${TMPDIR:-/tmp}/oem-projection.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
FIXLINE='[Console]::OutputEncoding = [System.Text.Encoding]::UTF8'

# Keep the genuine fingerprint fixtures, but build the counted fleet ourselves
# so new twins in the checkout cannot mask a floor regression in this test.
mkdir -p "$TMP/base/scripts/parity" "$TMP/base/scripts/lib" "$TMP/bin"
cp "$REPO/$SUITE" "$TMP/base/$SUITE"
while IFS= read -r path; do
  mkdir -p "$TMP/base/$(dirname "$path")"
  cp "$REPO/$path" "$TMP/base/$path"
done < <(sed -n 's/^  "\([^|]*\.ps1\)|.*/\1/p' "$REPO/$SUITE")
printf '%s\n' 'SNAPSHOT_PRESERVE="LICENSE"' > "$TMP/base/scripts/lib/public-clone-paths.sh"
# Exercise the real converging artifact: private checkouts derive the bounded
# scrubbed projection; public checkouts already carry that projected source.
if [ -f "$REPO/scripts/lib/public-clone-paths.sh" ]; then
  # shellcheck source=../lib/public-clone-paths.sh
  # shellcheck disable=SC1091
  . "$REPO/scripts/lib/public-clone-paths.sh"
  strip_public_scrub_blocks "$REPO/scripts/gen-changelog.ps1" "$TMP/base/scripts/gen-changelog.ps1"
else
  cp "$REPO/scripts/gen-changelog.ps1" "$TMP/base/scripts/gen-changelog.ps1"
fi
# The stdin exemption test-onboard-telegram.ps1 already contributes one fix.
# 55 generated twins + that exemption + converging gen-changelog = 57 fixes.
for ((i=1; i<=55; i++)); do
  printf '%s\n' "$FIXLINE" > "$TMP/base/scripts/fixed-$i.ps1"
done
# These are structural controls only. Hide pwsh rather than executing copied
# behavioural fixtures (which require a real subject twin and Windows console).
for tool in bash dirname git grep sort cut sed head awk sha256sum shasum openssl; do
  resolved="$(command -v "$tool" || true)"
  [ -z "$resolved" ] || ln -s "$resolved" "$TMP/bin/$tool"
done

new_case() {
  CASE="$TMP/$1"
  cp -R "$TMP/base" "$CASE"
  git -C "$CASE" init -q
  git -C "$CASE" add -- scripts
}

use_synthetic_preserved_path() {
  sed 's/^SNAPSHOT_PRESERVED_PS1=()$/SNAPSHOT_PRESERVED_PS1=(scripts\/fixed-55.ps1)/' \
    "$CASE/$SUITE" > "$CASE/suite.tmp"
  mv "$CASE/suite.tmp" "$CASE/$SUITE"
  printf '%s\n' 'SNAPSHOT_PRESERVE="LICENSE scripts/fixed-55.ps1"' \
    > "$CASE/scripts/lib/public-clone-paths.sh"
}

run_case() {
  local label="$1" want="$2" message="$3" rc=0
  PATH="$TMP/bin" bash "$CASE/$SUITE" > "$CASE/output" 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ] && grep -Fq -- "$message" "$CASE/output"; then
    printf 'ok: %s\n' "$label"
  else
    printf 'FAIL: %s (expected rc=%s and %s; got rc=%s)\n' "$label" "$want" "$message" "$rc" >&2
    cat "$CASE/output" >&2
    FAIL=$((FAIL + 1))
  fi
}

new_case private-clean
run_case 'private shipped fleet meets the floor' 0 '57 .ps1 file(s) carry the fix line (floor 57)'

new_case projected-clean
: > "$CASE/.himmel-public-projection"
rm "$CASE/scripts/lib/public-clone-paths.sh"
run_case 'projected converging generator remains counted' 0 '57 .ps1 file(s) carry the fix line (floor 57)'

# A projection marker must not exempt the newly converging generator.
# shellcheck disable=SC2016  # literal PowerShell, not shell expansion
printf '%s\n' '$text = git log --format=%s' > "$CASE/scripts/gen-changelog.ps1"
run_case 'projected converging generator still enforces OEM capture safety' 1 'FAIL: scripts/gen-changelog.ps1 captures native stdout'

new_case projected-other
: > "$CASE/.himmel-public-projection"
# shellcheck disable=SC2016
printf '%s\n' '$text = git log --format=%s' > "$CASE/scripts/fixed-1.ps1"
run_case 'marker does not exempt ordinary twins' 1 'FAIL: scripts/fixed-1.ps1 captures native stdout'

new_case archive-floor
mkdir -p "$CASE/archive"
mv "$CASE/scripts/fixed-1.ps1" "$CASE/archive/fixed.ps1"
git -C "$CASE" add -- scripts/fixed-1.ps1 archive/fixed.ps1
run_case 'archive fix cannot satisfy shipped floor' 1 'only 56 .ps1 file(s) carry the HIMMEL-2256 fix line, floor is 57'

new_case archive-detector
mkdir -p "$CASE/archive"
# shellcheck disable=SC2016
printf '%s\n' '$text = git log --format=%s' > "$CASE/archive/retired.ps1"
git -C "$CASE" add -- archive/retired.ps1
run_case 'retired archive captures are outside the scan' 0 '57 .ps1 file(s) carry the fix line (floor 57)'

# Preserve mechanics remain covered with a synthetic path, without restoring
# gen-changelog.ps1's retired classification.
new_case preserved-capture
use_synthetic_preserved_path
: > "$CASE/.himmel-public-projection"
# shellcheck disable=SC2016
printf '%s\n' '$text = git log --format=%s' > "$CASE/scripts/fixed-55.ps1"
run_case 'projected synthetic preserved capture is exempt' 0 '56 .ps1 file(s) carry the fix line (floor 56)'
rm "$CASE/.himmel-public-projection"
run_case 'same synthetic preserved capture without marker is not exempt' 1 'FAIL: scripts/fixed-55.ps1 captures native stdout'

new_case preserved-fixed
use_synthetic_preserved_path
: > "$CASE/.himmel-public-projection"
run_case 'synthetic preserved assignment itself does not count' 0 '56 .ps1 file(s) carry the fix line (floor 56)'

new_case preserved-absent
use_synthetic_preserved_path
: > "$CASE/.himmel-public-projection"
rm "$CASE/scripts/fixed-55.ps1"
run_case 'absent preserved path does not reduce the floor' 1 'only 56 .ps1 file(s) carry the HIMMEL-2256 fix line, floor is 57'

new_case preserve-drift
use_synthetic_preserved_path
printf '%s\n' 'SNAPSHOT_PRESERVE="LICENSE scripts/fixed-55.ps1 scripts/another.ps1"' > "$CASE/scripts/lib/public-clone-paths.sh"
run_case 'private preserve-list drift fails loudly' 1 'FAIL: SNAPSHOT_PRESERVED_PS1'
: > "$CASE/.himmel-public-projection"
run_case 'private drift check does not run on projections' 0 '56 .ps1 file(s) carry the fix line (floor 56)'

# A preserved file may also appear in a reviewed-exemption table. An obsolete
# pin must be ignored only on projections, not weakened for ordinary twins.
new_case preserved-pin
use_synthetic_preserved_path
sed '/^EXEMPT_ENTRIES=(/a\
  "scripts/fixed-55.ps1|000000000000|projection fingerprint control"
' "$CASE/$SUITE" > "$CASE/suite.tmp"
mv "$CASE/suite.tmp" "$CASE/$SUITE"
: > "$CASE/.himmel-public-projection"
run_case 'projection skips preserved fingerprint pins' 0 '56 .ps1 file(s) carry the fix line (floor 56)'
rm "$CASE/.himmel-public-projection"
run_case 'private still checks preserved fingerprint pins' 1 'FAIL: scripts/fixed-55.ps1 is a reviewed exemption pinned'

if [ "$FAIL" -ne 0 ]; then
  printf 'FAIL: %s projection control(s)\n' "$FAIL" >&2
  exit 1
fi
printf 'OK: all projection controls passed\n'
