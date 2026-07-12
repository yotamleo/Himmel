#!/usr/bin/env bash
# test-wizard-status-golden.sh — the #276-class golden fixture (HIMMEL-756
# T1.7): a single project-scope target whose himmelctl state.json marks
# EXACTLY six items desired-enabled — qmd-binary, qmd-index,
# wiring-statusline, wiring-pretooluse, jira-cli-dist-build,
# handover-wiring — every other manifest item disabled, and every one of
# the six probes ABSENT by hermetic construction (never by luck: the suite
# runner inherits the real PATH + parent env, so each condition is actively
# scrubbed/unset/omitted rather than assumed missing). Mirrors sibling
# test-wizard-status-cmd.sh / test-wizard-probes.sh conventions: a fake
# HOME + HIMMELCTL_CACHE_DIR + HIMMELCTL_REPO_ROOT fixture,
# scripts/lib/hermetic-path.sh's link_hermetic_tool/scrub_path for curated
# stub PATHs, node launched by absolute path, winpath for node.exe's
# MSYS-path blindness.
#
# The state entry is authored directly rather than reverse-engineered from
# a single deriveTarget() profile: no single profile/scope combination in
# the real manifest yields "these six and only these six" (e.g. profile
# 'luna' + scope 'project' would ALSO enable claude-plugins-pluginSet).
# state.json is himmelctl's OWN artifact (lib/state.js's module header: a
# SEPARATE artifact from install-profile.json, read/written by a stable
# public schema) — so the fixture runs ONE real `status` invocation to let
# ensureTarget derive-and-save the target entry under its real key (however
# path.resolve(cwd) stringifies on this platform — avoids reproducing that
# string by hand), then patches the saved items map via jq to the exact
# six-true/rest-false split the brief specifies. That patch (plus the one
# ensureTarget write it rides on) is the ONE sanctioned mutation; the sha256
# purity sweep (case d) snapshots AFTER it, so every read-only status
# invocation in cases (a)/(b) is held to true zero-diff.
#
# Covers:
#   a. `status --json --items <six-csv>` reports EXACTLY those six, all
#      severity=="red", summary.red==6 (and, as a bonus over the literal
#      --items-scoped requirement: a --items-less run root-to-tip proves
#      the STATE itself — not just the query — carries only six reds
#      against the full manifest: summary.red==6, na==manifestCount-6).
#   b. DISCRIMINATION: six flip cases. Each flips ONE condition to present
#      via a hermetic-env change scoped to that ONE invocation (extra PATH
#      entry, an env var, or a file edit — never a permanent fixture
#      mutation that survives past its own case) and asserts that item —
#      and, honestly, ONLY it, with one documented exception: qmd-index's
#      own probe requires has_qmd to succeed as a hard precondition
#      (scripts/lib/qmd-bin.sh's has_index chains `has_qmd && qmd_cmd
#      collection list`), so flipping qmd-index to present necessarily also
#      flips qmd-binary to present — a REAL causal coupling in the probe
#      engine, not a fixture shortcut, and the flip-2 case asserts it
#      explicitly rather than hiding it.
#   c. manifest-lint regression re-run against the REAL repo manifest.
#   d. purity: the full golden run (case a + all six flips, each restored)
#      leaves the fixture tree byte-identical, beyond the one sanctioned
#      derive+patch write that happens before the snapshot baseline.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
manifest_path="$repo_root/scripts/install/manifest.json"
lint_script="$repo_root/scripts/install/manifest-lint.mjs"
qmd_bin_lib="$repo_root/scripts/lib/qmd-bin.sh"
handover_path_lib="$repo_root/scripts/lib/handover-path.sh"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
[ -f "$lint_script" ] || { echo "FAIL: $lint_script not found" >&2; exit 1; }
[ -f "$qmd_bin_lib" ] || { echo "FAIL: $qmd_bin_lib not found" >&2; exit 1; }
[ -f "$handover_path_lib" ] || { echo "FAIL: $handover_path_lib not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "FAIL: sha256sum required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

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

# snapshot_dir <dir> — sorted "relpath sha256" pairs, for a before/after
# byte-identity check that doesn't depend on tar's metadata quirks. Portable
# across bash 3.2 + BSD sort (no -z/-print0/xargs -0 on macOS's base sort).
snapshot_dir() {
  ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done )
}

