// The one edge table (spec §3), shared by the server and the CLI. `peers` maps
// name -> registration {role, console?, pair?, predecessor?}. An edge is
// symmetric: (a) leg/judge/consult <-> its console, (c) leg <-> its pair,
// (d) console <-> its predecessor/successor console. A pair never involves a
// console, and a leg is always one end of it. Nothing else is allowed,
// so a declaration only counts when both endpoints hold the role it requires.
const role = (peers, name) => peers[name]?.role;

function declared(peers, name) {
  const me = peers[name];
  const out = [];
  if (me.console && me.role !== 'console' && role(peers, me.console) === 'console') out.push(me.console);
  const mate = role(peers, me.pair);
  if (me.pair && mate && me.role !== 'console' && mate !== 'console' && (me.role === 'leg' || mate === 'leg')) out.push(me.pair);
  if (me.predecessor && me.role === 'console' && role(peers, me.predecessor) === 'console') out.push(me.predecessor);
  return out.filter(other => other !== name);
}

export function edgeList(peers, name) {
  if (!peers[name]) return [];
  const out = new Set(declared(peers, name));
  for (const other of Object.keys(peers)) {
    if (declared(peers, other).includes(name)) out.add(other);
  }
  return [...out].sort();
}

// The refusal lists only the caller's own edges, never another console's (threat T5).
export function check(peers, from, to) {
  const list = edgeList(peers, from);
  if (list.includes(to)) return { ok: true };
  return { ok: false, error: `no edge to ${to}; your edges: ${list.join(', ') || '(none)'}` };
}
