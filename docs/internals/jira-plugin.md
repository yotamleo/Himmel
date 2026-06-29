# Jira plugin ↔ MCP mapping — reference

> Extracted from `CLAUDE.md` per HIMMEL-164 (state-not-prompt slimming).
> The rule ("prefer the local Jira CLI over Atlassian MCP") stays in
> CLAUDE.md and is enforced structurally by the
> `block-backend-tier.sh` PreToolUse hook + the `mcp-plugin-refs`
> pre-commit gate (see `docs/internals/enforcement.md`). This file is the
> per-operation lookup table.
>
> Routing is registry-driven: `scripts/backends.json` lists jira with
> `chain: [cli, api, mcp]` — CLI first, raw REST (curl/WebFetch) second,
> MCP last. Add or reorder tiers there; no hook edit needed.

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
| Assign      | `... assign HIMMEL-N <email\|accountId>` (`-`/`unassigned` clears, `auto` = default assignee; email → accountId via `/user/search`) (HIMMEL-437) | `editJiraIssue` (assignee field) |
| Attachments | `... attachments HIMMEL-N` (list) / `... download HIMMEL-N [id] [--all] [--out dir]` (HIMMEL-437) | (none — MCP has no attachment download) |
| Worklog     | `... worklog add HIMMEL-N --time 1h [--comment ...]` / `... worklog list HIMMEL-N` (HIMMEL-437) | `addWorklogToJiraIssue` (no list) |
| Watchers    | `... watch HIMMEL-N [user]` / `... unwatch HIMMEL-N [user]` / `... watchers HIMMEL-N` (HIMMEL-437) | (none) |
| Sprint      | `... boards` / `... sprints [--board N]` / `... sprint HIMMEL-N <sprintId\|backlog>` (Agile API `/rest/agile/1.0`; `JIRA_BOARD_ID` default) (HIMMEL-437) | (none — MCP has no Agile-board ops) |

**Use MCP only when the plugin lacks the operation** (custom-field
discovery, account-ID lookup via `lookupJiraAccountId`). Confluence now has
a sibling CLI (see below) — prefer it over the Confluence MCP tools. The MCP block in
`block-backend-tier.sh` derives its blocked-set by introspecting
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

## Confluence CLI (HIMMEL-437)

A sibling binary `scripts/jira/dist/confluence.js` (same package, same
`.env` auth) covers routine Confluence ops. It is registered as the
`confluence` service in `scripts/backends.json` (same Atlassian MCP prefix
as jira, `chain: [cli, api, mcp]`), so `block-backend-tier.sh` hard-blocks
the equivalent Confluence MCP tools — the routing hook evaluates BOTH
atlassian-prefixed services and blocks on whichever has the mapped verb
(Jira/Confluence method suffixes are disjoint).

**API surface:** Confluence Cloud REST **v2** (`/wiki/api/v2`) is the
default; two ops have no v2 equivalent and stay on **v1**
(`/wiki/rest/api`): **CQL search** and **attachment upload**.

**Auth (HIMMEL-437):** a *scoped* Jira API token returns `401` against
Confluence (`/wiki`) — same gotcha as the bitbucket CLI. The confluence CLI
uses `CONFLUENCE_EMAIL` / `CONFLUENCE_API_TOKEN` when **both** are set
(point them at a Confluence-capable, i.e. scopeless/full-account, Atlassian
token); otherwise it falls back to `JIRA_EMAIL` / `JIRA_API_TOKEN` (which
works only if that token covers Confluence too).

| Op            | Plugin (`node scripts/jira/dist/confluence.js …`)                    | MCP                                  |
|---------------|----------------------------------------------------------------------|--------------------------------------|
| Get page      | `page get <id>` (renders body ADF→text)                              | `getConfluencePage`                  |
| Create page   | `page create --space KEY --title ... --body-file f [--parent id]`    | `createConfluencePage`               |
| Update page   | `page update <id> [--title ...] [--body-file f]` (auto version-bump) | `updateConfluencePage`               |
| Delete page   | `page delete <id>`                                                    | (none)                               |
| Search        | `search --cql "..." [--limit N]` (v1)                                | `searchConfluenceUsingCql`           |
| Spaces        | `spaces [--limit N]`                                                  | `getConfluenceSpaces`                |
| Comments      | `comments <pageId>` (list) / `comment <pageId> "text" [--body-file f]` (add footer)  | `getConfluencePageFooterComments` / `createConfluenceFooterComment` |
| Attachments   | `attachments <pageId>` (list) / `attach <pageId> file...` (upload, v1) / `download <pageId> [id] [--all] [--out dir]` | (none) |

The verb↔MCP-method rows above mirror `_CONFLUENCE_VERB_METHOD_MAP` in
`block-backend-tier.sh` — keep them in sync.

## Mutation breadcrumbs (HIMMEL-618)

Every ticket-workflow mutating verb (`transition`, `comment`, `create`, `move`,
`edit`, `assign`, `worklog`, `link`, `sprint`) writes a breadcrumb file under
`~/.claude/jira-breadcrumbs/` immediately after its request **resolves** — not
gated on the command's exit code, so a mutation that landed before a later
non-fatal failure (e.g. an attachment upload) still leaves a breadcrumb.

The file is keyed by **repo + branch**, not session id: the standalone CLI
process (spawned via the Bash tool) never receives the Claude `session_id`, so
the writer (`scripts/jira/src/breadcrumb.ts`) and the SessionEnd hook reader
(`scripts/lib/jira-breadcrumb.sh` ← `scripts/hooks/jira-nudge-on-end.sh`) agree
on a `repo-key` (basename of `git remote get-url origin`, `.git` stripped —
stable across worktrees) and let the hook match on `epoch >= session-start`.
The path + token sanitization (`[^A-Za-z0-9._-]` → `-`) MUST stay byte-identical
between the TS writer and the bash reader. The nudge hook consumes these to
decide whether a ticket-scoped session already synced Jira (advisory, default
OFF).
