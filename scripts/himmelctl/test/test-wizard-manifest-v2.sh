#!/usr/bin/env bash
# test-wizard-manifest-v2.sh — hermetic tests for scripts/install/manifest-lint.mjs's
# schema-v2 extension (HIMMEL-755 A1): optional install/unwire/removable item
# keys, INSTALL_TYPES closed vocab + shape checks, the removable<=>unwire
# biconditional, scopes/profiles value-enums, and a deps[] DAG check (dep-cycle
# detector). Mirrors sibling test-wizard-*.sh conventions but needs no node
# process of its own beyond the lint script (ESM, run directly by node) — no
# HOME/HIMMELCTL_CACHE_DIR fixture needed, since manifest-lint.mjs is a pure
# fs-read validator with no cache/state surface.
#
# Covers:
#   a. install.type:"bogus" -> exit 1, per-item message naming the bad type.
#   b. removable:"per-item" with no 'unwire' -> exit 1 (biconditional violated).
#   c. scopes:["projects"] (typo, not in the enum) -> exit 1.
#   d. an unknown extra item key -> exit 1 (schema stays closed).
#   e. a deps[] cycle (X deps Y, Y deps X) -> exit 1, message names the cycle.
#   f. the real (post-v2) manifest.json lints clean -> exit 0.
#   g. a non-array 'scopes' (a bare string, not [...]) -> exit 1 with a
#      "'scopes' must be an array" message, not a silently-skipped enum check.
#   h. a non-string deps[] entry (a number) -> exit 1 with a clear per-item
#      message (not a crash/stack trace) — the DFS cycle detector must
#      reject it before building the graph, not choke on it.
#   i. (CR fix) install.type:"config" with BOTH 'key' and 'keys' -> exit 1
#      (the same key XOR keys shape probe type settings-key already
#      enforces); install.type:"config" with a valid 'keys' array (no
#      'key') -> accepted (case f's real-manifest check already covers
#      jira-env-keys using this exact shape, but this fixture pins the
#      shape check itself, independent of the real manifest's content).
#   j. (CR fix) install.type:"config" cross-checked against the SAME item's
#      probe: a probe with 4 keys + a singular install.key -> exit 1.
#   k. (CR fix) a probe with 4 keys + install.keys missing one of them ->
#      exit 1 (install must cover the probe's COMPLETE key set).
#   l. (CR fix) install.keys == the probe's key set exactly -> accepted
#      (the real jira-env-keys shape).
#   m. (CR fix) install:{type:"wire",target:"statusline"} + unwire:
#      {type:"wire",target:"pretooluse-hooks"} (mismatched targets) -> exit
#      1, naming both targets — the two independent shape checks alone
#      would each pass this incoherent pairing.
#   n. (CR fix) install/unwire both target:"statusline" (matching) ->
#      accepted — the real wiring-statusline/wiring-pretooluse items use
#      this exact shape (case f's real-manifest check already covers them
#      by content; this fixture pins the cross-check itself).
#   o. (CR fix) the REVERSE half of the removable<=>unwire biconditional
#      case b pins: `unwire` present but `removable` missing (or not
#      'per-item') -> exit 1, message identifying the invalid relationship.
#      Case b alone (removable-without-unwire) never catches an unwire
#      someone added and forgot to mark removable:'per-item'.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
lint="$repo_root/scripts/install/manifest-lint.mjs"
manifest_path="$repo_root/scripts/install/manifest.json"
[ -f "$lint" ] || { echo "FAIL: $lint not found" >&2; exit 1; }
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# winpath <path> — echo <path> unchanged on posix, or its Windows form on
# git-bash/MSYS/Cygwin (node.exe misresolves MSYS /tmp-style paths).
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

lint_w="$(winpath "$lint")"

# A minimal, otherwise-valid two-item base manifest: item "a" carries no
# deps, item "b" deps on "a". Each case below starts from this base and
# perturbs exactly one thing.
base_manifest() {
  cat <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "a",
      "kind": "hook",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "a.txt" }
    },
    {
      "id": "b",
      "kind": "hook",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": ["a"],
      "probe": { "type": "file-exists", "path": "b.txt" }
    }
  ]
}
JSON
}

