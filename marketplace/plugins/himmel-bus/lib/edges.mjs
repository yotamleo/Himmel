// The one edge table (spec §3), shared by the server and the CLI. `peers` maps
// name -> registration {role, console?, pair?, predecessor?}. An edge is
// symmetric: (a) leg/judge/consult <-> its console, (c) leg <-> its pair,
// (d) console <-> its predecessor/successor console. Nothing else is allowed.
export function edgeList(peers, name) {
  const me = peers[name];
  if (!me) return [];
  const out = new Set();
  const add = other => { if (other && other !== name && peers[other]) out.add(other); };
  add(me.console);
  add(me.pair);
  add(me.predecessor);
  for (const [other, p] of Object.entries(peers)) {
    if (p.console === name || p.pair === name || p.predecessor === name) add(other);
  }
  return [...out].sort();
}

// The refusal lists only the caller's own edges, never another console's (threat T5).
export function check(peers, from, to) {
  const list = edgeList(peers, from);
  if (list.includes(to)) return { ok: true };
  return { ok: false, error: `no edge to ${to}; your edges: ${list.join(', ') || '(none)'}` };
}
