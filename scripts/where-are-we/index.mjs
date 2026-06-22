// scripts/where-are-we/index.mjs
import { pathToFileURL } from 'node:url';
import { UsageError } from './lib/errors.mjs';
import { readRecords } from './lib/ledger.mjs';
import { fold } from './lib/fold.mjs';
import { query } from './lib/query.mjs';
import { render, renderItem } from './lib/render.mjs';

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
  if (!a.ledger) throw new UsageError('--ledger <path> is required');
  const state = fold(readRecords(a.ledger));
  const result = query(state, a.scope);
  if (a.fmt === 'json') return JSON.stringify(result, null, 2);
  // md: render full state for global/branch-fallback; for a --for hit, render the item line.
  if (result.item) {
    return renderItem(result.item, result.locks);
  }
  if (result.locks && !result.inFlight) {
    return '## Locks\n\n' + (result.locks.length ? result.locks.map((l) => `- **${l.key}** — ${l.lock}`).join('\n') : '_(none)_') + '\n';
  }
  return render(state);
}

// CLI entry (not exercised by hermetic tests)
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  try { process.stdout.write(run(process.argv.slice(2))); }
  catch (e) {
    // Clean message for UsageError, full stack otherwise (rationale: lib/errors.mjs).
    process.stderr.write((e instanceof UsageError ? e.message : (e.stack || String(e))) + '\n');
    process.exit(1);
  }
}
