// scripts/where-are-we/dock.mjs — L2 dock CLI seam.
// Renders the relevant where-are-we slice from the existing ledger (sync, no
// network) and reports whether the ledger is stale via a flag-file (NOT an exit
// code — an exit code would conflict with the hook's fail-open ERR trap). The
// SessionStart hook (scripts/hooks/inject-where-are-we.sh) consumes stdout +
// the flag-file. main() takes injected deps so the logic is hermetically tested
// (tests/dock.cli.test.mjs); only the thin CLI entry touches fs/clock.
import { pathToFileURL } from 'node:url';
import fs from 'node:fs';
import { readRecords } from './lib/ledger.mjs';
import { isStale, renderDock } from './lib/dock.mjs';

export function parseArgs(argv) {
  const a = { ledger: null, marker: null, branch: '', staleHours: 6, staleFlagFile: null, now: null };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--ledger') a.ledger = argv[++i];
    else if (t === '--marker') a.marker = argv[++i];
    else if (t === '--branch') a.branch = argv[++i] ?? '';
    else if (t === '--stale-hours') {
      const n = Number(argv[++i]);
      a.staleHours = Number.isFinite(n) ? Math.max(1, n) : 6;
    }
    else if (t === '--stale-flag-file') a.staleFlagFile = argv[++i];
    else if (t === '--now') {
      const v = argv[++i];
      const n = /^\d+$/.test(v) ? Number(v) : Date.parse(v);
      a.now = Number.isFinite(n) ? n : null; // unparseable → fall back to deps.now
    }
  }
  return a;
}

// Returns { text, stale }. Fail-open: a malformed/unreadable ledger yields
// {text:'', stale:true} so the hook re-collects and HEALS the ledger rather
// than freezing on it. (readRecords returns [] on ENOENT but THROWS on
// malformed JSON — e.g. a half-written record from a killed background collect.)
export function main(argv, deps = { statMtime: defaultStatMtime, readRecords, now: Date.now() }) {
  const a = parseArgs(argv);
  const nowMs = a.now ?? deps.now;
  const markerMtime = deps.statMtime(a.marker);
  let records;
  try { records = deps.readRecords(a.ledger); }
  catch { return { text: '', stale: true }; }
  const scope = a.branch ? { mode: 'branch', name: a.branch } : { mode: 'global' };
  return {
    text: renderDock(records, scope, nowMs, markerMtime),
    stale: isStale(markerMtime, nowMs, a.staleHours),
  };
}

function defaultStatMtime(p) {
  try { return fs.statSync(p).mtimeMs; }
  catch { return null; }
}

// CLI entry (not exercised by hermetic tests). Always exit 0 (fail-open): the
// hook treats us as advisory and must never break session start.
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  try {
    const a = parseArgs(process.argv.slice(2));
    const result = main(process.argv.slice(2), { statMtime: defaultStatMtime, readRecords, now: Date.now() });
    process.stdout.write(result.text);
    if (a.staleFlagFile) fs.writeFileSync(a.staleFlagFile, result.stale ? '1' : '0');
  } catch {
    // fail-open: no stdout, no flag.
  }
  process.exit(0);
}
