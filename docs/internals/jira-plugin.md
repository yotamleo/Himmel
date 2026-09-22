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
| Comments    | `... comments HIMMEL-N [--last N]` (HIMMEL-3162 — read path; author/created/body oldest-first, ADF rendered to plain text) | (none — MCP has no comment read) |
| Attach      | `... attach HIMMEL-N file.png`                                              | (none — MCP has no attach)                                       |
| Transition  | `... transition HIMMEL-N Done`                                              | `getTransitionsForJiraIssue` + `transitionJiraIssue` (two calls) |
| Transitions | `... transitions HIMMEL-N` (HIMMEL-149 — id<TAB>name per available transition) | `getTransitionsForJiraIssue`                                  |
| Move        | `... move HIMMEL-N --to-project LUNA [--type Story] [--dry-run]` (HIMMEL-197 — close source + create target + copy comments) | (none — Jira Cloud REST API has no direct project-change endpoint) |
| Projects    | `... projects` / `... project-create ...`                                   | `getVisibleJiraProjects` / no equivalent for create              |
| Link        | `... link HIMMEL-A HIMMEL-B --type Relates` (HIMMEL-210; case-insensitive type, validated against the live type list) | `createIssueLink` (+ `getIssueLinkTypes` for the type list) |
| Links       | `... links HIMMEL-N` (HIMMEL-1731; lists id, type, canonical `inward=` / `outward=` keys, and the relation from the queried issue) | `getJiraIssue` with the `issuelinks` field |
| Unlink      | `... unlink HIMMEL-INWARD HIMMEL-OUTWARD [--type Relates]` (HIMMEL-1731; resolves the REST id from the directed pair and refuses ambiguous matches) | (none — use `DELETE /rest/api/3/issueLink/{id}`) |
| Assign      | `... assign HIMMEL-N <email\|accountId>` (`-`/`unassigned` clears, `auto` = default assignee; email → accountId via `/user/search`) (HIMMEL-437) | `editJiraIssue` (assignee field) |
| Attachments | `... attachments HIMMEL-N` (list) / `... download HIMMEL-N [id] [--all] [--out dir]` (HIMMEL-437) | (none — MCP has no attachment download) |
| Worklog     | `... worklog add HIMMEL-N --time 1h [--comment ...]` / `... worklog list HIMMEL-N` (HIMMEL-437) | `addWorklogToJiraIssue` (no list) |
| Watchers    | `... watch HIMMEL-N [user]` / `... unwatch HIMMEL-N [user]` / `... watchers HIMMEL-N` (HIMMEL-437) | (none) |
| Sprint      | `... boards` / `... sprints [--board N]` / `... sprint HIMMEL-N <sprintId\|backlog>` (Agile API `/rest/agile/1.0`; `JIRA_BOARD_ID` default) (HIMMEL-437) | (none — MCP has no Agile-board ops) |
| Versions    | `... versions` / `... version-create <name> [--release-date YYYY-MM-DD] [--released] [--description ...]` / `... version-release <name> [--date YYYY-MM-DD]` / `... fix-version HIMMEL-N --add\|--remove <name>` (HIMMEL-3429; REST `/project/{key}/versions`, `/version`, and the issue `update.fixVersions` add/remove verbs, so other versions on the ticket are untouched) | (none — MCP has no version ops) |

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

## Gotchas

**`transition <key> <numeric-id>` is a vacuous success.** `transitions <key>`
lists numeric IDs for reading, not for passing back to `transition` — `transition`
takes the status **name** as its positional arg (`transition HIMMEL-N Done`).
Passing the numeric ID back can print a plausible-looking path (e.g.
`- In Progress` / `- Done`) and still leave the ticket in its original status.
Always pass the NAME, and always re-`get` the ticket afterward to verify the
status actually changed — the printed path is not the artifact.

