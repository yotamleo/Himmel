// scripts/where-are-we/lib/provision.mjs — L3 orchestrator seam (HIMMEL-517).
// PURE (no I/O). Two directions of the same push-side seam over the L1 contract:
//   renderSlice  — READ: the relevant slice for a ticket KEY, to embed in a
//                  spawned subagent's prompt (the PUSH complement to L2's pull-
//                  side SessionStart inject).
//   buildEmitRecord — WRITE: the single structured record the orchestrator
//                  appends (via the existing single writer appendRecords) to
//                  populate next_action/blockers/awaiting_operator for a KEY.
// L3 adds NO new fold/query/render logic and NO second writer path.
import { query } from './query.mjs';
import { renderItem } from './render.mjs';
import { UsageError } from './errors.mjs';

// READ: render the KEY's ledger slice for prompt embedding. Returns '' on a miss
// (no item for the KEY — the common "works before a branch/ticket exists" case;
// NO global-digest fallback, unlike L2's dock) AND on a contentless hit (an item
// that exists but carries no status / next_action / blockers / locks — e.g. a key
// seen only via a bare awaiting_operator emit; renderItem would emit a contentless
// "# KEY / - status: —" block that is noise in a child prompt).
export function renderSlice(state, key) {
  const r = query(state, { mode: 'for', key });
  const it = r.item;
  if (!it) return '';
  const hasLocks = (r.locks || []).length > 0;
  const substantive = it.status != null || it.next_action != null
    || (Array.isArray(it.blockers) && it.blockers.length > 0) || hasLocks;
  return substantive ? renderItem(it, r.locks || []) : '';
}

// WRITE: build the single structured record (source 'handover', kind 'ticket').
// Throws UsageError on an empty or internally-contradictory request so a no-op /
// ambiguous record never reaches the ledger. Emits ONLY the three handover-
// authoritative fields (next_action/blockers handover-authoritative, awaiting_
// operator always) — status/branch are jira/git-owned and would vanish in fold,
// so they are not offered. Clears emit the field's empty form (next_action:null,
// blockers:[], awaiting_operator:[]); a clear-only emit is a valid record because
// validateRecord checks only the REQUIRED set (ts/source/key/kind), and fold then
// finds the cleared field authoritative + isClear and deletes it.
export function buildEmitRecord(spec, now) {
  if (!spec.key) throw new UsageError('emit: --key is required');
  const rec = { ts: now, source: 'handover', key: spec.key, kind: 'ticket' };
  let any = false;

  if (spec.next_action != null && spec.clearNext) {
    throw new UsageError('emit: --next-action and --clear-next conflict');
  }
  if (spec.clearNext) { rec.next_action = null; any = true; }
  else if (spec.next_action != null) { rec.next_action = spec.next_action; any = true; }

  if (spec.blockers != null && spec.clearBlockers) {
    throw new UsageError('emit: --blockers and --clear-blockers conflict');
  }
  if (spec.clearBlockers) { rec.blockers = []; any = true; }
  else if (spec.blockers != null) { rec.blockers = spec.blockers; any = true; }

  if (spec.awaiting_operator != null && spec.clearAwaiting) {
    throw new UsageError('emit: --awaiting and --clear-awaiting conflict');
  }
  if (spec.clearAwaiting) { rec.awaiting_operator = []; any = true; }
  else if (spec.awaiting_operator != null) { rec.awaiting_operator = spec.awaiting_operator; any = true; }

  if (!any) {
    throw new UsageError('emit: at least one of --next-action/--blockers/--awaiting (or a --clear-*) is required');
  }
  return rec;
}
