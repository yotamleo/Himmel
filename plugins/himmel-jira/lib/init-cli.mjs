#!/usr/bin/env node
import { ensureEnvKeys, appendEnvKeys, runInit, loadEnvIntoProcess } from './init-flow.mjs';
import { envFilePath } from './jira-fetch.mjs';

const args = Object.fromEntries(process.argv.slice(2).map((a, i, arr) => {
  if (a.startsWith('--')) {
    const next = arr[i + 1];
    return next && !next.startsWith('--') ? [a.slice(2), next] : [a.slice(2), true];
  }
  return null;
}).filter(Boolean));

if (args.check) {
  const envFile = envFilePath(args['env-path']);
  const missing = ensureEnvKeys(envFile, ['JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_BASE_URL']);
  if (missing.length) {
    console.log(`needs-prompt: ${missing.join(' ')}`);
    process.exit(0);
  }
  console.log('env-ok');
  process.exit(0);
}

if (args['write-env']) {
  const envFile = envFilePath(args['env-path']);
  const kvs = {};
  if (args.email) kvs.JIRA_EMAIL = args.email;
  if (args.token) kvs.JIRA_API_TOKEN = args.token;
  if (args['base-url']) kvs.JIRA_BASE_URL = args['base-url'];
  if (Object.keys(kvs).length === 0) {
    console.error('--write-env requires at least --email, --token, or --base-url');
    process.exit(2);
  }
  appendEnvKeys(envFile, kvs);
  console.log('env-written');
  process.exit(0);
}

if (args.discover) {
  const envFile = envFilePath(args['env-path']);
  loadEnvIntoProcess(envFile);
  const projects = (args.projects || 'HIMMEL').split(',');
  try {
    const res = await runInit({ projects });
    console.log(res.summary || 'OK');
    process.exit(0);
  } catch (e) {
    console.error(`init: ${e.message}`);
    process.exit(1);
  }
}

console.error('usage: init-cli.mjs --check | --write-env --email E --token T | --discover --projects P,Q');
process.exit(2);
