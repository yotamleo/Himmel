'use strict';
// scripts/himmelctl/lib/status-report.js — the parameterized statusReport()
// library (HIMMEL-755 A2), extracted from bin.js's cmdStatus results loop
// (bin.js:1087-1125 pre-extraction, HIMMEL-756 T1.5/T1.6). PURE READ: no
// prompts, no state.json WRITE of any kind. Desired flags come from the
// target's PERSISTED state.json entry when one exists for {scope,
// targetPath} (state.js's own targetKeyForScope formula, replicated here so
// this lib needs no target object threaded in) — preserving any state that
// diverges from a fresh pure re-derivation (e.g. a manually-reconciled or
// hand-patched entry, as the shipped golden fixture exercises). When no
// entry exists yet for that target (never persisted), it falls back to an
// in-memory-only stateLib.deriveTarget() computation — never writes it.
// This is what makes the function safely callable with an EXPLICIT {scope,
// targetPath} that differs from cwd/repoRoot — unlike cmdStatus, it never
// falls back to process.cwd() or its own repoRoot() for the base target
// path; the caller decides, and a target with no persisted entry still
// reads a coherent (freshly-derived, unsaved) result.
//
// HIMMEL-2349: on top of the persisted flag, `desired` also gets an
// ADDITIVE-ONLY overlay from the CURRENTLY recorded install-profile
// (stateLib.recordedDesired() — the pure membership rule, never
// target.profile, which is derived once and never revisited) — never a
// replacement for the persisted flag, never something that can turn an item
// OFF. This stays inside the PURE READ contract below: no fs I/O beyond the
// stateLib.load() already happening, no mutation, no save().
//

// The ONE sanctioned state.json WRITE (deriving + persisting a target's
// FIRST entry) stays in cmdStatus, the CLI caller — this library only ever
// calls stateLib.load() (read) and stateLib.deriveTarget() (pure, no fs
// I/O), never stateLib.save() or stateLib.ensureTarget().
//
// Export: statusReport({ manifest, scope, targetPath, answers, itemIds?, state? })
//   -> { schemaVersion, target, items:[{id,kind,desired,actual,severity,detail}],
//        summary:{red,degraded,green,na} } — the SHIPPED JSON shape,
//   byte-stable with cmdStatus's pre-extraction output.
//
// Optional `state`: an ALREADY-LOADED (and possibly in-memory-reconciled,
// unsaved) state object to use for desired-flag lookup INSTEAD OF a fresh
// stateLib.load() from disk. Omitted (the shipped cmdStatus caller, and
// every other existing caller) -> unchanged disk-load behavior. This is what
// lets a caller preview an in-memory reconcile (e.g. `ensure --profile X
// --dry-run`) without persisting it first — `--dry-run`'s zero-mutation
// guarantee stays intact (no save happens either way), but the PREVIEW now
// reflects the reconcile instead of reading the stale on-disk entry.

const os = require('os');
const path = require('path');
const stateLib = require('./state.js');
const probesLib = require('./probes.js');
const lunaConfig = require('./luna-config.js');
const adopterProfileLib = require('./adopter-profile.js');

// Absolute himmel repo root, mirroring bin.js's own repoRoot()/himmelRoot()
// (this file lives one directory deeper, at scripts/himmelctl/lib/, hence
// the extra '..'). Deliberately duplicated rather than shared: this library
// is meant to be self-contained and independently testable, and the
// HIMMELCTL_REPO_ROOT seam is the same class as HIMMELCTL_CACHE_DIR.
function repoRoot() {
  return process.env.HIMMELCTL_REPO_ROOT || path.resolve(__dirname, '..', '..', '..');
}

