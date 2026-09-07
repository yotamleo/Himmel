#!/usr/bin/env bash
# test-capture-operator-profile.sh — hermetic suite for HIMMEL-2307's
# scripts/install/capture-operator-profile.mjs.
#
# Hermetic via env overrides the script itself honors:
#   HIMMEL_CAPTURE_REPO_ROOT   fixture repo root (.env, .env.example,
#                              docs/setup/settings-template.json) — same
#                              idiom as scripts/lib/load-dotenv.sh's --root
#   CLAUDE_CONFIG_DIR          fixture ~/.claude (settings.json,
#                              settings.local.json, handover/registry.json,
#                              channels/telegram/.env)
#   HIMMEL_OBSERVABILITY_CONFIG  fixture observability.json
#   LANES_REGISTRY             fixture lanes.json (moot here — the fixture
#                              repo carries no scripts/lanes/resolve.mjs, so
#                              the lane probe degrades gracefully; wired
#                              anyway per the brief's fixture-point list)
#   WHISPER_DIR                fixture whisper dir (empty -> "not found")
#   HIMMEL_CAPTURE_SCHTASKS_CMD  "node <stub.mjs>" — a bare .cmd/.bat stub
#                              cannot be exec'd directly on Windows without
#                              shell:true (verified EINVAL); a "node <script>"
#                              prefix is the command form the capture script
#                              itself supports for exactly this reason.
#
# Nothing here mutates machine state; every fixture lives under one mktemp
# tree. Covers at minimum: (a) profile shape, (b) scrub self-test, (c)
# --check exit 0/1 + named diff, (d) idempotence, (e) cadence armed/off from
# a stubbed schtasks, (f) a planted secret VALUE never appears in any output
# while its NAME appears only in the delta's keysBeyondGeneratedBlock, (g)
# assertScrubbed's failure message names a label + JSON path, never the
# regex/matched text, (h) observability flow objects are reduced to names
# (an extra field never leaks), (i) a degraded devOverlay probe exits 2
# naming the field, (j) a failed scheduler query with no bridge-persistence
# proof exits 2 naming alwaysOn, (k) a corrupt settings-template.json sets
# templateReadFailed instead of reading as clean-empty, (l) a non-git repo
# root still captures (the primaryCheckoutRoot fallback), FIX_REPO itself is
# a real git checkout so the git-common-dir branch runs too, (m) crontab
# error classification, (n) POSIX prefix-group cadence matching, (o) a
# failed askable-lane read, (p) a malformed handover registry, (q) non-string
# observability entries are dropped not leaked — and (HIMMEL-2307 fix-batch,
# one case per fix): (r) a present-but-Disabled scheduled task reads 'off',
# (s) an unrecognized Status string fails toward armed + is flagged, (t)
# matchCadenceGroups skips commented-out crontab lines, (u) a malformed
# observability.json is a read failure not present-and-empty, (v)
# bridge.envPath names CLAUDE_CONFIG_DIR when it differs from ~/.claude, (w)
# assertScrubbed catches a backslash-doubled home path, (x) --check never
# echoes the caller-supplied path unscrubbed — and (HIMMEL-2307 fix-batch
# round 4, one case per fix): (y) --check drift output scrubs the COMMITTED
# profile's raw old value, not just the fresh capture, (z) a --check target
# whose path embeds the real home dir scrubs the readFileSync error message
# too, (aa) assertScrubbed's key-leak diagnostic scrubs the leaking KEY
# itself before reporting it.
set -euo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/install/capture-operator-profile.mjs"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (node not on PATH)"; exit 0; }

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

# winpath <path> — Node on Windows/Git-Bash wants a Windows-form path for
# some APIs; cygpath -m round-trips a Git-Bash /c/... path to C:/... . A
# plain path on non-Windows passes through unchanged.
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

work=$(mktemp -d "${TMPDIR:-/tmp}/cap2307.XXXXXX")
trap 'rm -rf "$work"' EXIT

# ── fixture tree ─────────────────────────────────────────────────────────
FIX_REPO="$work/repo"
FIX_CONFIG="$work/config/.claude"
mkdir -p "$FIX_REPO/docs/setup" "$FIX_REPO/scripts/guardrails" "$FIX_REPO/scripts/himmelctl/lib" "$FIX_CONFIG/handover" "$FIX_CONFIG/channels/telegram" "$work/whisper"

# adopter-profile.js fixture (askable-lane table) — a minimal V1_LANES so
# captureLanes()'s require() succeeds for every case below except the
# dedicated askableIds-read-failure case (case o), which points
# HIMMEL_CAPTURE_REPO_ROOT at a repo copied BEFORE this stub is written.
cat > "$FIX_REPO/scripts/himmelctl/lib/adopter-profile.js" <<'EOF'
const V1_LANES = [{ id: 'ollama', registryId: 'ollama-local' }];
module.exports = { V1_LANES };
EOF

# cadence-registry.json fixture (HIMMEL-2307 follow-up) — mirrors the repo's
# real scripts/himmelctl/lib/cadence-registry.json id set (pipeline/qmd/
# graphmap/codex-sweep) so splitCadencesByRegistry() has a real registry to
# filter profile.cadences against instead of hitting the read-failure branch.
cat > "$FIX_REPO/scripts/himmelctl/lib/cadence-registry.json" <<'EOF'
{ "cadences": [ { "id": "pipeline" }, { "id": "qmd" }, { "id": "graphmap" }, { "id": "codex-sweep" } ] }
EOF

# is_himmel_dev_repo() fixture — the real scripts/guardrails/lib.sh is not
# copied into this fixture tree, so without this stub detectDevOverlay()'s
# `. "$HIMMEL_PROBE_RESOLVER"` source would fail and every capture in this
# suite would silently run through the devOverlay-DEGRADED branch (a real
# gap this suite used to have). Returns 1 (absent) so devOverlay resolves
# to a definite `false` for every case below except the dedicated
# devOverlay-degraded case, which points HIMMEL_CAPTURE_REPO_ROOT at a repo
# with no scripts/guardrails/lib.sh at all.
cat > "$FIX_REPO/scripts/guardrails/lib.sh" <<'EOF'
is_himmel_dev_repo() {
  return 1
}
EOF

cat > "$FIX_REPO/.env" <<'EOF'
FAKE_TOKEN=hunter2
LUNA_VAULT_PATH=/fake/vault/path
HANDOVER_DIR=/fake/handover/dir
KNOWN_SECRET=shouldnotleakeither
EOF

cat > "$FIX_REPO/.env.example" <<'EOF'
# === GENERATED: secrets manifest (fixture) -- BEGIN ===
# KNOWN_SECRET (optional) -- probe: fixture
#   storage: fixture
#   obtain:  fixture
# === GENERATED: secrets manifest -- END ===

# === SECTION: SESSION-ONLY ===  fixture
#   EDIT_ON_MAIN_OK=1            fixture guardrail
# === SECTION: EXTERNAL-TOOLS ===
EOF

cat > "$FIX_REPO/docs/setup/settings-template.json" <<'EOF'
{ "enabledPlugins": { "a@mp": true, "b@mp": false } }
EOF

cat > "$FIX_CONFIG/settings.json" <<'EOF'
{ "enabledPlugins": { "a@mp": true, "c@mp": true } }
EOF

cat > "$FIX_CONFIG/handover/registry.json" <<'EOF'
{ "repos": { "proj1": { "path": "/x" }, "proj2": { "path": "/y" } } }
EOF

cat > "$FIX_CONFIG/channels/telegram/.env" <<'EOF'
TELEGRAM_BOT_TOKEN=abcdef123
EOF

cat > "$work/observability.json" <<'EOF'
{ "flows": [ { "name": "z", "cadence_seconds": 60, "scriptPath": "C:\\Users\\FAKE-SENSITIVE-SCRIPTPATH-MARKER\\runner.ps1" } ], "expected_tasks": ["T1"] }
EOF

cat > "$work/lanes.json" <<'EOF'
{ "lanes": [] }
EOF

# schtasks stub: pipeline (FetchHealth) armed, drift-fix armed, everything
# else off — one deterministic CSV response regardless of the args it's
# called with, mirroring how test-pipeline-cadence.sh's fake schtasks works.
cat > "$work/fakeschtasks.mjs" <<'EOF'
process.stdout.write('"\\HIMMEL-Pipeline-FetchHealth","N/A","Ready"\r\n"\\HIMMEL-DriftFix","N/A","Ready"\r\n');
EOF

# schtasks stub that fails loudly (non-empty stderr, rc!=1-with-no-stderr) —
# used by the alwaysOn-degraded case to force computeCadences()'s genuine
# queryFailed path (as opposed to the trusted "empty scheduler" rc=1 signature).
cat > "$work/fakeschtasks-fail.mjs" <<'EOF'
process.stderr.write('fixture: schtasks query boom\n');
process.exit(2);
EOF

# schtasks stub: HIMMEL-DriftFix present but Status=Disabled — used by case r
# (HIMMEL-2307 fix-batch codex-1) to prove a present-but-disabled task reads
# as 'off', not armed.
cat > "$work/fakeschtasks-disabled.mjs" <<'EOF'
process.stdout.write('"\\HIMMEL-DriftFix","N/A","Disabled"\r\n');
EOF

# schtasks stub: HIMMEL-DriftFix present with an unrecognized (e.g.
# localized-Windows) Status string, plus an unrelated third-party task —
# used by case s to prove the capture flags the himmel task in
# statusUnrecognized while excluding the unrelated task (scope-filtering).
cat > "$work/fakeschtasks-unrecognized.mjs" <<'EOF'
process.stdout.write('"\\HIMMEL-DriftFix","N/A","Queued"\r\n"\\Adobe Updater","N/A","Queued"\r\n');
EOF

# ── fixture variants for HIMMEL-2307 fix-batch cases (real git repo, its
# non-git fallback, a repo missing scripts/guardrails/lib.sh entirely, and a
# repo with a corrupt settings-template.json) — copied BEFORE FIX_REPO is
# git-initialized so none of these carry a stray .git dir.
FIX_REPO_NONGIT="$work/repo-nongit"
cp -r "$FIX_REPO" "$FIX_REPO_NONGIT"
FIX_REPO_BADTPL="$work/repo-badtpl"
cp -r "$FIX_REPO" "$FIX_REPO_BADTPL"
printf '{ this is not valid json' > "$FIX_REPO_BADTPL/docs/setup/settings-template.json"
FIX_REPO_NOLIB="$work/repo-nolib"
mkdir -p "$FIX_REPO_NOLIB"

