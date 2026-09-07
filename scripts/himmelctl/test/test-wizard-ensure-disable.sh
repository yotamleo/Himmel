#!/usr/bin/env bash
# test-wizard-ensure-disable.sh — hermetic tests for `ensure`'s
# toward-disabled branch (HIMMEL-755 A5b): an enabled item the operator no
# longer wants (desired:false after a --profile reconcile, but still
# actually present) converges by `removable`: a `per-item` item runs its
# `unwire` primitive; a `full-offboard-only` item ERRORS naming itself +
# pointing at `himmelctl uninstall`, with zero mutation for that item.
# Drives bin.js end-to-end via a HIMMELCTL_REPO_ROOT fixture carrying a
# 2-item manifest + STUB wire-statusline.sh/wire-pretooluse-hooks.sh/
# unwire-statusline.sh primitives (a simple file-marker stand-in for
# "physically wired"). Mirrors sibling test-wizard-*.sh conventions.
#
# Covers:
#   a. an enabled per-item item (wiring-statusline-shaped: removable:
#      per-item + unwire) toward-disabled runs its unwire-statusline.sh stub
#      (spy log) and removes the underlying marker; a follow-up statusReport
#      — evaluated back under the ORIGINAL profile where the item is desired
#      again — reads it severity:red (proving the resource is actually gone,
#      not just no longer desired).
#   b. a full-offboard-only item toward-disabled ERRORS naming the item +
#      pointing at `himmelctl uninstall`, and its marker is left UNTOUCHED
#      (zero mutation for that item specifically).
#   c. (CR fix) a DEGRADED (not fully present, not absent) removable item is
#      STILL queued for disable — not just a fully 'present' one — and, when
#      its unwire primitive "succeeds" (exit 0) but the resource is STILL
#      not absent on re-probe (still degraded), ensure treats that as a
#      failure rather than trusting the primitive's exit code alone.
#   d. (CR fix) --dry-run surfaces a full-offboard-only blocker as a DRY
#      line and fails its own exit code, instead of silently returning 0.
#   e. (CR fix) reverse-dependency unwire ordering: two removable items
#      where B deps on A — the toward-disabled dispatch unwires B BEFORE A
#      (tear-down in reverse build order), not manifest declaration order.
#   f. (CR fix) --dry-run over a removable:per-item item whose unwire
#      descriptor is unrunnable surfaces the blocker (not a silent "DRY:
#      unwire <id>" success) and fails its own exit code.
#   g. (CR fix) --items must not break dependency closure on the
#      toward-DISABLED side either: item-y deps on item-x (removable:
#      per-item). Reconciling item-x toward disabled via `--items item-x`
#      while item-y (still desired under every profile this fixture can
#      reconcile to, depends on item-x) is excluded is REJECTED — exit 2,
#      names the excluded dependent, item-x's marker is left untouched
#      (zero mutation, unwire never runs — and the PERSISTED state.json/
#      install-profile cache are asserted byte-identical before vs. after,
#      not just the marker + spy log, proving the reject happens BEFORE any
#      save point). (CR fix, codex round 4, Suggestion) also asserts the
#      rejection does NOT advise merely adding item-y to --items (that
#      advice doesn't work — case k proves membership alone never disables
#      a still-desired dependent) and instead names the two remediations
#      that actually do: reconciling item-y undesired too, or dropping
#      item-x from the run. Deliberately does NOT go on to
#      "complete" the operation via a wider --items list that satisfies
#      the closure check while still leaving item-x gone and item-y (its
#      dependent) installed — that end state is exactly what the check
#      exists to prevent, not a legitimate success path to assert. The
#      genuinely coherent completion (both items becoming undesired
#      together, unwound in reverse-dependency order) is case e's own
#      coverage.
#   h. (CR fix, SECURITY — secret leak) the unwire spawn now goes through
#      the SAME hardened path (installEngineLib.runUnwire ->
#      runHardenedSpawn) as every install — a real (non-mocked) unwire
#      primitive that targeted-probes its own environment (CR fix,
#      CodeRabbit round 16: NOT a full `env` dump — that would leak the
#      operator's own real ambient secrets into test/CI output) proves
#      HIMMELCTL_SUDO_PASSWORD is ABSENT from it (an unrelated marker var survives,
#      proving this isn't "wipe everything"), mirroring the install-path
#      case r in test-wizard-install-engine.sh. A cross-model review caught
#      that this call site had drifted from runInstall's own hardening —
#      this proves the drift is closed.
#   i. (CR fix, HANG) a wedged unwire primitive that backgrounds a
#      grandchild (re-parenting it) is timed out by the SAME
#      INSTALL_TIMEOUT_SECS mechanism installs use — lands in disableErrors
#      naming a "timed out after Ns" reason, and the grandchild is verified
#      GENUINELY DEAD afterward (polled, not a fixed sleep — same bar as
#      the install-path case s), not merely orphaned/still running in the
#      background.
#   j. (CR fix) the final "N converged" completion count includes
#      successful UNWIRES, not just installs: ONE ensure call that both
#      disables item-x (unwire) and installs item-y reads "2 converged",
#      not 1 (the shipped-then-buggy shape derived the count from
#      ran.length alone).
#   k. (CR fix, cross-model: codex + CodeRabbit both found this) being
#      INCLUDED in --items is not proof a dependent is actually being
#      unwired: `--items item-x,item-y` where item-x is toward-disabled but
#      item-y (its dependent) stays desired is REJECTED — exit 2, names
#      both items, zero mutation (item-x's unwire never runs, its marker
#      survives). Only an excluded dependent was checked before; an
#      included-but-still-desired one slipped through.
#   l. (CR fix, CodeRabbit round 16, MAJOR — fail-closed) a REAL disable
#      failure stops the ensure immediately: item-y (dependent) unwires
#      first (reverse-dependency order) and is rigged to fail — item-x's
#      unwire (the prerequisite, second in order) is proven to NEVER run,
#      and a wholly unrelated toward-enabled item-z's install is proven to
#      NEVER be dispatched either (the abort skips Step 5 entirely, not
#      just the rest of the disable loop). --dry-run's own enumerate-
#      everything behavior (case d) is unaffected by this fix.
#   p. (CR fix, HIMMEL-1100 round 6, CodeRabbit App PR #1500 thread #4) a
#      full-offboard-only item that probes DEGRADED (not 'present', not
#      'absent') logs an advisory and lets the run PROCEED (exit 0) instead
#      of permanently blocking every ensure the way a 'present' item still
#      does — the removal gate used to push ANY non-absent probe as an
#      unconditional blocker, wedging a probe that can structurally never
#      confirm 'present' (e.g. guardrail-block-global, before its HIMMEL-1418
#      `status --json` verb) forever, with no unwire descriptor to ever
#      converge it. Asserted across TWO consecutive runs (not a one-shot
#      fluke).
#   q. (codex-2 review finding, HIMMEL-2349) pins the chosen asymmetric
#      behaviour of the split-consent decline: a run with towardEnabled AND
#      (via --prune) towardDisabled items, declined interactively at the
#      FIRST (converge) prompt, aborts the ENTIRE run — the second
#      (disable) confirm is never reached, so --prune's disable pass is
#      skipped too, not just the converge. Asserts the decline message says
#      so explicitly, and that NEITHER item is mutated (converge-item stays
#      uninstalled, prune-item stays installed with its unwire spy log
#      empty).
#   r. (codex-4 review finding, HIMMEL-2349) describeDisableCommand()'s
#      evidence line ("disabling would run: ...") quotes an argument
#      containing a space (a target path under "target with space") —
#      this string is consent evidence the operator reads before allowing
#      a disable, so an unquoted, ambiguous rendering is an honesty defect.
#   t. (CR fix, codex-1 round 6, HIMMEL-2349) the under-recorded EVIDENCE
#      count must not count an item carrying a deliberate per-item override
#      (target.items[id].overrides non-empty) — an override IS recorded
#      operator intent, the opposite of an under-recorded record. PRIMARY:
#      three removable items, all physically present, all carrying a
#      deliberate override — `ensure --prune --yes` (no --profile) must NOT
#      trip the guard, and the disable pass genuinely proceeds (markers
#      gone). NEGATIVE CONTROL (mandatory): the identical fixture with the
#      SAME three items but NO overrides — the guard DOES trip and --prune
#      is held back, proving the primary case discriminates rather than
#      passing vacuously.

set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
state_lib="$repo_root/scripts/himmelctl/lib/state.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
[ -f "$state_lib" ] || { echo "FAIL: $state_lib not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# sha256_hash <file> — sha256sum when present, else macOS's shasum -a 256
# (no sha256sum binary there by default). Mirrors test-wizard-ensure.sh's
# own helper.
if command -v sha256sum >/dev/null 2>&1; then
  sha256_hash() { sha256sum "$1"; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_hash() { shasum -a 256 "$1"; }
else
  echo "FAIL: sha256sum or shasum required" >&2
  exit 1
fi

# snapshot_file <path> — a sha256 hash line, or the literal "ABSENT" when
# the file doesn't exist — so a before/after comparison is meaningful
# whether or not the file existed at snapshot time (CR fix: case g's
# zero-mutation claim needs to cover the PERSISTED state, not just the
# primitive marker + spy log).
snapshot_file() {
  if [ -f "$1" ]; then sha256_hash "$1"; else echo "ABSENT"; fi
}

node_bin=$(command -v node)

work=$(mktemp -d)
# case s (negative control): the mutated pre-v2 bin.js lives NEXT TO the real
# one (not under $work) so its relative `./lib/...` and `../../hooks/...`
# requires resolve to the exact same real files bin.js already uses -- no
# directory-tree copy needed. The name carries $$ (this run's PID) because
# himmel runs concurrent suites/`/pr-check`s: a fixed name would let two
# runs' cleanup traps `rm -f` each other's fixture, or one overwrite the
# other's copy mid-test. Always removed here, pass or fail.
mutatedWizardInTree="$repo_root/scripts/himmelctl/.tmp-hazard-return2-test.$$.js"
cleanup() { rm -rf "$work"; rm -f "$mutatedWizardInTree"; }
trap cleanup EXIT

write_cache() {
  cat > "$1" <<JSON
{"role":"$2","tier":"standard","scope":"$3","vault":{"mode":"$4","path":"$5"},"handover":{"mode":"$6","path":"$7"},"pluginSet":"$8","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON
}

# ── fixture repo: 2 items, both profiles:["luna","all"] — a per-item item
# (wiring-statusline-shaped) and a full-offboard-only item. Stub primitives
# create/remove a marker file, standing in for "physically wired". ─────────
fixtureRepo="$work/repo"
mkdir -p "$fixtureRepo/scripts/install" "$fixtureRepo/scripts/lib"
cat > "$fixtureRepo/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "wiring-statusline", "kind": "wiring", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "wiring.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "full-offboard-item", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "offboard.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" },
      "removable": "full-offboard-only"
    }
  ]
}
JSON
cat > "$fixtureRepo/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > wiring.marker
exit 0
SH
cat > "$fixtureRepo/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > offboard.marker
exit 0
SH
cat > "$fixtureRepo/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${DISABLE_LOG:-}" ] && echo "unwire-statusline" >> "$DISABLE_LOG"
rm -f wiring.marker
exit 0
SH

targetDir="$work/target"; mkdir -p "$targetDir"
cacheDir="$work/cache"; mkdir -p "$cacheDir"
homeDir="$work/home"; mkdir -p "$homeDir"
write_cache "$cacheDir/install-profile.json" adopter project none "" inline "" lean
logDisable="$work/disable-log.txt"; : > "$logDisable"

