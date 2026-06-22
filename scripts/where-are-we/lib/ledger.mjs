// scripts/where-are-we/lib/ledger.mjs
import { appendFileSync, readFileSync } from 'node:fs';

export function appendRecord(ledgerPath, obj) {
  appendFileSync(ledgerPath, JSON.stringify(obj) + '\n');
}

export function readRecords(ledgerPath) {
  // Read directly and treat a missing file as empty — no existsSync precheck
  // (that was a TOCTOU race: the file could vanish between the stat and the read).
  let raw;
  try {
    raw = readFileSync(ledgerPath, 'utf8');
  } catch (e) {
    if (e.code === 'ENOENT') return [];
    throw e;
  }
  const out = [];
  const lines = raw.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    try { out.push(JSON.parse(line)); }
    catch { throw new Error(`malformed JSON at ${ledgerPath}:${i + 1}`); }
  }
  return out;
}
