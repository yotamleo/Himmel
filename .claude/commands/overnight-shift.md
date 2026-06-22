---
description: Auto-dispatch N tickets from Jira as parallel subagents — emits plan + confirms before fanout (HIMMEL-134).
argument-hint: [--limit N] [--project HIMMEL|LUNA] [--status STATUS] [--priority ORDER]
---

Pulls the top-N tickets from Jira matching the operator's filter, emits a
dispatch plan, asks for confirmation, and then fans out one Task subagent
per ticket (each in its own worktree). Automates the manual overnight-mode
dispatch step from `docs/handover/overnight-mode.md`.

## Workflow

1. **Build the plan.**
   Run the build-plan helper with `$ARGUMENTS` forwarded as-is:

   ```bash
   bash scripts/overnight/build-plan.sh $ARGUMENTS
   ```

   Default flags (when arguments are empty):
   - `--limit 5`
   - `--project HIMMEL`
   - `--status 'To Do,In Progress'`
   - `--priority key-desc`

   The script queries jira, slugifies ticket titles, picks the
   appropriate worktree type (`feat` / `fix`), and prints a markdown
   plan with: filter summary, numbered ticket list with target worktree
   + subagent prompt, dispatch tree, and post-fanout follow-up steps.

2. **Show the plan to the operator.**
   Display the plan verbatim in chat.

3. **Confirm before dispatching.**
   Use `AskUserQuestion` to confirm. Offer:
   - `Dispatch all N (Recommended)` — proceed with the plan as-shown.
   - `Edit filter` — re-run `/overnight-shift` with different flags.
   - `Abort` — stop without dispatching.

4. **Fan out subagents (only when operator confirms).**
   For each non-epic ticket in the plan, dispatch a Task subagent
   in parallel (single message, multiple Agent tool calls):

   - `description`: `Implement <KEY>` (3-5 words).
   - `subagent_type`: `general-purpose` (or `feature-dev:feature-dev`
     for larger features — pick based on ticket type/scope).
   - `isolation`: `worktree` (each subagent gets its own copy of the
     repo on the target branch).
   - `prompt`: The subagent prompt from the plan + the standard
     loop-step contract from the resume file (worktree → impl + tests
     → commit + push → PR → audit → merge → prune).

   Each subagent runs the implementation independently. Per-agent
   guardrails are inherited from the existing PreToolUse hooks:
   - `block-edit-on-main.sh` — refuses edits on main (existing).
   - `block-read-secrets.sh` — refuses reads of secret files (existing).
   - `block-mcp-when-plugin-exists.sh` — refuses MCP calls when a
     plugin equivalent exists (existing).

5. **After all subagents return — self-heal pass (HIMMEL-476, C2).**
   The fanout is fire-and-forget: a returned subagent can't be resumed,
   only replaced. Before writing the report, run a POST-RETURN
   retry/triage pass so one mechanical gate slip doesn't silently kill a
   ticket.

   a. **Capture** each subagent's result/log to a file and build a
      *swarm result ledger* (one row per dispatched ticket):

      ```
      KEY \t BRANCH \t PR \t STATUS \t OUTCOME \t LOGFILE
      ```

      (`STATUS` ∈ `done|blocked|partial`; `LOGFILE` = path to that
      subagent's captured output, empty for clean `done` rows.)

   b. **Classify** — done rows pass through; a CLOSED allow-list of
      mechanical failures (lint / encoding / diff-range) is HELD with a
      fix-subagent dispatch spec; substantive/CR failures are TRIAGED
      (reported, never auto-fixed — fail-safe):

      ```bash
      bash scripts/overnight/self-heal.sh classify \
        --rows-in /tmp/overnight-ledger.tsv \
        --rows-out /tmp/overnight-rows.tsv \
        --dispatch-out /tmp/overnight-fix-plan.tsv
      ```

   c. **Dispatch fresh fix subagents** — for each row in the dispatch
      plan, dispatch ONE new Task subagent (`isolation: worktree`) on that
      branch with the spec's `FIX_INSTRUCTION` (scoped: fix the mechanical
      finding ONLY, keep the same attestation trailers, push). Single-writer
      holds — each fix subagent writes ONLY its own branch; the parent never
      edits a branch. Re-collect their results into a *fixed* TSV
      (`KEY \t BRANCH \t PR \t STATUS \t OUTCOME`).

   d. **Reconcile** — merge the re-collected fixes back into the report
      rows. Auto-fixed-green becomes `done`; a fix that still fails (or a
      fix subagent that never returned) becomes an operator-gated blocker
      (bounded — one auto-fix attempt, never a loop):

      ```bash
      bash scripts/overnight/self-heal.sh reconcile \
        --plan /tmp/overnight-fix-plan.tsv \
        --fixed /tmp/overnight-fixed.tsv \
        --rows-in /tmp/overnight-rows.tsv \
        --rows-out /tmp/overnight-final.tsv
      ```

   If the fanout produced no mechanical failures, the dispatch plan
   (`/tmp/overnight-fix-plan.tsv`) is empty and `classify`'s `--rows-out`
   (`/tmp/overnight-rows.tsv`) is ALREADY the final TSV — skip c/d entirely
   and feed THAT file to the report in step 6 (there is no
   `/tmp/overnight-final.tsv` in this case, because reconcile never ran).

   e. **Emit structured status back to the ledger (HIMMEL-517, L3 push-side).**
      The orchestrator holds the structured signal the where-are-we ledger's
      `next_action`/`blockers`/`awaiting_operator` fields exist for — populate
      them so the **next** session's L2 view surfaces real status (closes the
      loop: L3 write → ledger → L2 read). For each final row that is `blocked`
      or carries a `DECISION`, emit through the single writer (judgement-driven —
      you decide what is blocked; skip cleanly when the ledger dir is absent /
      where-are-we is OFF):

      ```bash
      # blocked row → record the blocker(s):
      node scripts/where-are-we/provision.mjs emit \
        --ledger .where-are-we/ledger.jsonl --key "$KEY" --blockers "$REASON"
      # operator-decision row → record the operator-ask:
      node scripts/where-are-we/provision.mjs emit \
        --ledger .where-are-we/ledger.jsonl --key "$KEY" --awaiting "$DECISION"
      # a row that went green → clear any stale blocker:
      node scripts/where-are-we/provision.mjs emit \
        --ledger .where-are-we/ledger.jsonl --key "$KEY" --clear-blockers
      ```

      `emit` only writes the three fields the orchestrator owns — `next_action`
      and `blockers` are handover-authoritative, `awaiting_operator` is
      authoritative for any source; `status`/`branch` stay jira/git-owned and
      would vanish in fold from a handover record. It appends via the same
      `appendRecords` lock the collectors use (single-writer rule holds). Skip
      entirely if `.where-are-we/` does not exist.