runEnsure() {
  ( cd "$targetDir" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheDir")-luna-config.json" HOME="$homeDir" USERPROFILE="$(winpath "$homeDir")" DISABLE_LOG="$(winpath "$logDisable")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
runStatus() {
  ( cd "$targetDir" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheDir")-luna-config.json" HOME="$homeDir" USERPROFILE="$(winpath "$homeDir")" \
      "$node_bin" "$wizard" status "$@" </dev/null )
}

# ── step 1: converge BOTH items under profile luna (installs them: both
# markers created) ──────────────────────────────────────────────────────────
set +e
out1=$(runEnsure --profile luna --yes); rc1=$?
set -e
[ "$rc1" -eq 0 ] || fail "setup: ensure --profile luna --yes should converge both items (got rc=$rc1): $out1"
[ -f "$targetDir/wiring.marker" ] || fail "setup: wiring.marker should exist after the initial luna converge"
[ -f "$targetDir/offboard.marker" ] || fail "setup: offboard.marker should exist after the initial luna converge"
echo "ok: setup — both items converged (installed) under profile luna"

# ── step 2a: reconcile to profile core -> BOTH items flip desired:false
# while still physically present, but THIS run is scoped via --items to
# JUST wiring-statusline. CR fix (CodeRabbit round 16, MAJOR — fail-fast):
# a single combined `--profile core` run used to dispatch BOTH toward-
# disabled items and rely on neither one's outcome depending on the
# other's — that assumption broke once a real disable failure aborts the
# whole loop (this round's fix): reverseDependencyOrder's blanket
# `.reverse()` puts full-offboard-item (declared SECOND in the manifest,
# no dependency relationship to wiring-statusline) AHEAD of
# wiring-statusline for two independent, dep-less items, so a combined run
# now aborts on full-offboard-item's failure before ever reaching
# wiring-statusline's unwire at all. Splitting into two --items-scoped
# runs keeps cases a/b independently meaningful regardless of processing
# order — case l (below) is where the fail-fast ordering ITSELF gets
# tested directly. ──────────────────────────────────────────────────────
# ── case a (part 0, HIMMEL-2349 split consent): the SAME reconcile WITHOUT
# --prune must converge-only — the item flips desired:false (the reconcile
# itself is unconditional) but stays PHYSICALLY WIRED, and its unwire
# primitive never runs. This is the split-consent guarantee itself (default
# `ensure` never disables), worth asserting permanently alongside case a's
# own --prune-opted-in disable below, not just implied by it.
set +e
out2a0=$(runEnsure --profile core --yes --items wiring-statusline 2>&1); rc2a0=$?
set -e
[ "$rc2a0" -eq 0 ] || fail "step 2a (part 0, no --prune): ensure --items wiring-statusline should exit 0 (got rc=$rc2a0): $out2a0"
[ -f "$targetDir/wiring.marker" ] || fail "case a (part 0): wiring.marker should still exist — default ensure (no --prune) must not disable it"
if grep -qF 'unwire-statusline' "$logDisable"; then
  fail "case a (part 0): unwire-statusline.sh must NOT have run without --prune (spy log: $(cat "$logDisable"))"
fi
echo "ok: case a (part 0) — split consent: the SAME reconcile WITHOUT --prune leaves the item wired (unwire never runs)"

# ── case a (part 1, HIMMEL-2349): --prune opts in — NOW the per-item unwire
# actually runs and the marker is removed. ─────────────────────────────────
set +e
out2a=$(runEnsure --profile core --yes --prune --items wiring-statusline 2>&1); rc2a=$?
set -e
[ "$rc2a" -eq 0 ] || fail "step 2a: ensure --items wiring-statusline --prune should exit 0 (the per-item unwire succeeds) (got rc=$rc2a): $out2a"

# ── case a: per-item item's unwire ran; marker removed ─────────────────────
if ! grep -qF 'unwire-statusline' "$logDisable"; then
  fail "case a: unwire-statusline.sh should have been invoked (spy log: $(cat "$logDisable"))"
fi
[ ! -f "$targetDir/wiring.marker" ] || fail "case a: wiring.marker should be REMOVED after the per-item unwire runs"
echo "ok: case a (part 1) — --prune opted in: the per-item item's unwire primitive ran; its marker was removed"

# ── case a (part 2): a follow-up read, evaluated back under the ORIGINAL
# profile (luna) where the item is desired again, shows it severity:red —
# proving the underlying resource is actually gone, not just undesired.
# Reconciled DIRECTLY via state.js (bypassing ensure, which would otherwise
# auto-reinstall it) so this is a pure read-back, not a re-convergence.
# CR fix: paths passed via the ENVIRONMENT (STATE_LIB_PATH/MANIFEST_PATH/
# ANSWERS_PATH), never embedded in the node -e source string — a checkout
# path containing an apostrophe would otherwise break the inline JS. ───────
( cd "$targetDir" && HOME="$homeDir" USERPROFILE="$(winpath "$homeDir")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" \
    STATE_LIB_PATH="$(winpath "$state_lib")" \
    MANIFEST_PATH="$(winpath "$fixtureRepo/scripts/install/manifest.json")" \
    ANSWERS_PATH="$(winpath "$cacheDir/install-profile.json")" \
    "$node_bin" -e "
const state = require(process.env.STATE_LIB_PATH);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_PATH, 'utf8'));
const answers = JSON.parse(require('fs').readFileSync(process.env.ANSWERS_PATH, 'utf8'));
let s = state.load();
state.reconcileTarget(s, manifest, answers, { profile: 'luna', scope: 'project' });
state.save(s);
")
outStatus=$(runStatus --items wiring-statusline --json)
echo "$outStatus" | jq -e '.items[] | select(.id=="wiring-statusline") | .desired == true and .severity == "red"' >/dev/null \
  || fail "case a: re-evaluated under profile luna (desired again), wiring-statusline should read severity:red (marker gone) (got: $outStatus)"
echo "ok: case a (part 2) — re-evaluated under its original profile, the disabled item reads severity:red (resource confirmed gone)"

# ── step 2b: full-offboard-item was ALSO reconciled to desired:false back
# in step 2a (a --profile reconcile is unconditional, independent of
# --items) but was excluded from step 2a's --items filter, so it's still
# physically present and untouched. A follow-up run scoped to --items
# full-offboard-item drives ITS toward-disabled dispatch in isolation.
# --profile core is passed again explicitly (self-contained, not relying
# on ordering) — case a (part 2), directly above, reconciled the persisted
# target's profile back to luna via a raw state.js call (bypassing ensure
# on purpose, to avoid re-triggering a real convergence), so the stored
# profile can no longer be assumed to still be core by this point. ───────
set +e
out2b=$(runEnsure --profile core --yes --prune --items full-offboard-item 2>&1); rc2b=$?
set -e
[ "$rc2b" -ne 0 ] || fail "step 2b: ensure --items full-offboard-item should exit non-zero (the full-offboard-only item errors) (got rc=0): $out2b"

# ── case b: the full-offboard-only item ERRORS naming itself + pointing at
# 'himmelctl uninstall'; its marker is left UNTOUCHED (zero mutation) ──────
[ -f "$targetDir/offboard.marker" ] || fail "case b: offboard.marker should be left UNTOUCHED (full-offboard-only never unwires)"
grepq "$out2b" -F 'full-offboard-item' || fail "case b: the error should name 'full-offboard-item' (got: $out2b)"
grepq "$out2b" -F 'himmelctl uninstall' || fail "case b: the error should point at 'himmelctl uninstall' (got: $out2b)"
echo "ok: case b — the full-offboard-only item errors naming itself + pointing at 'himmelctl uninstall'; its marker is untouched"

# ── case b2 (CR round 8, codex-1, HIMMEL-2349): the per-item disable
# EVIDENCE line (describeDisableCandidate(), printed above the Step 4
# dispatch that produced case b's error) must not promise a run that never
# happens. full-offboard-item is 'present' here (same run as case b, same
# $out2b) — Step 4's else-branch for it ERRORS + BREAKS instead of running
# 'himmelctl uninstall', so the evidence line must say the run STOPS and
# the operator must run it themselves, never "disabling would run: ...".
if grepq "$out2b" -F 'would run'; then
  fail "case b2: the full-offboard-only evidence line must NOT say 'would run' — Step 4 never runs 'himmelctl uninstall' for it, it errors + aborts (got: $out2b)"
fi
grepq "$out2b" -F 'the run will STOP and ask you to run '"'"'himmelctl uninstall'"'"' yourself' \
  || fail "case b2: the evidence line must say the run stops and the operator must run 'himmelctl uninstall' themselves (got: $out2b)"
echo "ok: case b2 — the full-offboard-only disable-evidence line does not claim a run that never happens; it says the run stops and names the manual command"

# ── case c (CR fix): a DEGRADED (not fully present) removable item is
# STILL queued for disable, and a "successful" unwire (exit 0) that leaves
# the resource still non-absent on re-probe is treated as a failure. Fresh
# repo/target/cache — isolated from cases a/b. ─────────────────────────────
repoDeg="$work/repoDeg"; mkdir -p "$repoDeg/scripts/install" "$repoDeg/scripts/lib"
cat > "$repoDeg/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "degraded-item", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "settings-hooks", "file": ".claude/settings.json", "key": "hooks.PreToolUse" },
      "install": { "type": "wire", "target": "pretooluse-hooks" },
      "unwire": { "type": "wire", "target": "pretooluse-hooks" },
      "removable": "per-item"
    }
  ]
}
JSON
# The unwire stub deliberately does NOTHING to settings.json — it "succeeds"
# (exit 0) without actually clearing the resource, so the re-probe fix (not
# just trusting the primitive's exit code) is what catches this.
cat > "$repoDeg/scripts/lib/unwire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${DISABLE_LOG:-}" ] && echo "unwire-pretooluse-hooks" >> "$DISABLE_LOG"
exit 0
SH

targetDeg="$work/targetDeg"; mkdir -p "$targetDeg/.claude"
# 1 of 3 himmel PreToolUse markers present -> probeSettingsHooks reads
# 'degraded', never 'present' and never 'absent'.
cat > "$targetDeg/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/auto-approve-safe-bash.sh\""}]}
]}}
JSON
cacheDeg="$work/cacheDeg"; mkdir -p "$cacheDeg"
homeDeg="$work/homeDeg"; mkdir -p "$homeDeg"
# vault.mode=none -> profile 'core', which EXCLUDES degraded-item
# (profiles:["luna","all"]) -> desired:false from the very first run, no
# --profile reconcile needed to reach the toward-disabled path.
write_cache "$cacheDeg/install-profile.json" adopter project none "" inline "" lean
logDeg="$work/disable-log-deg.txt"; : > "$logDeg"

set +e
outDeg=$( cd "$targetDeg" && HIMMELCTL_REPO_ROOT="$(winpath "$repoDeg")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheDeg")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheDeg")-luna-config.json" HOME="$homeDeg" USERPROFILE="$(winpath "$homeDeg")" DISABLE_LOG="$(winpath "$logDeg")" \
    "$node_bin" "$wizard" ensure --yes --prune 2>&1 </dev/null ); rcDeg=$?
set -e
[ "$rcDeg" -ne 0 ] || fail "case c: ensure should exit non-zero (the degraded item's unwire doesn't actually clear it) (got rc=0): $outDeg"
grep -qF 'unwire-pretooluse-hooks' "$logDeg" || fail "case c: the degraded item's unwire primitive should have been invoked (queued despite not being fully 'present') (spy log: $(cat "$logDeg"))"
grepq "$outDeg" -F 'degraded-item' || fail "case c: the failure should name 'degraded-item' (got: $outDeg)"
grepq "$outDeg" -i 'degraded' || fail "case c: the failure should mention the resource is still degraded, not trusting the exit-0 primitive alone (got: $outDeg)"
# settings.json is untouched by the do-nothing stub -- still exactly 1/3 markers.
grep -qF 'auto-approve-safe-bash' "$targetDeg/.claude/settings.json" || fail "case c: settings.json should still carry its one marker (stub never touched it)"
echo "ok: case c — a degraded (not fully present) removable item is still queued for disable; a successful-exit unwire that leaves it non-absent is treated as a failure"

# ── case d (CR fix round 3, HIMMEL-755): --dry-run must SURFACE a
# full-offboard-only blocker (as a DRY line) and fail its own exit code,
# not silently return 0. Fresh, isolated target/cache (case a/b's shared
# target ends this suite reconciled back to profile luna by case a part 2's
# raw state.js call — reusing it here would converge wiring-statusline
# instead of exercising the blocker this case targets). ────────────────────
targetD="$work/targetD"; mkdir -p "$targetD"
cacheD="$work/cacheD"; mkdir -p "$cacheD"
homeD="$work/homeD"; mkdir -p "$homeD"
write_cache "$cacheD/install-profile.json" adopter project none "" inline "" lean

