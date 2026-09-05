#!/usr/bin/env bash
# test-wizard-cadence-registry.sh — CI staleness lint for
# scripts/himmelctl/lib/cadence-registry.json (HIMMEL-2302), mirroring the
# test-wizard-profile-lint.sh case a/b pattern (HIMMEL-2320): a positive
# control proving the real registry lints clean, and a NEGATIVE control
# (a deliberately broken fixture) proving the lint actually discriminates —
# a suite that only ever saw a pass would be just as "green" if the check
# were silently a no-op.
#
# What "lints clean" means here: every row's `script` (repo-root-relative)
# exists on disk AND contains cmd_arm()/cmd_status()/cmd_disarm() function
# definitions — the same three subcommands bin.js's arm/disarm plumbing
# assumes every registry row's script implements (HIMMEL-2302's
# cadenceArmFlags()/cadenceScriptPath()). A row naming a renamed/deleted
# script, or one missing a subcommand, must fail loud in CI rather than
# surface as a silent runtime spawn failure at install time.
#
# Covers:
#   a. POSITIVE CONTROL: the real cadence-registry.json lints clean — every
#      row's script exists and defines all three cmd_*().
#   b. NEGATIVE CONTROL (HIMMEL-2320, mandatory): a synthetic registry naming
#      a script missing cmd_disarm() -> the SAME lint logic fails, naming the
#      row and the missing function.
#   c. every registry id is unique (a duplicate id would let one row's
#      disposition silently shadow another's in bin.js's dispositions map).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
registry="$repo_root/scripts/himmelctl/lib/cadence-registry.json"
[ -f "$registry" ] || { echo "FAIL: $registry not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# grepq <text> [grep-args...] — see test-wizard-manifest-v2.sh's own comment
# for why this (not a piped `grep -q`) is required under `set -o pipefail`.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-registry-lint.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# lint_registry <repo_root> <registry_json_path> — the real lint logic: every
# row's script must exist under <repo_root> AND define cmd_arm()/cmd_status()/
# cmd_disarm(). Prints one "FAIL <id>: <reason>" line per violation to stdout,
# exits 1 if any violation was found, else prints "PASS" lines and exits 0.
# A plain node -e script (not a separate library module) since this check has
# exactly one caller — this test — and the brief scopes no production
# staleness-lint entrypoint, only "a test case ... asserting" the property.
lint_registry() {
  local _root="$1" _reg="$2"
  "$node_bin" -e "
const fs = require('fs');
const path = require('path');
const root = process.argv[1];
const reg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
let bad = 0;
for (const row of reg.cadences) {
  const p = path.join(root, row.script);
  if (!fs.existsSync(p)) {
    console.log('FAIL ' + row.id + ': script not found: ' + row.script);
    bad++;
    continue;
  }
  const src = fs.readFileSync(p, 'utf8');
  for (const fn of ['cmd_arm', 'cmd_status', 'cmd_disarm']) {
    if (!new RegExp('^' + fn + '\\\\(\\\\)', 'm').test(src)) {
      console.log('FAIL ' + row.id + ': ' + row.script + ' has no ' + fn + '()');
      bad++;
    }
  }
}
if (bad === 0) console.log('PASS');
process.exit(bad === 0 ? 0 : 1);
" "$_root" "$_reg"
}

# ── case a (POSITIVE CONTROL): the real registry lints clean ───────────────
set +e
outA=$(lint_registry "$repo_root" "$registry"); rcA=$?
set -e
[ "$rcA" -eq 0 ] || fail "case a: the real cadence-registry.json should lint clean (got rc=$rcA): $outA"
grepq "$outA" '^PASS$' || fail "case a: expected a PASS line (got: $outA)"
echo "ok: case a — the real cadence-registry.json lints clean (every row's script exists and defines cmd_arm/cmd_status/cmd_disarm)"

# ── case b (NEGATIVE CONTROL, HIMMEL-2320): a broken fixture fails loud ────
# A stub script missing cmd_disarm() entirely (arm/status only).
brokenScript="$work/broken-cadence.sh"
cat > "$brokenScript" <<'SH'
#!/usr/bin/env bash
cmd_arm() { :; }
cmd_status() { :; }
SH
brokenRegistry="$work/broken-registry.json"
cat > "$brokenRegistry" <<JSON
{"cadences":[{"id":"broken-unit","script":"$(basename "$brokenScript")","description":"x","requires":"none","recommended":false}]}
JSON
set +e
outB=$(lint_registry "$work" "$brokenRegistry"); rcB=$?
set -e
[ "$rcB" -ne 0 ] || fail "case b: a script missing cmd_disarm() should fail the lint (got rc=$rcB): $outB"
grepq "$outB" -F -- 'broken-unit' \
  || fail "case b: the failure should name the offending row id (got: $outB)"
grepq "$outB" -F -- 'cmd_disarm' \
  || fail "case b: the failure should name the missing function (got: $outB)"
echo "ok: case b — a script missing cmd_disarm() fails the SAME lint logic, naming the row and the missing function — proves the lint actually discriminates"

# ── case c: registry ids are unique ─────────────────────────────────────────
dupCheck=$("$node_bin" -e "
const reg = require('$registry');
const ids = reg.cadences.map((r) => r.id);
const seen = new Set();
const dups = [];
for (const id of ids) { if (seen.has(id)) dups.push(id); seen.add(id); }
console.log(dups.join(','));
")
[ -z "$dupCheck" ] || fail "case c: duplicate cadence registry id(s): $dupCheck"
echo "ok: case c — every cadence-registry.json id is unique"

echo "PASS"
