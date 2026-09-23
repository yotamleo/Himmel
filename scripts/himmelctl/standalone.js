#!/usr/bin/env node
'use strict';
// scripts/himmelctl/standalone.js — the node entry point the PATH launcher
// falls back to once the himmel clone is gone (HIMMEL-3312 S13 item 4,
// design HIMMEL-3312-standalone-undo.md §7). This file itself ships inside
// the bundle at ${HIMMEL_PROVENANCE_DIR:-~/.himmel}/uninstall/standalone.js,
// with the tree mirroring scripts/himmelctl/ so its own `./lib/*` requires
// resolve unchanged inside the bundle.
//
// Only `uninstall` works here. Every other verb — including no verb at all
// and --help — prints the "checkout not present" text and exits 1, because
// this file has no access to anything the clone provides (install/update/
// ensure/profile/doctor all need the clone's other scripts).

const path = require('path');
const uninstallWrapperLib = require('./lib/uninstall-wrapper.js');
const helpersLib = require('./lib/helpers.js');

const bundleRoot = __dirname;

function ledgerHimmelRoot() {
  // Best-effort only: standalone.js has no clone to read provenance.js from
  // in the general case (it's copied INTO the bundle, so it's actually
  // present here too) but a failure to resolve the ledger's himmel_root is
  // not fatal to printing a header — fall back to "(not present)".
  try {
    const provLib = require('./lib/provenance.js');
    const fs = require('fs');
    const lines = fs.readFileSync(provLib.ledgerPath(), 'utf8').trim().split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i]) continue;
      const row = JSON.parse(lines[i]);
      if (row.op === 'install-begin' && row.himmel_root) return row.himmel_root;
    }
  } catch (_e) { /* no ledger, or unreadable */ }
  return null;
}

function parseArgs(argv) {
  const args = { dryRun: false, purgeState: false, yes: false };
  for (const a of argv) {
    if (a === '--dry-run' || a === '-n') args.dryRun = true;
    else if (a === '--purge-state') args.purgeState = true;
    else if (a === '--yes' || a === '-y') args.yes = true;
    else return null; // unknown flag: fall through to the "not present" text
  }
  return args;
}

function printCheckoutNotPresent(himmelRoot) {
  console.error(`himmel's checkout ${himmelRoot ? '`' + himmelRoot + '`' : '(unknown)'} is not present. Only \`himmelctl uninstall\` works without it.`);
  console.error('To use himmel again, clone it and run `node <clone>/scripts/himmelctl/bin.js ensure`, which re-points this launcher.');
}

async function main() {
  const [verb, ...rest] = process.argv.slice(2);
  const himmelRoot = ledgerHimmelRoot();

  if (verb !== 'uninstall') {
    printCheckoutNotPresent(himmelRoot);
    return 1;
  }

  const args = parseArgs(rest);
  if (!args) {
    printCheckoutNotPresent(himmelRoot);
    return 1;
  }

  const header = (purgeState) => {
    console.log(`himmelctl: standalone uninstaller (bundle ${bundleRoot}, himmel_root ${himmelRoot || '(not present)'})`);
    console.log('himmelctl: (offboard plan skipped: running without the clone)');
    void purgeState;
  };
  const afterRun = (rc) => {
    if (rc === 0 && !args.dryRun && !args.purgeState) {
      console.log(`himmelctl: to finish removing state, re-run: node ${path.join(bundleRoot, 'standalone.js')} uninstall --purge-state`);
    }
  };

  const bashPath = process.platform === 'win32' ? helpersLib.resolvePowershell() : 'bash';
  const rc = await uninstallWrapperLib.runUninstallWrapper(args, {
    bashPath,
    repoRoot: bundleRoot,
    header,
    afterRun,
  });
  return rc;
}

if (require.main === module) {
  main().then((rc) => process.exit(rc)).catch((e) => {
    console.error(`himmelctl: standalone uninstaller failed: ${e.message}`);
    process.exit(1);
  });
}

module.exports = { main };
