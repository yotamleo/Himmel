'use strict';
// scripts/himmelctl/lib/cadence-emit.js — HIMMEL-2176 Stage-1 PR-C Task 8b.
//
// Pure mapping: a luna-config-shaped `cadence` object ({enabled, schedules,
// models} — see luna-config.js's SCHEMA) -> the CLI flags for
// `scripts/luna/pipeline-cadence.sh arm`. This module builds the invocation
// ONLY — it never spawns anything and never talks to schtasks/cron itself;
// pipeline-cadence.sh owns that translation (bin.js's caller is responsible
// for the actual spawn).
//
// Flag names verified in-tree against scripts/luna/pipeline-cadence.sh
// (subcommands: arm|status|disarm — NOT scripts/hooks/, a plan-doc drift the
// task brief called out). The config->flag mapping is NOT 1:1:
//   fetchHealth -> --fetch-health-time            (no model flag: runs no LLM)
//   harvest     -> --harvest-time, --harvest-model
//   synthesize  -> --synth-time, --synth-model     (NOT --synthesize-*)
//   health      -> --health-time, --health-model, --health-day
// `--health-day` is the ONLY day-accepting flag in the script — `--synth-day`
// was deliberately removed (HIMMEL-506) and the script hard-errors naming the
// removal; there is no `--harvest-day` or `--fetch-health-day` at all. A
// `day` present on any OTHER schedule is therefore a loud validation error
// here (thrown, never silently dropped) — the silent-04:00-stall class this
// module exists to prevent.
//
// `health.day` absent means daily per design A9 ("weekly when day is
// present, daily otherwise") — but pipeline-cadence.sh's own default when
// --health-day is omitted is SUN (weekly!), so omitting the flag entirely
// would silently reinterpret "daily" as "every Sunday". `--health-day DAILY`
// is emitted explicitly in that case instead of relying on the script's
// default.

const path = require('path');

const TIME_FLAG_BY_SCHEDULE = {
  fetchHealth: '--fetch-health-time',
  harvest: '--harvest-time',
  synthesize: '--synth-time',
  health: '--health-time',
};
// Fixed iteration order — deterministic argv, matches the script's own
// pipeline order (fetch-health -> harvest -> synthesize -> health).
const SCHEDULE_ORDER = ['fetchHealth', 'harvest', 'synthesize', 'health'];

const MODEL_FLAG_BY_LEG = {
  harvest: '--harvest-model',
  synthesize: '--synth-model',
  health: '--health-model',
};
const MODEL_ORDER = ['harvest', 'synthesize', 'health'];

// The only schedule key pipeline-cadence.sh can carry a day for.
const DAY_CAPABLE_SCHEDULE = 'health';

function pipelineCadenceScriptPath(repoRoot) {
  return path.join(repoRoot, 'scripts', 'luna', 'pipeline-cadence.sh');
}

// buildArmFlags({ cadence, vaultPath, force, dryRun }) -> string[] flags
// (no subcommand, no script path — the caller prefixes those). Throws a
// plain Error naming the offending schedule when a `day` sits on a schedule
// the script has no day flag for.
function buildArmFlags({ cadence, vaultPath, force, dryRun } = {}) {
  if (!cadence || typeof cadence !== 'object') {
    throw new Error('cadence-emit: cadence object is required');
  }
  const schedules = cadence.schedules || {};
  const models = cadence.models || {};
  const flags = [];

  for (const key of SCHEDULE_ORDER) {
    const sched = schedules[key];
    if (!sched || !sched.time) continue;
    if (sched.day && key !== DAY_CAPABLE_SCHEDULE) {
      throw new Error(
        `cadence-emit: schedule '${key}' carries a day (${sched.day}) but pipeline-cadence.sh has no `
        + `--${key}-day flag — only '${DAY_CAPABLE_SCHEDULE}' accepts a day (--health-day); `
        + '--synth-day was removed (HIMMEL-506) and there is no --harvest-day/--fetch-health-day',
      );
    }
    flags.push(TIME_FLAG_BY_SCHEDULE[key], sched.time);
  }

  // Always emit --health-day explicitly (see header comment: the script's
  // own omitted-flag default is SUN, not daily).
  const healthSched = schedules[DAY_CAPABLE_SCHEDULE];
  if (healthSched && healthSched.time) {
    flags.push('--health-day', healthSched.day || 'DAILY');
  }

  for (const key of MODEL_ORDER) {
    if (models[key]) flags.push(MODEL_FLAG_BY_LEG[key], models[key]);
  }

  if (vaultPath) flags.push('--vault', vaultPath);
  if (force) flags.push('--force');
  if (dryRun) flags.push('--dry-run');
  return flags;
}

module.exports = {
  buildArmFlags,
  pipelineCadenceScriptPath,
  TIME_FLAG_BY_SCHEDULE,
  MODEL_FLAG_BY_LEG,
  DAY_CAPABLE_SCHEDULE,
};
