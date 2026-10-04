#!/usr/bin/env node
import { readThreadCache, lookupPrefix } from './thread-cache.mjs';

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      out[a.slice(2)] = next;
      i++;
    } else {
      out[a.slice(2)] = true;
    }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const { owner, repo, number, prefix } = args;

if (!owner || !repo || !number || !prefix) {
  process.stderr.write(
    'usage: thread-resolve-cli.mjs --owner O --repo R --number N --prefix P\n',
  );
  process.exit(2);
}

const cached = readThreadCache(undefined, owner, repo, Number(number));
if (!cached) {
  process.stderr.write(`no-cache: run /gh-pr-comments ${number} first\n`);
  process.exit(1);
}

const res = lookupPrefix(cached, prefix);
if (res.status === 'no-match') {
  process.stderr.write(`no-match: prefix "${prefix}" not in cache for ${owner}/${repo}#${number}\n`);
  process.exit(1);
}
if (res.status === 'ambiguous') {
  process.stderr.write(`ambiguous: "${prefix}" matches ${res.prefixes.join(', ')}\n`);
  process.exit(1);
}

process.stdout.write(res.id);