runEnsureD() {
  ( cd "$targetD" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheD")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheD")-luna-config.json" HOME="$homeD" USERPROFILE="$(winpath "$homeD")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
# Converge full-offboard-item under luna (installs it: offboard.marker
# created), then reconcile to core (desired:false, still physically
# present) — the exact toward-disabled scenario, isolated from case a/b.
set +e
outD0=$(runEnsureD --profile luna --yes --items full-offboard-item); rcD0=$?
set -e
[ "$rcD0" -eq 0 ] || fail "case d setup: converging full-offboard-item under luna should exit 0 (got rc=$rcD0): $outD0"
[ -f "$targetD/offboard.marker" ] || fail "case d setup: offboard.marker should exist after the initial luna converge"
set +e
runEnsureD --profile core --yes --prune --items full-offboard-item >/dev/null 2>&1; rcD1=$?
set -e
[ "$rcD1" -ne 0 ] || fail "case d setup: reconciling to core should exit non-zero (full-offboard-item errors) (got rc=0)"

set +e
outDry=$(runEnsureD --dry-run --prune --items full-offboard-item 2>&1); rcDry=$?
set -e
[ "$rcDry" -ne 0 ] || fail "case d: --dry-run must NOT silently return 0 when a full-offboard-only blocker exists (got rc=0): $outDry"
grepq "$outDry" -F 'DRY:' || fail "case d: expected at least one DRY: line (got: $outDry)"
grepq "$outDry" -F 'full-offboard-item' || fail "case d: the DRY output should name full-offboard-item (got: $outDry)"
grepq "$outDry" -F 'himmelctl uninstall' || fail "case d: the DRY output should point at himmelctl uninstall (got: $outDry)"
[ -f "$targetD/offboard.marker" ] || fail "case d: --dry-run must make zero mutations (offboard.marker should still exist)"
echo "ok: case d — --dry-run surfaces a full-offboard-only blocker as a DRY line and fails its own exit code"

# ── case e (CR fix): reverse-dependency unwire ordering — item-b deps on
# item-a; toward-disabled must unwire item-b BEFORE item-a. Fresh, isolated
# repo/target/cache. ────────────────────────────────────────────────────────
repoE="$work/repoE"; mkdir -p "$repoE/scripts/install" "$repoE/scripts/lib"
cat > "$repoE/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "item-a", "kind": "wiring", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "item-a.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "item-b", "kind": "wiring", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": ["item-a"],
      "probe": { "type": "file-exists", "path": "item-b.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" },
      "unwire": { "type": "wire", "target": "pretooluse-hooks" },
      "removable": "per-item"
    }
  ]
}
JSON
cat > "$repoE/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > item-a.marker
exit 0
SH
cat > "$repoE/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > item-b.marker
exit 0
SH
cat > "$repoE/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${ORDER_LOG:-}" ] && echo "unwire-item-a" >> "$ORDER_LOG"
rm -f item-a.marker
exit 0
SH
cat > "$repoE/scripts/lib/unwire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${ORDER_LOG:-}" ] && echo "unwire-item-b" >> "$ORDER_LOG"
rm -f item-b.marker
exit 0
SH

targetE="$work/targetE"; mkdir -p "$targetE"
cacheE="$work/cacheE"; mkdir -p "$cacheE"
homeE="$work/homeE"; mkdir -p "$homeE"
write_cache "$cacheE/install-profile.json" adopter project none "" inline "" lean

runEnsureE() {
  ( cd "$targetE" && HIMMELCTL_REPO_ROOT="$(winpath "$repoE")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheE")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheE")-luna-config.json" HOME="$homeE" USERPROFILE="$(winpath "$homeE")" ORDER_LOG="$(winpath "$orderLogE")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
orderLogE="$work/order-log-e.txt"; : > "$orderLogE"

# Converge both under luna (installs them: both markers created).
set +e
outE0=$(runEnsureE --profile luna --yes); rcE0=$?
set -e
[ "$rcE0" -eq 0 ] || fail "case e setup: converging both items under luna should exit 0 (got rc=$rcE0): $outE0"
[ -f "$targetE/item-a.marker" ] || fail "case e setup: item-a.marker should exist after the initial luna converge"
[ -f "$targetE/item-b.marker" ] || fail "case e setup: item-b.marker should exist after the initial luna converge"

# Reconcile to core -> both flip desired:false while still physically
# present -> toward-disabled dispatch for both, in REVERSE dependency order.
set +e
runEnsureE --profile core --yes --prune >/dev/null 2>&1; rcE1=$?
set -e
[ "$rcE1" -eq 0 ] || fail "case e: reconciling to core should converge both unwires cleanly (got rc=$rcE1)"

lineCountE=$(wc -l < "$orderLogE" | tr -d ' ')
[ "$lineCountE" -eq 2 ] || fail "case e: expected exactly 2 unwire invocations (got $lineCountE); log: $(cat "$orderLogE")"
firstLineE=$(sed -n '1p' "$orderLogE")
secondLineE=$(sed -n '2p' "$orderLogE")
[ "$firstLineE" = "unwire-item-b" ] || fail "case e: item-b (the DEPENDENT) should unwire FIRST (got: $firstLineE; full log: $(cat "$orderLogE"))"
[ "$secondLineE" = "unwire-item-a" ] || fail "case e: item-a (the PREREQUISITE) should unwire SECOND (got: $secondLineE; full log: $(cat "$orderLogE"))"
[ ! -f "$targetE/item-a.marker" ] || fail "case e: item-a.marker should be removed"
[ ! -f "$targetE/item-b.marker" ] || fail "case e: item-b.marker should be removed"
echo "ok: case e — reverse-dependency unwire ordering: item-b (dependent) unwires before item-a (prerequisite)"

# ── case f (CR fix): --dry-run over a removable:per-item item with an
# UNRUNNABLE unwire descriptor (unwire.type isn't 'wire' — install-engine.js's
# unwireCommand() only knows 'wire') surfaces the blocker instead of a
# silent "DRY: unwire <id>" success. No stub primitives needed — the item's
# marker is seeded directly (standing in for "physically wired"); its
# profile excludes it under the default core profile, so a bare
# `ensure --dry-run` (no --profile reconcile needed) already reaches the
# toward-disabled path. ─────────────────────────────────────────────────────
repoF="$work/repoF"; mkdir -p "$repoF/scripts/install"
cat > "$repoF/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "unrunnable-unwire-item", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "item.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "bogus" },
      "removable": "per-item"
    }
  ]
}
JSON
targetF="$work/targetF"; mkdir -p "$targetF"
: > "$targetF/item.marker"
cacheF="$work/cacheF"; mkdir -p "$cacheF"
homeF="$work/homeF"; mkdir -p "$homeF"
write_cache "$cacheF/install-profile.json" adopter project none "" inline "" lean

set +e
outF=$( cd "$targetF" && HIMMELCTL_REPO_ROOT="$(winpath "$repoF")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheF")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheF")-luna-config.json" HOME="$homeF" USERPROFILE="$(winpath "$homeF")" \
    "$node_bin" "$wizard" ensure --dry-run --prune 2>&1 </dev/null ); rcF=$?
set -e
[ "$rcF" -ne 0 ] || fail "case f: --dry-run with an unrunnable unwire descriptor must NOT silently return 0 (got rc=0): $outF"
grepq "$outF" -F 'unrunnable-unwire-item' || fail "case f: the DRY output should name unrunnable-unwire-item (got: $outF)"
grepq "$outF" -F 'DRY:' || fail "case f: expected at least one DRY: line (got: $outF)"
[ -f "$targetF/item.marker" ] || fail "case f: --dry-run must make zero mutations (item.marker should still exist)"
echo "ok: case f — --dry-run over a removable:per-item item with an unrunnable unwire descriptor surfaces the blocker and fails"

# ── case g (CR fix, HIMMEL-755): --items must not break dependency closure
# on the toward-DISABLED side. item-y deps on item-x; item-x is profiled
# luna-only (drops out under core), item-y is profiled core+luna+all (STAYS
# desired under core) — so reconciling to core makes item-x toward-disabled
# while item-y remains desired throughout. ─────────────────────────────────
repoG="$work/repoG"; mkdir -p "$repoG/scripts/install" "$repoG/scripts/lib"
cat > "$repoG/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "item-x", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "x.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "item-y", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "luna", "all"], "deps": ["item-x"],
      "probe": { "type": "file-exists", "path": "y.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" },
      "removable": "full-offboard-only"
    }
  ]
}
JSON
cat > "$repoG/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > x.marker
exit 0
SH
cat > "$repoG/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > y.marker
exit 0
SH
cat > "$repoG/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${DISABLE_LOG_G:-}" ] && echo "unwire-item-x" >> "$DISABLE_LOG_G"
rm -f x.marker
exit 0
SH

targetG="$work/targetG"; mkdir -p "$targetG"
cacheG="$work/cacheG"; mkdir -p "$cacheG"
homeG="$work/homeG"; mkdir -p "$homeG"
write_cache "$cacheG/install-profile.json" adopter project none "" inline "" lean
logG="$work/disable-log-g.txt"; : > "$logG"

runEnsureG() {
  ( cd "$targetG" && HIMMELCTL_REPO_ROOT="$(winpath "$repoG")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheG")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheG")-luna-config.json" HOME="$homeG" USERPROFILE="$(winpath "$homeG")" DISABLE_LOG_G="$(winpath "$logG")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}

# Converge both under luna (installs them: both markers created).
set +e
outG0=$(runEnsureG --profile luna --yes); rcG0=$?
set -e
[ "$rcG0" -eq 0 ] || fail "case g setup: converging both items under luna should exit 0 (got rc=$rcG0): $outG0"
[ -f "$targetG/x.marker" ] || fail "case g setup: x.marker should exist after the initial luna converge"
[ -f "$targetG/y.marker" ] || fail "case g setup: y.marker should exist after the initial luna converge"

# case g (part 1): --profile core --items item-x — item-x goes
# toward-disabled while item-y (still desired under core, depends on
# item-x) is excluded from --items -> REJECTED, zero mutation.
# CR fix (rigor): the zero-mutation claim must cover the PERSISTED state
# too, not just the primitive marker + spy log — a premature profile/state
# save would go completely undetected otherwise. Snapshot state.json (state
# already exists here: the setup converge above legitimately persisted it)
# and the install-profile cache (never touched by ensure at all) BEFORE the
# rejected call, and assert both byte-identical after — that's the
# assertion that actually proves the reject happens before the save point.
stateSnapBefore=$(snapshot_file "$cacheG/state.json")
profileSnapBefore=$(snapshot_file "$cacheG/install-profile.json")
set +e
outG1=$(runEnsureG --profile core --yes --prune --items item-x 2>&1); rcG1=$?
set -e
[ "$rcG1" -eq 2 ] || fail "case g: --items item-x (dependent item-y excluded) should exit 2 (got rc=$rcG1): $outG1"
grepq "$outG1" -F 'item-y' || fail "case g: the rejection should name the excluded dependent item-y (got: $outG1)"
grepq "$outG1" -F 'item-x' || fail "case g: the rejection should name item-x (got: $outG1)"
# CR fix (codex round 4, Suggestion): the OLD message told the operator to
# "add it: --items item-x,item-y" -- advice that doesn't work, since
# item-y is still DESIRED and merely naming it in --items was proven this
# round to never disable anything on its own (that's case k's whole bug).
# Following that advice would walk straight into a SECOND rejection
# instead of resolving anything. The message must instead name the two
# remediations that actually work: reconciling item-y toward undesired
# too, or dropping item-x from this run.
if grepq "$outG1" -F 'add it: --items'; then
  fail "case g: the rejection must NOT advise merely adding item-y to --items -- that advice doesn't resolve anything (a still-desired dependent is rejected regardless of --items membership) (got: $outG1)"
fi
grepq "$outG1" -iF 'undesired' || fail "case g: the rejection should name reconciling item-y toward undesired as a working remediation (got: $outG1)"
grepq "$outG1" -F 'drop' || fail "case g: the rejection should name dropping item-x from this run as the other working remediation (got: $outG1)"
[ ! -s "$logG" ] || fail "case g: item-x's unwire must NOT have run (spy log: $(cat "$logG"))"
[ -f "$targetG/x.marker" ] || fail "case g: x.marker must still exist (zero mutation — item-x was never unwired)"
[ -f "$targetG/y.marker" ] || fail "case g: y.marker must still exist (item-y was never touched)"
stateSnapAfter=$(snapshot_file "$cacheG/state.json")
profileSnapAfter=$(snapshot_file "$cacheG/install-profile.json")
[ "$stateSnapBefore" = "$stateSnapAfter" ] || fail "case g: state.json must be byte-identical across the rejected run (the closure check must run BEFORE any save) — before: $stateSnapBefore; after: $stateSnapAfter"
[ "$profileSnapBefore" = "$profileSnapAfter" ] || fail "case g: install-profile.json must be untouched by the rejected run — before: $profileSnapBefore; after: $profileSnapAfter"
echo "ok: case g — --items excluding a still-desired dependent is REJECTED on the toward-disabled side (zero mutation, including the persisted state)"
# CR fix: this case deliberately stops here — it does NOT go on to prove a
# "corrected" completion by adding item-y to --items. item-y stays desired
# under EVERY profile this fixture can reconcile to (profiles:["core",
# "luna","all"]), so any --items list that satisfies the closure check
# without ALSO changing item-y's own desired-ness would still end the run
# with item-x gone while item-y (which depends on it) remains installed —
# an incoherent end state the closure check exists to PREVENT, not one a
# test should assert as a legitimate "success" path just because --items
# membership was satisfied. The genuinely coherent completion — BOTH a
# prerequisite and its dependent becoming undesired together and unwinding
# in reverse-dependency order to a clean end state (neither present) — is
# exactly what case e above already proves with its own item-a/item-b
# fixture; retesting the identical shape here under a different name would
# add no coverage. Case g's own job is narrowly this: prove the closure
# check makes the incoherent state unreachable in the first place.

# ── case h (CR fix, SECURITY — secret leak): the unwire spawn now goes
# through installEngineLib.runUnwire() -> the SAME runHardenedSpawn() every
# install already uses. A real (non-mocked) unwire primitive dumps its own
# environment to prove HIMMELCTL_SUDO_PASSWORD is ABSENT from it (an
# unrelated marker var survives, proving this isn't "wipe everything") —
# mirrors test-wizard-install-engine.sh's own case r for the install side.
# The unwire primitive also actually clears its marker (a clean rc=0
# success path keeps the assertions focused on the env-scrub property
# alone). ────────────────────────────────────────────────────────────────
repoH="$work/repoH"; mkdir -p "$repoH/scripts/install" "$repoH/scripts/lib"
cat > "$repoH/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "leaky-item", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "leaky.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    }
  ]
}
JSON
cat > "$repoH/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > leaky.marker
exit 0
SH
cat > "$repoH/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
# CR fix (CodeRabbit round 16, MAJOR -- secret exposure in OUR test): a full
# `env` dump here would print the OPERATOR'S REAL, ambient secrets (whatever
# happens to be in the shell that launched scripts/test-adopt.sh) straight
# into test/CI output. This stub exists only to prove HIMMELCTL_SUDO_
# PASSWORD is absent from the primitive's own environment -- which never
# requires seeing anything else in it. Print only the two targeted signals
# the assertions below actually check: the marker var's value (test-owned
# synthetic data, safe to print) and the password var's mere PRESENCE,
# never its value even if a future bug reintroduces it into the env.
echo "OTHER_MARKER_H=${OTHER_MARKER_H:-<unset>}"
if [ -n "${HIMMELCTL_SUDO_PASSWORD+x}" ]; then
  echo "HIMMELCTL_SUDO_PASSWORD_PRESENT=yes"
