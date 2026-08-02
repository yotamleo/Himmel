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
function expandHome(p) {
  if (typeof p !== 'string' || p === '') return p;
  const home = process.env.HOME || os.homedir();
  if (p === '~') return home;
  if (p.slice(0, 2) === '~/') return path.join(home, p.slice(2));
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

  const results = [];
  for (const item of items) {
    const entry = target.items[item.id];
    const desired = Boolean(entry && entry.enabled);
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
      if (item.id === 'guardrail-block-global') {
        severity = 'n/a';
        detail = `${probe.detail} — opt-in (bash scripts/setup-hooks.sh --guardrail-mode global --yes)`;
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

module.exports = { statusReport };
