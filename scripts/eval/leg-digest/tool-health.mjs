// HIMMEL-4816: shared read-only rollup for the Tool health page and console board.
// Denominators live in eval-runs metadata; class/recovery rows come from leg-failures.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const LANES = ['native', 'claudex', 'openrouter', 'cloud', 'unknown'];
const num = (n) => Number.isSafeInteger(n) && n >= 0;
const rate = (n, d) => d !== null && d > 0 ? n / d : null;
const dayOf = (t) => Number.isFinite(t) ? new Date(t).toISOString().slice(0, 10) : null;
const inferredTool = (cls) => cls.startsWith('error/') ? cls.slice(6).split(':')[0] : /^(denied|suite)\//.test(cls) ? 'Bash' : null;
function readRows(path) {
  try { return readFileSync(path, 'utf8').split('\n').flatMap((l) => { try { const r = JSON.parse(l); return r && typeof r === 'object' ? [r] : []; } catch { return []; } }); }
  catch { return []; }
}
export function readToolHealth(env = process.env, query = new URLSearchParams(), now = Date.now()) {
  const home = env.HOME || homedir();
  return rollupToolHealth(readRows(env.HIMMEL_EVAL_RUNS_LEDGER || join(home, '.himmel', 'eval-runs.jsonl')),
    readRows(env.HIMMEL_LEG_FAILURES_LEDGER || join(home, '.himmel', 'leg-failures.jsonl')), query, now);
}