else
  echo "HIMMELCTL_SUDO_PASSWORD_PRESENT=no"
fi
rm -f leaky.marker
exit 0
SH

targetH="$work/targetH"; mkdir -p "$targetH"
cacheH="$work/cacheH"; mkdir -p "$cacheH"
homeH="$work/homeH"; mkdir -p "$homeH"
write_cache "$cacheH/install-profile.json" adopter project none "" inline "" lean

runEnsureH() {
  ( cd "$targetH" && HIMMELCTL_REPO_ROOT="$(winpath "$repoH")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheH")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheH")-luna-config.json" HOME="$homeH" USERPROFILE="$(winpath "$homeH")" \
      HIMMELCTL_SUDO_PASSWORD='h-env-secret' OTHER_MARKER_H='should-survive-h' \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
# Converge under luna (installs it: leaky.marker created).
set +e
outH0=$(runEnsureH --profile luna --yes); rcH0=$?
set -e
[ "$rcH0" -eq 0 ] || fail "case h setup: converging leaky-item under luna should exit 0 (got rc=$rcH0): $outH0"
[ -f "$targetH/leaky.marker" ] || fail "case h setup: leaky.marker should exist after the initial luna converge"

# Reconcile to core (leaky-item is profiles:["luna","all"], drops out) ->
# toward-disabled -> the unwire primitive's `env` dump lands in outH1 (its
# stdio is inherited, sharing ensure's own stdout — the SAME channel this
# test captures).
set +e
outH1=$(runEnsureH --profile core --yes --prune); rcH1=$?
set -e
[ "$rcH1" -eq 0 ] || fail "case h: reconciling to core should cleanly unwire leaky-item (got rc=$rcH1): $outH1"
[ ! -f "$targetH/leaky.marker" ] || fail "case h: leaky.marker should be removed after the unwire runs"
grepq "$outH1" -F 'OTHER_MARKER_H=should-survive-h' \
  || fail "case h: an unrelated env var should survive into the unwire primitive's env (got: $outH1)"
grepq "$outH1" -F 'HIMMELCTL_SUDO_PASSWORD_PRESENT=no' \
  || fail "case h: HIMMELCTL_SUDO_PASSWORD must be ABSENT from the unwire primitive's environment (got: $outH1)"
if grepq "$outH1" -F 'h-env-secret'; then
  fail "case h: the password VALUE must never appear anywhere in the unwire primitive's output (got: $outH1)"
fi
echo "ok: case h — the unwire primitive's environment has HIMMELCTL_SUDO_PASSWORD stripped (an unrelated var survives)"

# ── case i (CR fix, HANG): a wedged unwire primitive that backgrounds a
# grandchild (re-parenting it) is timed out via the SAME INSTALL_TIMEOUT_SECS
# mechanism runInstall's own installs use — lands in disableErrors with a
# "timed out after Ns" reason, and the grandchild is verified GENUINELY DEAD
# afterward (polled, matching the install-path case s bar in
# test-wizard-install-engine.sh), not merely orphaned/still running. ───────
repoI="$work/repoI"; mkdir -p "$repoI/scripts/install" "$repoI/scripts/lib"
cat > "$repoI/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "wedged-unwire-item", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "wedged.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    }
  ]
}
JSON
cat > "$repoI/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > wedged.marker
exit 0
SH
# Backgrounds a grandchild (recording its pid via an env-var-passed path —
# CR fix convention: never interpolate a path into a fixture script) and
# blocks past any reasonable timeout, standing in for a real-world hung
# unwire primitive.
cat > "$repoI/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
sleep 30 &
echo $! > "$GRANDCHILD_PID_FILE_I"
wait
SH

targetI="$work/targetI"; mkdir -p "$targetI"
cacheI2="$work/cacheI2"; mkdir -p "$cacheI2"
homeI="$work/homeI"; mkdir -p "$homeI"
write_cache "$cacheI2/install-profile.json" adopter project none "" inline "" lean
grandchildPidFileI="$work/grandchild-unwire.pid"
grandchildPidFileIW="$(winpath "$grandchildPidFileI")"

set +e
outI0=$(cd "$targetI" && HIMMELCTL_REPO_ROOT="$(winpath "$repoI")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheI2")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheI2")-luna-config.json" HOME="$homeI" USERPROFILE="$(winpath "$homeI")" \
    "$node_bin" "$wizard" ensure --profile luna --yes </dev/null); rcI0=$?
set -e
[ "$rcI0" -eq 0 ] || fail "case i setup: converging wedged-unwire-item under luna should exit 0 (got rc=$rcI0): $outI0"
[ -f "$targetI/wedged.marker" ] || fail "case i setup: wedged.marker should exist after the initial luna converge"

set +e
outI1=$(cd "$targetI" && HIMMELCTL_REPO_ROOT="$(winpath "$repoI")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheI2")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheI2")-luna-config.json" HOME="$homeI" USERPROFILE="$(winpath "$homeI")" \
    GRANDCHILD_PID_FILE_I="$grandchildPidFileIW" INSTALL_TIMEOUT_SECS=1 \
    "$node_bin" "$wizard" ensure --profile core --yes --prune 2>&1 </dev/null); rcI1=$?
set -e
[ "$rcI1" -ne 0 ] || fail "case i: a timed-out unwire should exit non-zero (got rc=0): $outI1"
grepq "$outI1" -F 'wedged-unwire-item' || fail "case i: the failure should name wedged-unwire-item (got: $outI1)"
grepq "$outI1" -F 'timed out after' || fail "case i: the failure reason should mention the timeout (got: $outI1)"

[ -f "$grandchildPidFileI" ] || fail "case i: the grandchild's pid file was never written — it never even started before the timeout fired"
grandchildPidI=$(cat "$grandchildPidFileI")
# CR fix (flake, same lesson as install-engine's own case s): poll instead
# of a fixed sleep — a busy host can take longer than a beat to reap the
# process. The assertion itself stays strict. CR fix (portability): a bash
# arithmetic loop instead of `seq` (same fix as install-engine's own cases
# s/v) — `seq` is an external binary, not guaranteed present on every
# POSIX host this suite might run on.
grandchildDeadI=0
for ((_i = 0; _i < 50; _i++)); do
  if ! kill -0 "$grandchildPidI" 2>/dev/null; then
    grandchildDeadI=1
    break
  fi
  sleep 0.1
done
[ "$grandchildDeadI" -eq 1 ] || fail "case i: the grandchild (pid $grandchildPidI) must be dead after the unwire timeout kills the whole process tree, but it is still running (waited 5s)"
echo "ok: case i — a wedged unwire primitive is timed out (disableErrors names the reason); its backgrounded grandchild is verified genuinely dead, not merely orphaned"

# ── case j (CR fix, HIMMEL-755): the final "N converged" completion count
# must include successful UNWIRES, not just installs. item-x (profiles
# luna+all, removable:per-item) is already installed; item-y (profiles
# core+all) is not. Reconciling to core in ONE ensure call disables item-x
# (unwire) while installing item-y — the count must read 2, not 1 (the
# shipped-then-buggy shape derived it from ran.length alone, silently
# dropping successful disables). ───────────────────────────────────────────
repoJ="$work/repoJ"; mkdir -p "$repoJ/scripts/install" "$repoJ/scripts/lib"
cat > "$repoJ/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "item-x", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "x.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "item-y", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "y.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" }
    }
  ]
}
JSON
cat > "$repoJ/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > x.marker
exit 0
SH
cat > "$repoJ/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > y.marker
exit 0
SH
cat > "$repoJ/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
rm -f x.marker
exit 0
SH

targetJ="$work/targetJ"; mkdir -p "$targetJ"
cacheJ="$work/cacheJ"; mkdir -p "$cacheJ"
homeJ="$work/homeJ"; mkdir -p "$homeJ"
write_cache "$cacheJ/install-profile.json" adopter project none "" inline "" lean