// Expand a leading `~` to an absolute home path — mirrors bin.js's own
// expandHome(). Honors $HOME first (tests fake it), else os.homedir().
// CodeRabbit App finding (HIMMEL-2176 retask stage1-build-6d2e): `~\` (the
// separator Windows-style config values actually use, e.g. `~\Documents\luna`)
// was falling through to the bare `return p` below, same as the already-fixed
// `~/` gap. Only the exact `~/` / `~\` two-char prefix expands — a bare
// `~something` (POSIX home-of-another-user, or a filename that merely starts
// with a tilde) still falls through unexpanded, same as before. `path.join`
// doesn't split the remainder on `\` when run on POSIX, so a `~\`-prefixed
// path expanded on a POSIX host keeps its literal backslash as one odd path
// segment — harmless (not silently wrong, just an unusual segment name) and
// not worth a separator rewrite: `~\` is realistically only ever written on
// Windows, where both separators resolve correctly.
function expandHome(p) {
  if (typeof p !== 'string' || p === '') return p;
  const home = process.env.HOME || os.homedir();
  if (p === '~') return home;
  if (p.slice(0, 2) === '~/' || p.slice(0, 2) === '~\\') return path.join(home, p.slice(2));
  return p;
}

// The ONE place per-item probe ctx is constructed. Special case (and the
// ONLY one): luna-vault-scaffold's ctx.targetPath is the cached vault.path
// answer (expanded), not the caller's targetPath — its probe descriptor is
// a {vaultPath} placeholder with no other source of truth.
function ctxForItem(item, answers, targetPath, scope) {
  const resolvedTargetPath = item.id === 'luna-vault-scaffold'
    ? expandHome(answers.vault && answers.vault.path)
    : targetPath;
  return { repoRoot: repoRoot(), targetPath: resolvedTargetPath, scope, env: process.env };
}

// HIMMEL-2176 Task 7a: for a small, named set of items, desired-state can
// ALSO come from the adopter's live ~/.himmel/config.json — a SECONDARY
// source layered ON TOP of (never instead of) the state.json-derived signal
// above, since config.json can be toggled by the adopter (or future
// tooling) independently of whatever install-time profile/scope membership
// state.json's target entry was derived from. Purely additive: this only
// ever turns a false into a true, never the reverse — the persisted-state
// chain above still runs FIRST, unmodified. `configDoc` is null both when no
// config file exists yet (load() returns the schema-shaped default, not an
// error) and when load() throws (a malformed/invalid config) — this
// function stays agnostic to which; a genuine load() error is surfaced
// separately, at severity, by statusReport() itself (see CONFIG_OVERRIDE_ITEM_IDS
// below) rather than trusted to these items' own probes: bridge-health's,
// bridge-persistence's, and cadence-armed's probes all DO read
// lunaConfig.load() themselves (bridge-health since the CR-6 fix that made
// its cleanAbsence flag consult bridge.enabled, the same way cadence-armed's
// cleanAbsence already consulted luna.cadence.enabled, and bridge-persistence
// since HIMMEL-2176 Stage-1 PR-C's S6) — but only if the probe actually
// got to run, which it doesn't when configDesiredOverride silently returns
// false here and state.json hadn't independently enabled the item
// (HIMMEL-2176 CR fix, codex-4).
function configDesiredOverride(itemId, configDoc) {
  if (!configDoc) return false;
  if (itemId === 'cadence-armed') return Boolean(configDoc.luna && configDoc.luna.cadence && configDoc.luna.cadence.enabled);
  if (itemId === 'bridge-health') return Boolean(configDoc.bridge && configDoc.bridge.enabled);
  // HIMMEL-2176 Stage-1 PR-C, status item S6: bridge-persistence's own probe
  // ALSO gates entirely on bridge.enabled (see probes.js) — an operator
  // whose profile membership alone would read bridge-persistence
  // desired:false (e.g. a luna-only profile) but who explicitly opted the
  // bridge in via config must still have it probed, exactly the same
  // "additive OR" bridge-health already gets, so the two never disagree on
  // whether the bridge subsystem is opted into.
  if (itemId === 'bridge-persistence') return Boolean(configDoc.bridge && configDoc.bridge.enabled);
  return false;
}

// The three items configDesiredOverride() names above — the ONLY items whose
// desired-state this module derives from ~/.himmel/config.json. A malformed
// config makes desired-state for ALL of them fundamentally unknowable (see
// statusReport()'s configLoadError handling below), so all three are named
// here once rather than duplicating the id list.
const CONFIG_OVERRIDE_ITEM_IDS = new Set(['cadence-armed', 'bridge-health', 'bridge-persistence']);

