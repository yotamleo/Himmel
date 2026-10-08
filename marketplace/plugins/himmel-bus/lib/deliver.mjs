// Delivery worker for scripts/hooks/bus-deliver-hook.sh (HIMMEL-4828).
// Reads this session's bus log, formats the verified records and writes them to
// stdout, then commits the cursor past the records it emitted. Commit is AFTER
// the write: a crash between the two re-emits the same #n (at-least-once).
import { writeSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import * as store from './store.mjs';
import { resolveIdentity, loadPeers } from './identity.mjs';

// Claude Code 2.1.295 caps a hook's additionalContext at 8000 chars and 200
// lines (measured from the binary, see the PR). Stay under both.
export const BATCH_CHARS = 7500;
export const BATCH_LINES = 190;
const INLINE_BYTES = 1500;
const SUMMARY_CHARS = 300;
const RECORD_LINES = 20;
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
// C0 except tab/newline, DEL, C1, U+2028/2029: none may start a line of ours.
const CONTROL = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u2028\u2029]/g;
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

const clean = text => String(text ?? '').replace(CONTROL, '·');

function ulid(now = Date.now()) {
  let time = '';
  for (let t = now, i = 0; i < 10; i++, t = Math.floor(t / 32)) time = ALPHABET[t % 32] + time;
  return time + [...randomBytes(16)].map(byte => ALPHABET[byte % 32]).join('');
}

export function formatRecord(rec, { console: owner, re } = {}) {
  const from = NAME.test(String(rec.f)) ? rec.f : '?';
  const trusted = rec.c === 1 && from === owner;
  const head = `bus #${rec.n} ${trusted ? '' : 'data '}from ${from}${re ? ` re #${re}` : ''}:`;
  const body = String(rec.b ?? '');
  const text = Buffer.byteLength(body) <= INLINE_BYTES
    ? clean(body)
    : `${clean((typeof rec.s === 'string' && rec.s ? rec.s : body).slice(0, SUMMARY_CHARS))}\n[full: read ${rec.n}]`;
  // One record must fit the batch line cap on its own: clip many-line bodies.
  const rows = text.split('\n');
  if (rows.length > RECORD_LINES) rows.splice(RECORD_LINES, rows.length, `[clipped; full: read ${rec.n}]`);
  return [head, ...rows.map(line => `| ${line}`)].join('\n');
}

async function replyRef(root, rec) {
  if (!rec.re || !NAME.test(String(rec.f))) return undefined;
  return (await store.scan(root, rec.f)).find(r => r.i === rec.re)?.n;
}

export function envelope(event, text) {
  return event === 'PostToolUse'
    ? JSON.stringify({ hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: text } })
    : text;
}

export async function main(input, { name = process.env.HIMMEL_BUS_NAME } = {}) {
  if (!name || !NAME.test(name) || input.agent_id) return;
  const root = await store.busRoot();
  const me = await resolveIdentity(root);
  if (me.name !== name) return;
  const peers = await loadPeers(root);
  const owner = peers[name]?.role === 'console' ? undefined : peers[name]?.console;
  const event = input.hook_event_name === 'SessionStart' ? 'SessionStart' : 'PostToolUse';
  // writeSync may write less than asked; loop so a short write is never committed past.
  const emit = text => {
    const buf = Buffer.from(envelope(event, text) + '\n');
    for (let off = 0; off < buf.length;) off += writeSync(1, buf, off);
  };

  const { records, next, cursors, notice } = await store.read(root, name);
  if (notice) {
    // The log is halted already; telling the console is best effort.
    const told = owner && await store.append(root, owner, { i: ulid(), t: Date.now(), f: 'bus', r: owner, b: `${notice}; ${name} is halted` })
      .then(() => true, () => false);
    emit(`${notice}; ${name} is halted${told ? ', console notified' : ''}`);
    return;
  }
  if (!records.length) return;

  const blocks = [];
  let chars = 0, lines = 0;
  for (const rec of records) {
    const block = formatRecord(rec, { console: owner, re: await replyRef(root, rec) });
    const n = block.split('\n').length;
    if (blocks.length && (chars + block.length + 1 > BATCH_CHARS || lines + n > BATCH_LINES)) break;
    blocks.push(block); chars += block.length + 1; lines += n;
  }
  emit(blocks.join('\n'));
  await store.commit(root, name, blocks.length === records.length ? next : cursors[blocks.length - 1]);
}