# write_cache <path> <role> <scope> <vault-mode> <vault-path> <handover-mode>
#             <handover-path> <plugin-set> — a minimal valid Draft-A profile
#             (same shape test-wizard-status-cmd.sh's write_cache writes).
write_cache() {
  cat > "$1" <<JSON
{"role":"$2","tier":"standard","scope":"$3","vault":{"mode":"$4","path":"$5"},"handover":{"mode":"$6","path":"$7"},"pluginSet":"$8","lanes":[],"alwaysOn":false}
JSON
}

SIX_IDS_CSV="qmd-binary,qmd-index,wiring-statusline,wiring-pretooluse,jira-cli-dist-build,handover-wiring"
SIX_IDS_JSON='["qmd-binary","qmd-index","wiring-statusline","wiring-pretooluse","jira-cli-dist-build","handover-wiring"]'
SIX_SORTED_JSON='["handover-wiring","jira-cli-dist-build","qmd-binary","qmd-index","wiring-pretooluse","wiring-statusline"]'

# ── fixture repo root (HIMMELCTL_REPO_ROOT) ─────────────────────────────────
# A real copy of manifest.json, the two resolver libs the six items' probes
# actually source (scripts/lib/qmd-bin.sh for qmd-binary/qmd-index,
# scripts/lib/handover-path.sh for handover-wiring — control 1/2/6 need the
# REAL resolvers present so a later "flip to present" is genuinely possible,
# not just permanently absent because the sourced file itself 404s), and an
# EMPTY scripts/jira/dist/ (control 5: jira-cli-dist-build's file-exists
# probe resolves repoRoot-relative — the dir exists so the flip only ever
# adds/removes the one file, never a directory, keeping the purity diff
# clean). No handovers/ dir here (control 6 doesn't need it — see below).
fixtureRepo="$work/repo"
mkdir -p "$fixtureRepo/scripts/install" "$fixtureRepo/scripts/lib" "$fixtureRepo/scripts/jira/dist"
cp "$manifest_path" "$fixtureRepo/scripts/install/manifest.json"
cp "$qmd_bin_lib" "$fixtureRepo/scripts/lib/qmd-bin.sh"
cp "$handover_path_lib" "$fixtureRepo/scripts/lib/handover-path.sh"
fixtureRepo_w="$(winpath "$fixtureRepo")"

# ── target (project scope) ──────────────────────────────────────────────────
# Control 3/4: settings.json IS present (so the probes read a real parsed
# object, not a "file missing" absent) but carries neither
# statusLine.command nor any himmel PreToolUse marker.
targetGolden="$work/target"
mkdir -p "$targetGolden/.claude"
baselineSettingsJson='{"statusLine":{},"hooks":{"PreToolUse":[]}}'
printf '%s' "$baselineSettingsJson" > "$targetGolden/.claude/settings.json"

homeDir="$work/home"; mkdir -p "$homeDir/.claude"
cacheDir="$work/cache"; mkdir -p "$cacheDir"
cacheDir_w="$(winpath "$cacheDir")"

write_cache "$cacheDir/install-profile.json" adopter project none "" inline "" lean

# ── control 1/2: hermetic PATH — bash (+ git, for handover_root's `git
# rev-parse`) present via link_hermetic_tool, bun + qmd scrubbed via
# scrub_path (never assumed absent by luck — actively excluded even though
# the suite runner's own real PATH may carry either or both). ────────────
baseStub="$work/stub-base"; mkdir -p "$baseStub"
link_hermetic_tool bash "$baseStub"
link_hermetic_tool git "$baseStub"
scrubbedBase=$(scrub_path "$PATH" bun qmd)
basePath="$baseStub:$scrubbedBase"

