# scripts/jira — Jira CLI source

Loads only when working in this subtree. The repo-wide **prefer-plugin-
over-MCP** rule is frame-shaping and lives in the root `CLAUDE.md` — not
restated here.

## What this is
The Jira CLI itself (`jira-cli`). Run from repo root as
`node scripts/jira/dist/index.js <op>`. ESM (`"type": "module"`),
arg-parsing via `commander`. One file per op in `src/commands/`.
A second binary ships from the same package: the **Confluence CLI**
(`node scripts/jira/dist/confluence.js <op>`, entry `src/confluence.ts`,
ops under `src/commands/confluence/`) — shares `client.ts` auth + ADF
helpers (HIMMEL-437).

## Editing conventions
- **`dist/` is gitignored — not committed.** After editing `src/`, run
  `npm run build` (`tsc`) or the `dist/index.js` callers run stale code.
- Tests are colocated `*.test.ts`; run `npm run test` (vitest) after edits.
- `transition` takes a status **NAME**, not an ID (no two-call lookup).
- `create --summary` is an alias for `create --title` (Jira's own field name
  is `summary`, so it's the natural reach). If both are given, `--title`
  wins; one of the two is required (HIMMEL-1188).
- `create` refuses a body without the Impact/What/Why/Plan/DoD/Agent detail
  sections, Plan and DoD each needing a real bullet or numbered line (Epic and
  Subtask only warn; `create --type Task --skeleton` prints the six headings
  to fill); the rule lives in `src/plain-block.ts`, shared by the CLI and MCP
  `create` (HIMMEL-5226, HIMMEL-5643).
- `create` also refuses a Task, Story or Bug with no `--sector`, or with
  neither `--parent <epic>` nor `--labels standalone` (Epic and Subtask only
  warn); `homeVerdict` in `src/plain-block.ts`, shared by the CLI and MCP
  `create` (HIMMEL-6223). Any script that files a ticket passes both.
- Verify every `create`/`move` by checking the printed `Created HIMMEL-N`.
- `JIRA_PROJECT_KEY` is required at runtime — no `HIMMEL` fallback.

## Reference
- Op ↔ MCP mapping: [`docs/internals/jira-plugin.md`](../../docs/internals/jira-plugin.md).
