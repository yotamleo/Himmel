'use strict';
// scripts/himmelctl/lib/probes-observability.js — the status probe for the
// opt-in `observability-grafana` item (HIMMEL-4289). A separate file so it does
// not widen probes.js; probes.js registers it with one line and hands in the
// helpers it already owns (scopeConfigPathToCtx, spawnBashProbe,
// probeTimeoutSecs), so nothing is duplicated here.
//
// Prometheus + Grafana run as systemd USER units on Linux only
// (scripts/observability/install-grafana.sh). Opt-in via
// "observability": {"grafana": true} in ~/.himmel/config.json: not opted in, or
// not Linux, is a CLEAN absence (status-report reads it as n/a, never a nag).
const path = require('path');
const lunaConfig = require('./luna-config.js');

function probeObservabilityGrafana(item, ctx, h) {
  const env = ctx.env || process.env;
  const platform = ctx.platform || process.platform;
  if (platform !== 'linux') {
    return { actual: 'absent', detail: 'the Prometheus + Grafana user units are Linux-only so far', cleanAbsence: true };
  }
  let config;
  try {
    config = h.scopeConfigPathToCtx(ctx, () => lunaConfig.load());
  } catch (e) {
    return { actual: 'degraded', detail: `cannot read luna config: ${e.message}` };
  }
  if (!(config.observability && config.observability.grafana === true)) {
    return { actual: 'absent', detail: 'observability.grafana is not true in ~/.himmel/config.json — the Prometheus + Grafana stack is opt-in', cleanAbsence: true };
  }
  // Read-only: `status` runs systemctl is-enabled and curls three loopback endpoints.
  const script = path.join(ctx.repoRoot, 'scripts', 'observability', 'install-grafana.sh');
  const r = h.spawnBashProbe([script, 'status'], { env, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: `install-grafana.sh status timed out after ${h.probeTimeoutSecs(r)}s — stack state could not be determined` };
  if (r.error) return { actual: 'degraded', detail: `install-grafana.sh status failed to spawn: ${r.error.message} — stack state could not be determined` };
  const out = String(r.stdout || '').trim();
  if (r.status === 0) return { actual: 'present', detail: 'prometheus, grafana and the alert hook are registered and answering' };
  const fails = out.split(/\r?\n/).filter((l) => l.startsWith('FAIL'));
  if (fails.length === 0) return { actual: 'degraded', detail: `install-grafana.sh status exited rc=${r.status} — ${String(r.stderr || out).trim().slice(0, 200)}` };
  // every unit unregistered and no endpoint answering = never installed; anything else = partial.
  const services = fails.filter((l) => l.startsWith('FAIL service')).length;
  const health = fails.filter((l) => l.startsWith('FAIL health')).length;
  return { actual: services === 3 && health === 3 ? 'absent' : 'degraded', detail: fails.join('; ') };
}

module.exports = { probeObservabilityGrafana };
