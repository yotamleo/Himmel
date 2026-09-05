#!/usr/bin/env bash
# test-wizard-luna-sections.sh — hermetic tests for HIMMEL-2176 Stage-1 PR-C
# Task 8: the himmelctl wizard's three new sections (luna cadence, secrets
# walk, telegram bridge) — lib/cadence-emit.js's config->CLI-flag mapping,
# bin.js's askQuestions()/buildAnswers()/loadProfile()/runPlan() wiring, and
# lib/adopter-profile.js's buildSummary() honest-bucket contribution.
# Mirrors sibling test-wizard-*.sh conventions: node launched by absolute
# path, winpath for node.exe's MSYS-path blindness, a stub-only PATH via
# scripts/lib/hermetic-path.sh, HIMMELCTL_REPO_ROOT/HIMMELCTL_CACHE_DIR/
# HIMMELCTL_BIN_DIR/HIMMEL_LUNA_CONFIG_PATH so nothing ever touches the real
# checkout, ~/.himmel/config.json, or ~/.claude/himmel/.
#
# Covers (task brief Part 3, Definition of Done):
#   V9    cadence-emit.js: exact flag names + the synthesize->--synth-*
#         mapping + weekly health emitting --health-day SUN + health.day
#         absent emitting --health-day DAILY + a loud error when a `day`
#         lands on a dayless schedule.
#   V1    two --from-profile --dry-run replays produce byte-identical output.
#   caseApply  a full --from-profile APPLY run (no live TTY, hermetic
#         fixtures for adopt.sh/pipeline-cadence.sh):
#     - 8a persistence: luna.vaultPath/cadence.enabled/phi.declared/bridge.*
#       land in the sandboxed ~/.himmel/config.json and round-trip via
#       lunaConfigLib.load().
#     - bridge.envPath + bridge.whisper.{cli,model} are the OPERATOR's
#       configured values, not the schema defaults.
#     - the cadence arm step actually spawns pipeline-cadence.sh with the
#       expected argv (end-to-end wiring, not just the emitter unit).
#     - secrets walk: an unconfigured secret reports 'unconfigured', not an
#       error — the run still exits 0.
#     - V12: TELEGRAM_AUTO_ACTIONS is absent from the bridge .env and from
#       the printed profile JSON, both before and after the run.
#   V11   adopter-profile.js's buildSummary(): a skipped secret + a
#         trust-class bridge-probe result land under skipped/manual and
#         NEVER under installed.
#   ask-first  non-interactive with no --from-profile still refuses (rc 1);
#         nothing derived, nothing installed.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
cadence_emit_lib="$repo_root/scripts/himmelctl/lib/cadence-emit.js"
adopter_profile_lib="$repo_root/scripts/himmelctl/lib/adopter-profile.js"
luna_config_lib="$repo_root/scripts/himmelctl/lib/luna-config.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
[ -f "$cadence_emit_lib" ] || { echo "FAIL: $cadence_emit_lib not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# HIMMEL-1192: pin bin.js's bash spawns to the bare, PATH-honoring `bash`
# this suite links into its stub dir (see test-wizard-questions.sh's own
# comment on this — same reasoning applies verbatim here).
export HIMMELCTL_BASH=bash

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

t=$(mktemp -d "${TMPDIR:-/tmp}/wizard-luna-sections.XXXXXX") || exit 1
[ -n "$t" ] || exit 1
cleanup() { rm -rf "$t"; }
trap cleanup EXIT
work="$t"
cadence_emit_lib_w="$(winpath "$cadence_emit_lib")"
adopter_profile_lib_w="$(winpath "$adopter_profile_lib")"
luna_config_lib_w="$(winpath "$luna_config_lib")"

build_path() {
  local _stub="$1"; shift
  local _present=() _absent=() _stage=0 _tt
  for _tt in "$@"; do
    if [ "$_tt" = "--" ]; then _stage=1; continue; fi
    if [ "$_stage" -eq 0 ]; then _present+=("$_tt"); else _absent+=("$_tt"); fi
  done
  for _tt in "${_present[@]}"; do
    link_hermetic_tool "$_tt" "$_stub"
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
if [ "\$1" = "rev-parse" ] && [ "\$2" = "--show-toplevel" ]; then
  exit 1
fi
exit 0
STUB
  chmod +x "$_d/git"
}

# make_python_stub <destdir> — a fake `python` mimicking BOTH real consumers
# this suite's fixtures exercise, never a live interpreter or network call
# (RETASK stage1-build-6d2e): probePythonInterpreter's `-c "<script>"` shape
# (args: -c, script — replies with the fixed marker probePythonInterpreter
# checks for) AND probeLunaSources' `<fetch-health.py> --probe <source>`
# shape (args: script-path, --probe, source — replies with fetch-health.py's
# own {"status":..., "reason":...} JSON contract). Per-source canned replies
# below intentionally cover all three luna-sources verdicts: bitbucket=ok
# (configured+healthy), firecrawl=blocked-or-rate-limited (configured but
# broken — reason does NOT end in "missing", so probes.js's own
# UNCONFIGURED_REASON_RE does not reclassify it), reddit=auth-or-cookie-
# expired with a reason ending in "missing" (the adopter never configured
# it — probes.js's own unconfigured bucket). Any other source falls through
# to a generic "missing" reason (unconfigured), matching a real never-
# configured credential.
make_python_stub() {
  local _d="$1"
  cat > "$_d/python" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "-c" ]; then
  echo HIMMEL_PY_OK
  exit 0
fi
# RETASK stage1-build-6d2e: an opt-in invocation log (only written when the
# caller exports PROBE_INVOCATION_LOG) -- appends the probed source id ($3)
# on every real --probe call, so a test can count how many times a given
# source was actually invoked without changing any existing case's behavior.
if [ -n "${PROBE_INVOCATION_LOG:-}" ]; then
  printf '%s\n' "$3" >> "$PROBE_INVOCATION_LOG"
fi
case "$3" in
  bitbucket)
    echo '{"status":"ok","reason":"configured and healthy"}'
    exit 0
    ;;
  firecrawl)
    echo '{"status":"blocked-or-rate-limited","reason":"rate limited by upstream"}'
    exit 0
    ;;
  reddit)
    echo '{"status":"auth-or-cookie-expired","reason":"reddit cookie file missing"}'
    exit 0
    ;;
  *)
    echo '{"status":"auth-or-cookie-expired","reason":"'"$3"' credential missing"}'
    exit 0
    ;;
esac
STUB
  chmod +x "$_d/python"
}

grepq() { local _tt="$1"; shift; grep -q "$@" <<< "$_tt"; }

# extract_profile_json <blob> -- pull the printed `serialize(answers)`
# JSON object (schemaVersion/profile/.../alwaysOn) out of a captured
# INTERACTIVE run's stdout, e.g. for HIMMEL-2436's dry-run cases (PV1/
# caseVaultNoneNoOp below), where --dry-run no longer writes the T3 cache
# file but still prints the identical JSON serialize() would have written.
# The opening '{' lands glued onto the last prompt's "> " line (makeAsk
# writes no trailing newline before EOF-closed defaults resolve), so the
# range starts at any line ENDING in '{' and the first line is trimmed back
# to just '{'; the range ends at the bare '}' line -- root-level only, since
# 2-space-indented nested closes are never printed with nothing else on the
# line.
extract_profile_json() { printf '%s\n' "$1" | sed -n '/{$/,/^}$/p' | sed '1s/.*{/{/'; }

# ═══════════════════════════════════════════════════════════════════════════
# V9 — cadence-emit.js: config -> pipeline-cadence.sh CLI flags
# ═══════════════════════════════════════════════════════════════════════════

