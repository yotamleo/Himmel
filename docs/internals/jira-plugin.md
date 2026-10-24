# Jira plugin ↔ MCP mapping — reference

> Extracted from `CLAUDE.md` (state-not-prompt slimming).
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
| Get         | `node scripts/jira/dist/index.js get HIMMEL-N` (default includes description body, a `Labels:` line when the issue has any, and a `Fix versions:` line when it has any; add `--short` for header-only) | `getJiraIssue`                                                   |
| List/search | `... list --jql "..."`; `... list --label <l>` filters by label (composed into the built JQL, `--jql` still wins); `... list --labels` appends each issue's labels as a trailing comma-separated column (off by default — on by default would break fixed-column consumers of the TSV output) | `searchJiraIssuesUsingJql`                                       |
| Create      | `... create --type Story --title ... --desc ... [--labels a,b] [--fix-version v1.0.0] [--affects-version v1.0.0\|current]` (project auto-loaded from `.env`; pass `--project FOO` only to override per-call; `--labels` comma-separated; `--fix-version` validated against the project's versions — a Bug without it needs a placement: `--backlog`, `--gate critical\|regression` or `--priority Highest` (see "Bug placement" below); `--affects-version` is validated the same way and `current` resolves to the earliest unreleased version at call time) | `createJiraIssue`                                                |
| Edit        | `... edit HIMMEL-N --title ... --desc ... [--labels a,b]` (`--labels` is FULL-REPLACE: the set becomes the complete label list — no MCP `editJiraIssue` fallback needed for labels) or `... edit HIMMEL-N --add-labels a,b` (APPENDS without reading/replacing the existing set, via Jira's atomic `update` operation; mutually exclusive with `--labels`); `... edit HIMMEL-N --fix-version v1.0.0` (FULL-REPLACE) or `--add-fix-version v1.0.0` (APPENDS via the same atomic `update` operation; mutually exclusive with `--fix-version`) — both validated against the project's versions, failing non-zero and naming the project on an unknown version name; into a frozen version either needs `--gate critical\|regression\|must:<ref>\|receipt` (or `--console-override "<reason>"`) and appends the admissions ledger row (see Intake gate); `... edit HIMMEL-N --affects-version v1.0.0\|current` sets affectsVersion (FULL-REPLACE, same validation, read back after the PUT) | `editJiraIssue`                                                  |
| Comment     | `... comment HIMMEL-N "text"` / `... comment HIMMEL-N --edit <commentId> "text"` (replace a comment's body, PUT) | `addCommentToJiraIssue` / `addOrEditJiraIssueComment`            |
| Comments    | `... comments HIMMEL-N [--last N]` (read path; author/created/body oldest-first, ADF rendered to plain text) | (none — MCP has no comment read) |
| Attach      | `... attach HIMMEL-N file.png`                                              | (none — MCP has no attach)                                       |
| Transition  | `... transition HIMMEL-N Done`                                              | `getTransitionsForJiraIssue` + `transitionJiraIssue` (two calls) |
| Transitions | `... transitions HIMMEL-N` (id<TAB>name per available transition) | `getTransitionsForJiraIssue`                                  |
| Move        | `... move HIMMEL-N --to-project LUNA [--type Story] [--dry-run]` (close source + create target + copy comments) | (none — Jira Cloud REST API has no direct project-change endpoint) |
| Projects    | `... projects` / `... project-create ...`                                   | `getVisibleJiraProjects` / no equivalent for create              |
| Link        | `... link HIMMEL-A HIMMEL-B` (Relates, the default; case-insensitive `--type`, validated against the live type list). Blocks is explicit: `link A --blocks B` (A blocks B) and `link A --blocked-by B` (A is blocked by B); the bare two-key form is refused for Blocks, because the first key is the blocker (`link A B --type Blocks` stores "A blocks B") and callers often expect the reverse; the explicit flags state the direction. The output prints the stored relation (`Linked: A blocks B`), matching `links` and the Jira UI (HIMMEL-6577). `scripts/jira/audit-blocks-links.mjs` is a read-only TSV audit of open-ticket Blocks links with proposed flips | `createIssueLink` (+ `getIssueLinkTypes` for the type list) |
| Links       | `... links HIMMEL-N` (lists id, type, canonical `inward=` / `outward=` keys, and the relation from the queried issue) | `getJiraIssue` with the `issuelinks` field |
| Unlink      | `... unlink HIMMEL-INWARD HIMMEL-OUTWARD [--type Relates]` (resolves the REST id from the directed pair and refuses ambiguous matches) | (none — use `DELETE /rest/api/3/issueLink/{id}`) |
| Assign      | `... assign HIMMEL-N <email\|accountId>` (`-`/`unassigned` clears, `auto` = default assignee; email → accountId via `/user/search`) | `editJiraIssue` (assignee field) |
| Attachments | `... attachments HIMMEL-N` (list) / `... download HIMMEL-N [id] [--all] [--out dir]` | (none — MCP has no attachment download) |
| Worklog     | `... worklog add HIMMEL-N --time 1h [--comment ...]` / `... worklog list HIMMEL-N` | `addWorklogToJiraIssue` (no list) |
| Watchers    | `... watch HIMMEL-N [user]` / `... unwatch HIMMEL-N [user]` / `... watchers HIMMEL-N` | (none) |
| Sprint      | `... boards` / `... sprints [--board N]` / `... sprint HIMMEL-N <sprintId\|backlog>` (Agile API `/rest/agile/1.0`; `JIRA_BOARD_ID` default) | (none — MCP has no Agile-board ops) |
| Sector      | `... edit HIMMEL-N --sector "Ship loop"` (single-select custom field named by `jira.sectorField` in `~/.himmel/config.json`, opt-in via `... sector setup`; case-insensitive against the live option list, unknown option refused, value read back after the PUT) / `... edit-batch --file <tsv>` (columns `key`, `sector`; prints one `key<TAB>sector<TAB>set\|unchanged\|failed[<TAB>reason]` row per input row; a failed row never aborts, exit 1 if any failed; re-running is idempotent). `get` prints a `Sector:` line. | (none) |
| Versions    | `... versions` / `... version-create <name> [--start-date YYYY-MM-DD] [--release-date YYYY-MM-DD] [--released] [--description ...]` / `... version-edit <name> [--name <new>] [--start-date] [--release-date] [--description]` (`--name` renames in place; `version-create` and `--name` refuse a non-semver name - only `vX.Y.Z` or `vX.Y.Z-pre.N`) / `... version-release <name> [--date YYYY-MM-DD]` / `... version-archive <name> [--unarchive] [--force]` (REST `PUT /version/{id}` `archived`, refused while `relatedIssueCounts` shows issues unless `--force`; MCP twin `manageJiraProjectVersion` action=archive) / `... version-move <name> --after <name>\|--position First\|Last` (REST `POST /version/{id}/move`) / `... affects-version HIMMEL-N --add\|--remove <name\|current>` (the `update.versions` add/remove verbs, same validation; `current` = earliest unreleased version) / `... fix-version HIMMEL-N --add\|--remove <name>` (REST `/project/{key}/versions`, `/version`, and the issue `update.fixVersions` add/remove verbs, so other versions on the ticket are untouched) | `manageJiraProjectVersion` action=archive for `version-archive`; no other version op has an MCP twin |
| Freeze      | `... version-freeze <name> [--at YYYY-MM-DD] [--keys-file <path>] [--dry-run]` (writes `frozen: <date>` and `frozen-keys: A,B` into the version description and labels the set `scope-<name>`; the set is the version's open tickets, or the `--keys-file` list (one key per line, `#` comments) for a freeze that happened before the tool; refused on an already-frozen version) / `... version-ready <name> [--console-override <row-id> "<reason>"]...` (prints the P1 tag criterion as tab-separated `PASS`/`FAIL` rows: `frozen-set` every frozen key Done or deferred from this version (label `deferred` plus a deferral ledger row for it) and every key in the version but not in the frozen list either carrying an admission ledger row or Done (a Done key with no row is a Done-fold; any other without a row is a leak and fails the row), `no-blocker-bug` no open Highest-priority or `critical`/`blocker`/`v1-blocker`-labelled Bug in the version, `main-ci` every CI run green at main's head, `done-fold` every Done frozen key still carries the version; then `frozen-open`, `admitted-after-freeze` and `done-folded` counts, one `admitted<TAB><key><TAB><reason>[<TAB><by>]` line per ruled admission, and every ledger override/deferral; informational, exit 0, it refuses nothing, gates on no count and prints no roll date) / `... version-admit <KEY> --version <name> --reason "<why>" --by <rm-session>` (records a release-manager admission as an `rm-admit` ledger row) / `... version-defer <KEY> --version <name> --reason "<why>"` (labels `deferred` and records the deferral). `--console-override` is per row and repeatable, each overridden row gets its own ledger row; it and `version-admit` and `version-defer` need `HIMMEL_CONSOLE=1` (the same marker as `create --console-override`) and a non-blank reason; every row lands in the admissions ledger (`$HANDOVER_DIR/admissions-ledger.jsonl`, `HIMMEL_ADMISSIONS_LEDGER` overrides) <!-- old-term-ok: the console role and the --console-override flag are the operator-approved names --> | (none) |
| Mirror      | `... mirror [--full] [--status] [--qmd] [--root DIR]` (read-only Jira → one `<KEY>.md` per issue under `~/.himmel/state/jira-mirror/<PROJECT>/`, first run full backfill, later runs `updated >=` cursor; `--qmd` registers/re-embeds the `jira-himmel` qmd collection, non-fatal; `--status` prints mirror age, no network; a failed or short key listing deletes nothing) | (none) |
| Roadmap     | `... roadmap fields [--json]` / `... roadmap set HIMMEL-N [--readiness 0-4] [--theme T] [--goals G1,G3] [--impact 1-5] [--alignment N] [--effort XS\|S\|M\|L\|XL [--guard]] [--audit-date D] [--audit-evidence URL] [--close-candidate yes\|no] [--no-roi]` / `... roadmap get HIMMEL-N` / `... roadmap export --out F.json` / `... roadmap sync-sprints [--board N] [--dry-run]` (fields resolved by name, ROI = impact × alignment × confidence ÷ effort recomputed after every set; `sync-sprints` gives each dated unreleased fixVersion a same-named sprint carrying its dates and moves its open issues in — an issue on several dated versions goes to the earliest-releasing one — and `--dry-run` exits 1 on drift) | (none) |
| Rank        | `... rank HIMMEL-N --before\|--after HIMMEL-M` / `... rank --file order.txt` (Agile `PUT /issue/rank`, the file ranks top-down in chunks of 50) | (none) |
| Resolution  | `... resolution HIMMEL-N` (re-runs the current status's self-transition so the workflow post-function sets or clears the resolution — resolution is not on the edit screen) | (none) |
| Release     | `... release state <R> [--json]` (exit 3 when not OK) / `... release request <R> --verb INTAKE\|REVERSION\|DISCHARGE --key K --to <v\|backlog> --why ...` / `... release claim <R>` / `... release rule <R> --req Q --outcome O --op <kind> --sector S --ground G --reason-file F [--supersedes ids] [--authority operator --ref O-id]` / `... release apply <R> <R-id>` (fixVersions write, readback, receipt comment; idempotent) / `... release lease acquire\|release <R>` / `... release operator declare\|freeze\|decision\|takeover <R> ...` (refused inside a spawned worker). Signed, hash-chained state under `$HANDOVER_DIR/<user>/<repo>/release/<R>/` (HIMMEL-6796); the release manager's verbs: `himmel-ops:release-manager` | MCP tool `release` (`sub` = state, request, claim, rule, apply, lease-acquire, lease-release; the operator verbs are CLI-only) |

**Use MCP only when the plugin lacks the operation** (custom-field
discovery, account-ID lookup via `lookupJiraAccountId`). Confluence now has
a sibling CLI (see below) — prefer it over the Confluence MCP tools. The MCP block in
`block-backend-tier.sh` derives its blocked-set by introspecting
the CLI's verbs (`node …/index.js --list-commands`) against a small
verb→MCP-method map — an MCP method is refused iff its mapped
verb is a real CLI verb, so the set tracks this table automatically instead
of drifting from a hand-maintained literal. E.g. `getTransitionsForJiraIssue`
is refused because the `transition` verb exists; dogfood it.

**JIRA_PROJECT_KEY is required.** The plugin no longer
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

## Optional deterministic ticket-body normalization

Before `create --desc-file`, ticket-standard offers a local punctuation pass,
not a model rewrite. No model or plugin is invoked; a skipped pass never blocks
filing. Keep `draft.md`, generate a separate candidate, and only check that
candidate if normalization exits successfully:

```bash
python3 -I marketplace/plugins/himmel-ops/scripts/humanizer-facts.py --normalize draft.md normalized.md
bash marketplace/plugins/himmel-ops/scripts/ticket-standard-check.sh --type Task --sector "Ship loop" --draft draft.md --rewrite normalized.md
```

Leading bold/code labels get a colon instead of a spaced em/en dash; other
spaced dashes become commas and curly quotes become straight. Banned words are
advisory warnings only, never substitutions. No claims or connectives are added.
If a protected literal would change, normalization refuses and writes nothing;
use the original. The checker also falls back to `draft.md` when a candidate is
unreadable or unsafe, or Python is unavailable. Only file `normalized.md` after
normalization succeeds, `humanizer: accepted` and `ok:`; otherwise file the passing
original. The original is never modified. Literal checks preserve ticket keys,
numbers, file names, inline code, fenced/indented code and bare command lines.
Mark other commands as code. Changed counts, including additions, are refused,
but meaning still needs diff review. Record skipped/kept/dropped passages in the
filing note, not in the ticket's plain block.

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

**Ticket shape: a plain block, a Plan, a DoD, then Agent detail.** Every
ticket body carries six headed sections: three short ones anyone can read
without knowing the code, a Plan, a DoD, and one section for the agent doing
the work (the lint checks that all six are present and non-empty, and that Plan
and DoD each hold a real line, not their order):

```markdown
## Impact
<who notices, and what they see today — plain words, no file paths>

## What
<what we change, in one or two sentences>

## Why
<why it is worth doing now>

## Plan
1. <one to five bounded steps, each naming the surface it touches>

## DoD
- <one to five checkable results: a test, a command and its output, a doc section, a Jira state>

## Agent detail
<files, contract, suites>
```

- **Impact / What / Why:** the plain block.
- **Plan:** one to five bounded steps, each naming the surface it touches. A
  spike's plan starts with "Investigate", and its DoD is a written finding.
- **DoD:** one to five checkable results, each observable: a test that fails
  before and passes after, a command and its expected output, a doc section that
  exists, or a Jira state. "Works", "fixed" or "better" alone does not count.
- **Agent detail:** files, contract, suites.

A follow-up ticket (from a review, a deferral or a worker) names its source PR or
ticket in Why, and its DoD must differ from the parent's.

`create` enforces it in code (CLI and the MCP `create` tool share
`scripts/jira/src/plain-block.ts`): a body missing any of the six headings, or
with one empty, is refused with the missing names and this template. Plan and
DoD each also need at least one bullet or numbered line that is not template
placeholder text (a line whose whole content is an angle-bracket hint counts as
placeholder), so the printed skeleton never files as is. Headings
match by their words (`## Impact`, or an ADF heading node for `--adf-file`),
and a heading inside a code fence does not count. Explicit exemptions: an
`Epic` and a `Subtask` only **warn** (the CLI on stderr; the MCP tool files
them without a message) and are filed anyway; a
body-less create of any other type is refused like a body without the block.
`edit` is not gated, so an old ticket can be amended later.

Writing rules, adopted from the roadmap pipeline's plain-language ruling
(frame §18, luna vault): write for someone who has never read the
code; prefer "the merge check can pass even when a test never ran" over a
script-and-exit-code phrasing; no rubric terms or internal jargon without a
gloss; say plainly when a ticket is internal-only ("Internal: ..."); keep the
ticket's own facts and invent no impact. The roadmap tracker reads the
`Impact` section as a card's impact line (`tracker.py`), falling back to the
older stage-1 explain sidecar when a ticket has none.

**Ticket title: system tickets name their sector, user-facing tickets are a plain sentence.**
A title is one of two kinds:

- **System:** `<Sector>: <the result>`, for example `Ship loop: merge waits for the
  signed GO`. The sector is one of the Sector field's values (Fleet orchestration,
  Ship loop, Safety & enforcement, Cost & efficiency, Visibility, Quality & proof,
  Deployment, Knowledge & steering, Planning & tracking).
- **User-facing:** a short plain sentence of what the user can now do, for example
  `See which tickets are system work`.

Neither kind carries a commit prefix (`feat(x):`), a ticket id, or an internal name
(a `--flag`, a `field_name`, a file path, backticked code), and a title stays at most
90 characters. A system title needs a result after the sector, and a capitalised
`Name:` opening that is not one of the Sector options is flagged. `create` checks this for a Task, Story or Bug and **warns** with the
template on stderr (the MCP tool appends the warning to its reply); it never
refuses, and an Epic or Subtask is not checked. The check is `titleVerdict` in
`scripts/jira/src/plain-block.ts`. Existing titles are retitled in approved
batches with `edit --title`, never in bulk without the operator's approval.

**`create` has no `--priority`; `edit` does.** `create --help` does not list
a priority flag — file the ticket, then `node <repo-root>/scripts/jira/dist/index.js
edit <key> --priority High` to set the real field. A priority stated only in
the body text leaves the field empty and the ticket unsorted in any priority
view.

**A bare literal `JIRA_PROJECT_KEY=<KEY>` env-prefix is the ONE approvable
non-locale prefix.** `JIRA_PROJECT_KEY=HIMMEL node <repo-root>/scripts/jira/dist/index.js
comment HIMMEL-N --comment-file f.md` auto-approves exactly like the bare form;
`--project <KEY>` remains the plain way to target another project. The innocuous
locale/timezone prefixes (`LANG`, `LANGUAGE`, `LC_*`, `TZ`) stay approvable beside
it. Any OTHER
`VAR=value` prefix (or a quoted / `$VAR` / `$(…)` key) makes the permission
matcher bail, and `block-jira-compound-write` refuses it, naming the prefix.

**A worktree lacks `dist/` — invoke by absolute path from the primary
checkout.** `scripts/jira/dist/index.js` is an untracked build artifact that
only exists in the primary checkout. Running the CLI relative from a
worktree fails `MODULE_NOT_FOUND` and can silently fail a `create`. Always
invoke `node <repo-root>/scripts/jira/dist/index.js <op>` by absolute path,
never the global `jira` shim.

## Versions mirror the GitHub release tags

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

**Ticket home (HIMMEL-6223, HIMMEL-6277).** `create` refuses a Task, Story or
Bug with neither `--parent <epic>` nor `--labels standalone`, and, when Sector is
configured, with no `--sector` (matched case-insensitively against the field's
live option list); the refusal names the missing field, the valid options and
the opt-out. An Epic or Subtask only warns. The MCP `create` takes the same
`sector` argument. The check is `homeVerdict` in `scripts/jira/src/plain-block.ts`.
Rollout: the rule goes live on a station when `himmel-update` rebuilds
`scripts/jira/dist`; until then a stale `dist/` still files without a Sector.

**Sector is opt-in (HIMMEL-6277).** The field is a custom Jira field, so its id
is config, not code: `jira.sectorField` in `~/.himmel/config.json` (the
`JIRA_SECTOR_FIELD` env var overrides it). Absent or `none` means no
Sector check and no Sector field sent (a stray `--sector` on `create` warns and
is ignored; `edit --sector` and `edit-batch` refuse). Set, the options come live
from the field's contexts (`GET /field/<id>/context`, then `.../option`; cached
five minutes), not from a list in code. `jira sector setup [--dry-run] [--yes]
[--sectors "A,B,C"]` explains what a sector is, proposes a default nine, creates
the single-select field with its options, adds it to the default screen and
prints the `jira.sectorField` config.json snippet (it never writes the file;
config.json writes are operator-only); `--opt-out` prints the `none` snippet. With no
Sector configured a release ruling carries `sector=none` and applies (HIMMEL-7417); configured, a ruling
without one still refuses. Code:
`scripts/jira/src/commands/sector.ts` (config + options) and `sector-setup.ts`.

**Bug placement (HIMMEL-6776).** `create --type Bug` without `--fix-version` is
placed at filing, never defaulted silently. `--backlog` files it with the
`backlog` label and no fixVersion. `--priority Highest` or a valid `--gate`
(see the intake gate below) sets the earliest unreleased, unarchived version from the
project's versions and prints one stderr line saying so (no readable unreleased
version: filed with no fixVersion and a warning). With none of those the create
is refused, naming both choices and the `--sector` given. An explicit
`--fix-version` is untouched, as are other types. `create --priority <name>`
sets the Jira priority. This reverses the PR #1237 earliest-unreleased default
(decision 100, 2026-10-20); there is still no date cutoff (the v1 bug freeze was
removed by operator ruling 2026-10-05) and the release gate is the `v1-blocker`
label and priority.

**Override and admissions ledger.** `create --fix-version <v>
--console-override "<reason>"` is honoured only with `HIMMEL_CONSOLE=1` set, a
non-empty reason and a ledger that can take an append (`HANDOVER_DIR`, or
`HIMMEL_ADMISSIONS_LEDGER`); any miss, including an unwritable ledger, refuses
before the ticket is filed. After
the create it appends one JSON row `{ts, version, key, gate|kind, actor, reason}`
(`kind: "override"`) to `$HANDOVER_DIR/admissions-ledger.jsonl`. The marker is
spoofable by any same-uid caller (ponytail, upgrade path HIMMEL-6796). Code:
`scripts/jira/src/commands/admissions-ledger.ts` (`appendAdmission(row)`,
`readAdmissions(version?)` and the preflight `assertAdmissionsWritable()`, the
whole API).

**Intake gate for a frozen version (HIMMEL-6775).** A version whose description
has a line `frozen: <date>` takes no new ticket without a reason. `create` checks
the version the ticket will land in, whether from `--fix-version`, a Highest or
`--gate` Bug's default, or a `--residual-of` escape or hardening route, and
refuses unless `--gate critical|regression|must:<decision-ref>|receipt` is given
(`must:` needs a non-empty ref). The refusal comes before the ticket is filed, and
a gated filing also needs a ledger that can take an append. After the create it
appends the row `{ts, version, key, gate, actor}` to the admissions ledger.
`--console-override "<reason>"` (rules above) admits past the gate and writes its
override row instead. A version without the `frozen:` line behaves as before and
writes no row; `--backlog` files a Bug with no version, so it needs no gate. The
gate reason is recorded, not verified (ponytail, upgrade path HIMMEL-6796).
`edit --fix-version` and `edit --add-fix-version` run the same check with the same
`--gate` and `--console-override` flags: the refusal lands before the PUT, and the
gate or override row is appended after the edit reads back (HIMMEL-6918).
`jira fix-version --add` is not gated yet (HIMMEL-6828). Code:
`scripts/jira/src/commands/intake-gate.ts` (`frozenDate`, `assertIntakeGate`,
`checkIntakeGate`, `checkConsoleOverride`).

**Who sets `HIMMEL_CONSOLE=1`.** `headed-arm.sh --role console` exports it, so `console.sh` and every arm-resume re-arm carry it; the leg launcher scrubs it from a leg's environment. The console admits a fix to a broken console or operator flow itself, without the release manager. When the release manager rules an INTAKE `ADMIT`, `release apply` appends the `rm-admit` ledger row (`by` is the lease owner session, once per key and version), so the board counts it like a console admission. <!-- old-term-ok: the console role and --console-override flag are the operator-approved names -->

## Confluence CLI

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

**Auth:** a *scoped* Jira API token returns `401` against
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

## Mutation breadcrumbs

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
decide whether a ticket-scoped session already synced Jira (warn-only, default
OFF).