function statusReport({ manifest, scope, targetPath, answers, itemIds, state: passedState }) {
  let items = manifest.items;
  if (itemIds) {
    const wanted = new Set(itemIds);
    items = manifest.items.filter((i) => wanted.has(i.id));
  }

  // Desired flags: use the CALLER-PASSED state object when given (an
  // already-loaded, possibly in-memory-reconciled-but-unsaved state — see
  // the `state?` doc above); otherwise read the target's PERSISTED
  // state.json entry when one exists (state.js's own targetKeyForScope
  // formula — project scope keys off path.resolve(targetPath), user scope
  // is the literal "user" key); otherwise fall back to an in-memory-only
  // deriveTarget() computation (never persisted — see module header).
  //
  // CR fix: deriveTarget() reads `cachedAnswers.scope` itself (for the
  // item.scopes.includes(scope) membership check) — the uncached fallback
  // must honor the EXPLICIT `scope` this function was called with, not
  // whatever scope happens to be baked into `answers` (an explicit scope
  // override is exactly what makes this function safely callable with a
  // {scope,targetPath} that differs from the caller's own cached answers —
  // see the module header). scopedAnswers is a shallow clone: the caller's
  // `answers` object is never mutated.
  const state = passedState || stateLib.load();
  const targetKey = scope === 'user' ? 'user' : path.resolve(targetPath);
  const scopedAnswers = Object.assign({}, answers, { scope });
  const target = state.targets[targetKey] || stateLib.deriveTarget(manifest, scopedAnswers);

  let configDoc = null;
  let configLoadError = null;
  try {
    configDoc = lunaConfig.load();
  } catch (e) {
    configLoadError = e;
  }

  // HIMMEL-2305: telegram-bridge/hermes-lanes/codex-cli carry no
  // ~/.himmel/config.json flag of their own (unlike bridge-health/
  // bridge-persistence/cadence-armed above) — the only record of whether the
  // adopter ever selected these features lives in the recorded wizard
  // answers. adopterProfileLib.resolveActiveFeatures() is the ONE place both
  // this file and bin.js's secrets walk derive "selected" from those
  // answers, so the two surfaces can never disagree. `null` (a caller with
  // no real answers to consult) fails OPEN: featureNotSelected() then always
  // reads false, so every downgrade below is skipped and today's full-nag
  // behavior is preserved rather than silently going quiet.
  const activeFeatures = adopterProfileLib.resolveActiveFeatures(answers);
  function featureNotSelected(feature) {
    return activeFeatures !== null && !activeFeatures.has(feature);
  }

  const results = [];
  for (const item of items) {
    // HIMMEL-2176 CR fix (codex-4): a malformed ~/.himmel/config.json used to
    // vanish silently here — configDoc stayed null, configDesiredOverride()
    // returned false, and if state.json's persisted entry hadn't
    // independently enabled cadence-armed/bridge-health, each was pushed as
    // an ordinary "not enabled" n/a row below and its probe never ran at
    // all, so the corrupt config was invisible in `himmelctl status`
    // entirely (HIMMEL-1128's loud-degradation rule: a check that can't
    // evaluate something must say so at severity, never go quiet). Surfaced
    // HERE, once, for both affected items, rather than trusting either
    // item's own probe to catch it (see configDesiredOverride's comment for
    // why that trust would be misplaced) — non-fatal: every OTHER item still
    // runs its own probe normally below.
    if (configLoadError && CONFIG_OVERRIDE_ITEM_IDS.has(item.id)) {
      results.push({
        id: item.id, kind: item.kind, desired: true, actual: 'degraded',
        severity: 'degraded',
        detail: `desired-state for this item cannot be determined: ${configLoadError.message}`,
      });
      continue;
    }
    const entry = target.items[item.id];
    const persistedDesired = Boolean(entry && entry.enabled);
    const cfgDesired = configDesiredOverride(item.id, configDoc);
    // HIMMEL-2349: additive-only overlay — the CURRENTLY recorded
    // install-profile (never target.profile, which is derived once and
    // never revisited — see state.js's own module header) can ALSO make an
    // item desired, on top of (never instead of) the persisted flag above.
    // Pure, read-only (state.js's recordedDesired() does no fs I/O and this
    // file never calls stateLib.save()/ensureTarget() — see the header
    // comment) — resolving this additively IN MEMORY is what lets `status`
    // report it without ever writing state.json.
    //
    // GATED on `!passedState` (CR fix, HIMMEL-2349 retask 01S-A-2349-b73d):
    // every bin.js caller that supplies its OWN `state` (cmdEnsure's pre/
    // post-check + its --items fullById map, cmdScopeSet's pre/post-check)
    // does so ONLY after already computing that state's authoritative
    // desired-ness itself — additiveReconcile() and/or an explicit
    // reconcileTarget() (a destructive, intentional recompute against a
    // requested {profile, scope} that can legitimately turn an item's
    // `enabled` OFF). A caller who hands this function a state it already
    // reconciled has already decided desired-state for every item in it —
    // this overlay must not silently re-enable one of them just because the
    // RECORDED install-profile's own category also happens to cover it
    // (test-wizard-statusreport.sh case d: an explicit reconcile down to
    // enabled:false must be reported as desired:false, not silently
    // overridden). The overlay is only needed — and only safe — on the
    // OTHER branch: no `state` supplied, so `state` above came from this
    // function's OWN fresh stateLib.load() (or the no-entry-yet
    // deriveTarget() fallback), which nothing has reconciled against the
    // CURRENT recorded profile since it was first derived — exactly
    // `himmelctl status`'s own call shape, and exactly the incident this
    // overlay exists to fix.
    //
    // `!passedState` alone only protects THIS invocation's own reconcile —
    // a `status` call always has passedState=false, so it needs a SEPARATE
    // guard against a PRIOR run's explicit reconcile (HIMMEL-2349, codex-1,
    // Critical): recordedDesired() itself checks `target.profileSource`
    // (stamped by state.js's reconcileTarget()) and refuses to re-enable
    // anything on a target the operator has explicitly reconciled, however
    // many runs ago. Without that, an explicit downgrade
    // (`ensure --profile core --prune`) would silently come back on the
    // very next ordinary `ensure`/`status`.
    // scopedAnswers (not answers): recordedDesired() -> itemMembership()
    // checks item.scopes against .scope, same reason line 163's deriveTarget
    // fallback uses it — a scope-override caller must not get membership
    // evaluated against answers.scope instead of the explicit scope.
    const recordedOverlay = !passedState && !persistedDesired && !cfgDesired
      && stateLib.recordedDesired(target, entry, item, scopedAnswers);
    const desired = persistedDesired || cfgDesired || recordedOverlay;
    if (!desired) {
      results.push({
        id: item.id, kind: item.kind, desired: false, actual: null,
        severity: 'n/a', detail: 'not enabled for this target (profile/scope)',
      });
      continue;
    }
    const ctx = ctxForItem(item, answers, targetPath, scope);
    const probe = probesLib.runProbe(item, ctx);
    let severity;
    let detail = probe.detail;
    if (probe.actual === 'present') {
      severity = 'green';
    } else if (probe.actual === 'degraded') {
      severity = 'degraded';
    } else {
      severity = 'red';
      // CR follow-up (HIMMEL-1017, HIMMEL-1012 review): graphify-mcp carries
      // profiles:["luna","all"] like any other luna-profile item, so every
      // luna/all target reads it desired:true — but registering the
      // graphify MCP server is a genuinely OPT-IN, manual step (adopt.sh's
      // --with-graphify flag / `claude mcp add graphify`; adopt.sh's own
      // wire_graphify_core() comment: "unlike qmd, graphify is NOT wired by
      // default"), and unlike qmd-binary/qmd-index it carries no `install`
      // descriptor of its own for `ensure` to converge — it is HINT-only
      // (see cmdEnsure's towardEnabled/hints split). Demanding it
      // unconditionally therefore produced a false red for every luna/all
      // operator who simply never opted in. Downgrade to n/a (informational)
      // instead of red: it is still probed every run (desired stays true),
      // so an operator who DOES register the MCP server still sees it flip
      // green — this only silences the alarm for the "never opted in" case.
      //
      // CR fix (HIMMEL-1017 CR round): only for a CLEAN absence —
      // probeMcpRegistered's 'absent' also covers an unreadable/unparseable
      // or malformed-shape config (probe.configError:true), which is NOT
      // "never opted in", it's a broken config that may well have LOST a
      // real registration (e.g. ~/.claude.json got corrupted after the
      // operator genuinely ran --with-graphify). That case must stay on the
      // standard red path with probe.detail intact, not get silently
      // swallowed into the same friendly opt-in message. And even for the
      // clean-absence case, the underlying probe diagnostic is APPENDED
      // rather than discarded, so the n/a row still names exactly which
      // file/server was checked.
      if (item.id === 'graphify-mcp' && !probe.configError) {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (adopt.sh --with-graphify / claude mcp add graphify)`;
      }
      // HIMMEL-1093: doc-guard-map's deepened probe (cmd:is_himmel_dev) reads
      // 'absent' for the ordinary, expected case — any checkout that isn't a
      // himmel CONTRIBUTOR checkout (the .himmel-dev marker is an opt-in
      // dropped by contributor setup; adopters/most engineers never have it,
      // by design — see scripts/guardrails/lib.sh's is_himmel_dev_repo()).
      // profiles:["core","all"] makes this desired:true for every project
      // target, so without this downgrade the fix for the OLD tautological
      // false-green would just become a false red for nearly everyone.
      // 'degraded' (repo root unresolvable — a genuine problem) is a
      // DIFFERENT probe.actual and never reaches this branch.
      if (item.id === 'doc-guard-map') {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (himmel contributor setup only; adopted/non-contributor checkouts intentionally have the gate off)`;
      }
      // HIMMEL-1100: the three cadence runners are armed via an explicit,
      // one-time `arm` operator action — never part of setup.sh/adopt.sh's
      // automatic install path (unlike codex-cli/hermes-checkout, which DO
      // have a dedicated installer script the operator is expected to have
      // run, and so stay on the plain red-if-absent path with every other
      // `dep`/`lane` item). profiles:["core","all"] makes these desired:true
      // broadly; without the downgrade, "never armed" (the common case for
      // most operators) would read as a false red rather than the honest
      // "opt-in, not armed" it actually is. 'degraded' (a broken resolver /
      // unexpected rc) is a DIFFERENT probe.actual and never reaches here.
      if (item.id === 'pipeline-cadence') {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (bash scripts/luna/pipeline-cadence.sh arm)`;
      }
      if (item.id === 'codex-sweep-cadence') {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (bash scripts/cleanup/codex-sweep-cadence.sh arm)`;
      }
      if (item.id === 'graphmap-cadence') {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (bash scripts/luna/graphmap-cadence.sh arm)`;
      }
      // HIMMEL-1100: the user-scope guardrail block is armed via an explicit
      // `setup-hooks.sh --guardrail-mode global` opt-in — never the default
      // (project mode). 'degraded' (armed but the baked node path rotted —
      // exactly what report_guardrail_block's own drift check exists to
      // catch) is a DIFFERENT probe.actual and never reaches here.
      // HIMMEL-2176: this item now carries a REAL install descriptor (see
      // install-engine.js's 'guardrail-block-global' wire target), but it
      // still writes the OPERATOR'S GLOBAL ~/.claude/settings.json — the
      // round-3 ruling forbids ever letting that happen on the strength of
      // the manifest membership alone. The ONLY thing that lifts this n/a
      // downgrade is an explicit, RECORDED consent — cmdEnsure's ask-first
      // gate (bin.js) is the ONE place that ever writes
      // entry.overrides.consent = 'yes', and it does so ONLY after a real
      // prompt (or an already-recorded 'yes' from a prior run) — never as a
      // side effect of a bare --yes or a non-interactive run. No recorded
      // answer, or an explicit decline ('no'), keeps this item exactly as
      // opt-in/invisible-to-ensure as it was before this ticket.
      if (item.id === 'guardrail-block-global' && (!entry.overrides || entry.overrides.consent !== 'yes')) {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (bash scripts/setup-hooks.sh --guardrail-mode global --yes, or run 'himmelctl ensure' interactively to consent + auto-wire)`;
      }
      // HIMMEL-1100: obsidian-second-brain is a MANUAL clone only — no himmel
      // script ever installs it (docs/setup/new-machine.md: "manual clone,
      // NOT in himmel marketplace"), the same "no automated path exists"
      // shape as graphify-mcp/doc-guard-map above.
      if (item.id === 'obsidian-second-brain') {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (manual clone: git clone https://github.com/eugeniughelbur/obsidian-second-brain ~/.claude/plugins/obsidian-second-brain)`;
      }
      // HIMMEL-1100 round 5 (glm-3): gemini-cli is an optional second-opinion
      // lane (gemini-subagent, /x-read family), not core tooling every
      // operator needs — unlike codex-cli/hermes-checkout, which stay
      // red-if-absent because they ARE core lanes here. profiles:["core",
      // "all"] makes this desired:true broadly, so a non-Gemini operator
      // would otherwise carry a permanent false red — exactly the noise
      // HIMMEL-1093/1100 exist to kill.
      if (item.id === 'gemini-cli') {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (npm install -g @google/gemini-cli)`;
      }
      // HIMMEL-2176 Task 7: cadence-armed's/engine-allowlist's/bridge-health's
      // OWN probes (probes.js) each mark the ordinary "never turned on"
      // absence with an additive `cleanAbsence` field (cadence-armed:
      // luna.cadence.enabled=false with nothing armed; engine-allowlist: no
      // luna cadence leg with a known engine requirement currently armed;
      // bridge-health: the Telegram token is entirely unconfigured AND
      // bridge.enabled is not true in ~/.himmel/config.json) — a fresh
      // adopter with no luna cadence / no bridge must not read a wall of red
      // for a subsystem they never opted into. A GENUINE problem (enabled:
      // true with nothing armed; an armed leg missing an allow-list entry;
      // bridge.enabled=true with the token still unconfigured; a
      // partially-configured or broken bridge) never carries this flag and
      // stays a loud red.
      if (item.id === 'cadence-armed' && probe.cleanAbsence) {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (bash scripts/luna/pipeline-cadence.sh arm, or set luna.cadence.enabled in ~/.himmel/config.json)`;
      }
      if (item.id === 'engine-allowlist' && probe.cleanAbsence) {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (no luna cadence legs armed yet; run scripts/luna/pipeline-cadence.sh arm)`;
      }
      if (item.id === 'bridge-health' && probe.cleanAbsence) {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (configure .claude/channels/telegram/.env + access.json, or set bridge.enabled in ~/.himmel/config.json, to enable the bridge)`;
      }
      // HIMMEL-2176 Stage-1 PR-C, status item S6: bridge-persistence's OWN
      // probe (probes.js) marks the ordinary "bridge never opted in" absence
      // with the SAME additive `cleanAbsence` field as bridge-health above
      // (bridge.enabled is not true in ~/.himmel/config.json) — a fresh
      // adopter who never opted into the bridge must not read a red
      // "persistence missing" for a subsystem they never turned on. A
      // GENUINE problem (bridge.enabled:true with no logon task/systemd
      // unit+linger, an unverifiable scheduler query, or an unsupported
      // platform) never carries this flag — probeBridgePersistence returns
      // 'degraded' (a loud warn) for every one of those, never 'absent', so
      // it never even reaches this red-downgrade branch to begin with.
      if (item.id === 'bridge-persistence' && probe.cleanAbsence) {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (set bridge.enabled in ~/.himmel/config.json to enable the bridge)`;
      }
      // HIMMEL-2326: observability-stack's own probe (probes.js) reads
      // 'absent' on posix UNCONDITIONALLY — Phase A (HIMMEL-922) ships a
      // win32-only installer, so a posix host can never converge this item
      // no matter what the operator does. profiles:["core","all"] makes it
      // desired:true for every core/all target — without this downgrade
      // this would be the exact false-red class doc-guard-map's own comment
      // above names ("without this downgrade the fix for the OLD
      // tautological false-green would just become a false red for nearly
      // everyone"). win32 stays on the standard red path: unlike
      // graphify-mcp/doc-guard-map, this item carries a REAL `install`
      // descriptor (install.type:'observability'), so `himmelctl ensure`
      // can genuinely converge a win32 'absent' — that stays a true alarm.
      // 'degraded' (a partial install, or an inconclusive win32 query) is a
      // DIFFERENT probe.actual and never reaches this branch on either
      // platform.
      if (item.id === 'observability-stack' && (ctx.platform || process.platform) !== 'win32') {
        severity = 'n/a';
        detail = `${probe.detail} — Phase A (HIMMEL-922) ships a Windows-only installer; tracked as HIMMEL-2333`;
      }
      // HIMMEL-2305: a cadence-off, bridge-off (or lane-not-selected) adopter
      // must not be nagged about credentials for a feature they never opted
      // into — see resolveActiveFeatures()'s own header for the shared
      // mapping and its fail-open contract.
      if (item.id === 'telegram-bridge' && featureNotSelected('bridge')) {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (telegram bridge not selected in your himmelctl profile; re-run himmelctl install to opt in)`;
      }
      if (item.id === 'hermes-lanes' && featureNotSelected('lane:hermes')) {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (hermes lane not selected; re-run himmelctl install --with-hermes)`;
      }
      if (item.id === 'codex-cli' && featureNotSelected('lane:codex')) {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (codex lane not selected; re-run himmelctl install --with-codex)`;
      }
    }
    // HIMMEL-2176 Task 7 (status item S2, design §3.5): luna-sources' own
    // probe (Task 6, refined by CR fixes — codex-3, and CR round 3 retask
    // stage1-build-6d2e — that also fold an individually-UNCONFIGURED source,
    // e.g. no reddit cookie file yet, into 'absent' rather than 'degraded',
    // and land an ALL-unrecognized profile on 'degraded' rather than
    // 'absent'; see probes.js's documented actual/detail contract and its own
    // landed tests) returns 'absent' for "no sources configured at all, or
    // every evaluated source is simply unconfigured" and 'degraded' for "at
    // least one CONFIGURED, evaluated source is unhealthy, OR every named
    // source is unrecognized by fetch-health.py (nothing is being monitored
    // at all)" — exactly BACKWARDS from this status item's own pass/warn/fail
    // table: an unconfigured luna install (or an individual unconfigured
    // source) should WARN (a fresh adopter who only set up one clip source is
    // not an alarm), while a genuinely broken configured clip source, or a
    // profile naming nothing the probe recognizes, should FAIL (a silently-
    // broken or entirely-unmonitored source is a real problem, not a shrug).
    // Remapped HERE rather than by changing probes.js's landed, already-
    // tested contract for a probe used nowhere else. Final mapping: all
    // healthy -> green; some unconfigured (none broken) -> degraded (warn);
    // any configured-but-broken source -> red (fail); every named source
    // unrecognized -> red (fail); nothing configured at all (no sources
    // listed, or every named source unconfigured) -> degraded (warn).
    if (item.id === 'luna-sources') {
      if (severity === 'degraded') severity = 'red';
      else if (severity === 'red') severity = 'degraded';
    }
    // HIMMEL-2349: surface WHY this item is desired when the persisted
    // state.json entry alone would have said "not enabled for this
    // target" — an operator must be able to SEE that their recorded
    // profile changed the answer, not merely observe the answer change.
    if (recordedOverlay) {
      detail = `${detail} — desired via the recorded install-profile (state.json target entry says disabled)`;
    }
    results.push({ id: item.id, kind: item.kind, desired: true, actual: probe.actual, severity, detail });
  }

  results.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

  const summary = { red: 0, degraded: 0, green: 0, na: 0 };
  for (const r of results) {
    if (r.severity === 'red') summary.red++;
    else if (r.severity === 'degraded') summary.degraded++;
    else if (r.severity === 'green') summary.green++;
    else summary.na++;
  }

  return { schemaVersion: 1, target: targetKey, items: results, summary };
}

module.exports = { statusReport, expandHome };