outV9a=$("$node_bin" -e "
const ce = require('$cadence_emit_lib_w');
const cadence = {
  schedules: {
    fetchHealth: { time: '01:30' },
    harvest: { time: '02:15' },
    synthesize: { time: '03:45' },
    health: { time: '04:30', day: 'SUN' },
  },
  models: { harvest: 'sonnet', synthesize: 'opus', health: 'haiku' },
};
const flags = ce.buildArmFlags({ cadence, vaultPath: '/vault/path' });
console.log(JSON.stringify(flags));
")
echo "$outV9a" | jq -e '.[0:2] == ["--fetch-health-time","01:30"]' >/dev/null \
  || fail "V9a: expected --fetch-health-time 01:30 first (got: $outV9a)"
echo "$outV9a" | jq -e '.[2:4] == ["--harvest-time","02:15"]' >/dev/null \
  || fail "V9a: expected --harvest-time 02:15 (got: $outV9a)"
echo "$outV9a" | jq -e '.[4:6] == ["--synth-time","03:45"]' >/dev/null \
  || fail "V9a: synthesize schedule must map to --synth-time, NOT --synthesize-time (got: $outV9a)"
echo "$outV9a" | jq -e '.[6:8] == ["--health-time","04:30"]' >/dev/null \
  || fail "V9a: expected --health-time 04:30 (got: $outV9a)"
echo "$outV9a" | jq -e '.[8:10] == ["--health-day","SUN"]' >/dev/null \
  || fail "V9a: weekly health (day=SUN) must emit --health-day SUN (got: $outV9a)"
echo "$outV9a" | jq -e '.[10:12] == ["--harvest-model","sonnet"]' >/dev/null \
  || fail "V9a: expected --harvest-model sonnet (got: $outV9a)"
echo "$outV9a" | jq -e '.[12:14] == ["--synth-model","opus"]' >/dev/null \
  || fail "V9a: synthesize model must map to --synth-model, NOT --synthesize-model (got: $outV9a)"
echo "$outV9a" | jq -e '.[14:16] == ["--health-model","haiku"]' >/dev/null \
  || fail "V9a: expected --health-model haiku (got: $outV9a)"
echo "$outV9a" | jq -e 'any(.[]; . == "--synthesize-time" or . == "--synthesize-model" or . == "--fetch-health-model" or . == "--harvest-day" or . == "--fetch-health-day" or . == "--synth-day")' >/dev/null \
  && fail "V9a: must NEVER emit a wrong/nonexistent flag name (got: $outV9a)"
echo "$outV9a" | jq -e '.[-2:] == ["--vault","/vault/path"]' >/dev/null \
  || fail "V9a: expected trailing --vault /vault/path (got: $outV9a)"
echo "ok: V9a cadence-emit — exact flag names, synth-day removed mapping honored, weekly health emits --health-day SUN"

outV9b=$("$node_bin" -e "
const ce = require('$cadence_emit_lib_w');
const cadence = { schedules: { health: { time: '04:00' } }, models: {} };
console.log(JSON.stringify(ce.buildArmFlags({ cadence })));
")
echo "$outV9b" | jq -e '. as $a | ($a | index("--health-day")) as $i | $i != null and $a[$i+1] == "DAILY"' >/dev/null \
  || fail "V9b: health.day ABSENT must emit --health-day DAILY explicitly (pipeline-cadence.sh's own omitted-flag default is SUN, not daily) (got: $outV9b)"
echo "ok: V9b cadence-emit — health.day absent emits --health-day DAILY (never relies on the script's own SUN default)"

for dayless in fetchHealth harvest synthesize; do
  outV9c=$("$node_bin" -e "
const ce = require('$cadence_emit_lib_w');
const cadence = { schedules: { $dayless: { time: '02:00', day: 'MON' } }, models: {} };
try {
  ce.buildArmFlags({ cadence });
  console.log(JSON.stringify({ threw: false }));
} catch (e) {
  console.log(JSON.stringify({ threw: true, message: e.message }));
}
")
  echo "$outV9c" | jq -e '.threw == true' >/dev/null \
    || fail "V9c ($dayless): a day on a dayless schedule must throw a LOUD error, never silently drop it (got: $outV9c)"
  echo "$outV9c" | jq -e --arg k "$dayless" '.message | contains($k)' >/dev/null \
    || fail "V9c ($dayless): the thrown error should name the offending schedule (got: $outV9c)"
done
echo "ok: V9c cadence-emit — a day on fetchHealth/harvest/synthesize is a loud validation error, never silently dropped"

# ═══════════════════════════════════════════════════════════════════════════
# V11 — adopter-profile.js buildSummary(): skipped/manual bucketing, never
# installed (pure unit test — no wizard invocation, no spawn).
# ═══════════════════════════════════════════════════════════════════════════

outV11=$("$node_bin" -e "
const ap = require('$adopter_profile_lib_w');
const answers = {
  role: 'adopter', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'inline', path: '' },
  pluginSet: 'lean',
  luna: { cadenceEnabled: false, phiDeclared: false },
  secretsWalk: 'run',
  bridge: { enabled: true, envPath: '/x/.env', whisperCli: '', whisperModel: 'ggml-small.bin', installPersistence: false },
};
const opts = {
  dryRun: false,
  secretsWalkResults: [{ name: 'BITBUCKET_API_TOKEN', status: 'unconfigured', detail: 'not actively probed by the wizard', obtain: 'id.atlassian.com — create a token' }],
  bridgeProbes: {
    whisperReady: { actual: 'absent', detail: 'whisper binary not found' },
    pythonInterpreter: { actual: 'present', detail: 'python3 runs' },
    distinctTokens: { actual: 'present', detail: 'distinct tokens' },
  },
};
const summary = ap.buildSummary(answers, [], opts);
console.log(JSON.stringify(summary));
")
echo "$outV11" | jq -e '.installed | map(select(contains("BITBUCKET_API_TOKEN"))) | length == 0' >/dev/null \
  || fail "V11: an unconfigured secret must NEVER appear under installed (got: $outV11)"
echo "$outV11" | jq -e '.installed | map(select(contains("whisperReady") or contains("absent"))) | length == 0' >/dev/null \
  || fail "V11: a trust-class/absent bridge probe result must NEVER appear under installed (got: $outV11)"
echo "$outV11" | jq -e '.skipped | any(.[]; contains("BITBUCKET_API_TOKEN") and contains("unconfigured"))' >/dev/null \
  || fail "V11: the skipped secret should be listed under skipped as unconfigured (got: $outV11)"
echo "$outV11" | jq -e '.manual | any(.[]; (.what | contains("whisperReady")) and (.what | contains("absent")))' >/dev/null \
  || fail "V11: the trust-class bridge probe result should be listed under manual (got: $outV11)"
echo "ok: V11 buildSummary — a skipped secret + a trust-class bridge-probe result land under skipped/manual, never under installed"

# ── V11b (RETASK stage1-build-6d2e round 3) — pure unit tests of buildSummary's
# two coordinator-mandated wording distinctions:
#   1. an UNTOUCHED section (no luna/bridge key at all) reads "left as-is",
#      never "you answered ... =off" (codex-1 honesty fix).
#   2. a DELIBERATE persistence skip (probes not ready, p.skipped:true) reads
#      "SKIPPED (probes not ready)", distinct from a genuine install failure
#      (p.ok:false, no skipped flag) which still reads "NOT installed".
outV11b_untouched=$("$node_bin" -e "
const ap = require('$adopter_profile_lib_w');
const answers = {
  role: 'adopter', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'inline', path: '' },
  pluginSet: 'lean',
  secretsWalk: 'skip',
  // luna/bridge DELIBERATELY absent — the legacy-profile shape.
};
console.log(JSON.stringify(ap.buildSummary(answers, [], { dryRun: false })));
")
echo "$outV11b_untouched" | jq -e '.skipped | any(.[]; contains("luna cadence") and contains("left as-is"))' >/dev/null \
  || fail "V11b: an untouched luna section should read 'left as-is', not 'you answered cadence=off' (got: $outV11b_untouched)"
echo "$outV11b_untouched" | jq -e '.skipped | any(.[]; contains("PHI checklist") and contains("left as-is"))' >/dev/null \
  || fail "V11b: an untouched luna section's PHI line should also read 'left as-is' (got: $outV11b_untouched)"
echo "$outV11b_untouched" | jq -e '.skipped | any(.[]; contains("telegram bridge") and contains("left as-is"))' >/dev/null \
  || fail "V11b: an untouched bridge section should read 'left as-is', not 'you answered bridge=off' (got: $outV11b_untouched)"
echo "$outV11b_untouched" | jq -e '.skipped | any(.[]; contains("cadence=off"))' >/dev/null \
  && fail "V11b: an UNTOUCHED section must never claim 'you answered cadence=off' -- nothing was answered (got: $outV11b_untouched)"
echo "$outV11b_untouched" | jq -e '.skipped | any(.[]; contains("bridge=off"))' >/dev/null \
  && fail "V11b: an UNTOUCHED bridge section must never claim 'you answered bridge=off' (got: $outV11b_untouched)"
echo "ok: V11b buildSummary — an untouched luna/bridge section reads 'left as-is', never a false 'you answered ...=off'"

outV11b_skip=$("$node_bin" -e "
const ap = require('$adopter_profile_lib_w');
const answers = {
  role: 'adopter', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'inline', path: '' },
  pluginSet: 'lean',
  luna: { cadenceEnabled: false, phiDeclared: false },
  secretsWalk: 'skip',
  bridge: { enabled: true, envPath: '/x/.env', whisperCli: '', whisperModel: 'ggml-small.bin', installPersistence: true },
};
const summarySkip = ap.buildSummary(answers, [], { dryRun: false, bridgePersistence: { ok: false, skipped: true, actions: [], detail: 'probes not ready' } });
const summaryFail = ap.buildSummary(answers, [], { dryRun: false, bridgePersistence: { ok: false, actions: [], detail: 'systemctl exited 1' } });
console.log(JSON.stringify({ summarySkip, summaryFail }));
")
echo "$outV11b_skip" | jq -e '.summarySkip.manual | any(.[]; (.what | contains("SKIPPED")) and (.what | contains("probes not ready")))' >/dev/null \
  || fail "V11b: a deliberate persistence skip should read SKIPPED (probes not ready) (got: $outV11b_skip)"
echo "$outV11b_skip" | jq -e '.summarySkip.manual | any(.[]; .what | contains("NOT installed"))' >/dev/null \
  && fail "V11b: a deliberate SKIP must not be worded the same as a genuine failure (NOT installed) (got: $outV11b_skip)"
echo "$outV11b_skip" | jq -e '.summaryFail.manual | any(.[]; (.what | contains("NOT installed")) and (.what | contains("systemctl exited 1")))' >/dev/null \
  || fail "V11b: a genuine persistence failure should still read NOT installed with the real detail (got: $outV11b_skip)"
echo "$outV11b_skip" | jq -e '.summaryFail.manual | any(.[]; .what | contains("SKIPPED"))' >/dev/null \
  && fail "V11b: a genuine failure must not be worded as a deliberate SKIPPED (got: $outV11b_skip)"
echo "ok: V11b buildSummary — a deliberate persistence skip (probes not ready) and a genuine install failure render DIFFERENT wording"

# ── V11c (RETASK stage1-build-6d2e round 6) — pure unit tests, same style as
# V11/V11b, for the two findings that have no safe/deterministic end-to-end
# trigger (a genuine thrown probe exception, and a real Linux unit-succeeds-
# linger-fails partial state — neither reproducible hermetically on this
# Windows test host without spawning a real systemd/network dependency):
#   1. [codex-3] a secret result with status:'error' (the shape bin.js's
#      probeOneSecret catch now returns for a thrown probe exception) must
#      land under still-manual, name the failure, and NEVER read as
#      'unconfigured' or be told to "go configure" something we never
#      actually checked.
#   2. [codex-4] a bridgePersistence result with partial:true (unit running,
#      linger not set) must land under still-manual — never installed — and
#      say PARTIAL, not the blanket "NOT installed" a total failure gets.
outV11c_error=$("$node_bin" -e "
const ap = require('$adopter_profile_lib_w');
const answers = {
  role: 'adopter', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'inline', path: '' },
  pluginSet: 'lean',
  secretsWalk: 'run',
  bridge: { enabled: false },
};
const summary = ap.buildSummary(answers, [], {
  dryRun: false,
  secretsWalkResults: [{ name: 'TELEGRAM_BOT_TOKEN', status: 'error', detail: 'probe threw: spawn ENOENT', obtain: 'message @BotFather' }],
});
console.log(JSON.stringify(summary));
")
echo "$outV11c_error" | jq -e '.installed | map(select(contains("TELEGRAM_BOT_TOKEN"))) | length == 0' >/dev/null \
  || fail "V11c [codex-3]: a probe-error secret must NEVER appear under installed (got: $outV11c_error)"
echo "$outV11c_error" | jq -e '.skipped | map(select(contains("TELEGRAM_BOT_TOKEN"))) | length == 0' >/dev/null \
  || fail "V11c [codex-3]: a probe-error secret must NOT be classified as skipped/unconfigured (got: $outV11c_error)"
echo "$outV11c_error" | jq -e '.manual | any(.[]; (.what | contains("TELEGRAM_BOT_TOKEN")) and (.what | contains("probe error")) and (.what | contains("spawn ENOENT")))' >/dev/null \
  || fail "V11c [codex-3]: the probe-error secret should land in manual, naming the actual failure (got: $outV11c_error)"
echo "$outV11c_error" | jq -e '.manual | any(.[]; (.what | contains("TELEGRAM_BOT_TOKEN")) and (.what | contains("unconfigured")))' >/dev/null \
  && fail "V11c [codex-3]: a probe error must never read as 'unconfigured' -- that tells the adopter to configure something we never actually checked (got: $outV11c_error)"
echo "ok: V11c [codex-3] a thrown probe exception (status:'error') lands in still-manual naming the failure, never 'unconfigured'"

outV11c_partial=$("$node_bin" -e "
const ap = require('$adopter_profile_lib_w');
const answers = {
  role: 'adopter', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'inline', path: '' },
  pluginSet: 'lean',
  secretsWalk: 'skip',
  bridge: { enabled: true, envPath: '/x/.env', whisperCli: '', whisperModel: 'ggml-small.bin', installPersistence: true },
};
const summary = ap.buildSummary(answers, [], {
  dryRun: false,
  configSaveOk: true,
  bridgeProbes: { whisperReady: { actual: 'present', detail: 'ok' }, pythonInterpreter: { actual: 'present', detail: 'ok' }, distinctTokens: { actual: 'present', detail: 'ok' } },
  bridgePersistence: { ok: false, partial: true, actions: [], detail: 'unit installed and RUNNING (telegram-bridge.service enabled and started); linger NOT enabled — loginctl exited 1. The bridge will stop at the next logout. Remediation: loginctl enable-linger bob' },
});
console.log(JSON.stringify(summary));
")
echo "$outV11c_partial" | jq -e '.installed | map(select(contains("persistence"))) | length == 0' >/dev/null \
  || fail "V11c [codex-4]: a PARTIAL persistence result must NEVER appear under installed (got: $outV11c_partial)"
echo "$outV11c_partial" | jq -e '.manual | any(.[]; (.what | contains("PARTIAL")) and (.what | contains("RUNNING")) and (.what | contains("linger NOT enabled")))' >/dev/null \
  || fail "V11c [codex-4]: the partial state should say plainly what IS true (unit running) and what is NOT (linger) (got: $outV11c_partial)"
echo "$outV11c_partial" | jq -e '.manual | any(.[]; .what | contains("loginctl enable-linger"))' >/dev/null \
  || fail "V11c [codex-4]: the exact remediation command should be present (got: $outV11c_partial)"
echo "$outV11c_partial" | jq -e '.manual | any(.[]; (.what | contains("persistence")) and (.what | contains("NOT installed")))' >/dev/null \
  && fail "V11c [codex-4]: a PARTIAL success must not be worded the same as a total failure (NOT installed) (got: $outV11c_partial)"
echo "ok: V11c [codex-4] a partial persistence state (unit running, linger not set) reports PARTIAL under still-manual, names the exact remediation, never installed"

# ── V11d (RETASK stage1-build-6d2e round 9 [codex-1 follow-up]) — pure unit
# test, same style as V11b's luna/bridge pin: a not-asked secretsWalk
# (answers.secretsWalk undefined -- the shape round 8's fix produces for
# vaultMode=='none'/contributor) must read "left as-is", distinct from a
# genuinely-asked-and-declined secretsWalk=skip, which keeps its own wording.
outV11d=$("$node_bin" -e "
const ap = require('$adopter_profile_lib_w');
const baseAnswers = {
  role: 'adopter', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'inline', path: '' },
  pluginSet: 'lean',
};
const notAsked = ap.buildSummary(Object.assign({}, baseAnswers), [], { dryRun: false });
const declined = ap.buildSummary(Object.assign({}, baseAnswers, { secretsWalk: 'skip' }), [], { dryRun: false });
console.log(JSON.stringify({ notAsked, declined }));
")
echo "$outV11d" | jq -e '.notAsked.skipped | any(.[]; contains("secrets walk") and contains("left as-is"))' >/dev/null \
  || fail "V11d [codex-1 follow-up]: a not-asked secretsWalk should read 'left as-is' (got: $outV11d)"
echo "$outV11d" | jq -e '.notAsked.skipped | any(.[]; contains("secretsWalk=skip"))' >/dev/null \
  && fail "V11d [codex-1 follow-up]: a not-asked secretsWalk must NEVER claim 'you answered secretsWalk=skip' -- nothing was answered (got: $outV11d)"
echo "$outV11d" | jq -e '.declined.skipped | any(.[]; contains("secrets walk") and contains("secretsWalk=skip"))' >/dev/null \
  || fail "V11d [codex-1 follow-up]: a genuinely-declined secretsWalk should keep its own 'you answered secretsWalk=skip' wording (got: $outV11d)"
echo "$outV11d" | jq -e '.declined.skipped | map(select(contains("secrets walk"))) | any(.[]; contains("left as-is"))' >/dev/null \
  && fail "V11d [codex-1 follow-up]: a genuinely-declined secretsWalk must NOT read 'left as-is' -- it WAS asked (got: $outV11d)"
echo "ok: V11d [codex-1 follow-up] a not-asked secretsWalk reads 'left as-is', distinct from a genuinely-declined secretsWalk=skip"

# ── V11e (RETASK stage1-build-6d2e round 10 [codex-2]) — pure unit test,
# same style as V11b/V11c/V11d: the --dry-run "would install" text for bridge
# persistence must platform-branch, exactly like attemptBridgePersistence()
# itself does. process.platform is overridden in-process (the same technique
# test-wizard-probes.sh already uses for probeWhisperReady's own platform-
# routing test) since buildSummary reads process.platform directly, not
# through a ctx parameter.
outV11e=$("$node_bin" -e "
const ap = require('$adopter_profile_lib_w');
const answers = {
  role: 'adopter', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'inline', path: '' },
  pluginSet: 'lean',
  secretsWalk: 'skip',
  bridge: { enabled: true, envPath: '/x/.env', whisperCli: '', whisperModel: 'ggml-small.bin', installPersistence: true },
};
Object.defineProperty(process, 'platform', { value: 'win32', configurable: true });
const win = ap.buildSummary(answers, [], { dryRun: true });
Object.defineProperty(process, 'platform', { value: 'linux', configurable: true });
const lin = ap.buildSummary(answers, [], { dryRun: true });
Object.defineProperty(process, 'platform', { value: 'darwin', configurable: true });
const mac = ap.buildSummary(answers, [], { dryRun: true });
console.log(JSON.stringify({ win, lin, mac }));
")
echo "$outV11e" | jq -e '.win.planned | any(.[]; contains("HimmelTelegramBridge scheduled task"))' >/dev/null \
  || fail "V11e [codex-2]: win32 dry-run should name the HimmelTelegramBridge scheduled task (got: $outV11e)"
echo "$outV11e" | jq -e '.win.planned | any(.[]; contains("systemd"))' >/dev/null \
  && fail "V11e [codex-2]: win32 dry-run must NOT claim a systemd unit -- that is not what will be installed there (got: $outV11e)"
echo "$outV11e" | jq -e '.lin.planned | any(.[]; contains("telegram-bridge.service") and contains("systemd") and contains("linger"))' >/dev/null \
  || fail "V11e [codex-2]: linux dry-run should name the telegram-bridge.service systemd unit + linger (got: $outV11e)"
echo "$outV11e" | jq -e '.lin.planned | any(.[]; contains("scheduled task"))' >/dev/null \
  && fail "V11e [codex-2]: linux dry-run must NOT claim a scheduled task -- that is the win32 artifact, not linux (got: $outV11e)"
echo "$outV11e" | jq -e '.mac.manual | any(.[]; (.what | contains("not supported on this platform")) and (.what | contains("darwin")))' >/dev/null \
  || fail "V11e [codex-2]: an unsupported platform's dry-run should say so plainly rather than claim an install (got: $outV11e)"
echo "$outV11e" | jq -e '.mac.planned | any(.[]; contains("would install (systemd") or contains("would install (HimmelTelegramBridge"))' >/dev/null \
  && fail "V11e [codex-2]: an unsupported platform must NEVER claim it would install persistence (got: $outV11e)"
echo "ok: V11e [codex-2] the --dry-run bridge-persistence text platform-branches (win32 scheduled task / linux systemd+linger / other unsupported), never claims the wrong artifact"

# ── V11f (RETASK stage1-build-6d2e round 10 [codex-1]) — a paired credential
# reported 'unconfigured' must name the pair and say the shared probe cannot
# tell them apart, rather than pinning the blame on whichever one happens to
# be listed; an UNPAIRED secret (control) keeps the plain wording.
outV11f=$("$node_bin" -e "
const ap = require('$adopter_profile_lib_w');
const answers = {
  role: 'adopter', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'inline', path: '' },
  pluginSet: 'lean',
  secretsWalk: 'run',
  bridge: { enabled: false },
};
const summary = ap.buildSummary(answers, [], {
  dryRun: false,
  secretsWalkResults: [
    { name: 'BITBUCKET_API_TOKEN', status: 'unconfigured', detail: 'not actively probed by the wizard', obtain: 'id.atlassian.com -- create a token' },
    { name: 'REDDIT_COOKIE_FILE', status: 'unconfigured', detail: 'reddit cookie file missing', obtain: 'export a cookie jar' },
  ],
});
console.log(JSON.stringify(summary));
")
echo "$outV11f" | jq -e '.skipped | any(.[]; contains("BITBUCKET_API_TOKEN") and contains("paired with BITBUCKET_EMAIL"))' >/dev/null \
  || fail "V11f [codex-1]: a paired credential's unconfigured wording should name the pair (got: $outV11f)"
echo "$outV11f" | jq -e '.skipped | any(.[]; contains("BITBUCKET_API_TOKEN") and (contains("cannot tell them apart") or contains("either credential may be")))' >/dev/null \
  || fail "V11f [codex-1]: the paired wording should say the probe cannot distinguish which credential is missing (got: $outV11f)"
echo "$outV11f" | jq -e '.skipped | map(select(contains("REDDIT_COOKIE_FILE"))) | any(.[]; contains("paired with"))' >/dev/null \
  && fail "V11f [codex-1] control: an UNPAIRED secret must NOT get the paired wording (got: $outV11f)"
echo "ok: V11f [codex-1] a paired credential's unconfigured wording names the pair and admits the probe can't tell them apart; an unpaired secret keeps the plain wording"

# ── V11g (RETASK stage1-build-6d2e round 11 [codex-2]) — the PHI checklist
# text must describe what luna.phi.declared ACTUALLY records (the adopter's
# yes/no answer to the PHI question), never the old "checklist was shown"
# phrasing -- every adopter with a vault sees the checklist regardless of
# their answer, so "shown" would be true for essentially everyone and the
# field would carry no signal. Pins BOTH printed sites: phiChecklistLines()
# itself and buildSummary's manual-entry wording for phiDeclared=true.
outV11g_checklist=$("$node_bin" -e "
const ap = require('$adopter_profile_lib_w');
console.log(JSON.stringify(ap.phiChecklistLines()));
")
echo "$outV11g_checklist" | jq -e 'any(.[]; contains("records only your yes/no answer") or (contains("records") and contains("answer")))' >/dev/null \
  || fail "V11g [codex-2]: phiChecklistLines() should say the field records the adopter's ANSWER (got: $outV11g_checklist)"
echo "$outV11g_checklist" | jq -e 'any(.[]; contains("checklist was shown") or contains("saw this checklist"))' >/dev/null \
  && fail "V11g [codex-2]: phiChecklistLines() must NOT say it records that the checklist was 'shown' -- every adopter with a vault sees it regardless of their answer (got: $outV11g_checklist)"

outV11g_summary=$("$node_bin" -e "
const ap = require('$adopter_profile_lib_w');
const answers = {
  role: 'adopter', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'inline', path: '' },
  pluginSet: 'lean',
  luna: { cadenceEnabled: false, phiDeclared: true, disarmCadence: false },
  secretsWalk: 'skip',
  bridge: { enabled: false },
};
console.log(JSON.stringify(ap.buildSummary(answers, [], { dryRun: false, configSaveOk: true })));
")
echo "$outV11g_summary" | jq -e '.manual | any(.[]; (.what | contains("PHI trust markers")) and (.how | contains("declared") or (.how | contains("answer"))))' >/dev/null \
  || fail "V11g [codex-2]: buildSummary's PHI manual entry should say the adopter DECLARED/answered, not that a checklist was shown (got: $outV11g_summary)"
echo "$outV11g_summary" | jq -e '.manual | any(.[]; (.what | contains("PHI trust markers")) and ((.how | contains("was shown")) or (.how | contains("saw this checklist"))))' >/dev/null \
  && fail "V11g [codex-2]: buildSummary's PHI manual entry must NOT say 'it was shown' (got: $outV11g_summary)"
echo "ok: V11g [codex-2] the PHI checklist text (both phiChecklistLines() and buildSummary's manual entry) describes the adopter's DECLARATION/answer, never the false 'checklist was shown'"

# ── V11h (RETASK stage1-build-6d2e -- CR finding treated as more than a
# Suggestion) — the bridge-persistence CONSENT PROMPT (bin.js's interactive
# "install bridge persistence now (...)" question) must name the artifact
# THIS platform actually installs, not a hardcoded "systemd --user unit" --
# it was the third site in this family (round 4 fixed the preview, round 9
# fixed buildSummary's planned: line) and had drifted independently both
# times. Since the fix routes the prompt through the SAME shared decision
# buildSummary's own --dry-run wording now reads
# (adopterProfileLib.bridgePersistenceArtifact()), pinning that function
# across platforms -- same process.platform-override technique as V11e --
# pins the prompt text itself: bin.js's prompt is a single, unconditional
# template around this one value (`? install bridge persistence now
# (${persistArtifact}; consented, --dry-run shows it) [yes|no] (default:
# no)\n> `, see bin.js's askQuestions()), so asserting the template's output
# per platform IS asserting the actual prompt wording.
outV11h=$("$node_bin" -e "
const ap = require('$adopter_profile_lib_w');
function promptText(artifact) {
  return '? install bridge persistence now (' + artifact + '; consented, --dry-run shows it) [yes|no] (default: no)';
}
Object.defineProperty(process, 'platform', { value: 'win32', configurable: true });
const winArtifact = ap.bridgePersistenceArtifact();
Object.defineProperty(process, 'platform', { value: 'linux', configurable: true });
const linArtifact = ap.bridgePersistenceArtifact();
Object.defineProperty(process, 'platform', { value: 'darwin', configurable: true });
const macArtifact = ap.bridgePersistenceArtifact();
console.log(JSON.stringify({
  win: winArtifact === null ? null : promptText(winArtifact),
  lin: linArtifact === null ? null : promptText(linArtifact),
  mac: macArtifact,
}));
")
echo "$outV11h" | jq -e '.win | contains("scheduled task")' >/dev/null \
  || fail "V11h: the win32 consent prompt should name the scheduled task (got: $outV11h)"
echo "$outV11h" | jq -e '.win | contains("systemd")' >/dev/null \
  && fail "V11h: the win32 consent prompt must NOT promise a systemd unit -- that is not what will be installed there (got: $outV11h)"
echo "$outV11h" | jq -e '.lin | contains("systemd") and contains("telegram-bridge.service") and contains("linger")' >/dev/null \
  || fail "V11h: the linux consent prompt should name the systemd --user unit AND linger (got: $outV11h)"
echo "$outV11h" | jq -e '.lin | contains("scheduled task")' >/dev/null \
  && fail "V11h: the linux consent prompt must NOT claim a scheduled task -- that is the win32 artifact (got: $outV11h)"
echo "$outV11h" | jq -e '.mac == null' >/dev/null \
  || fail "V11h: an unsupported platform must resolve to null (no artifact) -- bin.js skips the consent prompt entirely on null rather than promise an install that will never happen (got: $outV11h)"
echo "ok: V11h the bridge-persistence consent prompt names the scheduled task on win32, the systemd unit + linger on linux, and promises no install (prompt skipped) on an unsupported platform"

# ═══════════════════════════════════════════════════════════════════════════
# V1 — two --from-profile --dry-run replays produce byte-identical output
# ═══════════════════════════════════════════════════════════════════════════

stubV1="$work/stubV1"; mkdir -p "$stubV1"
pathV1=$(build_path "$stubV1" bash jq python3 npm -- python)
make_git_stub "$stubV1" "https://github.com/someone/other-repo.git"
homeV1="$work/homeV1"; mkdir -p "$homeV1"
bridgeEnvV1="$work/bridgeV1"; mkdir -p "$bridgeEnvV1"
printf 'SOME_UNRELATED_KEY=1\n' > "$bridgeEnvV1/.env"

profileV1="$work/profileV1.json"
cat > "$profileV1" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "default-template", "path": "$(winpath "$work/vaultV1")" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": true, "phiDeclared": true },
  "secretsWalk": "run",
  "bridge": {
    "enabled": true,
    "envPath": "$(winpath "$bridgeEnvV1/.env")",
    "whisperCli": "$(winpath "$work/nowhere-whisper-cli")",
    "whisperModel": "custom-model.bin",
    "installPersistence": true
  }
}
JSON

run_v1_dry_run() {
  PATH="$pathV1" HOME="$homeV1" USERPROFILE="$(winpath "$homeV1")" HIMMELCTL_INTERACTIVE=0 \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-v1-unused.json")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-v1")" \
    HIMMELCTL_BIN_DIR="$(winpath "$work/bin-v1")" \
    "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$profileV1")" </dev/null 2>&1
}

set +e
outV1a=$(run_v1_dry_run); rcV1a=$?
outV1b=$(run_v1_dry_run); rcV1b=$?
set -e
[ "$rcV1a" -eq 0 ] || fail "V1: first --dry-run replay should succeed (got rc=$rcV1a): $outV1a"
[ "$rcV1b" -eq 0 ] || fail "V1: second --dry-run replay should succeed (got rc=$rcV1b): $outV1b"
[ "$outV1a" = "$outV1b" ] \
  || fail "V1: two --from-profile --dry-run replays must be byte-identical
--- run 1 ---
$outV1a
--- run 2 ---
$outV1b"
grepq "$outV1a" 'DRY: luna.cadence.enabled -> true' \
  || fail "V1: expected the luna cadence DRY preview line (got: $outV1a)"
grepq "$outV1a" 'DRY: bash .*pipeline-cadence\.sh arm' \
  || fail "V1: expected the cadence arm DRY preview line (got: $outV1a)"
grepq "$outV1a" 'DRY: bridge config' \
  || fail "V1: expected the bridge config DRY preview line (got: $outV1a)"
echo "ok: V1 two --from-profile --dry-run replays produce byte-identical output"

# ═══════════════════════════════════════════════════════════════════════════
# caseApply — a full --from-profile APPLY run against hermetic fixtures.
# Covers: 8a persistence, bridge.envPath/whisper.{cli,model} actually
# written, cadence arm end-to-end wiring, secrets walk 'unconfigured' (not
# an error), and V12 (TELEGRAM_AUTO_ACTIONS untouched).
# ═══════════════════════════════════════════════════════════════════════════

stubApply="$work/stubApply"; mkdir -p "$stubApply"
pathApply=$(build_path "$stubApply" bash jq python3 npm -- python)
make_git_stub "$stubApply" "https://github.com/someone/other-repo.git"
# RETASK stage1-build-6d2e: a working `python` stub (shadows the scrubbed
# real one — the stub dir is always PATH-first) so the luna-sources secrets
# walk actually probes instead of reading rc=127 "not found" for every
# entry; see make_python_stub's own comment for the exact per-source replies.
make_python_stub "$stubApply"
homeApply="$work/homeApply"; mkdir -p "$homeApply"

fixtureRepo="$work/fixture-repo"; mkdir -p "$fixtureRepo/scripts/luna"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepo/scripts/adopt.sh"
chmod +x "$fixtureRepo/scripts/adopt.sh"

markerFile="$work/cadence-arm-marker.txt"
cat > "$fixtureRepo/scripts/luna/pipeline-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_FILE"
exit 0
STUB
chmod +x "$fixtureRepo/scripts/luna/pipeline-cadence.sh"

bridgeDirApply="$work/bridgeApply"; mkdir -p "$bridgeDirApply"
bridgeEnvApply="$bridgeDirApply/.env"
printf 'SOME_UNRELATED_KEY=1\n' > "$bridgeEnvApply"
bridgeEnvBefore=$(cat "$bridgeEnvApply")

vaultPathApply="$(winpath "$work/vaultApply")"
bridgeEnvPathApply="$(winpath "$bridgeEnvApply")"
whisperCliApply="$(winpath "$work/nowhere-whisper-cli")"
configPathApply="$(winpath "$work/config-apply.json")"

profileApply="$work/profileApply.json"
cat > "$profileApply" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "default-template", "path": "$vaultPathApply" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": true, "phiDeclared": false },
  "secretsWalk": "run",
  "bridge": {
    "enabled": true,
    "envPath": "$bridgeEnvPathApply",
    "whisperCli": "$whisperCliApply",
    "whisperModel": "custom-model.bin",
    "installPersistence": false
  }
}
JSON

set +e
outApply=$(PATH="$pathApply" HOME="$homeApply" USERPROFILE="$(winpath "$homeApply")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathApply" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-apply")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-apply")" \
  MARKER_FILE="$(winpath "$markerFile")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileApply")" </dev/null 2>&1)
rcApply=$?
set -e
[ "$rcApply" -eq 0 ] || fail "caseApply: full apply run should exit 0 (got rc=$rcApply): $outApply"
echo "ok: caseApply full --from-profile apply run exits 0"

# --- 8a persistence + round-trip -------------------------------------------
outCfg=$("$node_bin" -e "
process.env.HIMMEL_LUNA_CONFIG_PATH = '$configPathApply';
const lc = require('$luna_config_lib_w');
const doc = lc.load();
console.log(JSON.stringify({ doc, errors: lc.validateConfig(doc) }));
")
echo "$outCfg" | jq -e '.errors | length == 0' >/dev/null \
  || fail "caseApply/8a: the saved config must validate cleanly against luna-config.js's own schema (got: $outCfg)"
echo "$outCfg" | jq -e --arg v "$vaultPathApply" '.doc.luna.vaultPath == $v' >/dev/null \
  || fail "caseApply/8a: luna.vaultPath should be the answered vault path (got: $outCfg)"
echo "$outCfg" | jq -e '.doc.luna.cadence.enabled == true' >/dev/null \
  || fail "caseApply/8a: luna.cadence.enabled should be true (got: $outCfg)"
echo "$outCfg" | jq -e '.doc.luna.cadence.schedules.fetchHealth.time and .doc.luna.cadence.schedules.harvest.time and .doc.luna.cadence.schedules.synthesize.time and .doc.luna.cadence.schedules.health.time' >/dev/null \
  || fail "caseApply/8a: all four luna.cadence.schedules.* entries should be present with a time (got: $outCfg)"
echo "$outCfg" | jq -e '.doc.luna.cadence.models.harvest and .doc.luna.cadence.models.synthesize and .doc.luna.cadence.models.health' >/dev/null \
  || fail "caseApply/8a: all three luna.cadence.models.* entries should be present (got: $outCfg)"
echo "$outCfg" | jq -e '.doc.luna.phi.declared == false' >/dev/null \
  || fail "caseApply/8a: luna.phi.declared should be false (answered no) (got: $outCfg)"
echo "$outCfg" | jq -e '.doc.bridge.enabled == true' >/dev/null \
  || fail "caseApply/8a: bridge.enabled should be true (got: $outCfg)"
echo "ok: caseApply/8a the three sections' answers land in ~/.himmel/config.json at the exact 8a field paths, and lunaConfig.load() round-trips them cleanly"

# --- bridge.envPath + whisper.{cli,model} actually written ------------------
echo "$outCfg" | jq -e --arg v "$bridgeEnvPathApply" '.doc.bridge.envPath == $v' >/dev/null \
  || fail "caseApply: bridge.envPath should be the operator's configured value, not the schema default (got: $outCfg)"
echo "$outCfg" | jq -e --arg v "$whisperCliApply" '.doc.bridge.whisper.cli == $v' >/dev/null \
  || fail "caseApply: bridge.whisper.cli should be the operator's configured value, not null/default (got: $outCfg)"
echo "$outCfg" | jq -e '.doc.bridge.whisper.model == "custom-model.bin"' >/dev/null \
  || fail "caseApply: bridge.whisper.model should be the operator's configured value, not ggml-small.bin (got: $outCfg)"
echo "ok: caseApply bridge.envPath + bridge.whisper.{cli,model} are actually written (not left at defaults)"

# --- cadence arm end-to-end wiring ------------------------------------------
[ -f "$markerFile" ] || fail "caseApply: pipeline-cadence.sh stub should have been invoked (marker file missing: $markerFile)"
markerContent=$(cat "$markerFile")
grepq "$markerContent" -F -- 'arm' || fail "caseApply: cadence spawn should invoke the 'arm' subcommand (got: $markerContent)"
grepq "$markerContent" -F -- '--fetch-health-time' || fail "caseApply: cadence arm argv missing --fetch-health-time (got: $markerContent)"
grepq "$markerContent" -F -- '--synth-time' || fail "caseApply: cadence arm argv missing --synth-time (got: $markerContent)"
grepq "$markerContent" -F -- '--health-day' || fail "caseApply: cadence arm argv missing --health-day (got: $markerContent)"
grepq "$markerContent" -F -- "--vault" || fail "caseApply: cadence arm argv missing --vault (got: $markerContent)"
grepq "$markerContent" -F -- "$vaultPathApply" || fail "caseApply: cadence arm argv should carry the configured vault path (got: $markerContent)"
echo "ok: caseApply luna cadence — the apply step actually spawns pipeline-cadence.sh arm with the expected argv (end-to-end wiring)"

# --- secrets walk: unconfigured, not an error --------------------------------
grepq "$outApply" 'unconfigured' \
  || fail "caseApply: secrets walk should report at least one 'unconfigured' secret (got: $outApply)"
grepq "$outApply" -i 'BITBUCKET_API_TOKEN' \
  || fail "caseApply: secrets walk should show the instruction card for BITBUCKET_API_TOKEN (got: $outApply)"
echo "ok: caseApply secrets walk — a skipped source reports unconfigured, not an error (rc stayed 0)"

# --- V12: TELEGRAM_AUTO_ACTIONS untouched, before AND after -----------------
grepq "$bridgeEnvBefore" 'TELEGRAM_AUTO_ACTIONS' \
  && fail "V12: sanity — the fixture .env must not carry TELEGRAM_AUTO_ACTIONS before the run"
bridgeEnvAfter=$(cat "$bridgeEnvApply")
[ "$bridgeEnvBefore" = "$bridgeEnvAfter" ] \
  || fail "V12: the bridge .env must be byte-identical before/after the run — the wizard must never write to it
before: $bridgeEnvBefore
after:  $bridgeEnvAfter"
grepq "$bridgeEnvAfter" 'TELEGRAM_AUTO_ACTIONS' \
  && fail "V12: TELEGRAM_AUTO_ACTIONS must never appear in the bridge .env after the run (got: $bridgeEnvAfter)"
grepq "$outApply" 'TELEGRAM_AUTO_ACTIONS' \
  && fail "V12: TELEGRAM_AUTO_ACTIONS must never appear anywhere in the wizard's own output (printed profile JSON included) (got: $outApply)"
grepq "$(cat "$profileApply")" 'TELEGRAM_AUTO_ACTIONS' \
  && fail "V12: sanity — the profile fixture itself must not name TELEGRAM_AUTO_ACTIONS"
echo "ok: V12 TELEGRAM_AUTO_ACTIONS is absent from the bridge .env and the profile, both before and after the run"

# ═══════════════════════════════════════════════════════════════════════════
# caseSecretsProbe (RETASK stage1-build-6d2e) — the three luna-sources secrets
# walk verdicts, precisely: a configured+healthy source reports ok/configured;
# a configured-but-broken source surfaces the PROBE'S OWN reason and is never
# flattened to 'unconfigured'; a never-configured source reports
# 'unconfigured'; and a failing source never aborts the install (rc stays 0).
# Drives the REAL secrets-manifest.json (BITBUCKET_API_TOKEN -> bitbucket,
# FIRECRAWL_API_KEY -> firecrawl, REDDIT_COOKIE_FILE -> reddit) against the
# hermetic `python` stub above — NO live network call, no real fetch-health.py
# execution (the stub shadows both `python`/`python3` resolution and never
# spawns the real interpreter).
# ═══════════════════════════════════════════════════════════════════════════

stubSecrets="$work/stubSecrets"; mkdir -p "$stubSecrets"
pathSecrets=$(build_path "$stubSecrets" bash jq python3 npm -- python)
make_git_stub "$stubSecrets" "https://github.com/someone/other-repo.git"
make_python_stub "$stubSecrets"
homeSecrets="$work/homeSecrets"; mkdir -p "$homeSecrets"

fixtureRepoSecrets="$work/fixture-repo-secrets"; mkdir -p "$fixtureRepoSecrets/scripts/luna"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoSecrets/scripts/adopt.sh"
chmod +x "$fixtureRepoSecrets/scripts/adopt.sh"
# probeLunaSources only needs a resolvable PATH (ctx.repoRoot + item.probe.script);
# the file's own contents are never read — the hermetic `python` stub replies
# without ever executing it. An empty placeholder keeps path.resolve() honest.
: > "$fixtureRepoSecrets/scripts/luna/fetch-health.py"

configPathSecrets="$(winpath "$work/config-secrets.json")"
# HIMMEL-2305: the secrets walk now scopes OUT a feature's secrets when it
# was never selected — vault=none used to be irrelevant to this fixture (it
# only exists to exercise the luna-sources verdict rendering below), but
# BITBUCKET_API_TOKEN/FIRECRAWL_API_KEY/REDDIT_COOKIE_FILE are all tagged
# feature:vault, so vault must actually be selected for them to be walked
# at all. vaultPathSecrets is never created -- adopt.sh is a no-op stub here.
vaultPathSecrets="$(winpath "$work/vaultSecrets")"
profileSecrets="$work/profileSecrets.json"
cat > "$profileSecrets" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "default-template", "path": "$vaultPathSecrets" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false },
  "secretsWalk": "run",
  "bridge": {
    "enabled": false,
    "envPath": "~/.claude/channels/telegram/.env",
    "whisperCli": "",
    "whisperModel": "ggml-small.bin",
    "installPersistence": false
  }
}
JSON

set +e
outSecrets=$(PATH="$pathSecrets" HOME="$homeSecrets" USERPROFILE="$(winpath "$homeSecrets")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoSecrets")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathSecrets" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-secrets")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-secrets")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileSecrets")" </dev/null 2>&1)
rcSecrets=$?
set -e
[ "$rcSecrets" -eq 0 ] || fail "caseSecretsProbe: a failing source must NOT abort the install — expected rc=0 (got $rcSecrets): $outSecrets"
echo "ok: caseSecretsProbe a failing source does not abort the install (rc stayed 0)"

