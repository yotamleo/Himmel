#!/usr/bin/env node
import { readMetadata } from './metadata.mjs';

const args = Object.fromEntries(process.argv.slice(2).map((a, i, arr) => {
  if (a.startsWith('--')) {
    const next = arr[i + 1];
    return next && !next.startsWith('--') ? [a.slice(2), next] : [a.slice(2), true];
  }
  return null;
}).filter(Boolean));

const meta = readMetadata();
if (!meta) { console.error('no-cache'); process.exit(1); }
if (!args.key) { console.error('--key required'); process.exit(1); }
if (!args.status) { console.error('--status required'); process.exit(1); }
const proj = args.key.split('-')[0];
const tid = meta.projects[proj]?.transitions?.[args.status];
if (!tid) { console.error(`no transition ${args.status} for ${proj}`); process.exit(1); }
process.stdout.write(tid);
