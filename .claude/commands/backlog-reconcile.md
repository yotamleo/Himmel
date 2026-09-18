---
description: Classify the open Jira backlog against merged commits and propose batched closes. Read-only until the operator approves.
---

Lean-invoke wrapper over `scripts/jira/reconcile-backlog.mjs` (HIMMEL-374) — the
pure-code engine that classifies every open ticket against the merged-commit
corpus. This command never writes to Jira on its own; it only runs the
engine's default `--dry-run` mode and asks before re-invoking it with
`--apply`.

1. Run the engine read-only:
   ```bash
   node scripts/jira/reconcile-backlog.mjs --project "$JIRA_PROJECT_KEY" --hygiene-doc <path-to-latest-hygiene-sweep-report-if-any>
   ```
   (omit `--hygiene-doc` if no hygiene-sweep report exists yet). This prints
   one JSON record per ticket plus a summary line — no writes happen in this
   mode.
2. Group the non-`LEAVE` records into the batched-close shape from HIMMEL-378:
   - **A — shipped**: `disposition: CLOSE` (`reason: subject-match`) — a
     merged commit subject names the ticket and nothing downgrades it.
   - **D — rescope partial**: `disposition: RESCOPE` (`reason:
     partial-delivery` / `outcome-acceptance` / `multi-task-ticket`) — comment
     only, never transitioned.
   - Note explicitly: buckets **B (superseded)** and **C (stale, Won't Do)**
     from HIMMEL-378's original design have no automated trigger in this
     engine (`STALE-PREMISE` is schema-only — see `reconcile-lib.mjs`'s
     comment above `classifyTicket`) — inventing a heuristic for "this
     ticket's premise no longer exists" would be guessing at semantics the
     commit corpus can't prove. Present any `LEAVE` reasons worth a human
     glance (e.g. `body-only-match`) as candidates for manual B/C judgment,
     but do not auto-bucket them.
3. Present batch A and batch D to the operator with the evidence line for
   each ticket. **Do not proceed without an explicit answer.**
4. Only on explicit approval, re-run with the approved keys and the existing
   safety valves (HIMMEL-3128 — both required by the engine itself):
   ```bash
   node scripts/jira/reconcile-backlog.mjs --project "$JIRA_PROJECT_KEY" --apply \
     --only <approved-key-list> --max-close <count-of-approved-CLOSE-keys> \
     --hygiene-doc <same-path-as-step-1-or-/dev/null>
   ```
   A ticket the operator did not name in `--only` is untouched no matter its
   disposition.
5. Report the engine's own summary line (mode/counts/acted/failed/closed)
   back to the operator.