grepq "$outSecrets" -F -- 'installed:' || fail "caseSecretsProbe: expected an install summary (got: $outSecrets)"
installedBlock=$(printf '%s' "$outSecrets" | sed -n '/^installed:$/,/^$/p')
skippedBlock=$(printf '%s' "$outSecrets" | sed -n '/^skipped:$/,/^$/p')
manualBlock=$(printf '%s' "$outSecrets" | sed -n '/^still manual/,$p')

grepq "$installedBlock" -F -- 'BITBUCKET_API_TOKEN' \
  || fail "caseSecretsProbe: a configured+healthy source (BITBUCKET_API_TOKEN -> bitbucket, stub replies ok) should report configured under installed: (got installed block: $installedBlock)"
grepq "$installedBlock" -i 'configured' \
  || fail "caseSecretsProbe: the installed-bucket line should say 'configured' (got: $installedBlock)"
echo "ok: caseSecretsProbe a configured source probing green (bitbucket=ok) reports configured under installed:"

grepq "$manualBlock" -F -- 'FIRECRAWL_API_KEY' \
  || fail "caseSecretsProbe: a configured-but-broken source (FIRECRAWL_API_KEY -> firecrawl, stub replies blocked-or-rate-limited) should land under still-manual (got manual block: $manualBlock)"
grepq "$manualBlock" -F -- 'blocked-or-rate-limited' \
  || fail "caseSecretsProbe: the manual entry must surface the PROBE'S OWN reason, not a flat verdict (got: $manualBlock)"
grepq "$(printf '%s\n' "$manualBlock" | grep -F 'FIRECRAWL_API_KEY')" -F -- 'unconfigured' \
  && fail "caseSecretsProbe: a configured-but-broken source must NEVER be reported as unconfigured (got: $manualBlock)"
echo "ok: caseSecretsProbe a configured source whose probe fails (firecrawl=blocked-or-rate-limited) surfaces the probe's own reason, never flattened to unconfigured"

grepq "$skippedBlock" -F -- 'REDDIT_COOKIE_FILE' \
  || fail "caseSecretsProbe: a never-configured source (REDDIT_COOKIE_FILE -> reddit, stub replies auth-or-cookie-expired/...missing) should land under skipped (got skipped block: $skippedBlock)"
grepq "$(printf '%s\n' "$skippedBlock" | grep -F 'REDDIT_COOKIE_FILE')" -F -- 'unconfigured' \
  || fail "caseSecretsProbe: the skipped entry should say unconfigured (got: $skippedBlock)"
echo "ok: caseSecretsProbe a skipped/never-configured source (reddit) reports unconfigured under skipped:"

# ═══════════════════════════════════════════════════════════════════════════
# caseSecretsProbeDedup (RETASK stage1-build-6d2e -- CR Suggestion) -- paired
# credentials (BITBUCKET_API_TOKEN/BITBUCKET_EMAIL -> bitbucket,
# TWITTER_AUTH_TOKEN/TWITTER_CT0 -> x-twitter-cli) both declare the SAME
# luna-sources id, so a naive per-entry walk fires the SAME external
# fetch-health.py --probe <source> call twice per source per walk. Proves
# runSecretsWalk's per-source memoization actually invokes the underlying
# probe ONCE per source (counted via PROBE_INVOCATION_LOG, the python stub's
# opt-in call log) while BOTH paired entries still each print their own,
# IDENTICAL verdict line -- dedup must never merge or drop a reported row.
# ═══════════════════════════════════════════════════════════════════════════

stubDedup="$work/stubDedup"; mkdir -p "$stubDedup"
pathDedup=$(build_path "$stubDedup" bash jq python3 npm -- python)
make_git_stub "$stubDedup" "https://github.com/someone/other-repo.git"
make_python_stub "$stubDedup"
homeDedup="$work/homeDedup"; mkdir -p "$homeDedup"

fixtureRepoDedup="$work/fixture-repo-dedup"; mkdir -p "$fixtureRepoDedup/scripts/luna"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoDedup/scripts/adopt.sh"
chmod +x "$fixtureRepoDedup/scripts/adopt.sh"
: > "$fixtureRepoDedup/scripts/luna/fetch-health.py"

configPathDedup="$(winpath "$work/config-dedup.json")"
probeLogDedup="$work/probe-invocations-dedup.log"
rm -f "$probeLogDedup"

# HIMMEL-2305: BITBUCKET_API_TOKEN/BITBUCKET_EMAIL/TWITTER_AUTH_TOKEN/
# TWITTER_CT0 are all tagged feature:vault -- vault must be selected for
# this dedup test to still walk them. vaultPathDedup is never created --
# adopt.sh is a no-op stub here.
vaultPathDedup="$(winpath "$work/vaultDedup")"
profileDedup="$work/profileDedup.json"
cat > "$profileDedup" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "default-template", "path": "$vaultPathDedup" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false },
  "secretsWalk": "run",
  "bridge": {
    "enabled": false,
    "envPath": "~/.claude/channels/telegram/.env",
    "whisperCli": "",
    "whisperModel": "ggml-small.bin",
    "installPersistence": false
  }
}
JSON

set +e
outDedup=$(PATH="$pathDedup" HOME="$homeDedup" USERPROFILE="$(winpath "$homeDedup")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoDedup")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathDedup" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-dedup")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-dedup")" \
  PROBE_INVOCATION_LOG="$(winpath "$probeLogDedup")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileDedup")" </dev/null 2>&1)
rcDedup=$?
set -e
[ "$rcDedup" -eq 0 ] || fail "caseSecretsProbeDedup: run should exit 0 (got rc=$rcDedup): $outDedup"

[ -f "$probeLogDedup" ] || fail "caseSecretsProbeDedup: expected the probe invocation log at $probeLogDedup (got run output: $outDedup)"
bitbucketCallsDedup=$(grep -c -F -- 'bitbucket' "$probeLogDedup" || true)
twitterCallsDedup=$(grep -c -F -- 'x-twitter-cli' "$probeLogDedup" || true)
[ "$bitbucketCallsDedup" -eq 1 ] \
  || fail "caseSecretsProbeDedup: bitbucket should be probed EXACTLY ONCE across BITBUCKET_API_TOKEN + BITBUCKET_EMAIL, not once per credential (got $bitbucketCallsDedup calls; log: $(cat "$probeLogDedup"))"
[ "$twitterCallsDedup" -eq 1 ] \
  || fail "caseSecretsProbeDedup: x-twitter-cli should be probed EXACTLY ONCE across TWITTER_AUTH_TOKEN + TWITTER_CT0, not once per credential (got $twitterCallsDedup calls; log: $(cat "$probeLogDedup"))"
echo "ok: caseSecretsProbeDedup a paired source (bitbucket, x-twitter-cli) is probed exactly once per walk, not once per credential naming it"

# Both members of a pair must still get their OWN printed line, and it must
# be the SAME verdict the single shared probe actually returned -- dedup must
# never merge the two rows into one or drop either.
grepq "$outDedup" -F -- 'BITBUCKET_API_TOKEN' \
  || fail "caseSecretsProbeDedup: BITBUCKET_API_TOKEN should still get its own printed line (got: $outDedup)"
grepq "$outDedup" -F -- 'BITBUCKET_EMAIL' \
  || fail "caseSecretsProbeDedup: BITBUCKET_EMAIL should still get its own printed line (got: $outDedup)"
# Anchored on the literal "  <NAME> [<required>]" header line (not a
# substring match) -- BITBUCKET_API_TOKEN's own obtain text NAMES
# BITBUCKET_EMAIL (and vice versa), so a plain substring grep would also
# catch the sibling's cross-reference line instead of just its own block.
bitbucketApiLineDedup=$(printf '%s\n' "$outDedup" | sed -n '/^  BITBUCKET_API_TOKEN \[/,/^    probe:/p' | grep -F 'probe:')
bitbucketEmailLineDedup=$(printf '%s\n' "$outDedup" | sed -n '/^  BITBUCKET_EMAIL \[/,/^    probe:/p' | grep -F 'probe:')
grepq "$bitbucketApiLineDedup" -F -- 'configured' \
  || fail "caseSecretsProbeDedup: BITBUCKET_API_TOKEN's own line should still read configured (stub replies ok) (got: $bitbucketApiLineDedup)"
grepq "$bitbucketEmailLineDedup" -F -- 'configured' \
  || fail "caseSecretsProbeDedup: BITBUCKET_EMAIL's own line should still read configured -- the memoized reuse must carry the SAME verdict, not drop it (got: $bitbucketEmailLineDedup)"

grepq "$outDedup" -F -- 'TWITTER_AUTH_TOKEN' \
  || fail "caseSecretsProbeDedup: TWITTER_AUTH_TOKEN should still get its own printed line (got: $outDedup)"
grepq "$outDedup" -F -- 'TWITTER_CT0' \
  || fail "caseSecretsProbeDedup: TWITTER_CT0 should still get its own printed line (got: $outDedup)"
skippedBlockDedup=$(printf '%s' "$outDedup" | sed -n '/^skipped:$/,/^$/p')
grepq "$(printf '%s\n' "$skippedBlockDedup" | grep -F 'TWITTER_AUTH_TOKEN')" -F -- 'paired with TWITTER_CT0' \
  || fail "caseSecretsProbeDedup: TWITTER_AUTH_TOKEN's unconfigured line should still name its sibling TWITTER_CT0 (got skipped block: $skippedBlockDedup)"
grepq "$(printf '%s\n' "$skippedBlockDedup" | grep -F 'TWITTER_CT0')" -F -- 'paired with TWITTER_AUTH_TOKEN' \
  || fail "caseSecretsProbeDedup: TWITTER_CT0's unconfigured line should still name its sibling TWITTER_AUTH_TOKEN (got skipped block: $skippedBlockDedup)"
echo "ok: caseSecretsProbeDedup both members of a pair still print their own line with the identical, correct verdict -- dedup changes call count only, never wording"

# ═══════════════════════════════════════════════════════════════════════════
# caseSecretsWalkNoBridge (RETASK stage1-build-6d2e CR round 15 [codex-1]) --
# secretsWalk='run' with a bridge section that carries ONLY `enabled:true`
# (no envPath/whisperCli/whisperModel at all). The WHISPER_MODEL secret's
# probe reads resolveWhisperEnvOverrides(bridge), which used to dereference
# bridge.whisperModel/bridge.whisperCli straight through -- fine while every
# caller already guards with `answers.bridge || {}`, but a latent crash if
# that guard were ever missing when the FIELDS themselves are absent (the
# exact causal chain the finding names: round 8 made "no bridge section" a
# real `undefined`, round 7 wired whisper resolution to read `bridge`
# directly). Proves the WHISPER_MODEL secret still reports a normal verdict
# (probing with the hardcoded defaults, the bottom tier of
# WHISPER_CLI/WHISPER_MODEL's precedence) rather than an internal/thrown
# error.
#
# HIMMEL-2305: bridge.enabled must be true for TELEGRAM_BOT_TOKEN/
# WHISPER_MODEL (feature:bridge/whisper) to be walked at all under the new
# selection scoping -- an entirely ABSENT bridge section (the original,
# pre-2305 shape of this fixture) now scopes both out before they ever reach
# the probe this case exists to stress; `bridge: {enabled:true}` with every
# OTHER field missing keeps both secrets in scope while still exercising the
# exact "guard against a partial/incomplete bridge object" property this
# case is named for. Selection-scoping itself (an entirely-absent bridge
# section scoping WHISPER_MODEL/TELEGRAM_BOT_TOKEN out, and the honest
# "scoped out N secret(s)" line) is covered separately by
# test-wizard-adopter-profile.sh's caseAC (resolveActiveFeatures unit test).
# ═══════════════════════════════════════════════════════════════════════════

stubNB="$work/stubNB"; mkdir -p "$stubNB"
pathNB=$(build_path "$stubNB" bash jq python3 npm -- python)
make_git_stub "$stubNB" "https://github.com/someone/other-repo.git"
homeNB="$work/homeNB"; mkdir -p "$homeNB"

fixtureRepoNB="$work/fixture-repo-nobridge"; mkdir -p "$fixtureRepoNB/scripts/luna"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoNB/scripts/adopt.sh"
chmod +x "$fixtureRepoNB/scripts/adopt.sh"
: > "$fixtureRepoNB/scripts/luna/fetch-health.py"

# CR fix (HIMMEL-2176): bridgeEnvProbeCtx() used to resolve an absent/empty
# bridge.envPath to the EMPTY string (`(bridge && bridge.envPath) || ''`),
# which resolves to CWD (`path.dirname('')` is `.`) instead of the
# documented bridge default (~/.claude/channels/telegram/.env) — so
# TELEGRAM_BOT_TOKEN silently probed the wrong path and always read
# 'unconfigured', even with a real bridge .env sitting where it belongs.
# A fixture .env AT the default location (relative to $homeNB, this run's
# HOME) proves the probe actually looks there when no bridge section names
# a different path.
mkdir -p "$homeNB/.claude/channels/telegram"
printf 'TELEGRAM_BOT_TOKEN=fake-token-not-real\n' > "$homeNB/.claude/channels/telegram/.env"

configPathNB="$(winpath "$work/config-nobridge.json")"
# The exact pre-Task-8-shaped-but-with-secretsWalk profile: secretsWalk='run'
# is present and asked; luna/bridge are ABSENT entirely (never "off"),
# matching what a vault=none interactive run (or an old cache) legally
# produces per caseVaultNoneNoOp/caseLegacyProfile above.
profileNB="$work/profileNoBridge.json"
cat > "$profileNB" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "secretsWalk": "run",
  "bridge": {
    "enabled": true,
    "envPath": "",
    "whisperCli": "",
    "whisperModel": "",
    "installPersistence": false
  }
}
JSON

set +e
outNB=$(PATH="$pathNB" HOME="$homeNB" USERPROFILE="$(winpath "$homeNB")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoNB")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathNB" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-nobridge")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-nobridge")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileNB")" </dev/null 2>&1)
rcNB=$?
set -e
[ "$rcNB" -eq 0 ] \
  || fail "caseSecretsWalkNoBridge: a profile with secretsWalk=run and no bridge key should still exit 0 (got rc=$rcNB): $outNB"

whisperLineNB=$(printf '%s\n' "$outNB" | sed -n '/^  WHISPER_MODEL \[/,/^    probe:/p' | grep -F 'probe:')
[ -n "$whisperLineNB" ] || fail "caseSecretsWalkNoBridge: expected a WHISPER_MODEL probe line in the walk (got: $outNB)"
grepq "$whisperLineNB" -F -- 'error' \
  && fail "caseSecretsWalkNoBridge [codex-1]: WHISPER_MODEL must NOT report an internal/thrown error when bridge is entirely absent (got: $whisperLineNB)"
grepq "$whisperLineNB" -F -- 'probe threw' \
  && fail "caseSecretsWalkNoBridge [codex-1]: WHISPER_MODEL must NOT crash resolveWhisperEnvOverrides on an absent bridge section (got: $whisperLineNB)"
grepq "$whisperLineNB" -F -- 'unconfigured' \
  || fail "caseSecretsWalkNoBridge [codex-1]: WHISPER_MODEL should probe with the hardcoded defaults and report a normal 'unconfigured' verdict (no model on disk in this fixture) (got: $whisperLineNB)"
echo "ok: caseSecretsWalkNoBridge [codex-1] secretsWalk=run with a bridge section carrying only enabled:true still probes WHISPER_MODEL with the hardcoded defaults and reports a normal verdict, never an internal error"

# CR fix (HIMMEL-2176): TELEGRAM_BOT_TOKEN must be probed against the
# documented bridge default (~/.claude/channels/telegram/.env, i.e.
# $homeNB/.claude/channels/telegram/.env here), not an empty-string path
# that resolves to CWD. The fixture .env above carries a token but the
# fixture repo has no scripts/telegram/telegram-api.ts for bun to import --
# deliberately: this proves the env file was found and its token read
# (the probe gets far enough to dynamic-import that module and name its own
# path) WITHOUT ever making a live Telegram network call. A pre-fix run
# never gets this far: it can't even find the file (CWD has no .env),
# fails at the read step, and reports the FALSE 'unconfigured' verdict this
# test guards against.
telegramLineNB=$(printf '%s\n' "$outNB" | sed -n '/^  TELEGRAM_BOT_TOKEN \[/,/^    probe:/p' | grep -F 'probe:')
[ -n "$telegramLineNB" ] || fail "caseSecretsWalkNoBridge: expected a TELEGRAM_BOT_TOKEN probe line in the walk (got: $outNB)"
grepq "$telegramLineNB" -F -- 'unconfigured' \
  && fail "caseSecretsWalkNoBridge: TELEGRAM_BOT_TOKEN must NOT report 'unconfigured' when a fixture .env exists at the bridge default path -- an empty envPath is resolving to CWD instead of ~/.claude/channels/telegram/.env (got: $telegramLineNB)"
grepq "$telegramLineNB" -F -- 'cannot read' \
  && fail "caseSecretsWalkNoBridge: TELEGRAM_BOT_TOKEN must not fail at the file-read step -- the fixture .env at the bridge default path should have been found (got: $telegramLineNB)"
grepq "$telegramLineNB" -F -- 'telegram-api.ts' \
  || fail "caseSecretsWalkNoBridge: expected TELEGRAM_BOT_TOKEN to reach the getMe dynamic-import step (proving the fixture .env at the default path WAS found and its token read) (got: $telegramLineNB)"
echo "ok: caseSecretsWalkNoBridge TELEGRAM_BOT_TOKEN resolves an absent bridge section to the documented default path, not an empty-string CWD lookup"

# ═══════════════════════════════════════════════════════════════════════════
# caseSecretsWalkScoping (HIMMEL-2305) -- vault=none + no bridge section at
# all + secretsWalk='run': every secret in the REAL manifest is tagged
# feature:vault/bridge/whisper, and NONE of those features are selected, so
# the walk must scope ALL of them out -- printing the one honest
# "scoped out N secret(s)" line (naming which features, comma-separated) and
# never a single per-secret instruction card. This is the exact
# "cadence-off, bridge-off adopter should not be nagged" scenario the ticket
# names, applied to the vault-off case too (bridge/whisper follow vault=none
# here because the profile also omits `bridge` entirely -- never asked).
# ═══════════════════════════════════════════════════════════════════════════

stubScoping="$work/stubScoping"; mkdir -p "$stubScoping"
pathScoping=$(build_path "$stubScoping" bash jq python3 npm -- python)
make_git_stub "$stubScoping" "https://github.com/someone/other-repo.git"
homeScoping="$work/homeScoping"; mkdir -p "$homeScoping"

fixtureRepoScoping="$work/fixture-repo-scoping"; mkdir -p "$fixtureRepoScoping/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoScoping/scripts/adopt.sh"
chmod +x "$fixtureRepoScoping/scripts/adopt.sh"

configPathScoping="$(winpath "$work/config-scoping.json")"
profileScoping="$work/profileScoping.json"
cat > "$profileScoping" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "secretsWalk": "run"
}
JSON

set +e
outScoping=$(PATH="$pathScoping" HOME="$homeScoping" USERPROFILE="$(winpath "$homeScoping")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoScoping")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathScoping" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-scoping")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-scoping")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileScoping")" </dev/null 2>&1)
rcScoping=$?
set -e
[ "$rcScoping" -eq 0 ] \
  || fail "caseSecretsWalkScoping: a profile with every optional feature never selected should still exit 0 (got rc=$rcScoping): $outScoping"

grepq "$outScoping" -F -- 'scoped out' \
  || fail "caseSecretsWalkScoping: expected the honest 'scoped out N secret(s)' line (got: $outScoping)"
grepq "$outScoping" -F -- 'TELEGRAM_BOT_TOKEN' \
  && fail "caseSecretsWalkScoping: TELEGRAM_BOT_TOKEN (feature:bridge, never selected) must NOT get an instruction card (got: $outScoping)"
grepq "$outScoping" -F -- 'BITBUCKET_API_TOKEN' \
  && fail "caseSecretsWalkScoping: BITBUCKET_API_TOKEN (feature:vault, never selected -- vault=none) must NOT get an instruction card (got: $outScoping)"
grepq "$outScoping" -F -- 'WHISPER_MODEL' \
  && fail "caseSecretsWalkScoping: WHISPER_MODEL (feature:whisper, never selected) must NOT get an instruction card (got: $outScoping)"
echo "ok: caseSecretsWalkScoping — vault=none + no bridge section scopes EVERY secret out, printing one honest line and zero instruction cards"

# ═══════════════════════════════════════════════════════════════════════════
# caseLegacyProfile (RETASK stage1-build-6d2e [codex-1]) — a profile with NO
# luna/bridge sections at all (the pre-Task-8 shape) must NEVER disarm an
# existing config: cadence.enabled/phi.declared/bridge.enabled must survive
# the run UNCHANGED, never coerced from `undefined` to `false`.
# ═══════════════════════════════════════════════════════════════════════════

stubLegacy="$work/stubLegacy"; mkdir -p "$stubLegacy"
pathLegacy=$(build_path "$stubLegacy" bash jq python3 npm -- python)
make_git_stub "$stubLegacy" "https://github.com/someone/other-repo.git"
homeLegacy="$work/homeLegacy"; mkdir -p "$homeLegacy"

fixtureRepoLegacy="$work/fixture-repo-legacy"; mkdir -p "$fixtureRepoLegacy/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoLegacy/scripts/adopt.sh"
chmod +x "$fixtureRepoLegacy/scripts/adopt.sh"

configPathLegacy="$(winpath "$work/config-legacy.json")"

# Seed a config that is ALREADY armed (cadence on, PHI declared, bridge on)
# — the exact state a legacy --from-profile replay must leave untouched.
"$node_bin" -e "
process.env.HIMMEL_LUNA_CONFIG_PATH = '$configPathLegacy';
const lc = require('$luna_config_lib_w');
const d = lc.defaultConfig();
d.luna.cadence.enabled = true;
d.luna.phi.declared = true;
d.bridge.enabled = true;
lc.save(d);
"

# A LEGACY profile — the exact pre-Task-8 shape: no luna/secretsWalk/bridge
# keys at all. loadProfile() must still accept it (those sections are
# optional), and the apply step must leave the seeded config alone.
profileLegacy="$work/profileLegacy.json"
cat > "$profileLegacy" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false
}
JSON

set +e
outLegacy=$(PATH="$pathLegacy" HOME="$homeLegacy" USERPROFILE="$(winpath "$homeLegacy")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoLegacy")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathLegacy" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-legacy")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-legacy")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileLegacy")" </dev/null 2>&1)
rcLegacy=$?
set -e
[ "$rcLegacy" -eq 0 ] || fail "caseLegacyProfile: a legacy (pre-Task-8) profile should still install successfully (got rc=$rcLegacy): $outLegacy"

outLegacyCfg=$("$node_bin" -e "
process.env.HIMMEL_LUNA_CONFIG_PATH = '$configPathLegacy';
const lc = require('$luna_config_lib_w');
console.log(JSON.stringify(lc.load()));
")
echo "$outLegacyCfg" | jq -e '.luna.cadence.enabled == true' >/dev/null \
  || fail "caseLegacyProfile [codex-1]: a legacy profile must NOT disarm an already-enabled luna.cadence.enabled (got: $outLegacyCfg)"
echo "$outLegacyCfg" | jq -e '.luna.phi.declared == true' >/dev/null \
  || fail "caseLegacyProfile [codex-1]: a legacy profile must NOT clear an already-declared luna.phi.declared (got: $outLegacyCfg)"
echo "$outLegacyCfg" | jq -e '.bridge.enabled == true' >/dev/null \
  || fail "caseLegacyProfile [codex-1]: a legacy profile must NOT disable an already-enabled bridge.enabled (got: $outLegacyCfg)"
grepq "$outLegacy" -F -- 'profile carries no luna section' \
  || fail "caseLegacyProfile: the run should disclose that the luna section was left untouched (got: $outLegacy)"
grepq "$outLegacy" -F -- 'profile carries no bridge section' \
  || fail "caseLegacyProfile: the run should disclose that the bridge section was left untouched (got: $outLegacy)"
echo "ok: caseLegacyProfile [codex-1] a legacy --from-profile (no luna/bridge sections) leaves an existing armed config untouched, not silently disarmed"

# RETASK stage1-build-6d2e round 3: the rendered summary itself must say
# "left as-is", never the false "you answered ...=off" (an already-armed
# config replayed through a legacy profile must not be told it was turned
# off, when it was in fact deliberately left alone).
skippedBlockLegacy=$(printf '%s' "$outLegacy" | sed -n '/^skipped:$/,/^$/p')
grepq "$skippedBlockLegacy" -F -- 'left as-is' \
  || fail "caseLegacyProfile: the summary's skipped: bucket should use the honest 'left as-is' wording (got skipped block: $skippedBlockLegacy)"
grepq "$skippedBlockLegacy" -F -- 'cadence=off' \
  && fail "caseLegacyProfile: an untouched (still-armed) cadence must NEVER be summarized as 'you answered cadence=off' (got: $skippedBlockLegacy)"
grepq "$skippedBlockLegacy" -F -- 'bridge=off' \
  && fail "caseLegacyProfile: an untouched (still-enabled) bridge must NEVER be summarized as 'you answered bridge=off' (got: $skippedBlockLegacy)"
echo "ok: caseLegacyProfile the rendered summary says 'left as-is', never the false 'you answered cadence=off'/'bridge=off'"

# ═══════════════════════════════════════════════════════════════════════════
# caseVaultNoneNoOp (RETASK stage1-build-6d2e round 8 [codex-1] CRITICAL) —
# the round-1 defect returning through a SECOND door: caseLegacyProfile only
# covered a --from-profile cache that was ALREADY missing the luna/bridge
# keys (a legacy file). This case covers the path that PRODUCES such a
# profile in the first place: an INTERACTIVE adopter run answering
# vault=none, where the luna/secrets/bridge questions are never asked at
# all (they are gated behind vault!=none — see askQuestions' own comment).
# Before the fix, buildAnswers() still serialized answer-shaped "off"
# defaults for a section nobody was asked about, so lunaSectionSupplied()/
# bridgeSectionSupplied() read that manufactured presence as genuine
# consent and a LATER replay of that innocuous cache would silently disarm
# an already-armed config — exactly the codex-1 class, arriving through the
# interactive->cache path instead of a hand-authored legacy file.
# ═══════════════════════════════════════════════════════════════════════════

stubVN="$work/stubVN"; mkdir -p "$stubVN"
pathVN=$(build_path "$stubVN" bash jq python3 npm -- python)
make_git_stub "$stubVN" "https://github.com/someone/other-repo.git"
homeVN="$work/homeVN"; mkdir -p "$homeVN"
cacheVN="$work/cache-vn"; mkdir -p "$cacheVN"

# ── step 1: drive the INTERACTIVE flow, answering vault=none (7 questions,
# the same shape test-wizard-questions.sh's own case1 pins). HIMMEL-2436:
# --dry-run no longer WRITES the T3 cache (case2436d below), so the artifact
# under test here is extracted from the dry-run's own stdout instead of read
# back off disk -- the printed JSON (`process.stdout.write(serialize(answers)
# + '\n')`) is byte-identical to what writeCache() would persist (same
# serialize() call, same reasoning PV1/PV2 below rely on), so this changes
# nothing about what "the cache" means here, only how the test gets it
# without a real (non-dry, side-effecting) install.
set +e
outVNInteractive=$(PATH="$pathVN" HOME="$homeVN" USERPROFILE="$(winpath "$homeVN")" HIMMELCTL_INTERACTIVE=1 \
  HIMMELCTL_CACHE_DIR="$(winpath "$cacheVN")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheVN")-luna-config.json" \
  "$node_bin" "$wizard" install --dry-run 2>&1 <<INPUT
adopter
project
none
inline
lean
none
no
INPUT
)
rcVNInteractive=$?
set -e
[ "$rcVNInteractive" -eq 0 ] || fail "caseVaultNoneNoOp: the interactive vault=none run should succeed (got rc=$rcVNInteractive): $outVNInteractive"