runEnsureJ() {
  ( cd "$targetJ" && HIMMELCTL_REPO_ROOT="$(winpath "$repoJ")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheJ")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheJ")-luna-config.json" HOME="$homeJ" USERPROFILE="$(winpath "$homeJ")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
# Converge item-x under luna (installs it: x.marker created; item-y is NOT
# desired under luna, so it stays uninstalled).
set +e
outJ0=$(runEnsureJ --profile luna --yes); rcJ0=$?
set -e
[ "$rcJ0" -eq 0 ] || fail "case j setup: converging item-x under luna should exit 0 (got rc=$rcJ0): $outJ0"
[ -f "$targetJ/x.marker" ] || fail "case j setup: x.marker should exist after the initial luna converge"

# Reconcile to core: item-x drops out (unwound) while item-y comes in
# (installed) -- ONE ensure call, both directions, in the SAME run.
set +e
outJ1=$(runEnsureJ --profile core --yes --prune); rcJ1=$?
set -e
[ "$rcJ1" -eq 0 ] || fail "case j: reconciling to core should cleanly disable item-x and install item-y (got rc=$rcJ1): $outJ1"
[ ! -f "$targetJ/x.marker" ] || fail "case j: x.marker should be removed (item-x unwired)"
[ -f "$targetJ/y.marker" ] || fail "case j: y.marker should exist (item-y installed)"
grepq "$outJ1" -F 'ensure complete (2 converged)' \
  || fail "case j: the completion count should be 2 (1 install + 1 unwire), not just ran.length (got: $outJ1)"
echo "ok: case j — the completion count includes successful unwires, not just installs (1 install + 1 unwire = 2 converged)"

# ── case k (CR fix, cross-model: codex + CodeRabbit both found this): being
# INCLUDED in --items does NOT mean a dependent is being disabled — it only
# means it's in scope. `--items item-x,item-y` (item-x the prerequisite
# going toward-disabled, item-y the STILL-DESIRED dependent, BOTH named)
# must be REJECTED just like the excluded case (g) already is — the
# shipped-then-buggy shape treated itemsSet membership as sufficient and
# would have unwired item-x while item-y (still enabled) broke silently.
# Reuses repoG's exact item-x/item-y fixture (item-y is desired under
# EVERY profile this fixture can reconcile to). ───────────────────────────
targetK="$work/targetK"; mkdir -p "$targetK"
cacheK="$work/cacheK"; mkdir -p "$cacheK"
homeK="$work/homeK"; mkdir -p "$homeK"
write_cache "$cacheK/install-profile.json" adopter project none "" inline "" lean
logK="$work/disable-log-k.txt"; : > "$logK"

runEnsureK() {
  ( cd "$targetK" && HIMMELCTL_REPO_ROOT="$(winpath "$repoG")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheK")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheK")-luna-config.json" HOME="$homeK" USERPROFILE="$(winpath "$homeK")" DISABLE_LOG_G="$(winpath "$logK")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
set +e
outK0=$(runEnsureK --profile luna --yes); rcK0=$?
set -e
[ "$rcK0" -eq 0 ] || fail "case k setup: converging both items under luna should exit 0 (got rc=$rcK0): $outK0"
[ -f "$targetK/x.marker" ] || fail "case k setup: x.marker should exist after the initial luna converge"

# --items item-x,item-y (BOTH included) -- item-y is still desired under
# core (it was never going to be disabled), so this must STILL reject.
set +e
outK1=$(runEnsureK --profile core --yes --prune --items item-x,item-y 2>&1); rcK1=$?
set -e
[ "$rcK1" -eq 2 ] || fail "case k: --items item-x,item-y (item-y included but still desired) should exit 2 (got rc=$rcK1): $outK1"
grepq "$outK1" -F 'item-y' || fail "case k: the rejection should name item-y (got: $outK1)"
grepq "$outK1" -F 'item-x' || fail "case k: the rejection should name item-x (got: $outK1)"
[ ! -s "$logK" ] || fail "case k: item-x's unwire must NOT have run (spy log: $(cat "$logK"))"
[ -f "$targetK/x.marker" ] || fail "case k: x.marker must still exist (zero mutation — item-x was never unwired)"
echo "ok: case k — --items INCLUDING a still-desired dependent is REJECTED too (membership alone was never sufficient), zero mutation"

# ── case l (CR fix, CodeRabbit round 16, MAJOR — fail-closed): a REAL
# disable failure must stop the WHOLE ensure right there — the failing
# item's unwire must prevent BOTH the next toward-disabled item's unwire
# AND any toward-enabled install from ever being attempted in the SAME
# run. Fresh, isolated repo/target/cache. item-y deps on item-x (reverse-
# dependency order processes item-y FIRST, same as case e); item-y's
# unwire is rigged to fail (exit 1). item-z is a wholly unrelated,
# runnable install-only item that becomes desired in the SAME reconcile —
# proving the abort reaches all the way past Step 4 into skipping Step 5
# entirely, not just skipping the rest of the disable loop. ──────────────
repoL="$work/repoL"; mkdir -p "$repoL/scripts/install" "$repoL/scripts/lib"
cat > "$repoL/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "item-x", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "x.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "item-y", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": ["item-x"],
      "probe": { "type": "file-exists", "path": "y.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" },
      "unwire": { "type": "wire", "target": "pretooluse-hooks" },
      "removable": "per-item"
    },
    {
      "id": "item-z", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "z.marker" },
      "install": { "type": "wire", "target": "statusline" }
    }
  ]
}
JSON
# item-z (profiles:["core","all"], undesired under luna) also uses the
# 'statusline' install target -- buildEntry only wires up TWO real targets
# ('statusline' and a hardcoded pretooluse-hooks fallback), so a third
# independent runnable item has to reuse one of them. wire-statusline.sh is
# instrumented with its OWN spy log (INSTALL_LOG_L, reset right after
# setup below) so "was ANY install dispatched" is provable regardless of
# which item's install would have invoked it.
cat > "$repoL/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${INSTALL_LOG_L:-}" ] && echo "wire-statusline" >> "$INSTALL_LOG_L"
: > x.marker
exit 0
SH
cat > "$repoL/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > y.marker
exit 0
SH
cat > "$repoL/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${ORDER_LOG_L:-}" ] && echo "unwire-item-x" >> "$ORDER_LOG_L"
rm -f x.marker
exit 0
SH
cat > "$repoL/scripts/lib/unwire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${ORDER_LOG_L:-}" ] && echo "unwire-item-y" >> "$ORDER_LOG_L"
exit 1
SH

targetL="$work/targetL"; mkdir -p "$targetL"
cacheL="$work/cacheL"; mkdir -p "$cacheL"
homeL="$work/homeL"; mkdir -p "$homeL"
write_cache "$cacheL/install-profile.json" adopter project none "" inline "" lean
orderLogL="$work/order-log-l.txt"; : > "$orderLogL"
installLogL="$work/install-log-l.txt"; : > "$installLogL"

runEnsureL() {
  ( cd "$targetL" && HIMMELCTL_REPO_ROOT="$(winpath "$repoL")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheL")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheL")-luna-config.json" HOME="$homeL" USERPROFILE="$(winpath "$homeL")" \
      ORDER_LOG_L="$(winpath "$orderLogL")" INSTALL_LOG_L="$(winpath "$installLogL")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}

# Converge item-x/item-y under luna (installs them: both markers created);
# item-z stays undesired (excluded from luna).
set +e
outL0=$(runEnsureL --profile luna --yes); rcL0=$?
set -e
[ "$rcL0" -eq 0 ] || fail "case l setup: converging item-x/item-y under luna should exit 0 (got rc=$rcL0): $outL0"
[ -f "$targetL/x.marker" ] || fail "case l setup: x.marker should exist after the initial luna converge"
[ -f "$targetL/y.marker" ] || fail "case l setup: y.marker should exist after the initial luna converge"
[ ! -f "$targetL/z.marker" ] || fail "case l setup: z.marker should NOT exist yet (item-z is not desired under luna)"
# Reset the install spy log AFTER setup — setup's own item-x install
# legitimately wrote to it; only the reconcile below matters for this case.
: > "$installLogL"

# Reconcile to core in ONE combined run: item-x/item-y flip toward-disabled
# (item-y, the dependent, unwires FIRST per reverse-dependency order, and
# is rigged to fail); item-z flips toward-enabled (desired+red) at the
# SAME time.
set +e
outL1=$(runEnsureL --profile core --yes --prune 2>&1); rcL1=$?
set -e
[ "$rcL1" -ne 0 ] || fail "case l: a failed unwire should exit non-zero (got rc=0): $outL1"
grepq "$outL1" -F 'item-y' || fail "case l: the failure should name item-y (got: $outL1)"
grepq "$outL1" -F 'unwire failed' || fail "case l: the failure reason should say the unwire failed (got: $outL1)"

# item-y's own unwire ran (and failed) — it's the first item processed.
grep -qF 'unwire-item-y' "$orderLogL" \
  || fail "case l: item-y's unwire should have run (and failed) — it's processed FIRST (reverse-dependency order) (log: $(cat "$orderLogL"))"
# item-x's unwire must NEVER have run — the loop aborted on item-y first.
if grep -qF 'unwire-item-x' "$orderLogL"; then
  fail "case l: item-x's unwire must NEVER have run — the disable loop aborts on item-y's failure before reaching it (log: $(cat "$orderLogL"))"
fi
[ -f "$targetL/x.marker" ] || fail "case l: x.marker must still exist — item-x's unwire never ran"
# item-z's install must never have been dispatched either — the whole
# ensure aborts before Step 5 (installs) on a real disable failure.
if [ -s "$installLogL" ]; then
  fail "case l: no install should have been dispatched — item-z's install must never run after the disable-phase failure (install spy log: $(cat "$installLogL"))"
fi
[ ! -f "$targetL/z.marker" ] || fail "case l: z.marker must NOT exist — item-z's install must never be dispatched"
echo "ok: case l — a real disable failure stops the ensure immediately: the second toward-disabled item is never attempted, and no install is dispatched"

# ── case m (CR fix, CodeRabbit round 19): the toward-disabled closure check
# is UNGATED — an UNFILTERED ensure (no --items) must ALSO reject when
# unwiring a prerequisite would break a still-desired dependent. Pre-fix the
# check lived inside `if (args.items)`, so a plain `ensure --profile core
# --yes` skipped it and silently unwired item-x while item-y (still desired,
# deps item-x) stayed installed — broken, invisibly (item-y's file-exists
# probe still read green). Reuses repoG's item-x/item-y fixture (item-x
# profiles:["luna","all"] drops under core; item-y profiles:["core","luna",
# "all"] stays desired; item-y deps item-x). ─────────────────────────────
targetM="$work/targetM"; mkdir -p "$targetM"
cacheM="$work/cacheM"; mkdir -p "$cacheM"
homeM="$work/homeM"; mkdir -p "$homeM"
write_cache "$cacheM/install-profile.json" adopter project none "" inline "" lean
logM="$work/disable-log-m.txt"; : > "$logM"

runEnsureM() {
  ( cd "$targetM" && HIMMELCTL_REPO_ROOT="$(winpath "$repoG")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheM")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheM")-luna-config.json" HOME="$homeM" USERPROFILE="$(winpath "$homeM")" DISABLE_LOG_G="$(winpath "$logM")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
# Converge both under luna (installs them: both markers created).
set +e
outM0=$(runEnsureM --profile luna --yes); rcM0=$?
set -e
[ "$rcM0" -eq 0 ] || fail "case m setup: converging both items under luna should exit 0 (got rc=$rcM0): $outM0"
[ -f "$targetM/x.marker" ] || fail "case m setup: x.marker should exist after the initial luna converge"
[ -f "$targetM/y.marker" ] || fail "case m setup: y.marker should exist after the initial luna converge"

# UNFILTERED `ensure --profile core --yes` (NO --items): item-x flips
# toward-disabled while item-y (desired under core, deps item-x) stays —
# the ungated check must REJECT before any unwire, zero mutation.
stateSnapBeforeM=$(snapshot_file "$cacheM/state.json")
set +e
outM1=$(runEnsureM --profile core --yes --prune 2>&1); rcM1=$?
set -e
[ "$rcM1" -eq 2 ] || fail "case m: an UNFILTERED ensure must REJECT (exit 2) when unwiring item-x would break the still-desired item-y (got rc=$rcM1): $outM1"
grepq "$outM1" -F 'item-y' || fail "case m: the rejection should name the still-desired dependent item-y (got: $outM1)"
grepq "$outM1" -F 'item-x' || fail "case m: the rejection should name item-x (got: $outM1)"
# CR fix (round 19): the message must no longer claim --items on an unfiltered run.
# `-e` is REQUIRED, not decoration: without it grep parses the leading `--` of
# the pattern as its own flag ("grep: unknown option -- items would disable",
# rc=2), the `if` never fires, and this assertion silently cannot fail — it was
# dead from the round-19 commit that introduced it until round 23 caught it.
# A negative assertion that cannot fire is worse than no assertion: it reads as
# coverage. Verified: `grep -qF '--items…'` => rc=2; `grep -qF -e '--items…'` => rc=0.
if grepq "$outM1" -F -e '--items would disable'; then
  fail "case m: the rejection must NOT say '--items would disable' on an UNFILTERED run (got: $outM1)"
fi
[ ! -s "$logM" ] || fail "case m: item-x's unwire must NOT have run (spy log: $(cat "$logM"))"
[ -f "$targetM/x.marker" ] || fail "case m: x.marker must still exist (zero mutation — item-x was never unwired)"
[ -f "$targetM/y.marker" ] || fail "case m: y.marker must still exist (item-y was never touched)"
stateSnapAfterM=$(snapshot_file "$cacheM/state.json")
[ "$stateSnapBeforeM" = "$stateSnapAfterM" ] || fail "case m: state.json must be byte-identical across the rejected run (the closure check must run BEFORE any save) — before: $stateSnapBeforeM; after: $stateSnapAfterM"
echo "ok: case m — an UNFILTERED ensure rejects unwiring a prerequisite a still-desired dependent needs (zero mutation, incl. persisted state); message does not claim --items"

# ── case n (CR fix, CodeRabbit round 23, MAJOR — toward-DISABLED TRANSITIVE
# reverse closure): the reverse-closure walk must be TRANSITIVE, not
# direct-edges-only. Topology desired C -> undesired-present B -> disabled A:
# unwiring A must be REJECTED naming C, even though no item DIRECTLY
# depending on A is still desired. The prior loop checked each item's OWN
# deps[] for a disabled id: B's deps DO include A, but B is undesired so its
# iteration `continue`s; C's deps hold B (not A), so C was never examined
# and A unwired under a still-desired transitive dependent. B is undesired
# AND present AND NOT removable (so it never enters towardDisabled itself)
# — exactly the narrow reachability the CR thread names. ──────────────────
repoN="$work/repoN"; mkdir -p "$repoN/scripts/install" "$repoN/scripts/lib" "$repoN/scripts/machine-setup"
cat > "$repoN/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "item-a", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "n-a.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "item-b", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": ["item-a"],
      "probe": { "type": "file-exists", "path": "n-b.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" }
    },
    {
      "id": "item-c", "kind": "plugin", "scopes": ["project"], "profiles": ["core", "luna", "all"], "deps": ["item-b"],
      "probe": { "type": "file-exists", "path": "n-c.marker" },
      "install": { "type": "plugins" }
    }
  ]
}
JSON
cat > "$repoN/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > n-a.marker
exit 0
SH
cat > "$repoN/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > n-b.marker
exit 0
SH
cat > "$repoN/scripts/machine-setup/install-plugins.sh" <<'SH'
#!/usr/bin/env bash
: > n-c.marker
exit 0
SH
cat > "$repoN/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${DISABLE_LOG_N:-}" ] && echo "unwire-item-a" >> "$DISABLE_LOG_N"
rm -f n-a.marker
exit 0
SH
targetN="$work/targetN"; mkdir -p "$targetN"
cacheN="$work/cacheN"; mkdir -p "$cacheN"
homeN="$work/homeN"; mkdir -p "$homeN"
write_cache "$cacheN/install-profile.json" adopter project none "" inline "" lean
logN="$work/disable-log-n.txt"; : > "$logN"

