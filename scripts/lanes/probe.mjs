// scripts/lanes/probe.mjs
// HIMMEL-689 — pure probe evaluator. NO I/O: all machine state arrives via ctx.
export function evalProbe(probe, ctx) {
  if (!probe || typeof probe !== 'object') return false;
  switch (probe.kind) {
    case 'always': return true;
    case 'env':    return typeof ctx.env?.[probe.name] === 'string' && ctx.env[probe.name].trim() !== '';
    case 'path':   return ctx.pathHas(probe.cli);
    case 'crprofile': {
      const raw = ctx.env?.CR_PROFILE ?? '';
      return raw.split(/[,\s]+/).map((s) => s.trim()).filter(Boolean).includes(probe.token);
    }
    case 'installed': return ctx.installed?.[probe.tool] === true;
    default:          return false; // fail-closed on unknown kind
  }
}