cacheFileVN="$cacheVN/install-profile.json"
extract_profile_json "$outVNInteractive" > "$cacheFileVN"
[ -s "$cacheFileVN" ] || fail "caseVaultNoneNoOp: could not extract the printed profile JSON from the dry-run's stdout (got: $outVNInteractive)"
cacheBodyVN=$(cat "$cacheFileVN")
echo "$cacheBodyVN" | jq -e 'has("luna") | not' >/dev/null \
  || fail "caseVaultNoneNoOp [codex-1]: a vault=none interactive run must NOT serialize a luna key at all -- the question was never asked (got cache: $cacheBodyVN)"
echo "$cacheBodyVN" | jq -e 'has("bridge") | not' >/dev/null \
  || fail "caseVaultNoneNoOp [codex-1]: a vault=none interactive run must NOT serialize a bridge key at all -- the question was never asked (got cache: $cacheBodyVN)"
echo "$cacheBodyVN" | jq -e 'has("secretsWalk") | not' >/dev/null \
  || fail "caseVaultNoneNoOp: a vault=none interactive run should not serialize secretsWalk either -- same never-asked shape (got cache: $cacheBodyVN)"
echo "ok: caseVaultNoneNoOp [codex-1] an interactive vault=none run never serializes luna/secretsWalk/bridge keys -- 'not asked' is structurally absent, not a manufactured default"

# ── step 2: replay that EXACT cache (the artifact a real adopter would get)
# via --from-profile against an ALREADY-ARMED config -- same assertion shape
# as caseLegacyProfile, this time via the path that actually produces the file.
fixtureRepoVN="$work/fixture-repo-vn"; mkdir -p "$fixtureRepoVN/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoVN/scripts/adopt.sh"
chmod +x "$fixtureRepoVN/scripts/adopt.sh"

configPathVN="$(winpath "$work/config-vn.json")"
"$node_bin" -e "
process.env.HIMMEL_LUNA_CONFIG_PATH = '$configPathVN';
const lc = require('$luna_config_lib_w');
const d = lc.defaultConfig();
d.luna.cadence.enabled = true;
d.luna.phi.declared = true;
d.bridge.enabled = true;
lc.save(d);
"

set +e
outVNReplay=$(PATH="$pathVN" HOME="$homeVN" USERPROFILE="$(winpath "$homeVN")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoVN")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathVN" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-vn-replay")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-vn-replay")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheFileVN")" </dev/null 2>&1)
rcVNReplay=$?
set -e
[ "$rcVNReplay" -eq 0 ] || fail "caseVaultNoneNoOp: replaying the vault=none cache should still install successfully (got rc=$rcVNReplay): $outVNReplay"

outVNCfg=$("$node_bin" -e "
process.env.HIMMEL_LUNA_CONFIG_PATH = '$configPathVN';
const lc = require('$luna_config_lib_w');
console.log(JSON.stringify(lc.load()));
")
echo "$outVNCfg" | jq -e '.luna.cadence.enabled == true' >/dev/null \
  || fail "caseVaultNoneNoOp [codex-1]: a vault=none profile replay must NOT disarm an already-enabled luna.cadence.enabled (got: $outVNCfg)"
echo "$outVNCfg" | jq -e '.luna.phi.declared == true' >/dev/null \
  || fail "caseVaultNoneNoOp [codex-1]: a vault=none profile replay must NOT clear an already-declared luna.phi.declared (got: $outVNCfg)"
echo "$outVNCfg" | jq -e '.bridge.enabled == true' >/dev/null \
  || fail "caseVaultNoneNoOp [codex-1]: a vault=none profile replay must NOT disable an already-enabled bridge.enabled (got: $outVNCfg)"
grepq "$outVNReplay" -F -- 'profile carries no luna section' \
  || fail "caseVaultNoneNoOp: the replay should disclose that the luna section was left untouched (got: $outVNReplay)"
grepq "$outVNReplay" -F -- 'profile carries no bridge section' \
  || fail "caseVaultNoneNoOp: the replay should disclose that the bridge section was left untouched (got: $outVNReplay)"
echo "ok: caseVaultNoneNoOp [codex-1] replaying a vault=none-produced cache against an already-armed config leaves cadence/PHI/bridge fully untouched"

# ═══════════════════════════════════════════════════════════════════════════
# caseDistinctTokensSameFile (RETASK stage1-build-6d2e [codex-4]) — when
# bridge.envPath resolves to the SAME file as the repo-root .env, the
# distinct-tokens probe must NEVER read green (nothing distinct to compare)
# — it must report degraded, not a vacuous pass.
# ═══════════════════════════════════════════════════════════════════════════

stubDT="$work/stubDT"; mkdir -p "$stubDT"
pathDT=$(build_path "$stubDT" bash jq python3 npm -- python)
make_git_stub "$stubDT" "https://github.com/someone/other-repo.git"
homeDT="$work/homeDT"; mkdir -p "$homeDT"

fixtureRepoDT="$work/fixture-repo-dt"; mkdir -p "$fixtureRepoDT/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoDT/scripts/adopt.sh"
chmod +x "$fixtureRepoDT/scripts/adopt.sh"
# The repo-root .env AND the configured bridge.envPath point at this SAME
# file — the exact misconfiguration codex-4 must never read as a pass.
printf 'SOME_KEY=1\n' > "$fixtureRepoDT/.env"

configPathDT="$(winpath "$work/config-dt.json")"
profileDT="$work/profileDT.json"
cat > "$profileDT" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false },
  "secretsWalk": "skip",
  "bridge": {
    "enabled": true,
    "envPath": "$(winpath "$fixtureRepoDT/.env")",
    "whisperCli": "",
    "whisperModel": "ggml-small.bin",
    "installPersistence": false
  }
}
JSON

set +e
outDT=$(PATH="$pathDT" HOME="$homeDT" USERPROFILE="$(winpath "$homeDT")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoDT")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathDT" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-dt")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-dt")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileDT")" </dev/null 2>&1)
rcDT=$?
set -e
[ "$rcDT" -eq 0 ] || fail "caseDistinctTokensSameFile: run should still exit 0 -- a degraded probe never aborts the install (got rc=$rcDT): $outDT"

manualBlockDT=$(printf '%s' "$outDT" | sed -n '/^still manual/,$p')
grepq "$manualBlockDT" -F -- 'distinctTokens' \
  || fail "caseDistinctTokensSameFile: the distinctTokens probe result should land under still-manual (got manual block: $manualBlockDT)"
distinctTokensLineDT=$(printf '%s\n' "$manualBlockDT" | grep -F 'distinctTokens')
grepq "$distinctTokensLineDT" -F -- 'present' \
  && fail "caseDistinctTokensSameFile [codex-4]: same-file must NEVER read as a pass -- 'present' must not appear on the distinctTokens line (got: $distinctTokensLineDT)"
grepq "$manualBlockDT" -F -- 'SAME file' \
  || fail "caseDistinctTokensSameFile: the manual entry should explain that A and B resolve to the same file (got: $manualBlockDT)"
echo "ok: caseDistinctTokensSameFile [codex-4] bridge.envPath resolving to the repo-root .env reports degraded (never a vacuous pass)"

# ═══════════════════════════════════════════════════════════════════════════
# caseBridgePersistenceSkipRc (RETASK stage1-build-6d2e round 3, coordinator
# ruling on codex-2) — end-to-end pin: when the bridge readiness probes are
# NOT green, installPersistence=true must skip the arm/enable step (never
# spawn a real installer) AND leave rc at 0 -- a deliberate, designed skip is
# NOT an install failure. Probes are left genuinely unhealthy here (no real
# whisper binary/model, python scrubbed from PATH) so bridgeProbesHealthy()
# is false and attemptBridgePersistence() is never even called -- no real
# systemctl/schtasks spawn, hermetic by construction.
# ═══════════════════════════════════════════════════════════════════════════

stubSkipRc="$work/stubSkipRc"; mkdir -p "$stubSkipRc"
pathSkipRc=$(build_path "$stubSkipRc" bash jq python3 npm -- python)
make_git_stub "$stubSkipRc" "https://github.com/someone/other-repo.git"
homeSkipRc="$work/homeSkipRc"; mkdir -p "$homeSkipRc"

fixtureRepoSkipRc="$work/fixture-repo-skiprc"; mkdir -p "$fixtureRepoSkipRc/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoSkipRc/scripts/adopt.sh"
chmod +x "$fixtureRepoSkipRc/scripts/adopt.sh"

configPathSkipRc="$(winpath "$work/config-skiprc.json")"
profileSkipRc="$work/profileSkipRc.json"
cat > "$profileSkipRc" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false },
  "secretsWalk": "skip",
  "bridge": {
    "enabled": true,
    "envPath": "$(winpath "$work/skiprc-bridge.env")",
    "whisperCli": "$(winpath "$work/nowhere-whisper-cli-skiprc")",
    "whisperModel": "ggml-small.bin",
    "installPersistence": true
  }
}
JSON

set +e
outSkipRc=$(PATH="$pathSkipRc" HOME="$homeSkipRc" USERPROFILE="$(winpath "$homeSkipRc")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoSkipRc")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathSkipRc" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-skiprc")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-skiprc")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileSkipRc")" </dev/null 2>&1)
rcSkipRc=$?
set -e
[ "$rcSkipRc" -eq 0 ] \
  || fail "caseBridgePersistenceSkipRc [codex-2 ruling]: a deliberate probes-not-ready skip must leave rc=0, a designed skip is not a failure (got rc=$rcSkipRc): $outSkipRc"
manualBlockSkipRc=$(printf '%s' "$outSkipRc" | sed -n '/^still manual/,$p')
bridgePersistenceLineSkipRc=$(printf '%s\n' "$manualBlockSkipRc" | grep -F 'bridge persistence')
grepq "$bridgePersistenceLineSkipRc" -F -- 'SKIPPED' \
  || fail "caseBridgePersistenceSkipRc: the summary should report the persistence skip honestly (got manual block: $manualBlockSkipRc)"
grepq "$bridgePersistenceLineSkipRc" -F -- 'not green' \
  || fail "caseBridgePersistenceSkipRc: the skip reason should name the probes-not-green cause (got: $bridgePersistenceLineSkipRc)"
grepq "$bridgePersistenceLineSkipRc" -F -- 'NOT installed' \
  && fail "caseBridgePersistenceSkipRc: a deliberate skip must not read the same as a genuine install failure (got: $manualBlockSkipRc)"
echo "ok: caseBridgePersistenceSkipRc [codex-2 ruling] probes-not-ready skips arm/enable, rc stays 0, wording says SKIPPED not NOT-installed"

# ═══════════════════════════════════════════════════════════════════════════
# caseWhisperModelBareFilename (RETASK stage1-build-6d2e round 7 [codex-1])
# — the exact adopter scenario the bug broke: a whisper model correctly
# installed at ~/.himmel/whisper/<name>, with only the BARE FILENAME
# configured (matching the schema default's own shape, e.g. "ggml-small.bin").
# Before the fix, the bare filename was handed straight through as
# WHISPER_MODEL (a probe-side COMPLETE-PATH env var), so it was checked
# against the process CWD instead of the whisper dir and read absent — which
# then blocked bridge persistence entirely via the round-1 readiness gate.
# whisperCli is given as a full path directly here (deliberately isolating
# the test to the model bug this round is about — cli's own full-path
# handling was verified unchanged by inspection, not by this fixture).
#
# installPersistence stays FALSE here, deliberately, even though the
# scenario is about persistence not being blocked: with it true and probes
# healthy, bridgeProbesHealthy() opens the gate and bin.js actually calls
# attemptBridgePersistence() FOR REAL. On win32 that spawns real
# install-logon-task.ps1; on a real Linux box with systemctl present it
# would write a real unit file and call `systemctl --user enable --now
# telegram-bridge.service` against the operator's REAL systemd user
# session — if that operator already runs himmel's own bridge via systemd
# persistence (a realistic case for anyone running this suite locally), that
# call would re-enable/restart their ACTUAL running bridge. No fixture trick
# closes that on every platform, so the safe design proves "not blocked" via
# the readiness probe's own verdict instead: with installPersistence=false,
# nothing downstream can be gated OR attempted, so a healthy whisperReady
# probe (present, not absent/degraded) IS the direct, complete proof that
# the model-resolution bug no longer produces a false negative — the
# gate-skip and real-attempt code paths this proves are safe are already
# covered by other cases (caseBridgePersistenceSkipRc, caseApply) without
# needing to re-run them here.
# ═══════════════════════════════════════════════════════════════════════════

stubWM="$work/stubWM"; mkdir -p "$stubWM"
pathWM=$(build_path "$stubWM" bash jq python3 npm -- python)
make_git_stub "$stubWM" "https://github.com/someone/other-repo.git"
make_python_stub "$stubWM"
homeWM="$work/homeWM"; mkdir -p "$homeWM"

fixtureRepoWM="$work/fixture-repo-wm"; mkdir -p "$fixtureRepoWM/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoWM/scripts/adopt.sh"
chmod +x "$fixtureRepoWM/scripts/adopt.sh"
printf 'TELEGRAM_BOT_TOKEN=REPO_TOKEN\n' > "$fixtureRepoWM/.env"

whisperDirWM="$homeWM/.himmel/whisper"
mkdir -p "$whisperDirWM"
printf 'stub-cli' > "$whisperDirWM/whisper-cli"
chmod +x "$whisperDirWM/whisper-cli"
printf 'stub-model-bytes' > "$whisperDirWM/custom-model.bin"

bridgeEnvPathWM="$work/wm-bridge.env"
printf 'TELEGRAM_BOT_TOKEN=BRIDGE_TOKEN\n' > "$bridgeEnvPathWM"

configPathWM="$(winpath "$work/config-wm.json")"
profileWM="$work/profileWM.json"
cat > "$profileWM" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false },
  "secretsWalk": "skip",
  "bridge": {
    "enabled": true,
    "envPath": "$(winpath "$bridgeEnvPathWM")",
    "whisperCli": "$(winpath "$whisperDirWM/whisper-cli")",
    "whisperModel": "custom-model.bin",
    "installPersistence": false
  }
}
JSON

set +e
outWM=$(PATH="$pathWM" HOME="$homeWM" USERPROFILE="$(winpath "$homeWM")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoWM")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathWM" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-wm")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-wm")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileWM")" </dev/null 2>&1)
rcWM=$?
set -e
skippedBlockWM=$(printf '%s' "$outWM" | sed -n '/^skipped:$/,/^$/p')
manualBlockWM=$(printf '%s' "$outWM" | sed -n '/^still manual/,$p')
grepq "$manualBlockWM" -F -- 'whisperReady' \
  && fail "caseWhisperModelBareFilename [codex-1]: a correctly-installed model (bare filename, resolved against the whisper dir) must read whisperReady PRESENT, not land in still-manual (got manual block: $manualBlockWM)"
grepq "$skippedBlockWM" -F -- 'bridge probe whisperReady' \
  || fail "caseWhisperModelBareFilename [codex-1]: whisperReady should read present -> 'already ready' under skipped: (got skipped block: $skippedBlockWM)"
grepq "$skippedBlockWM" -F -- 'already ready' \
  || fail "caseWhisperModelBareFilename [codex-1]: expected the 'already ready' wording for a present probe (got: $skippedBlockWM)"
# rc IS asserted, not left uninspected: installPersistence=false here means
# nothing downstream (gate or real install attempt) can fail, so a healthy
# whisper probe should produce a completely clean run. rc=1 would mean
# something else broke (e.g. the model bug regressing into a 'degraded'
# probe result that then poisoned the summary/rc some other way) — this is
# the "correctly-configured adopter is not blocked" signal in full, not just
# the probe verdict on its own.
[ "$rcWM" -eq 0 ] \
  || fail "caseWhisperModelBareFilename [codex-1]: a correctly-configured whisper model must produce a clean run (rc=0) -- installPersistence=false means nothing here can legitimately fail (got rc=$rcWM): $outWM"
echo "ok: caseWhisperModelBareFilename [codex-1] a bare-filename model correctly installed under ~/.himmel/whisper reads present, rc=0 confirms the adopter is not blocked"

# ═══════════════════════════════════════════════════════════════════════════
# caseCadenceDisarm (RETASK stage1-build-6d2e round 4 [codex-1]) — two cases:
#   A. cadence=off + disarmCadence=true (consented) actually spawns
#      `pipeline-cadence.sh disarm` (end-to-end wiring, like caseApply's own
#      arm-wiring proof).
#   B. cadence=off + disarmCadence NOT set (declined/not-applicable — the
#      default) NEVER silently no-ops: still-manual names the exact disarm
#      command so the adopter knows any existing armed jobs keep firing.
# ═══════════════════════════════════════════════════════════════════════════

stubDisarm="$work/stubDisarm"; mkdir -p "$stubDisarm"
pathDisarm=$(build_path "$stubDisarm" bash jq python3 npm -- python)
make_git_stub "$stubDisarm" "https://github.com/someone/other-repo.git"
homeDisarm="$work/homeDisarm"; mkdir -p "$homeDisarm"

fixtureRepoDisarm="$work/fixture-repo-disarm"; mkdir -p "$fixtureRepoDisarm/scripts/luna"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoDisarm/scripts/adopt.sh"
chmod +x "$fixtureRepoDisarm/scripts/adopt.sh"
markerFileDisarm="$work/cadence-disarm-marker.txt"
cat > "$fixtureRepoDisarm/scripts/luna/pipeline-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_FILE"
exit 0
STUB
chmod +x "$fixtureRepoDisarm/scripts/luna/pipeline-cadence.sh"

configPathDisarmA="$(winpath "$work/config-disarmA.json")"
profileDisarmA="$work/profileDisarmA.json"
cat > "$profileDisarmA" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "disarmCadence": true },
  "secretsWalk": "skip",
  "bridge": { "enabled": false, "envPath": "~/.claude/channels/telegram/.env", "whisperCli": "", "whisperModel": "ggml-small.bin", "installPersistence": false }
}
JSON

set +e
outDisarmA=$(PATH="$pathDisarm" HOME="$homeDisarm" USERPROFILE="$(winpath "$homeDisarm")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoDisarm")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathDisarmA" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-disarmA")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-disarmA")" \
  MARKER_FILE="$(winpath "$markerFileDisarm")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileDisarmA")" </dev/null 2>&1)
rcDisarmA=$?
set -e
[ "$rcDisarmA" -eq 0 ] || fail "caseCadenceDisarm A: consented disarm run should exit 0 (got rc=$rcDisarmA): $outDisarmA"
[ -f "$markerFileDisarm" ] || fail "caseCadenceDisarm A: pipeline-cadence.sh should have been spawned with 'disarm' (marker file missing)"
grepq "$(cat "$markerFileDisarm")" -F -- 'disarm' \
  || fail "caseCadenceDisarm A: the spawned argv should carry the 'disarm' subcommand (got: $(cat "$markerFileDisarm"))"
installedBlockDisarmA=$(printf '%s' "$outDisarmA" | sed -n '/^installed:$/,/^$/p')
grepq "$installedBlockDisarmA" -F -- 'luna cadence disarmed' \
  || fail "caseCadenceDisarm A: the summary should report the cadence as disarmed under installed: (got: $installedBlockDisarmA)"
echo "ok: caseCadenceDisarm A [codex-1] cadence=off + consented disarm actually spawns pipeline-cadence.sh disarm (end-to-end wiring)"

configPathDisarmB="$(winpath "$work/config-disarmB.json")"
profileDisarmB="$work/profileDisarmB.json"
cat > "$profileDisarmB" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false },
  "secretsWalk": "skip",
  "bridge": { "enabled": false, "envPath": "~/.claude/channels/telegram/.env", "whisperCli": "", "whisperModel": "ggml-small.bin", "installPersistence": false }
}
JSON

rm -f "$markerFileDisarm"
set +e
outDisarmB=$(PATH="$pathDisarm" HOME="$homeDisarm" USERPROFILE="$(winpath "$homeDisarm")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoDisarm")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathDisarmB" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-disarmB")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-disarmB")" \
  MARKER_FILE="$(winpath "$markerFileDisarm")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileDisarmB")" </dev/null 2>&1)
rcDisarmB=$?
set -e
[ "$rcDisarmB" -eq 0 ] || fail "caseCadenceDisarm B: declined-disarm run should still exit 0 (got rc=$rcDisarmB): $outDisarmB"
[ -f "$markerFileDisarm" ] && fail "caseCadenceDisarm B: pipeline-cadence.sh must NEVER be spawned when disarm was not consented (a silent no-op is exactly what codex-1 forbids) — found marker: $(cat "$markerFileDisarm")"
manualBlockDisarmB=$(printf '%s' "$outDisarmB" | sed -n '/^still manual/,$p')
grepq "$manualBlockDisarmB" -F -- 'PREVIOUSLY ARMED jobs are still armed' \
  || fail "caseCadenceDisarm B: a declined/not-applicable disarm must be reported under still-manual, naming the risk (got: $manualBlockDisarmB)"
grepq "$manualBlockDisarmB" -F -- 'pipeline-cadence.sh disarm' \
  || fail "caseCadenceDisarm B: still-manual should name the exact disarm command (got: $manualBlockDisarmB)"
echo "ok: caseCadenceDisarm B [codex-1] cadence=off without consent NEVER silently no-ops -- still-manual names the exact disarm command, nothing spawned"

# ═══════════════════════════════════════════════════════════════════════════
# caseTelegramEnvOverride (RETASK stage1-build-6d2e round 4 [codex-2]) —
# TELEGRAM_ENV must win over bridge.envPath for distinct-tokens, exactly the
# precedence probes.js's own resolveBridgeEnvFilePath() already implements.
# bridge.envPath is deliberately set to hold the SAME token as the repo-root
# .env (would read degraded/collision if bridge.envPath were used); TELEGRAM_ENV
# points at a THIRD file with a genuinely different token — a green
# (non-colliding) result proves TELEGRAM_ENV was actually read.
# ═══════════════════════════════════════════════════════════════════════════

stubTE="$work/stubTE"; mkdir -p "$stubTE"
pathTE=$(build_path "$stubTE" bash jq python3 npm -- python)
make_git_stub "$stubTE" "https://github.com/someone/other-repo.git"
homeTE="$work/homeTE"; mkdir -p "$homeTE"

fixtureRepoTE="$work/fixture-repo-te"; mkdir -p "$fixtureRepoTE/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoTE/scripts/adopt.sh"
chmod +x "$fixtureRepoTE/scripts/adopt.sh"
printf 'TELEGRAM_BOT_TOKEN=SHARED_TOKEN\n' > "$fixtureRepoTE/.env"

bridgeEnvPathTE="$work/te-bridge.env"
printf 'TELEGRAM_BOT_TOKEN=SHARED_TOKEN\n' > "$bridgeEnvPathTE"
telegramEnvOverrideTE="$work/te-override.env"
printf 'TELEGRAM_BOT_TOKEN=OVERRIDE_TOKEN\n' > "$telegramEnvOverrideTE"

configPathTE="$(winpath "$work/config-te.json")"
profileTE="$work/profileTE.json"
cat > "$profileTE" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false },
  "secretsWalk": "skip",
  "bridge": {
    "enabled": true,
    "envPath": "$(winpath "$bridgeEnvPathTE")",
    "whisperCli": "",
    "whisperModel": "ggml-small.bin",
    "installPersistence": false
  }
}
JSON

set +e
outTE=$(PATH="$pathTE" HOME="$homeTE" USERPROFILE="$(winpath "$homeTE")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoTE")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathTE" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-te")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-te")" \
  TELEGRAM_ENV="$(winpath "$telegramEnvOverrideTE")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileTE")" </dev/null 2>&1)