# ── flip fixtures, created ONCE up front (never mutated in place) so they
# read identically in the before/after purity snapshot ─────────────────────
qmdMinStub="$work/qmd-min-stub"; mkdir -p "$qmdMinStub"
cat > "$qmdMinStub/qmd" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$qmdMinStub/qmd"

qmdFullStub="$work/qmd-full-stub"; mkdir -p "$qmdFullStub"
cat > "$qmdFullStub/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "collection" ] && [ "$2" = "list" ]; then
  printf 'himmel\nluna\n'
  exit 0
fi
exit 0
STUB
chmod +x "$qmdFullStub/qmd"

handoverTarget="$work/handover-target"; mkdir -p "$handoverTarget"

# run_status <extra-path-prefix|""> <handover-dir|""> — one status
# invocation, --json --items <the six>, scope=project, cwd=targetGolden.
# HANDOVER_DIR is explicitly unset by default (control 6 — the suite
# runner's OWN real env may carry an operator HANDOVER_DIR; an inherited
# value would make handover-wiring read present by luck, not absence).
run_status() {
  local extra="$1" handoverDir="$2" pathVal="$basePath"
  [ -n "$extra" ] && pathVal="$extra:$basePath"
  if [ -n "$handoverDir" ]; then
    ( cd "$targetGolden" && HANDOVER_DIR="$(winpath "$handoverDir")" HIMMELCTL_REPO_ROOT="$fixtureRepo_w" HIMMELCTL_CACHE_DIR="$cacheDir_w" HOME="$homeDir" PATH="$pathVal" \
        "$node_bin" "$wizard" status --json --items "$SIX_IDS_CSV" )
  else
    ( cd "$targetGolden" && unset HANDOVER_DIR && HIMMELCTL_REPO_ROOT="$fixtureRepo_w" HIMMELCTL_CACHE_DIR="$cacheDir_w" HOME="$homeDir" PATH="$pathVal" \
        "$node_bin" "$wizard" status --json --items "$SIX_IDS_CSV" )
  fi
}

# run_status_full — same as run_status but WITHOUT --items (the bonus
# whole-manifest check in case a).
run_status_full() {
  ( cd "$targetGolden" && unset HANDOVER_DIR && HIMMELCTL_REPO_ROOT="$fixtureRepo_w" HIMMELCTL_CACHE_DIR="$cacheDir_w" HOME="$homeDir" PATH="$basePath" \
      "$node_bin" "$wizard" status --json )
}

# assert_items_severity <json> <label> <id:severity>... — one jq -e check
# per pair, naming the item + json on failure.
assert_items_severity() {
  local json="$1" label="$2" pair id sev
  shift 2
  for pair in "$@"; do
    id="${pair%%:*}"; sev="${pair#*:}"
    echo "$json" | jq -e --arg id "$id" --arg sev "$sev" \
      '.items[] | select(.id==$id) | .severity == $sev' >/dev/null \
      || fail "$label: expected $id severity=$sev (got: $(echo "$json" | jq -c --arg id "$id" '.items[] | select(.id==$id)'))"
  done
}

# ── seed state.json: run once to derive (ensureTarget's ONE sanctioned
# first-write), then patch the saved items map to the exact six-true/
# rest-false split. A cheap, spawn-free item (pre-commit-hooks) is used for
# the seed run's own --items so this step never shells out to bash. ───────
( cd "$targetGolden" && HIMMELCTL_REPO_ROOT="$fixtureRepo_w" HIMMELCTL_CACHE_DIR="$cacheDir_w" HOME="$homeDir" PATH="$basePath" \
    "$node_bin" "$wizard" status --json --items pre-commit-hooks >/dev/null ) \
  || fail "setup: seed status run failed"

targetKey=$(jq -r '.targets | keys[0]' "$cacheDir/state.json")
if [ -z "$targetKey" ] || [ "$targetKey" = "null" ]; then
  fail "setup: state.json has no derived target key"
