// scripts/where-are-we/index.mjs
import { pathToFileURL } from 'node:url';
import { readRecords } from './lib/ledger.mjs';
import { fold } from './lib/fold.mjs';
import { query } from './lib/query.mjs';
import { render } from './lib/render.mjs';

function parseArgs(argv) {
  const a = { ledger: null, scope: { mode: 'global' }, fmt: 'md' };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--ledger') a.ledger = argv[++i];
    else if (t === '--for') a.scope = { mode: 'for', key: argv[++i] };
    else if (t === '--branch') a.scope = { mode: 'branch', name: argv[++i] };
    else if (t === '--locks') a.scope = { mode: 'locks' };
    else if (t === '--json') a.fmt = 'json';
    else if (t === '--md') a.fmt = 'md';
  }
  return a;
}

export function run(argv) {
  const a = parseArgs(argv);
  if (!a.ledger) throw new Error('--ledger <path> is required');
  const state = fold(readRecords(a.ledger));
  const result = query(state, a.scope);
  if (a.fmt === 'json') return JSON.stringify(result, null, 2);
  // md: render full state for global/branch-fallback; for a --for hit, render the item line.
  if (result.item) {
    const it = result.item;
    const lines = [`# ${it.key}`, '', `- status: ${it.status || '—'}`,
      it.next_action ? `- next: ${it.next_action}` : null,
      (it.blockers && it.blockers.length) ? `- blockers: ${it.blockers.join('; ')}` : null,
      ...result.locks.map((l) => `- lock: ${l.lock}`)].filter(Boolean);
    return lines.join('\n') + '\n';
  }
  if (result.locks && !result.inFlight) {
    return '## Locks\n\n' + (result.locks.length ? result.locks.map((l) => `- **${l.key}** — ${l.lock}`).join('\n') : '_(none)_') + '\n';
  }
  return render(state);
}

// CLI entry (not exercised by hermetic tests)
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  try { process.stdout.write(run(process.argv.slice(2))); }
  catch (e) { process.stderr.write(String(e.message) + '\n'); process.exit(1); }
}
