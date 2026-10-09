// himmel-bus AG-UI collector (spec §13.1–13.4, threat T8). The only reader of the
// store for the fleet view: it yields STATE_DELTA events carrying metadata and a
// redacted summary, never a body. Redaction runs on the WHOLE text before the
// clip, so a clip cannot split a token into a fragment the patterns miss.
import { readdir, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { redact } from '../../../../scripts/handover/console-kit/redact.mjs';
import * as store from './store.mjs';

export const SUMMARY_CHARS = 120;
export const EXPIRY_MS = 4 * 60 * 60 * 1000;

const MARKER = /^(LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|RESUMED)\b/;
const DIRECTIVE = /^(HALT|GO|RETASK)\b/;

// Display classification only (spec §13.1); nothing reads `kind` to decide anything.
export function classify(rec) {
  const b = String(rec.b ?? '');
  if (rec.c === 1 && (redact(b) !== b || DIRECTIVE.test(b))) return 'ruling';
  if (MARKER.test(b)) return 'report';
  return 'data';
}

export function summarize(rec) {
  const text = redact(String(rec.s ?? rec.b ?? ''));
  return text.length > SUMMARY_CHARS ? `${text.slice(0, SUMMARY_CHARS - 1)}…` : text;
}

async function logNames(root) {
  const names = new Set();
  for (const file of await readdir(join(root, 'log'))) {
    // ponytail: a session name that itself ends `.<digits>` is read as a rotated segment, upgrade path is a peer-file lookup (HIMMEL-4834).
    const live = file.match(/^(.+)\.jsonl$/);
    const closed = file.match(/^(.+)\.\d+\.jsonl(\.zst|\.gz)?$/);
    const name = closed?.[1] ?? live?.[1];
    if (name && /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(name)) names.add(name);
  }
  return [...names];
}

async function delivery(root, name) {
  const file = join(root, 'cur', name);
  try {
    const [cur, st] = await Promise.all([readFile(file, 'utf8'), stat(file)]);
    // ponytail: the cursor stores no delivery time, so its mtime stands in, upgrade path is a stamped cursor field.
    return { n: JSON.parse(cur).n ?? 0, at: Math.round(st.mtimeMs) };
  } catch { return { n: 0, at: 0 }; }
}

async function acks(root) {
  const rows = [];
  let files = [];
  try { files = await readdir(join(root, 'ack')); } catch { return rows; }
  for (const file of files) {
    const m = file.match(/^(.+)\.jsonl$/);
    if (!m) continue;
    for (const line of (await readFile(join(root, 'ack', file), 'utf8')).split('\n')) {
      try { const row = JSON.parse(line); if (row && typeof row.i === 'string') rows.push({ ...row, by: m[1] }); } catch { /* torn line */ }
    }
  }
  return rows;
}

const delta = (timestamp, op, path, value) => ({ type: 'STATE_DELTA', delta: [{ op, path, value }], timestamp });

// Events newer than `since` (ms, exclusive), ordered by time. Refused sends are
// not stored in phase 1, so no `refused` event is produced.
export async function* busEvents(root, { since = 0, now = Date.now() } = {}) {
  const events = [];
  const acked = new Map();
  for (const row of await acks(root)) {
    acked.set(row.i, Math.min(row.t, acked.get(row.i) ?? Infinity));
    events.push(delta(row.t, 'add', `/bus/msgs/${row.i}/acked`, { t: row.t, by: row.by }));
  }
  for (const name of await logNames(root)) {
    const done = await delivery(root, name);
    for (const rec of await store.scan(root, name)) {
      const value = { i: rec.i, t: rec.t, f: rec.f, r: rec.r, len: Buffer.byteLength(String(rec.b ?? '')), c: rec.c ?? 0, kind: classify(rec), summary: summarize(rec) };
      if (rec.re !== undefined) value.re = rec.re;
      events.push(delta(rec.t, 'add', `/bus/msgs/${rec.i}`, value));
      if (rec.n <= done.n) events.push(delta(done.at, 'add', `/bus/msgs/${rec.i}/delivered`, done.at));
      // An ack that lands after the window does not erase the expiry already shown to live consumers.
      if (rec.c === 1 && (acked.get(rec.i) ?? Infinity) > rec.t + EXPIRY_MS && now - rec.t > EXPIRY_MS) events.push(delta(rec.t + EXPIRY_MS, 'add', `/bus/msgs/${rec.i}/expired`, rec.t + EXPIRY_MS));
    }
  }
  // Equal timestamps: the parent `/bus/msgs/<id>` sorts before its `/delivered|/acked|/expired` children.
  events.sort((a, b) => a.timestamp - b.timestamp || a.delta[0].path.length - b.delta[0].path.length);
  for (const event of events) if (event.timestamp > since) yield event;
}
