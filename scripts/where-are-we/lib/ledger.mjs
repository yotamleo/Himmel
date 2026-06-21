// scripts/where-are-we/lib/ledger.mjs
import { appendFileSync, readFileSync, existsSync } from 'node:fs';

export function appendRecord(ledgerPath, obj) {
  appendFileSync(ledgerPath, JSON.stringify(obj) + '\n');
}

export function readRecords(ledgerPath) {
  if (!existsSync(ledgerPath)) return [];
  const out = [];
  const lines = readFileSync(ledgerPath, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    try { out.push(JSON.parse(line)); }
    catch { throw new Error(`malformed JSON at ${ledgerPath}:${i + 1}`); }
  }
  return out;
}
