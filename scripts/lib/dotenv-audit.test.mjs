import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, copyFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { auditDotenv as audit } from './dotenv-audit.mjs';

test('doctor warns on an unlisted shell consumer, names unused keys without values', () => {
  const root = mkdtempSync(join(tmpdir(), 'dotenv-audit-'));
  try {
    mkdirSync(join(root, 'scripts'));
    writeFileSync(join(root, 'scripts/consumer.sh'), 'load_dotenv --root "$ROOT"\n');
    writeFileSync(join(root, '.env'), 'TEST_ANTHROPIC_API_KEY=DO_NOT_PRINT_THIS\n');
    const rows = audit(root);
    assert.ok(rows.some(r => r.sev === 'WARN' && r.msg.includes('scripts/consumer.sh')));
    assert.ok(rows.some(r => r.sev === 'INFO' && r.msg.includes('TEST_ANTHROPIC_API_KEY')));
    assert.ok(!JSON.stringify(rows).includes('DO_NOT_PRINT_THIS'));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('doctor warns when an empty loader call precedes shell operators', () => {
  const root = mkdtempSync(join(tmpdir(), 'dotenv-audit-'));
  try {
    mkdirSync(join(root, 'scripts'));
    writeFileSync(join(root, 'scripts/consumer.sh'), 'load_dotenv && true\nload_dotenv || true\nload_dotenv; true\n');
    const rows = audit(root);
    for (const line of [1, 2, 3]) {
      assert.ok(rows.some(r => r.sev === 'WARN' && r.msg.endsWith(`consumer.sh:${line}`)));
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('doctor recognizes explicit consumer keys, including multiline lists', () => {
  const root = mkdtempSync(join(tmpdir(), 'dotenv-audit-'));
  try {
    mkdirSync(join(root, 'scripts'));
    writeFileSync(join(root, 'scripts/consumer.sh'), 'load_dotenv --root "$ROOT" HANDOVER_DIR \\\n USER_SLUG\n');
    writeFileSync(join(root, '.env'), 'HANDOVER_DIR=/dummy\nUSER_SLUG=fixture\nUNUSED_KEY=DO_NOT_PRINT_THIS\n');
    const rows = audit(root);
    assert.ok(!rows.some(r => r.sev === 'WARN'));
    const info = rows.filter(r => r.sev === 'INFO').map(r => r.msg).join('\n');
    assert.ok(info.includes('UNUSED_KEY'));
    assert.ok(!info.includes('HANDOVER_DIR'));
    assert.ok(!info.includes('USER_SLUG'));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('C57 emits WARN and INFO through the doctor reporting function', () => {
  const root = mkdtempSync(join(tmpdir(), 'dotenv-doctor-'));
  try {
    mkdirSync(join(root, 'scripts/lib'), { recursive: true });
    copyFileSync(new URL('./dotenv-audit.mjs', import.meta.url), join(root, 'scripts/lib/dotenv-audit.mjs'));
    writeFileSync(join(root, 'scripts/consumer.sh'), 'load_dotenv\n');
    writeFileSync(join(root, '.env'), 'TEST_ANTHROPIC_API_KEY=DO_NOT_PRINT_THIS\n');
    const doctor = readFileSync(new URL('../himmel-doctor.sh', import.meta.url), 'utf8');
    const body = doctor.match(/^check_c57_dotenv_allowlists\(\) \{[\s\S]*?^\}/m)?.[0];
    assert.ok(body, 'doctor must provide its C57 implementation');
    const run = spawnSync('bash', ['-c', `resolve_node() { printf '%s' "$NODE"; }\nemit() { printf '%s|%s|%s\\n' "$1" "$2" "$3"; }\n${body}\ncheck_c57_dotenv_allowlists`], { env: { PATH: process.env.PATH, NODE: process.execPath, REPO_ROOT: root }, encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /WARN\|C57-dotenv-allowlists\|.*consumer.sh/);
    assert.match(run.stdout, /INFO\|C57-dotenv-allowlists\|.*TEST_ANTHROPIC_API_KEY/);
    assert.ok(!run.stdout.includes('DO_NOT_PRINT_THIS'));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('doctor warns on blanket Python and JavaScript loaders', () => {
  const root = mkdtempSync(join(tmpdir(), 'dotenv-audit-'));
  try {
    mkdirSync(join(root, 'scripts'));
    writeFileSync(join(root, 'scripts/consumer.py'), 'from dotenv import load_dotenv\nload_dotenv()\n');
    writeFileSync(join(root, 'scripts/consumer.ts'), 'process.env[key.trim()] ??= value;\n');
    const rows = audit(root);
    assert.ok(rows.some(r => r.sev === 'WARN' && r.msg.includes('consumer.py')));
    assert.ok(rows.some(r => r.sev === 'WARN' && r.msg.includes('consumer.ts')));
  } finally { rmSync(root, { recursive: true, force: true }); }
});