base_manifest_path="$work/base.json"
base_manifest > "$base_manifest_path"
base_manifest_w="$(winpath "$base_manifest_path")"

run_lint() {
  # $1 = manifest path
  "$node_bin" "$lint_w" "$(winpath "$1")"
}

# mutate_base <out-path> <js-mutation-expr-on-m> — load the base fixture,
# apply a JS mutation to `m`, write it to <out-path>. CR fix: the base/out
# paths are passed as process.argv args (node -e "script" argv1 argv2),
# never interpolated into the JS source string — a checkout path carrying
# an apostrophe or space would otherwise break the quoting.
mutate_base() {
  local out="$1" mutation="$2"
  "$node_bin" -e "
const [, basePath, outPath] = process.argv;
const m = JSON.parse(require('fs').readFileSync(basePath, 'utf8'));
$mutation
require('fs').writeFileSync(outPath, JSON.stringify(m, null, 2));
" "$base_manifest_w" "$(winpath "$out")"
}

# ── case a: install.type:"bogus" -> exit 1 ─────────────────────────────────
caseA="$work/case-a.json"
mutate_base "$caseA" "m.items[0].install = { type: 'bogus' };"
set +e
errA=$(run_lint "$caseA" 2>&1); rcA=$?
set -e
[ "$rcA" -eq 1 ] || fail "case a: install.type:bogus should exit 1 (got rc=$rcA): $errA"
echo "$errA" | grep -q "a:" || fail "case a: error should be a per-item message naming item 'a' (got: $errA)"
echo "$errA" | grep -qi "install.type" || fail "case a: error should mention install.type (got: $errA)"
echo "ok: case a — install.type:bogus exits 1 with a per-item message"

# ── case b: removable:"per-item" with no unwire -> exit 1 ─────────────────
caseB="$work/case-b.json"
mutate_base "$caseB" "m.items[0].removable = 'per-item';"
set +e
errB=$(run_lint "$caseB" 2>&1); rcB=$?
set -e
[ "$rcB" -eq 1 ] || fail "case b: removable:per-item with no unwire should exit 1 (got rc=$rcB): $errB"
echo "$errB" | grep -q "a:" || fail "case b: error should be a per-item message naming item 'a' (got: $errB)"
echo "ok: case b — removable:per-item with no unwire exits 1"

# ── case c: scopes:["projects"] (typo) -> exit 1 ───────────────────────────
caseC="$work/case-c.json"
mutate_base "$caseC" "m.items[0].scopes = ['projects'];"
set +e
errC=$(run_lint "$caseC" 2>&1); rcC=$?
set -e
[ "$rcC" -eq 1 ] || fail "case c: scopes:[projects] should exit 1 (got rc=$rcC): $errC"
echo "$errC" | grep -q "a:" || fail "case c: error should be a per-item message naming item 'a' (got: $errC)"
echo "$errC" | grep -qi "scopes" || fail "case c: error should mention scopes (got: $errC)"
echo "ok: case c — scopes:[projects] (not in enum) exits 1"

# ── case d: unknown extra item key -> exit 1 ───────────────────────────────
caseD="$work/case-d.json"
mutate_base "$caseD" "m.items[0].bogusExtraKey = 'nope';"
set +e
errD=$(run_lint "$caseD" 2>&1); rcD=$?
set -e
[ "$rcD" -eq 1 ] || fail "case d: unknown extra item key should exit 1 (got rc=$rcD): $errD"
echo "$errD" | grep -q "a:" || fail "case d: error should be a per-item message naming item 'a' (got: $errD)"
echo "$errD" | grep -qi "bogusExtraKey" || fail "case d: error should name the unknown key (got: $errD)"
echo "ok: case d — an unknown extra item key exits 1 (schema stays closed)"

