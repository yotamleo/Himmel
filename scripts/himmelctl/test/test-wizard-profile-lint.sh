#!/usr/bin/env bash
# test-wizard-profile-lint.sh — CI staleness/validation check for CHECKED-IN
# install-profile fixtures (HIMMEL-2308 part B item 4; mirrors the
# secrets-manifest CI-staleness precedent, HIMMEL-2176, and the
# test-wizard-manifest-v2.sh sibling-suite pattern in this same directory).
#
# docs/setup/profiles/*.install-profile.json is the agreed canonical location
# for hand-authored install-profile fixtures an operator can point
# --from-profile at (HIMMEL-2307 landed the operator profile there). This
# suite proves every file that ends up there actually validates against the
# REAL v2 schema bin.js's own loadProfile() enforces — never a hand-rolled
# duplicate of that schema that could silently drift from it.
#
# How the real validator is invoked: bin.js exports nothing (main() runs
# unconditionally on load, so `require`-ing it as a module would execute the
# CLI against this test's own argv) and there is no separate profile-lint
# entrypoint. `loadProfile()` already runs as literally the FIRST thing
# `install --from-profile <path>` does (bin.js's own cmdInstall step 0, before
# any side effect — see its comment: "load + validate the FULL schema BEFORE
# any side effect"), so `node bin.js install --dry-run --from-profile <path>`
# invokes the real validator with zero code changes to bin.js: rc=2 + a
# per-field message means the profile is rejected, rc=0 means it validated
# AND the rest of the (side-effect-free, --dry-run) preview completed. This
# can never drift from the real validator because it *is* the real validator.
#
# Covers:
#   a. POSITIVE CONTROL (HIMMEL-2320, mandatory): a hand-built valid v2
#      profile fixture -> rc=0.
#   b. POSITIVE CONTROL: a hand-built v2 profile with one bad enum field
#      -> rc=2, message naming the bad field. Cases a+b together prove the
#      harness's invocation actually runs a real, discriminating validator —
#      a suite that only ever saw rc=0 would pass just as "green" if the
#      invocation were silently a no-op.
#   c. every real docs/setup/profiles/*.install-profile.json in this checkout
#      (today: operator.install-profile.json, landed by HIMMEL-2307) lints
#      clean via the SAME invocation as cases a/b. The empty-glob vacuous-pass
#      path stays in the harness BY DESIGN — case a/b already prove the
#      invocation isn't vacuous in general, and an empty directory should
#      never fail this suite — it just isn't exercised while a real fixture
#      is checked in.

set -euo pipefail

# grepq <text> [grep-args...] — see test-wizard-manifest-v2.sh's own comment
# for why this (not a piped `grep -q`) is required under `set -o pipefail`.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

export HIMMELCTL_BASH=bash

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/profile-lint.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

HIMMELCTL_BIN_DIR="$(winpath "$work/isolated-bin")"
export HIMMELCTL_BIN_DIR

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

make_git_stub() {
  local _d="$1" _url="$2"
  cat > "$_d/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "remote" ] && [ "\$2" = "get-url" ] && [ "\$3" = "origin" ]; then
  printf '%s\n' "$_url"
  exit 0
fi
exit 0
STUB
  chmod +x "$_d/git"
}

# make_fixture <dir> — a throwaway HIMMELCTL_REPO_ROOT with a no-op adopt.sh
# and a copy of the real lane registry, same shape as the sibling suites'
# own make_fixture() (test-wizard-adopter-profile.sh) — needed because
# --dry-run install still walks the full preview path (lane probing,
# plan derivation), not just loadProfile() itself.
make_fixture() {
  local _d="$1"
  mkdir -p "$_d/scripts/lanes"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_d/scripts/adopt.sh"
  chmod +x "$_d/scripts/adopt.sh"
  cp "$repo_root/scripts/lanes/lanes.json" "$_d/scripts/lanes/lanes.json"
  # HIMMEL-2308: a checked-in profile may carry devOverlay:true (the operator
  # profile does) — bin.js's step-5.5 gate then requires the dev-overlay
  # primitive to exist, so the fixture must look like a real himmel checkout
  # on either platform (same setup.sh/setup.ps1 stub pair as the sibling
  # suite's own make_fixture(), test-wizard-contributor-profile.sh).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_d/scripts/setup.sh"
  chmod +x "$_d/scripts/setup.sh"
  cat > "$_d/scripts/setup.ps1" <<'STUB'
& bash (Join-Path $PSScriptRoot 'setup.sh')
exit $LASTEXITCODE
STUB
}

