#!/usr/bin/env bash
# test-wizard-install-engine.sh — hermetic tests for
# scripts/himmelctl/lib/install-engine.js's planInstall()/runInstall()
# (HIMMEL-755 A4): the install-descriptor engine `ensure` drives to converge
# red/degraded manifest items via EXISTING shell primitives (never
# reimplemented wiring). Invokes the library directly via `node -e` +
# require — no bin.js/manifest.json involvement (planInstall/runInstall take
# plain item objects, not full manifest items, so a minimal fixture is
# enough). Mirrors sibling test-wizard-*.sh conventions: node launched by
# absolute path, winpath for node.exe's MSYS-path blindness. CR fix: every
# fixture path used inside a node -e script is passed via the ENVIRONMENT
# (exported once, read via process.env inside the script) rather than
# interpolated into the JS source string — a checkout path containing an
# apostrophe or backslash would otherwise break the inline JS on Windows
# Git Bash, macOS, or Linux alike.
#
# Covers:
#   a. planInstall order: a 6-item chain of PER-ITEM install types
#      (wire/wire/plugins/qmd/dep/build), each depending on the previous,
#      returns exactly 6 plan entries in deps[] order.
#   b. planInstall coalescing: 2 adopt-type items (one depending on the
#      other) collapse to EXACTLY 1 plan entry, tagged coalesceKey:'adopt'.
#   c. runInstall(plan, {dryRun:true}) executes NOTHING — {ran:[],
#      failed:[]} and a spy marker file (that a real invocation of the stub
#      primitive would create) is proven ABSENT afterward.
#   d/e. runInstall(plan, {dryRun:false}) against a 2-item plan (one stub
#      primitive that succeeds + writes its marker, one that exits
#      non-zero) surfaces the success in ran[] (marker now present) and the
#      failure in failed[] with a reason (fail-closed, never silent).
#   f. install-plugins.sh (the KEPT orchestrator, unchanged) at a
#      NON-default --scope project still runs its HIMMEL_RECONCILE_PLUGINS
#      lean-floor reconcile step — proving the `plugins` install type's
#      delegation to it is behavior-preserving, not a capability regression.
#   g. plugin-spec canonicalization drift check: bin.js's inline
#      FULL_PLUGIN_ENABLE table stays byte-identical to the canonical
#      scripts/machine-setup/full-plugin-enable.json `plugins` array (kept
#      inline rather than read from the file at runtime — see bin.js's own
#      comment — so this test is what actually keeps the two from drifting).
#   h. a signal-terminated primitive (r.signal set, r.status null — a real
#      OS signal kill does not reliably surface via Node's spawnSync.signal
#      field on Windows, verified empirically; a child_process.spawnSync
#      monkey-patch injects the exact shape cross-platform) lands in
#      failed[] with a reason naming the signal — NOT in ran[] (the bug: it
#      previously fell through both the r.error and r.status!==0 checks).
#   i. (CR fix) runInstall skip-after-prereq-failure: a 2-entry plan where
#      the second entry depends on the first, and the first fails — the
#      second is SKIPPED (never spawned; a spy marker proves it), landing
#      in failed[] naming the failed prerequisite, not silently run anyway.
#   j. (CR fix) coalesce merges deps (union, not first-occurrence-only):
#      adopt-a and adopt-b BOTH depend on dep-x (a third, non-coalescing
#      item) — dep-x must be ordered BEFORE the single coalesced adopt
#      entry, proving the coalesced node's graph position accounts for
#      EVERY member's deps, not just the first item coalesced.
#
# HIMMELCTL_SUDO_PASSWORD (linux dep-install) — driven with ctx.platform
# forced to 'linux'/'darwin' (buildEntry/planInstall accept a ctx.platform
# override for exactly this: the suite itself runs on Windows Git Bash and
# needs to exercise branches process.platform alone could never reach here).
#   k. HIMMELCTL_SUDO_PASSWORD set -> the plan entry passes the password on
#      STDIN (`input`) ONLY — cmd:'sudo', args:['-S','-p','','env',
#      'DEBIAN_FRONTEND=noninteractive','apt-get','install','-y',<pkg>] —
#      and the password string appears NOWHERE in cmd/args.
#   l. HIMMELCTL_SUDO_PASSWORD unset -> the fail-fast `sudo -n
#      DEBIAN_FRONTEND=noninteractive apt-get install -y <pkg>` form, no
#      `input` field at all.
#   m. runInstall()'s spawnSync call for an `input`-bearing entry, proven
#      via a child_process.spawnSync monkey-patch (a real-process stub is
#      unreliable on Windows — see the case's own comment). On THIS suite's
#      real host platform (win32), routes through job-run.ps1 (CR fix, Job
#      Object round): cmd is 'powershell', entry.cmd/entry.args travel via
#      -Command/-CommandArgsB64, and opts.input still carries the password
#      / opts.stdio is still ['pipe','inherit','inherit'] (Node pipes it
#      into POWERSHELL's stdin; job-run.ps1 relays it onward) — no secret
#      material anywhere in the captured argv, under any encoding.
#   n. the exact `DRY: ${cmd} ${args.join(' ')}` string bin.js's dry-run
#      printer builds for a password-bearing entry contains no secret
#      material (mirrors bin.js's own print line so a plan-shape change
#      that broke this would be caught here too).
#   o. (addendum) no HIMMELCTL_SUDO_PASSWORD + 2 linux dep items in ONE
#      planInstall() call -> the "no HIMMELCTL_SUDO_PASSWORD configured"
#      diagnostic prints to stderr EXACTLY ONCE (not once per item); both
#      entries still use the sudo -n fail-fast form.
#   p. (addendum) HIMMELCTL_SUDO_PASSWORD set -> the diagnostic never
#      prints, and no secret material appears in any output stream.
#   q. (CR fix) spawnSync timeout: INSTALL_TIMEOUT_SECS forced to 1s against
#      a stub primitive that sleeps 3s — the REAL Node spawnSync timeout (not
#      a monkey-patch) kills it, landing in failed[] with a "timed out after
#      1s" reason, never ran[], and the primitive is proven never to finish
#      (its own completion marker is absent).
#   r. (CR fix, SECURITY — secret leak) the child's ENVIRONMENT never
#      carries HIMMELCTL_SUDO_PASSWORD: a real (non-monkey-patched) entry
#      whose primitive targeted-probes its own environment (CR fix,
#      CodeRabbit round 16: NOT a full `env` dump, which would leak the
#      operator's own real ambient secrets into test/CI output) + echoes
#      stdin back proves the var is ABSENT (a different, unrelated env var
#      survives, proving this isn't just "the whole env is stripped"),
#      while the password STILL arrives via stdin (the sudo/stdin transport
#      from cases k/m is unaffected by the fix).
#   s. (CR fix) timeout kills the WHOLE process tree, not just the direct
#      child: a wedged primitive that backgrounds a grandchild (and records
#      its pid) is timed out at 1s — the grandchild is verified GENUINELY
#      DEAD afterward (kill -0), not merely orphaned/still running in the
#      background. Exercises the REAL mechanism for whichever platform this
#      suite actually runs on (win32's job-run.ps1 Windows Job Object,
#      verified here — see case v for the harder RE-PARENTING scenario that
#      actually discriminates it from the old taskkill /T /F; the POSIX
#      detached-process-group mechanism can't be exercised for real on a
#      Windows host — see cases t/u for a portable, deterministic proof of
#      BOTH mechanisms' exact shape via a spawnSync/process.kill
#      monkey-patch, the same technique case h/m already established).
#   t. (CR fix) process-group-kill mechanism, POSIX branch (process.platform
#      monkey-patched to 'linux'): on a monkey-patched ETIMEDOUT, runInstall
#      calls process.kill(-pid, 'SIGKILL') (the NEGATIVE pid — the whole
#      group, not just the direct child) — and the spawnOpts captured by the
#      monkey-patched spawnSync carried detached:true (required so that
#      negative-pid kill can never reach OUR OWN process group) and an env
#      with HIMMELCTL_SUDO_PASSWORD already stripped.
#   u. (CR fix, Job Object round) win32 dispatch mechanism (process.platform
#      monkey-patched to 'win32'): runInstall issues exactly ONE spawnSync
#      call — cmd:'powershell', routed through job-run.ps1, entry.cmd/
#      entry.args carried via -Command/-CommandArgsB64, NO `detached` flag —
#      and job-run.ps1's own TIMEOUT_EXIT_CODE (4217, simulated here)
#      classifies as the standard "timed out after Ns" failure, the SAME
#      shape case t proves for POSIX. Supersedes this case's PRE-Job-Object
#      shape (a second spawnSync('taskkill', ...) call), which no longer
#      exists — win32 cleanup now lives entirely inside job-run.ps1.
#   v. (CR fix, Job Object round — THE discriminating test) a genuinely
#      RE-PARENTED grandchild (backgrounded inside a `(...)` subshell that
#      exits WITHOUT waiting, so its recorded parent is already dead by the
#      time the timeout fires — exactly how a real installer's postinst/
#      daemon-spawning script behaves) is verified GENUINELY DEAD after the
#      timeout. Verified EMPIRICALLY during development that this exact
#      construction defeats the OLD taskkill /T /F mechanism (the
#      grandchild survived); job-run.ps1's Windows Job Object does not (every
#      descendant joins the SAME job at creation, independent of whether its
#      immediate parent is still alive at kill time) — see the case's own
#      comment and job-run.ps1's header for the full account.
#   w. (CR fix, codex critic round 3, IMPORTANT — the SUCCESS-path mirror
#      of case v) a primitive that exits 0 after legitimately backgrounding
#      a descendant that KEEPS RUNNING (a real Windows installer starting a
#      service/daemon/helper) must NOT have that descendant killed just
#      because job-run.ps1's own wrapper process exited successfully —
#      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE is exactly right on the timeout
#      path and exactly wrong here. Also uncovered (and fixed in the same
#      round) a SEPARATE, deeper bug this case's own comment documents in
#      full: a PowerShell nested-struct-field assignment that never
#      actually persisted, silently making KILL_ON_JOB_CLOSE inert since
#      the very first shipped version — the timeout path only ever worked
#      via the independent, unconditional TerminateJobObject() call.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
install_engine_lib="$repo_root/scripts/himmelctl/lib/install-engine.js"
install_plugins_sh="$repo_root/scripts/machine-setup/install-plugins.sh"
[ -f "$install_engine_lib" ] || { echo "FAIL: $install_engine_lib not found" >&2; exit 1; }
[ -f "$install_plugins_sh" ] || { echo "FAIL: $install_plugins_sh not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

work=$(mktemp -d)
# CR fix (CodeRabbit round 16, item 8): case w (below) deliberately leaves a
# backgrounded survivor process ALIVE past its own assertions — that's the
# whole point of the test (proving kill-on-close does NOT fire on the
# success path). SURVIVOR_PID is set once that pid is known; cleanup() kills
# it (harmless if it already exited on its own 30s sleep, or was already
# reaped by an earlier explicit kill in case w itself) BEFORE removing the
# work dir, so a passing (or a failing/aborted) run never leaks a live
# process past this script's own exit.
SURVIVOR_PID=""
cleanup() {
  if [ -n "$SURVIVOR_PID" ]; then
    kill "$SURVIVOR_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# winpath <path> — echo <path> unchanged on posix, or its Windows form on
# git-bash/MSYS/Cygwin (node.exe misresolves MSYS /tmp-style paths).
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# CR fix: exported ONCE, read via process.env inside every node -e script
# below instead of being interpolated into the JS source string.
INSTALL_ENGINE_LIB="$(winpath "$install_engine_lib")"
export INSTALL_ENGINE_LIB

# ── case a: planInstall order over a 6-item per-item-type chain ────────────
outA=$("$node_bin" -e "
const { planInstall } = require(process.env.INSTALL_ENGINE_LIB);
const items = [
  { id: 'wire-a', deps: [], install: { type: 'wire', target: 'statusline' } },
  { id: 'wire-b', deps: ['wire-a'], install: { type: 'wire', target: 'pretooluse-hooks' } },
  { id: 'plugins-a', deps: ['wire-b'], install: { type: 'plugins' } },
  { id: 'qmd-a', deps: ['plugins-a'], install: { type: 'qmd' } },
  { id: 'dep-a', deps: ['qmd-a'], install: { type: 'dep' }, probe: { type: 'dep', cmd: 'somebin' } },
  { id: 'build-a', deps: ['dep-a'], install: { type: 'build', target: 'jira-cli' } },
];
// CR fix (CodeRabbit round 17, item 3): platform PINNED, and it matters for
// more than determinism. Unpinned, ctx.platform fell through to
// process.platform -- so on a Linux runner the dep item took buildEntry's
// linux branch, which calls resolveSudoPassword() and embeds the REAL
// HIMMELCTL_SUDO_PASSWORD (ambient env, or the primary checkout's .env) as
// entry.input... which this very test then JSON.stringify's to stdout. Same
// credential-exposure class as round 16's env-dump fixture fix. 'darwin' is
// the right seam here (not 'win32'): it yields a normal brew-install entry,
// preserving the entry shape these ordering assertions read, whereas win32
// would hit an unmapped WINGET_IDS lookup and return an {unrunnable} entry
// instead. This test is about ORDER, not the dep payload.
// (NB: no backticks in this comment -- it lives inside a double-quoted
// node -e string, where the shell would treat them as command substitution
// and run them before node ever sees the script. shellcheck SC2006 caught
// exactly that here.)
const ctx = { repoRoot: '/fake/repo', scope: 'project', profile: 'core', targetPath: '/fake/target', platform: 'darwin' };
console.log(JSON.stringify(planInstall(items, ctx)));
")
echo "$outA" | jq -e '. | length == 6' >/dev/null || fail "case a: expected 6 plan entries (got: $outA)"
echo "$outA" | jq -e '[.[].id] == ["wire-a","wire-b","plugins-a","qmd-a","dep-a","build-a"]' >/dev/null \
  || fail "case a: expected the 6 entries in deps[] order (got: $(echo "$outA" | jq -c '[.[].id]'))"
echo "ok: case a — planInstall orders 6 per-item-type entries in deps[] order"

# ── case b: planInstall coalesces 2 adopt-type items to 1 entry ────────────
outB=$("$node_bin" -e "
const { planInstall } = require(process.env.INSTALL_ENGINE_LIB);
const items = [
  { id: 'adopt-a', deps: [], install: { type: 'adopt' } },
  { id: 'adopt-b', deps: ['adopt-a'], install: { type: 'adopt' } },
];
const ctx = { repoRoot: '/fake/repo', scope: 'project', profile: 'core', targetPath: '/fake/target' };
console.log(JSON.stringify(planInstall(items, ctx)));
")
echo "$outB" | jq -e '. | length == 1' >/dev/null || fail "case b: expected exactly 1 coalesced entry (got: $outB)"
echo "$outB" | jq -e '.[0].coalesceKey == "adopt"' >/dev/null || fail "case b: coalesced entry should carry coalesceKey:adopt (got: $outB)"
echo "ok: case b — 2 adopt-type items coalesce to exactly 1 plan entry"

# ── fixture repo for cases c/d/e: one succeeding stub primitive (writes a
# marker), one failing stub primitive (exits 1) ────────────────────────────
fixtureRepo="$work/repo"
mkdir -p "$fixtureRepo/scripts/lib"
markerOk="$work/marker-ok"
cat > "$fixtureRepo/scripts/lib/wire-statusline.sh" <<SH
#!/usr/bin/env bash
echo done > "$(winpath "$markerOk")"
exit 0
SH
cat > "$fixtureRepo/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
fixtureTarget="$work/target"; mkdir -p "$fixtureTarget"

FIXTURE_REPO="$(winpath "$fixtureRepo")"
FIXTURE_TARGET="$(winpath "$fixtureTarget")"
PLAN_CDE_PATH="$(winpath "$work/plan-cde.json")"
export FIXTURE_REPO FIXTURE_TARGET PLAN_CDE_PATH
"$node_bin" -e "
const { planInstall } = require(process.env.INSTALL_ENGINE_LIB);
const items = [
  { id: 'wire-ok', deps: [], install: { type: 'wire', target: 'statusline' } },
  { id: 'wire-fail', deps: [], install: { type: 'wire', target: 'pretooluse-hooks' } },
];
const ctx = { repoRoot: process.env.FIXTURE_REPO, scope: 'project', profile: 'core', targetPath: process.env.FIXTURE_TARGET };
require('fs').writeFileSync(process.env.PLAN_CDE_PATH, JSON.stringify(planInstall(items, ctx)));
"

# ── case c: --dry-run executes NOTHING (spy: marker file proven absent) ────
[ ! -f "$markerOk" ] || fail "case c setup: marker should not pre-exist"
outC=$("$node_bin" -e "
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const plan = JSON.parse(require('fs').readFileSync(process.env.PLAN_CDE_PATH, 'utf8'));
const result = runInstall(plan, { dryRun: true });
console.log(JSON.stringify(result));
")
echo "$outC" | jq -e '.ran == [] and .failed == []' >/dev/null || fail "case c: dry-run should return {ran:[],failed:[]} (got: $outC)"
[ ! -f "$markerOk" ] || fail "case c: dry-run must NOT have invoked the stub primitive (marker file exists)"
echo "ok: case c — runInstall(plan,{dryRun:true}) executes nothing; spy marker proven absent"

# ── case d/e: non-dry-run — success lands in ran[] (marker now present),
# failure lands in failed[] with a reason ──────────────────────────────────
outDE=$("$node_bin" -e "
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const plan = JSON.parse(require('fs').readFileSync(process.env.PLAN_CDE_PATH, 'utf8'));
const result = runInstall(plan, { dryRun: false });
console.log(JSON.stringify(result));
")
[ -f "$markerOk" ] || fail "case d/e: the succeeding stub primitive should have run (marker file missing)"
echo "$outDE" | jq -e '.ran | length == 1 and .[0].id == "wire-ok"' >/dev/null \
  || fail "case d/e: wire-ok should land in ran[] (got: $outDE)"
echo "$outDE" | jq -e '.failed | length == 1 and .[0].id == "wire-fail" and (.[0].reason | length > 0)' >/dev/null \
  || fail "case d/e: wire-fail should land in failed[] with a non-empty reason (got: $outDE)"
echo "ok: case d/e — a succeeding primitive lands in ran[] (marker present); a failing one lands in failed[] with a reason"

# ── case f: install-plugins.sh (kept orchestrator) at --scope project still
# runs its HIMMEL_RECONCILE_PLUGINS lean-floor reconcile ───────────────────
pluginsWork="$work/plugins-scope"
mkdir -p "$pluginsWork/.claude"
templateF="$work/template.json"
cat > "$templateF" <<'JSON'
{"extraKnownMarketplaces":{},"enabledPlugins":{"foo@bar":true}}
JSON
cat > "$pluginsWork/.claude/settings.json" <<'JSON'
{"enabledPlugins":{"foo@bar":true}}
JSON
claudeStubDir="$work/claude-stub"; mkdir -p "$claudeStubDir"
cat > "$claudeStubDir/claude" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
  echo "foo@bar"
  exit 0
fi
exit 0
SH
chmod +x "$claudeStubDir/claude"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH — case f skipped"
else
  set +e
  outF=$(cd "$pluginsWork" && PATH="$claudeStubDir:$PATH" HIMMEL_RECONCILE_PLUGINS=1 \
    bash "$install_plugins_sh" --scope project --template "$templateF" 2>&1)
  rcF=$?
  set -e
  # CR fix: a nonzero install-plugins.sh exit here is a genuine test
  # failure (the stub claude/jq preflight is fully satisfied above), not
  # something to swallow — assert success explicitly instead of `|| true`.
  [ "$rcF" -eq 0 ] || fail "case f: install-plugins.sh --scope project with HIMMEL_RECONCILE_PLUGINS=1 should exit 0 (got rc=$rcF): $outF"
  echo "$outF" | grep -q "Reconciling enabledPlugins to lean floor" \
    || fail "case f: install-plugins.sh --scope project with HIMMEL_RECONCILE_PLUGINS=1 should still run the lean-floor reconcile step (got: $outF)"
  echo "ok: case f — install-plugins.sh at a non-default --scope project still runs its lean-floor reconcile (orchestrator preserved)"
fi

# ── case g: plugin-spec canonicalization drift check ───────────────────────
wizard="$repo_root/scripts/himmelctl/bin.js"
plugin_json="$repo_root/scripts/machine-setup/full-plugin-enable.json"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
[ -f "$plugin_json" ] || { echo "FAIL: $plugin_json not found" >&2; exit 1; }
WIZARD_PATH="$(winpath "$wizard")"
PLUGIN_JSON_PATH="$(winpath "$plugin_json")"
export WIZARD_PATH PLUGIN_JSON_PATH
outG=$("$node_bin" -e "
const fs = require('fs');
const src = fs.readFileSync(process.env.WIZARD_PATH, 'utf8');
const m = src.match(/const FULL_PLUGIN_ENABLE = (\[[\s\S]*?\n\]);/);
if (!m) { console.log(JSON.stringify({ error: 'FULL_PLUGIN_ENABLE const not found in bin.js' })); process.exit(0); }
// Safe JS-literal -> JSON transform (NOT eval): the const is a plain array of
// { spec, marketplaceAdd? } object literals with single-quoted string values
// and bare (unquoted) keys — quote the two known keys, swap quote style, and
// drop the trailing comma before the closing bracket, then JSON.parse it.
const jsonish = m[1]
  .replace(/'/g, '\"')
  .replace(/\b(spec|marketplaceAdd)\b\s*:/g, '\"\$1\":')
  .replace(/,(\s*\])/g, '\$1');
const inline = JSON.parse(jsonish);
const fromFile = JSON.parse(fs.readFileSync(process.env.PLUGIN_JSON_PATH, 'utf8')).plugins;
console.log(JSON.stringify({ inline, fromFile }));
")
echo "$outG" | jq -e '.error == null' >/dev/null || fail "case g: could not extract FULL_PLUGIN_ENABLE from bin.js (got: $outG)"
echo "$outG" | jq -e '.inline == .fromFile' >/dev/null \
  || fail "case g: bin.js's inline FULL_PLUGIN_ENABLE has drifted from scripts/machine-setup/full-plugin-enable.json (got: $outG)"
echo "ok: case g — bin.js's inline FULL_PLUGIN_ENABLE stays byte-identical to the canonical full-plugin-enable.json"

# ── case h: a signal-terminated primitive lands in failed[], never ran[] ───
# child_process.spawnSync is monkey-patched to return the exact
# {status:null, signal:'SIGKILL'} shape a real signal kill produces — a
# genuine OS signal doesn't reliably surface via Node's spawnSync.signal on
# Windows (verified empirically: process.kill(pid,'SIGTERM') on a child
# process here reports signal:null, status:1), so this is the portable way
# to exercise the exact branch the bug lived in, on every platform.
outH=$("$node_bin" -e "
const cp = require('child_process');
cp.spawnSync = function () { return { status: null, signal: 'SIGKILL', error: null }; };
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const plan = [{ id: 'signal-item', type: 'wire', cmd: 'bash', args: ['-c', 'true'] }];
console.log(JSON.stringify(runInstall(plan, { dryRun: false })));
")
echo "$outH" | jq -e '.ran == []' >/dev/null || fail "case h: a signal-terminated primitive must NOT land in ran[] (got: $outH)"
echo "$outH" | jq -e '.failed | length == 1 and .[0].id == "signal-item"' >/dev/null \
  || fail "case h: a signal-terminated primitive should land in failed[] (got: $outH)"
echo "$outH" | jq -e '.failed[0].reason | test("SIGKILL")' >/dev/null \
  || fail "case h: the failure reason should name the signal (got: $outH)"
echo "ok: case h — a signal-terminated primitive lands in failed[] with a reason naming the signal, never in ran[]"

# ── case i: runInstall skip-after-prereq-failure ────────────────────────────
skipWork="$work/skip-work"; mkdir -p "$skipWork"
outI=$(cd "$skipWork" && "$node_bin" -e "
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const plan = [
  { id: 'prereq', type: 'wire', deps: [], cmd: 'bash', args: ['-c', 'exit 1'] },
  { id: 'dependent', type: 'wire', deps: ['prereq'], cmd: 'bash', args: ['-c', 'touch DEPENDENT_RAN.marker'] },
];
console.log(JSON.stringify(runInstall(plan, { dryRun: false })));
")
echo "$outI" | jq -e '.ran == []' >/dev/null || fail "case i: nothing should land in ran[] (prereq failed) (got: $outI)"
echo "$outI" | jq -e '.failed | length == 2' >/dev/null || fail "case i: expected 2 failed[] entries (got: $outI)"
echo "$outI" | jq -e '.failed[0].id == "prereq" and (.failed[0].reason | test("exited 1"))' >/dev/null \
  || fail "case i: prereq should fail with 'exited 1' (got: $outI)"
echo "$outI" | jq -e '.failed[1].id == "dependent" and (.failed[1].reason | test("skipped")) and (.failed[1].reason | test("prereq"))' >/dev/null \
  || fail "case i: dependent should be SKIPPED naming the failed prerequisite (got: $outI)"
[ ! -f "$skipWork/DEPENDENT_RAN.marker" ] || fail "case i: the dependent entry must NEVER have been spawned (marker exists)"
echo "ok: case i — a dependent entry is skipped (never spawned) after its prerequisite fails, naming it in failed[]"

# ── case j: coalesce merges deps as a UNION, not first-occurrence-only ─────
# CR fix: ONLY adopt-b depends on dep-x (adopt-a — the FIRST-seen member,
# whose own deps a "first-occurrence-only" implementation would use for the
# coalesced node's graph position — carries NO deps at all). This is the
# precise, discriminating case: the old shipped-then-buggy code would have
# passed even the original (both-depend-on-dep-x) fixture by accident,
# since adopt-a's OWN deps already included dep-x. With adopt-a deps-free,
# only a TRUE union (pulling adopt-b's dep-x in too) orders dep-x first.
outJ=$("$node_bin" -e "
const { planInstall } = require(process.env.INSTALL_ENGINE_LIB);
const items = [
  { id: 'adopt-a', deps: [], install: { type: 'adopt' } },
  { id: 'adopt-b', deps: ['dep-x'], install: { type: 'adopt' } },
  { id: 'dep-x', deps: [], install: { type: 'dep' }, probe: { type: 'dep', cmd: 'sometool' } },
];
// CR fix (CodeRabbit round 17, item 3): platform pinned to 'darwin' so the
// dep-x item cannot consume HIMMELCTL_SUDO_PASSWORD into the serialized
// plan this test prints -- see case a's own comment for the full rationale.
const ctx = { repoRoot: '/fake/repo', scope: 'project', profile: 'core', targetPath: '/fake/target', platform: 'darwin' };
console.log(JSON.stringify(planInstall(items, ctx)));
")
echo "$outJ" | jq -e '. | length == 2' >/dev/null || fail "case j: expected exactly 2 plan entries (dep-x + 1 coalesced adopt) (got: $outJ)"
echo "$outJ" | jq -e '[.[].id] == ["dep-x", "adopt-a"]' >/dev/null \
  || fail "case j: dep-x should be ordered BEFORE the coalesced adopt entry (got: $(echo "$outJ" | jq -c '[.[].id]'))"
echo "$outJ" | jq -e '.[1].coalesceKey == "adopt"' >/dev/null || fail "case j: the second entry should carry coalesceKey:adopt (got: $outJ)"
echo "$outJ" | jq -e '.[1].deps == ["dep-x"]' >/dev/null \
  || fail "case j: the coalesced entry's deps should carry dep-x (the union across BOTH coalesced members, not just the first) (got: $outJ)"
echo "ok: case j — coalescing merges deps as a union across all members; a shared prereq sorts before the coalesced entry"

# ── HIMMELCTL_SUDO_PASSWORD cases: buildEntry/planInstall driven with an
# explicit ctx.platform override so the linux/darwin branches are
# exercised deterministically on Windows Git Bash. ──────────────────────────

# ── case k: password SET -> sudo -S -p '' env ... form; the plan carries
# ONLY a non-secret marker, NEVER the credential (HIMMEL-1119 item 1).
# ctx.platform pinned to 'linux' (see case a's comment) — kept. ─────────────
outK=$(HIMMELCTL_SUDO_PASSWORD='s3cr3t-pw' "$node_bin" -e "
const { planInstall } = require(process.env.INSTALL_ENGINE_LIB);
const items = [
  { id: 'dep-x', deps: [], install: { type: 'dep' }, probe: { type: 'dep', cmd: 'sometool' } },
];
const ctx = { repoRoot: '/fake/repo-nonexistent-k', scope: 'project', profile: 'core', targetPath: '/fake/target', platform: 'linux' };
console.log(JSON.stringify(planInstall(items, ctx)));
")
echo "$outK" | jq -e '.[0].cmd == "sudo"' >/dev/null || fail "case k: cmd should be 'sudo' (got: $outK)"
echo "$outK" | jq -e '.[0].args == ["-S","-p","","env","DEBIAN_FRONTEND=noninteractive","apt-get","install","-y","sometool"]' >/dev/null \
  || fail "case k: unexpected args shape (got: $outK)"
# HIMMEL-1119 item 1: the plan no longer carries the live credential. It
# carries a NON-SECRET marker (needsSudoPassword) + repoRoot (so the exec
# path resolves the real password immediately before the spawn) — and NO
# `input` field at all (the old shape embedded the password here).
echo "$outK" | jq -e '.[0].needsSudoPassword == true' >/dev/null \
  || fail "case k: entry should carry the non-secret marker needsSudoPassword:true (got: $outK)"
echo "$outK" | jq -e '.[0].repoRoot == "/fake/repo-nonexistent-k"' >/dev/null \
  || fail "case k: entry should carry repoRoot for exec-time resolution (got: $outK)"
if echo "$outK" | jq -e '.[0] | has("input")' >/dev/null 2>&1; then
  fail "case k: the plan must NOT carry an 'input' field — the credential is resolved at exec time, never embedded in the plan (got: $outK)"
fi
# The WHOLE POINT of HIMMEL-1119 item 1: the ENTIRE returned plan object,
# JSON-serialized, contains the secret NOWHERE — not in cmd, args, input
# (gone), repoRoot, or any other field. A plan that can be freely logged /
# serialized / printed without leaking the credential. Verified to BITE: see
# the sabotage note in the commit/PR — temporarily re-attaching the password
# to the entry (the old plan-time shape) makes this assertion fail.
if echo "$outK" | grep -qF 's3cr3t-pw'; then
  fail "case k: the password must appear NOWHERE in the serialized plan object (got: $outK)"
fi
echo "ok: case k — HIMMELCTL_SUDO_PASSWORD set: the plan carries only a non-secret marker (needsSudoPassword + repoRoot); the ENTIRE serialized plan contains the secret nowhere"

# ── case l: password UNSET -> the fail-fast 'sudo -n' form, no 'input' ─────
outL=$( (unset HIMMELCTL_SUDO_PASSWORD; "$node_bin" -e "
const { planInstall } = require(process.env.INSTALL_ENGINE_LIB);
const items = [
  { id: 'dep-x', deps: [], install: { type: 'dep' }, probe: { type: 'dep', cmd: 'sometool' } },
];
const ctx = { repoRoot: '/fake/repo-nonexistent-l', scope: 'project', profile: 'core', targetPath: '/fake/target', platform: 'linux' };
console.log(JSON.stringify(planInstall(items, ctx)));
") 2>/dev/null )
echo "$outL" | jq -e '.[0].cmd == "bash"' >/dev/null || fail "case l: cmd should be 'bash' (got: $outL)"
# CR fix (CodeRabbit round 16 — Fable, injection-hardening consistency):
# 'sometool' is now passed as a bash POSITIONAL arg ($1), not interpolated
# into the -c script text (same class of fix already applied to the
# 'qmd'/'build' cases) — the array now carries a trailing
# ['himmel-dep', 'sometool'] pair instead of the tool name embedded in the
# string itself.
echo "$outL" | jq -e '.[0].args == ["-c", "sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y \"$1\"", "himmel-dep", "sometool"]' >/dev/null \
  || fail "case l: expected the sudo -n fail-fast form with 'sometool' as a positional arg (got: $outL)"
if echo "$outL" | jq -e '.[0] | has("input")' >/dev/null 2>&1; then
  fail "case l: no 'input' field should exist when no password is configured (got: $outL)"
fi
echo "ok: case l — HIMMELCTL_SUDO_PASSWORD unset: the fail-fast 'sudo -n' form, no 'input' field"

# ── case m: runInstall()'s spawnOpts for an `input`-bearing entry with
# process.platform FORCED to 'win32' — proven via a child_process.spawnSync
# MONKEY-PATCH (same technique as the existing case h signal test above),
# not a real child process. CR fix (codex critic): the platform is now
# EXPLICITLY forced (same technique case u already uses) rather than relying
# on the suite's real host happening to be Windows — the earlier shape only
# captured the powershell dispatch when run on a Windows host, silently
# testing NOTHING on macOS/Linux CI. CR fix (Job Object round): win32 now
# routes EVERY spawn through job-run.ps1 (installEngineLib's
# runHardenedSpawnWin32) instead of spawning entry.cmd directly, so the
# captured call's cmd is 'powershell', not 'sudo'. The credential transport
# itself is UNCHANGED in shape: opts.input still carries the password and
# opts.stdio is still ['pipe','inherit','inherit'] (Node pipes it into
# POWERSHELL's stdin; job-run.ps1 relays it to the wrapped command's stdin —
# see job-run.ps1's own header for why it's relayed rather than passed as a
# -InputTextB64 argv value, an EARLIER design caught and reverted for being
# ps-visible). entry.cmd/entry.args (never secret) travel via
# -Command/-CommandArgsB64 in the captured powershell argv, decoded here and
# asserted against case k's real buildEntry shape — while the password
# appears NOWHERE in that argv, under ANY encoding. ────────────────────────
outM=$(HIMMELCTL_SUDO_PASSWORD='m-secret-pw' "$node_bin" -e "
const cp = require('child_process');
// CR fix (codex critic): FORCE the win32 dispatch path — same
// process.platform monkey-patch technique case u already uses (this is
// the SAME portability convention as ctx.platform in cases k/l, applied
// here since runInstall has no ctx param of its own). Without this, case
// m only captured the powershell dispatch when the REAL host happened to
// be Windows — silently testing NOTHING on macOS/Linux CI. Restored
// afterward so nothing later in this script (there's nothing today, but
// the discipline matters for whoever extends this case next) observes a
// stale platform value.
const originalPlatform = process.platform;
Object.defineProperty(process, 'platform', { value: 'win32', configurable: true });
let captured = null;
cp.spawnSync = function (cmd, args, opts) {
  captured = { cmd, args, opts };
  return { status: 0, signal: null, error: null };
};
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
// HIMMEL-1119 item 1: the entry now carries ONLY the non-secret marker
// (needsSudoPassword + repoRoot) — NO 'input' field. runHardenedSpawn
// resolves the real credential from HIMMELCTL_SUDO_PASSWORD (set in this
// process's env, above) immediately before the spawn and feeds it to the
// child's stdin — the SAME transport this case always proved (opts.input
// carries the password, opts.stdio is ['pipe','inherit','inherit']), now
// driven through the ACTUAL exec-time resolution path rather than a
// hand-placed input value. SECRET is derived from the same env var so the
// assertions below pin the exact value the exec path must reconstruct.
const SECRET = process.env.HIMMELCTL_SUDO_PASSWORD + '\\n';
const plan = [
  { id: 'dep-x', type: 'dep', cmd: 'sudo',
    args: ['-S', '-p', '', 'env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', 'sometool'],
    needsSudoPassword: true,
    repoRoot: '/fake/repo-nonexistent-m' },
];
const result = runInstall(plan, { dryRun: false });
Object.defineProperty(process, 'platform', { value: originalPlatform, configurable: true });
const b64Idx = captured.args.indexOf('-CommandArgsB64');
const decodedCommandArgs = JSON.parse(Buffer.from(captured.args[b64Idx + 1], 'base64').toString('utf8'));
console.log(JSON.stringify({ result, captured, decodedCommandArgs, secretB64: Buffer.from(SECRET).toString('base64') }));
")
echo "$outM" | jq -e '.result.ran | length == 1 and .[0].id == "dep-x"' >/dev/null || fail "case m: dep-x should land in ran[] (got: $outM)"
echo "$outM" | jq -e '.captured.cmd == "powershell"' >/dev/null || fail "case m: spawnSync should route win32 through cmd:'powershell' (job-run.ps1) (got: $outM)"
echo "$outM" | jq -e '.captured.args | any(.[]; contains("job-run.ps1"))' >/dev/null \
  || fail "case m: the powershell argv should reference job-run.ps1 via -File (got: $outM)"
# CR fix (codex critic): without -ExecutionPolicy Bypass, a machine at the
# DEFAULT Windows policy (client: Restricted; server: RemoteSigned) refuses
# to load job-run.ps1 at all — EVERY win32 install/unwire would fail before
# the wrapper even started. This dev box's LocalMachine=Unrestricted policy
# masked it; only an argv-shape assertion (not the real host's policy, which
# a hermetic test can't flip) catches a regression here.
echo "$outM" | jq -e '.captured.args | index("-ExecutionPolicy") != null' >/dev/null \
  || fail "case m: -ExecutionPolicy must be present (got: $outM)"
echo "$outM" | jq -e '(.captured.args | index("-ExecutionPolicy")) as $i | .captured.args[$i+1] == "Bypass"' >/dev/null \
  || fail "case m: -ExecutionPolicy must be 'Bypass' (process-scoped, no machine/user policy change, no prompt) (got: $outM)"
echo "$outM" | jq -e '.captured.args | index("-NoProfile") != null' >/dev/null \
  || fail "case m: -NoProfile must still be present (got: $outM)"
echo "$outM" | jq -e '(.captured.args | index("-Command")) as $i | .captured.args[$i+1] == "sudo"' >/dev/null \
  || fail "case m: -Command should carry entry.cmd ('sudo') (got: $outM)"
echo "$outM" | jq -e '.decodedCommandArgs == ["-S","-p","","env","DEBIAN_FRONTEND=noninteractive","apt-get","install","-y","sometool"]' >/dev/null \
  || fail "case m: -CommandArgsB64 should decode to entry.args, matching case k's real shape (got: $outM)"
echo "$outM" | jq -e '.captured.args | index("-HasInput") != null' >/dev/null \
  || fail "case m: -HasInput should be present for an input-bearing entry (got: $outM)"
echo "$outM" | jq -e '.captured.opts.input == "m-secret-pw\n"' >/dev/null \
  || fail "case m: spawnSync's opts.input should carry the password (got: $outM)"
echo "$outM" | jq -e '.captured.opts.stdio == ["pipe","inherit","inherit"]' >/dev/null \
  || fail "case m: spawnSync's opts.stdio should be ['pipe','inherit','inherit'] for an input-bearing entry (got: $outM)"
if echo "$outM" | jq -e '.captured.args | join(" ") | contains("m-secret-pw")' >/dev/null 2>&1; then
  fail "case m: the password must NEVER appear in the captured powershell argv, under any encoding (got: $outM)"
fi
if echo "$outM" | jq -e '.captured.cmd | contains("m-secret-pw")' >/dev/null 2>&1; then
  fail "case m: the password must NEVER appear in the captured cmd (got: $outM)"
fi
# HIMMEL-1119 item 2: the two assertions above reject only the PLAINTEXT
# secret, yet this case's whole claim is "nowhere in that argv, under ANY
# encoding" — and job-run.ps1's argv interface is base64+JSON. A revived
# -InputTextB64 (the EARLIER design reverted for being ps-visible — see
# job-run.ps1's header) would carry base64(SECRET) verbatim in the argv and
# sail straight past a plaintext scan. Verified to BITE: injecting an
# -InputTextB64 pair leaves every other assertion in this case GREEN and
# fails only here.
# The other shape — entry.input leaking into entry.args — needs no assertion
# of its own: it rides -CommandArgsB64, and the exact-equality check above
# ('-CommandArgsB64 should decode to entry.args') already pins the decoded
# array, so any extra element fails there first (confirmed empirically; a
# decoded-payload scan added here proved unfirable and was removed).
if echo "$outM" | jq -e '.secretB64 as $b64 | .captured.args | join(" ") | contains($b64)' >/dev/null 2>&1; then
  fail "case m: the password's BASE64 must NEVER appear in the captured powershell argv (a revived -InputTextB64-style argv value would be ps-visible) (got: $outM)"
fi
echo "ok: case m — runInstall() on win32 routes an input-bearing entry through job-run.ps1, piping the password to POWERSHELL's stdin (never job-run.ps1's argv, under any encoding)"

# ── case n: the exact DRY: print string (mirrors bin.js's own print line)
# contains no secret material ───────────────────────────────────────────────
outN=$(HIMMELCTL_SUDO_PASSWORD='n-secret-pw' "$node_bin" -e "
const { planInstall } = require(process.env.INSTALL_ENGINE_LIB);
const items = [
  { id: 'dep-x', deps: [], install: { type: 'dep' }, probe: { type: 'dep', cmd: 'sometool' } },
];
const ctx = { repoRoot: '/fake/repo-nonexistent-n', scope: 'project', profile: 'core', targetPath: '/fake/target', platform: 'linux' };
const p = planInstall(items, ctx)[0];
console.log(\`DRY: \${p.cmd} \${p.args.join(' ')}\`);
")
if echo "$outN" | grep -qF 'n-secret-pw'; then
  fail "case n: the DRY: print line leaked the password (got: $outN)"
fi
echo "$outN" | grep -qF 'DRY: sudo -S -p' || fail "case n: expected the DRY line to show the sudo -S -p form (got: $outN)"
echo "$outN" | grep -qF 'apt-get install -y sometool' || fail "case n: expected the DRY line to show the apt-get install shape (got: $outN)"
echo "ok: case n — the DRY: print line for a password-bearing entry contains no secret material"

# ── case o (addendum): no password + 2 linux dep items -> the diagnostic
# prints EXACTLY ONCE (not per item); both entries still use sudo -n ───────
stderrLogO="$work/stderr-o.txt"
outO=$( (unset HIMMELCTL_SUDO_PASSWORD; "$node_bin" -e "
const { planInstall } = require(process.env.INSTALL_ENGINE_LIB);
const items = [
  { id: 'dep-x', deps: [], install: { type: 'dep' }, probe: { type: 'dep', cmd: 'toolone' } },
  { id: 'dep-y', deps: [], install: { type: 'dep' }, probe: { type: 'dep', cmd: 'tooltwo' } },
];
const ctx = { repoRoot: '/fake/repo-nonexistent-o', scope: 'project', profile: 'core', targetPath: '/fake/target', platform: 'linux' };
console.log(JSON.stringify(planInstall(items, ctx)));
") 2>"$stderrLogO" )
echo "$outO" | jq -e '. | length == 2' >/dev/null || fail "case o: expected 2 plan entries (got: $outO)"
diagCountO=$(grep -c 'no HIMMELCTL_SUDO_PASSWORD configured' "$stderrLogO" || true)
[ "$diagCountO" -eq 1 ] || fail "case o: the diagnostic should print EXACTLY once for 2 linux dep items (got $diagCountO); stderr: $(cat "$stderrLogO")"
echo "$outO" | jq -e '.[0].cmd == "bash" and .[1].cmd == "bash"' >/dev/null \
  || fail "case o: both entries should still use the sudo -n fail-fast form (got: $outO)"
echo "ok: case o — no HIMMELCTL_SUDO_PASSWORD + 2 linux dep items: the diagnostic prints exactly once; both entries use sudo -n"

# ── case p (addendum): password SET -> the diagnostic never prints, and
# NOTHING is written to real stdout/stderr (the console output streams a
# real `ensure` run would surface to the operator/logs) — the resulting
# plan is written to a FILE for structural inspection instead of
# console.log'd, so this test never confuses its own data transport with a
# genuine product-code leak channel. HIMMEL-1119 item 1: the plan no longer
# carries the credential at all (only the non-secret marker), so this case
# now ALSO asserts the secret appears NOWHERE in the serialized plan file —
# the same guarantee case k proves on the in-memory plan, here on the
# file-written form a real handover/log path would consume. ────────────────
stderrLogP="$work/stderr-p.txt"
stdoutLogP="$work/stdout-p.txt"
planOutP="$work/plan-out-p.json"
HIMMELCTL_SUDO_PASSWORD='p-secret-pw' PLAN_OUT_P="$(winpath "$planOutP")" "$node_bin" -e "
const { planInstall } = require(process.env.INSTALL_ENGINE_LIB);
const items = [
  { id: 'dep-x', deps: [], install: { type: 'dep' }, probe: { type: 'dep', cmd: 'toolone' } },
];
const ctx = { repoRoot: '/fake/repo-nonexistent-p', scope: 'project', profile: 'core', targetPath: '/fake/target', platform: 'linux' };
const plan = planInstall(items, ctx);
require('fs').writeFileSync(process.env.PLAN_OUT_P, JSON.stringify(plan));
" >"$stdoutLogP" 2>"$stderrLogP"
[ ! -s "$stderrLogP" ] || fail "case p: no diagnostic (or any stderr output) expected when the password IS configured (got: $(cat "$stderrLogP"))"
[ ! -s "$stdoutLogP" ] || fail "case p: no stdout output expected — the plan is written to a file, never console.log'd (got: $(cat "$stdoutLogP"))"
outP=$(cat "$planOutP")
# HIMMEL-1119 item 1: the written plan carries ONLY the non-secret marker —
# not the credential. Assert the marker shape, that NO `input` field exists,
# AND that the secret appears nowhere in the serialized plan file.
echo "$outP" | jq -e '.[0].cmd == "sudo" and .[0].needsSudoPassword == true' >/dev/null \
  || fail "case p: expected the sudo-with-password marker shape in the written plan file (got: $outP)"
if echo "$outP" | jq -e '.[0] | has("input")' >/dev/null 2>&1; then
  fail "case p: the written plan must NOT carry an 'input' field (got: $outP)"
fi
if echo "$outP" | grep -qF 'p-secret-pw'; then
  fail "case p: the password must appear NOWHERE in the serialized plan file (got: $outP)"
fi
echo "ok: case p — HIMMELCTL_SUDO_PASSWORD set: no diagnostic printed, no product-code output on stdout/stderr, and the plan file carries no secret"

# ── case q: spawnSync timeout — a wedged primitive lands in failed[] with a
# "timed out after Ns" reason, never ran[]. Uses REAL spawnSync (no
# monkey-patch) with INSTALL_TIMEOUT_SECS forced to 1s against a stub
# primitive that sleeps 3s — exercises Node's genuine ETIMEDOUT+SIGKILL
# behavior, not just the shape (case h/m already cover the monkey-patch
# technique for the signal/input branches).
timeoutWork="$work/timeout-work"; mkdir -p "$timeoutWork"
outQ=$(cd "$timeoutWork" && INSTALL_TIMEOUT_SECS=1 "$node_bin" -e "
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const plan = [
  { id: 'wedged', type: 'wire', deps: [], cmd: 'bash', args: ['-c', 'sleep 3; touch WEDGED_FINISHED.marker'] },
];
console.log(JSON.stringify(runInstall(plan, { dryRun: false })));
")
echo "$outQ" | jq -e '.ran == []' >/dev/null || fail "case q: a timed-out primitive must NOT land in ran[] (got: $outQ)"
echo "$outQ" | jq -e '.failed | length == 1 and .[0].id == "wedged"' >/dev/null \
  || fail "case q: the timed-out primitive should land in failed[] (got: $outQ)"
echo "$outQ" | jq -e '.failed[0].reason | test("timed out after 1s")' >/dev/null \
  || fail "case q: the failure reason should read 'timed out after 1s' (got: $outQ)"
[ ! -f "$timeoutWork/WEDGED_FINISHED.marker" ] || fail "case q: the wedged primitive must have been killed before completing (marker exists)"
echo "ok: case q — a spawnSync call exceeding INSTALL_TIMEOUT_SECS lands in failed[] with a 'timed out after Ns' reason, never ran[], and is actually killed before finishing"

# ── case r (CR fix, SECURITY — secret leak): HIMMELCTL_SUDO_PASSWORD never
# reaches the child's ENVIRONMENT — only stdin. A real (non-monkey-patched)
# entry whose primitive proves: the var is ABSENT from the child's own
# environment, a DIFFERENT unrelated env var survives (proves this isn't
# "the whole env got wiped"), and the password STILL arrives via stdin (the
# existing case k/m transport is unaffected by the fix). Two DISTINCT
# marker strings are used for the env-var value vs. the stdin payload so a
# leak via either channel is unambiguous about which one failed.
#
# CR fix (CodeRabbit round 16, MAJOR — secret exposure in OUR test): the
# primitive used to `env` (a FULL dump of its own environment) then `cat`
# stdin — on a real operator's machine, "its own environment" is whatever
# ambient secrets happen to be in the shell that launched
# scripts/test-adopt.sh, printed straight into test/CI output. Replaced
# with `printenv <name>` calls targeting ONLY the two vars this case
# actually checks — a presence-only probe for HIMMELCTL_SUDO_PASSWORD
# (never its value, even if a future bug reintroduces it into the env) and
# the value of the synthetic, test-owned OTHER_MARKER_R. Deliberately
# avoids `$VAR`/`"..."` shell syntax inside this one-liner — it's a JS
# single-quoted string INSIDE a bash double-quoted `node -e` argument
# (see this file's own STATE_LIB_PATH/MANIFEST_PATH convention elsewhere
# for the same "no $ or unescaped quotes across a nested-string boundary"
# lesson) — `printenv NAME` needs neither, so nothing to escape. ──────────
rWork="$work/env-scrub-work"; mkdir -p "$rWork"
outR=$(cd "$rWork" && HIMMELCTL_SUDO_PASSWORD='r-env-secret' OTHER_MARKER_R='should-survive-r' "$node_bin" -e "
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const probeScript = 'echo -n OTHER_MARKER_R=; printenv OTHER_MARKER_R || echo; if printenv HIMMELCTL_SUDO_PASSWORD >/dev/null 2>&1; then echo HIMMELCTL_SUDO_PASSWORD_PRESENT=yes; else echo HIMMELCTL_SUDO_PASSWORD_PRESENT=no; fi; cat';
const plan = [
  { id: 'env-dump', type: 'dep', cmd: 'bash', args: ['-c', probeScript], input: 'r-stdin-password\n' },
];
const result = runInstall(plan, { dryRun: false });
console.log('RESULT_JSON:' + JSON.stringify(result));
")
echo "$outR" | grep -qF 'OTHER_MARKER_R=should-survive-r' \
  || fail "case r: an unrelated env var should survive into the child's env (got: $outR)"
echo "$outR" | grep -qF 'HIMMELCTL_SUDO_PASSWORD_PRESENT=no' \
  || fail "case r: HIMMELCTL_SUDO_PASSWORD must be ABSENT from the child's environment (got: $outR)"
if echo "$outR" | grep -qF 'r-env-secret'; then
  fail "case r: the password VALUE must never appear anywhere in the child's output (got: $outR)"
fi
echo "$outR" | grep -qF 'r-stdin-password' \
  || fail "case r: the password must STILL arrive via stdin (cat should have echoed it back) (got: $outR)"
resultLineR=$(echo "$outR" | grep '^RESULT_JSON:')
jsonR=${resultLineR#RESULT_JSON:}
echo "$jsonR" | jq -e '.ran | length == 1 and .[0].id == "env-dump"' >/dev/null \
  || fail "case r: the env-dump primitive should have run successfully (got: $jsonR)"
echo "ok: case r — HIMMELCTL_SUDO_PASSWORD is absent from the child's environment (an unrelated var survives) while still arriving via stdin"

# ── case s (CR fix): a timeout kills the WHOLE process tree, not just the
# direct child. A wedged primitive backgrounds a grandchild and records its
# pid to a file; after the 1s timeout fires, the grandchild is verified
# GENUINELY DEAD (kill -0), not merely orphaned/still running. This exercises
# the REAL mechanism for whichever platform this suite is actually running
# on — cases t/u below prove the exact shape of BOTH platforms' mechanisms
# deterministically via monkey-patch (this host can only exercise one for
# real). ─────────────────────────────────────────────────────────────────
treeWork="$work/tree-work"; mkdir -p "$treeWork"
wedgedTreeSh="$treeWork/wedged-tree.sh"
cat > "$wedgedTreeSh" <<'SH'
#!/usr/bin/env bash
d="$(dirname "$0")"
sleep 30 &
echo $! > "$d/grandchild.pid"
wait
SH
WEDGED_TREE_SH="$wedgedTreeSh"
export WEDGED_TREE_SH
outS=$(cd "$treeWork" && INSTALL_TIMEOUT_SECS=1 "$node_bin" -e "
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const plan = [
  { id: 'wedged-tree', type: 'wire', deps: [], cmd: 'bash', args: [process.env.WEDGED_TREE_SH] },
];
console.log(JSON.stringify(runInstall(plan, { dryRun: false })));
")
echo "$outS" | jq -e '.ran == []' >/dev/null || fail "case s: a timed-out primitive must NOT land in ran[] (got: $outS)"
echo "$outS" | jq -e '.failed | length == 1 and .[0].id == "wedged-tree"' >/dev/null \
  || fail "case s: the timed-out primitive should land in failed[] (got: $outS)"
grandchildPidFile="$treeWork/grandchild.pid"
[ -f "$grandchildPidFile" ] || fail "case s: the grandchild's pid file was never written — it never even started before the timeout fired"
grandchildPid=$(cat "$grandchildPidFile")
# CR fix (flake): poll instead of a fixed `sleep 1` — signal delivery/
# process teardown is async, and a busy host can take longer than 1s to
# actually reap the process, which would false-fail a fixed-sleep check.
# Re-checks liveness every 100ms for up to 5s; the assertion itself stays
# STRICT (genuinely dead, not merely unchecked/assumed) — this only avoids
# racing the OS's own reaper, never loosens what's being proven.
grandchildDead=0
# CR fix (portability): a bash arithmetic loop instead of `seq` — same 50
# iterations, same kill -0 check, same break/sleep timing; `seq` is an
# external binary not guaranteed present on every POSIX host this suite
# might run on, where a C-style for-loop is a bash builtin.
for ((_i = 0; _i < 50; _i++)); do
  if ! kill -0 "$grandchildPid" 2>/dev/null; then
    grandchildDead=1
    break
  fi
  sleep 0.1
done
[ "$grandchildDead" -eq 1 ] || fail "case s: the grandchild (pid $grandchildPid) must be dead after a timeout kills the whole process tree, but it is still running (waited 5s)"
echo "ok: case s — a timeout kills the WHOLE process tree on this host's real platform; a backgrounded grandchild is verified dead, not merely orphaned"

# ── case t (CR fix): process-group-kill mechanism, POSIX branch —
# process.platform monkey-patched to 'linux' (same portability technique as
# ctx.platform in cases k/l, applied here since runInstall has no ctx param
# of its own) + a child_process.spawnSync monkey-patch (same technique as
# case h/m) simulating an ETIMEDOUT with a known pid. Proves: process.kill
# is called with the NEGATIVE pid (the whole process group, not just the
# direct child) + 'SIGKILL', the spawnOpts captured detached:true (required
# so the negative-pid kill can never reach OUR OWN process group), and the
# captured env already had HIMMELCTL_SUDO_PASSWORD stripped. ─────────────
outT=$(HIMMELCTL_SUDO_PASSWORD='t-secret-mech' "$node_bin" -e "
const cp = require('child_process');
Object.defineProperty(process, 'platform', { value: 'linux', configurable: true });
let captured = null;
cp.spawnSync = function (cmd, args, opts) {
  captured = { cmd, args, opts };
  return { pid: 4242, status: null, signal: 'SIGKILL', error: { code: 'ETIMEDOUT', message: 'spawnSync bash ETIMEDOUT' } };
};
const killCalls = [];
process.kill = function (pid, sig) { killCalls.push({ pid, sig }); return true; };
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const plan = [ { id: 'wedged-posix', type: 'dep', cmd: 'bash', args: ['-c', 'sleep 999'] } ];
const result = runInstall(plan, { dryRun: false });
console.log(JSON.stringify({
  result,
  detached: captured.opts.detached === true,
  envHasPassword: Object.prototype.hasOwnProperty.call(captured.opts.env || {}, 'HIMMELCTL_SUDO_PASSWORD'),
  killCalls,
}));
")
echo "$outT" | jq -e '.result.failed | length == 1 and .[0].id == "wedged-posix" and (.[0].reason | test("timed out after"))' >/dev/null \
  || fail "case t: expected a timeout failure entry (got: $outT)"
echo "$outT" | jq -e '.detached == true' >/dev/null \
  || fail "case t: spawnOpts.detached should be true on the (simulated) POSIX branch (got: $outT)"
echo "$outT" | jq -e '.envHasPassword == false' >/dev/null \
  || fail "case t: HIMMELCTL_SUDO_PASSWORD must be stripped from the child env (got: $outT)"
echo "$outT" | jq -e '.killCalls | length == 1 and .[0].pid == -4242 and .[0].sig == "SIGKILL"' >/dev/null \
  || fail "case t: expected process.kill(-4242, 'SIGKILL') — the NEGATIVE pid (whole process group) (got: $outT)"
echo "ok: case t — POSIX (simulated) timeout-cleanup: process.kill(-pid,'SIGKILL') on a detached:true child, password stripped from env"

# ── case u (CR fix, Job Object round): win32 dispatch mechanism —
# process.platform monkey-patched to 'win32'. CR fix: the PREVIOUS win32
# mechanism (direct spawnSync + a SECOND spawnSync('taskkill', ...) call on
# ETIMEDOUT) is GONE — win32 now issues exactly ONE spawnSync call, routing
# through job-run.ps1 (a Windows Job Object owns the whole spawn+timeout+
# tree-kill lifecycle internally — see job-run.ps1's own header and
# install-engine.js's runHardenedSpawnWin32 for why: taskkill's tree-walk
# can miss a re-parented descendant, verified empirically during
# development). Proves: the single captured call routes through powershell/
# job-run.ps1 with entry.cmd/entry.args correctly encoded (-Command,
# -CommandArgsB64), carries NO `detached` flag (POSIX-only), the captured
# env has the password stripped, and — when that call's result simulates
# job-run.ps1's OWN internal timeout signal (status===4217, its
# $TIMEOUT_EXIT_CODE) — runInstall classifies it as a timeout with the
# standard "timed out after Ns" reason, the SAME shape case t proves for
# the POSIX mechanism. ─────────────────────────────────────────────────────
outU=$(HIMMELCTL_SUDO_PASSWORD='u-secret-mech' "$node_bin" -e "
const cp = require('child_process');
Object.defineProperty(process, 'platform', { value: 'win32', configurable: true });
let callCount = 0;
let captured = null;
cp.spawnSync = function (cmd, args, opts) {
  callCount++;
  captured = { cmd, args, opts };
  return { status: 4217, signal: null, error: null };
};
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const plan = [ { id: 'wedged-win', type: 'dep', cmd: 'bash', args: ['-c', 'sleep 999'] } ];
const result = runInstall(plan, { dryRun: false });
const b64Idx = captured.args.indexOf('-CommandArgsB64');
const decodedCommandArgs = JSON.parse(Buffer.from(captured.args[b64Idx + 1], 'base64').toString('utf8'));
console.log(JSON.stringify({
  result,
  callCount,
  cmd: captured.cmd,
  usesJobRun: captured.args.some((a) => a.includes('job-run.ps1')),
  usesExecutionPolicyBypass: (() => {
    const i = captured.args.indexOf('-ExecutionPolicy');
    return i !== -1 && captured.args[i + 1] === 'Bypass';
  })(),
  decodedCommandArgs,
  detached: captured.opts.detached === true,
  envHasPassword: Object.prototype.hasOwnProperty.call(captured.opts.env || {}, 'HIMMELCTL_SUDO_PASSWORD'),
}));
")
echo "$outU" | jq -e '.callCount == 1' >/dev/null \
  || fail "case u: win32 should issue exactly ONE spawnSync call (job-run.ps1 owns cleanup internally, no separate taskkill call) (got: $outU)"
echo "$outU" | jq -e '.cmd == "powershell"' >/dev/null \
  || fail "case u: win32 should route through cmd:'powershell' (got: $outU)"
echo "$outU" | jq -e '.usesJobRun == true' >/dev/null \
  || fail "case u: the powershell argv should reference job-run.ps1 (got: $outU)"
echo "$outU" | jq -e '.usesExecutionPolicyBypass == true' >/dev/null \
  || fail "case u: -ExecutionPolicy Bypass must be present — without it a default-policy machine (Restricted/RemoteSigned) refuses to load job-run.ps1 at all (got: $outU)"
echo "$outU" | jq -e '.decodedCommandArgs == ["-c","sleep 999"]' >/dev/null \
  || fail "case u: -CommandArgsB64 should decode to entry.args (got: $outU)"
echo "$outU" | jq -e '.detached == false' >/dev/null \
  || fail "case u: spawnOpts.detached must NOT be set on win32 (POSIX-only) (got: $outU)"
echo "$outU" | jq -e '.envHasPassword == false' >/dev/null \
  || fail "case u: HIMMELCTL_SUDO_PASSWORD must be stripped from the captured env (got: $outU)"
echo "$outU" | jq -e '.result.failed | length == 1 and .[0].id == "wedged-win" and (.[0].reason | test("timed out after"))' >/dev/null \
  || fail "case u: job-run.ps1's own TIMEOUT_EXIT_CODE (4217) should classify as a timeout failure (got: $outU)"
echo "ok: case u — win32 routes through a SINGLE job-run.ps1 call (Job Object owns tree-kill internally); its own timeout exit code classifies as a timeout, password stripped from env, no detached flag"

# ── case v (CR fix, Job Object round — THE discriminating test): a
# RE-PARENTING grandchild is verified genuinely dead after a timeout. Case
# s's own wedged-tree.sh backgrounds a grandchild and then `wait`s in the
# SAME script — the direct child (bash) stays ALIVE the whole time, so
# EITHER mechanism (the old taskkill /T /F OR a Job Object) can find the
# grandchild via a live, unbroken parent chain; it does not discriminate
# between them. THIS case instead backgrounds the grandchild inside a
# `(...)` SUBSHELL that exits WITHOUT waiting — the subshell (the
# grandchild's recorded parent) is dead within milliseconds, "re-parenting"
# the grandchild exactly like a real installer's postinst/daemon-spawning
# script does — while bash itself keeps running in the foreground (standing
# in for the installer still legitimately working) until timed out.
#
# Verified EMPIRICALLY during development (not just asserted here) that
# this exact construction defeats the OLD `taskkill /PID <pid> /T /F`
# mechanism: run directly against Node's spawnSync + a taskkill cleanup (the
# shape install-engine.js used before this round), the grandchild was left
# running after the timeout fired — taskkill's tree-walk, built from a
# process snapshot at KILL TIME, could not find it once its recorded parent
# had already exited. Run through job-run.ps1's Windows Job Object instead
# (every descendant automatically joins the SAME job at creation, so
# lineage staying "live" at kill time is irrelevant), the grandchild is
# genuinely dead. This case proves the LATTER against the CURRENT code;
# the former was the actual reproduction that justified building the Job
# Object shim in the first place — see job-run.ps1's own header. ──────────
reparentWork="$work/reparent-work"; mkdir -p "$reparentWork"
wedgedReparentSh="$reparentWork/wedged-reparent.sh"
cat > "$wedgedReparentSh" <<'SH'
#!/usr/bin/env bash
d="$(dirname "$0")"
(sleep 30 & echo $! > "$d/grandchild-reparent.pid")
sleep 30
SH
WEDGED_REPARENT_SH="$wedgedReparentSh"
export WEDGED_REPARENT_SH
outV=$(cd "$reparentWork" && INSTALL_TIMEOUT_SECS=2 "$node_bin" -e "
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const plan = [
  { id: 'wedged-reparent', type: 'wire', deps: [], cmd: 'bash', args: [process.env.WEDGED_REPARENT_SH] },
];
console.log(JSON.stringify(runInstall(plan, { dryRun: false })));
")
echo "$outV" | jq -e '.ran == []' >/dev/null || fail "case v: a timed-out primitive must NOT land in ran[] (got: $outV)"
echo "$outV" | jq -e '.failed | length == 1 and .[0].id == "wedged-reparent" and (.[0].reason | test("timed out after"))' >/dev/null \
  || fail "case v: the timed-out primitive should land in failed[] naming the timeout (got: $outV)"
grandchildReparentPidFile="$reparentWork/grandchild-reparent.pid"
[ -f "$grandchildReparentPidFile" ] || fail "case v: the grandchild's pid file was never written — it never even started before the timeout fired"
grandchildReparentPid=$(cat "$grandchildReparentPidFile")
# Poll, not a fixed sleep — same reasoning as case s. CR fix (portability):
# a bash arithmetic loop instead of `seq`, same as case s's own fix.
grandchildReparentDead=0
for ((_i = 0; _i < 50; _i++)); do
  if ! kill -0 "$grandchildReparentPid" 2>/dev/null; then
    grandchildReparentDead=1
    break
  fi
  sleep 0.1
done
[ "$grandchildReparentDead" -eq 1 ] || fail "case v: the RE-PARENTED grandchild (pid $grandchildReparentPid) must be dead after the timeout kills the whole tree, but it is still running (waited 5s) — this is the exact scenario the old taskkill /T /F mechanism was verified to miss"
echo "ok: case v — a RE-PARENTED grandchild (its own parent already exited before the timeout fired) is verified genuinely dead — the discriminating scenario that defeats a plain process-tree-walk but not a Job Object"

# ── case w (CR fix, codex critic round 3, IMPORTANT — the SUCCESS-path
# mirror of case v): a primitive that exits 0 after LEGITIMATELY
# backgrounding a descendant that KEEPS RUNNING (a stand-in for a real
# Windows installer starting a service/daemon/background helper, a
# perfectly normal thing for a package installer to do) must NOT have that
# descendant killed just because the wrapper's OWN job-run.ps1 process
# exited successfully. JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE terminates every
# job member the instant the job's last handle closes — exactly right on
# the TIMEOUT path (case v) and exactly wrong here; job-run.ps1 now clears
# the limit flag before releasing the handle on the success path (Clear-
# JobKillOnClose), so a surviving descendant is released, not killed. The
# survivor's OWN stdio is explicitly redirected away from the wrapper (`<
# /dev/null > /dev/null 2>&1`) so this test's own stdout capture doesn't
# hang waiting for a pipe only the (deliberately still-running) survivor
# holds open — an artifact of a real daemon needing to detach its own
# stdio for the same reason, unrelated to the Job Object mechanism itself.
# This test FAILS against a version with the struct-setting bug below
# fixed but the success-path clear removed — verified empirically during
# development (not shippable as a permanent second implementation to
# regression-test against, so recorded here instead): job-run.ps1 originally
# also carried a SEPARATE, deeper bug where `$info.BasicLimitInformation.
# LimitFlags = ...` never actually persisted (PowerShell copies a nested
# struct field by value on property access, so the write landed on a
# temporary copy) — meaning KILL_ON_JOB_CLOSE was NEVER genuinely active in
# the very first shipped version, and this exact success-path bug could not
# yet manifest; the timeout path (case v) only ever worked because
# TerminateJobObject() is an unconditional, independent kill that doesn't
# rely on the flag at all. Both bugs are fixed in this same round: the
# struct-field bug (build-then-assign into a local variable, then assign
# the WHOLE struct into the outer field, never a nested-property mutation)
# makes the flag genuinely active; this test proves the success-path
# handling is correct now that it actually matters. ────────────────────────
survivorWork="$work/survivor-work"; mkdir -p "$survivorWork"
survivorSh="$survivorWork/survives-success.sh"
cat > "$survivorSh" <<'SH'
#!/usr/bin/env bash
d="$(dirname "$0")"
sleep 30 < /dev/null > /dev/null 2>&1 &
echo $! > "$d/survivor.pid"
exit 0
SH
SURVIVOR_SH="$survivorSh"
# CR fix (flake, discovered empirically): the result is written to a FILE
# (fs.writeFileSync), NOT console.log'd + captured via `$(...)` — mirrors
# case p's own established convention (test-wizard-install-engine.sh,
# HIMMELCTL_SUDO_PASSWORD round) of avoiding a Node-owned pipe whenever a
# case also needs to inspect a BACKGROUNDED descendant's liveness by pid.
# `$(...)` command substitution makes the outer node process's stdout a
# real OS pipe, inherited hop-by-hop down to bash.exe — even though the
# survivor's OWN stdio is separately redirected away (`< /dev/null >
# /dev/null 2>&1`), that EXTRA pipe-capture plumbing was empirically found
# (via direct, repeated isolation) to leave MSYS's own pid-server unable to
# resolve the survivor's freshly-issued pid from THIS script's separate
# bash session afterward — a test-harness/environment artifact, not a
# product bug (independently verified: the identical scenario driven via a
# DIRECT powershell.exe invocation with plain stdio:'inherit', bypassing
# this capture entirely, resolves the pid reliably every time). Writing the
# result to a file sidesteps the extra pipe entirely.
# HIMMEL-1119 item 3: winpath'd because node.exe (not bash) resolves this one
# — fs.writeFileSync consumes it, and node.exe is blind to MSYS /tmp-style
# paths, the same reason INSTALL_ENGINE_LIB/FIXTURE_REPO/… above are converted.
# SURVIVOR_SH is deliberately NOT converted: bash consumes that one, so its
# MSYS form is the correct one. Reading it back with `cat` below stays fine —
# git-bash resolves the converted form too.
RESULT_OUT="$(winpath "$survivorWork/result.json")"
export SURVIVOR_SH RESULT_OUT
( cd "$survivorWork" && "$node_bin" -e "
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const plan = [
  { id: 'survives', type: 'wire', deps: [], cmd: 'bash', args: [process.env.SURVIVOR_SH] },
];
const result = runInstall(plan, { dryRun: false });
require('fs').writeFileSync(process.env.RESULT_OUT, JSON.stringify(result));
" )
outW=$(cat "$RESULT_OUT")
echo "$outW" | jq -e '.ran | length == 1 and .[0].id == "survives"' >/dev/null \
  || fail "case w: the primitive should succeed and land in ran[] (got: $outW)"
survivorPidFile="$survivorWork/survivor.pid"
[ -f "$survivorPidFile" ] || fail "case w: the survivor's pid file was never written"
survivorPid=$(cat "$survivorPidFile")
# CR fix (CodeRabbit round 16, item 8): record the pid for cleanup() (see
# the top of this file) BEFORE the liveness assertion below — if that
# assertion itself calls fail() (exit 1), the trap still fires and reaps
# the survivor; a leaked process must not depend on this case reaching its
# own "ok:" line.
SURVIVOR_PID="$survivorPid"
# A brief moment for a BUGGY implementation's kill-on-close to take effect
# (near-instant if it fires) before asserting liveness — this is NOT a
# poll-for-death loop, since the point is proving the opposite (still
# alive).
sleep 0.5
if ! kill -0 "$survivorPid" 2>/dev/null; then
  fail "case w: the survivor (pid $survivorPid) — a legitimately-backgrounded descendant of a SUCCESSFULLY-completed primitive — must still be ALIVE; it was killed instead, meaning kill-on-close fired on the success path"
fi
# The assertion above is done with the survivor — kill it NOW rather than
# waiting for the script's own exit trap, so a passing run doesn't hold a
# live process (and its own 30s sleep) open for the rest of this file's
# remaining test cases. SURVIVOR_PID is deliberately left set (not cleared)
# so cleanup()'s own kill stays a backstop — harmless no-op if this one
# already succeeded, guarded by `|| true` there and here alike.
kill "$survivorPid" >/dev/null 2>&1 || true
echo "ok: case w — a legitimate background descendant of a SUCCESSFUL install survives (kill-on-close is cleared before the job handle is released on any non-timeout path)"

# ── case x (CR fix, codex round 17): the FAILURE complement of case w. Case
# w proves a survivor lives when clearing KILL_ON_JOB_CLOSE succeeds; this
# proves what happens when that clear FAILS. job-run.ps1 then signals
# $CLEANUP_FAILED_EXIT_CODE (4220): the wrapped command itself succeeded,
# but releasing the handle may have killed the background descendants it
# launched. The bug being locked down: the old success branch exited with
# the CHILD's success code, so ensure reported green right after
# potentially breaking the service it just installed — a fail-OPEN of the
# same class as round 16's WaitForExit find. install-engine.js classifies
# this spawn by exit code ALONE (job-run's stderr warning is never read),
# so the sentinel is the only channel that can carry it. Asserts it lands
# in failed[] (never ran[]) with a reason that names the actual hazard.
# ─────────────────────────────────────────────────────────────────────────
outX=$("$node_bin" -e "
const cp = require('child_process');
Object.defineProperty(process, 'platform', { value: 'win32', configurable: true });
cp.spawnSync = function () {
  return { status: 4220, signal: null, error: null };
};
const { runInstall } = require(process.env.INSTALL_ENGINE_LIB);
const plan = [ { id: 'cleanup-failed-win', type: 'dep', cmd: 'bash', args: ['-c', 'true'] } ];
console.log(JSON.stringify(runInstall(plan, { dryRun: false })));
")
echo "$outX" | jq -e '.ran | length == 0' >/dev/null \
  || fail "case x: a 4220 (cleanup-failed) spawn must NOT be reported as a successful run — that is the false-green this sentinel exists to prevent (got: $outX)"
echo "$outX" | jq -e '.failed | length == 1 and .[0].id == "cleanup-failed-win"' >/dev/null \
  || fail "case x: job-run.ps1's CLEANUP_FAILED_EXIT_CODE (4220) should classify as a failure (got: $outX)"
echo "$outX" | jq -e '.failed[0].reason | test("KILL_ON_JOB_CLOSE")' >/dev/null \
  || fail "case x: the 4220 failure reason should name the actual hazard (failed to clear KILL_ON_JOB_CLOSE), not a bare 'exited 4220' (got: $outX)"
echo "ok: case x — job-run.ps1's CLEANUP_FAILED_EXIT_CODE (4220) fails closed: a succeeded-but-uncleanable spawn is reported as a failure naming the hazard, never as a false green"

echo "PASS"
