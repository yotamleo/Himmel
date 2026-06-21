// scripts/where-are-we/lib/query.mjs
import { inFlight } from './fold.mjs';

export function branchToKey(name) {
  const m = /^[a-z]+\/([A-Za-z]+-\d+)\b/.exec(name || '');
  return m ? m[1].toUpperCase() : null;
}

function globalView(state) {
  return { inFlight: inFlight(state), awaiting_operator: state.awaiting_operator, locks: state.locks };
}

function forKey(state, key) {
  const item = state.items[key];
  if (!item) return globalView(state);
  const locks = state.locks.filter((l) => l.key === key);
  return { item, locks };
}

export function query(state, scope) {
  switch (scope.mode) {
    case 'for': return forKey(state, scope.key);
    case 'branch': {
      const key = branchToKey(scope.name);
      return key ? forKey(state, key) : globalView(state);
    }
    case 'locks': return { locks: state.locks };
    case 'global':
    default: return globalView(state);
  }
}