6. **Write the consolidated morning report (HIMMEL-258).**
   Feed the final rows —

   ```
   KEY \t BRANCH \t PR \t STATUS \t OUTCOME [\t DECISION]
   ```

   where `STATUS` ∈ `done|blocked|partial` and a non-empty `DECISION`
   marks an item needing a human call — into `morning-report.sh`. Use the
   reconcile output when there were mechanical failures, else the classify
   output:

   ```bash
   # mechanical failures were dispatched + reconciled (step 5d ran):
   bash scripts/overnight/morning-report.sh --rows /tmp/overnight-final.tsv
   # OR — no mechanical failures (steps 5c/5d skipped):
   bash scripts/overnight/morning-report.sh --rows /tmp/overnight-rows.tsv
   ```

   The script writes a single artifact (decisions-needed grouped at top,
   per-ticket table ordered decisions-first) to
   `<handover-root>/overnight-report-YYYY-MM-DD.md`, resolving the root
   via `scripts/lib/handover-path.sh` (`handover_root_ensure` — a write
   op, so the Mode A inline dir is created on demand). A broken
   `HANDOVER_DIR` fails closed (exit 2 — fix it or pass `--out`); there
   is no hardcoded `./handovers/` fallback.

   Then run `/handover-flush` (HIMMEL-143) to reconcile any handover
   state the subagents wrote, and surface the report path + its
   "Decisions needed" block in chat. Morning review = the operator reads
   that ONE report, then drills into PRs (`/pr-check`) — no per-ticket
   discovery.

7. **Drop a durable resume breadcrumb (HIMMEL-477, C3).**
   This post-fanout step is one of the seams the breadcrumb writer
   piggybacks (there is no per-leg dispatch runtime). Record where the run
   stopped so a crashed/interrupted resume reconstructs intent instead of
   silently grounding in raw repo state:

   ```bash
   bash scripts/handover/breadcrumb.sh write \
     --ticket "$EPIC_OR_RUN_KEY" \
     --next-step "review overnight report; merge green PRs; triage blockers" \
     --completed "fanout dispatched" --completed "self-heal + morning report written"
   ```

   On the next session, resolve it BEFORE acting — a fresh breadcrumb gives
   a deterministic resume; a missing/stale one is flagged
   `DEGRADED — confirm before proceeding` (exit 3) with intent
   reconstructed from `git log` + Jira, never a silent degrade:

   ```bash
   bash scripts/handover/breadcrumb.sh resolve --ticket "$EPIC_OR_RUN_KEY"
   ```

## Flags forwarded to `build-plan.sh`

| Flag | Default | Notes |
|---|---|---|
| `--limit N` | 5 | Positive integer; rejected otherwise. |
| `--project KEY` | HIMMEL | Any Jira project key. |
| `--status STATUS` | `To Do,In Progress` | Comma-separated list passed to `jira list`. |
| `--priority ORDER` | `key-desc` | v1 supports `key-desc` (newest-first). Other values pass through for forward-compat with a future priority-aware jira CLI. |
| `--out PATH` | _(none)_ | Write plan to a file in addition to stdout. |

## Out of scope (per HIMMEL-32 reopen)

- Per-agent guardrails beyond the existing PreToolUse hooks — covered separately.
- MORNING_BRIEFING.md auto-generator — separate sub-task (HIMMEL-135).

## Smoke test

```bash
bash scripts/overnight/test-build-plan.sh
bash scripts/overnight/test-morning-report.sh
bash scripts/overnight/test-self-heal.sh
```

24/24 + 35/35 + 43/43 pass on Git Bash.