runEnsureN() {
  ( cd "$targetN" && HIMMELCTL_REPO_ROOT="$(winpath "$repoN")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheN")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheN")-luna-config.json" HOME="$homeN" USERPROFILE="$(winpath "$homeN")" DISABLE_LOG_N="$(winpath "$logN")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}

# Setup: converge ALL THREE under profile luna (all desired under luna) —
# every marker created, every item green/present.
set +e
outN0=$(runEnsureN --profile luna --yes); rcN0=$?
set -e
[ "$rcN0" -eq 0 ] || fail "case n setup: converging all three under luna should exit 0 (got rc=$rcN0): $outN0"
[ -f "$targetN/n-a.marker" ] || fail "case n setup: n-a.marker should exist after the luna converge"
[ -f "$targetN/n-b.marker" ] || fail "case n setup: n-b.marker should exist after the luna converge"
[ -f "$targetN/n-c.marker" ] || fail "case n setup: n-c.marker should exist after the luna converge"

# case n: reconcile to profile core. Under core: item-a (luna-only) flips
# undesired+removable+present -> toward-disabled; item-b (luna-only, NO
# removable) flips undesired but STAYS PRESENT and is NOT in towardDisabled;
# item-c (core+luna+all) STAYS desired. The TRANSITIVE reverse walk must
# reach item-c through the undesired-present item-b and REJECT before any
# unwire — naming item-c (and the chain), zero mutation. UNFILTERED run
# (the check is ungated — round 19).
stateSnapBeforeN=$(snapshot_file "$cacheN/state.json")
set +e
outN1=$(runEnsureN --profile core --yes --prune 2>&1); rcN1=$?
set -e
[ "$rcN1" -eq 2 ] || fail "case n: --profile core (transitive still-desired dependent item-c behind undesired item-b) should exit 2 (got rc=$rcN1): $outN1"
grepq "$outN1" -F 'item-c' || fail "case n: the rejection should name the still-desired TRANSITIVE dependent item-c (got: $outN1)"
grepq "$outN1" -F 'item-a' || fail "case n: the rejection should name the disabled item-a (got: $outN1)"
grepq "$outN1" -F 'item-c -> item-b -> item-a' \
  || fail "case n: a TRANSITIVE break should name the whole chain 'item-c -> item-b -> item-a', not only the endpoints (got: $outN1)"
[ ! -s "$logN" ] || fail "case n: item-a's unwire must NOT have run (spy log: $(cat "$logN"))"
[ -f "$targetN/n-a.marker" ] || fail "case n: n-a.marker must still exist (zero mutation — item-a was never unwired)"
stateSnapAfterN=$(snapshot_file "$cacheN/state.json")
[ "$stateSnapBeforeN" = "$stateSnapAfterN" ] || fail "case n: state.json must be byte-identical across the rejected run (the closure check must run BEFORE any save) — before: $stateSnapBeforeN; after: $stateSnapAfterN"
echo "ok: case n — a still-desired dependent hidden behind an UNDESIRED-present middle node is still caught by the TRANSITIVE reverse walk (exit 2, names item-c + the chain), zero mutation"

# ── case o (CR fix, CodeRabbit round 23 FOLLOW-ON, MAJOR — stop the reverse
# walk at an ABSENT undesired intermediate): the mirror of case n. Topology
# desired C -> undesired-ABSENT B -> disabled A. Because B is physically
# ABSENT, the chain C -> B -> A is ALREADY broken at B, so unwiring A cannot
# newly break C — the walk must NOT descend through the absent B and must NOT
# reject. Pre-fix the walk assumed every undesired intermediate was present
# (statusReport leaves an undesired item's actual state unprobed -> fullById
# has actual:null), descended through the absent B, reached the still-desired
# C and FALSELY rejected. The fix probes the intermediate's presence and
# descends only when it is not 'absent'. Here B is undesired under core AND
# never installed (its profiles omit the luna setup profile), so its marker
# is absent while A stays present. ──────────────────────────────────────────
repoO="$work/repoO"; mkdir -p "$repoO/scripts/install" "$repoO/scripts/lib" "$repoO/scripts/machine-setup"
cat > "$repoO/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "item-a", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "o-a.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "item-b", "kind": "wiring", "scopes": ["project"], "profiles": ["all"], "deps": ["item-a"],
      "probe": { "type": "file-exists", "path": "o-b.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" }
    },
    {
      "id": "item-c", "kind": "plugin", "scopes": ["project"], "profiles": ["core", "luna", "all"], "deps": ["item-b"],
      "probe": { "type": "file-exists", "path": "o-c.marker" },
      "install": { "type": "plugins" }
    }
  ]
}
JSON
cat > "$repoO/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > o-a.marker
exit 0
SH
cat > "$repoO/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > o-b.marker
exit 0
SH
cat > "$repoO/scripts/machine-setup/install-plugins.sh" <<'SH'
#!/usr/bin/env bash
: > o-c.marker
exit 0
SH
cat > "$repoO/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${DISABLE_LOG_O:-}" ] && echo "unwire-item-a" >> "$DISABLE_LOG_O"
rm -f o-a.marker
exit 0
SH
targetO="$work/targetO"; mkdir -p "$targetO"
cacheO="$work/cacheO"; mkdir -p "$cacheO"
homeO="$work/homeO"; mkdir -p "$homeO"
write_cache "$cacheO/install-profile.json" adopter project none "" inline "" lean
logO="$work/disable-log-o.txt"; : > "$logO"

runEnsureO() {
  ( cd "$targetO" && HIMMELCTL_REPO_ROOT="$(winpath "$repoO")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheO")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheO")-luna-config.json" HOME="$homeO" USERPROFILE="$(winpath "$homeO")" DISABLE_LOG_O="$(winpath "$logO")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}

# Setup: converge under profile luna. item-a (luna/all) + item-c (core/luna/
# all) are desired -> installed (markers created). item-b (profiles ["all"]
# only) is UNDESIRED under luna -> never installed -> o-b.marker stays absent.
set +e
outO0=$(runEnsureO --profile luna --yes); rcO0=$?
set -e
[ "$rcO0" -eq 0 ] || fail "case o setup: converging item-a + item-c under luna should exit 0 (got rc=$rcO0): $outO0"
[ -f "$targetO/o-a.marker" ] || fail "case o setup: o-a.marker should exist after the luna converge (item-a is desired)"
[ -f "$targetO/o-c.marker" ] || fail "case o setup: o-c.marker should exist after the luna converge (item-c is desired)"
[ ! -f "$targetO/o-b.marker" ] || fail "case o setup: o-b.marker must NOT exist — item-b is undesired under luna, so it was never installed (the whole point: an ABSENT intermediate)"

# case o: reconcile to profile core. item-a (luna/all) flips undesired +
# removable + present -> toward-disabled; item-b (only "all") is undesired +
# ABSENT; item-c (core) STAYS desired (deps item-b). The reverse walk reaches
# item-b, probes it ABSENT, and must STOP — never reaching item-c. Unwiring
# item-a must PROCEED (rc 0, marker removed), NOT be falsely rejected.
set +e
outO1=$(runEnsureO --profile core --yes --prune 2>&1); rcO1=$?
set -e
[ "$rcO1" -eq 0 ] || fail "case o: unwiring item-a must PROCEED (exit 0) when the intermediate item-b is ABSENT — the chain is already broken, so blocking is a false rejection (got rc=$rcO1): $outO1"
if grepq "$outO1" -F 'item-c'; then
  fail "case o: the run must NOT name item-c as a blocking dependent — it is unreachable behind the absent item-b (got: $outO1)"
fi
[ ! -f "$targetO/o-a.marker" ] || fail "case o: o-a.marker must be GONE — item-a was unwired (the run proceeded, not rejected)"
grep -qF 'unwire-item-a' "$logO" || fail "case o: item-a's unwire must have RUN (the false rejection would have skipped it) — spy log: $(cat "$logO")"
echo "ok: case o — the TRANSITIVE reverse walk STOPS at an absent undesired intermediate: unwiring item-a proceeds (exit 0, marker removed) instead of a false rejection on the unreachable item-c"

# ── case p (CR fix, HIMMEL-1100 round 6, CodeRabbit App PR #1500 thread #4):
# a full-offboard-only item that probes DEGRADED (not fully 'present', not
# 'absent') must NOT block/abort an `ensure` run the way a 'present' one
# does — the toward-disabled removal gate used to push ANY non-absent probe
# as an unconditional blocker, so a probe that structurally can never
# confirm 'present' from status output alone (e.g. guardrail-block-global,
# before its HIMMEL-1418 `status --json` verb) wedged EVERY run permanently,
# with no unwire descriptor to ever converge it. The fix probes the item
# first: 'present' still blocks (case b, above,
# unchanged); 'degraded' logs an ADVISORY line instead and the run PROCEEDS
# (exit 0); 'absent' needs no note. Reuses the settings-hooks probe shape
# from case c (1/3 himmel PreToolUse markers -> 'degraded', never 'present'
# and never 'absent') on a full-offboard-only item (no unwire descriptor at
# all — the exact shape this bug targeted). ────────────────────────────────
repoP="$work/repoP"; mkdir -p "$repoP/scripts/install"
cat > "$repoP/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "degraded-offboard-item", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "settings-hooks", "file": ".claude/settings.json", "key": "hooks.PreToolUse" },
      "install": { "type": "wire", "target": "pretooluse-hooks" },
      "removable": "full-offboard-only"
    }
  ]
}
JSON

targetP="$work/targetP"; mkdir -p "$targetP/.claude"
# 1 of 3 himmel PreToolUse markers present -> probeSettingsHooks reads
# 'degraded', never 'present' and never 'absent' (mirrors case c's fixture).
cat > "$targetP/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/auto-approve-safe-bash.sh\""}]}
]}}
JSON
cacheP="$work/cacheP"; mkdir -p "$cacheP"
homeP="$work/homeP"; mkdir -p "$homeP"
# vault.mode=none -> profile 'core', which EXCLUDES degraded-offboard-item
# (profiles:["luna","all"]) -> desired:false from the very first run, no
# --profile reconcile needed to reach the toward-disabled path (mirrors
# case c's setup).
write_cache "$cacheP/install-profile.json" adopter project none "" inline "" lean

runEnsureP() {
  ( cd "$targetP" && HIMMELCTL_REPO_ROOT="$(winpath "$repoP")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheP")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheP")-luna-config.json" HOME="$homeP" USERPROFILE="$(winpath "$homeP")" \
      "$node_bin" "$wizard" ensure --yes --prune 2>&1 </dev/null )
}

set +e
outP1=$(runEnsureP); rcP1=$?
set -e
[ "$rcP1" -eq 0 ] || fail "case p: ensure must exit 0 when the only toward-disabled item is full-offboard-only AND degraded (must not permanently wedge the run) (got rc=$rcP1): $outP1"
grepq "$outP1" -F 'degraded-offboard-item' || fail "case p: the advisory line should name degraded-offboard-item (got: $outP1)"
grepq "$outP1" -i 'degraded' || fail "case p: the advisory line should say the item is degraded (got: $outP1)"
grepq "$outP1" -F 'himmelctl uninstall' || fail "case p: the advisory line should point at 'himmelctl uninstall' (got: $outP1)"
grepq "$outP1" -F 'if you want it fully removed' || fail "case p: the advisory should use the degraded-specific phrasing, distinct from the present-blocker's error (got: $outP1)"
if grepq "$outP1" -F 'to remove it'; then
  fail "case p: a degraded full-offboard-only item must NOT surface the 'present'-only blocker error shape (got: $outP1)"
