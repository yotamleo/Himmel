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

## himmel rubric overrides (HIMMEL-480)

The upstream rubric predates Anthropic's Claude 5 context-engineering guidance
and scores two dimensions in the direction that guidance **reverses**. It ships
in the user-scope plugin cache
(`claude-plugins-official/claude-md-management/*/skills/claude-md-improver/`), so
it is deliberately **not ours to edit**: a cache write is discarded on the next
plugin update and leaks into every parallel session meanwhile. Apply these on top
of its report instead. Where they conflict, **these win** — say so explicitly in
the findings rather than reporting two scores without a verdict.

### Score against the six shifts

| Then — what the upstream rubric rewards | Now — score for this instead |
|---|---|
| Give Claude rules | Let Claude use judgement |
| Give Claude examples | Design interfaces (expressive params/enums) |
| Put it all upfront | Progressive disclosure (skills, deferred tools, file trees) |
| Repeat yourself | State it ONCE, in the place that acts on it |
| Memory in CLAUDE.md | Auto-memory |
| Simple specs | Rich references (code, test suites, rubrics) |

### Two dimensions to re-score, not accept

- **Architecture clarity** (upstream: 20 pts, "key directories explained").
  A directory listing is derivable from `ls`, and documenting it is precisely
  the anti-pattern the guidance names. Do **not** award points for one, and do
  **not** raise a finding that one is missing. Score instead on whether the
  **non-derivable** structure is captured: untracked build artifacts, generated
  files, which subtree owns which convention. himmel's `MAP` earns full marks in
  three sentences — if the audit wants it expanded, the audit is wrong.
- **Commands/workflows** (upstream: 20 pts, build/test/deploy commands).
  Keep the dimension — non-guessable commands are on the guidance's KEEP list —
  but score only what a reader could not infer. `npm test` in a directory with a
  `package.json` is inferable and earns nothing; `bash scripts/ci/run-shell-tests.sh`,
  or a suite that `npm test` does **not** reach, is the real content.

### Size budget

Every byte is paid on every turn of every session. Report the byte count and
grade it:

- **≤ 16,000 B** — fine.
- **16,001–20,000 B** — flag, and name the specific lines that are derivable or
  reference-shaped and belong in `docs/internals/`. A bare "consider trimming" is
  not a finding.
- **> 20,000 B** — a finding in its own right, whatever else scores well.

Report the **delta vs the branch base** too, not only the absolute: a +2,000 B
change is worth surfacing even while under budget.

### Do not credit verification scaffolding

Per the Opus 5 guidance, explicit "verify your work" / "double-check" /
"re-read before answering" instructions cause **over**-verification, as do
separate verification steps in harness scaffolding. If the file contains them,
that is a finding to **remove** — never a strength to credit. Same for standing
instructions to delegate or to spawn subagents by default.

Notes:
- Audit-only: the skill emits a report; edits are a separate, deliberate step you
  make in the worktree. Nothing is mutated automatically by invoking this command.
- Scope to the changed CLAUDE.md(s) — do not audit unchanged files in the tree.