export function rollupToolHealth(evals, failures, query = new URLSearchParams(), now = Date.now()) {
  const days = query.get('days') === '30' ? 30 : 7;
  const since = query.get('since');
  const lastDay = dayOf(now), firstDay = since ? dayOf(Date.parse(since)) : dayOf(Date.parse(lastDay) - (days - 1) * 86400000);
  const selected = { model: query.get('model') || '', lane: query.get('lane') || '', role: query.get('role') || '', days };
  const matches = (r, withLane = true) => (!selected.model || r.model === selected.model) && (!selected.role || r.role === selected.role) && (!withLane || !selected.lane || r.lane === selected.lane);
  const sessions = new Map();
  for (const r of evals) {
    if (r.eval !== 'leg-trajectory' || typeof r.run_id !== 'string' || !['ok', 'partial', 'inconclusive'].includes(r.status)) continue;
    const prev = sessions.get(r.run_id);
    if (!prev || prev.status !== 'ok' || r.status === 'ok') sessions.set(r.run_id, r);
  }
  const slots = new Map(), byAgent = new Map(), models = new Set(), roles = new Set();
  for (const [session, r] of sessions) {
    const ts = typeof r.meta?.started_ts === 'number' ? r.meta.started_ts : Date.parse(r.ts);
    const day = dayOf(ts);
    if (!day) continue;
    const lane = LANES.includes(r.lane) ? r.lane : 'unknown';
    const role = r.meta?.leg ? 'leg' : 'console';
    const health = Array.isArray(r.meta?.tool_health) ? r.meta.tool_health : [];
    const addSlot = (agent, model, cohort = day) => {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(cohort) || cohort < firstDay || cohort > lastDay) return null;
      const key = `${session}\0${agent}\0${cohort}`;
      if (!slots.has(key)) {
        const slot = { session, agent, day: cohort, lane, role, model: model || 'unknown', known: Array.isArray(r.meta?.tool_health), incomplete: !!since && cohort === firstDay && Date.parse(since) !== Date.parse(firstDay), tools: new Map(), failures: [] };
        slots.set(key, slot);
        const agentKey = `${session}\0${agent}`, cohorts = byAgent.get(agentKey) || [];
        cohorts.push(slot); byAgent.set(agentKey, cohorts);
      }
      const slot = slots.get(key); models.add(slot.model); roles.add(slot.role); return slot;
    };
    if (!health.length) addSlot('main', r.model);
    for (const h of health) {
      if (!h || typeof h.tool !== 'string' || !num(h.calls) || !num(h.failures) || !num(h.errors) || !num(h.denials) || typeof h.agent?.id !== 'string') continue;
      const slot = addSlot(h.agent.id, h.agent.model || (h.agent.id === 'main' ? r.model : null), h.day || day);
      if (slot) slot.tools.set(h.tool, h);
    }
  }
  const seenFailures = new Set();
  for (const r of failures) {
    if (!r || typeof r.class !== 'string' || !num(r.count) || !r.agent || r.failure === 'traj' || r.failure === 'run_error') continue;
    const identity = `${r.session}\0${r.agent.id}\0${r.class}`;
    if (seenFailures.has(identity)) continue;
    seenFailures.add(identity);
    let candidates = byAgent.get(`${r.session}\0${r.agent.id}`) || [];
    // Legacy subagent failures still show with unknown denominators.
    if (!candidates.length) {
      const main = byAgent.get(`${r.session}\0main`)?.[0];
      if (main && !main.known) {
        const slot = { ...main, agent: r.agent.id, model: r.agent.model || 'unknown', known: false, tools: new Map(), failures: [] };
        models.add(slot.model); slots.set(`${r.session}\0${r.agent.id}\0${slot.day}`, slot); candidates = [slot]; byAgent.set(`${r.session}\0${r.agent.id}`, candidates);
      }
    }
    for (const slot of candidates) {
      const health = [...slot.tools.values()];
      const count = slot.known && health.every((h) => h.classes && typeof h.classes === 'object')
        ? health.reduce((n, h) => n + (num(h.classes[r.class]) ? h.classes[r.class] : 0), 0) : r.count;
      if (!count) continue;
      slot.failures.push({ ...r, count });
      const tool = inferredTool(r.class), h = slot.tools.get(tool);
      if (!slot.known && tool) {
        if (h) { h.failures += count; if (r.failure === 'error' || r.failure === 'suite') h.errors += count; if (r.failure === 'denied') h.denials += count; }
        else slot.tools.set(tool, { tool, calls: null, failures: count, errors: r.failure === 'error' || r.failure === 'suite' ? count : 0, denials: r.failure === 'denied' ? count : 0, legacy: true });
      }
    }
  }
  const blank = () => ({ calls: 0, failures: 0, errors: 0, denials: 0, recovered: 0, known: 0, sessions: new Set(), classes: new Map(), ids: new Set() });
  const finish = (r) => ({ ...r, rate: rate(r.failures, r.calls), error_rate: rate(r.errors, r.calls), recovery_rate: rate(r.recovered, r.known), sessions: [...r.sessions], classes: [...r.classes].sort((a, b) => b[1] - a[1]).map(([className, count]) => ({ class: className, count })), tool_call_ids: [...r.ids].slice(0, 20) });
  const sumCalls = (a, b) => a === null || b === null ? null : a + b;
  function aggregate(list) {
    const tools = new Map(), daily = new Map(), hooks = new Map(), dailyHooks = new Map(), bashByGroup = new Map();
    let bashCalls = 0, totalCalls = 0;
    for (const s of list) {
      const group = `${s.day}\0${s.model}\0${s.lane}\0${s.role}`;
      const bash = s.tools.get('Bash'), calls = s.known && !s.incomplete ? bash ? bash.calls : 0 : null;
      bashCalls = sumCalls(bashCalls, calls);
      bashByGroup.set(group, sumCalls(bashByGroup.has(group) ? bashByGroup.get(group) : 0, calls));
      for (const h of s.tools.values()) {
        totalCalls = sumCalls(totalCalls, h.calls);
        const key = `${s.day}\0${s.model}\0${s.lane}\0${s.role}\0${h.tool}`;
        const t = tools.get(h.tool) || { ...blank(), tool: h.tool };
        const d = daily.get(key) || { ...blank(), tool: h.tool, day: s.day, model: s.model, lane: s.lane, role: s.role };
        for (const target of [t, d]) {
          target.calls = sumCalls(target.calls, h.calls); target.failures += h.failures; target.errors += h.errors; target.denials += h.denials; target.sessions.add(s.session);
          for (const f of s.failures) {
            const count = h.classes ? h.classes[f.class] : inferredTool(f.class) === h.tool ? f.count : 0;
            if (!num(count) || count === 0) continue;
            target.classes.set(f.class, (target.classes.get(f.class) || 0) + count);
            for (const id of f.tool_call_ids || []) if (typeof id === 'string') target.ids.add(id);
            if (typeof f.recovered === 'boolean') { target.known += count; if (f.recovered) target.recovered += count; }
          }
        }
        tools.set(h.tool, t); daily.set(key, d);
      }
      for (const f of s.failures) {
        if (f.failure !== 'denied') continue;
        const h = hooks.get(f.class) || { ...blank(), class: f.class };
        const key = `${group}\0${f.class}`;
        const d = dailyHooks.get(key) || { ...blank(), class: f.class, day: s.day, model: s.model, lane: s.lane, role: s.role, group };
        for (const target of [h, d]) {
          target.failures += f.count; target.sessions.add(s.session);
          for (const id of f.tool_call_ids || []) if (typeof id === 'string') target.ids.add(id);
          if (typeof f.recovered === 'boolean') { target.known += f.count; if (f.recovered) target.recovered += f.count; }
        }
        hooks.set(f.class, h); dailyHooks.set(key, d);
      }
    }
    if (list.some((s) => !s.known || s.incomplete)) {
      for (const t of tools.values()) t.calls = null;
      bashCalls = null; totalCalls = null;
    }
    const unknownGroups = new Set(list.filter((s) => !s.known || s.incomplete).map((s) => `${s.day}\0${s.model}\0${s.lane}\0${s.role}`));
    for (const d of daily.values()) if (unknownGroups.has(`${d.day}\0${d.model}\0${d.lane}\0${d.role}`)) d.calls = null;
    return { tools: [...tools.values()].map(finish), daily: [...daily.values()].map(finish), hooks: [...hooks.values()].map((h) => finish({ ...h, calls: bashCalls })), daily_hooks: [...dailyHooks.values()].map(({ group, ...h }) => finish({ ...h, calls: bashByGroup.get(group) })), totalCalls };
  }
  const all = [...slots.values()].filter((s) => matches(s, false));
  const filtered = all.filter((s) => matches(s));
  const result = aggregate(filtered);
  const class_counts = Object.create(null);
  for (const s of filtered) for (const f of s.failures) class_counts[f.class] = (class_counts[f.class] || 0) + f.count;
  for (const t of result.tools) {
    t.trend = Array.from({ length: days }, (_, i) => {
      const day = dayOf(Date.parse(firstDay) + i * 86400000), rows = result.daily.filter((d) => d.tool === t.tool && d.day === day);
      const calls = rows.length ? rows.reduce((n, d) => sumCalls(n, d.calls), 0) : null;
      const value = rate(rows.reduce((n, d) => n + d.failures, 0), calls);
      return { day, calls, failures: rows.reduce((n, d) => n + d.failures, 0), rate: value, x: i * 118 / days, height: value === null ? null : Math.min(26, value * 26) };
    });
  }
  const comparison = new Map();
  const compare = (metric, key, lane, value) => {
    const id = `${metric}\0${key}`, row = comparison.get(id) || { metric, key, values: {}, delta: {} };
    row.values[lane] = value; comparison.set(id, row);
  };
  for (const lane of LANES) {
    const a = aggregate(all.filter((s) => s.lane === lane));
    for (const t of a.tools) {
      compare('calls_per_100', t.tool, lane, rate(t.calls, a.totalCalls) === null ? null : 100 * rate(t.calls, a.totalCalls));
      compare('error_rate', t.tool, lane, t.error_rate); compare('recovery_rate', t.tool, lane, t.recovery_rate);
    }
    for (const h of a.hooks) compare('denial_rate', h.class, lane, h.rate);
  }
  for (const r of comparison.values()) for (const lane of LANES) r.delta[lane] = typeof r.values.native === 'number' && typeof r.values[lane] === 'number' ? r.values[lane] - r.values.native : null;
  const class_rates = new Map(result.hooks.map((h) => [h.class, h.rate]));
  for (const t of result.tools) for (const c of t.classes) {
    if (c.class.startsWith('denied/')) continue;
    const tool = inferredTool(c.class);
    const related = result.tools.filter((r) => tool === 'mcp' ? r.tool === 'mcp' || r.tool.startsWith('mcp__') : tool ? r.tool === tool : r.classes.some((x) => x.class === c.class));
    const calls = related.reduce((n, r) => sumCalls(n, r.calls), 0);
    const n = related.reduce((n, r) => n + (r.classes.find((x) => x.class === c.class)?.count || 0), 0);
    class_rates.set(c.class, rate(n, calls));
  }
  return { state: slots.size ? 'ok' : 'absent', ...result, class_rates: Object.fromEntries(class_rates), class_counts, comparison: [...comparison.values()], filters: { models: [...models].sort(), lanes: LANES, roles: [...roles].sort() }, selected };
}