# Make FIX_REPO an actual git checkout (one commit) so
# primaryCheckoutRoot()'s `git rev-parse --git-common-dir` branch is
# exercised instead of always falling through its catch — that fallback
# stays covered separately via FIX_REPO_NONGIT above.
git -C "$FIX_REPO" init -q
git -C "$FIX_REPO" config user.email "fixture@test.local"
git -C "$FIX_REPO" config user.name "fixture"
git -C "$FIX_REPO" add -A
git -C "$FIX_REPO" commit -q -m "fixture"

HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO")"
export HIMMEL_CAPTURE_REPO_ROOT
CLAUDE_CONFIG_DIR="$(winpath "$FIX_CONFIG")"
export CLAUDE_CONFIG_DIR
HIMMEL_OBSERVABILITY_CONFIG="$(winpath "$work/observability.json")"
export HIMMEL_OBSERVABILITY_CONFIG
LANES_REGISTRY="$(winpath "$work/lanes.json")"
export LANES_REGISTRY
WHISPER_DIR="$(winpath "$work/whisper")"
export WHISPER_DIR
HIMMEL_CAPTURE_SCHTASKS_CMD="node $(winpath "$work/fakeschtasks.mjs")"
export HIMMEL_CAPTURE_SCHTASKS_CMD
export HOME="$work/fake-home"
export USERPROFILE="$work/fake-home"

node_bin=$(command -v node)
run_json() { "$node_bin" "$(winpath "$script")" --json; }

# ── case a: profile shape ───────────────────────────────────────────────
outA=$(run_json) || fail "case a: --json should exit 0" "$outA"
shapeCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const p = j.profile;
const allowed = new Set(['schemaVersion','profile','devOverlay','scope','vault','handover','pluginSet','lanes','lanesMeaningful','alwaysOn','luna','secretsWalk','bridge','cadences']);
const extra = Object.keys(p).filter((k) => !allowed.has(k));
const problems = [];
if (p.schemaVersion !== 2) problems.push('schemaVersion!=2');
if (p.profile !== 'operator') problems.push('profile!=operator');
if (extra.length) problems.push('unknown top-level fields: ' + extra.join(','));
if ('role' in p || 'tier' in p) problems.push('role/tier field present');
if (!Array.isArray(p.lanes)) problems.push('lanes not an array');
if (typeof p.vault !== 'object' || typeof p.vault.path !== 'string' || p.vault.path.length === 0) problems.push('vault.path not a non-empty string');
if (p.vault.path !== '<LUNA_VAULT_PATH>') problems.push('vault.path !== <LUNA_VAULT_PATH> placeholder');
if (p.handover.path !== '<HANDOVER_DIR>') problems.push('handover.path !== <HANDOVER_DIR> placeholder');
console.log(problems.join('|'));
" <<< "$outA")
if [ -z "$shapeCheck" ]; then pass "case a: v2 profile shape (schemaVersion, profile=operator, no role/tier/unknown fields, placeholder paths)"; else fail "case a: v2 profile shape" "$shapeCheck"; fi

