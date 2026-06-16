# Jira plugin ↔ MCP mapping — reference

> Extracted from `CLAUDE.md` per HIMMEL-164 (state-not-prompt slimming).
> The rule ("prefer the local Jira CLI over Atlassian MCP") stays in
> CLAUDE.md and is enforced structurally by the
> `block-mcp-when-plugin-exists.sh` PreToolUse hook + the `mcp-plugin-refs`
> pre-commit gate (see `docs/internals/enforcement.md`). This file is the
> per-operation lookup table.

For Jira ops in this repo, default to the local CLI at
`scripts/jira/dist/index.js` instead of the Atlassian MCP server
(`mcp__plugin_atlassian_atlassian__*`).

**Why:**
- The CLI is one shell call with the schema in `--help` — fewer
  input/output tokens than MCP, which fetches a verbose JSON schema
  per tool and returns full Jira response payloads.
- Dogfoods the code we ship.
- `transition` takes a status NAME (e.g. `Done`), avoiding the
  two-call MCP pattern (`getTransitionsForJiraIssue` to look up the
  numeric transition ID, then `transitionJiraIssue` with that ID).

**Mapping (preferred plugin call ↔ MCP equivalent):**

| Op          | Plugin                                                                      | MCP                                                              |
|-------------|-----------------------------------------------------------------------------|------------------------------------------------------------------|
| Get         | `node scripts/jira/dist/index.js get HIMMEL-N` (default includes description body; add `--short` for header-only) | `getJiraIssue`                                                   |
| List/search | `... list --jql "..."`; `... list --label <l>` filters by label (HIMMEL-243; composed into the built JQL, `--jql` still wins) | `searchJiraIssuesUsingJql`                                       |
| Create      | `... create --type Story --title ... --desc ... [--labels a,b]` (project auto-loaded from `.env`; pass `--project FOO` only to override per-call; `--labels` comma-separated, HIMMEL-243) | `createJiraIssue`                                                |
| Edit        | `... edit HIMMEL-N --title ... --desc ... [--labels a,b]` (`--labels` is FULL-REPLACE: the set becomes the complete label list — no MCP `editJiraIssue` fallback needed for labels since HIMMEL-243) | `editJiraIssue`                                                  |
| Comment     | `... comment HIMMEL-N "text"`                                               | `addCommentToJiraIssue`                                          |
| Attach      | `... attach HIMMEL-N file.png`                                              | (none — MCP has no attach)                                       |
| Transition  | `... transition HIMMEL-N Done`                                              | `getTransitionsForJiraIssue` + `transitionJiraIssue` (two calls) |
| Transitions | `... transitions HIMMEL-N` (HIMMEL-149 — id<TAB>name per available transition) | `getTransitionsForJiraIssue`                                  |
| Move        | `... move HIMMEL-N --to-project LUNA [--type Story] [--dry-run]` (HIMMEL-197 — close source + create target + copy comments) | (none — Jira Cloud REST API has no direct project-change endpoint) |
| Projects    | `... projects` / `... project-create ...`                                   | `getVisibleJiraProjects` / no equivalent for create              |
| Link        | `... link HIMMEL-A HIMMEL-B --type Relates` (HIMMEL-210; case-insensitive type, validated against the live type list) | `createIssueLink` (+ `getIssueLinkTypes` for the type list) |

**Use MCP only when the plugin lacks the operation** (custom-field
discovery, account-ID lookup via `lookupJiraAccountId`, Confluence
operations — there is no Confluence plugin yet). The MCP block in
`block-mcp-when-plugin-exists.sh` derives its blocked-set by introspecting
the CLI's verbs (`node …/index.js --list-commands`) against a small
verb→MCP-method map (HIMMEL-231) — an MCP method is refused iff its mapped
verb is a real CLI verb, so the set tracks this table automatically instead
of drifting from a hand-maintained literal. E.g. `getTransitionsForJiraIssue`
is refused post-HIMMEL-149 because the `transition` verb exists; dogfood it.

**JIRA_PROJECT_KEY is required (HIMMEL-146).** The plugin no longer
hardcodes `HIMMEL` as a fallback in `projectKey()`. Operators must set
`JIRA_PROJECT_KEY=<your-key>` in `.env` or the launching shell.
`scripts/setup.sh` step 0.4 verifies this at install time and fails
loud when unset.

**Do NOT pass `--project` or export `JIRA_*` when running from the repo
root.** The CLI calls `loadEnv()` at startup, which reads the repo-root
`.env` into `process.env` (via `??=`, never clobbering an already-set
var). So `JIRA_BASE_URL / JIRA_EMAIL / JIRA_API_TOKEN / JIRA_PROJECT_KEY /
JIRA_CLOUD_ID` are all picked up automatically — `node
scripts/jira/dist/index.js list` works with an empty shell environment.
A `JIRA_PROJECT_KEY` *unset in your shell* is irrelevant and is **not**
the cause of a `projectKey()` error; check the repo-root `.env` instead.
Only pass `--project FOO` for a one-off call against a different project.