fi

jq --arg key "$targetKey" --argjson six "$SIX_IDS_JSON" '
  .targets[$key].items = (.targets[$key].items
    | with_entries(.value.enabled = ((.key as $k | $six | index($k)) != null)))
' "$cacheDir/state.json" > "$cacheDir/state.json.tmp" && mv "$cacheDir/state.json.tmp" "$cacheDir/state.json"

enabledIds=$(jq -c --arg key "$targetKey" '[.targets[$key].items | to_entries[] | select(.value.enabled) | .key] | sort' "$cacheDir/state.json")
[ "$enabledIds" = "$(echo "$SIX_SORTED_JSON" | jq -c 'sort')" ] \
  || fail "setup: patched state.json does not carry EXACTLY the six desired-enabled ids (got: $enabledIds)"
echo "ok: setup — state.json target entry marks exactly the six ids desired-enabled, all others disabled"

# ── case (d) purity baseline: taken AFTER the one sanctioned derive+patch
# write, so every read-only status invocation from here on is held to true
# zero-diff. ─────────────────────────────────────────────────────────────
snapBefore=$(snapshot_dir "$work")

# ── case (a): all six red, correctly grouped, nothing else red ────────────
outA=$(run_status "" "")
countA=$(echo "$outA" | jq '.items | length')
[ "$countA" -eq 6 ] || fail "case a: expected 6 items in the --items-scoped result (got $countA): $outA"
idsA=$(echo "$outA" | jq -c '[.items[].id]')
[ "$idsA" = "$SIX_SORTED_JSON" ] || fail "case a: expected exactly the six ids sorted (got: $idsA)"
allRed=$(echo "$outA" | jq -c '[.items[].severity] | unique')
[ "$allRed" = '["red"]' ] || fail "case a: expected every item severity=red (got severities: $allRed): $outA"
echo "$outA" | jq -e '.summary.red == 6 and .summary.degraded == 0 and .summary.green == 0 and .summary.na == 0' >/dev/null \
  || fail "case a: expected summary {red:6,degraded:0,green:0,na:0} (got: $(echo "$outA" | jq -c '.summary'))"
echo "ok: case a — status --json --items <the-six> reports exactly those six, all red, summary.red==6"

# bonus: the STATE itself (not just the --items-scoped query) carries only
# six reds against the FULL manifest.
manifestCount=$(jq '.items | length' "$manifest_path")
outAFull=$(run_status_full)
echo "$outAFull" | jq -e --argjson n "$manifestCount" \
  '(.items | length) == $n and .summary.red == 6 and .summary.degraded == 0 and .summary.green == 0 and .summary.na == ($n - 6)' >/dev/null \
  || fail "case a (bonus): expected the full $manifestCount-item run to read {red:6, na:$((manifestCount - 6))} (got: $(echo "$outAFull" | jq -c '.summary'))"
echo "ok: case a (bonus) — a --items-less run against the same state confirms only six reds against the whole manifest"

# ── case (b): six discrimination flips, each restored after ────────────────

# flip 1 — qmd-binary: minimal qmd stub on PATH (has_qmd succeeds; no
# collection-list support, so qmd-index stays absent — genuine isolation).
out1=$(run_status "$qmdMinStub" "")
assert_items_severity "$out1" "flip qmd-binary" \
  "qmd-binary:green" "qmd-index:red" "wiring-statusline:red" "wiring-pretooluse:red" \
  "jira-cli-dist-build:red" "handover-wiring:red"
echo "ok: flip 1/6 — qmd-binary alone leaves the red set (qmd-index stays red: no collection-list support in the minimal stub)"

# flip 2 — qmd-index: a qmd stub that ALSO answers `collection list` with
# all 4 required collections. qmd-binary's has_qmd probe necessarily also
# reads present here — a REAL dependency in the probe engine (has_index
# chains has_qmd && qmd_cmd collection list), not a fixture leak — asserted
# explicitly rather than hidden.
out2=$(run_status "$qmdFullStub" "")
assert_items_severity "$out2" "flip qmd-index" \
  "qmd-index:green" "qmd-binary:green" "wiring-statusline:red" "wiring-pretooluse:red" \
  "jira-cli-dist-build:red" "handover-wiring:red"