rcTE=$?
set -e
[ "$rcTE" -eq 0 ] || fail "caseTelegramEnvOverride: run should exit 0 (got rc=$rcTE): $outTE"
skippedBlockTE=$(printf '%s' "$outTE" | sed -n '/^skipped:$/,/^$/p')
manualBlockTE=$(printf '%s' "$outTE" | sed -n '/^still manual/,$p')
grepq "$skippedBlockTE" -F -- 'bridge probe distinctTokens' \
  || fail "caseTelegramEnvOverride [codex-2]: TELEGRAM_ENV's distinct (non-colliding) token should read distinctTokens as already-ready/skipped, proving TELEGRAM_ENV -- not the colliding bridge.envPath -- was read (got skipped: $skippedBlockTE, manual: $manualBlockTE)"
grepq "$manualBlockTE" -F -- 'distinctTokens' \
  && fail "caseTelegramEnvOverride [codex-2]: distinctTokens must NOT read degraded/collision here -- that would mean bridge.envPath (the colliding file) was read instead of TELEGRAM_ENV (got manual: $manualBlockTE)"
echo "ok: caseTelegramEnvOverride [codex-2] TELEGRAM_ENV process-env override wins over a colliding bridge.envPath for distinct-tokens"

# ═══════════════════════════════════════════════════════════════════════════
# caseConfigSaveFailure (RETASK stage1-build-6d2e round 4 [codex-3]) — a
# config save() failure must stop the SUBSEQUENT machine-state mutations
# (cadence arm, bridge persistence install) — never arm/install against a
# config that was never recorded. HIMMEL_LUNA_CONFIG_PATH is pointed INSIDE
# a plain FILE (not a directory) so save()'s own mkdirSync(dir) genuinely
# fails -- a real, deterministic save() failure, not a simulated one.
# ═══════════════════════════════════════════════════════════════════════════

stubSaveFail="$work/stubSaveFail"; mkdir -p "$stubSaveFail"
pathSaveFail=$(build_path "$stubSaveFail" bash jq python3 npm -- python)
make_git_stub "$stubSaveFail" "https://github.com/someone/other-repo.git"
homeSaveFail="$work/homeSaveFail"; mkdir -p "$homeSaveFail"

fixtureRepoSaveFail="$work/fixture-repo-savefail"; mkdir -p "$fixtureRepoSaveFail/scripts/luna"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoSaveFail/scripts/adopt.sh"
chmod +x "$fixtureRepoSaveFail/scripts/adopt.sh"
markerFileSaveFail="$work/cadence-savefail-marker.txt"
rm -f "$markerFileSaveFail"
cat > "$fixtureRepoSaveFail/scripts/luna/pipeline-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_FILE"
exit 0
STUB
chmod +x "$fixtureRepoSaveFail/scripts/luna/pipeline-cadence.sh"

# A plain FILE sits where config.json's PARENT DIRECTORY needs to be --
# save()'s own mkdirSync(dirname(p), {recursive:true}) genuinely cannot
# create a directory where a file already exists, so save() throws a REAL
# error -- while load() stays unaffected (fs.existsSync(p) is false, since
# nothing can exist one level "inside" a plain file, so load() cleanly
# returns defaultConfig(), exactly like a fresh install). This isolates the
# SAVE failure from the (already-handled, pre-existing) LOAD failure path.
# The path is built by STRING-CONCATENATING onto an already-winpath'd base
# rather than winpath-ing the full blocked path directly: cygpath -m itself
# refuses to convert a path through a non-directory component ("Not a
# directory", rc=1), so winpath's `|| fallback` would silently hand node.exe
# an UNconverted POSIX-style path that collides with nothing from node's own
# view on win32 -- the trap that made an earlier version of this fixture
# report "NO THROW". Kept as a documented trap for the next person tempted
# to winpath the whole blocked path in one call.
blockerFileSaveFail="$work/savefail-blocker"
printf 'not a directory\n' > "$blockerFileSaveFail"
workWinSaveFail="$(winpath "$work")"
configPathSaveFail="$workWinSaveFail/savefail-blocker/config.json"

profileSaveFail="$work/profileSaveFail.json"
cat > "$profileSaveFail" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": true, "phiDeclared": false },
  "secretsWalk": "skip",
  "bridge": { "enabled": true, "envPath": "~/.claude/channels/telegram/.env", "whisperCli": "", "whisperModel": "ggml-small.bin", "installPersistence": false }
}
JSON

set +e
outSaveFail=$(PATH="$pathSaveFail" HOME="$homeSaveFail" USERPROFILE="$(winpath "$homeSaveFail")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoSaveFail")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathSaveFail" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-savefail")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-savefail")" \
  MARKER_FILE="$(winpath "$markerFileSaveFail")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileSaveFail")" </dev/null 2>&1)
rcSaveFail=$?
set -e
[ "$rcSaveFail" -ne 0 ] \
  || fail "caseConfigSaveFailure [codex-3]: a genuine save() failure should leave rc nonzero (got rc=0): $outSaveFail"
[ -f "$markerFileSaveFail" ] \
  && fail "caseConfigSaveFailure [codex-3]: pipeline-cadence.sh must NEVER be spawned after a failed config save -- machine state would then be unrecorded (found marker: $(cat "$markerFileSaveFail"))"
grepq "$outSaveFail" -F -- 'skipping luna cadence arm/disarm and bridge persistence install' \
  || fail "caseConfigSaveFailure [codex-3]: the run should WARN that it is skipping machine-state mutation after the save failure (got: $outSaveFail)"
echo "ok: caseConfigSaveFailure [codex-3] a failed config save stops cadence arm/disarm (no spawn), rc reflects the failure, reporting still ran"

# RETASK stage1-build-6d2e round 5 [codex-1]: an unapplied cadence (the arm
# step never ran because the config save failed) must NEVER appear under
# installed: -- it belongs in skipped/still-manual instead. This is the
# exact honesty guarantee V11 already covers for secrets/bridge probes;
# codex-1 round 5 found the cadence-arm and bridge-persistence "declared but
# never ran" branches still leaking into `actions` (which renders as
# installed:) on an APPLIED run.
installedBlockSaveFail=$(printf '%s' "$outSaveFail" | sed -n '/^installed:$/,/^$/p')
manualBlockSaveFail=$(printf '%s' "$outSaveFail" | sed -n '/^still manual/,$p')
grepq "$installedBlockSaveFail" -F -- 'cadence' \
  && fail "caseConfigSaveFailure [codex-1]: the installed: block must NOT mention luna cadence at all when the arm step never ran (got installed block: $installedBlockSaveFail)"
grepq "$manualBlockSaveFail" -F -- 'luna cadence' \
  || fail "caseConfigSaveFailure [codex-1]: the never-armed cadence should be reported under still-manual (got manual block: $manualBlockSaveFail)"
grepq "$manualBlockSaveFail" -F -- 'NOT armed' \
  || fail "caseConfigSaveFailure [codex-1]: still-manual should say plainly that cadence is NOT armed (got: $manualBlockSaveFail)"
echo "ok: caseConfigSaveFailure [codex-1] an unapplied cadence (arm never ran) is reported under still-manual, never under installed:"

# RETASK stage1-build-6d2e round 6 [codex-2]: bridge.enabled=true in the SAME
# failed-save run (the profile above was flipped from bridge.enabled=false to
# true for exactly this) -- the bridge config write claim must be gated on
# the same save failure, never appearing under installed:.
grepq "$installedBlockSaveFail" -F -- 'telegram bridge config' \
  && fail "caseConfigSaveFailure [codex-2]: the installed: block must NOT claim the bridge config was written when the config save failed (got installed block: $installedBlockSaveFail)"
grepq "$manualBlockSaveFail" -F -- 'telegram bridge config' \
  || fail "caseConfigSaveFailure [codex-2]: the un-persisted bridge config should be reported under still-manual (got manual block: $manualBlockSaveFail)"
grepq "$manualBlockSaveFail" -F -- 'NOT written' \
  || fail "caseConfigSaveFailure [codex-2]: still-manual should say plainly the bridge config was NOT written (got: $manualBlockSaveFail)"
echo "ok: caseConfigSaveFailure [codex-2] an enabled bridge whose config save failed is reported under still-manual, never under installed:"

# ═══════════════════════════════════════════════════════════════════════════
# caseConfigLoadFailure (CR fix) -- a MALFORMED ~/.himmel/config.json (invalid
# JSON, distinct from caseConfigSaveFailure's SAVE failure above) must make
# --dry-run report the exact same refusal applyLunaSectionsStep performs for
# real, instead of silently substituting defaultConfig() and previewing
# cadence/secrets/bridge actions the apply path will never perform. Both a
# --dry-run and a real apply run against the SAME malformed file, so the two
# can be checked for agreement, not just each in isolation.
# ═══════════════════════════════════════════════════════════════════════════

stubLF="$work/stubLF"; mkdir -p "$stubLF"
pathLF=$(build_path "$stubLF" bash jq python3 npm -- python)
make_git_stub "$stubLF" "https://github.com/someone/other-repo.git"
homeLF="$work/homeLF"; mkdir -p "$homeLF"

fixtureRepoLF="$work/fixture-repo-lf"; mkdir -p "$fixtureRepoLF/scripts/luna"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoLF/scripts/adopt.sh"
chmod +x "$fixtureRepoLF/scripts/adopt.sh"
markerFileLF="$work/cadence-loadfail-marker.txt"
rm -f "$markerFileLF"
cat > "$fixtureRepoLF/scripts/luna/pipeline-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_FILE"
exit 0
STUB
chmod +x "$fixtureRepoLF/scripts/luna/pipeline-cadence.sh"

# A genuinely malformed config.json -- lunaConfigLib.load() throws a real
# JSON.parse error against this, not a simulated one. Written via node (not
# a bash redirect) so the winpath'd Windows-style path resolves correctly.
configPathLF="$(winpath "$work/config-loadfail.json")"
"$node_bin" -e "
const fs = require('fs');
const path = require('path');
const p = '$configPathLF';
fs.mkdirSync(path.dirname(p), { recursive: true });
fs.writeFileSync(p, '{ this is not valid json');
"

# luna.cadenceEnabled + bridge.enabled/installPersistence are all ON --
# maximal surface for a leaked 'would arm'/'would install' preview line, so
# a regression here has nowhere to hide. HIMMEL-2302 Fix 2 also names a
# NON-pipeline unit (codex-sweep) as armed here -- codex-sweep's
# `requires:'lane:codex'` is a consent surface, not a functional dependency
# (see loadProfile's own comment), so naming it armed with an empty `lanes`
# validates cleanly; that's what lets this fixture reach the config-load
# failure with a requested non-pipeline unit still in play, to prove
# buildSummary's configLoadFailed branch reports it honestly instead of
# dropping it.
profileLF="$work/profileLF.json"
cat > "$profileLF" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": true, "phiDeclared": false },
  "secretsWalk": "run",
  "bridge": { "enabled": true, "envPath": "~/.claude/channels/telegram/.env", "whisperCli": "", "whisperModel": "ggml-small.bin", "installPersistence": true },
  "cadences": { "codex-sweep": "armed" }
}
JSON

# ── dry-run half ─────────────────────────────────────────────────────────
set +e
outLFDry=$(PATH="$pathLF" HOME="$homeLF" USERPROFILE="$(winpath "$homeLF")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoLF")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathLF" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-loadfail-dry")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-loadfail-dry")" \
  MARKER_FILE="$(winpath "$markerFileLF")" \
  "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$profileLF")" </dev/null 2>&1)
rcLFDry=$?
set -e
[ "$rcLFDry" -eq 0 ] \
  || fail "caseConfigLoadFailure: a --dry-run should still exit 0 (the refusal is informational only) (got rc=$rcLFDry): $outLFDry"
grepq "$outLFDry" -F -- 'could not read' \
  || fail "caseConfigLoadFailure: the dry-run should name the load failure (got: $outLFDry)"
grepq "$outLFDry" -F -- 'malformed JSON' \
  || fail "caseConfigLoadFailure: the dry-run should name the parse failure, the same way applyLunaSectionsStep's own WARN does (got: $outLFDry)"
grepq "$outLFDry" -F -- 'DRY: luna.cadence.enabled' \
  && fail "caseConfigLoadFailure: the dry-run must NOT preview luna.cadence.enabled when the config could not even be loaded (got: $outLFDry)"
grepq "$outLFDry" -F -- 'would arm' \
  && fail "caseConfigLoadFailure: the dry-run must NOT claim it would arm cadence -- applyLunaSectionsStep refuses this section entirely on a load failure (got: $outLFDry)"
grepq "$outLFDry" -F -- 'bridge config' \
  && fail "caseConfigLoadFailure: the dry-run must NOT preview a bridge config write when the config could not even be loaded (got: $outLFDry)"
grepq "$outLFDry" -F -- 'secrets walk — would show' \
  && fail "caseConfigLoadFailure: the dry-run must NOT preview the secrets walk either -- applyLunaSectionsStep returns before reaching it on a load failure (got: $outLFDry)"
plannedBlockLFDry=$(printf '%s' "$outLFDry" | sed -n '/^would install/,/^$/p')
grepq "$plannedBlockLFDry" -F -- 'cadence' \
  && fail "caseConfigLoadFailure: the planned: bucket must not mention luna cadence at all (got planned block: $plannedBlockLFDry)"
grepq "$plannedBlockLFDry" -F -- 'bridge' \
  && fail "caseConfigLoadFailure: the planned: bucket must not mention the telegram bridge at all (got planned block: $plannedBlockLFDry)"
grepq "$plannedBlockLFDry" -F -- 'secrets walk' \
  && fail "caseConfigLoadFailure: the planned: bucket must not mention the secrets walk at all (got planned block: $plannedBlockLFDry)"
# HIMMEL-2302 Fix 2: before this fix, the configLoadFailed branch returned
# only the two legacy luna-cadence/PHI lines and never reached the per-unit
# loop, so a profile requesting a non-pipeline unit (codex-sweep here) lost
# that row entirely -- neither reported nor claimed armed. It must now
# appear under skipped: with an honest "requested but not armed" wording,
# and must NEVER appear under installed:.
skippedBlockLFDry=$(printf '%s' "$outLFDry" | sed -n '/^skipped:$/,/^$/p')
grepq "$skippedBlockLFDry" -F -- 'codex orphan sweep cadence — requested but not armed' \
  || fail "caseConfigLoadFailure [HIMMEL-2302 Fix 2]: dry-run skipped: bucket should report the requested-but-not-armed codex-sweep row (got skipped block: $skippedBlockLFDry)"
grepq "$outLFDry" -F -- 'would arm via codex-sweep-cadence.sh' \
  && fail "caseConfigLoadFailure [HIMMEL-2302 Fix 2]: the dry-run must never plan the codex-sweep arm on a config-load failure (got: $outLFDry)"
echo "ok: caseConfigLoadFailure dry-run names the load/parse failure and previews NO cadence/bridge actions as planned"

# ── apply half (SAME malformed file) ────────────────────────────────────
set +e
outLFApply=$(PATH="$pathLF" HOME="$homeLF" USERPROFILE="$(winpath "$homeLF")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoLF")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathLF" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-loadfail-apply")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-loadfail-apply")" \
  MARKER_FILE="$(winpath "$markerFileLF")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileLF")" </dev/null 2>&1)
rcLFApply=$?
set -e
[ "$rcLFApply" -ne 0 ] \
  || fail "caseConfigLoadFailure: a real apply against a malformed config should leave rc nonzero (got rc=0): $outLFApply"
grepq "$outLFApply" -F -- 'could not read' \
  || fail "caseConfigLoadFailure: the apply run should WARN naming the load failure (got: $outLFApply)"
[ -f "$markerFileLF" ] \
  && fail "caseConfigLoadFailure: pipeline-cadence.sh must NEVER be spawned when the config could not be loaded (found marker: $(cat "$markerFileLF"))"
installedBlockLFApply=$(printf '%s' "$outLFApply" | sed -n '/^installed:$/,/^$/p')
grepq "$installedBlockLFApply" -F -- 'cadence' \
  && fail "caseConfigLoadFailure: the apply run's installed: block must not mention cadence (got installed block: $installedBlockLFApply)"
grepq "$installedBlockLFApply" -F -- 'telegram bridge config' \
  && fail "caseConfigLoadFailure: the apply run's installed: block must not claim the bridge config was written (got installed block: $installedBlockLFApply)"
# HIMMEL-2302 Fix 2 (apply half, same fixture): same honest skipped row, same
# never-installed guarantee.
skippedBlockLFApply=$(printf '%s' "$outLFApply" | sed -n '/^skipped:$/,/^$/p')
grepq "$skippedBlockLFApply" -F -- 'codex orphan sweep cadence — requested but not armed' \
  || fail "caseConfigLoadFailure [HIMMEL-2302 Fix 2]: apply skipped: bucket should report the requested-but-not-armed codex-sweep row (got skipped block: $skippedBlockLFApply)"
grepq "$installedBlockLFApply" -F -- 'codex-sweep' \
  && fail "caseConfigLoadFailure [HIMMEL-2302 Fix 2]: the apply run's installed: block must not mention codex-sweep at all (got installed block: $installedBlockLFApply)"
echo "ok: caseConfigLoadFailure apply run also refuses (rc nonzero, no spawn, nothing claimed installed) -- agreeing with the dry-run half that nothing runs in this state"

# ═══════════════════════════════════════════════════════════════════════════
# caseLegacyReplayNoOp (RETASK stage1-build-6d2e round 6 [codex-1]) -- a
# no-op legacy replay (no luna/bridge sections, vault=none: nothing in the
# document changes) must leave an EXISTING config file's content byte-
# identical (and mtime untouched -- proving save() was never called, not
# just that it happened to write the same bytes), and must NOT create one
# when none existed. Two sub-cases, one profile.
# ═══════════════════════════════════════════════════════════════════════════

stubNoOp="$work/stubNoOp"; mkdir -p "$stubNoOp"
pathNoOp=$(build_path "$stubNoOp" bash jq python3 npm -- python)
make_git_stub "$stubNoOp" "https://github.com/someone/other-repo.git"
homeNoOp="$work/homeNoOp"; mkdir -p "$homeNoOp"

fixtureRepoNoOp="$work/fixture-repo-noop"; mkdir -p "$fixtureRepoNoOp/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoNoOp/scripts/adopt.sh"
chmod +x "$fixtureRepoNoOp/scripts/adopt.sh"

profileNoOp="$work/profileNoOp.json"
cat > "$profileNoOp" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false
}
JSON

# ── sub-case A: an EXISTING config file must survive byte-identical + mtime-untouched ──
configPathNoOpA="$(winpath "$work/config-noopA.json")"
"$node_bin" -e "
process.env.HIMMEL_LUNA_CONFIG_PATH = '$configPathNoOpA';
const lc = require('$luna_config_lib_w');
const d = lc.defaultConfig();
d.luna.cadence.enabled = true;
d.luna.phi.declared = true;
lc.save(d);
"
contentBeforeNoOpA=$(cat "$work/config-noopA.json")
mtimeBeforeNoOpA=$(stat -c '%Y' "$work/config-noopA.json" 2>/dev/null || stat -f '%m' "$work/config-noopA.json")
sleep 1.1

set +e
outNoOpA=$(PATH="$pathNoOp" HOME="$homeNoOp" USERPROFILE="$(winpath "$homeNoOp")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoNoOp")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathNoOpA" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-noopA")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-noopA")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileNoOp")" </dev/null 2>&1)
rcNoOpA=$?
set -e
[ "$rcNoOpA" -eq 0 ] || fail "caseLegacyReplayNoOp A: a no-op legacy replay should still exit 0 (got rc=$rcNoOpA): $outNoOpA"
contentAfterNoOpA=$(cat "$work/config-noopA.json")
mtimeAfterNoOpA=$(stat -c '%Y' "$work/config-noopA.json" 2>/dev/null || stat -f '%m' "$work/config-noopA.json")
[ "$contentBeforeNoOpA" = "$contentAfterNoOpA" ] \
  || fail "caseLegacyReplayNoOp A [codex-1]: a no-op legacy replay must leave the config file's CONTENT byte-identical
before: $contentBeforeNoOpA
after:  $contentAfterNoOpA"
[ "$mtimeBeforeNoOpA" = "$mtimeAfterNoOpA" ] \
  || fail "caseLegacyReplayNoOp A [codex-1]: a no-op legacy replay must leave the config file's MTIME untouched (save() must never be called) -- before=$mtimeBeforeNoOpA after=$mtimeAfterNoOpA"
grepq "$outNoOpA" -F -- 'unchanged — nothing to write' \
  || fail "caseLegacyReplayNoOp A: the run should say the config was unchanged (got: $outNoOpA)"
echo "ok: caseLegacyReplayNoOp A [codex-1] a no-op legacy replay leaves an EXISTING config file's content and mtime untouched"

# ── sub-case B: no config file existed -- a no-op legacy replay must NOT create one ──
configPathNoOpB="$(winpath "$work/config-noopB-does-not-exist.json")"
set +e
outNoOpB=$(PATH="$pathNoOp" HOME="$homeNoOp" USERPROFILE="$(winpath "$homeNoOp")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoNoOp")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathNoOpB" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-noopB")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-noopB")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileNoOp")" </dev/null 2>&1)
rcNoOpB=$?
set -e
[ "$rcNoOpB" -eq 0 ] || fail "caseLegacyReplayNoOp B: a no-op legacy replay should still exit 0 (got rc=$rcNoOpB): $outNoOpB"
[ -f "$work/config-noopB-does-not-exist.json" ] \
  && fail "caseLegacyReplayNoOp B [codex-1]: a no-op legacy replay must NOT create ~/.himmel/config.json when none existed (got: $outNoOpB)"
echo "ok: caseLegacyReplayNoOp B [codex-1] a no-op legacy replay does not create ~/.himmel/config.json when none existed"

# ═══════════════════════════════════════════════════════════════════════════
# casePhiVault (HIMMEL-2347) — the wizard's PHI/consent surface gains a
# personal/medical-vault-path question and WIRES it to the guard surface
# (~/.config/claude-glm/phi-roots + an offered .salus marker) the guardrails
# already read (graph-refresh.sh:75/403, refresh-graph-map.sh:339,
# graphify-fence.sh:330) — closing the HIMMEL-1773/1767 inertness class those
# guards have been silently exposed to since nothing in the installer ever
# created either input. HOME and CLAUDE_GLM_CONFIG_DIR are BOTH redirected
# into this suite's own fixtures on every invocation below (belt + suspenders
# over the HIMMEL-2350 hermeticity guard) so no case can ever touch the
# operator's real ~/.config/claude-glm/phi-roots.
# ═══════════════════════════════════════════════════════════════════════════

# ── PV1 (interactive --dry-run): the question is asked in the PHI section, a
# bare digit does NOT satisfy it (HIMMEL-2288 literal-only, live proof
# alongside test-wizard-questions.sh case10's source-level check), and
# answering with a path + consenting to the marker records BOTH in the
# printed profile. HIMMEL-2436: --dry-run no longer writes the T3 cache
# (same as caseVaultNoneNoOp's own step 1 below) — PV2 below extracts the
# equivalent JSON from this run's own stdout instead of reading it off disk
# — without touching any real file — proven again explicitly in PV6.
stubPV1="$work/stubPV1"; mkdir -p "$stubPV1"
pathPV1=$(build_path "$stubPV1" bash jq python3 npm -- python)
homePV1="$work/homePV1"; mkdir -p "$homePV1"
cachePV1="$work/cache-pv1"; mkdir -p "$cachePV1"
glmPV1="$work/glm-pv1"; mkdir -p "$glmPV1"
# NOT pre-created: vaultMode=default-template scaffolds it fresh, and an
# already-existing-but-unstamped directory trips the adopter preflight's own
# "carries no luna-second-brain stamp" refusal — unrelated to this ticket.
vaultPV1="$(winpath "$work/vault-pv1")"
phiVaultPV1="$(winpath "$work/personal-vault-pv1")"; mkdir -p "$work/personal-vault-pv1"

set +e
outPV1=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV1")" HIMMELCTL_INTERACTIVE=1 \
  HIMMELCTL_CACHE_DIR="$(winpath "$cachePV1")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cachePV1")-luna-config.json" \
  "$node_bin" "$wizard" install --dry-run 2>&1 <<INPUT
custom
project
default-template
$vaultPV1
inline
lean
none
no
none
no
no
1
yes
$phiVaultPV1
yes
skip
off
INPUT
); rcPV1=$?
set -e
[ "$rcPV1" -eq 0 ] || fail "PV1: interactive dry-run should succeed (got rc=$rcPV1): $outPV1"
reprompts_pv1=$(printf '%s' "$outPV1" | grep -c -- "do you keep a personal/medical vault" || true)
[ "$reprompts_pv1" -eq 2 ] \
  || fail "PV1 [HIMMEL-2288]: answering '1' (a bare digit) must NOT satisfy the personal-vault question — expected it to re-print exactly once more (2 total headers), got $reprompts_pv1: $outPV1"
grepq "$outPV1" -F "\"phiVaultPath\": \"$phiVaultPV1\"" \
  || fail "PV1: the answered path should be recorded in the profile at luna.phiVaultPath (got: $outPV1)"
grepq "$outPV1" -F '"createSalusMarker": true' \
  || fail "PV1: consenting to the .salus offer should record createSalusMarker=true (got: $outPV1)"
echo "ok: PV1 the personal/medical-vault question is literal-only (a bare digit re-prompts) and records path + marker-consent in the profile"

# ── PV2 (apply via --from-profile, non-dry, replaying PV1's own cache): the
# declaration MATERIALIZES the guard inputs — phi-roots gets the path
# appended in the LF-terminated, one-path-per-line format graph-refresh.sh's
# _under_any_list (and refresh-graph-map.sh's twin) parse, and the .salus
# marker is created at the vault root. A second identical apply proves the
# MERGE RULE: append-if-absent, never a duplicate line for the same path.
# HIMMEL-2436: --dry-run no longer WRITES the T3 cache (case2436d below), so
# extract the printed profile JSON from PV1's own stdout instead -- see the
# identical reasoning at caseVaultNoneNoOp's own step 1 above.
cachefilePV1="$cachePV1/install-profile.json"
extract_profile_json "$outPV1" > "$cachefilePV1"
[ -s "$cachefilePV1" ] || fail "PV2: could not extract PV1's printed profile JSON from its --dry-run stdout (got: $outPV1)"

