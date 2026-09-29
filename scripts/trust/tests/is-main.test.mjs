// HIMMEL-3810 — spec for scripts/lib/is-main.mjs. Each case runs a real child
// `node` so process.argv[1] and import.meta.url are the genuine article, not a
// hand-built pair that could agree by construction.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { before, describe, test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { makeTmpDir } from '../../lib/test-tmpdir.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const IS_MAIN_URL = pathToFileURL(path.join(HERE, '..', '..', 'lib', 'is-main.mjs')).href;

let TMP;
let REAL_DIR;
let ENTRY;
before(() => {
  TMP = makeTmpDir('is-main-');
  REAL_DIR = path.join(TMP, 'real');
  fs.mkdirSync(REAL_DIR);
  ENTRY = path.join(REAL_DIR, 'entry.mjs');
  // Prints the verdict on load; also exports nothing, so importing it is the
  // "non-main import" case.
  fs.writeFileSync(ENTRY, `import { isMain } from ${JSON.stringify(IS_MAIN_URL)};\nprocess.stdout.write(String(isMain(import.meta.url)));\n`);
});

const run = (script) => spawnSync(process.execPath, [script], { encoding: 'utf8' });

describe('isMain(import.meta.url)', () => {
  test('true on a direct invocation', () => {
    assert.equal(run(ENTRY).stdout, 'true');
  });

  test('true when invoked through a symlinked DIRECTORY', () => {
    const link = path.join(TMP, 'linked-dir');
    fs.symlinkSync(REAL_DIR, link, 'dir');
    assert.equal(run(path.join(link, 'entry.mjs')).stdout, 'true');
  });

  test('true when invoked through a symlinked FILE', () => {
    const link = path.join(TMP, 'linked-file.mjs');
    fs.symlinkSync(ENTRY, link, 'file');
    assert.equal(run(link).stdout, 'true');
  });

  test('false when the module is imported by another entry script', () => {
    const importer = path.join(TMP, 'importer.mjs');
    fs.writeFileSync(importer, `await import(${JSON.stringify(pathToFileURL(ENTRY).href)});\n`);
    assert.equal(run(importer).stdout, 'false');
  });
});

describe('isMain edge inputs', () => {
  // `node --input-type=module -e` runs with no script path, so process.argv is
  // the real shape a REPL/eval caller sees; `setup` then bends argv[1] per case.
  const evalIsMain = (setup, moduleUrl) => spawnSync(process.execPath, [
    '--input-type=module', '-e',
    `import { isMain } from ${JSON.stringify(IS_MAIN_URL)};\n${setup}\nprocess.stdout.write(String(isMain(${JSON.stringify(moduleUrl)})));`,
  ], { encoding: 'utf8' });

  test('false when argv[1] is missing (node -e)', () => {
    const r = evalIsMain('', pathToFileURL(ENTRY).href);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, 'false');
  });

  test('false, not a throw, when argv[1] is not a real path', () => {
    const r = evalIsMain(`process.argv[1] = ${JSON.stringify(path.join(TMP, 'does-not-exist.mjs'))};`, pathToFileURL(ENTRY).href);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, 'false');
  });

  test('false, not a throw, when the module URL is not a file: URL', () => {
    const r = evalIsMain(`process.argv[1] = ${JSON.stringify(ENTRY)};`, 'data:text/javascript,0');
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, 'false');
  });
});
