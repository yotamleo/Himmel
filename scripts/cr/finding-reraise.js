'use strict';

const fs = require('fs');
const path = require('path');
const { findingFingerprint } = require('./finding-fingerprint');

const e = process.env;
const sep = String.fromCharCode(28);
const keySep = String.fromCharCode(31);
const artifact = 'diff';
const perspective = 'off';

function findingKey(head, id, rowArtifact, rowPerspective) {
  return [head, id, rowArtifact || 'diff', rowPerspective || 'off'].join(keySep);
}

function dispositionKey(row) {
  return [row.branch, row.fingerprint, row.artifact || 'diff', row.perspective || 'off'].join(keySep);
}

function validRound(value) {
  return /^[1-9][0-9]*$/.test(String(value == null ? '' : value));
}

function validDeferred(row) {
  return row.verdict === 'deferred' &&
    /^[A-Z][A-Z0-9]*-[0-9]+$/.test(String(row.deferred_to || '')) &&
    Boolean(String(row.reason || '').trim());
}

let ledgerRows = [];
try {
  ledgerRows = fs.existsSync(e.CR_LEDGER)
    ? fs.readFileSync(e.CR_LEDGER, 'utf8').split('\n').filter(Boolean).map(JSON.parse)
    : [];
} catch (err) {
  process.stderr.write(`finding-reraise: cannot read ledger: ${err.message}\n`);
  process.exit(2);
}

const states = new Map();
const latest = new Map();
for (const row of ledgerRows) {
  if (row.kind === 'finding') {
    const state = { ...row };
    const sourceKey = findingKey(row.head, row.finding_id, row.artifact, row.perspective);
    states.set(sourceKey, state);
    if (state.fingerprint && state.verdict) {
      latest.set(dispositionKey(state), { ...state, _sourceKey: sourceKey });
    }
    continue;
  }
  if (row.kind !== 'amend' || !row.set || typeof row.set !== 'object') continue;
  const targetKey = findingKey(row.target_head, row.finding_id, row.artifact, row.perspective);
  const target = states.get(targetKey);
  if (!target) continue;

  const oldFile = target.file;
  const oldFingerprint = target.fingerprint;
  const oldDispositionKey = oldFingerprint ? dispositionKey(target) : '';
  Object.assign(target, row.set);

  // The fingerprint includes the file anchor, but the durable text may be a
  // truncated display copy. A file correction therefore invalidates the old
  // identity rather than guessing a replacement fingerprint from incomplete
  // claim material. The invalidation is itself the latest identity event, so
  // an occurrence at the old anchor fails active.
  const fileChanged = Object.prototype.hasOwnProperty.call(row.set, 'file') && target.file !== oldFile;
  if (fileChanged) {
    if (oldDispositionKey) {
      latest.set(oldDispositionKey, {
        ...target,
        fingerprint: oldFingerprint,
        verdict: 'identity-changed',
        _sourceKey: targetKey,
      });
    }
    target.fingerprint = '';
    continue;
  }

  if (Object.prototype.hasOwnProperty.call(row.set, 'verdict') && target.fingerprint && target.verdict) {
    const event = { ...target, _sourceKey: targetKey };
    if (validRound(target.round)) event.disposition_round = Number(target.round);
    latest.set(dispositionKey(event), event);
    continue;
  }

  // Metadata-only amendments may refine the current disposition, but they do
  // not become a new adjudication event. Update only when this exact source is
  // still authoritative; never revive an older verdict over a newer row.
  if (target.fingerprint &&
      (Object.prototype.hasOwnProperty.call(row.set, 'reason') ||
       Object.prototype.hasOwnProperty.call(row.set, 'deferred_to'))) {
    const key = dispositionKey(target);
    const current = latest.get(key);
    if (current && current._sourceKey === targetKey) {
      if (Object.prototype.hasOwnProperty.call(row.set, 'reason')) current.reason = target.reason;
      if (Object.prototype.hasOwnProperty.call(row.set, 'deferred_to')) current.deferred_to = target.deferred_to;
    }
  }
}

const active = { crit: [], imp: [], sug: [] };
const reraises = [];
const enriched = [];
const input = fs.readFileSync(0, 'utf8').split('\n').filter(Boolean);
for (const line of input) {
  const parts = line.split(sep);
  const [model, id, severity, file, lineNumber] = parts;
  const text = parts.slice(5).join(sep);
  if (!id) continue;

  const fingerprint = findingFingerprint(model, file, text);
  const prior = fingerprint
    ? latest.get([e.REVIEW_BRANCH, fingerprint, artifact, perspective].join(keySep))
    : null;
  const sourceRound = prior && (prior.disposition_round || prior.round);
  const suppress = Boolean(prior && validRound(sourceRound) &&
    (prior.verdict === 'disproved' || validDeferred(prior)));

  const row = {
    branch: e.REVIEW_BRANCH,
    head: e.REVIEW_HEAD,
    model,
    id,
    severity,
    file,
    line: lineNumber,
    verdict: '',
    artifact,
    perspective,
    text,
  };
  if (validRound(e.CR_REVIEW_ROUND)) row.round = Number(e.CR_REVIEW_ROUND);

  if (suppress) {
    row.verdict = prior.verdict;
    row.disposition_round = Number(sourceRound);
    if (prior.reason) row.reason = prior.reason;
    if (prior.deferred_to) row.deferred_to = prior.deferred_to;
    const ticket = prior.verdict === 'deferred' && prior.deferred_to ? ` [${prior.deferred_to}]` : '';
    reraises.push(`${text} — RE-RAISE (r${sourceRound} ${prior.verdict})${ticket}`);
  } else if (active[severity]) {
    active[severity].push(text);
  }
  enriched.push(JSON.stringify(row));
}

for (const severity of Object.keys(active)) {
  fs.writeFileSync(path.join(e.PANEL_SPOOL_DIR, `.active-${severity}`), active[severity].join('\n'));
}
fs.writeFileSync(path.join(e.PANEL_SPOOL_DIR, '.reraises'), reraises.join('\n'));
process.stdout.write(enriched.length ? `${enriched.join('\n')}\n` : '');
