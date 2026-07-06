// Tests for guardrail-skip-in-himmel.js (HIMMEL-709). Dependency-free:
//   node --test scripts/hooks/guardrail-skip-in-himmel.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const WRAPPER = join(HERE, 'guardrail-skip-in-himmel.js');
const GUARD = 'block-read-secrets.sh';

// Run the wrapper; return {code, ran} where `ran` is whether the fake guardrail
// executed (it drops a marker file). env overrides CLAUDE_PROJECT_DIR etc.
function runWrapper({ projectDir, declares, bash, script }) {
  const work = mkdtempSync(join(tmpdir(), 'gskip-'));
  const proj = projectDir ?? join(work, 'proj');
  mkdirSync(join(proj, '.claude'), { recursive: true });
  writeFileSync(
    join(proj, '.claude', 'settings.json'),
    declares ? JSON.stringify({ hooks: { PreToolUse: [{ command: `bash ${GUARD}` }] } }) : '{}',
  );
  const marker = join(work, 'ran.marker');
  const guardPath = script ?? join(work, GUARD);
  // Fake guardrail: writes the marker so we can detect execution.
  writeFileSync(guardPath, `#!/usr/bin/env bash\necho ran > "${marker.replace(/\\/g, '/')}"\nexit 0\n`);
  try { chmodSync(guardPath, 0o755); } catch { /* windows */ }

  const env = { ...process.env, CLAUDE_PROJECT_DIR: proj };
  delete env.HIMMEL_REPO; // isolate: exercise self-describing skip, not the root fallback
  if (bash !== undefined) env.GUARDRAIL_BASH = bash;

  let code = 0;
  try {
    execFileSync(process.execPath, [WRAPPER, guardPath], { env, input: '{}', stdio: ['pipe', 'ignore', 'ignore'] });
  } catch (e) {
    code = typeof e.status === 'number' ? e.status : -1;
  }
  let ran = false;
  try { readFileSync(marker); ran = true; } catch { ran = false; }
  return { code, ran };
}

test('skips (exit 0, no bash spawn) when project settings declare the guardrail', () => {
  const bash = process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : '/bin/bash';
  const r = runWrapper({ declares: true, bash });
  assert.equal(r.code, 0);
  assert.equal(r.ran, false, 'guardrail must NOT run when project already declares it');
});

test('runs the resolved bash guardrail when the project does not declare it', () => {
  const bash = process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : '/bin/bash';
  const r = runWrapper({ declares: false, bash });
  assert.equal(r.code, 0);
  assert.equal(r.ran, true, 'guardrail MUST run when the project does not cover it');
});

test('fails closed (exit 2) when the resolved bash cannot be spawned', () => {
  const r = runWrapper({ declares: false, bash: join(tmpdir(), 'no-such-bash-xyz') });
  assert.equal(r.code, 2);
});

test('fails closed (exit 2) when no guardrail path arg is given', () => {
  let code = 0;
  try {
    execFileSync(process.execPath, [WRAPPER], { input: '{}', stdio: ['pipe', 'ignore', 'ignore'] });
  } catch (e) { code = e.status; }
  assert.equal(code, 2);
});

test('source contains no hardcoded home path literal', () => {
  const src = readFileSync(WRAPPER, 'utf8');
  assert.ok(!/Users\/[^/]+\/(Documents|github)/i.test(src), 'no committed home path');
});
