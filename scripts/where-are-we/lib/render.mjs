// scripts/where-are-we/lib/render.mjs
import { inFlight } from './fold.mjs';

const byKey = (a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0);

function section(title, lines) {
  return `## ${title}\n\n` + (lines.length ? lines.join('\n') : '_(none)_') + '\n';
}

export function render(state) {
  const flight = inFlight(state);
  const awaiting = [...state.awaiting_operator].sort(byKey)
    .map((a) => `- **${a.key}** — ${a.items.join(', ')}`);
  const inflight = flight.filter((it) => it.status === 'in-progress').sort(byKey)
    .map((it) => `- **${it.key}**${it.next_action ? ` — ${it.next_action}` : ''}`);
  const blocked = flight.filter((it) => it.status === 'blocked').sort(byKey)
    .map((it) => `- **${it.key}** — ${(it.blockers || []).join('; ') || 'blocked'}`);
  const locks = [...state.locks].sort(byKey).map((l) => `- **${l.key}** — ${l.lock}`);
  return [
    '# Where are we',
    '',
    section('Awaiting YOU (operator)', awaiting),
    section('In flight', inflight),
    section('Blocked', blocked),
    section('Locks', locks),
  ].join('\n');
}
