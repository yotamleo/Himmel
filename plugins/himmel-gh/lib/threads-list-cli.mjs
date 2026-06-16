#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { writeThreadCache } from './thread-cache.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const QUERY_FILE = join(__dirname, '..', 'graphql', 'list-threads.gql');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) { out[a.slice(2)] = next; i++; }
    else out[a.slice(2)] = true;
  }
  return out;
}

function execGhApi(owner, repo, number) {
  return new Promise((resolve) => {
    let stdout = ''; let stderr = '';
    const proc = spawn('gh', [
      'api', 'graphql',
      '-F', `owner=${owner}`,
      '-F', `name=${repo}`,
      '-F', `number=${number}`,
      '-F', `query=@${QUERY_FILE}`,
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    proc.stdout.on('data', (d) => (stdout += d.toString()));
    proc.stderr.on('data', (d) => (stderr += d.toString()));
    proc.on('error', (err) => {
      const code = err.code === 'ENOENT' ? 127 : 1;
      resolve({ stdout, stderr: `${stderr}${err.message}\n`, exitCode: code });
    });
    // Signal-killed exits arrive with code === null and a non-null signal name.
    // Mapping null → 0 would silently hide the kill and trip downstream JSON.parse
    // with an empty stdout (confusing "parse error"). Match init-flow / repo-context-cli
    // pattern: synthesise exitCode 129 (signal) or 1 (unknown) and surface the
    // signal name in stderr. See HIMMEL-106 (#100).
    proc.on('close', (code, signal) => {
      const exitCode = code ?? (signal ? 129 : 1);
      const finalStderr = signal ? `${stderr}gh killed by signal ${signal}\n` : stderr;
      resolve({ stdout, stderr: finalStderr, exitCode });
    });
  });
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

const args = parseArgs(process.argv.slice(2));
const { owner, repo, number } = args;
const stdinJson = Boolean(args['stdin-json']);

if (!owner || !repo || !number) {
  process.stderr.write('usage: threads-list-cli.mjs --owner O --repo R --number N [--stdin-json]\n');
  process.exit(2);
}

let raw;
if (stdinJson) {
  raw = await readStdin();
} else {
  const res = await execGhApi(owner, repo, Number(number));
  if (res.exitCode !== 0) {
    process.stderr.write(res.stderr || `gh api graphql failed (exit ${res.exitCode})\n`);
    process.exit(res.exitCode);
  }
  raw = res.stdout;
}

let parsed;
try {
  parsed = JSON.parse(raw);
} catch (e) {
  process.stderr.write(`parse error: ${e.message}\n`);
  process.exit(1);
}

const nodes = parsed?.data?.repository?.pullRequest?.reviewThreads?.nodes;
if (!Array.isArray(nodes)) {
  process.stderr.write(`unexpected response shape (no reviewThreads.nodes)\n`);
  process.exit(1);
}

const data = writeThreadCache(undefined, owner, repo, Number(number), nodes);
const total = nodes.length;
const unresolved = nodes.filter((t) => !t.isResolved).length;

// Write table to stdout (runner relays to normal.log).
process.stdout.write(`# review threads for ${owner}/${repo}#${number}\n`);
process.stdout.write(`prefix  state       file:line                 author              comment\n`);
for (const [prefix, t] of Object.entries(data.threads)) {
  const state = t.isResolved ? 'resolved' : 'OPEN    ';
  const loc = `${t.path}:${t.line}`.padEnd(25).slice(0, 25);
  const c = nodes.find((n) => n.id === t.id)?.comments?.nodes?.[0];
  const author = (c?.author?.login ?? '?').padEnd(18).slice(0, 18);
  const body = (c?.bodyText ?? '').replace(/\s+/g, ' ').slice(0, 60);
  process.stdout.write(`${prefix}  ${state}  ${loc} ${author}  ${body}\n`);
}

// Final line — the runner's --summary-regex picks this up.
process.stdout.write(`threads=${total} unresolved=${unresolved}\n`);
