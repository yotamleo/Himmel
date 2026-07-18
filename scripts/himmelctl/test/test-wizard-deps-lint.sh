#!/usr/bin/env bash
# test-wizard-deps-lint.sh — hermetic tests for scripts/install/deps-lint.mjs
# (HIMMEL-759). Mirrors test-wizard-manifest-v2.sh's conventions (needs no
# node process beyond the lint script itself — pure fs-read validator).
#
# Covers:
#   a. a dep with an unknown extra key -> exit 1, naming the key.
#   b. minVersion not null and not a dotted version string -> exit 1.
#   c. install.<os>.manager not in the closed vocabulary -> exit 1.
#   d. install missing one of linux/macos/win32 -> exit 1.
#   e. manager:"winget" missing its required 'id' field -> exit 1.
#   f. manager:"script" with a non-array 'args' -> exit 1.
#   g. duplicate dep ids -> exit 1.
#   h. the real deps.json lints clean -> exit 0.
#   i. minVersion:null is accepted (the real file's own shape).
#   j. manager:"ensure-tools" with an unexpected extra field -> exit 1.
#   k. a whitespace-only 'pkg' (brew) -> exit 1 (identifier fields pkg/
#      script/resolver must be non-blank, not merely string-typed).
#   l. a whitespace-only winget 'id' AND a whitespace-only dep 'cmd' -> exit 1
#      (the winget id and the dep-level cmd are identifier fields too —
#      non-blank, not merely string-typed).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
lint="$repo_root/scripts/install/deps-lint.mjs"
deps_path="$repo_root/scripts/install/deps.json"
[ -f "$lint" ] || { echo "FAIL: $lint not found" >&2; exit 1; }
[ -f "$deps_path" ] || { echo "FAIL: $deps_path not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

lint_w="$(winpath "$lint")"

# A minimal, otherwise-valid one-dep base fixture.
base_deps() {
  cat <<'JSON'
{
  "schemaVersion": 1,
  "deps": [
    {
      "id": "a",
      "cmd": "a",
      "versionProbe": { "args": ["--version"] },
      "minVersion": null,
      "bootstrap": false,
      "install": {
        "linux": { "manager": "ensure-tools" },
        "macos": { "manager": "ensure-tools" },
        "win32": { "manager": "winget", "id": "Fake.A" }
      }
    }
  ]
}
JSON
}

base_path="$work/base.json"
base_deps > "$base_path"
base_w="$(winpath "$base_path")"

run_lint() {
  "$node_bin" "$lint_w" "$(winpath "$1")"
}

# mutate_base <out-path> <js-mutation-expr-on-m> — CR-style: args passed via
# process.argv, never interpolated into the JS source string (mirrors
# test-wizard-manifest-v2.sh's own mutate_base).
mutate_base() {
  local out="$1" mutation="$2"
  "$node_bin" -e "
const [, basePath, outPath] = process.argv;
const m = JSON.parse(require('fs').readFileSync(basePath, 'utf8'));
$mutation
require('fs').writeFileSync(outPath, JSON.stringify(m, null, 2));
" "$base_w" "$(winpath "$out")"
}

# ── case a: unknown extra key -> exit 1 ─────────────────────────────────────
caseA="$work/case-a.json"
mutate_base "$caseA" "m.deps[0].bogusKey = 'nope';"
set +e
errA=$(run_lint "$caseA" 2>&1); rcA=$?
set -e
[ "$rcA" -eq 1 ] || fail "case a: an unknown extra key should exit 1 (got rc=$rcA): $errA"
echo "$errA" | grep -qi 'bogusKey' || fail "case a: error should name the unknown key (got: $errA)"
echo "ok: case a — an unknown extra dep key exits 1, naming it"

# ── case b: minVersion not null and not a dotted version -> exit 1 ─────────
caseB="$work/case-b.json"
mutate_base "$caseB" "m.deps[0].minVersion = 'latest';"
set +e
errB=$(run_lint "$caseB" 2>&1); rcB=$?
set -e
[ "$rcB" -eq 1 ] || fail "case b: a non-dotted minVersion should exit 1 (got rc=$rcB): $errB"
echo "$errB" | grep -qi 'minVersion' || fail "case b: error should mention minVersion (got: $errB)"
echo "ok: case b — minVersion not null/not a dotted version exits 1"

# ── case c: an unknown install manager -> exit 1 ───────────────────────────
caseC="$work/case-c.json"
mutate_base "$caseC" "m.deps[0].install.linux = { manager: 'apt-get-directly' };"
set +e
errC=$(run_lint "$caseC" 2>&1); rcC=$?
set -e
[ "$rcC" -eq 1 ] || fail "case c: an unknown manager should exit 1 (got rc=$rcC): $errC"
echo "$errC" | grep -qi 'manager' || fail "case c: error should mention manager (got: $errC)"
echo "ok: case c — an install manager outside the closed vocabulary exits 1"

# ── case d: install missing one of linux/macos/win32 -> exit 1 ────────────
caseD="$work/case-d.json"
mutate_base "$caseD" "delete m.deps[0].install.win32;"
set +e
errD=$(run_lint "$caseD" 2>&1); rcD=$?
set -e
[ "$rcD" -eq 1 ] || fail "case d: install missing win32 should exit 1 (got rc=$rcD): $errD"
echo "$errD" | grep -qF 'missing=[win32]' || fail "case d: error should name the missing OS key (got: $errD)"
echo "ok: case d — install missing one of linux/macos/win32 exits 1, naming it"

# ── case e: manager:winget missing 'id' -> exit 1 ──────────────────────────
caseE="$work/case-e.json"
mutate_base "$caseE" "m.deps[0].install.win32 = { manager: 'winget' };"
set +e
errE=$(run_lint "$caseE" 2>&1); rcE=$?
set -e
[ "$rcE" -eq 1 ] || fail "case e: winget without 'id' should exit 1 (got rc=$rcE): $errE"
echo "$errE" | grep -qF "requires 'id'" || fail "case e: error should name the missing 'id' field (got: $errE)"
echo "ok: case e — manager:winget without 'id' exits 1"

# ── case f: manager:script with a non-array 'args' -> exit 1 ──────────────
caseF="$work/case-f.json"
mutate_base "$caseF" "m.deps[0].install.linux = { manager: 'script', script: 'x.sh', args: 'install' };"
set +e
errF=$(run_lint "$caseF" 2>&1); rcF=$?
set -e
[ "$rcF" -eq 1 ] || fail "case f: a non-array args should exit 1 (got rc=$rcF): $errF"
echo "$errF" | grep -qi 'args' || fail "case f: error should mention args (got: $errF)"
echo "ok: case f — manager:script with a non-array 'args' exits 1"

# ── case g: duplicate dep ids -> exit 1 ────────────────────────────────────
caseG="$work/case-g.json"
mutate_base "$caseG" "m.deps.push(JSON.parse(JSON.stringify(m.deps[0])));"
set +e
errG=$(run_lint "$caseG" 2>&1); rcG=$?
set -e
[ "$rcG" -eq 1 ] || fail "case g: duplicate dep ids should exit 1 (got rc=$rcG): $errG"
echo "$errG" | grep -qi 'duplicate' || fail "case g: error should say duplicate (got: $errG)"
echo "ok: case g — duplicate dep ids exit 1"

# ── case h: the real deps.json lints clean -> exit 0 ───────────────────────
set +e
outH=$(DEPS_PATH="$(winpath "$deps_path")" "$node_bin" "$lint_w" 2>&1); rcH=$?
set -e
[ "$rcH" -eq 0 ] || fail "case h: the real deps.json should lint clean (got rc=$rcH): $outH"
echo "ok: case h — the real deps.json lints clean via the DEPS_PATH seam"

# ── case i: minVersion:null is accepted ────────────────────────────────────
set +e
outI=$(run_lint "$base_path" 2>&1); rcI=$?
set -e
[ "$rcI" -eq 0 ] || fail "case i: the base fixture (minVersion:null) should lint clean (got rc=$rcI): $outI"
echo "ok: case i — minVersion:null is accepted"

# ── case j: manager:ensure-tools with an unexpected extra field -> exit 1 ──
caseJ="$work/case-j.json"
mutate_base "$caseJ" "m.deps[0].install.linux = { manager: 'ensure-tools', pkg: 'nope' };"
set +e
errJ=$(run_lint "$caseJ" 2>&1); rcJ=$?
set -e
[ "$rcJ" -eq 1 ] || fail "case j: ensure-tools with an extra field should exit 1 (got rc=$rcJ): $errJ"
echo "$errJ" | grep -qi 'unexpected field' || fail "case j: error should name the unexpected field (got: $errJ)"
echo "ok: case j — manager:ensure-tools with an unexpected extra field exits 1"

# ── case k: whitespace-only 'pkg' (brew) -> exit 1 ─────────────────────────
# CodeRabbit: identifier fields pkg/script/resolver must be NON-WHITESPACE
# non-empty strings — a whitespace-only value is string-typed (so the old
# typeof check let it through) but names no package to install. Covers the
# trim-based rejection; empty-string pkg/script/resolver fail the same way.
caseK="$work/case-k.json"
mutate_base "$caseK" "m.deps[0].install.linux = { manager: 'brew', pkg: '   ' };"
set +e
errK=$(run_lint "$caseK" 2>&1); rcK=$?
set -e
[ "$rcK" -eq 1 ] || fail "case k: a whitespace-only pkg should exit 1 (got rc=$rcK): $errK"
echo "$errK" | grep -qi 'pkg' || fail "case k: error should mention pkg (got: $errK)"
echo "ok: case k — a whitespace-only 'pkg' exits 1 (non-blank identifier check)"

# ── case l: whitespace-only winget 'id' / dep 'cmd' -> exit 1 ───────────────
# CodeRabbit: the winget id and the dep-level cmd are IDENTIFIER fields too —
# a whitespace-only value is string-typed (so the old typeof check let it
# through) but names nothing to install/resolve. Both must fail the same
# non-blank (empty-after-trim) check pkg/script/resolver do (case k).
caseL="$work/case-l.json"
mutate_base "$caseL" "m.deps[0].install.win32 = { manager: 'winget', id: '   ' };"
set +e
errL=$(run_lint "$caseL" 2>&1); rcL=$?
set -e
[ "$rcL" -eq 1 ] || fail "case l: a whitespace-only winget id should exit 1 (got rc=$rcL): $errL"
echo "$errL" | grep -qF "requires 'id'" || fail "case l: error should name the winget 'id' field (got: $errL)"

caseL2="$work/case-l2.json"
mutate_base "$caseL2" "m.deps[0].cmd = '  ';"
set +e
errL2=$(run_lint "$caseL2" 2>&1); rcL2=$?
set -e
[ "$rcL2" -eq 1 ] || fail "case l: a whitespace-only cmd should exit 1 (got rc=$rcL2): $errL2"
echo "$errL2" | grep -qF "'cmd'" || fail "case l: error should name the 'cmd' field (got: $errL2)"
echo "ok: case l — whitespace-only winget 'id' AND dep 'cmd' exit 1 (non-blank identifier check)"

echo "PASS"