**`--desc-file`/`--comment-file` bodies are markdown, and Jira wiki markup
corrupts them.** These flags are parsed as markdown → ADF. Writing Jira wiki
markup (`h2.`, `||header||`, `{code}`, `{{mono}}`) does not render — the
tokens come through literally and tables collapse to one unreadable line.
The dangerous part: **markdown italics eat underscores** — `HIMMEL_REPO`
renders as `HIMMELREPO`, `himmel_dir` as `himmeldir`. A table can survive
looking plausible while naming variables that don't exist. Use `##`,
markdown tables, fenced code blocks, and backtick every identifier; then
re-`get` and check the underscores explicitly — this is an artifact check,
not a formatting preference. `edit --desc-file` repairs a corrupted body in
place.

**`create` has no `--priority`; `edit` does.** `create --help` does not list
a priority flag — file the ticket, then `node <repo-root>/scripts/jira/dist/index.js
edit <key> --priority High` to set the real field. A priority stated only in
the body text leaves the field empty and the ticket unsorted in any priority
view.

**A literal `JIRA_PROJECT_KEY=<key>` env-prefix on a CLI call is refused as a
SHAPE, not resolved.** For a cross-project op (filing into a different
project from the repo root), use `--project <KEY>` — never a `VAR=value`
prefix on the command. The permission matcher bails on the env-prefix shape
and `block-jira-compound-write` refuses it outright; this applies to every
write verb, including explicit-key verbs (`comment <KEY-N>`, `transition
<KEY-N>`) which need no project arg at all.

**A worktree lacks `dist/` — invoke by absolute path from the primary
checkout.** `scripts/jira/dist/index.js` is an untracked build artifact that
only exists in the primary checkout. Running the CLI relative from a
worktree fails `MODULE_NOT_FOUND` and can silently fail a `create`. Always
invoke `node <repo-root>/scripts/jira/dist/index.js <op>` by absolute path,
never the global `jira` shim.

## Versions mirror the GitHub release tags (HIMMEL-3429)

Jira's version field (`fixVersions`, multi-valued) mirrors the GitHub release
tags: one Jira version per published tag, same name (`v0.3.0-pre.6`), released,
dated with the release date, a pre-release noted in the description. On top of
that, **`v1.0.0` = Linux GA** is a hand-made, unreleased version whose scope is
the reconciled v1 milestone ticket list — *in addition to* any tag version a
ticket carries.

**Adding a release's version (part of cutting a release).** After the tag and
its GitHub release are published, from the primary checkout (`dist/` built):

```bash
node scripts/jira/sync-versions.mjs --dry-run --project HIMMEL   # report only
node scripts/jira/sync-versions.mjs --apply --project HIMMEL     # write
```

The sync is idempotent: it creates the missing versions, then for every merged
PR it takes the **first** tag containing the PR's merge commit and adds that
version to every `[HIMMEL-N]` key in the PR title (a PR in no tag is left
alone). It needs `gh`, the tags in the local clone (`git fetch --tags`) and a
built `dist/`; it prints counts plus any key a PR cites that Jira lacks. Only
tag versions (and `v1.0.0` under `--v1-keys`) are ever created or released.

**v1.0.0 scope.** `--v1-keys <file>` (one key per line, `#` comments allowed)
creates `v1.0.0` if missing and adds it to those tickets. It is add-only: a
ticket dropped from the list keeps `v1.0.0` until you remove it by hand. The
list is a file, not code, because the v1 definition has moved before. New
v1-scoped work outside a sync run, or dropping a ticket from v1:
`node <repo-root>/scripts/jira/dist/index.js fix-version HIMMEL-N --add v1.0.0`
(`--remove` to drop it).

The sync reads reachability from the tags of the clone it runs in, so it must
run from a clone of the repo whose releases it lists (`--repo` must match), and
`--apply` refuses when a published tag is missing locally (`git fetch --tags`).

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
`edit`, `assign`, `worklog`, `link`, `unlink`, `sprint`, `fix-version`) writes a breadcrumb file under
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