fixture="$work/fixture"
make_fixture "$fixture"

# lint_profile <path> — run the profile through the REAL v2 validator via
# `install --dry-run --from-profile`. Echoes combined output, returns rc.
lint_profile() {
  local _profile="$1"
  local _stub="$work/lint-stub-$RANDOM"; mkdir -p "$_stub"
  local _home="$work/lint-home-$RANDOM"; mkdir -p "$_home"
  local _p
  _p=$(build_path "$_stub" bash jq python3 npm --)
  make_git_stub "$_stub" "https://github.com/someone/other-repo.git"
  PATH="$_p" HOME="$_home" USERPROFILE="$(winpath "$_home")" HIMMELCTL_CACHE_DIR="$(winpath "$_home.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$_home.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_REPO_ROOT="$(winpath "$fixture")" \
    "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$_profile")" \
    </dev/null 2>&1
}

# ── case a (POSITIVE CONTROL): a valid v2 profile lints clean ──────────────
validProfile="$work/valid.install-profile.json"
cat > "$validProfile" <<'JSON'
{
  "schemaVersion": 2,
  "profile": "starter",
  "devOverlay": false,
  "tier": "standard",
  "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON
set +e
outA=$(lint_profile "$validProfile"); rcA=$?
set -e
[ "$rcA" -eq 0 ] || fail "case a: a valid v2 profile should lint clean (got rc=$rcA): $outA"
echo "ok: case a — a valid v2 install-profile fixture lints clean (rc=0)"

# ── case b (POSITIVE CONTROL): a broken v2 profile (bad enum) fails loud ───
brokenProfile="$work/broken.install-profile.json"
cat > "$brokenProfile" <<'JSON'
{
  "schemaVersion": 2,
  "profile": "starter",
  "devOverlay": false,
  "tier": "standard",
  "scope": "bogus",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON
set +e
outB=$(lint_profile "$brokenProfile"); rcB=$?
set -e
[ "$rcB" -eq 2 ] || fail "case b: a profile with scope:'bogus' should exit 2 (got rc=$rcB): $outB"
grepq "$outB" -i "field 'scope'" \
  || fail "case b: error should name the bad 'scope' field (got: $outB)"
echo "ok: case b — a broken v2 install-profile fixture (bad enum) exits 2 naming the field — proves the validator actually discriminates"

# ── case c: every REAL checked-in fixture under docs/setup/profiles/ lints
# clean. Globs docs/setup/profiles/*.install-profile.json — the directory may
# not exist yet (HIMMEL-2307 lands the first real fixture there), in which
# case this loop simply runs zero times. Cases a/b above already prove that
# emptiness here is a vacuous pass BY DESIGN, not a broken harness. ─────────
shopt -s nullglob
profileFiles=("$repo_root"/docs/setup/profiles/*.install-profile.json)
shopt -u nullglob
if [ "${#profileFiles[@]}" -eq 0 ]; then
  echo "ok: case c — no checked-in docs/setup/profiles/*.install-profile.json yet (vacuous pass by design; cases a/b prove the validator itself is real)"
else
  for f in "${profileFiles[@]}"; do
    set +e
    outC=$(lint_profile "$f"); rcC=$?
    set -e
    [ "$rcC" -eq 0 ] || fail "case c: checked-in profile $f should lint clean against the real v2 validator (got rc=$rcC): $outC"
  done
  echo "ok: case c — every checked-in docs/setup/profiles/*.install-profile.json lints clean (${#profileFiles[@]} file(s))"
fi

echo "PASS"
