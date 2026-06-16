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

5. **After all subagents return — write the consolidated morning report
   (HIMMEL-258).**
   Collect ONE TSV row per dispatched ticket from the subagent results —

   ```
   KEY \t BRANCH \t PR \t STATUS \t OUTCOME [\t DECISION]
   ```

   where `STATUS` ∈ `done|blocked|partial` and a non-empty `DECISION`
   marks an item needing a human call. Write the rows to a temp file and
   run:

   ```bash
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
```

24/24 + 35/35 pass on Git Bash.
