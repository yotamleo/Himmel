---
description: Audit changed CLAUDE.md files against the claude-md-improver rubric before PR — audit-only, applies no edits on its own
---

Pre-ship quality gate for CLAUDE.md edits (HIMMEL-218). Run this on a worktree
branch **before `gh pr create`** whenever the branch changes a `CLAUDE.md`. It
runs the `claude-md-management:claude-md-improver` skill in AUDIT mode against
the changed file(s) and surfaces findings; fixes are a deliberate follow-up you
apply in the worktree, never an automatic edit. (`block-edit-on-main` would
refuse an edit to the primary worktree on `main` anyway — CLAUDE.md edits belong
in a worktree.)

Lean-invoke by design (HIMMEL-177): an LLM audit is too heavy to run on every
commit, so this is on-demand, not a hook. It is also why there is no operational
rule about it in root `CLAUDE.md` (see the operator convention on keeping
CLAUDE.md free of prunable operational guidance).

Steps:

1. List the CLAUDE.md files this branch changes vs main:
   ```bash
   git diff --name-only main...HEAD -- 'CLAUDE.md' '**/CLAUDE.md'
   ```
   If the list is empty, report `no CLAUDE.md change on <branch> — nothing to audit`
   and stop.

2. If `git branch --show-current` is `main`, stop and report that CLAUDE.md
   edits belong in a worktree — this pre-ship audit runs on feature branches.

3. Invoke the `claude-md-management:claude-md-improver` skill via the Skill tool,
   scoped to the file(s) from step 1, in **audit mode**: produce a quality report
   against the rubric (the 4 global rules — think-before-coding, simplicity,
   surgical changes, goal-driven — plus himmel's own conventions: state-not-prompt,
   every line paid per session, reference detail lives in `docs/internals/`).
   Do NOT let the skill auto-apply edits; this command is audit-only.

4. Surface the findings grouped by severity. Apply the clear, in-scope fixes
   yourself with Edit against the **worktree copy** (never the primary worktree on
   main), and note each. Leave judgment-call findings for the operator.

5. On request, re-run step 3 to confirm the audit is clean before `gh pr create`.

Notes:
- Audit-only: the skill emits a report; edits are a separate, deliberate step you
  make in the worktree. Nothing is mutated automatically by invoking this command.
- Scope to the changed CLAUDE.md(s) — do not audit unchanged files in the tree.
