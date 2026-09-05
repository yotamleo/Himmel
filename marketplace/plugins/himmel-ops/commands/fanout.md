---
description: Fan out N work items to the right lane by TYPE — encodes the invariant routing table so tier selection stops being a per-dispatch judgement call, and REFUSES to route destructive/irreversible work below the judgement tier (HIMMEL-1829).
argument-hint: [work items, one per line or a numbered list]
---

Fan-out has been a HABIT, not a primitive: `/overnight-shift` dispatches with
no model named at all, and a destructive worktree cleanup was once fanned out
to Sonnet — judgement work with an unrecoverable failure mode. This command
makes lane selection a lookup instead of an improvisation.

## Routing (invariant — CLAUDE.md "Subagent policy", restated here only so
step 3 has something to validate against; if the policy changes, change both)

| Work type | Lane | Notes |
|---|---|---|
| `judgement` — taste calls, IRREVERSIBLE or destructive operations | Fable | escalation target |
| `reasoning` — multi-step reasoning, orchestration | Opus | default parent |
| `implementation` — well-specified implementation | Sonnet (default) or a caller-named claude-tier lane (e.g. Opus for a harder task) | impl routes to native Claude subagents only — HIMMEL-1967; an impl-class lane (claudex, hermes-oneshot, codex-exec/wsl, openrouter-claude) is ALWAYS refused as a /fanout destination, dormant or not — it isn't dispatchable via the `Agent` tool's `model` param |
| `research` — scoped, read-only | Sonnet | |
| `bulk` — bulk mechanical | Haiku | **never spawns further** |

Any item marked `destructive: true` MUST be `type: "judgement"` — anything
else is refused, not downgraded. That is the specific defect this command
exists to prevent.

## Workflow

1. **Classify.** From `$ARGUMENTS` (or ask if empty), build one entry per
   work item: `{id, type, destructive, lane?, effort?, why}`. `lane` only
   applies to `type: "implementation"` (omit to default to Sonnet) and must
   name a live, non-dormant claude-tier lane — an impl-class lane is always
   refused. Mark `destructive: true` for anything with an unrecoverable
   failure mode — deletion, force-push, `git worktree remove`, prod writes,
   irreversible state changes. When unsure, ask; never default a
   questionable item to `destructive: false`.

2. Write the items array to a scratch JSON file.

3. **Validate against the live roster — this is the refusal mechanism, not a
   request:**

   ```bash
   node scripts/lanes/fanout-plan.mjs /path/to/items.json
   ```

   - Exit 0 → the plan (JSON), one resolved `lane` per item plus an explicit
     `model` (the DISPATCHABLE id — pass this to the `Agent` tool's `model`
     param verbatim) and a human-readable `label` for display.
   - Exit 1 → REFUSED. Every violation printed to stderr (unknown type,
     destructive routed below judgement, a lane not in the LIVE roster
     `node scripts/lanes/resolve.mjs --json` reports, a lane the roster marks
     `dormant`, or a `bulk` item requesting further spawning). Fix the items
     file and re-run — never hand-override the script's verdict.
   - Exit 2 → items file didn't parse.

4. **Show the plan, then confirm before dispatching** (the same
   confirm-before-fanout shape `/overnight-shift` already has). One line per
   item: id, type, destructive?, lane, model, why. Use `AskUserQuestion` (or a
   plain-text confirm if unavailable):
   - `Dispatch all N (Recommended)`
   - `Edit an item's type/destructive flag` — back to step 1
   - `Abort`

5. **Dispatch only on confirmation** — one `Agent` call per item, passing the
   plan's `model` verbatim to the tool's `model` param (never `label` — that's
   for display only); no dispatch may inherit the parent loop.
   Every brief carries:
   - **Context / why / done-looks-like** — the child starts blank.
   - **The RETASK block**, fresh nonce per dispatch (verbatim template:
     `docs/internals/retask-channel.md` §3).
   - **Concurrency discipline** — single-writer: many readers, ONE writer,
     never fan parallel writes at one shared artifact; independent
     per-item/per-ticket branches are fine.
   - **The attestation-trailer requirement** (`Platforms tested:` /
     `Security reviewed:` in the first commit) for any code-touching item.

6. Report what was dispatched where, and what's still running.

## Notes

- `scripts/lanes/fanout-plan.mjs` consults `scripts/lanes/resolve.mjs --json`
  for the LIVE roster on every run — never a hardcoded lane list. A lane that
  is out of bank, unauthenticated, retired, or marked `dormant` simply fails
  validation (dormant is a policy closure — HIMMEL-1967 — not merely
  "unavailable"; it is never routed around even when its own probe passes).
- Spawn-depth limit 2 and "Haiku does not spawn" still hold; this command
  doesn't relax either.
- `/overnight-shift`'s dispatch step should be updated to name models via this
  same validator (one routing implementation, not two) — tracked as a
  follow-up; see the HIMMEL-1829 PR notes for why it wasn't done in the same
  change.