echo "ok: flip 2/6 — qmd-index leaves the red set (qmd-binary necessarily follows: documented has_qmd precondition); the other four stay red"

# flip 3 — wiring-statusline: add statusLine.command, leave hooks untouched.
printf '{"statusLine":{"command":"bash foo.sh"},"hooks":{"PreToolUse":[]}}' > "$targetGolden/.claude/settings.json"
out3=$(run_status "" "")
assert_items_severity "$out3" "flip wiring-statusline" \
  "wiring-statusline:green" "wiring-pretooluse:red" "qmd-binary:red" "qmd-index:red" \
  "jira-cli-dist-build:red" "handover-wiring:red"
printf '%s' "$baselineSettingsJson" > "$targetGolden/.claude/settings.json"
echo "ok: flip 3/6 — wiring-statusline alone leaves the red set; restored"

# flip 4 — wiring-pretooluse: add all 3 himmel PreToolUse markers, leave
# statusLine untouched.
cat > "$targetGolden/.claude/settings.json" <<'JSON'
{"statusLine":{},"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/auto-approve-safe-bash.sh\""}]},
  {"matcher":"Edit","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/block-edit-on-main.sh\""}]},
  {"matcher":"Read","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/block-read-secrets.sh\""}]}
]}}
JSON
out4=$(run_status "" "")
assert_items_severity "$out4" "flip wiring-pretooluse" \
  "wiring-pretooluse:green" "wiring-statusline:red" "qmd-binary:red" "qmd-index:red" \
  "jira-cli-dist-build:red" "handover-wiring:red"
printf '%s' "$baselineSettingsJson" > "$targetGolden/.claude/settings.json"
echo "ok: flip 4/6 — wiring-pretooluse alone leaves the red set; restored"

# flip 5 — jira-cli-dist-build: create the repoRoot-relative dist file.
: > "$fixtureRepo/scripts/jira/dist/index.js"
out5=$(run_status "" "")
assert_items_severity "$out5" "flip jira-cli-dist-build" \
  "jira-cli-dist-build:green" "wiring-statusline:red" "wiring-pretooluse:red" \
  "qmd-binary:red" "qmd-index:red" "handover-wiring:red"
rm -f "$fixtureRepo/scripts/jira/dist/index.js"
echo "ok: flip 5/6 — jira-cli-dist-build alone leaves the red set; restored"

# flip 6 — handover-wiring: HANDOVER_DIR set to a real directory for this
# ONE invocation only (never persisted into the ambient env).
out6=$(run_status "" "$handoverTarget")
assert_items_severity "$out6" "flip handover-wiring" \
  "handover-wiring:green" "wiring-statusline:red" "wiring-pretooluse:red" \
  "qmd-binary:red" "qmd-index:red" "jira-cli-dist-build:red"
echo "ok: flip 6/6 — handover-wiring alone leaves the red set"

# ── case (c): manifest-lint regression re-run against the REAL manifest ────
set +e
lintOut=$("$node_bin" "$lint_script" 2>&1)
lintRc=$?
set -e
[ "$lintRc" -eq 0 ] || fail "case c: manifest-lint regression failed (rc=$lintRc): $lintOut"
echo "ok: case c — manifest-lint regression re-run passes"

# ── case (d): purity — the full golden run (case a + all six flips,
# each restored) left the fixture tree byte-identical to the post-setup
# baseline. ─────────────────────────────────────────────────────────────
snapAfter=$(snapshot_dir "$work")
[ "$snapBefore" = "$snapAfter" ] || fail "case d: the golden run (case a + six flips) mutated the fixture tree beyond the sanctioned setup write"
echo "ok: case d — purity: case a + all six flips (each restored) left the fixture tree byte-identical"

echo "PASS"