# ── case e: deps[] cycle (a deps b, b deps a) -> exit 1 ────────────────────
caseE="$work/case-e.json"
mutate_base "$caseE" "m.items[0].deps = ['b'];"
set +e
errE=$(run_lint "$caseE" 2>&1); rcE=$?
set -e
[ "$rcE" -eq 1 ] || fail "case e: a deps[] cycle should exit 1 (got rc=$rcE): $errE"
echo "$errE" | grep -qi "cycle" || fail "case e: error should name the cycle (got: $errE)"
echo "ok: case e — a deps[] cycle exits 1 naming it"

# ── case f: the real manifest.json (post-v2) lints clean -> exit 0 ────────
set +e
outF=$(MANIFEST_PATH="$(winpath "$manifest_path")" "$node_bin" "$lint_w" 2>&1); rcF=$?
set -e
[ "$rcF" -eq 0 ] || fail "case f: the real manifest.json should lint clean (got rc=$rcF): $outF"
echo "ok: case f — the real manifest.json lints clean via the MANIFEST_PATH seam"

# ── case g: a non-array 'scopes' (a bare string) -> exit 1, clear message ──
caseG="$work/case-g.json"
mutate_base "$caseG" "m.items[0].scopes = 'project';"
set +e
errG=$(run_lint "$caseG" 2>&1); rcG=$?
set -e
[ "$rcG" -eq 1 ] || fail "case g: a non-array scopes should exit 1 (got rc=$rcG): $errG"
echo "$errG" | grep -qF "'scopes' must be an array" || fail "case g: error should say scopes must be an array (got: $errG)"
echo "ok: case g — a non-array scopes exits 1 with a clear message (not a silently-skipped enum check)"

# ── case h: a non-string deps[] entry (a number) -> exit 1, no crash ──────
caseH="$work/case-h.json"
mutate_base "$caseH" "m.items[1].deps = [42];"
set +e
errH=$(run_lint "$caseH" 2>&1); rcH=$?
set -e
[ "$rcH" -eq 1 ] || fail "case h: a non-string deps[] entry should exit 1, not crash (got rc=$rcH): $errH"
echo "$errH" | grep -qF 'must be a string' || fail "case h: error should say the deps entry must be a string (got: $errH)"
if echo "$errH" | grep -qi 'TypeError\|stack\|at Object'; then
  fail "case h: a non-string deps entry must not crash with a stack trace (got: $errH)"
fi
echo "ok: case h — a non-string deps[] entry exits 1 with a clear message, no crash"

# ── case i (CR fix): install.type:"config" key XOR keys shape ──────────────
caseI_both="$work/case-i-both.json"
mutate_base "$caseI_both" "m.items[0].install = { type: 'config', key: 'FOO', keys: ['FOO', 'BAR'] };"
set +e
errI1=$(run_lint "$caseI_both" 2>&1); rcI1=$?
set -e
[ "$rcI1" -eq 1 ] || fail "case i: install.type:config with BOTH key and keys should exit 1 (got rc=$rcI1): $errI1"
echo "$errI1" | grep -qF "exactly one of 'key'" || fail "case i: error should name the key XOR keys requirement (got: $errI1)"
echo "ok: case i (part 1) — install.type:config with both key and keys exits 1"

caseI_keys="$work/case-i-keys.json"
mutate_base "$caseI_keys" "m.items[0].install = { type: 'config', keys: ['FOO', 'BAR'] };"
set +e
errI2=$(run_lint "$caseI_keys" 2>&1); rcI2=$?
set -e
[ "$rcI2" -eq 0 ] || fail "case i: install.type:config with a valid 'keys' array (no 'key') should lint clean (got rc=$rcI2): $errI2"
echo "ok: case i (part 2) — install.type:config with a valid 'keys' array (no 'key') is accepted"

