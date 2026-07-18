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
      // Review carry-forward (bin.js pre-extraction #3): pre-commit-hooks
      // reads absent for a generic adopter (targetPath-relative, adopt.sh
      // never lays this file) — that is the intended "does THIS project
      // carry the gate" semantic, not a broken install; say so plainly.
      if (item.id === 'pre-commit-hooks') detail = 'no .pre-commit-config.yaml in this project';
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
