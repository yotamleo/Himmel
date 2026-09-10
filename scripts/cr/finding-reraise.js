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

function severityRank(value) {
  return { sug: 1, imp: 2, crit: 3 }[String(value || '')] || 0;
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
// HIMMEL-2901: "first seen" is the earliest round this fingerprint was ever
// OBSERVED on this branch, derived rather than persisted. An inherited re-raise
// carries its own observation round, so reading `round` off the latest event
// would report a later re-raise as the first sighting.
const firstSeen = new Map();
for (const row of ledgerRows) {
  if (row.kind === 'finding') {
    const state = { ...row };
    const sourceKey = findingKey(row.head, row.finding_id, row.artifact, row.perspective);
    states.set(sourceKey, state);
    if (state.fingerprint && validRound(state.round)) {
      const seenKey = dispositionKey(state);
      const seen = firstSeen.get(seenKey);
      if (seen === undefined || Number(state.round) < seen) firstSeen.set(seenKey, Number(state.round));
    }
    if (state.fingerprint && state.verdict) {
      const key = dispositionKey(state);
      const previous = latest.get(key);
      const event = { ...state, _sourceKey: sourceKey };
      // A row that carries the PREVIOUS event's disposition round did not
      // adjudicate anything: it inherited that disposition as a re-raise.
      const previousRound = previous && (previous.disposition_round || previous.round);
      const inherited = Boolean(previous && validRound(state.disposition_round) &&
        String(previousRound) === String(state.disposition_round));
      if (!event.disposition_severity) {
        event.disposition_severity = inherited
          ? (previous.disposition_severity || previous.severity)
          : state.severity;
      }
      // HIMMEL-2901: remember WHICH adjudication this inherited from, so a
      // later correction to that original row still reaches the ceiling it
      // handed down. `previous._originKey` collapses a chain of re-raises onto
      // the one row that was actually adjudicated.
      if (inherited) event._originKey = previous._originKey || previous._sourceKey;
      latest.set(key, event);
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
    const event = { ...target, disposition_severity: target.severity, _sourceKey: targetKey };
    // HIMMEL-2901: the amend states the round it adjudicated in. The producer
    // round remains the fallback so pre-2901 amends keep rendering as before.
    if (validRound(row.disposition_round)) event.disposition_round = Number(row.disposition_round);
    else if (validRound(target.round)) event.disposition_round = Number(target.round);
    latest.set(dispositionKey(event), event);
    continue;
  }

  // Metadata-only amendments may refine the current disposition, but they do
  // not become a new adjudication event. Update only when this exact source is
  // still authoritative; never revive an older verdict over a newer row.
  if (target.fingerprint &&
      (Object.prototype.hasOwnProperty.call(row.set, 'reason') ||
       Object.prototype.hasOwnProperty.call(row.set, 'deferred_to') ||
       Object.prototype.hasOwnProperty.call(row.set, 'severity'))) {
    const key = dispositionKey(target);
    const current = latest.get(key);
    // HIMMEL-2901: the amended row is authoritative either because it IS the
    // current event, or because the current event merely inherited its
    // disposition from it. Any other row of the same fingerprint is a
    // bystander and must not move the ceiling.
    const isCurrent = Boolean(current && current._sourceKey === targetKey);
    const isOrigin = Boolean(current && !isCurrent && current._originKey === targetKey);
    if (isCurrent || isOrigin) {
      if (Object.prototype.hasOwnProperty.call(row.set, 'reason')) current.reason = target.reason;
      if (Object.prototype.hasOwnProperty.call(row.set, 'deferred_to')) current.deferred_to = target.deferred_to;
      if (Object.prototype.hasOwnProperty.call(row.set, 'severity')) {
        // The inherited row's own observed severity stays its own; only the
        // DISPOSITION ceiling it carries forward is corrected.
        if (isCurrent) current.severity = target.severity;
        current.disposition_severity = target.severity;
      }
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
  const priorKey = fingerprint
    ? [e.REVIEW_BRANCH, fingerprint, artifact, perspective].join(keySep)
    : '';
  const prior = priorKey ? latest.get(priorKey) : null;
  const sourceRound = prior && (prior.disposition_round || prior.round);
  const firstSeenRound = priorKey ? firstSeen.get(priorKey) : undefined;
  const dispositionSeverity = prior && (prior.disposition_severity || prior.severity);
  const currentSeverityRank = severityRank(severity);
  const dispositionSeverityRank = severityRank(dispositionSeverity);
  const suppress = Boolean(prior && validRound(sourceRound) &&
    currentSeverityRank && dispositionSeverityRank && currentSeverityRank <= dispositionSeverityRank &&
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
    row.disposition_severity = dispositionSeverity;
    if (prior.reason) row.reason = prior.reason;
    if (prior.deferred_to) row.deferred_to = prior.deferred_to;
    const ticket = prior.verdict === 'deferred' && prior.deferred_to ? ` [${prior.deferred_to}]` : '';
    // HIMMEL-2901: name both rounds only when the finding was adjudicated in a
    // later round than it was first seen in; otherwise one round is the truth.
    const rounds = validRound(firstSeenRound) && String(firstSeenRound) !== String(sourceRound)
      ? `first seen r${firstSeenRound} · dispositioned r${sourceRound}`
      : `r${sourceRound}`;
    reraises.push(`${text} — RE-RAISE (${rounds} ${prior.verdict})${ticket}`);
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