# ── case j (CR fix): probe has 4 keys + install has a singular 'key' -> exit 1
caseJ="$work/case-j.json"
mutate_base "$caseJ" "
m.items[0].probe = { type: 'settings-key', file: '.env', keys: ['A', 'B', 'C', 'D'] };
m.items[0].install = { type: 'config', key: 'A' };
"
set +e
errJ=$(run_lint "$caseJ" 2>&1); rcJ=$?
set -e
[ "$rcJ" -eq 1 ] || fail "case j: a singular install.key against a 4-key probe should exit 1 (got rc=$rcJ): $errJ"
echo "$errJ" | grep -qF 'singular' || fail "case j: error should call out the singular key vs multi-key probe mismatch (got: $errJ)"
echo "ok: case j — install.type:config with a singular 'key' against a probe checking multiple keys exits 1"

# ── case k (CR fix): probe has 4 keys + install.keys missing one -> exit 1 ─
caseK="$work/case-k.json"
mutate_base "$caseK" "
m.items[0].probe = { type: 'settings-key', file: '.env', keys: ['A', 'B', 'C', 'D'] };
m.items[0].install = { type: 'config', keys: ['A', 'B', 'C'] };
"
set +e
errK=$(run_lint "$caseK" 2>&1); rcK=$?
set -e
[ "$rcK" -eq 1 ] || fail "case k: install.keys missing one of the probe's 4 keys should exit 1 (got rc=$rcK): $errK"
echo "$errK" | grep -qF 'missing=[D]' || fail "case k: error should name the missing key 'D' (got: $errK)"
echo "ok: case k — install.keys missing one of the probe's keys exits 1, naming the missing key"

# ── case l (CR fix): install.keys == the probe's key set exactly -> accepted
# (the real jira-env-keys shape) ────────────────────────────────────────────
caseL="$work/case-l.json"
mutate_base "$caseL" "
m.items[0].probe = { type: 'settings-key', file: '.env', keys: ['A', 'B', 'C', 'D'] };
m.items[0].install = { type: 'config', keys: ['A', 'B', 'C', 'D'] };
"
set +e
errL=$(run_lint "$caseL" 2>&1); rcL=$?
set -e
[ "$rcL" -eq 0 ] || fail "case l: install.keys matching the probe's key set exactly should lint clean (got rc=$rcL): $errL"
echo "ok: case l — install.keys covering exactly the probe's key set is accepted"

# ── case m (CR fix): install/unwire both type:"wire" but MISMATCHED targets
# -> exit 1, naming both. removable:'per-item' set alongside so the
# biconditional check (h) doesn't ALSO fire and confuse the assertion. ─────
caseM="$work/case-m.json"
mutate_base "$caseM" "
m.items[0].install = { type: 'wire', target: 'statusline' };
m.items[0].unwire = { type: 'wire', target: 'pretooluse-hooks' };
m.items[0].removable = 'per-item';
"
set +e
errM=$(run_lint "$caseM" 2>&1); rcM=$?
set -e
[ "$rcM" -eq 1 ] || fail "case m: mismatched install/unwire wire targets should exit 1 (got rc=$rcM): $errM"
echo "$errM" | grep -qF "install.target 'statusline'" || fail "case m: error should name install.target 'statusline' (got: $errM)"
echo "$errM" | grep -qF "unwire.target 'pretooluse-hooks'" || fail "case m: error should name unwire.target 'pretooluse-hooks' (got: $errM)"
echo "ok: case m — mismatched install/unwire wire targets exit 1, naming both"

# ── case n (CR fix): install/unwire both type:"wire" with MATCHING targets
# -> accepted (the real wiring-statusline/wiring-pretooluse shape). ────────
caseN="$work/case-n.json"
mutate_base "$caseN" "
m.items[0].install = { type: 'wire', target: 'statusline' };
m.items[0].unwire = { type: 'wire', target: 'statusline' };
m.items[0].removable = 'per-item';
"
set +e
errN=$(run_lint "$caseN" 2>&1); rcN=$?
set -e
[ "$rcN" -eq 0 ] || fail "case n: matching install/unwire wire targets should lint clean (got rc=$rcN): $errN"
echo "ok: case n — matching install/unwire wire targets are accepted"

