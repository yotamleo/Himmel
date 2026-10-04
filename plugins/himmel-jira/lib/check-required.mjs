#!/usr/bin/env node
import { readMetadata, isStale } from './metadata.mjs';

const args = Object.fromEntries(process.argv.slice(2).map((a, i, arr) => {
  if (a.startsWith('--')) {
    const next = arr[i + 1];
    return next && !next.startsWith('--') ? [a.slice(2), next] : [a.slice(2), true];
  }
  return null;
}).filter(Boolean));

const meta = readMetadata();
if (!meta) { console.log('no-cache run /jira-init'); process.exit(1); }
if (isStale(meta)) console.error('(cache stale, run /jira-refresh)');

const type = args.type;
const proj = args.project || meta.default_project;
const t = meta.projects[proj]?.issue_types[type];
if (!t) { console.log(`unknown type ${type} in project ${proj}`); process.exit(1); }
console.log(`required: ${t.required_fields.join(',') || '(none)'}`);