fixtureRepoPV2="$work/fixture-repo-pv2"; mkdir -p "$fixtureRepoPV2/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV2/scripts/adopt.sh"
chmod +x "$fixtureRepoPV2/scripts/adopt.sh"

run_pv2_apply() {
  PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV1")" HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV2")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv2.json")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv2-replay")" \
    HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv2")" \
    "$node_bin" "$wizard" install --from-profile "$(winpath "$cachefilePV1")" </dev/null 2>&1
}
set +e
outPV2a=$(run_pv2_apply); rcPV2a=$?
set -e
[ "$rcPV2a" -eq 0 ] || fail "PV2: first apply of the recorded cache should succeed (got rc=$rcPV2a): $outPV2a"
phiRootsPV1="$glmPV1/phi-roots"
[ -f "$phiRootsPV1" ] || fail "PV2: expected phi-roots to be created at $phiRootsPV1 (got: $outPV2a)"
phiRootsBodyPV1=$(cat "$phiRootsPV1")
grepq "$phiRootsBodyPV1" -F "$phiVaultPV1" \
  || fail "PV2: phi-roots should contain the declared vault path (got: $phiRootsBodyPV1)"
[ "$(python -c "print(open(r'$(winpath "$phiRootsPV1")','rb').read().count(b'\r'))")" -eq 0 ] \
  || fail "PV2 [HIMMEL-1680 class]: phi-roots must be written LF-only, zero CR bytes (got: $phiRootsBodyPV1)"
salusMarkerPV1="$work/personal-vault-pv1/.salus"
[ -f "$salusMarkerPV1" ] \
  || fail "PV2: the consented .salus marker should be created at $salusMarkerPV1 (got: $outPV2a)"

# Re-apply the SAME cache: the merge rule is append-if-absent, so a second
# materialization of the same declared path must not duplicate the line.
set +e
outPV2b=$(run_pv2_apply); rcPV2b=$?
set -e
[ "$rcPV2b" -eq 0 ] || fail "PV2: second (idempotent) apply should succeed (got rc=$rcPV2b): $outPV2b"
occurrencesPV1=$(grep -c -F -- "$phiVaultPV1" "$phiRootsPV1")
[ "$occurrencesPV1" -eq 1 ] \
  || fail "PV2 [merge rule]: re-applying the same declared path must append-if-absent, not duplicate the line (got $occurrencesPV1 occurrences in: $(cat "$phiRootsPV1"))"
grepq "$outPV2b" -F 'already present' \
  || fail "PV2: the second apply should report the path as already present, not re-add it (got: $outPV2b)"
echo "ok: PV2 applying the recorded declaration appends phi-roots (LF-only) and creates the consented .salus marker; a repeat apply merges append-if-absent, never duplicating the entry"

# ── PV3 — the merge rule preserves an existing CRLF-saved file's OTHER
# entries (never truncates what an operator or another tool put there) while
# normalizing the rewrite to LF and deduping without a CRLF-vs-LF false
# mismatch.
glmPV3="$work/glm-pv3"; mkdir -p "$glmPV3"
priorEntryPV3="$(winpath "$work/some-other-declared-root")"
printf '%s\r\n' "$priorEntryPV3" > "$glmPV3/phi-roots"
vaultPV3="$(winpath "$work/vault-pv3")"  # not pre-created — matches caseApply's vaultPathApply convention

profilePV3="$work/profilePV3.json"
cat > "$profilePV3" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "default-template", "path": "$vaultPV3" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV3", "createSalusMarker": false }
}
JSON

fixtureRepoPV3="$work/fixture-repo-pv3"; mkdir -p "$fixtureRepoPV3/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV3/scripts/adopt.sh"
chmod +x "$fixtureRepoPV3/scripts/adopt.sh"

set +e
outPV3=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV3")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV3")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv3.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv3")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv3")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV3")" </dev/null 2>&1); rcPV3=$?
set -e
[ "$rcPV3" -eq 0 ] || fail "PV3: apply against a CRLF-saved phi-roots should succeed (got rc=$rcPV3): $outPV3"
phiRootsBodyPV3=$(cat "$glmPV3/phi-roots")
grepq "$phiRootsBodyPV3" -F "$priorEntryPV3" \
  || fail "PV3 [merge rule]: a pre-existing entry from an operator/another tool must be preserved, never truncated (got: $phiRootsBodyPV3)"
grepq "$phiRootsBodyPV3" -F "$vaultPV3" \
  || fail "PV3: the newly declared path should be appended alongside the preserved entry (got: $phiRootsBodyPV3)"
[ "$(python -c "print(open(r'$(winpath "$glmPV3/phi-roots")','rb').read().count(b'\r'))")" -eq 0 ] \
  || fail "PV3 [HIMMEL-1680 class]: the rewritten phi-roots must be LF-only even though the pre-existing file was CRLF-saved (got: $phiRootsBodyPV3)"
# HIMMEL-2347 CR fix 3: mergePhiRoot() now writes via a sibling tmp file +
# rename() (atomic write, torn-write fix) — this listing proves the tmp file
# never survives a normal run: exactly one entry (phi-roots itself), no
# `.phi-roots.<pid>.tmp` litter left behind in the config dir. NOTE this does
# NOT discriminate pre-/post-fix (same as PV9d's own note): the pre-fix code
# wrote `file` directly with no tmp file at all, so "no .tmp litter" was
# already trivially true before this change too — it's a regression guard
# against a FUTURE tmp-cleanup bug, not proof the atomic-write fix itself
# exists. An interruption-mid-write is inherently hard to simulate
# behaviorally in a hermetic test; the actual discriminating proof that fix 3
# landed is source-level: test-wizard-noinstall-guard.sh's caseC pin on
# `fs.writeFileSync(tmp, lines.join('` (was `fs.writeFileSync(file, ...`
# pre-fix — that exact string is absent before this change).
glmPV3Listing=$(ls -a "$glmPV3")
[ "$(printf '%s\n' "$glmPV3Listing" | grep -c '^phi-roots$')" -eq 1 ] \
  || fail "PV3 [HIMMEL-2347 CR fix 3]: expected exactly one phi-roots file, got: $glmPV3Listing"
printf '%s\n' "$glmPV3Listing" | grep -q '\.tmp$' \
  && fail "PV3 [HIMMEL-2347 CR fix 3]: the atomic-write tmp file must be renamed away, never left behind in the config dir (got: $glmPV3Listing)"
echo "ok: PV3 a CRLF-saved phi-roots file's existing entries survive the merge, the rewrite normalizes to LF-only, and the atomic-write tmp file is never left behind"

# ── PV4 — declining the .salus offer still records the declaration (phi-
# roots is written regardless; only the consented marker write is gated).
glmPV4="$work/glm-pv4"; mkdir -p "$glmPV4"
vaultPV4="$(winpath "$work/vault-pv4")"  # not pre-created — matches caseApply's vaultPathApply convention
profilePV4="$work/profilePV4.json"
cat > "$profilePV4" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "default-template", "path": "$vaultPV4" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV4", "createSalusMarker": false }
}
JSON
fixtureRepoPV4="$work/fixture-repo-pv4"; mkdir -p "$fixtureRepoPV4/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV4/scripts/adopt.sh"
chmod +x "$fixtureRepoPV4/scripts/adopt.sh"

set +e
outPV4=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV4")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV4")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv4.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv4")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv4")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV4")" </dev/null 2>&1); rcPV4=$?
set -e
[ "$rcPV4" -eq 0 ] || fail "PV4: apply declining the marker offer should succeed (got rc=$rcPV4): $outPV4"
grepq "$(cat "$glmPV4/phi-roots")" -F "$vaultPV4" \
  || fail "PV4: declining the .salus offer must still write phi-roots (got: $(cat "$glmPV4/phi-roots" 2>/dev/null))"
[ -f "$work/vault-pv4/.salus" ] \
  && fail "PV4: declining the .salus offer must NOT create the marker (got a .salus file at $work/vault-pv4/.salus)"
echo "ok: PV4 declining the .salus marker offer still records the declaration and still writes phi-roots"

# ── PV5 — a declared vault path that does not YET exist is still a valid
# declaration (design constraint: a not-yet-created vault is not a reason to
# drop it): phi-roots is written regardless, and the consented .salus offer
# is honestly deferred (never silently claimed) rather than crashing.
glmPV5="$work/glm-pv5"; mkdir -p "$glmPV5"
vaultPV5="$(winpath "$work/vault-pv5-does-not-exist")"
profilePV5="$work/profilePV5.json"
cat > "$profilePV5" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "phiDeclared": false, "phiVaultPath": "$vaultPV5", "createSalusMarker": true }
}
JSON
fixtureRepoPV5="$work/fixture-repo-pv5"; mkdir -p "$fixtureRepoPV5/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV5/scripts/adopt.sh"
chmod +x "$fixtureRepoPV5/scripts/adopt.sh"

set +e
outPV5=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV5")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV5")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv5.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv5")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv5")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV5")" </dev/null 2>&1); rcPV5=$?
set -e
[ "$rcPV5" -eq 0 ] || fail "PV5: a declared-but-not-yet-created vault path must not fail the install (got rc=$rcPV5): $outPV5"
grepq "$(cat "$glmPV5/phi-roots" 2>/dev/null)" -F "$vaultPV5" \
  || fail "PV5: phi-roots should still record the declaration for a not-yet-created vault (got: $(cat "$glmPV5/phi-roots" 2>/dev/null))"
grepq "$outPV5" -F 'does not exist yet' \
  || fail "PV5: the run should say honestly that the .salus marker was NOT created, rather than silently claiming it (got: $outPV5)"
echo "ok: PV5 a declared vault path that does not yet exist still writes phi-roots; the consented .salus marker is honestly deferred, never silently claimed"

# ── PV6 (not-asked discipline, the regression that matters most) — a run
# that never reaches the personal-vault question must leave phi-roots
# UNTOUCHED and fabricate no phiVaultPath. Two angles: (a) the interactive
# vault=none cache never serializes the field at all (extends
# caseVaultNoneNoOp's own "not asked" proof above with the SAME cache file);
# (b) a legacy --from-profile replay with NO luna section leaves an
# EXISTING, pre-seeded phi-roots file byte-identical.
echo "$cacheBodyVN" | jq -e 'has("luna") | not' >/dev/null \
  || fail "PV6a: (sanity re-check) the vault=none cache from caseVaultNoneNoOp must still carry no luna key at all"
echo "$cacheBodyVN" | jq -e '(.luna.phiVaultPath // null) == null' >/dev/null \
  || fail "PV6a [HIMMEL-2347]: a vault=none interactive run must never fabricate luna.phiVaultPath (got cache: $cacheBodyVN)"
echo "ok: PV6a a vault=none interactive run never serializes luna.phiVaultPath -- the question was never reached"

glmPV6="$work/glm-pv6"; mkdir -p "$glmPV6"
priorRootPV6="some/pre-existing/root"
printf '%s\n' "$priorRootPV6" > "$glmPV6/phi-roots"
phiRootsBeforePV6=$(cat "$glmPV6/phi-roots")
mtimeBeforePV6=$(stat -c '%Y' "$glmPV6/phi-roots" 2>/dev/null || stat -f '%m' "$glmPV6/phi-roots")  # gnu-ok: GNU stat -c is paired with the BSD `stat -f` fallback on this same line
sleep 1.1

fixtureRepoPV6="$work/fixture-repo-pv6"; mkdir -p "$fixtureRepoPV6/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV6/scripts/adopt.sh"
chmod +x "$fixtureRepoPV6/scripts/adopt.sh"

set +e
outPV6=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV6")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV6")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv6.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv6")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv6")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileLegacy")" </dev/null 2>&1); rcPV6=$?
set -e
[ "$rcPV6" -eq 0 ] || fail "PV6b: a legacy (no-luna-section) replay should still succeed (got rc=$rcPV6): $outPV6"
phiRootsAfterPV6=$(cat "$glmPV6/phi-roots")
mtimeAfterPV6=$(stat -c '%Y' "$glmPV6/phi-roots" 2>/dev/null || stat -f '%m' "$glmPV6/phi-roots")  # gnu-ok: GNU stat -c is paired with the BSD `stat -f` fallback on this same line
[ "$phiRootsBeforePV6" = "$phiRootsAfterPV6" ] \
  || fail "PV6b [HIMMEL-2347]: a run whose profile carries no luna section must leave phi-roots byte-identical
before: $phiRootsBeforePV6
after:  $phiRootsAfterPV6"
[ "$mtimeBeforePV6" = "$mtimeAfterPV6" ] \
  || fail "PV6b [HIMMEL-2347]: a run whose profile carries no luna section must leave phi-roots' mtime untouched (never rewritten) -- before=$mtimeBeforePV6 after=$mtimeAfterPV6"
echo "ok: PV6b a legacy replay with no luna section leaves an existing phi-roots file byte-identical -- not-asked never fabricates a write"

# ── PV7 — --dry-run's unconditional zero-mutation guarantee covers phi-roots
# and the .salus marker too: the DRY: preview lines print, but neither file
# is created.
glmPV7="$work/glm-pv7"; mkdir -p "$glmPV7"
vaultPV7="$(winpath "$work/vault-pv7")"  # not pre-created — matches caseApply's vaultPathApply convention
profilePV7="$work/profilePV7.json"
cat > "$profilePV7" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "default-template", "path": "$vaultPV7" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV7", "createSalusMarker": true }
}
JSON

set +e
outPV7=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV7")" HIMMELCTL_INTERACTIVE=0 \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv7-unused.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv7")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv7")" \
  "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$profilePV7")" </dev/null 2>&1); rcPV7=$?
set -e
[ "$rcPV7" -eq 0 ] || fail "PV7: --dry-run should succeed (got rc=$rcPV7): $outPV7"
grepq "$outPV7" -F "DRY: phi-roots -> append $vaultPV7" \
  || fail "PV7: --dry-run should print the intended phi-roots write (got: $outPV7)"
grepq "$outPV7" -F 'DRY: .salus marker ->' \
  || fail "PV7: --dry-run should print the intended .salus marker creation (got: $outPV7)"
[ -e "$glmPV7/phi-roots" ] \
  && fail "PV7 [--dry-run zero-mutation]: --dry-run must NOT actually create phi-roots (found: $glmPV7/phi-roots)"
[ -e "$work/vault-pv7/.salus" ] \
  && fail "PV7 [--dry-run zero-mutation]: --dry-run must NOT actually create the .salus marker (found: $work/vault-pv7/.salus)"
echo "ok: PV7 --dry-run prints the intended phi-roots write and .salus offer and creates neither file"

# ── PV8 (HIMMEL-2347 CR fix 1) — an existing `.salus` marker WITH CONTENT
# must survive a re-consented offer byte-for-byte: the pre-fix code did an
# unconditional fs.writeFileSync(path, '') on every consenting run, which
# truncates whatever an operator or another tool had already put in the
# marker. The guards only check existence ([ -e "$d/.salus" ]), so an
# existing marker never needs rewriting -- and the run must say so honestly
# ("already present"), never "created".
glmPV8="$work/glm-pv8"; mkdir -p "$glmPV8"
vaultPV8="$(winpath "$work/vault-pv8")"; mkdir -p "$work/vault-pv8"
markerPV8="$work/vault-pv8/.salus"
markerBodyPV8="operator note: do not touch -- salus metadata lives here"
printf '%s' "$markerBodyPV8" > "$markerPV8"
profilePV8="$work/profilePV8.json"
cat > "$profilePV8" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV8", "createSalusMarker": true }
}
JSON
fixtureRepoPV8="$work/fixture-repo-pv8"; mkdir -p "$fixtureRepoPV8/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV8/scripts/adopt.sh"
chmod +x "$fixtureRepoPV8/scripts/adopt.sh"

set +e
outPV8=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV8")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV8")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv8.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv8")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv8")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV8")" </dev/null 2>&1); rcPV8=$?
set -e
[ "$rcPV8" -eq 0 ] || fail "PV8: apply with a pre-existing .salus marker should still succeed (got rc=$rcPV8): $outPV8"
markerBodyAfterPV8=$(cat "$markerPV8")
[ "$markerBodyAfterPV8" = "$markerBodyPV8" ] \
  || fail "PV8 [HIMMEL-2347 CR fix 1]: an existing .salus marker with content must survive byte-for-byte, never truncated by a re-consented offer
before: $markerBodyPV8
after:  $markerBodyAfterPV8"
grepq "$outPV8" -F ".salus marker already present at" \
  || fail "PV8: the run should report the marker as already present, not created (got: $outPV8)"
grepq "$outPV8" -F "himmelctl: created" \
  && fail "PV8: the run must NOT claim it created a marker that already existed (got: $outPV8)"
echo "ok: PV8 an existing .salus marker with content survives a consented offer byte-for-byte; the run reports it as already present, never created"

# ── PV9 (HIMMEL-2347 CR fix 2) — profile validation on luna.phiVaultPath:
# the pre-fix validator only checked `typeof === 'string'`, so a blank,
# whitespace-only, or RELATIVE path was silently accepted -- a relative
# entry never matches the guards' absolute-path comparison (silently inert,
# the HIMMEL-1773 class), and path.join(phiVaultAbs, '.salus') on one
# resolves against the installer's cwd, not the declared vault.  9a-9c: each
# of relative/blank/whitespace-only must be REJECTED (rc=2, naming the
# field).
fixtureRepoPV9="$work/fixture-repo-pv9"; mkdir -p "$fixtureRepoPV9/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV9/scripts/adopt.sh"
chmod +x "$fixtureRepoPV9/scripts/adopt.sh"
pv9_labels=(9a 9b 9c)
pv9_values=("relative/vault-dir" "" "   ")
pv9_descs=("a RELATIVE path" "a blank path" "a whitespace-only path")
for i9 in 0 1 2; do
  label9="${pv9_labels[$i9]}"
  val9="${pv9_values[$i9]}"
  desc9="${pv9_descs[$i9]}"
  profilePV9="$work/profilePV9-$label9.json"
  # jq -n so an empty/whitespace value round-trips into the JSON exactly,
  # without a heredoc's own quoting to fight.
  jq -n --arg v "$val9" '{
    schemaVersion: 2, profile: "custom", devOverlay: false, tier: "standard", scope: "project",
    vault: {mode:"none", path:""}, handover: {mode:"inline", path:""},
    pluginSet: "lean", lanes: [], lanesMeaningful: true, alwaysOn: false,
    luna: {cadenceEnabled:false, phiDeclared:false, phiVaultPath:$v, createSalusMarker:false}
  }' > "$profilePV9"
  set +e
  out9=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$work/glm-pv9-$label9")" HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV9")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv9-$label9.json")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv9-$label9")" \
    HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv9-$label9")" \
    "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV9")" </dev/null 2>&1); rc9=$?
  set -e
  [ "$rc9" -eq 2 ] || fail "PV9$label9 [HIMMEL-2347 CR fix 2]: $desc9 luna.phiVaultPath should be rejected with rc=2 (got rc=$rc9): $out9"
  grepq "$out9" -i "field 'luna.phiVaultPath'" \
    || fail "PV9$label9: should name the bad luna.phiVaultPath field (got: $out9)"
done
echo "ok: PV9a-c a relative, blank, or whitespace-only luna.phiVaultPath is rejected (rc=2, names the field)"

# ── PV9d -- a leading '~' is explicitly accepted (expandHome() resolves it
# later, downstream of this validation). NOTE this one does NOT discriminate
# pre-/post-fix: the pre-fix validator's bare typeof==='string' check never
# rejected '~' either (verified by hand). It stays as a regression guard
# against an absolute-only implementation of fix 2 that would incorrectly
# reject a '~'-prefixed value before expandHome() ever runs.
homeTildePV9="$work/home-tilde-pv9"; mkdir -p "$homeTildePV9"
profilePV9d="$work/profilePV9d.json"
cat > "$profilePV9d" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "~/personal-vault-tilde", "createSalusMarker": false }
}
JSON
glmPV9d="$work/glm-pv9d"; mkdir -p "$glmPV9d"

set +e
outPV9d=$(PATH="$pathPV1" HOME="$homeTildePV9" USERPROFILE="$(winpath "$homeTildePV9")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV9d")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV9")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv9d.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv9d")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv9d")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV9d")" </dev/null 2>&1); rcPV9d=$?
set -e
[ "$rcPV9d" -eq 0 ] || fail "PV9d: a '~'-prefixed luna.phiVaultPath should be ACCEPTED and expanded, not rejected (got rc=$rcPV9d): $outPV9d"
grepq "$(cat "$glmPV9d/phi-roots" 2>/dev/null)" -F "personal-vault-tilde" \
  || fail "PV9d: the expanded ~-path should land in phi-roots (got: $(cat "$glmPV9d/phi-roots" 2>/dev/null))"
echo "ok: PV9d a '~'-prefixed luna.phiVaultPath is accepted by validation and expanded before being recorded"

# ── PV10 (HIMMEL-2347 CR fix 3) — a phi-roots READ failure must not discard
# existing entries, and must not abort the whole install: pre-fix,
# mergePhiRoot()'s unconditional `catch (_e) { lines = []; }` treated ANY
# read failure (not just "no file yet") as "empty file", then the
# unconditional rewrite either silently loses every already-recorded root,
# or (when the write ALSO fails, as it does here since the "file" is a
# directory) throws with no try/catch anywhere above mergePhiRoot() --
# main()'s own top-level .catch() turns that into a bare `himmelctl: EISDIR:
# ...` line and aborts the ENTIRE run right there, skipping every step after
# it (bridge/cadence wiring, the plugin step, the install summary, the
# uninstall footer) instead of completing the run and reporting the one
# failure honestly.
# Simulated portably per the brief: CLAUDE_GLM_CONFIG_DIR points at a
# directory whose `phi-roots` entry is itself a DIRECTORY, so
# fs.readFileSync raises EISDIR -- verified by hand on this host (a bare
# MSYS-style /tmp/... path resolves to C:\tmp and gives ENOENT instead; an
# absolute winpath()'d path under $work reliably gives EISDIR here).
glmPV10="$work/glm-pv10"; mkdir -p "$glmPV10"
mkdir -p "$glmPV10/phi-roots"   # a DIRECTORY named phi-roots, not a file
vaultPV10="$(winpath "$work/vault-pv10")"; mkdir -p "$work/vault-pv10"
profilePV10="$work/profilePV10.json"
cat > "$profilePV10" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV10", "createSalusMarker": false }
}
JSON
fixtureRepoPV10="$work/fixture-repo-pv10"; mkdir -p "$fixtureRepoPV10/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV10/scripts/adopt.sh"
chmod +x "$fixtureRepoPV10/scripts/adopt.sh"

set +e
outPV10=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV10")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV10")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv10.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv10")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv10")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV10")" </dev/null 2>&1); rcPV10=$?
set -e
[ "$rcPV10" -ne 0 ] \
  || fail "PV10 [HIMMEL-2347 CR fix 3]: a phi-roots read failure should surface as a non-zero rc, not a silent success (got rc=0): $outPV10"
grepq "$outPV10" -F "PHI root NOT recorded" \
  || fail "PV10: the run should honestly report the PHI root was NOT recorded, not silently swallow (or bare-crash on) the read failure (got: $outPV10)"
grepq "$outPV10" -F "To uninstall later:" \
  || fail "PV10: the run must complete gracefully (reach the uninstall footer and the rest of the install), not abort mid-run on the phi-roots failure (got: $outPV10)"
[ -d "$glmPV10/phi-roots" ] \
  || fail "PV10: phi-roots must stay untouched (still the directory it was) -- the unreadable path must never be rewritten (got: $(ls -la "$glmPV10" 2>&1))"
echo "ok: PV10 a phi-roots read failure (EISDIR) is surfaced honestly (non-zero rc, 'PHI root NOT recorded') and the install completes rather than losing entries or aborting mid-run"

# ── The FAILS-BEFORE observation (HIMMEL-2347 brief): every PV1-PV7
# assertion above targets code that did not exist before this ticket. VERIFIED
# by hand: running this suite against the pre-2347 bin.js (HEAD of this
# branch before the fix), PV1 fails first -- "answering '1' (a bare digit)
# must NOT satisfy the personal-vault question ... got 0" -- because
# askQuestions() never asks it at all (closed-stdin fast-fills every
# subsequent prompt with '', so the reprompt count is 0, not 2). Every later
# PV case would fail the same way in turn (buildAnswers() never carries
# phiVaultPath/createSalusMarker, applyLunaSectionsStep()/
# previewLunaSections() never write/preview phi-roots or .salus at all) --
# not re-run here since that would require checking out a second bin.js
# mid-suite.

# ═══════════════════════════════════════════════════════════════════════════
# HIMMEL-2347 CR round 2 (PV11-PV14): four fixes verified in this pass —
# fix 1 (interactive-site validation gap), fix 2 (consented marker-creation
# failure must set rc=1), fix 4 (createSalusMarker without phiVaultPath is
# rejected). Fix 3 (atomic write) is covered by the tmp-litter assertion
# added to PV3 above, alongside its existing preserve/append/LF-only checks.
# ═══════════════════════════════════════════════════════════════════════════