fi
# settings.json is untouched -- full-offboard-only never unwires (no
# descriptor exists to run in the first place).
grep -qF 'auto-approve-safe-bash' "$targetP/.claude/settings.json" || fail "case p: settings.json should still carry its one marker (nothing ran against it)"

# Run it a SECOND time to prove this is not a one-shot fluke: a permanently
# degraded item must never wedge, on any run.
set +e
outP2=$(runEnsureP); rcP2=$?
set -e
[ "$rcP2" -eq 0 ] || fail "case p: a SECOND ensure run must also exit 0 -- a permanently degraded full-offboard-only item must never wedge (got rc=$rcP2): $outP2"
echo "ok: case p — a DEGRADED (not 'present') full-offboard-only item logs an advisory and lets the run proceed (exit 0), instead of permanently blocking every ensure"

# ── case q (codex-2 review finding, HIMMEL-2349): declining the FIRST
# (converge) confirm, when --prune is ALSO passed and there's a real
# towardDisabled item, must abort the WHOLE run — the disable confirm is
# never reached, so the item --prune would have removed stays untouched.
# A fresh, self-contained 2-item fixture (independent of the earlier
# cases' accumulated state): conv-item (profiles:["luna"] only,
# install-only, no removable) and prune-item (profiles:["core"] only,
# removable:per-item).
# ────────────────────────────────────────────────────────────────────────
repoQ="$work/repoQ"; mkdir -p "$repoQ/scripts/install" "$repoQ/scripts/lib"
cat > "$repoQ/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "conv-item", "kind": "wiring", "scopes": ["project"], "profiles": ["luna"], "deps": [],
      "probe": { "type": "file-exists", "path": "conv.marker" },
      "install": { "type": "wire", "target": "statusline" }
    },
    {
      "id": "prune-item", "kind": "wiring", "scopes": ["project"], "profiles": ["core"], "deps": [],
      "probe": { "type": "file-exists", "path": "prune.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" },
      "unwire": { "type": "wire", "target": "pretooluse-hooks" },
      "removable": "per-item"
    }
  ]
}
JSON
cat > "$repoQ/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > conv.marker
exit 0
SH
cat > "$repoQ/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > prune.marker
exit 0
SH
cat > "$repoQ/scripts/lib/unwire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${UNWIRE_LOG:-}" ] && echo "unwire-prune-item" >> "$UNWIRE_LOG"
rm -f prune.marker
exit 0
SH

targetQ="$work/targetQ"; mkdir -p "$targetQ"
cacheQ="$work/cacheQ"; mkdir -p "$cacheQ"
homeQ="$work/homeQ"; mkdir -p "$homeQ"
unwireLogQ="$work/unwire-log-q.txt"; : > "$unwireLogQ"
write_cache "$cacheQ/install-profile.json" adopter project none "" inline "" lean

runEnsureQ() {
  ( cd "$targetQ" && HIMMELCTL_REPO_ROOT="$(winpath "$repoQ")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheQ")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheQ")-luna-config.json" HOME="$homeQ" USERPROFILE="$(winpath "$homeQ")" UNWIRE_LOG="$(winpath "$unwireLogQ")" \
      "$node_bin" "$wizard" ensure "$@" )
}

# setup: converge under profile core --yes -> prune-item installed, conv-item
# stays absent (undesired under 'a').
set +e
outQsetup=$(runEnsureQ --profile core --yes </dev/null 2>&1); rcQsetup=$?
set -e
[ "$rcQsetup" -eq 0 ] || fail "case q setup: ensure --profile core --yes should converge prune-item (got rc=$rcQsetup): $outQsetup"
[ -f "$targetQ/prune.marker" ] || fail "case q setup: prune.marker should exist after the initial profile-a converge"
[ ! -f "$targetQ/conv.marker" ] || fail "case q setup: conv.marker should NOT exist yet (conv-item is undesired under profile core)"
echo "ok: case q (setup) — prune-item converged under profile core; conv-item stays uninstalled"

# reconcile to profile luna: conv-item flips desired:true (towardEnabled, needs
# install), prune-item flips desired:false while still physically present
# (towardDisabled, would be pruned IF --prune's own confirm were reached).
# Interactive decline ("n") at the FIRST (converge) prompt must abort the
# WHOLE run -- --prune's disable confirm below it must never be offered.
set +e
outQ=$(cd "$targetQ" && HIMMELCTL_REPO_ROOT="$(winpath "$repoQ")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheQ")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheQ")-luna-config.json" HOME="$homeQ" USERPROFILE="$(winpath "$homeQ")" UNWIRE_LOG="$(winpath "$unwireLogQ")" HIMMELCTL_INTERACTIVE=1 \
    "$node_bin" "$wizard" ensure --profile luna --prune <<<"n" 2>&1); rcQ=$?
set -e
[ "$rcQ" -eq 0 ] || fail "case q: an interactive decline of the converge prompt should exit 0 (got rc=$rcQ): $outQ"
grepq "$outQ" -F 'declined; nothing run' || fail "case q: expected the decline message (got: $outQ)"
# a distinctive substring of the honest message, not just "prune" -- the
# fixture's OWN item is named prune-item, so a bare case-insensitive
# 'prune' match would pass vacuously even without this wording fix.
grepq "$outQ" -F 'disable pass is skipped' || fail "case q: the decline message must ALSO make clear the pending --prune disable pass was skipped, not just the converge (got: $outQ)"
if grepq "$outQ" -F 'Proceed with disabling'; then
  fail "case q: the disable confirm must NEVER be reached after declining the converge confirm (got: $outQ)"
fi
[ ! -f "$targetQ/conv.marker" ] || fail "case q: conv-item must NOT have been installed after the decline"
[ -f "$targetQ/prune.marker" ] || fail "case q: prune-item must STILL be present -- the disable pass never ran"
[ ! -s "$unwireLogQ" ] || fail "case q: unwire-pretooluse-hooks.sh must NEVER have been invoked (spy log: $(cat "$unwireLogQ"))"
echo "ok: case q — declining the converge confirm when --prune is ALSO passed aborts the whole run; the disable confirm is never reached and prune-item is left untouched"

# ── case r (codex-4 review finding, HIMMEL-2349): describeDisableCommand()'s
# evidence line ("disabling would run: ...") is what the operator reads to
# decide whether to consent to a disable — an unquoted arg containing a
# space renders ambiguously and isn't copy-pasteable, and on Windows a
# space in a path is the common case (a target under "Program Files", a
# username with a space), not the edge case. A fresh, self-contained 1-item
# fixture (mirrors case p's pre-created-marker convention: the probe reads
# 'present' directly off a hand-placed marker, no install ever run) whose
# TARGET directory path itself contains a space, so unwireCommand()'s own
# settings.json arg necessarily has a space in it too. ────────────────────
repoR="$work/repoR"; mkdir -p "$repoR/scripts/install"
cat > "$repoR/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "space-item", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "space.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    }
  ]
}
JSON
targetR="$work/target with space"; mkdir -p "$targetR"
# vault.mode=none -> profile 'core', which EXCLUDES space-item
# (profiles:["luna","all"]) -> desired:false from the first run, no
# --profile reconcile needed to reach the toward-disabled evidence path
# (mirrors case p's setup).
: > "$targetR/space.marker"
cacheR="$work/cacheR"; mkdir -p "$cacheR"
homeR="$work/homeR"; mkdir -p "$homeR"
write_cache "$cacheR/install-profile.json" adopter project none "" inline "" lean

outR=$( cd "$targetR" && HIMMELCTL_REPO_ROOT="$(winpath "$repoR")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheR")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheR")-luna-config.json" HOME="$homeR" USERPROFILE="$(winpath "$homeR")" \
    "$node_bin" "$wizard" ensure --yes 2>&1 </dev/null )
grepq "$outR" -F 'disabling would run' || fail "case r: expected the disable evidence line (got: $outR)"
# the settings.json arg must render single-quoted (shellQuote's own
# convention — same helper displayCommand() already uses for the derived:
# line) precisely BECAUSE the target path contains a space -- an unquoted
# 'target with space' token would be ambiguous (3 words, not 1 path).
grepq "$outR" -E "'[^']*target with space[^']*settings\.json'" \
  || fail "case r: the disable evidence line must quote an arg containing a space so it's unambiguous/copy-pasteable (got: $outR)"
echo "ok: case r — the disable-command evidence line quotes an argument containing a space (consent evidence stays unambiguous)"

# ── case s (HIMMEL-2349 v2, console ruling 77): a hazardous --prune disable
# pass must NOT veto an UNRELATED, safe converge in the same run. item-s-a
# (profiles luna/all) is a prerequisite of item-s-c (profiles core/luna/all,
# stays desired under core) -- unwiring item-s-a would break item-s-c, same
# hazard shape as cases g/k/m/n. item-s-d (profiles core only) is a wholly
# UNRELATED item with a runnable install that only becomes desired once we
# reconcile to core. A plain `ensure --profile core --yes --prune` must:
#  - reject the item-s-a prune (hazard message on stderr, item-s-a's marker
#    + unwire spy log untouched)
#  - STILL converge item-s-d (its install runs, d.marker appears)
#  - exit 1 (not 2 -- a whole-run abort would be false, install ran; not 0 --
#    the prune pass genuinely did not run)
# This is the exact incident this ticket fixes: pre-v2, the hazard walk
# `return 2`'d before item-s-d's install was ever attempted. ─────────────
repoS="$work/repoS"; mkdir -p "$repoS/scripts/install" "$repoS/scripts/lib" "$repoS/scripts/machine-setup"
cat > "$repoS/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "item-s-a", "kind": "wiring", "scopes": ["project"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "s-a.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "item-s-c", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "luna", "all"], "deps": ["item-s-a"],
      "probe": { "type": "file-exists", "path": "s-c.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" }
    },
    {
      "id": "item-s-d", "kind": "plugin", "scopes": ["project"], "profiles": ["core"], "deps": [],
      "probe": { "type": "file-exists", "path": "s-d.marker" },
      "install": { "type": "plugins" }
    }
  ]
}
JSON
cat > "$repoS/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > s-a.marker
exit 0
SH
cat > "$repoS/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > s-c.marker
exit 0
SH
cat > "$repoS/scripts/machine-setup/install-plugins.sh" <<'SH'
#!/usr/bin/env bash
: > s-d.marker
exit 0
SH
cat > "$repoS/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${DISABLE_LOG_S:-}" ] && echo "unwire-item-s-a" >> "$DISABLE_LOG_S"
rm -f s-a.marker
exit 0
SH

targetS="$work/targetS"; mkdir -p "$targetS"
cacheS="$work/cacheS"; mkdir -p "$cacheS"
homeS="$work/homeS"; mkdir -p "$homeS"
write_cache "$cacheS/install-profile.json" adopter project none "" inline "" lean
logS="$work/disable-log-s.txt"; : > "$logS"