# ── case o (CR fix, CodeRabbit round 22): the REVERSE half of the
# removable<=>unwire biconditional case b pins. Case b only asserts
# removable:'per-item' WITHOUT unwire exits 1 — a one-directional check
# never catches the converse: an `unwire` someone added and forgot to mark
# removable:'per-item' (a removable item the disable planner could never
# pick up, since towardDisabled keys on item.removable === 'per-item'). Both
# shapes here lint-exit 1 AND the message must NAME the biconditional
# relationship, not just the item — so a reader (or a grep) can tell this is
# the removable<=>unwire rule firing, not some other violation.
# part 1: unwire present, `removable` MISSING entirely ───────────────────────
caseO_missing="$work/case-o-missing.json"
mutate_base "$caseO_missing" "m.items[0].unwire = { type: 'wire', target: 'statusline' };"
set +e
errO1=$(run_lint "$caseO_missing" 2>&1); rcO1=$?
set -e
[ "$rcO1" -eq 1 ] || fail "case o: unwire present with NO removable should exit 1 (got rc=$rcO1): $errO1"
echo "$errO1" | grep -qF "removable === 'per-item' iff 'unwire' is present" \
  || fail "case o: error should identify the removable<=>unwire relationship (got: $errO1)"
# hasUnwire=true distinguishes THIS direction from case b's (hasUnwire=false) —
# proves the message carries the converse half, not just the one case b pins.
echo "$errO1" | grep -qF "hasUnwire=true" \
  || fail "case o: error should report hasUnwire=true (the unwire-present direction, distinct from case b) (got: $errO1)"
echo "ok: case o (part 1) — unwire present with no removable exits 1, naming the biconditional"

# part 2: unwire present, removable present but NOT 'per-item' ───────────────
caseO_wrong="$work/case-o-wrong.json"
mutate_base "$caseO_wrong" "
m.items[0].unwire = { type: 'wire', target: 'statusline' };
m.items[0].removable = 'full-offboard-only';
"
set +e
errO2=$(run_lint "$caseO_wrong" 2>&1); rcO2=$?
set -e
[ "$rcO2" -eq 1 ] || fail "case o: unwire present with removable:'full-offboard-only' (not per-item) should exit 1 (got rc=$rcO2): $errO2"
echo "$errO2" | grep -qF "removable === 'per-item' iff 'unwire' is present" \
  || fail "case o: error should identify the removable<=>unwire relationship (got: $errO2)"
echo "ok: case o (part 2) — unwire present with removable not 'per-item' exits 1, naming the biconditional"

# ── case p (HIMMEL-755 sub-ticket E): offboard value outside the closed
# vocabulary -> exit 1, naming the bad value. Mirrors case c's enum-mutation
# shape (scopes entry not in its enum) for the newer offboard field. ────────
caseP="$work/case-p.json"
mutate_base "$caseP" "m.items[0].offboard = 'bogus';"
set +e
errP=$(run_lint "$caseP" 2>&1); rcP=$?
set -e
[ "$rcP" -eq 1 ] || fail "case p: offboard:'bogus' should exit 1 (got rc=$rcP): $errP"
echo "$errP" | grep -qF "offboard 'bogus' not in [unwire, advise, keep]" \
  || fail "case p: error should name the bad offboard value and the closed vocabulary (got: $errP)"
echo "ok: case p (part 1) — offboard:'bogus' (not in the closed vocabulary) exits 1"

# part 2: a valid offboard value ('advise') lints clean — pins the positive
# path so case p isn't just "any offboard value fails". ────────────────────
caseP_valid="$work/case-p-valid.json"
mutate_base "$caseP_valid" "m.items[0].offboard = 'advise';"
set +e
errP2=$(run_lint "$caseP_valid" 2>&1); rcP2=$?
set -e
[ "$rcP2" -eq 0 ] || fail "case p: offboard:'advise' (a valid value) should lint clean (got rc=$rcP2): $errP2"
echo "ok: case p (part 2) — offboard:'advise' (a valid closed-vocabulary value) is accepted"

echo "PASS"