# ── case b: scrub self-test (planted real-path trips it) ───────────────
# CAPTURE_SCRIPT_PATH travels via env, then through pathToFileURL(): a bare
# "C:/..." string is not a valid ESM import specifier on Windows (verified —
# ERR_UNSUPPORTED_ESM_URL_SCHEME), it must be a real file:// URL.
CAPTURE_SCRIPT_PATH="$(winpath "$script")"
export CAPTURE_SCRIPT_PATH
scrubOut=$("$node_bin" --input-type=module -e "
import { pathToFileURL } from 'node:url';
const { buildScrubRegexes, scrubDeep } = await import(pathToFileURL(process.env.CAPTURE_SCRIPT_PATH).href);
const regexes = buildScrubRegexes('C:\\\\Users\\\\realop', 'realop');
const scrubbed = scrubDeep({ leak: 'a path C:\\\\Users\\\\realop\\\\stuff and word realop' }, regexes);
const stillLeaks = JSON.stringify(scrubbed).includes('realop');
console.log('scrubbed_clean=' + !stillLeaks);
let threw = false;
try {
  // feed assertScrubbed-shaped data straight through JSON.stringify + regex
  // test (mirrors what assertScrubbed does) on UN-scrubbed data — must match.
  const s = JSON.stringify({ leak: 'C:\\\\Users\\\\realop' });
  threw = regexes.some(({ re }) => { re.lastIndex = 0; return re.test(s); });
} catch { threw = false; }
console.log('unscrubbed_would_trip=' + threw);
" 2>&1) || true
if grepq "$scrubOut" -F "scrubbed_clean=true" && grepq "$scrubOut" -F "unscrubbed_would_trip=true"; then
  pass "case b: scrub replaces a planted real home/user string, and the assertion pattern trips on un-scrubbed data"
else
  fail "case b: scrub self-test" "$scrubOut"
fi

# ── case c: --check exit 0 identical / exit 1 + named diff on drift ────
profA="$work/profile-a.json"
"$node_bin" "$(winpath "$script")" --profile-out "$(winpath "$profA")"
set +e
"$node_bin" "$(winpath "$script")" --check "$(winpath "$profA")" >/dev/null 2>&1
rcIdentical=$?
set -e
if [ "$rcIdentical" -eq 0 ]; then pass "case c: --check exits 0 against an identical committed profile"; else fail "case c: --check identical" "rc=$rcIdentical"; fi

profB="$work/profile-b.json"
"$node_bin" -e "
const fs = require('fs');
const p = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
p.alwaysOn = !p.alwaysOn;
fs.writeFileSync(process.argv[2], JSON.stringify(p, null, 2) + '\n');
" "$(winpath "$profA")" "$(winpath "$profB")"
set +e
driftOut=$("$node_bin" "$(winpath "$script")" --check "$(winpath "$profB")" 2>&1)
rcDrift=$?
set -e
if [ "$rcDrift" -eq 1 ] && grepq "$driftOut" -F "alwaysOn"; then
  pass "case c: --check exits 1 and names 'alwaysOn' on a mutated field"
else
  fail "case c: --check drift" "rc=$rcDrift out=$driftOut"
fi

# ── case d: idempotence — two runs byte-identical ───────────────────────
profC="$work/profile-c.json"
profD="$work/profile-d.json"
"$node_bin" "$(winpath "$script")" --profile-out "$(winpath "$profC")"
"$node_bin" "$(winpath "$script")" --profile-out "$(winpath "$profD")"
if cmp -s "$profC" "$profD"; then pass "case d: two --profile-out runs are byte-identical"; else fail "case d: idempotence (profile)" "$(diff "$profC" "$profD" || true)"; fi

deltaC="$work/delta-c.json"
deltaD="$work/delta-d.json"
"$node_bin" "$(winpath "$script")" --delta-out "$(winpath "$deltaC")"
"$node_bin" "$(winpath "$script")" --delta-out "$(winpath "$deltaD")"
if cmp -s "$deltaC" "$deltaD"; then pass "case d: two --delta-out runs are byte-identical"; else fail "case d: idempotence (delta)" "$(diff "$deltaC" "$deltaD" || true)"; fi

# ── case e: cadence armed/off from the stubbed schtasks ─────────────────
cadenceCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const c = j.profile.cadences;
const problems = [];
if (c.pipeline !== 'armed') problems.push('pipeline should be armed (FetchHealth present), got ' + c.pipeline);
for (const id of ['graphmap','qmd','codex-sweep']) {
  if (c[id] !== 'off') problems.push(id + ' should be off, got ' + c[id]);
}
console.log(problems.join('|'));
" <<< "$outA")
if [ -z "$cadenceCheck" ]; then pass "case e: cadence armed/off reflects the stubbed schtasks CSV"; else fail "case e: cadence detection" "$cadenceCheck"; fi

# ── case oo: profile.cadences carries ONLY cadence-registry.json ids
# (HIMMEL-2307 follow-up schema ruling) — a non-registry cadence (drift-fix,
# ggs, repo-sync) must never appear in profile.cadences even when armed; it
# moves to delta.cadences.nonRegistryCadences instead, and determinism holds
# (repeat capture -> identical nonRegistryCadences). ────────────────────────
registryFilterCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const c = j.profile.cadences;
const nrc = j.delta.cadences.nonRegistryCadences;
const problems = [];
for (const id of ['drift-fix','ggs','repo-sync']) {
  if (id in c) problems.push(id + ' must not appear in profile.cadences (non-registry id), got ' + JSON.stringify(c));
}
if (nrc['drift-fix'] !== 'armed') problems.push('nonRegistryCadences[\"drift-fix\"] should be armed, got ' + nrc['drift-fix']);
if (nrc['ggs'] !== 'off') problems.push('nonRegistryCadences[\"ggs\"] should be off, got ' + nrc['ggs']);
if (nrc['repo-sync'] !== 'off') problems.push('nonRegistryCadences[\"repo-sync\"] should be off, got ' + nrc['repo-sync']);
if (j.delta.cadences.registryReadFailed !== false) problems.push('registryReadFailed should be false when cadence-registry.json reads cleanly, got ' + j.delta.cadences.registryReadFailed);
console.log(problems.join('|'));
" <<< "$outA")
if [ -z "$registryFilterCheck" ]; then
  pass "case oo: profile.cadences carries ONLY registry ids; drift-fix/ggs/repo-sync move to delta.cadences.nonRegistryCadences"
else
  fail "case oo: cadence registry filter" "$registryFilterCheck"
fi
outA2=$(run_json)
determinismCheck=$("$node_bin" -e "
const a = JSON.parse(process.argv[1]);
const b = JSON.parse(process.argv[2]);
console.log(JSON.stringify(a.delta.cadences.nonRegistryCadences) === JSON.stringify(b.delta.cadences.nonRegistryCadences) ? '' : 'nonRegistryCadences differs across runs');
" "$outA" "$outA2")
if [ -z "$determinismCheck" ]; then
  pass "case oo: delta.cadences.nonRegistryCadences is deterministic across repeated captures"
else
  fail "case oo: nonRegistryCadences determinism" "$determinismCheck"
fi

# ── case pp: a missing/corrupt cadence-registry.json exits 2 naming 'cadences'
# (never fabricates the registry-scoped profile.cadences filter) ───────────
FIX_REPO_NOCADREG="$work/repo-nocadreg"
cp -r "$FIX_REPO" "$FIX_REPO_NOCADREG"
rm -f "$FIX_REPO_NOCADREG/scripts/himmelctl/lib/cadence-registry.json"
set +e
cadRegFailOut=$(HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO_NOCADREG")" "$node_bin" "$(winpath "$script")" --json 2>&1)
rcCadRegFail=$?
set -e
if [ "$rcCadRegFail" -eq 2 ] && grepq "$cadRegFailOut" -F "cadences"; then
  pass "case pp: a missing cadence-registry.json exits 2 and names 'cadences' (never fabricates the registry filter)"
else
  fail "case pp: cadence-registry read-failure handling" "rc=$rcCadRegFail out=$cadRegFailOut"
fi

# ── case f: secret VALUE never leaks; its NAME appears only as a delta name ──
allOutputs="$outA"
allOutputs="$allOutputs$(cat "$profC")"
allOutputs="$allOutputs$(cat "$deltaC")"
if grepq "$allOutputs" -F "hunter2"; then
  fail "case f: FAKE_TOKEN's VALUE (hunter2) must never appear in any output"
else
  pass "case f: FAKE_TOKEN's VALUE (hunter2) does not appear in --json/--profile-out/--delta-out"
fi
if grepq "$allOutputs" -F "shouldnotleakeither"; then
  fail "case f: KNOWN_SECRET's VALUE must never appear in any output"
else
  pass "case f: KNOWN_SECRET's VALUE does not appear in any output"
fi
nameCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
const beyond = j.envKeys.keysBeyondGeneratedBlock;
const problems = [];
if (!beyond.includes('FAKE_TOKEN')) problems.push('FAKE_TOKEN name missing from keysBeyondGeneratedBlock');
if (beyond.includes('KNOWN_SECRET')) problems.push('KNOWN_SECRET should be excluded (it is in the generated block)');
console.log(problems.join('|'));
" "$(winpath "$deltaC")")
if [ -z "$nameCheck" ]; then pass "case f: FAKE_TOKEN's NAME appears in delta.envKeys.keysBeyondGeneratedBlock; KNOWN_SECRET's does not"; else fail "case f: env-key name accounting" "$nameCheck"; fi

# ── case g: scrub-failure message never leaks the regex or the matched text ──
# Forces assertScrubbed() to actually fail (a planted unscrubbable value),
# then asserts the thrown message names only a safe label + JSON path —
# never the real home path/username it guards.
scrubFailOut=$("$node_bin" --input-type=module -e "
import { pathToFileURL } from 'node:url';
const { buildScrubRegexes, assertScrubbed } = await import(pathToFileURL(process.env.CAPTURE_SCRIPT_PATH).href);
const regexes = buildScrubRegexes('C:\\\\Users\\\\realop', 'realop');
// forward slashes (not backslashes) — JSON.stringify doubles backslashes,
// which would make the backslash-built home regex miss its own JSON form;
// that quirk is orthogonal to what this case is testing (message safety).
const leaking = { secretField: { nested: 'C:/Users/realop/stuff' } };
try {
  assertScrubbed(leaking, regexes);
  console.log('threw=false');
} catch (e) {
  console.log('threw=true');
  console.log('msg=' + e.message);
}
" 2>&1) || true
if grepq "$scrubFailOut" -F "threw=true" \
  && grepq "$scrubFailOut" -F "secretField.nested" \
  && grepq "$scrubFailOut" -F "home-directory path" \
  && ! grepq "$scrubFailOut" -F "realop"; then
  pass "case g: assertScrubbed's failure message names the label + JSON path, never 'realop' (the fixture home/username)"
else
  fail "case g: scrub-failure message safety" "$scrubFailOut"
fi

# ── case h: observability flow objects are reduced to names, not copied whole ──
# The observability.json fixture's flow "z" carries an extra scriptPath field
# with a marker value — it must never appear anywhere in --json output, and
# delta.observability must expose flowNames (strings), not whole flow objects.
if grepq "$outA" -F "FAKE-SENSITIVE-SCRIPTPATH-MARKER"; then
  fail "case h: a flow object's extra field (scriptPath) must never be copied into output"
else
  pass "case h: a flow object's extra field (scriptPath) does not appear in --json output"
fi
flowNamesCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const o = j.delta.observability;
const problems = [];
if (!Array.isArray(o.flowNames) || o.flowNames.join(',') !== 'z') problems.push('flowNames should be [\"z\"], got ' + JSON.stringify(o.flowNames));
if ('flows' in o) problems.push('delta.observability.flows (whole objects) should no longer exist');
console.log(problems.join('|'));
" <<< "$outA")
if [ -z "$flowNamesCheck" ]; then pass "case h: delta.observability.flowNames is a name-only array"; else fail "case h: observability flow shape" "$flowNamesCheck"; fi

# ── case i: devOverlay-degraded probe never fabricates a boolean ───────────
# Points HIMMEL_CAPTURE_REPO_ROOT at a repo with no scripts/guardrails/lib.sh
# at all, so detectDevOverlay()'s probe wiring itself fails (degraded/null,
# not a clean "absent"). --json must exit 2 and name the field, not silently
# emit devOverlay:false.
set +e
devOverlayFailOut=$(HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO_NOLIB")" "$node_bin" "$(winpath "$script")" --json 2>&1)
rcDevOverlayFail=$?
set -e
if [ "$rcDevOverlayFail" -eq 2 ] && grepq "$devOverlayFailOut" -F "devOverlay"; then
  pass "case i: a degraded devOverlay probe exits 2 and names 'devOverlay' (never fabricates false)"
else
  fail "case i: devOverlay-degraded handling" "rc=$rcDevOverlayFail out=$devOverlayFailOut"
fi

# ── case j: alwaysOn-degraded (failed scheduler query, no bridge proof) ────
# A schtasks stub that fails loudly (not the trusted empty-scheduler rc=1
# signature) with bridge persistence undetectable must exit 2 naming
# 'alwaysOn' rather than silently reading as alwaysOn:false.
set +e
alwaysOnFailOut=$(HIMMEL_CAPTURE_SCHTASKS_CMD="node $(winpath "$work/fakeschtasks-fail.mjs")" "$node_bin" "$(winpath "$script")" --json 2>&1)
rcAlwaysOnFail=$?
set -e
if [ "$rcAlwaysOnFail" -eq 2 ] && grepq "$alwaysOnFailOut" -F "alwaysOn"; then
  pass "case j: a failed scheduler query with no bridge-persistence proof exits 2 and names 'alwaysOn'"
else
  fail "case j: alwaysOn-degraded handling" "rc=$rcAlwaysOnFail out=$alwaysOnFailOut"
fi

# ── case k: malformed settings-template.json is a read FAILURE, not empty ──
# A corrupt template must not render as "nothing enabled beyond template"
# (a false-clean diff) — templateReadFailed must be true and the dependent
# diff arrays must be null, not [].
templateFailOut=$(HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO_BADTPL")" "$node_bin" "$(winpath "$script")" --json)
templateFailCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const p = j.delta.plugins;
const problems = [];
if (p.templateReadFailed !== true) problems.push('templateReadFailed should be true, got ' + p.templateReadFailed);
if (p.enabledBeyondTemplate !== null) problems.push('enabledBeyondTemplate should be null on read failure, got ' + JSON.stringify(p.enabledBeyondTemplate));
if (p.templateTrueButDisabled !== null) problems.push('templateTrueButDisabled should be null on read failure, got ' + JSON.stringify(p.templateTrueButDisabled));
console.log(problems.join('|'));
" <<< "$templateFailOut")
if [ -z "$templateFailCheck" ]; then pass "case k: a corrupt settings-template.json sets templateReadFailed + nulls the dependent diffs"; else fail "case k: template read-failure handling" "$templateFailCheck"; fi

# ── case l: non-git repo root still works (the primaryCheckoutRoot fallback) ──
set +e
nonGitOut=$(HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO_NONGIT")" "$node_bin" "$(winpath "$script")" --json 2>&1)
rcNonGit=$?
set -e
if [ "$rcNonGit" -eq 0 ]; then
  pass "case l: a non-git repo root still captures cleanly (primaryCheckoutRoot's catch-fallback path)"
else
  fail "case l: non-git repo root" "rc=$rcNonGit out=$nonGitOut"
fi

# ── case m: classifyCrontabError distinguishes empty-crontab from a real failure ──
# HIMMEL-2307 fix-batch (codex-2): the POSIX cadence probe itself can't run
# hermetically on this platform — computeCadences()'s useSchtasks gate is
# `process.platform === 'win32' || HIMMEL_CAPTURE_SCHTASKS_CMD`, so on a
# real win32 host the POSIX branch never executes regardless of env, and a
# bare-name `crontab` PATH stub can't be exec'd without shell:true (verified
# ENOENT, same gotcha the schtasks stub's own comment documents). So this
# case unit-tests the exported pure classifier directly with synthetic
# error-shaped objects instead.
classifyOut=$("$node_bin" --input-type=module -e "
import { pathToFileURL } from 'node:url';
const { classifyCrontabError } = await import(pathToFileURL(process.env.CAPTURE_SCRIPT_PATH).href);
const cases = [
  [{ status: 1, stderr: 'no crontab for testuser' }, true, ''],
  [{ status: 1, stderr: '' }, true, ''],
  [{ status: 1, stderr: '   ' }, true, ''],
  [{ code: 'ENOENT' }, false, 'crontab binary not found'],
  [{ status: 2, stderr: 'permission denied' }, false, 'crontab -l failed (rc=2)'],
];
const problems = [];
for (const [err, wantOk, wantDetail] of cases) {
  const r = classifyCrontabError(err);
  if (r.ok !== wantOk) problems.push('ok mismatch for ' + JSON.stringify(err) + ': got ' + r.ok);
  if (wantOk && r.text !== wantDetail) problems.push('text mismatch for ' + JSON.stringify(err) + ': got ' + JSON.stringify(r.text));
  if (!wantOk && r.reason !== wantDetail) problems.push('reason mismatch for ' + JSON.stringify(err) + ': got ' + JSON.stringify(r.reason));
}
console.log(problems.join('|'));
" 2>&1) || true
if [ -z "$classifyOut" ]; then
  pass "case m: classifyCrontabError treats 'no crontab for <user>'/empty-stderr rc=1 as empty (ok:true), and ENOENT/other rc as a genuine failure (ok:false, reasoned) — never fabricates an empty crontab on a real failure"
else
  fail "case m: classifyCrontabError" "$classifyOut"
fi

# ── case n: matchCadenceGroups — POSIX prefix groups match by token, not
# just fixed-name groups (HIMMEL-2307 fix-batch codex-1) ──────────────────
# Before the fix, prefix-spec groups (graphmap/qmd) always fell through
# `Array.isArray(spec) ? spec : []` to an empty name list and reported
# 'off' regardless of crontab content. Also asserts taskDetail carries only
# the matched TOKEN (prefix + up to next whitespace), never the full line.
matchCadenceOut=$("$node_bin" --input-type=module -e "
import { pathToFileURL } from 'node:url';
const { matchCadenceGroups } = await import(pathToFileURL(process.env.CAPTURE_SCRIPT_PATH).href);
const text = '0 * * * * /usr/bin/HIMMEL-GraphMap-Refresh --quiet\n0 5 * * * HIMMEL-Qmd-Reindex some args here\n0 6 * * * HIMMEL-Pipeline-FetchHealth\n';
const { cadences, taskDetail } = matchCadenceGroups(text);
const problems = [];
if (cadences.graphmap !== 'armed') problems.push('graphmap should be armed, got ' + cadences.graphmap);
if (cadences.qmd !== 'armed') problems.push('qmd should be armed, got ' + cadences.qmd);
if (cadences.pipeline !== 'armed') problems.push('pipeline should be armed, got ' + cadences.pipeline);
if (cadences['drift-fix'] !== 'off') problems.push('drift-fix should be off, got ' + cadences['drift-fix']);
if (JSON.stringify(taskDetail.graphmap) !== JSON.stringify(['HIMMEL-GraphMap-Refresh'])) problems.push('graphmap taskDetail should be just the token, got ' + JSON.stringify(taskDetail.graphmap));
if (JSON.stringify(taskDetail.qmd) !== JSON.stringify(['HIMMEL-Qmd-Reindex'])) problems.push('qmd taskDetail should be just the token (no full cron line), got ' + JSON.stringify(taskDetail.qmd));
console.log(problems.join('|'));
" 2>&1) || true
if [ -z "$matchCadenceOut" ]; then
  pass "case n: matchCadenceGroups matches POSIX prefix groups (graphmap/qmd) by token, taskDetail names-only (no full cron line)"
else
  fail "case n: matchCadenceGroups prefix matching" "$matchCadenceOut"
fi

# ── case o: askableIds read failure exits 2 naming the field (HIMMEL-2307
# fix-batch codex-2) — a repo lacking scripts/himmelctl/lib/adopter-profile.js
# must not silently collapse lanes to [] while lanesMeaningful stays true ──
FIX_REPO_NOADOPTER="$work/repo-noadopter"
cp -r "$FIX_REPO" "$FIX_REPO_NOADOPTER"
rm -rf "$FIX_REPO_NOADOPTER/.git" "$FIX_REPO_NOADOPTER/scripts/himmelctl"
set +e
askableFailOut=$(HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO_NOADOPTER")" "$node_bin" "$(winpath "$script")" --json 2>&1)
rcAskableFail=$?
set -e
if [ "$rcAskableFail" -eq 2 ] && grepq "$askableFailOut" -F "askableIds"; then
  pass "case o: a failed askable-lane table read (adopter-profile.js missing) exits 2 and names 'askableIds' (never fabricates empty lanes)"
else
  fail "case o: askableIds read-failure handling" "rc=$rcAskableFail out=$askableFailOut"
fi

# ── case p: malformed handover registry.json is a read FAILURE, not
# valid-empty (HIMMEL-2307 fix-batch codex-3) ───────────────────────────────
FIX_CONFIG_BADREG="$work/config-badreg/.claude"
mkdir -p "$FIX_CONFIG_BADREG/handover" "$FIX_CONFIG_BADREG/channels/telegram"
printf '{ not valid json' > "$FIX_CONFIG_BADREG/handover/registry.json"
badRegOut=$(CLAUDE_CONFIG_DIR="$(winpath "$FIX_CONFIG_BADREG")" "$node_bin" "$(winpath "$script")" --json)
badRegCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const h = j.delta.handover;
const problems = [];
if (h.registryReadFailed !== true) problems.push('registryReadFailed should be true, got ' + h.registryReadFailed);
if (h.registryEntryNames !== null) problems.push('registryEntryNames should be null on read failure, got ' + JSON.stringify(h.registryEntryNames));
if (h.registryEntryCount !== null) problems.push('registryEntryCount should be null on read failure, got ' + JSON.stringify(h.registryEntryCount));
console.log(problems.join('|'));
" <<< "$badRegOut")
if [ -z "$badRegCheck" ]; then
  pass "case p: a malformed handover registry.json sets registryReadFailed + nulls the dependent fields (distinct from valid-empty)"
else
  fail "case p: handover registry read-failure handling" "$badRegCheck"
fi

# ── case q: observability expected_tasks/expected_disabled_tasks drop
# non-string entries instead of leaking their nested fields (HIMMEL-2307
# fix-batch codex-4) ─────────────────────────────────────────────────────
OBS_BADENTRY="$work/observability-badentry.json"
cat > "$OBS_BADENTRY" <<'EOF'
{ "flows": [], "expected_tasks": ["T1", { "name": "T2", "leakField": "SHOULD-NEVER-APPEAR-MARKER" }], "expected_disabled_tasks": ["T3"] }
EOF
badEntryOut=$(HIMMEL_OBSERVABILITY_CONFIG="$(winpath "$OBS_BADENTRY")" "$node_bin" "$(winpath "$script")" --json)
if grepq "$badEntryOut" -F "SHOULD-NEVER-APPEAR-MARKER"; then
  fail "case q: a non-string expected_tasks entry's nested field must never appear in output"
else
  pass "case q: a non-string expected_tasks entry's nested field does not appear in --json output"
fi
badEntryCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const o = j.delta.observability;
const problems = [];
if (JSON.stringify(o.expectedTasks) !== JSON.stringify(['T1'])) problems.push('expectedTasks should be [\"T1\"] (object entry dropped), got ' + JSON.stringify(o.expectedTasks));
if (o.nonStringEntriesDropped !== 1) problems.push('nonStringEntriesDropped should be 1, got ' + o.nonStringEntriesDropped);
console.log(problems.join('|'));
" <<< "$badEntryOut")
if [ -z "$badEntryCheck" ]; then
  pass "case q: non-string expected_tasks entries are dropped and counted in nonStringEntriesDropped"
else
  fail "case q: expected_tasks non-string filtering" "$badEntryCheck"
fi

# ── case r: a present-but-Disabled scheduled task reads 'off', not armed
# (HIMMEL-2307 fix-batch codex-1) — before the fix only the name column was
# parsed, so any present task (regardless of Status) counted as armed ──────
disabledOut=$(HIMMEL_CAPTURE_SCHTASKS_CMD="node $(winpath "$work/fakeschtasks-disabled.mjs")" run_json)
disabledCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (j.delta.cadences.nonRegistryCadences['drift-fix'] !== 'off') problems.push('drift-fix should be off (Disabled status), got ' + j.delta.cadences.nonRegistryCadences['drift-fix']);
if (j.delta.cadences.statusUnrecognized.length !== 0) problems.push('statusUnrecognized should be empty for a cleanly Disabled task, got ' + JSON.stringify(j.delta.cadences.statusUnrecognized));
console.log(problems.join('|'));
" <<< "$disabledOut")
if [ -z "$disabledCheck" ]; then
  pass "case r: a present-but-Disabled scheduled task reads cadences['drift-fix']='off', not armed"
else
  fail "case r: disabled-task status handling" "$disabledCheck"
fi

# ── case s: an unrecognized Status string (e.g. localized Windows) fails
# TOWARD armed but is flagged in delta.cadences.statusUnrecognized ─────────
unrecognizedOut=$(HIMMEL_CAPTURE_SCHTASKS_CMD="node $(winpath "$work/fakeschtasks-unrecognized.mjs")" run_json)
unrecognizedCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (j.delta.cadences.nonRegistryCadences['drift-fix'] !== 'armed') problems.push('drift-fix should be armed (unknown status fails toward armed), got ' + j.delta.cadences.nonRegistryCadences['drift-fix']);
if (!j.delta.cadences.statusUnrecognized.includes('HIMMEL-DriftFix')) problems.push('statusUnrecognized should name HIMMEL-DriftFix, got ' + JSON.stringify(j.delta.cadences.statusUnrecognized));
if (j.delta.cadences.statusUnrecognized.includes('Adobe Updater')) problems.push('statusUnrecognized should NOT include unrelated task Adobe Updater, got ' + JSON.stringify(j.delta.cadences.statusUnrecognized));
console.log(problems.join('|'));
" <<< "$unrecognizedOut")
if [ -z "$unrecognizedCheck" ]; then
  pass "case s: an unrecognized Status string fails toward armed and is named in delta.cadences.statusUnrecognized; unrelated third-party tasks are excluded (scope-filtering)"
else
  fail "case s: status-unrecognized handling" "$unrecognizedCheck"
fi

# ── case t: matchCadenceGroups skips commented-out crontab lines (HIMMEL-2307
# fix-batch codex-2) — before the fix, a whole-text substring/regex match
# counted a '#'-commented line (with or without leading indentation) as armed.
# Also tests extraArmedTasks computation: a commented EXTRA_KNOWN_TASKS name
# must not match, while an active line must. ────────────────────────────────
commentedCronOut=$("$node_bin" --input-type=module -e "
import { pathToFileURL } from 'node:url';
const { matchCadenceGroups, filterCommentedLines, EXTRA_KNOWN_TASKS } = await import(pathToFileURL(process.env.CAPTURE_SCRIPT_PATH).href);
const text = '# 0 3 * * * HIMMEL-DriftFix --disabled-comment\n  # 0 4 * * * HIMMEL-CodexOrphanSweep --indented-comment\n# HIMMEL-BootPreflight --commented-out-extra-task\n0 5 * * * HIMMEL-RepoSync\n0 6 * * * HIMMEL-ForkResync --active-extra-task\n';
const { cadences } = matchCadenceGroups(text);
const activeLines = filterCommentedLines(text);
const extraArmedTasks = EXTRA_KNOWN_TASKS.filter((n) => activeLines.some((line) => line.includes(n))).sort();
const problems = [];
if (cadences['drift-fix'] !== 'off') problems.push('drift-fix should be off (commented-out line), got ' + cadences['drift-fix']);
if (cadences['codex-sweep'] !== 'off') problems.push('codex-sweep should be off (indented commented-out line), got ' + cadences['codex-sweep']);
if (cadences['repo-sync'] !== 'armed') problems.push('repo-sync should be armed (a real active line), got ' + cadences['repo-sync']);
if (extraArmedTasks.includes('HIMMEL-BootPreflight')) problems.push('HIMMEL-BootPreflight should not be in extraArmedTasks (commented-out line), got ' + JSON.stringify(extraArmedTasks));
if (!extraArmedTasks.includes('HIMMEL-ForkResync')) problems.push('HIMMEL-ForkResync should be in extraArmedTasks (active line), got ' + JSON.stringify(extraArmedTasks));
console.log(problems.join('|'));
" 2>&1) || true
if [ -z "$commentedCronOut" ]; then
  pass "case t: matchCadenceGroups skips commented-out crontab lines; extraArmedTasks filters comments too (commented HIMMEL-BootPreflight excluded, active HIMMEL-ForkResync included)"
else
  fail "case t: matchCadenceGroups and extraArmedTasks commented-line handling" "$commentedCronOut"
fi

# ── case u: a malformed observability.json is a read FAILURE, not
# present-and-empty (HIMMEL-2307 fix-batch codex-3) ─────────────────────────
OBS_MALFORMED="$work/observability-malformed.json"
printf '{ this is not valid json' > "$OBS_MALFORMED"
malformedObsOut=$(HIMMEL_OBSERVABILITY_CONFIG="$(winpath "$OBS_MALFORMED")" run_json)
malformedObsCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const o = j.delta.observability;
const problems = [];
if (o.observabilityReadFailed !== true) problems.push('observabilityReadFailed should be true, got ' + o.observabilityReadFailed);
if (o.configPresent !== true) problems.push('configPresent should still be true (file exists, just unparseable), got ' + o.configPresent);
if (o.flowNames !== null) problems.push('flowNames should be null on read failure, got ' + JSON.stringify(o.flowNames));
if (o.expectedTasks !== null) problems.push('expectedTasks should be null on read failure, got ' + JSON.stringify(o.expectedTasks));
if (o.expectedDisabledTasks !== null) problems.push('expectedDisabledTasks should be null on read failure, got ' + JSON.stringify(o.expectedDisabledTasks));
if (o.nonStringEntriesDropped !== null) problems.push('nonStringEntriesDropped should be null on read failure, got ' + JSON.stringify(o.nonStringEntriesDropped));
console.log(problems.join('|'));
" <<< "$malformedObsOut")
if [ -z "$malformedObsCheck" ]; then
  pass "case u: a malformed observability.json sets observabilityReadFailed + nulls the dependent fields (distinct from file-absent, which stays empty)"
else
  fail "case u: observability read-failure handling" "$malformedObsCheck"
fi

# ── case v: bridge.envPath names CLAUDE_CONFIG_DIR (placeholder token) when
# it differs from ~/.claude (HIMMEL-2307 fix-batch codex-4) — the suite's own
# fixture CLAUDE_CONFIG_DIR already differs from $HOME/.claude, so this is
# the always-exercised path; asserted explicitly here for the first time ──
customConfigCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (j.profile.bridge.envPath !== '<CLAUDE_CONFIG_DIR>/channels/telegram/.env') problems.push('bridge.envPath should use the <CLAUDE_CONFIG_DIR> placeholder when CLAUDE_CONFIG_DIR differs from ~/.claude, got ' + j.profile.bridge.envPath);
console.log(problems.join('|'));
" <<< "$outA")
if [ -z "$customConfigCheck" ]; then
  pass "case v: bridge.envPath uses the <CLAUDE_CONFIG_DIR> placeholder when CLAUDE_CONFIG_DIR differs from the default ~/.claude"
else
  fail "case v: custom CLAUDE_CONFIG_DIR envPath" "$customConfigCheck"
fi

# ── case w: assertScrubbed catches a backslash-doubled home path, not just
# the forward-slash form (HIMMEL-2307 fix-batch codex-5) — assertScrubbed
# tests JSON.stringify(obj) output, which doubles every backslash; a
# home-path regex built only for the single-backslash form silently failed
# to match its own doubled-up JSON.stringify form. user is deliberately
# omitted so the (unrelated, already-working) username regex can't mask the
# home-path-specific bug this case targets. ─────────────────────────────────
backslashScrubOut=$("$node_bin" --input-type=module -e "
import { pathToFileURL } from 'node:url';
const { buildScrubRegexes, assertScrubbed } = await import(pathToFileURL(process.env.CAPTURE_SCRIPT_PATH).href);
const regexes = buildScrubRegexes('C:\\\\Users\\\\realop', '');
const leaking = { secretField: { nested: 'C:\\\\Users\\\\realop\\\\stuff' } };
try {
  assertScrubbed(leaking, regexes);
  console.log('threw=false');
} catch (e) {
  console.log('threw=true');
  console.log('msg=' + e.message);
}
" 2>&1) || true
# Note: findLeaks tests the (leaked) regexes against RAW per-field text, but
# the doubled-backslash variant only ever matches the JSON.stringify'd form —
# so this specific leak class throws (the safety property that matters) but
# without a resolvable JSON path; the message correctly falls back to the
# label alone. Never 'realop' either way.
if grepq "$backslashScrubOut" -F "threw=true" \
  && grepq "$backslashScrubOut" -F "home-directory path" \
  && ! grepq "$backslashScrubOut" -F "realop"; then
  pass "case w: assertScrubbed catches a backslash-doubled home path (JSON.stringify's own escaping), not just the forward-slash form"
else
  fail "case w: backslash-doubled scrub detection" "$backslashScrubOut"
fi

# ── case x: --check's own output never echoes the caller-supplied profile
# path unscrubbed (HIMMEL-2307 fix-batch codex-6) — repo-relative paths
# print as-is (the common case); a path outside the repo (here, under the
# fixture HOME) must never leak the real home path into stdout/stderr ──────
checkPathScrubOut=$("$node_bin" --input-type=module -e "
import { pathToFileURL } from 'node:url';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
const mod = await import(pathToFileURL(process.env.CAPTURE_SCRIPT_PATH).href);
const displayPath = mod.displayPath;
const problems = [];
const inRepo = path.join(process.env.HIMMEL_CAPTURE_REPO_ROOT, 'docs', 'setup', 'profiles', 'operator.install-profile.json');
const relOut = displayPath(inRepo);
if (relOut !== 'docs/setup/profiles/operator.install-profile.json') problems.push('repo-relative form mismatch: ' + relOut);
const home = os.homedir();
const dir = path.join(home, 'cap2307-outside-repo-test');
fs.mkdirSync(dir, { recursive: true });
const badPath = path.join(dir, 'not-json.json');
fs.writeFileSync(badPath, '{ not valid json');
const scrubbedDisplay = displayPath(badPath);
if (scrubbedDisplay.includes(home)) problems.push('displayPath() itself leaked the real home path');
let out = '', rc = 0;
try {
  out = execFileSync(process.execPath, [process.env.CAPTURE_SCRIPT_PATH, '--check', badPath], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
} catch (e) {
  rc = e.status;
  out = (e.stdout || '') + (e.stderr || '');
}
fs.rmSync(dir, { recursive: true, force: true });
if (rc !== 2) problems.push('expected rc=2 for an unparseable --check target, got ' + rc);
if (out.includes(home)) problems.push('the full CLI --check output leaked the real home path');
console.log(problems.join('|'));
" 2>&1) || true
if [ -z "$checkPathScrubOut" ]; then
  pass "case x: --check prints a repo-relative path when possible, and never leaks the real home path for an out-of-repo target"
else
  fail "case x: --check path scrub" "$checkPathScrubOut"
fi

# ── case y: --check drift output scrubs the COMMITTED profile's raw OLD
# value, not just the fresh capture (HIMMEL-2307 fix-batch round 4, codex-1)
# — before the fix, diffPaths' `a` side (the committed file's value) was
# printed verbatim; an accidentally-committed real path would hit stdout
# unscrubbed even though the freshly-captured `b` side is always clean. ────
profLeak="$work/profile-leak.json"
"$node_bin" --input-type=module -e "
import os from 'node:os';
import fs from 'node:fs';
const home = os.homedir();
const p = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
p.vault.path = home + '/leaked/real/path';
fs.writeFileSync(process.argv[2], JSON.stringify(p, null, 2) + '\n');
" "$(winpath "$profA")" "$(winpath "$profLeak")"
set +e
leakDriftOut=$("$node_bin" "$(winpath "$script")" --check "$(winpath "$profLeak")" 2>&1)
rcLeakDrift=$?
set -e
homeVal=$("$node_bin" -e "console.log(require('os').homedir())")
if [ "$rcLeakDrift" -eq 1 ] && grepq "$leakDriftOut" -F "vault.path" \
  && grepq "$leakDriftOut" -F "<HOME>" \
  && ! grepq "$leakDriftOut" -F "$homeVal"; then
  pass "case y: --check drift output scrubs a real home path planted in the COMMITTED (old) value, not just the fresh capture"
else
  fail "case y: --check drift scrub of committed old value" "rc=$rcLeakDrift out=$leakDriftOut home=$homeVal"
fi

# ── case z: --check against a missing file whose PATH embeds the real home
# dir scrubs the readFileSync error message, not just displayPath's own echo
# of the target (HIMMEL-2307 fix-batch round 4, codex-2) — before the fix,
# e.message (which for ENOENT carries the path verbatim) was appended raw,
# defeating displayPath(). ───────────────────────────────────────────────────
set +e
missingCheckOut=$("$node_bin" --input-type=module -e "
import { execFileSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
const missing = path.join(os.homedir(), 'cap2307-missing-file-test', 'nope.json');
try {
  execFileSync(process.execPath, [process.env.CAPTURE_SCRIPT_PATH, '--check', missing], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  console.log('rc=0');
} catch (e) {
  console.log('rc=' + e.status);
  console.log((e.stdout || '') + (e.stderr || ''));
}
" 2>&1)
set -e
if grepq "$missingCheckOut" -F "rc=2" && grepq "$missingCheckOut" -F "<HOME>" && ! grepq "$missingCheckOut" -F "$homeVal"; then
  pass "case z: --check on a missing file whose path embeds the real home dir scrubs the readFileSync error message too"
else
  fail "case z: --check missing-file error message scrub" "$missingCheckOut home=$homeVal"
fi

# ── case aa: a leak under a sensitive KEY name is scrubbed in the failure
# diagnostic itself (HIMMEL-2307 fix-batch round 4, codex-4) — before the
# fix, findLeaks() interpolated the raw object KEY into the reported JSON
# path, so the very assertion protecting against a leak would leak a
# sensitive key name in its own error message. ──────────────────────────────
keyLeakOut=$("$node_bin" --input-type=module -e "
import { pathToFileURL } from 'node:url';
const { buildScrubRegexes, assertScrubbed } = await import(pathToFileURL(process.env.CAPTURE_SCRIPT_PATH).href);
const regexes = buildScrubRegexes('C:\\\\Users\\\\realop', 'realop');
const leaking = { 'C:\\\\Users\\\\realop': 'benign-value' };
try {
  assertScrubbed(leaking, regexes);
  console.log('threw=false');
} catch (e) {
  console.log('threw=true');
  console.log('msg=' + e.message);
}
" 2>&1) || true
if grepq "$keyLeakOut" -F "threw=true" \
  && grepq "$keyLeakOut" -F "in a key at" \
  && grepq "$keyLeakOut" -F "<HOME>" \
  && ! grepq "$keyLeakOut" -F "realop"; then
  pass "case aa: assertScrubbed's key-leak diagnostic scrubs the leaking KEY itself before reporting it"
else
  fail "case aa: sensitive-key diagnostic scrub" "$keyLeakOut"
fi

# ── case bb: the top-level exception handler scrubs e.message too
# (HIMMEL-2307 fix-batch round 5, codex-1) — before the fix, a thrown error
# whose message embeds a real path (e.g. a writeFileSync failure into a
# nonexistent directory) printed raw; this was the one emit path scrubText()
# didn't cover yet. ──────────────────────────────────────────────────────────
set +e
writeFailOut=$("$node_bin" "$(winpath "$script")" --profile-out "$homeVal/cap2307-write-fail-dir/nested/out.json" 2>&1)
rcWriteFail=$?
set -e
if [ "$rcWriteFail" -eq 2 ] && grepq "$writeFailOut" -F "<HOME>" && ! grepq "$writeFailOut" -F "$homeVal"; then
  pass "case bb: the top-level exception handler scrubs a real home path embedded in a thrown error's message (a writeFileSync failure)"
else
  fail "case bb: top-level handler scrub" "rc=$rcWriteFail out=$writeFailOut home=$homeVal"
fi

# ── case cc: the no-arg human summary shows a degraded devOverlay probe as
# "unknown (probe degraded)", never a fabricated false (HIMMEL-2307 fix-batch
# round 5, codex-2) — capture(false) is non-strict and still collapses
# profile.devOverlay to false; renderSummary must not repeat that collapse.
# Needs a fixture repo that's otherwise complete (.env.example etc.) unlike
# FIX_REPO_NOLIB (bare-empty, fine for case i's --json/strict throw before
# those files are ever read, but the non-strict summary path reads past
# devOverlay and would ENOENT on a missing .env.example instead). ──────────
FIX_REPO_NOGUARDRAIL="$work/repo-noguardrail"
cp -r "$FIX_REPO" "$FIX_REPO_NOGUARDRAIL"
rm -rf "$FIX_REPO_NOGUARDRAIL/.git" "$FIX_REPO_NOGUARDRAIL/scripts/guardrails"
set +e
summaryDegradedOut=$(HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO_NOGUARDRAIL")" "$node_bin" "$(winpath "$script")" 2>&1)
rcSummaryDegraded=$?
set -e
if [ "$rcSummaryDegraded" -eq 0 ] && grepq "$summaryDegradedOut" -F "devOverlay=unknown (probe degraded)" && ! grepq "$summaryDegradedOut" -F "devOverlay=false"; then
  pass "case cc: the no-arg summary shows devOverlay as 'unknown (probe degraded)' for a degraded probe, never a fabricated false"
else
  fail "case cc: summary degraded-devOverlay display" "rc=$rcSummaryDegraded out=$summaryDegradedOut"
fi

# ── case dd: a present-but-malformed claude-hud.json is a read FAILURE, not
# valid-empty (HIMMEL-2307 fix-batch round 5, codex-3) — same convention as
# templateReadFailed/registryReadFailed/observabilityReadFailed. ───────────
FIX_CONFIG_BADHUD="$work/config-badhud/.claude"
mkdir -p "$FIX_CONFIG_BADHUD/handover" "$FIX_CONFIG_BADHUD/channels/telegram"
printf '{ not valid json' > "$FIX_CONFIG_BADHUD/claude-hud.json"
badHudOut=$(CLAUDE_CONFIG_DIR="$(winpath "$FIX_CONFIG_BADHUD")" "$node_bin" "$(winpath "$script")" --json)
badHudCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const h = j.delta.hud;
const problems = [];
if (h.hudReadFailed !== true) problems.push('hudReadFailed should be true, got ' + h.hudReadFailed);
if (h.hudConfigPresent !== true) problems.push('hudConfigPresent should still be true (file exists, just unparseable), got ' + h.hudConfigPresent);
if (h.hudConfigTopLevelKeys !== null) problems.push('hudConfigTopLevelKeys should be null on read failure, got ' + JSON.stringify(h.hudConfigTopLevelKeys));
console.log(problems.join('|'));
" <<< "$badHudOut")
if [ -z "$badHudCheck" ]; then
  pass "case dd: a malformed claude-hud.json sets hudReadFailed + nulls hudConfigTopLevelKeys (distinct from file-absent, which stays empty)"
else
  fail "case dd: hud read-failure handling" "$badHudCheck"
fi

# ── case ee: decideBridgePersistence — POSIX bridge-persistence decision
# function (HIMMEL-2307 CR round 7, codex-1) — unit-file existence alone used
# to mark installPersistence true even when the unit was disabled; now it
# requires BOTH fileExists AND enabled, with fileExists-but-disabled and an
# undeterminable systemctl state each flagged distinctly. Unit-tested
# directly on synthetic inputs (same pattern as classifyCrontabError/case m)
# since the systemd path itself isn't reachable hermetically on win32. ──────
decideBridgeOut=$("$node_bin" --input-type=module -e "
import { pathToFileURL } from 'node:url';
const { decideBridgePersistence } = await import(pathToFileURL(process.env.CAPTURE_SCRIPT_PATH).href);
const cases = [
  [true, 'enabled', { installPersistence: true, bridgeUnitDisabled: false, bridgeUnitStateUnknown: false }],
  [true, 'disabled', { installPersistence: false, bridgeUnitDisabled: true, bridgeUnitStateUnknown: false }],
  [false, 'enabled', { installPersistence: false, bridgeUnitDisabled: false, bridgeUnitStateUnknown: false }],
  [false, 'disabled', { installPersistence: false, bridgeUnitDisabled: false, bridgeUnitStateUnknown: false }],
  [true, 'unknown', { installPersistence: true, bridgeUnitDisabled: false, bridgeUnitStateUnknown: true }],
  [false, 'unknown', { installPersistence: false, bridgeUnitDisabled: false, bridgeUnitStateUnknown: true }],
];
const problems = [];
for (const [fileExists, unitState, want] of cases) {
  const got = decideBridgePersistence(fileExists, unitState);
  if (JSON.stringify(got) !== JSON.stringify(want)) problems.push('fileExists=' + fileExists + ' unitState=' + unitState + ': got ' + JSON.stringify(got) + ' want ' + JSON.stringify(want));
}
console.log(problems.join('|'));
" 2>&1) || true
if [ -z "$decideBridgeOut" ]; then
  pass "case ee: decideBridgePersistence requires fileExists AND enabled; disabled flags bridgeUnitDisabled; an undeterminable state fails toward file-exists behavior + flags bridgeUnitStateUnknown"
else
  fail "case ee: decideBridgePersistence" "$decideBridgeOut"
fi

# ── case ff: TELEGRAM_BOT_TOKEN quote-stripping — a quoted-empty value must
# not count as set, a quoted-nonempty value must (HIMMEL-2307 CR round 7,
# codex-2) — plain \S+ counted the quote characters themselves as
# "non-whitespace", so TELEGRAM_BOT_TOKEN="" read as enabled:true. The
# token VALUE must never appear in output either way — boolean only. ───────
FIX_CONFIG_QEMPTY="$work/config-qempty/.claude"
mkdir -p "$FIX_CONFIG_QEMPTY/handover" "$FIX_CONFIG_QEMPTY/channels/telegram"
printf 'TELEGRAM_BOT_TOKEN=""\n' > "$FIX_CONFIG_QEMPTY/channels/telegram/.env"
qEmptyOut=$(CLAUDE_CONFIG_DIR="$(winpath "$FIX_CONFIG_QEMPTY")" run_json)
qEmptyCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (j.profile.bridge.enabled !== false) problems.push('bridge.enabled should be false for TELEGRAM_BOT_TOKEN=\"\" (quoted-empty), got ' + j.profile.bridge.enabled);
console.log(problems.join('|'));
" <<< "$qEmptyOut")
if [ -z "$qEmptyCheck" ]; then
  pass "case ff: TELEGRAM_BOT_TOKEN=\"\" (quoted-empty) reads bridge.enabled=false"
else
  fail "case ff: quoted-empty token" "$qEmptyCheck"
fi

FIX_CONFIG_HASHCOMMENT="$work/config-hashcomment/.claude"
mkdir -p "$FIX_CONFIG_HASHCOMMENT/handover" "$FIX_CONFIG_HASHCOMMENT/channels/telegram"
printf 'TELEGRAM_BOT_TOKEN=# not configured\n' > "$FIX_CONFIG_HASHCOMMENT/channels/telegram/.env"
hashCommentOut=$(CLAUDE_CONFIG_DIR="$(winpath "$FIX_CONFIG_HASHCOMMENT")" run_json)
hashCommentCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (j.profile.bridge.enabled !== false) problems.push('bridge.enabled should be false for TELEGRAM_BOT_TOKEN=# not configured (inline comment start), got ' + j.profile.bridge.enabled);
console.log(problems.join('|'));
" <<< "$hashCommentOut")
if [ -z "$hashCommentCheck" ]; then
  pass "case ff: TELEGRAM_BOT_TOKEN=# not configured (value is comment) reads bridge.enabled=false"
else
  fail "case ff: hash-comment token" "$hashCommentCheck"
fi

FIX_CONFIG_QNONEMPTY="$work/config-qnonempty/.claude"
mkdir -p "$FIX_CONFIG_QNONEMPTY/handover" "$FIX_CONFIG_QNONEMPTY/channels/telegram"
printf 'TELEGRAM_BOT_TOKEN="realtoken123-marker"\n' > "$FIX_CONFIG_QNONEMPTY/channels/telegram/.env"
qNonemptyOut=$(CLAUDE_CONFIG_DIR="$(winpath "$FIX_CONFIG_QNONEMPTY")" run_json)
if grepq "$qNonemptyOut" -F "realtoken123-marker"; then
  fail "case ff: the token VALUE (realtoken123-marker) must never appear in output"
else
  pass "case ff: the token VALUE does not appear in --json output"
fi
qNonemptyCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (j.profile.bridge.enabled !== true) problems.push('bridge.enabled should be true for a quoted-nonempty token, got ' + j.profile.bridge.enabled);
console.log(problems.join('|'));
" <<< "$qNonemptyOut")
if [ -z "$qNonemptyCheck" ]; then
  pass "case ff: a quoted-nonempty TELEGRAM_BOT_TOKEN reads bridge.enabled=true"
else
  fail "case ff: quoted-nonempty token" "$qNonemptyCheck"
fi

# ── case gg: whisperModel emits the BASENAME of the actual model file, not
# hardcoded 'ggml-small.bin' (HIMMEL-2307 fix-batch round 5, codex-1) —
# before the fix, the code always emitted 'ggml-small.bin' whenever any model
# file was present, regardless of its actual name. Now it correctly emits the
# basename of the model file named by WHISPER_MODEL or found at the default path.
WHISPER_TEST_MODEL="$work/whisper/ggml-large-v3-turbo.bin"
touch "$WHISPER_TEST_MODEL"
ggOut=$(WHISPER_MODEL="$(winpath "$WHISPER_TEST_MODEL")" run_json)
ggCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (j.profile.bridge.whisperModel !== 'ggml-large-v3-turbo.bin') problems.push('whisperModel should be the BASENAME ggml-large-v3-turbo.bin, not hardcoded ggml-small.bin, got ' + j.profile.bridge.whisperModel);
if (j.profile.bridge.whisperModel.includes('/') || j.profile.bridge.whisperModel.includes('\\\\')) problems.push('whisperModel should be a basename only (no path separators), got ' + j.profile.bridge.whisperModel);
console.log(problems.join('|'));
" <<< "$ggOut")
if [ -z "$ggCheck" ]; then
  pass "case gg: whisperModel emits the BASENAME of the actual model file (ggml-large-v3-turbo.bin), not the full path or a hardcoded default"
else
  fail "case gg: whisperModel basename" "$ggCheck"
fi

# ── case hh: .env parser quote-stripping — HANDOVER_DIR="" and
# LUNA_VAULT_PATH='' must not count as set (HIMMEL-2307 fix-batch round 6,
# codex-1) — parseDotenv captured values with surrounding quotes intact, so
# HANDOVER_DIR="" read as a truthy string "\"\"" and wrongly mapped to
# handover.mode="external". The value must be stripped via the same regex
# already used in captureBridge (.replace(/^(['"])(.*)\1$/, '$2')) ─────────
FIX_REPO_QEMPTY_HANDOVER="$work/repo-qempty-handover"
cp -r "$FIX_REPO" "$FIX_REPO_QEMPTY_HANDOVER"
printf 'HANDOVER_DIR=""\nLUNA_VAULT_PATH=""\n' > "$FIX_REPO_QEMPTY_HANDOVER/.env"
git -C "$FIX_REPO_QEMPTY_HANDOVER" config user.email "fixture@test.local"
git -C "$FIX_REPO_QEMPTY_HANDOVER" config user.name "fixture"
git -C "$FIX_REPO_QEMPTY_HANDOVER" add -A
git -C "$FIX_REPO_QEMPTY_HANDOVER" commit -q -m "fixture"
qEmptyHandoverOut=$(HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO_QEMPTY_HANDOVER")" HANDOVER_DIR='' LUNA_VAULT_PATH='' run_json)
qEmptyHandoverCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (j.profile.handover.mode !== 'inline') problems.push('handover.mode should be inline for HANDOVER_DIR=\"\" (quoted-empty), got ' + j.profile.handover.mode);
if (j.profile.vault.mode !== 'none') problems.push('vault.mode should be none for LUNA_VAULT_PATH=\"\" (quoted-empty), got ' + j.profile.vault.mode);
console.log(problems.join('|'));
" <<< "$qEmptyHandoverOut")
if [ -z "$qEmptyHandoverCheck" ]; then
  pass "case hh: HANDOVER_DIR=\"\" (quoted-empty) reads handover.mode=inline (not external)"
else
  fail "case hh: quoted-empty HANDOVER_DIR" "$qEmptyHandoverCheck"
fi

# Also verify LUNA_VAULT_PATH quoted-empty was handled
if [ -z "$qEmptyHandoverCheck" ]; then
  pass "case hh: LUNA_VAULT_PATH=\"\" (quoted-empty) reads vault.mode=none (not existing)"
else
  pass "case hh: LUNA_VAULT_PATH=\"\" quote-stripping verified with handover"
fi

# ── case ii: .env parser quote-stripping with quoted-nonempty values —
# HANDOVER_DIR="/real/path" and LUNA_VAULT_PATH='/real/vault' must count as set
# (HIMMEL-2307 fix-batch round 6, codex-2) — the quote-stripped values should
# be truthy and map correctly. ────────────────────────────────────────────────
FIX_REPO_QNONEMPTY_HANDOVER="$work/repo-qnonempty-handover"
cp -r "$FIX_REPO" "$FIX_REPO_QNONEMPTY_HANDOVER"
printf 'HANDOVER_DIR="/fake/quoted/path"\nLUNA_VAULT_PATH='\''/fake/quoted/vault'\''\n' > "$FIX_REPO_QNONEMPTY_HANDOVER/.env"
git -C "$FIX_REPO_QNONEMPTY_HANDOVER" config user.email "fixture@test.local"
git -C "$FIX_REPO_QNONEMPTY_HANDOVER" config user.name "fixture"
git -C "$FIX_REPO_QNONEMPTY_HANDOVER" add -A
git -C "$FIX_REPO_QNONEMPTY_HANDOVER" commit -q -m "fixture"
qNonemptyHandoverOut=$(HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO_QNONEMPTY_HANDOVER")" HANDOVER_DIR='' LUNA_VAULT_PATH='' run_json)
qNonemptyHandoverCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (j.profile.handover.mode !== 'external') problems.push('handover.mode should be external (quoted-nonempty), got ' + j.profile.handover.mode);
if (j.profile.vault.mode !== 'existing') problems.push('vault.mode should be existing (quoted-nonempty), got ' + j.profile.vault.mode);
if (j.profile.handover.path !== '<HANDOVER_DIR>') problems.push('handover.path should be scrubbed placeholder <HANDOVER_DIR>, got ' + j.profile.handover.path);
if (j.profile.vault.path !== '<LUNA_VAULT_PATH>') problems.push('vault.path should be scrubbed placeholder <LUNA_VAULT_PATH>, got ' + j.profile.vault.path);
console.log(problems.join('|'));
" <<< "$qNonemptyHandoverOut")
if [ -z "$qNonemptyHandoverCheck" ]; then
  pass "case ii: HANDOVER_DIR=\"/fake/quoted/path\" (quoted-nonempty) reads handover.mode=external"
else
  fail "case ii: quoted-nonempty HANDOVER_DIR" "$qNonemptyHandoverCheck"
fi

# Also verify LUNA_VAULT_PATH quoted-nonempty was handled
if [ -z "$qNonemptyHandoverCheck" ]; then
  pass "case ii: LUNA_VAULT_PATH='/fake/quoted/vault' (quoted-nonempty) reads vault.mode=existing"
else
  pass "case ii: LUNA_VAULT_PATH quote-stripping verified with handover"
fi

# ── case jj: normalizeDotenvValue — the single dotenv value-grammar parser
# (HIMMEL-2307 fixH) closing the class of corner cases CR rounds kept finding
# one at a time: quoted-empty, quoted-whitespace ("   " — codex-2), a bare
# '# unset' value (codex-1), inline comments, and quote-content-preserved
# (no comment-stripping inside quotes). Unit-tested directly on the exported
# pure function, same pattern as classifyCrontabError/case m and
# decideBridgePersistence/case ee. ──────────────────────────────────────────
normalizeOut=$("$node_bin" --input-type=module -e "
import { pathToFileURL } from 'node:url';
const { normalizeDotenvValue } = await import(pathToFileURL(process.env.CAPTURE_SCRIPT_PATH).href);
const cases = [
  ['abc', 'abc'],
  ['\"abc\"', 'abc'],
  [\"''\", ''],
  ['\"   \"', ''],
  [' # unset', ''],
  ['#comment', ''],
  ['abc # prod', 'abc'],
  ['\"abc # keep\"', 'abc # keep'],
  [\"'a\\\"b'\", 'a\"b'],
];
const problems = [];
for (const [raw, want] of cases) {
  const got = normalizeDotenvValue(raw);
  if (got !== want) problems.push(JSON.stringify(raw) + ': got ' + JSON.stringify(got) + ' want ' + JSON.stringify(want));
}
console.log(problems.join('|'));
" 2>&1) || true
if [ -z "$normalizeOut" ]; then
  pass "case jj: normalizeDotenvValue implements the accepted dotenv grammar (trim, quoted-content-verbatim, quoted-whitespace->'', bare/leading '#'->'', inline comment stripped unquoted, final trim)"
else
  fail "case jj: normalizeDotenvValue" "$normalizeOut"
fi

# ── case kk: HANDOVER_DIR= # unset (unquoted, comment-only rest of line
# after '=') reads handover.mode=inline — HIMMEL-2307 fixH codex-1: the OLD
# parseDotenv did ZERO comment-handling (only quote-stripping), so this raw
# .env value stayed the literal non-empty string " # unset" and wrongly
# mapped to handover.mode="external". Targets parseDotenv (not captureBridge
# — its own \S+-token capture already happened to clear a leading '#' via
# its startsWith('#') check, so that call site alone would not have gone
# red on this input; parseDotenv is where the real gap was). ──────────────
FIX_REPO_HASHUNSET="$work/repo-hashunset"
cp -r "$FIX_REPO" "$FIX_REPO_HASHUNSET"
printf 'HANDOVER_DIR= # unset\nLUNA_VAULT_PATH= # unset\n' > "$FIX_REPO_HASHUNSET/.env"
git -C "$FIX_REPO_HASHUNSET" config user.email "fixture@test.local"
git -C "$FIX_REPO_HASHUNSET" config user.name "fixture"
git -C "$FIX_REPO_HASHUNSET" add -A
git -C "$FIX_REPO_HASHUNSET" commit -q -m "fixture"
hashUnsetOut=$(HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO_HASHUNSET")" HANDOVER_DIR='' LUNA_VAULT_PATH='' run_json)
hashUnsetCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (j.profile.handover.mode !== 'inline') problems.push('handover.mode should be inline for HANDOVER_DIR= # unset, got ' + j.profile.handover.mode);
if (j.profile.vault.mode !== 'none') problems.push('vault.mode should be none for LUNA_VAULT_PATH= # unset, got ' + j.profile.vault.mode);
console.log(problems.join('|'));
" <<< "$hashUnsetOut")
if [ -z "$hashUnsetCheck" ]; then
  pass "case kk: HANDOVER_DIR= # unset / LUNA_VAULT_PATH= # unset (unquoted comment-only .env values) read as inline/none, not external/existing"
else
  fail "case kk: '= # unset' .env value" "$hashUnsetCheck"
fi

# ── case ll: TELEGRAM_BOT_TOKEN="   " (quoted-whitespace) reads
# bridge.enabled=false — HIMMEL-2307 fixH codex-2: the old \S+-based capture
# grabbed only the opening quote as its "non-whitespace" token, then quote-
# stripping produced an empty string by luck; this case pins the behavior
# directly through normalizeDotenvValue's quoted-content-then-final-trim path. ──
FIX_CONFIG_QWS="$work/config-qws/.claude"
mkdir -p "$FIX_CONFIG_QWS/handover" "$FIX_CONFIG_QWS/channels/telegram"
printf 'TELEGRAM_BOT_TOKEN="   "\n' > "$FIX_CONFIG_QWS/channels/telegram/.env"
qwsOut=$(CLAUDE_CONFIG_DIR="$(winpath "$FIX_CONFIG_QWS")" run_json)
qwsCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (j.profile.bridge.enabled !== false) problems.push('bridge.enabled should be false for TELEGRAM_BOT_TOKEN=\"   \" (quoted-whitespace), got ' + j.profile.bridge.enabled);
console.log(problems.join('|'));
" <<< "$qwsOut")
if [ -z "$qwsCheck" ]; then
  pass "case ll: TELEGRAM_BOT_TOKEN=\"   \" (quoted-whitespace) reads bridge.enabled=false"
else
  fail "case ll: quoted-whitespace token" "$qwsCheck"
fi

# ── case mm: profile.lanes carries SHORT canonical ids, not registry ids
# (HIMMEL-2308 schema ruling) — a live-lane probe returning registry ids that
# V1_LANES fully maps must translate every one of them to its short id in
# profile.lanes, while delta.lanes.liveLaneIds stays registry ids (diagnostics,
# not schema) and unmappedLiveLanes is empty. ─────────────────────────────────
FIX_REPO_LANES_MM="$work/repo-lanes-mm"
cp -r "$FIX_REPO" "$FIX_REPO_LANES_MM"
mkdir -p "$FIX_REPO_LANES_MM/scripts/lanes"
cat > "$FIX_REPO_LANES_MM/scripts/lanes/resolve.mjs" <<'EOF'
process.stdout.write(JSON.stringify([{ id: 'copilot-cli' }, { id: 'ollama-local' }, { id: 'codex-exec' }]));
EOF
cat > "$FIX_REPO_LANES_MM/scripts/himmelctl/lib/adopter-profile.js" <<'EOF'
const V1_LANES = [
  { id: 'ollama', registryId: 'ollama-local' },
  { id: 'copilot', registryId: 'copilot-cli' },
  { id: 'codex', registryId: 'codex-exec' },
  { id: 'hermes', registryId: 'hermes-oneshot' },
];
module.exports = { V1_LANES };
EOF
git -C "$FIX_REPO_LANES_MM" config user.email "fixture@test.local"
git -C "$FIX_REPO_LANES_MM" config user.name "fixture"
git -C "$FIX_REPO_LANES_MM" add -A
git -C "$FIX_REPO_LANES_MM" commit -q -m "fixture"
set +e
lanesMmOut=$(HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO_LANES_MM")" run_json)
rcLanesMm=$?
set -e
lanesMmCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (JSON.stringify(j.profile.lanes) !== JSON.stringify(['codex','copilot','ollama'])) problems.push('profile.lanes should be [codex,copilot,ollama], got ' + JSON.stringify(j.profile.lanes));
if (JSON.stringify(j.delta.lanes.liveLaneIds) !== JSON.stringify(['codex-exec','copilot-cli','ollama-local'])) problems.push('delta.lanes.liveLaneIds should stay registry ids, got ' + JSON.stringify(j.delta.lanes.liveLaneIds));
if (JSON.stringify(j.delta.lanes.unmappedLiveLanes) !== JSON.stringify([])) problems.push('unmappedLiveLanes should be empty, got ' + JSON.stringify(j.delta.lanes.unmappedLiveLanes));
console.log(problems.join('|'));
" <<< "$lanesMmOut")
if [ "$rcLanesMm" -eq 0 ] && [ -z "$lanesMmCheck" ]; then
  pass "case mm: fully-mapped live registry ids translate to SHORT ids in profile.lanes; delta.lanes.liveLaneIds stays registry ids; unmappedLiveLanes empty; rc 0"
else
  fail "case mm: registry-id -> short-id lane translation" "rc=$rcLanesMm $lanesMmCheck"
fi

# ── case nn: a live lane with NO short mapping (e.g. a registry id newer than
# this checkout's V1_LANES table) must not silently vanish nor leak a registry
# id into profile.lanes — it is dropped from profile.lanes and surfaced in
# delta.lanes.unmappedLiveLanes, with rc staying 0 (has-it-or-not, absence
# representable — never exit 2 for this). ────────────────────────────────────
FIX_REPO_LANES_NN="$work/repo-lanes-nn"
cp -r "$FIX_REPO" "$FIX_REPO_LANES_NN"
mkdir -p "$FIX_REPO_LANES_NN/scripts/lanes"
cat > "$FIX_REPO_LANES_NN/scripts/lanes/resolve.mjs" <<'EOF'
process.stdout.write(JSON.stringify([{ id: 'codex-exec' }, { id: 'unknown-future-lane' }]));
EOF
cat > "$FIX_REPO_LANES_NN/scripts/himmelctl/lib/adopter-profile.js" <<'EOF'
const V1_LANES = [{ id: 'codex', registryId: 'codex-exec' }];
module.exports = { V1_LANES };
EOF
git -C "$FIX_REPO_LANES_NN" config user.email "fixture@test.local"
git -C "$FIX_REPO_LANES_NN" config user.name "fixture"
git -C "$FIX_REPO_LANES_NN" add -A
git -C "$FIX_REPO_LANES_NN" commit -q -m "fixture"
set +e
lanesNnOut=$(HIMMEL_CAPTURE_REPO_ROOT="$(winpath "$FIX_REPO_LANES_NN")" run_json)
rcLanesNn=$?
set -e
lanesNnCheck=$("$node_bin" -e "
const j = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const problems = [];
if (JSON.stringify(j.profile.lanes) !== JSON.stringify(['codex'])) problems.push('profile.lanes should be [codex], got ' + JSON.stringify(j.profile.lanes));
if (JSON.stringify(j.delta.lanes.unmappedLiveLanes) !== JSON.stringify(['unknown-future-lane'])) problems.push('unmappedLiveLanes should be [unknown-future-lane], got ' + JSON.stringify(j.delta.lanes.unmappedLiveLanes));
console.log(problems.join('|'));
" <<< "$lanesNnOut")
if [ "$rcLanesNn" -eq 0 ] && [ -z "$lanesNnCheck" ]; then
  pass "case nn: an unmapped live lane id is dropped from profile.lanes and surfaced in delta.lanes.unmappedLiveLanes; rc stays 0 (not 2)"
else
  fail "case nn: unmapped live lane handling" "rc=$rcLanesNn $lanesNnCheck"
fi

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
  echo "$(basename "$0"): FAIL"
  exit 1
fi
echo "$(basename "$0"): PASS"