runEnsureS() {
  ( cd "$targetS" && HIMMELCTL_REPO_ROOT="$(winpath "$repoS")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheS")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheS")-luna-config.json" HOME="$homeS" USERPROFILE="$(winpath "$homeS")" DISABLE_LOG_S="$(winpath "$logS")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}

# Setup: converge item-s-a + item-s-c under profile luna (item-s-d is
# core-only, stays uninstalled -- it's the toward-ENABLED item this case
# proves still converges).
set +e
outS0=$(runEnsureS --profile luna --yes); rcS0=$?
set -e
[ "$rcS0" -eq 0 ] || fail "case s setup: converging item-s-a/item-s-c under luna should exit 0 (got rc=$rcS0): $outS0"
[ -f "$targetS/s-a.marker" ] || fail "case s setup: s-a.marker should exist after the initial luna converge"
[ -f "$targetS/s-c.marker" ] || fail "case s setup: s-c.marker should exist after the initial luna converge"
[ ! -f "$targetS/s-d.marker" ] || fail "case s setup: s-d.marker should NOT exist yet (item-s-d is not desired under luna)"

# case s (PRIMARY): --profile core --yes --prune. item-s-a flips
# toward-disabled (hazard: item-s-c still desired, depends on it);
# item-s-d flips toward-enabled (fresh install). Exit code asserted
# EXPLICITLY against both wrong values, not just != 0.
set +e
outS1=$(runEnsureS --profile core --yes --prune 2>&1); rcS1=$?
set -e
[ "$rcS1" -ne 2 ] || fail "case s: a hazardous prune must NOT abort the whole run (exit 2) -- that vetoes the unrelated, wanted converge (got rc=$rcS1): $outS1"
[ "$rcS1" -ne 0 ] || fail "case s: the prune pass was genuinely rejected -- exit 0 would falsely claim full success (got rc=$rcS1): $outS1"
[ "$rcS1" -eq 1 ] || fail "case s: expected exit 1 (got rc=$rcS1): $outS1"
grepq "$outS1" -F 'item-s-a' || fail "case s: the hazard message should name item-s-a (got: $outS1)"
grepq "$outS1" -F 'item-s-c' || fail "case s: the hazard message should name item-s-c (got: $outS1)"
[ ! -s "$logS" ] || fail "case s: item-s-a's unwire must NOT have run (spy log: $(cat "$logS"))"
[ -f "$targetS/s-a.marker" ] || fail "case s: s-a.marker must still exist -- item-s-a was never unwired despite the rejected prune"
[ -f "$targetS/s-d.marker" ] || fail "case s: s-d.marker MUST exist -- the unrelated, safe converge must still have run despite the rejected prune pass (this is the exact incident HIMMEL-2349 v2 fixes)"
# The hazard message must land on STDERR specifically, not merely somewhere
# in combined output.
set +e
outS1err=$(runEnsureS --profile core --yes --prune 2>&1 1>/dev/null)
set -e
grepq "$outS1err" -F 'item-s-a' || fail "case s: the hazard message must be printed on STDERR (got stderr: $outS1err)"
echo "ok: case s — a hazardous --prune disable pass is rejected WITHOUT vetoing an unrelated, safe converge in the same run (exit 1, item-s-a untouched, item-s-d installed)"

# case s (NEGATIVE CONTROL): prove the assertions above actually discriminate
# -- rerun the identical scenario against a MUTATED copy of bin.js that
# restores the pre-v2 `return 2` (whole-run abort) behavior at the exact
# hazard site, and confirm item-s-d does NOT get installed under it. If this
# control did NOT fail here, the primary case's "s-d.marker MUST exist"
# assertion above would not be proving anything.
# bin.js requires sibling ./lib/* and ../../hooks/* by relative path -- the
# mutated copy is written NEXT TO the real bin.js (see mutatedWizardInTree /
# cleanup() above) so those resolve to the same real files, no tree copy.
mutatedWizard="$mutatedWizardInTree"
mutateScript="$work/mutate-hazard.js"
# Single-quoted heredoc -- no bash interpolation of $/`` inside the JS body.
cat > "$mutateScript" <<'JS'
// Restores the pre-v2 hazard-walk behavior (hard `return 2`, aborting the
// WHOLE ensure run) at the one site this ticket changed to a collect+continue.
// Structural match (push-line followed by a bare `continue;`), not a literal
// text match against the message string -- so this stays robust even if the
// message wording is later edited, and fails LOUD (not silently) if the code
// shape it depends on has moved.
const fs = require('fs');
const srcPath = process.argv[2];
const outPath = process.argv[3];
const lines = fs.readFileSync(srcPath, 'utf8').split('\n');
const idx = lines.findIndex((l) => l.includes('pruneHazards.push(`would disable'));
if (idx === -1) {
  console.error('control fixture broken: hazard-collect line (pruneHazards.push) not found in ' + srcPath);
  process.exit(1);
}
const nextLine = lines[idx + 1];
if (nextLine.trim() !== 'continue;') {
  console.error('control fixture broken: expected a bare `continue;` immediately after the hazard-collect line, got: ' + JSON.stringify(nextLine));
  process.exit(1);
}
const pushLine = lines[idx];
const openParen = pushLine.indexOf('(', pushLine.indexOf('pruneHazards.push'));
const closeIdx = pushLine.lastIndexOf(');');
if (openParen === -1 || closeIdx === -1) {
  console.error('control fixture broken: could not locate push(...) parens on: ' + pushLine);
  process.exit(1);
}
const inner = pushLine.slice(openParen + 1, closeIdx); // the `...` template literal, backticks included
if (!inner.startsWith('`') || !inner.endsWith('`')) {
  console.error('control fixture broken: unexpected pruneHazards.push argument shape: ' + inner);
  process.exit(1);
}
const indent = pushLine.slice(0, pushLine.search(/\S/));
lines[idx] = `${indent}console.error(\`himmelctl: ${inner.slice(1, -1)}\`);`;
lines[idx + 1] = `${indent}return 2;`;
fs.writeFileSync(outPath, lines.join('\n'));
JS
"$node_bin" "$mutateScript" "$wizard" "$mutatedWizard" || fail "case s (negative control): failed to build the mutated pre-v2 bin.js -- the hazard site's source shape has drifted from what this control expects"

targetSn="$work/targetSn"; mkdir -p "$targetSn"
cacheSn="$work/cacheSn"; mkdir -p "$cacheSn"
homeSn="$work/homeSn"; mkdir -p "$homeSn"
write_cache "$cacheSn/install-profile.json" adopter project none "" inline "" lean
logSn="$work/disable-log-sn.txt"; : > "$logSn"
runEnsureSn() {
  ( cd "$targetSn" && HIMMELCTL_REPO_ROOT="$(winpath "$repoS")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheSn")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheSn")-luna-config.json" HOME="$homeSn" USERPROFILE="$(winpath "$homeSn")" DISABLE_LOG_S="$(winpath "$logSn")" \
      "$node_bin" "$mutatedWizard" ensure "$@" </dev/null )
}
set +e
outSn0=$(runEnsureSn --profile luna --yes); rcSn0=$?
set -e
[ "$rcSn0" -eq 0 ] || fail "case s (negative control) setup: converging item-s-a/item-s-c under luna via the MUTATED wizard should exit 0 (got rc=$rcSn0): $outSn0"
[ -f "$targetSn/s-a.marker" ] || fail "case s (negative control) setup: s-a.marker should exist after the initial luna converge"

set +e
outSn1=$(runEnsureSn --profile core --yes --prune 2>&1); rcSn1=$?
set -e
[ "$rcSn1" -eq 2 ] || fail "case s (negative control): the MUTATED (pre-v2) wizard should still hard-abort with exit 2 (got rc=$rcSn1) -- if it doesn't, the mutation above didn't actually restore the old behavior: $outSn1"
[ ! -f "$targetSn/s-d.marker" ] || fail "case s (negative control): s-d.marker must NOT exist -- under the pre-v2 return-2 behavior the converge never ran, proving the primary case's 's-d.marker MUST exist' assertion actually discriminates between old and new behavior"
echo "ok: case s (negative control) — the pre-v2 return-2 behavior genuinely blocks the unrelated converge (item-s-d never installed), proving the primary case's assertions discriminate"

# ═══════════════════════════════════════════════════════════════════════
# case t (CR fix, codex-1 round 6, HIMMEL-2349): the under-recorded
# EVIDENCE count must exclude items carrying a DELIBERATE per-item override
# — recorded operator intent is the opposite of an under-recorded record.
# state.json is hand-written directly (the only way to pre-seed a per-item
# override in a hermetic fixture — no CLI flow sets one for an arbitrary
# item), scope 'user' (a literal state.json key, unlike 'project' which
# resolves to the invocation cwd) — same technique
# test-wizard-recorded-profile.sh's cases f/f2 already establish for this
# exact "3 present, not-desired" shape. Three items, both toward-disabled
# fixtures below, differ ONLY in whether their persisted entries carry an
# override.
# ═══════════════════════════════════════════════════════════════════════
manifestT='{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "override-a", "kind": "wiring", "scopes": ["user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "override-a.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "override-b", "kind": "wiring", "scopes": ["user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "override-b.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" },
      "unwire": { "type": "wire", "target": "pretooluse-hooks" },
      "removable": "per-item"
    },
    {
      "id": "override-c", "kind": "wiring", "scopes": ["user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "override-c.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    }
  ]
}'
setup_repoT() {
  local dir="$1"
  mkdir -p "$dir/scripts/install" "$dir/scripts/lib"
  printf '%s' "$manifestT" > "$dir/scripts/install/manifest.json"
  cat > "$dir/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${DISABLE_LOG_T:-}" ] && echo "unwire-statusline" >> "$DISABLE_LOG_T"
rm -f override-a.marker override-c.marker
exit 0
SH
  cat > "$dir/scripts/lib/unwire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${DISABLE_LOG_T:-}" ] && echo "unwire-pretooluse-hooks" >> "$DISABLE_LOG_T"
rm -f override-b.marker
exit 0
SH
  ( cd "$dir" && : > override-a.marker && : > override-b.marker && : > override-c.marker )
}

# ── PRIMARY: three present items, each carrying a deliberate override. ────
repoT="$work/repoT"; setup_repoT "$repoT"
cacheT="$work/cacheT"; mkdir -p "$cacheT"
homeT="$work/homeT"; mkdir -p "$homeT"
write_cache "$cacheT/install-profile.json" adopter user none "" inline "" lean
cat > "$cacheT/state.json" <<'JSON'
{
  "schemaVersion": 1, "harness": "claude",
  "targets": {
    "user": {
      "profile": "core", "scope": "user",
      "items": {
        "override-a": { "enabled": false, "overrides": { "consent": "no" } },
        "override-b": { "enabled": false, "overrides": { "consent": "no" } },
        "override-c": { "enabled": false, "overrides": { "consent": "no" } }
      },
      "lastEnsured": null
    }
  }
}
JSON
logT="$work/disable-log-t.txt"; : > "$logT"

runEnsureT() {
  ( cd "$repoT" && HIMMELCTL_REPO_ROOT="$(winpath "$repoT")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheT")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheT")-luna-config.json" HOME="$homeT" USERPROFILE="$(winpath "$homeT")" DISABLE_LOG_T="$(winpath "$logT")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}

set +e
outT1=$(runEnsureT --prune --yes 2>&1); rcT1=$?
set -e
[ "$rcT1" -eq 0 ] || fail "case t (primary): ensure --prune --yes should exit 0 (got rc=$rcT1): $outT1"
if grepq "$outT1" -F 'UNDER-RECORDED'; then
  fail "case t (primary): a deliberate per-item override is recorded intent, not under-recording -- the guard must not fire (got: $outT1)"
fi
grepq "$outT1" -F 'converged' || fail "case t (primary): the completion summary should mention converged (got: $outT1)"
for id in override-a override-b override-c; do
  [ ! -f "$repoT/$id.marker" ] || fail "case t (primary): $id.marker should be GONE -- the disable pass must actually proceed for overridden-but-present items (got: $outT1)"
done
echo "ok: case t (primary) — three present items each carrying a deliberate override do NOT trip the under-recorded guard, and --prune genuinely disables all three"

# ── NEGATIVE CONTROL: identical fixture, but the SAME three items carry NO
# override -- proves the primary case's assertions discriminate rather than
# passing vacuously (the guard's threshold is exactly 3). ──────────────────
repoTn="$work/repoTn"; setup_repoT "$repoTn"
cacheTn="$work/cacheTn"; mkdir -p "$cacheTn"
homeTn="$work/homeTn"; mkdir -p "$homeTn"
write_cache "$cacheTn/install-profile.json" adopter user none "" inline "" lean
cat > "$cacheTn/state.json" <<'JSON'
{
  "schemaVersion": 1, "harness": "claude",
  "targets": {
    "user": {
      "profile": "core", "scope": "user",
      "items": {
        "override-a": { "enabled": false, "overrides": {} },
        "override-b": { "enabled": false, "overrides": {} },
        "override-c": { "enabled": false, "overrides": {} }
      },
      "lastEnsured": null
    }
  }
}
JSON
logTn="$work/disable-log-tn.txt"; : > "$logTn"

runEnsureTn() {
  ( cd "$repoTn" && HIMMELCTL_REPO_ROOT="$(winpath "$repoTn")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheTn")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheTn")-luna-config.json" HOME="$homeTn" USERPROFILE="$(winpath "$homeTn")" DISABLE_LOG_T="$(winpath "$logTn")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}

set +e
outTn1=$(runEnsureTn --prune --yes 2>&1); rcTn1=$?
set -e
[ "$rcTn1" -eq 0 ] || fail "case t (negative control): ensure --prune --yes should exit 0 (got rc=$rcTn1): $outTn1"
grepq "$outTn1" -F 'UNDER-RECORDED' || fail "case t (negative control): without overrides, the SAME 3-present shape must still trip the under-recorded guard (got: $outTn1)"
for id in override-a override-b override-c; do
  [ -f "$repoTn/$id.marker" ] || fail "case t (negative control): $id.marker must still exist -- the guard should have held --prune back (got: $outTn1)"
done
echo "ok: case t (negative control) — the identical fixture WITHOUT overrides still trips the under-recorded guard and --prune is held back, proving the primary case discriminates"

echo "PASS"
