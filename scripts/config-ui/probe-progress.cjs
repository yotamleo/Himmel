'use strict';
// HIMMEL-4807: preloaded (`node --require`) into the `himmelctl report --json` the config UI runs for its feed.
// It writes one stderr line per probe step, `himmel-probe {"i":2,"n":9,"source":"doctor checks"}`, so the page can
// say which source is being probed, n of N. The report itself is untouched: the hook only watches config-feed.js
// load (the report starting) and the children it spawns (spawnSync), in composeFeed's fixed order.
// ponytail: the steps are inferred from config-feed.js's spawns (the doctor, each cadence's status, the plugin
// list), not announced by it, so a source added there shows under the step before it; upgrade path: config-feed.js
// emits its own steps (a follow-up to HIMMEL-4807) and this hook is deleted.
const cp = require('child_process');
const Module = require('module');
const path = require('path');

const PREFIX = 'himmel-probe ';
let steps = null; // set once config-feed.js loads
let cur = -1;
let cadences = [];

function emit(k) {
  cur = k;
  process.stderr.write(PREFIX + JSON.stringify({ i: k + 1, n: steps.length, source: steps[k] }) + '\n');
}

// config-feed.js is required by cmdReport right before buildFeed: the report starts here.
function begin(feed) {
  cadences = feed.CADENCES.filter((c) => !c.windowsOnly || process.platform === 'win32').map((c) => c.name);
  steps = ['install items', 'doctor checks', ...cadences.map((c) => `${c} cadence`), 'plugin profile', 'lanes, initiative legs, flags and secrets'];
  emit(0);
}

const load = Module._load;
Module._load = function (...a) {
  const m = load.apply(this, a);
  if (!steps && m && Array.isArray(m.CADENCES) && typeof m.buildFeed === 'function') begin(m);
  return m;
};

// The step a spawn starts, or -1. The status engine may run a cadence's `status` itself before the doctor,
// so a cadence or the plugin list counts only once the doctor has started (steps only move forward).
function stepOf(args) {
  if (!Array.isArray(args) || args.length < 2) return -1;
  const base = path.basename(String(args[0]));
  if (args[1] === '--json' && args[2] === '--no-color') return 1;
  const m = /^(.+)-cadence\.sh$/.exec(base);
  if (m && args[1] === 'status' && cadences.includes(m[1])) return 2 + cadences.indexOf(m[1]);
  if (base === 'plugin-profile.sh' && args[1] === 'list') return steps.length - 2;
  return -1;
}

const spawnSync = cp.spawnSync;
cp.spawnSync = function (file, args, ...rest) {
  if (steps) {
    const k = stepOf(args);
    if (k > cur && (k === 1 || cur >= 1)) emit(k);
  }
  const r = spawnSync.call(this, file, args, ...rest);
  if (steps && cur === steps.length - 2) emit(steps.length - 1); // the plugin list is the last spawn; the rest is in-process
  return r;
};