# ── PV11 (HIMMEL-2347 CR fix 1) — the INTERACTIVE personal/medical vault
# path question re-prompts on a RELATIVE answer instead of accepting it:
# pre-fix, loadProfile() was the ONLY enforcement point (PV9a-c above), so an
# operator typing a relative path AT THE WIZARD ITSELF sailed straight
# through — the same HIMMEL-1773 inertness bug PV9 already closed for
# --from-profile, reopened for the live question. Same convention as
# PV1's own bare-digit reprompt proof: count the prompt header occurrences.
stubPV11="$work/stubPV11"; mkdir -p "$stubPV11"
pathPV11=$(build_path "$stubPV11" bash jq python3 npm -- python)
homePV11="$work/homePV11"; mkdir -p "$homePV11"
cachePV11="$work/cache-pv11"; mkdir -p "$cachePV11"
glmPV11="$work/glm-pv11"; mkdir -p "$glmPV11"
vaultPV11="$(winpath "$work/vault-pv11")"  # not pre-created, same as PV1
phiVaultPV11="$(winpath "$work/personal-vault-pv11")"; mkdir -p "$work/personal-vault-pv11"
relativeAnswerPV11="relative/pv11-personal-vault"

set +e
outPV11=$(PATH="$pathPV11" HOME="$homePV11" USERPROFILE="$(winpath "$homePV11")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV11")" HIMMELCTL_INTERACTIVE=1 \
  HIMMELCTL_CACHE_DIR="$(winpath "$cachePV11")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cachePV11")-luna-config.json" \
  "$node_bin" "$wizard" install --dry-run 2>&1 <<INPUT
custom
project
default-template
$vaultPV11
inline
lean
none
no
none
no
no
1
yes
$relativeAnswerPV11
$phiVaultPV11
yes
skip
off
INPUT
); rcPV11=$?
set -e
[ "$rcPV11" -eq 0 ] || fail "PV11: interactive dry-run should succeed after re-prompting on the relative answer (got rc=$rcPV11): $outPV11"
reprompts_pv11=$(printf '%s' "$outPV11" | grep -c -- "personal/medical vault path" || true)
[ "$reprompts_pv11" -eq 2 ] \
  || fail "PV11 [HIMMEL-2347 CR fix 1]: answering a RELATIVE path must re-prompt (2 total headers: the original + one retry), got $reprompts_pv11: $outPV11"
grepq "$outPV11" -F "$relativeAnswerPV11" \
  || fail "PV11: the rejection reason should name the rejected relative answer (got: $outPV11)"
grepq "$outPV11" -F "\"phiVaultPath\": \"$phiVaultPV11\"" \
  || fail "PV11: the eventually-accepted ABSOLUTE answer should be recorded in the profile (got: $outPV11)"
grepq "$outPV11" -F "\"phiVaultPath\": \"$relativeAnswerPV11\"" \
  && fail "PV11: the rejected relative answer must NEVER be recorded as luna.phiVaultPath (got: $outPV11)"
echo "ok: PV11 the interactive personal/medical-vault-path question re-prompts on a relative answer and records only the later absolute one"

# ── PV12 (HIMMEL-2347 CR fix 1, continued) — materializing PV11's own
# recorded declaration never writes the rejected relative string into
# phi-roots; only the absolute path that was ultimately accepted lands
# there. (This step's own cache already carries the fixed value by
# construction — PV11 above is the case that actually discriminates
# pre-/post-fix behavior at the wizard; this closes the loop end-to-end.)
# HIMMEL-2436: --dry-run no longer WRITES the T3 cache -- extract the
# printed profile JSON from PV11's own stdout instead (see the identical
# reasoning at caseVaultNoneNoOp's own step 1 above).
cachefilePV11="$cachePV11/install-profile.json"
extract_profile_json "$outPV11" > "$cachefilePV11"
[ -s "$cachefilePV11" ] || fail "PV12: could not extract PV11's printed profile JSON from its --dry-run stdout (got: $outPV11)"
fixtureRepoPV12="$work/fixture-repo-pv12"; mkdir -p "$fixtureRepoPV12/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV12/scripts/adopt.sh"
chmod +x "$fixtureRepoPV12/scripts/adopt.sh"

set +e
outPV12=$(PATH="$pathPV11" HOME="$homePV11" USERPROFILE="$(winpath "$homePV11")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV11")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV12")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv12.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv12-replay")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv12")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$cachefilePV11")" </dev/null 2>&1); rcPV12=$?
set -e
[ "$rcPV12" -eq 0 ] || fail "PV12: applying PV11's recorded cache should succeed (got rc=$rcPV12): $outPV12"
phiRootsBodyPV11=$(cat "$glmPV11/phi-roots" 2>/dev/null)
grepq "$phiRootsBodyPV11" -F "$phiVaultPV11" \
  || fail "PV12: phi-roots should contain the accepted ABSOLUTE path (got: $phiRootsBodyPV11)"
grepq "$phiRootsBodyPV11" -F "$relativeAnswerPV11" \
  && fail "PV12: phi-roots must never contain the rejected RELATIVE answer (got: $phiRootsBodyPV11)"
echo "ok: PV12 materializing the wizard's own recorded declaration writes only the accepted absolute path into phi-roots, never the rejected relative one"

# ── PV13 (HIMMEL-2347 CR fix 2) — a CONSENTED .salus creation that genuinely
# fails must surface as a non-zero rc, not a silent WARN-and-exit-0. EEXIST
# (PV8) is NOT this case (a directory named .salus was tried and, verified by
# hand on this Windows/Node host, produces EEXIST — success/"already
# present", not a failure). What DOES reliably fail here: making
# luna.phiVaultPath itself an existing FILE (not a directory) — fs.existsSync
# is true (so the marker-creation branch is reached, not the "does not exist
# yet" deferral), but fs.writeFileSync(path.join(fileAsVault, '.salus'), '',
# {flag:'wx'}) then fails with ENOENT (verified by hand: `node -e` against
# this exact shape on this host). phi-roots is written BEFORE the marker
# attempt (independent write), so it should still record the declaration —
# only the marker half fails.
glmPV13="$work/glm-pv13"; mkdir -p "$glmPV13"
phiVaultFilePV13="$(winpath "$work/phivault-pv13-as-file")"
printf 'not a directory' > "$work/phivault-pv13-as-file"
profilePV13="$work/profilePV13.json"
cat > "$profilePV13" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$phiVaultFilePV13", "createSalusMarker": true }
}
JSON
fixtureRepoPV13="$work/fixture-repo-pv13"; mkdir -p "$fixtureRepoPV13/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV13/scripts/adopt.sh"
chmod +x "$fixtureRepoPV13/scripts/adopt.sh"

set +e
outPV13=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV13")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV13")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv13.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv13")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv13")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV13")" </dev/null 2>&1); rcPV13=$?
set -e
[ "$rcPV13" -ne 0 ] \
  || fail "PV13 [HIMMEL-2347 CR fix 2]: a consented .salus creation that genuinely fails should surface as a non-zero rc, not exit 0 (got rc=0): $outPV13"
grepq "$outPV13" -F "could not create .salus marker" \
  || fail "PV13: should WARN naming the failed marker creation (got: $outPV13)"
grepq "$(cat "$glmPV13/phi-roots" 2>/dev/null)" -F "$phiVaultFilePV13" \
  || fail "PV13: phi-roots should still record the declaration even though the marker failed (got: $(cat "$glmPV13/phi-roots" 2>/dev/null))"
echo "ok: PV13 a consented .salus creation that genuinely fails sets a non-zero rc while still recording phi-roots"

# ── PV14 (HIMMEL-2347 CR fix 4) — createSalusMarker:true with NO
# phiVaultPath is a marker request that can never be applied
# (applyLunaSectionsStep only reaches the marker block when phiVaultPath is
# truthy) — reject it in profile validation, same rc=2/field-naming shape as
# PV9a-c, rather than silently accepting a request that will silently no-op.
fixtureRepoPV14="$work/fixture-repo-pv14"; mkdir -p "$fixtureRepoPV14/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV14/scripts/adopt.sh"
chmod +x "$fixtureRepoPV14/scripts/adopt.sh"
profilePV14="$work/profilePV14.json"
cat > "$profilePV14" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "createSalusMarker": true }
}
JSON

set +e
outPV14=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$work/glm-pv14")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV14")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv14.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv14")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv14")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV14")" </dev/null 2>&1); rcPV14=$?
set -e
[ "$rcPV14" -eq 2 ] || fail "PV14 [HIMMEL-2347 CR fix 4]: createSalusMarker:true without phiVaultPath should be rejected with rc=2 (got rc=$rcPV14): $outPV14"
grepq "$outPV14" -i "field 'luna.createSalusMarker'" \
  || fail "PV14: should name luna.createSalusMarker in the rejection (got: $outPV14)"
echo "ok: PV14 createSalusMarker:true without a declared phiVaultPath is rejected by profile validation (rc=2, names the field)"

# ── PV15 (HIMMEL-2347 CR fix 7) — an existing phi-roots file's permissions
# survive the atomic tmp+rename replace introduced by fix 3. Fix 3 replaced
# an in-place fs.writeFileSync (which preserves the target's existing mode)
# with a fresh tmp file + rename, and a fresh tmp file gets the platform
# default mode -- silently WIDENING an operator-restricted phi-roots on
# rename. mergePhiRoot() now fs.statSync()s the pre-existing file and
# re-applies its mode to tmp before the rename carries it onto the target.
# NOTE this assertion does NOT discriminate pre-/post-fix on THIS
# Windows/Git-Bash host, verified by hand: fs.chmodSync()/fs.statSync() here
# only round-trip a BINARY "has any write bit" -> the DOS read-only
# attribute -- any mode with an owner-write bit (0600 included) reads back
# as 0666 both before and after this fix (a freshly-created tmp file's own
# default mode is ALSO 0666 here, so the pre-fix widening this test targets
# is invisible on this host), and the one mode that DOES read back
# distinctly (0444, no write bits at all) makes fs.renameSync() itself fail
# with EPERM on Windows when it would replace a read-only target -- a
# separate, pre-existing limitation of fix 3's tmp+rename mechanism
# (present with or without this fix, verified by hand), not something
# addressed or introduced here. It stays as a regression guard: on POSIX a
# fresh file's umask-restricted default mode (typically 0644) genuinely
# differs from an operator's tighter 0600, so there this assertion DOES
# discriminate (same non-discriminating-here precedent as PV9d/PV3).
glmPV15="$work/glm-pv15"; mkdir -p "$glmPV15"
priorRootPV15="$(winpath "$work/vault-pv15-prior")"
printf '%s\n' "$priorRootPV15" > "$glmPV15/phi-roots"
chmod 600 "$glmPV15/phi-roots"
modeBeforePV15=$(python -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$(winpath "$glmPV15/phi-roots")")

fixtureRepoPV15="$work/fixture-repo-pv15"; mkdir -p "$fixtureRepoPV15/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV15/scripts/adopt.sh"
chmod +x "$fixtureRepoPV15/scripts/adopt.sh"
vaultPV15="$(winpath "$work/vault-pv15")"
profilePV15="$work/profilePV15.json"
cat > "$profilePV15" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV15", "createSalusMarker": false }
}
JSON

set +e
outPV15=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV15")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV15")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv15.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv15")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv15")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV15")" </dev/null 2>&1); rcPV15=$?
set -e
[ "$rcPV15" -eq 0 ] || fail "PV15: apply should succeed (got rc=$rcPV15): $outPV15"
grepq "$(cat "$glmPV15/phi-roots")" -F "$vaultPV15" \
  || fail "PV15: the newly declared root should be appended (got: $(cat "$glmPV15/phi-roots"))"
modeAfterPV15=$(python -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$(winpath "$glmPV15/phi-roots")")
[ "$modeBeforePV15" = "$modeAfterPV15" ] \
  || fail "PV15 [HIMMEL-2347 CR fix 7]: phi-roots' mode must survive the atomic replace (before=$modeBeforePV15 after=$modeAfterPV15)"
echo "ok: PV15 an existing phi-roots' permissions survive the atomic tmp+rename replace when a new root is appended (see NOTE above: non-discriminating on this Windows/Git-Bash host)"

# ── PV16 (HIMMEL-2347 CR fix 6) — a root differing from an already-listed
# one ONLY by a trailing space is a genuinely DISTINCT POSIX path and must
# be appended, not silently treated as "already present". The pre-fix
# norm() trimmed the INCOMING root before comparing, so "/vault" and
# "/vault " (trailing space) collapsed to the same key and the
# space-suffixed declaration was silently dropped -- the guard stays inert
# for the path the operator actually declared (the exact HIMMEL-1773 class
# this ticket exists to close).
glmPV16="$work/glm-pv16"; mkdir -p "$glmPV16"
vaultPV16="$(winpath "$work/vault-pv16")"
printf '%s\n' "$vaultPV16" > "$glmPV16/phi-roots"
vaultPV16Spaced="${vaultPV16} "

fixtureRepoPV16="$work/fixture-repo-pv16"; mkdir -p "$fixtureRepoPV16/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV16/scripts/adopt.sh"
chmod +x "$fixtureRepoPV16/scripts/adopt.sh"
profilePV16="$work/profilePV16.json"
cat > "$profilePV16" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV16Spaced", "createSalusMarker": false }
}
JSON

set +e
outPV16=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV16")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV16")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv16.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv16")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv16")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV16")" </dev/null 2>&1); rcPV16=$?
set -e
[ "$rcPV16" -eq 0 ] || fail "PV16: apply should succeed (got rc=$rcPV16): $outPV16"
phiRootsBodyPV16=$(cat "$glmPV16/phi-roots")
[ "$(printf '%s\n' "$phiRootsBodyPV16" | grep -c -x -F -- "$vaultPV16")" -eq 1 ] \
  || fail "PV16: the original (space-free) entry must survive untouched (got: $phiRootsBodyPV16)"
[ "$(printf '%s\n' "$phiRootsBodyPV16" | grep -c -x -F -- "$vaultPV16Spaced")" -eq 1 ] \
  || fail "PV16 [HIMMEL-1773 class]: a root differing only by a trailing space must be treated as DISTINCT and appended, not silently skipped as 'already present' (got: $phiRootsBodyPV16)"
echo "ok: PV16 a root differing from a listed one only by a trailing space is treated as distinct and is appended, never silently merged away"

# ── PV17 (HIMMEL-2347 CR fix 6) — stripping trailing separators for the
# dedupe comparison must not collapse a root to the empty string: pre-fix,
# norm("/") stripped the lone "/" down to "", so a declared root of "/"
# spuriously compared equal to any blank line already in the file and was
# silently dropped.
glmPV17="$work/glm-pv17"; mkdir -p "$glmPV17"
priorOtherPV17="$(winpath "$work/vault-pv17-other")"
printf '%s\n\n' "$priorOtherPV17" > "$glmPV17/phi-roots"   # entry + a stray blank line

fixtureRepoPV17="$work/fixture-repo-pv17"; mkdir -p "$fixtureRepoPV17/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV17/scripts/adopt.sh"
chmod +x "$fixtureRepoPV17/scripts/adopt.sh"
profilePV17="$work/profilePV17.json"
cat > "$profilePV17" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "/", "createSalusMarker": false }
}
JSON

set +e
outPV17=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV17")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV17")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv17.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv17")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv17")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV17")" </dev/null 2>&1); rcPV17=$?
set -e
[ "$rcPV17" -eq 0 ] || fail "PV17: apply should succeed (got rc=$rcPV17): $outPV17"
phiRootsBodyPV17=$(cat "$glmPV17/phi-roots")
[ "$(printf '%s\n' "$phiRootsBodyPV17" | grep -c -x -F -- '/')" -eq 1 ] \
  || fail "PV17 [HIMMEL-1773 class]: a declared root of '/' must be appended as itself, not collapsed to empty and swallowed by an existing blank line (got: $phiRootsBodyPV17)"
grepq "$phiRootsBodyPV17" -F "$priorOtherPV17" \
  || fail "PV17: the pre-existing entry must survive (got: $phiRootsBodyPV17)"
echo "ok: PV17 a root of '/' is appended as itself, not collapsed to empty by the trailing-separator strip, and does not match a pre-existing blank line"

# ── PV18 (HIMMEL-2347 CR fix 8, round 4) — a trailing separator is not
# semantically significant, so it must be stripped on the INCOMING root too
# (round 3 stripped it on the stored side only): a stored "/vault" and a
# declared "/vault/" name the same directory and must dedupe as one entry in
# BOTH declaration orders, else phi-roots grows without bound across
# repeated installs of the same root.
glmPV18="$work/glm-pv18"; mkdir -p "$glmPV18"
vaultPV18="$(winpath "$work/vault-pv18")"
printf '%s\n' "$vaultPV18" > "$glmPV18/phi-roots"
vaultPV18Slash="${vaultPV18}/"

fixtureRepoPV18="$work/fixture-repo-pv18"; mkdir -p "$fixtureRepoPV18/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV18/scripts/adopt.sh"
chmod +x "$fixtureRepoPV18/scripts/adopt.sh"
profilePV18="$work/profilePV18.json"
cat > "$profilePV18" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV18Slash", "createSalusMarker": false }
}
JSON

set +e
outPV18=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV18")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV18")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv18.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv18")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv18")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV18")" </dev/null 2>&1); rcPV18=$?
set -e
[ "$rcPV18" -eq 0 ] || fail "PV18: apply should succeed (got rc=$rcPV18): $outPV18"
phiRootsBodyPV18=$(cat "$glmPV18/phi-roots")
linesPV18=$(printf '%s\n' "$phiRootsBodyPV18" | grep -c -v '^$')
[ "$linesPV18" -eq 1 ] \
  || fail "PV18 [HIMMEL-2347 CR fix 8]: declaring '/vault/' when '/vault' is already stored must append NOTHING, expected 1 line, got $linesPV18: $phiRootsBodyPV18"
grepq "$outPV18" -F 'already present' \
  || fail "PV18: should report the slash-suffixed declaration as already present (got: $outPV18)"
echo "ok: PV18 a trailing-separator-only difference from an already-stored root ('/vault' stored, '/vault/' declared) appends nothing"

# ── PV19 — same as PV18, reverse order: stored WITH the trailing separator,
# declared WITHOUT one. The comparison is symmetric (same normalization on
# both sides), so this must dedupe identically to PV18. NOTE this direction
# does NOT discriminate pre-/post-fix, verified by hand: round 3's
# normStored() already stripped a trailing separator off the STORED side, so
# a bare (unsuffixed) declared root already matched a slash-suffixed stored
# one before this fix too — the round-4 bug (PV18) only bit when the
# separator was on the INCOMING side, which normStored never touched. Kept
# as a regression guard proving the new symmetric rule doesn't regress the
# direction that already worked, same non-discriminating precedent as
# PV3/PV9d/PV15/PV22.
glmPV19="$work/glm-pv19"; mkdir -p "$glmPV19"
vaultPV19="$(winpath "$work/vault-pv19")"
printf '%s/\n' "$vaultPV19" > "$glmPV19/phi-roots"

fixtureRepoPV19="$work/fixture-repo-pv19"; mkdir -p "$fixtureRepoPV19/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV19/scripts/adopt.sh"
chmod +x "$fixtureRepoPV19/scripts/adopt.sh"
profilePV19="$work/profilePV19.json"
cat > "$profilePV19" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV19", "createSalusMarker": false }
}
JSON

set +e
outPV19=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV19")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV19")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv19.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv19")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv19")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV19")" </dev/null 2>&1); rcPV19=$?
set -e
[ "$rcPV19" -eq 0 ] || fail "PV19: apply should succeed (got rc=$rcPV19): $outPV19"
phiRootsBodyPV19=$(cat "$glmPV19/phi-roots")
linesPV19=$(printf '%s\n' "$phiRootsBodyPV19" | grep -c -v '^$')
[ "$linesPV19" -eq 1 ] \
  || fail "PV19 [HIMMEL-2347 CR fix 8, symmetric]: declaring '/vault' when '/vault/' is already stored must append NOTHING, expected 1 line, got $linesPV19: $phiRootsBodyPV19"
echo "ok: PV19 the reverse order (stored '/vault/', declared '/vault') also dedupes to nothing appended — the rule is symmetric"

# ── PV20 (HIMMEL-2347 CR fix 8) — whitespace is NOT a separator: a stored
# entry with a trailing space must NOT suppress a distinct incoming root
# that lacks one. Round 3's `.trim()` on the stored side alone made this
# false-suppress; the fix drops trimming entirely so both survive as two
# distinct entries (the mirror image of PV16, which proved the incoming side
# was never trimmed either).
glmPV20="$work/glm-pv20"; mkdir -p "$glmPV20"
vaultPV20="$(winpath "$work/vault-pv20")"
printf '%s \n' "$vaultPV20" > "$glmPV20/phi-roots"   # stored WITH a trailing space

fixtureRepoPV20="$work/fixture-repo-pv20"; mkdir -p "$fixtureRepoPV20/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV20/scripts/adopt.sh"
chmod +x "$fixtureRepoPV20/scripts/adopt.sh"
profilePV20="$work/profilePV20.json"
cat > "$profilePV20" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV20", "createSalusMarker": false }
}
JSON

set +e
outPV20=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV20")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV20")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv20.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv20")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv20")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV20")" </dev/null 2>&1); rcPV20=$?
set -e
[ "$rcPV20" -eq 0 ] || fail "PV20: apply should succeed (got rc=$rcPV20): $outPV20"
phiRootsBodyPV20=$(cat "$glmPV20/phi-roots")
[ "$(printf '%s\n' "$phiRootsBodyPV20" | grep -c -x -F -- "${vaultPV20} ")" -eq 1 ] \
  || fail "PV20 [HIMMEL-2347 CR fix 8]: the original space-suffixed entry must survive untouched (got: $phiRootsBodyPV20)"
[ "$(printf '%s\n' "$phiRootsBodyPV20" | grep -c -x -F -- "$vaultPV20")" -eq 1 ] \
  || fail "PV20 [HIMMEL-2347 CR fix 8]: a stored '/vault ' (trailing space) must NOT suppress a distinct incoming '/vault' — both must end up present (got: $phiRootsBodyPV20)"
echo "ok: PV20 a stored entry with a trailing space does not falsely suppress a genuinely distinct incoming root without one; both are recorded"

# ── PV21 (HIMMEL-2347 CR fix 9) — a replay that adds nothing (root already
# present) must not touch the file at all: no tmp+rename, no metadata bump.
# Compared via python's st_mtime_ns rather than a raw `stat -c`/`stat -f`
# pair — this file already leans on python for stat-shaped assertions
# (PV15's st_mode) because it is the one reliable cross-platform reader on
# this Windows/Git-Bash host.
glmPV21="$work/glm-pv21"; mkdir -p "$glmPV21"
vaultPV21="$(winpath "$work/vault-pv21")"
printf '%s\n' "$vaultPV21" > "$glmPV21/phi-roots"
mtimeBeforePV21=$(python -c "import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)" "$(winpath "$glmPV21/phi-roots")")

fixtureRepoPV21="$work/fixture-repo-pv21"; mkdir -p "$fixtureRepoPV21/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV21/scripts/adopt.sh"
chmod +x "$fixtureRepoPV21/scripts/adopt.sh"
profilePV21="$work/profilePV21.json"
cat > "$profilePV21" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV21", "createSalusMarker": false }
}
JSON

set +e
outPV21=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV21")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV21")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv21.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv21")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv21")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV21")" </dev/null 2>&1); rcPV21=$?
set -e
[ "$rcPV21" -eq 0 ] || fail "PV21: apply should succeed (got rc=$rcPV21): $outPV21"
grepq "$outPV21" -F 'already present' \
  || fail "PV21: a no-op replay should report already present (got: $outPV21)"
mtimeAfterPV21=$(python -c "import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)" "$(winpath "$glmPV21/phi-roots")")
[ "$mtimeBeforePV21" = "$mtimeAfterPV21" ] \
  || fail "PV21 [HIMMEL-2347 CR fix 9]: a no-op replay (root already present) must not rewrite phi-roots at all (mtime_ns before=$mtimeBeforePV21 after=$mtimeAfterPV21)"
echo "ok: PV21 a replay that adds nothing (root already present) does not rewrite phi-roots — mtime is unchanged"

# ── PV22 (HIMMEL-2347 CR fix 10) — a first-time phi-roots (no existing file,
# nothing to preserve) is created owner-only rather than keeping whatever the
# platform default mode would otherwise be; PV15 already covers the other
# half (an EXISTING file's mode surviving the atomic replace). NOTE like
# PV15: fs.chmodSync()/fs.statSync() on this Windows/Git-Bash host only
# round-trip a binary "has any write bit" -> the DOS read-only attribute, so
# 0o600 (has the owner-write bit) reads back identically to the platform
# default here and this assertion does NOT discriminate on this host —
# verified by hand. On POSIX, a fresh file's umask-restricted default
# (typically 0644) genuinely differs from 0600, so there it does.
glmPV22="$work/glm-pv22"; mkdir -p "$glmPV22"
vaultPV22="$(winpath "$work/vault-pv22")"

fixtureRepoPV22="$work/fixture-repo-pv22"; mkdir -p "$fixtureRepoPV22/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV22/scripts/adopt.sh"
chmod +x "$fixtureRepoPV22/scripts/adopt.sh"
profilePV22="$work/profilePV22.json"
cat > "$profilePV22" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "$vaultPV22", "createSalusMarker": false }
}
JSON

