// scripts/where-are-we/lib/render.mjs
import { inFlight } from './fold.mjs';

// Natural-numeric comparator: split each key into maximal runs of digits /
// non-digits and compare run-by-run — digit runs numerically, others by
// codepoint — so 'HIMMEL-2' < 'HIMMEL-9' < 'HIMMEL-10' (not lexical, where
// '10' would sort before '2'). Deterministic + a total order (string tie-break
// on equal numeric value), which the byte-identical render contract requires.
function naturalCompare(a, b) {
  const ax = String(a).match(/\d+|\D+/g) || [];
  const bx = String(b).match(/\d+|\D+/g) || [];
  const n = Math.min(ax.length, bx.length);
  for (let i = 0; i < n; i++) {
    const as = ax[i];
    const bs = bx[i];
    if (/^\d/.test(as) && /^\d/.test(bs)) {
      const an = Number(as);
      const bn = Number(bs);
      if (an !== bn) return an < bn ? -1 : 1;
      if (as !== bs) return as < bs ? -1 : 1; // equal value, differ by leading zeros
    } else if (as !== bs) {
      return as < bs ? -1 : 1;
    }
  }
  if (ax.length !== bx.length) return ax.length < bx.length ? -1 : 1;
  return 0;
}

const byKey = (a, b) => naturalCompare(a.key, b.key);

function section(title, lines) {
  return `## ${title}\n\n` + (lines.length ? lines.join('\n') : '_(none)_') + '\n';
}

// Render a single item's card (the --for / branch-hit shape). Extracted from
// index.mjs so the L2 dock (lib/dock.mjs) reuses the identical shaping instead
// of duplicating it. Output is byte-identical to the prior inline version.
export function renderItem(item, locks) {
  const lines = [`# ${item.key}`, '', `- status: ${item.status || '—'}`,
    item.next_action ? `- next: ${item.next_action}` : null,
    (item.blockers && item.blockers.length) ? `- blockers: ${item.blockers.join('; ')}` : null,
    ...locks.map((l) => `- lock: ${l.lock}`)].filter(Boolean);
  return lines.join('\n') + '\n';
}

export function render(state) {
  const flight = inFlight(state);
  const awaiting = [...state.awaiting_operator].sort(byKey)
    .map((a) => `- **${a.key}** — ${a.items.join(', ')}`);
  const inflight = flight.filter((it) => it.status === 'in-progress').sort(byKey)
    .map((it) => `- **${it.key}**${it.next_action ? ` — ${it.next_action}` : ''}`);
  // Catch-all: non-terminal items with a status other than in-progress/blocked
  // (real examples: a to-do ticket, an open or closed-unmerged PR). flight is
  // already terminal-free (from inFlight()). Keyed on status != null so genuinely
  // status-less items stay unrendered (L1a design: retained in state.items for
  // --for, not surfaced in the digest).
  const other = flight
    .filter((it) => it.status != null && it.status !== 'in-progress' && it.status !== 'blocked')
    .sort(byKey)
    .map((it) => `- **${it.key}** (${it.status})${it.next_action ? ` — ${it.next_action}` : ''}`);
  const blocked = flight.filter((it) => it.status === 'blocked').sort(byKey)
    .map((it) => `- **${it.key}** — ${(it.blockers || []).join('; ') || 'blocked'}`);
  const locks = [...state.locks].sort(byKey).map((l) => `- **${l.key}** — ${l.lock}`);
  return [
    '# Where are we',
    '',
    section('Awaiting YOU (operator)', awaiting),
    section('In flight', inflight),
    section('Other in-flight', other),
    section('Blocked', blocked),
    section('Locks', locks),
  ].join('\n');
}
