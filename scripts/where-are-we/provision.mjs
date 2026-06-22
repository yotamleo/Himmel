// scripts/where-are-we/provision.mjs — L3 orchestrator-seam CLI (HIMMEL-517).
// Two verbs, the two directions of the push-side seam:
//   slice --ledger <p> --for <KEY>            READ  → prints the KEY's slice
//                                                    (empty on miss/contentless)
//   emit  --ledger <p> --key <KEY> [fields]   WRITE → appends ONE structured
//                                                    record via appendRecords
// Pure logic lives in lib/provision.mjs; this is the thin impure seam. main()
// takes injected deps (readRecords/appendRecords) so tests stay hermetic —
// local-fs-only (a temp ledger), no network/collector surface. Mirrors
// collect.mjs / index.mjs.
import { pathToFileURL } from 'node:url';
import { readRecords } from './lib/ledger.mjs';
import { appendRecords } from './lib/append.mjs';
import { fold } from './lib/fold.mjs';
import { renderSlice, buildEmitRecord } from './lib/provision.mjs';
import { UsageError } from './lib/errors.mjs';

// Split a ';'-separated list into a trimmed, empty-dropped array.
function parseList(s) {
  return String(s).split(';').map((x) => x.trim()).filter((x) => x.length > 0);
}

export function parseArgs(argv) {
  const a = {
    verb: argv[0], ledger: null, key: null, now: null,
    next_action: null, blockers: null, awaiting_operator: null,
    clearNext: false, clearBlockers: false, clearAwaiting: false,
  };
  for (let i = 1; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--ledger') a.ledger = argv[++i];
    else if (t === '--for' || t === '--key') a.key = argv[++i];
    else if (t === '--now') a.now = argv[++i];
    else if (t === '--next-action') a.next_action = argv[++i];
    else if (t === '--blockers') a.blockers = parseList(argv[++i]);
    else if (t === '--awaiting') a.awaiting_operator = parseList(argv[++i]);
    else if (t === '--clear-next') a.clearNext = true;
    else if (t === '--clear-blockers') a.clearBlockers = true;
    else if (t === '--clear-awaiting') a.clearAwaiting = true;
  }
  return a;
}

// main(argv, deps). `now` is resolved here as a string ISO timestamp (the
// collect.mjs precedent), NOT injected. Returns a string: the rendered slice
// (slice) or an "appended=N dropped=M" summary (emit).
export function main(argv, deps = { readRecords, appendRecords }) {
  const read = deps.readRecords ?? readRecords;
  const append = deps.appendRecords ?? appendRecords;
  const a = parseArgs(argv);
  const now = a.now ?? new Date().toISOString();

  if (a.verb === 'slice') {
    if (!a.key) throw new UsageError('slice: --for <KEY> is required');
    if (!a.ledger) throw new UsageError('slice: --ledger <path> is required');
    let records;
    // Fail-open: a corrupt/half-written ledger must not break plan generation.
    try { records = read(a.ledger); }
    catch { return ''; }
    return renderSlice(fold(records), a.key);
  }

  if (a.verb === 'emit') {
    if (!a.ledger) throw new UsageError('emit: --ledger <path> is required');
    const rec = buildEmitRecord(a, now); // throws UsageError on bad/empty/conflict
    const r = append(a.ledger, [rec]);
    return `appended=${r.appended} dropped=${r.dropped}`;
  }

  throw new UsageError(`unknown verb: ${a.verb ?? '(none)'} (expected 'slice' or 'emit')`);
}

// CLI entry (not exercised by hermetic tests). slice is fail-open (exit 0 even on
// empty); UsageError → clean message + exit 1; unexpected → stack + exit 1.
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  try {
    const out = main(process.argv.slice(2));
    process.stdout.write(out.endsWith('\n') || out === '' ? out : out + '\n');
  } catch (e) {
    process.stderr.write((e instanceof UsageError ? e.message : (e.stack || String(e))) + '\n');
    process.exit(1);
  }
}
