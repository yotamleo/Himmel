#!/usr/bin/env node
// bus-deliver-run.js — node entry for bus-deliver-hook.sh (HIMMEL-4828).
//
// Hook-integrity coverage for marketplace/plugins/himmel-bus/lib/*.mjs: the
// launcher pins and verifies scripts/hooks files, but the delivery worker lives
// in the plugin. record-hook-integrity.sh pins those .mjs files too, and this
// runner compares each one to its pin BEFORE importing it. A mismatch delivers
// nothing (a tampered lib must not feed a session); no record or no pin fails
// open, like every pin lookup (loadIntegrityRecord). Always exits 0.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { loadIntegrityRecord, gitBlobSha1 } = require('./hook-integrity.js');

const REL = 'marketplace/plugins/himmel-bus/lib';
const root = path.resolve(__dirname, '..', '..');

function tampered(sessionId) {
  const pins = (loadIntegrityRecord(sessionId) || {}).pins;
  if (!pins || typeof pins !== 'object') return false;
  for (const file of fs.readdirSync(path.join(root, REL))) {
    if (!file.endsWith('.mjs')) continue;
    const pin = pins[`${REL}/${file}`];
    if (pin && pin !== gitBlobSha1(fs.readFileSync(path.join(root, REL, file)))) return true;
  }
  return false;
}

(async () => {
  let input = {};
  try { input = JSON.parse(fs.readFileSync(0, 'utf8')); } catch (_e) { return; }
  if (tampered(input.session_id)) return;
  const { main } = await import(pathToFileURL(path.join(root, REL, 'deliver.mjs')).href);
  await main(input);
})().catch(() => {}).finally(() => process.exit(0));
