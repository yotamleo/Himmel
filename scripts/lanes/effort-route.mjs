// scripts/lanes/effort-route.mjs — HIMMEL-3997
// Turns an effort-assess record into an ADVISORY LEG_EFFORT recommendation
// (research HIMMEL-3992 section c). It never names a tier or model: raise
// effort before tier, and Opus/Fable still pass headed-arm-leg.sh's Tier gate.
//
//   node effort-route.mjs record.json [--config effort-routing.json]
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CONFIG = join(HERE, 'effort-routing.json');

export function loadConfig(path = DEFAULT_CONFIG) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

// recommend(record, cfg) -> { action, effort, review, suggest_tier_design, reason }. Pure.
export function recommend(record, cfg) {
  const out = (action, effort, review, reason) =>
    ({ action, effort, review, suggest_tier_design: action === 'plan-first', reason });
  const { sigma, mean_seq: mean } = record ?? {};
  const failed = record?.dod?.failed ?? [];
  if (!Number.isFinite(sigma) || !Number.isFinite(mean)) return out('plan-first', null, false, 'record has no usable sigma/mean');
  if (record.dod?.passed === false) return out('plan-first', null, false, `estimate DoD refused (${failed.join(', ') || 'unspecified'})`);
  if (sigma >= cfg.plan_first_sigma_gte) return out('plan-first', null, false, `sigma ${sigma} >= ${cfg.plan_first_sigma_gte}: plan-first or split, no implementation leg`);
  if (record.g1 === 'yes') return out('implement', 'high', true, 'G1 work: high effort plus independent review');
  if (mean > cfg.review_mean_gt) return out('implement', 'high', true, `mean ${mean.toFixed(2)} S-eq > ${cfg.review_mean_gt}: high effort plus independent review`);
  if (sigma > cfg.high.sigma_max) return out('implement', 'high', true, `sigma ${sigma} above ${cfg.high.sigma_max}: high effort plus independent review`);
  if (mean <= cfg.medium.mean_max && sigma <= cfg.medium.sigma_max) return out('implement', 'medium', false, 'small and well-bounded: medium effort');
  return out('implement', 'high', false, 'mid-size or uncertain: high effort');
}

// one-line human form, shared by fanout and the arm-leg advisory
export function describe(r) {
  if (r.action === 'plan-first') return `plan-first or split, no implementation leg (${r.reason}); a design slice may justify a Tier line, never written here`;
  return `LEG_EFFORT=${r.effort}${r.review ? ' + independent review before GO' : ''} (${r.reason})`;
}

if (process.argv[1]?.endsWith('effort-route.mjs')) {
  const args = process.argv.slice(2);
  const ci = args.indexOf('--config');
  const cfgPath = ci >= 0 ? args.splice(ci, 2)[1] : undefined;
  try {
    const r = recommend(JSON.parse(readFileSync(args[0], 'utf8')), loadConfig(cfgPath));
    process.stdout.write(JSON.stringify({ ...r, advisory: describe(r) }, null, 2) + '\n');
  } catch (e) {
    process.stderr.write(`effort-route: ${e.message}\n`);
    process.exit(2);
  }
}