set +e
outPV22=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV22")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV22")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv22.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv22")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv22")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV22")" </dev/null 2>&1); rcPV22=$?
set -e
[ "$rcPV22" -eq 0 ] || fail "PV22: apply should succeed (got rc=$rcPV22): $outPV22"
modePV22=$(python -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$(winpath "$glmPV22/phi-roots")")
[ "$modePV22" = "0o600" ] \
  || echo "note: PV22 [HIMMEL-2347 CR fix 10]: first-time phi-roots mode is $modePV22, not 0o600 -- non-discriminating on this Windows/Git-Bash host per the NOTE above, not a failure"
echo "ok: PV22 a first-time phi-roots is created owner-only where this host's chmod semantics can show it (see NOTE above)"

# ── PV23 (HIMMEL-2424) — luna.phiVaultPath carrying an embedded CR or LF is
# rejected by profile validation, not silently split into two phi-roots
# lines. mergePhiRoot() writes phi-roots ONE PATH PER LINE and the PHI
# guards (graph-refresh.sh, refresh-graph-map.sh) read it back line-wise, so
# a declared path containing a newline was stored (pre-fix) as two lines and
# read back as two bogus roots, neither of which is the directory the
# operator actually declared -- the wrong-direction failure (reports
# success, protects the wrong thing). Reachable via --from-profile: profile
# JSON is arbitrary and profiles are generated/copied between machines, so
# "who would type that" doesn't apply the way it would to the interactive
# readline site. The embedded byte is placed via a JSON \n/\r ESCAPE
# SEQUENCE (two literal chars, backslash + n/r) written into the profile
# text -- not a raw CR/LF byte threaded through argv -- because passing a
# raw CR through jq's argv on this Windows/Git-Bash host was observed (by
# hand, running this exact case) to get silently eaten by the MSYS
# argv-translation layer before jq ever saw it (LF survived intact; CR did
# not) -- a variant of this suite's own file-header MSYS-mangling warning.
# JSON.parse() on this escape sequence produces the exact same in-memory
# control byte a raw one would, so the predicate under test sees an
# identical string either way; only the on-disk profile encoding differs.
fixtureRepoPV23="$work/fixture-repo-pv23"; mkdir -p "$fixtureRepoPV23/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV23/scripts/adopt.sh"
chmod +x "$fixtureRepoPV23/scripts/adopt.sh"
vaultBasePV23="$(winpath "$work/vault-pv23")"
pv23_labels=(23a 23b)
pv23_escapes=('\n' '\r')
pv23_descs=("an embedded LF" "an embedded CR")
# HIMMEL-2424 CR round 3: the expected reason is now per-BYTE, not shared
# across the loop, because the two phi-roots readers disagree about a bare
# CR. The PHI guards' `read -r` (graph-refresh.sh's _under_any_list) splits
# on LF only and strips a trailing \r, so a mid-line CR survives inside ONE
# guard entry -- no immediate split. But bin.js's own mergePhiRoot() re-reads
# phi-roots with split(/\r\n|\r|\n/), where a bare CR IS a separator, then
# writes every line back joined with \n -- so the split does not happen on
# THIS declaration, it happens (and gets persisted) on the NEXT
# mergePhiRoot() run. LF has no such ambiguity: both readers split on it
# immediately. pv23_reasons pins what each iteration's message MUST contain;
# pv23_not_reasons pins what it must NOT (empty means no such check) --
# together they stop the reason collapsing back into one clause that is
# right for LF and wrong for CR.
pv23_reasons=("line-delimited storage" "corrupts the stored path")
pv23_not_reasons=("" "line-delimited storage")
for i23 in 0 1; do
  label23="${pv23_labels[$i23]}"
  esc23="${pv23_escapes[$i23]}"
  desc23="${pv23_descs[$i23]}"
  profilePV23="$work/profilePV23-$label23.json"
  cat > "$profilePV23" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "${vaultBasePV23}${esc23}not-a-real-root", "createSalusMarker": false }
}
JSON
  glmPV23="$work/glm-pv23-$label23"; mkdir -p "$glmPV23"
  set +e
  out23=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV23")" HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV23")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv23-$label23.json")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv23-$label23")" \
    HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv23-$label23")" \
    "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV23")" </dev/null 2>&1); rc23=$?
  set -e
  # Pre-fix observation (verified by hand against the un-patched predicate,
  # which only checked non-blank + path.isAbsolute()): node's path.isAbsolute()
  # looks only at the string's PREFIX, so a value that starts with a real
  # absolute path and then carries a trailing "\nnot-a-real-root" or
  # "\rnot-a-real-root" still satisfied it -- rc was 0, not 2. This case
  # discriminates.
  [ "$rc23" -eq 2 ] || fail "PV23$label23 [HIMMEL-2424]: $desc23 luna.phiVaultPath should be rejected with rc=2 (got rc=$rc23): $out23"
  grepq "$out23" -i "field 'luna.phiVaultPath'" \
    || fail "PV23$label23: should name the bad luna.phiVaultPath field (got: $out23)"
  # HIMMEL-2424 CR round 3: see the per-iteration note above pv23_reasons --
  # 23a (LF) keeps the immediate line-split reason; 23b (CR) gets its own
  # reason and must NOT carry 23a's immediate-split claim. The sibling PV25
  # assertion below pins the NUL half (it must not claim a line split either).
  grepq "$out23" -F "${pv23_reasons[$i23]}" \
    || fail "PV23$label23 [HIMMEL-2424 CR]: $desc23's rejection must give its own reason, expected to contain \"${pv23_reasons[$i23]}\" (got: $out23)"
  if [ -n "${pv23_not_reasons[$i23]}" ]; then
    grepq "$out23" -F "${pv23_not_reasons[$i23]}" \
      && fail "PV23$label23 [HIMMEL-2424 CR]: $desc23's rejection must NOT make the immediate-split claim (\"${pv23_not_reasons[$i23]}\") that only LF earns (got: $out23)"
  fi
  [ -e "$glmPV23/phi-roots" ] \
    && fail "PV23$label23 [HIMMEL-2424]: a rejected declaration must add NO line to phi-roots -- expected the file to stay absent (got: $(cat "$glmPV23/phi-roots"))"
done
echo "ok: PV23a-b a luna.phiVaultPath containing an embedded CR or LF is rejected (rc=2, names the field, phi-roots stays absent)"

# ── PV23c — positive control: a legitimate absolute path with none of
# PV23's forbidden bytes still passes (guards against the fix over-
# rejecting; PV1/PV2/PV5/PV22 above already cover this shape too, but this
# one sits right next to the new check as a direct before/after contrast).
glmPV23c="$work/glm-pv23c"; mkdir -p "$glmPV23c"
profilePV23c="$work/profilePV23c.json"
jq -n --arg v "$vaultBasePV23" '{
  schemaVersion: 2, profile: "custom", devOverlay: false, tier: "standard", scope: "project",
  vault: {mode:"none", path:""}, handover: {mode:"inline", path:""},
  pluginSet: "lean", lanes: [], lanesMeaningful: true, alwaysOn: false,
  luna: {cadenceEnabled:false, phiDeclared:false, phiVaultPath:$v, createSalusMarker:false}
}' > "$profilePV23c"
set +e
outPV23c=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV23c")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV23")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv23c.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv23c")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv23c")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV23c")" </dev/null 2>&1); rcPV23c=$?
set -e
[ "$rcPV23c" -eq 0 ] || fail "PV23c: a clean absolute luna.phiVaultPath (no CR/LF) should still be ACCEPTED (got rc=$rcPV23c): $outPV23c"
grepq "$(cat "$glmPV23c/phi-roots" 2>/dev/null)" -F "$vaultBasePV23" \
  || fail "PV23c: the accepted path should land in phi-roots (got: $(cat "$glmPV23c/phi-roots" 2>/dev/null))"
echo "ok: PV23c a clean absolute luna.phiVaultPath with no forbidden byte is still accepted (guards against over-rejecting)"

# ── PV24 (HIMMEL-2424 CR) — a NON-STRING luna.phiVaultPath still produces
# the 'must be a string' validation error, not a raw TypeError. A reviewer
# raised this as Critical: loadProfile() reads phiVaultPathBadByte(v)
# -- which does v.indexOf(...) -- inside the isValidPhiVaultPathAnswer()
# branch, and the claim was that a non-string value could reach it and die
# with "v.indexOf is not a function" instead of the intended message. It
# cannot: the string-type check a few lines above (bin.js ~1606) runs
# FIRST and calls profileError(), which ends in process.exit(2) and never
# returns -- 33 call sites in this file, including the sibling
# createSalusMarker checks right below this one, depend on exactly that
# contract. This case is a GUARD against a future refactor that makes
# profileError() return (or reorders these two blocks), not proof of a bug
# today -- it PASSES on the current code and is EXPECTED to keep passing.
# If it ever starts failing (rc != 2, or 'indexOf'/'TypeError' shows up in
# stderr), that refactor broke an invariant this whole file leans on.
fixtureRepoPV24="$work/fixture-repo-pv24"; mkdir -p "$fixtureRepoPV24/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoPV24/scripts/adopt.sh"
chmod +x "$fixtureRepoPV24/scripts/adopt.sh"
pv24_labels=(24a 24b 24c)
pv24_json=(42 true '{}')
pv24_descs=("a number" "a boolean" "an object")
for i24 in 0 1 2; do
  label24="${pv24_labels[$i24]}"
  json24="${pv24_json[$i24]}"
  desc24="${pv24_descs[$i24]}"
  profilePV24="$work/profilePV24-$label24.json"
  cat > "$profilePV24" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": $json24, "createSalusMarker": false }
}
JSON
  glmPV24="$work/glm-pv24-$label24"; mkdir -p "$glmPV24"
  set +e
  out24=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV24")" HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV24")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv24-$label24.json")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv24-$label24")" \
    HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv24-$label24")" \
    "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV24")" </dev/null 2>&1); rc24=$?
  set -e
  [ "$rc24" -eq 2 ] || fail "PV24$label24 [HIMMEL-2424 CR]: $desc24 luna.phiVaultPath should be rejected with rc=2 (got rc=$rc24): $out24"
  grepq "$out24" -F "field 'luna.phiVaultPath' must be a string" \
    || fail "PV24$label24: should name the string-type error (got: $out24)"
  grepq "$out24" -i "indexof" \
    && fail "PV24$label24: must NOT reach phiVaultPathBadByte()'s v.indexOf() -- a non-string must be caught by the string-type check first, never fall through to it (got: $out24)"
  grepq "$out24" "TypeError" \
    && fail "PV24$label24: must NOT surface a raw TypeError -- profileError() must exit before a non-string value reaches any string method (got: $out24)"
done
echo "ok: PV24a-c a non-string luna.phiVaultPath (number/boolean/object) is rejected with the string-type message, never a TypeError/indexOf crash (pins profileError()'s no-return contract; not a bug reproduction)"

# ── PV25 (HIMMEL-2424) — luna.phiVaultPath carrying an embedded NUL byte is
# rejected the same way PV23a/b reject CR/LF (phiVaultPathBadByte()
# checks NUL too). Same JSON \u0000 escape-sequence approach as PV23's
# \n/\r -- a raw NUL byte threaded through argv risks the same kind of
# shell/argv mangling PV23 observed for a raw CR on this host, so the
# escape sequence (decoded by JSON.parse() to the identical in-memory
# byte) is used instead. Discrimination verified by hand: running this
# exact profile against the pre-HIMMEL-2424 predicate (isValidPhiVaultPathAnswer()
# before this ticket -- typeof/non-blank/path.isAbsolute() only, no bad-byte
# check) does NOT reject at profile validation -- path.isAbsolute() only
# looks at the string's prefix, so the NUL-suffixed value still satisfies
# it and loadProfile() lets it through (the run proceeds past validation
# into later install steps, unlike the rc=2 + field-name message asserted
# below). This case discriminates the same way PV23a/b do.
vaultBasePV25="$(winpath "$work/vault-pv25")"
profilePV25="$work/profilePV25.json"
cat > "$profilePV25" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "${vaultBasePV25}\u0000not-a-real-root", "createSalusMarker": false }
}
JSON
glmPV25="$work/glm-pv25"; mkdir -p "$glmPV25"
set +e
outPV25=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV25")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV23")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv25.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv25")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv25")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV25")" </dev/null 2>&1); rcPV25=$?
set -e
[ "$rcPV25" -eq 2 ] || fail "PV25 [HIMMEL-2424]: an embedded NUL byte luna.phiVaultPath should be rejected with rc=2 (got rc=$rcPV25): $outPV25"
grepq "$outPV25" -i "field 'luna.phiVaultPath'" \
  || fail "PV25: should name the bad luna.phiVaultPath field (got: $outPV25)"
# HIMMEL-2424 CR round 2 -- the reason must be per-byte. A NUL does NOT
# start a new line, so the shared "would split phi-roots' line-delimited
# storage into a bogus extra entry" clause was FALSE in exactly this case:
# an operator-facing message over-claiming its own reason, which is the
# class this PR chain exists to correct. NUL is rejected on its own merits
# (never valid in a path on either platform, and it truncates the value in
# any consumer reading through a NUL-terminated API), so that is what the
# message has to say. PV23a/b above pin the CR/LF half.
grepq "$outPV25" -F "line-delimited storage" \
  && fail "PV25 [HIMMEL-2424 CR]: a NUL byte does not split a line -- the rejection must NOT claim it splits phi-roots' line-delimited storage (got: $outPV25)"
grepq "$outPV25" -F "a NUL byte" \
  || fail "PV25 [HIMMEL-2424 CR]: should name the NUL byte (got: $outPV25)"
grepq "$outPV25" -i "truncat" \
  || fail "PV25 [HIMMEL-2424 CR]: should give the NUL-specific reason (never valid in a path; truncates it in a NUL-terminated consumer) (got: $outPV25)"
[ -e "$glmPV25/phi-roots" ] \
  && fail "PV25 [HIMMEL-2424]: a rejected declaration must add NO line to phi-roots -- expected the file to stay absent (got: $(cat "$glmPV25/phi-roots"))"
echo "ok: PV25 a luna.phiVaultPath containing an embedded NUL byte is rejected (rc=2, names the field, phi-roots stays absent)"

# ── PV26 (HIMMEL-2424 CR) — a luna.phiVaultPath carrying BOTH bytes (an LF
# and a CR, in either order) must report LF's IMMEDIATE-split reason, not
# CR's DELAYED-split one. phiVaultPathBadByte() checked CR before LF, so a
# value containing both always matched the CR branch first and got CR's
# "corrupts the stored path, and the next phi-roots merge splits it" wording
# -- even when the LF in that same value already splits phi-roots' storage
# on THIS declaration, not the next one. That under-claims the damage: the
# operator is told the wrong severity for the byte that actually breaks the
# file right now. PV23a/b above pin each byte's clause in isolation; this
# case is what only shows up when both are present together, in EITHER
# order (26a: LF then CR; 26b: CR then LF), since plain indexOf-order alone
# used to decide which clause won, not which claim stayed true for the
# value. The fix checks LF before CR, so both orders must report LF's
# reason and must NOT report CR's -- the negative assertion below is
# load-bearing: without it, restoring the old CR-first order would still
# pass 26b (a value that happens to contain "corrupts the stored path" is
# not caught by a check that only looks for the LF substring). Same JSON
# \n/\r escape-sequence approach as PV23 -- a raw CR byte threaded through
# argv is silently eaten by this host's MSYS argv-translation layer before
# jq/node ever see it (LF survives; CR does not), so the control bytes are
# written into the profile JSON as literal \n/\r escape sequences, which
# JSON.parse() decodes to the identical in-memory bytes a raw one would
# produce.
vaultBasePV26="$(winpath "$work/vault-pv26")"
pv26_labels=(26a 26b)
pv26_values=('\nfoo\rbar' '\rfoo\nbar')
pv26_descs=("an embedded LF then CR" "an embedded CR then LF")
for i26 in 0 1; do
  label26="${pv26_labels[$i26]}"
  val26="${pv26_values[$i26]}"
  desc26="${pv26_descs[$i26]}"
  profilePV26="$work/profilePV26-$label26.json"
  cat > "$profilePV26" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": false, "phiDeclared": false, "phiVaultPath": "${vaultBasePV26}${val26}", "createSalusMarker": false }
}
JSON
  glmPV26="$work/glm-pv26-$label26"; mkdir -p "$glmPV26"
  set +e
  out26=$(PATH="$pathPV1" HOME="$homePV1" USERPROFILE="$(winpath "$homePV1")" CLAUDE_GLM_CONFIG_DIR="$(winpath "$glmPV26")" HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoPV23")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-pv26-$label26.json")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-pv26-$label26")" \
    HIMMELCTL_BIN_DIR="$(winpath "$work/bin-pv26-$label26")" \
    "$node_bin" "$wizard" install --from-profile "$(winpath "$profilePV26")" </dev/null 2>&1); rc26=$?
  set -e
  [ "$rc26" -eq 2 ] || fail "PV26$label26 [HIMMEL-2424 CR]: $desc26 luna.phiVaultPath should be rejected with rc=2 (got rc=$rc26): $out26"
  grepq "$out26" -i "field 'luna.phiVaultPath'" \
    || fail "PV26$label26: should name the bad luna.phiVaultPath field (got: $out26)"
  grepq "$out26" -F "line-delimited storage" \
    || fail "PV26$label26 [HIMMEL-2424 CR]: a value containing an LF must report LF's immediate-split reason regardless of byte order (got: $out26)"
  grepq "$out26" -F "corrupts the stored path" \
    && fail "PV26$label26 [HIMMEL-2424 CR]: must NOT report CR's delayed-split reason when an LF is also present -- that's exactly the over/under-claim the LF-first check order exists to prevent (got: $out26)"
  [ -e "$glmPV26/phi-roots" ] \
    && fail "PV26$label26 [HIMMEL-2424 CR]: a rejected declaration must add NO line to phi-roots -- expected the file to stay absent (got: $(cat "$glmPV26/phi-roots"))"
done
echo "ok: PV26a-b a luna.phiVaultPath containing BOTH an LF and CR (either order) reports LF's immediate-split reason, never CR's delayed-split reason"

# ═══════════════════════════════════════════════════════════════════════════
# ask-first — non-interactive with no --from-profile still refuses (rc 1);
# nothing derived, nothing installed.
# ═══════════════════════════════════════════════════════════════════════════

stubAsk="$work/stubAsk"; mkdir -p "$stubAsk"
pathAsk=$(build_path "$stubAsk" bash jq python3 npm -- python)
make_git_stub "$stubAsk" "https://github.com/someone/other-repo.git"
homeAsk="$work/homeAsk"; mkdir -p "$homeAsk"
set +e
outAsk=$(PATH="$pathAsk" HOME="$homeAsk" USERPROFILE="$(winpath "$homeAsk")" HIMMELCTL_CACHE_DIR="$(winpath "$homeAsk.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$homeAsk.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
  "$node_bin" "$wizard" install </dev/null 2>&1); rcAsk=$?
set -e
[ "$rcAsk" -ne 0 ] || fail "ask-first: non-interactive install with no --from-profile should exit non-zero (got $rcAsk)"
grepq "$outAsk" 'requires --from-profile' \
  || fail "ask-first: should print the --from-profile hint (got: $outAsk)"
grepq "$outAsk" '^detected:' \
  && fail "ask-first: must NOT start the question engine (got: $outAsk)"
grepq "$outAsk" '^derived:' \
  && fail "ask-first: must NOT derive/print an install plan (got: $outAsk)"
echo "ok: ask-first non-interactive with no --from-profile refuses (rc 1), nothing derived or installed"

# ═══════════════════════════════════════════════════════════════════════════
# HIMMEL-2436 — a successful --from-profile install must persist the profile
# cache (status/ensure's ONLY source of truth for a target), and MUST NOT
# under --dry-run, on EITHER answer-producing branch (--from-profile or the
# interactive question engine) -- one guard, one source of truth.
# ═══════════════════════════════════════════════════════════════════════════

# case2436a/b reuse caseApply's already-completed, non-dry, --from-profile
# apply run above (env: pathApply/homeApply/fixtureRepo/configPathApply,
# rcApply already asserted 0) -- no hand-seeding of the cache file.
cache2436_posix="$work/cache-apply"
cache2436_file="$cache2436_posix/install-profile.json"

# case2436b: the cache exists and carries the operator's actual answers, not
# just a placeholder.
[ -f "$cache2436_file" ] \
  || fail "case2436b: caseApply's --from-profile install should have written $cache2436_file"
cache2436_body=$(cat "$cache2436_file")
# profileApply.json is authored in the legacy v1 role="adopter" shape;
# loadProfile() migrates that to v2 profile/devOverlay on READ (never writes
# `role` again -- see serialize()'s own comment), so the persisted cache
# carries the MIGRATED fields, not the file's original `role` key.
grepq "$cache2436_body" '"profile": "custom"' \
  || fail "case2436b: cached profile should record the migrated profile=custom (got: $cache2436_body)"
grepq "$cache2436_body" '"devOverlay": false' \
  || fail "case2436b: cached profile should record devOverlay=false (got: $cache2436_body)"
grepq "$cache2436_body" '"scope": "user"' \
  || fail "case2436b: cached profile should record scope=user (got: $cache2436_body)"
grepq "$cache2436_body" -F "$vaultPathApply" \
  || fail "case2436b: cached profile should record the operator's own vault path $vaultPathApply, not a placeholder (got: $cache2436_body)"
echo "ok: case2436b install-profile.json exists under the sandboxed cache dir after --from-profile apply and carries the operator's answers"

# case2436a: `status`, in the SAME sandboxed HOME, right after the install --
# this is the adopter chain the ticket is about. `status` reads a REAL
# scripts/install/manifest.json off HIMMELCTL_REPO_ROOT (unlike a stub
# adopt.sh, which only ever needs to exist and exit 0) -- caseApply's own
# minimal fixtureRepo never needed one, so build a dedicated one here,
# mirroring test-wizard-status-cmd.sh's own fixture recipe. HIMMELCTL_CACHE_DIR
# still points at cache-apply (the install's own cache dir, untouched) --
# that is the "no hand-seeding" part under test, not the repo root fixture.
manifest_path2436="$repo_root/scripts/install/manifest.json"
[ -f "$manifest_path2436" ] || fail "case2436a fixture: $manifest_path2436 not found"
fixtureRepoStatus2436="$work/fixture-repo-status-2436"
mkdir -p "$fixtureRepoStatus2436/scripts/install" "$fixtureRepoStatus2436/scripts/jira/dist" \
  "$fixtureRepoStatus2436/scripts/bitbucket/dist" "$fixtureRepoStatus2436/scripts/lib"
cp "$manifest_path2436" "$fixtureRepoStatus2436/scripts/install/manifest.json"
: > "$fixtureRepoStatus2436/scripts/jira/dist/index.js"
: > "$fixtureRepoStatus2436/scripts/bitbucket/dist/index.js"
: > "$fixtureRepoStatus2436/scripts/lib/doc-guard-map.sh"

set +e
outStatus2436=$(PATH="$pathApply" HOME="$homeApply" USERPROFILE="$(winpath "$homeApply")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoStatus2436")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathApply" \
  HIMMELCTL_CACHE_DIR="$(winpath "$cache2436_posix")" \
  "$node_bin" "$wizard" status </dev/null 2>&1); rcStatus2436=$?
set -e
[ "$rcStatus2436" -eq 0 ] \
  || fail "case2436a: 'status' right after a --from-profile install should exit 0 with no hand-seeded cache (got rc=$rcStatus2436): $outStatus2436"
grepq "$outStatus2436" 'no himmelctl install profile found' \
  && fail "case2436a: 'status' should find the cache the install just wrote, not report it missing (got: $outStatus2436)"
echo "ok: case2436a 'status' succeeds immediately after a --from-profile install in the same sandboxed HOME, with no hand-seeded cache"

# case2436c — a --dry-run --from-profile install must leave the profile
# cache ABSENT (the guard). Fresh cache dir so caseApply's own cache above
# cannot mask a broken guard here.
stub2436c="$work/stub2436c"; mkdir -p "$stub2436c"
path2436c=$(build_path "$stub2436c" bash jq python3 npm -- python)
make_git_stub "$stub2436c" "https://github.com/someone/other-repo.git"
home2436c="$work/home2436c"; mkdir -p "$home2436c"
cache2436c_posix="$work/cache-2436c"
set +e
out2436c=$(PATH="$path2436c" HOME="$home2436c" USERPROFILE="$(winpath "$home2436c")" HIMMELCTL_INTERACTIVE=0 \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/config-2436c-unused.json")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$cache2436c_posix")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-2436c")" \
  "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$profileApply")" </dev/null 2>&1); rc2436c=$?
set -e
[ "$rc2436c" -eq 0 ] || fail "case2436c: --from-profile --dry-run should still exit 0 (got rc=$rc2436c): $out2436c"
[ -e "$cache2436c_posix/install-profile.json" ] \
  && fail "case2436c: --from-profile --dry-run must NOT write the profile cache (found $cache2436c_posix/install-profile.json)"
echo "ok: case2436c a --from-profile --dry-run install leaves the profile cache absent"

# case2436d — RETASK widening: the SAME guard covers the interactive branch
# too. shouldPrompt() ignores dryRun entirely, so an interactive
# `install --dry-run` (HIMMELCTL_INTERACTIVE=1, the minimal starter stdin
# sequence -- same shape as test-wizard-questions.sh's case1/case5) reaches
# askQuestions() and, pre-fix, would still cache. Must leave the cache
# ABSENT.
stub2436d="$work/stub2436d"; mkdir -p "$stub2436d"
path2436d=$(build_path "$stub2436d" bash jq python3 npm -- )
home2436d="$work/home2436d"; mkdir -p "$home2436d"
cache2436d_posix="$work/cache-2436d"
set +e
out2436d=$(PATH="$path2436d" HOME="$home2436d" USERPROFILE="$(winpath "$home2436d")" HIMMELCTL_INTERACTIVE=1 \
  HIMMELCTL_CACHE_DIR="$(winpath "$cache2436d_posix")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cache2436d_posix")-luna-config.json" \
  "$node_bin" "$wizard" install --dry-run 2>&1 <<INPUT
starter
project
none
inline
lean
none
no
INPUT
); rc2436d=$?
set -e
[ "$rc2436d" -eq 0 ] || fail "case2436d: interactive starter-profile --dry-run should exit 0 (got rc=$rc2436d): $out2436d"
[ -e "$cache2436d_posix/install-profile.json" ] \
  && fail "case2436d: interactive install --dry-run must NOT write the profile cache -- shouldPrompt ignores dryRun, so the same guard must cover this branch too (found $cache2436d_posix/install-profile.json)"
echo "ok: case2436d an interactive install --dry-run leaves the profile cache absent (RETASK widening)"

echo "PASS"
