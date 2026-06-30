---
name: handover
description: Use when the user says "new epic", "new task", "new standalone", "end session", "update status", "handover", "handover-resume #N", "handover bug", "log a bug", "track a bug", "fix didn't work", "handover bugs", "bug dashboard", "handover lessons", "lessons sweep", "handover init", "handover register", "handover repos", or asks to create/track work items in the handover system. Also use when wrapping up a session or resuming tracked work. Triggers on phrases like "wrap up", "session done", "start epic", "add task to #N", "handover-resume", "resume session", "register handover for <repo>".
---

# Handover System

Tracks epics, tasks, and standalones across sessions. Multi-repo capable: state lives per registered repo under `<repo-root>/handovers/<user>/`, optionally bucketed by source repo under `<repo-root>/handovers/<user>/<bucket>/` (HIMMEL-129 layout — see Bucket Resolution).

## Target Repo Resolution

Every command resolves a **target repo** before reading or writing state. Order:

1. **CWD match (primary).** Run `git -C <cwd> rev-parse --path-format=absolute --git-common-dir`. Take its parent directory (handles worktrees AND regular checkouts — `--path-format=absolute` returns an absolute path either way, so the parent is always the main repo root). Canonicalise (lowercase drive on Windows, forward slashes, `$HOME` expansion). Compare against canonical `path` of each entry in `~/.claude/handover/registry.json`. Exact match wins.
2. **Conversation alias (fallback).** Only if step 1 produces no match. Scan recent user turns for any registered alias or keyword (case-insensitive substring). Unambiguous hit → use it.
3. **Ambiguous or none → prompt** via `AskUserQuestion`. No session cache — always prompt when ambiguous, every invocation. (If `AskUserQuestion` is unavailable — non-Claude harness, e.g. Codex — ask the same question as plain text and route on the typed answer; never silently pick a repo.)

Once resolved, `<repo-root>` = registry path, `<state-root>` = `<repo-root>/handovers/<user>/` (user from registry).

Read-only commands (`handover-resume`, `repos list`, `update-status` regen) skip step 3 if the user clearly intends a specific repo from context.

Full algorithm + canonicalisation rules: `references/routing.md` (load only on ambiguity or first invocation in a new session).

## Bucket Resolution (HIMMEL-129)

Some registered repos — the **state-root host** an operator chose at `/handover-setup` (e.g. a repo named `<state-repo>`) — split `<state-root>` into per-source-repo buckets to keep work from multiple code repos disambiguated:

```
<state-root>/
  himmel/{epics,standalones}/
  luna/{epics,standalones}/
  luna_brain/{epics,standalones}/
  cross/{epics,standalones}/      # cross-repo work; no Jira prefix
  <extra>/{epics,standalones}/    # e.g. luna-medic/ — extra source bucket (HIMMEL-307); explicit-only, no Jira-prefix route
```

A bucket layer is active when **any recognized source bucket** dir exists directly under `<state-root>`. The **recognized source-bucket set** is the four built-ins `himmel/`, `luna/`, `luna_brain/`, `cross/` **plus** any names listed in the state-root host repo's `source_buckets_extra` registry field (HIMMEL-307). When `source_buckets_extra` is absent or empty, the recognized set is exactly the four built-ins, so behaviour is byte-identical to the pre-HIMMEL-307 4-set. Wherever this skill says "active bucket" / "every `<state-root>/<bucket>/`" (ID derivation, `update-status`, roadmap, `handover-resume`, the No-ID picker), `<bucket>` ranges over the **recognized** set — extra buckets are walked automatically. In an active layer, every read/write resolves `<bucket>` first:

1. **Ticket-prefix rule (primary).** If the item carries a Jira key, map prefix → bucket via the registry's `bucket_name` field (HIMMEL-147). Default mappings carry over from HIMMEL-129: `HIMMEL-*` → `himmel/`, `LUNA-*` → `luna/`, `LUNA-BRAIN-*` → `luna_brain/`. No-prefix or unmapped prefix → `cross/`. Operators with forked repos override per-entry by setting `bucket_name` in registry.json. The prefix rule only ever resolves to one of the **four built-in** buckets — it never auto-routes to an extra bucket (see rule 3).
2. **No Jira key (offline-fallback `#N`).** Use the source-repo registry `bucket_name` (HIMMEL-147; defaults to slugified `basename(path)`) where the slash command was invoked. If the source repo is the state-root host itself (no obvious bucket), prompt via `AskUserQuestion` listing the active buckets — which includes any recognized extra buckets.
3. **Extra source buckets are explicit-only (HIMMEL-307).** Names in `source_buckets_extra` get **no** Jira-prefix auto-route — an item lands in one only by an explicit operator choice: the source-bucket step in `new-epic`/`new-standalone` (offered only when extra buckets exist), or an explicit `/handover bucket <id> <extra>` move. Rationale: an extra bucket like `luna-medic` carries `LUNA-*` tickets that would otherwise collide with `luna/` under the prefix rule, so it must never silently capture prefix-routed work. Once an item lives in an extra bucket, all scans/regens walk it like any built-in bucket (see the recognized-set note above).
4. **Inactive bucket layer.** When no recognized source-bucket dir exists under `<state-root>`, the resolver walks the flat layout (`<state-root>/{epics,standalones}/`) directly — backwards compatible with pre-HIMMEL-129 state roots.

Top-level files (`status.md`, `roadmap.md`, `backlog.md`, `tech-debt.md`, `counter.md`, `sync.log`, `next-session-resume.md`, `luna-wave-resume.md`, `overnight-summary-*.md`, `_templates/`) remain at `<state-root>/` root regardless of bucket layer. They're cross-bucket index files.

### Internal specs (design / plan / decision) — HIMMEL-409

Each source bucket also holds a `specs/<type>/` subtree — the single home for **internal, non-customer-facing** design artifacts that aren't handover items: design docs, implementation plans, decision records. Path: `<state-root>/<bucket>/specs/<type>/` (e.g. `…/himmel/specs/design/`, `…/himmel/specs/plan/`).

These live in the **state repo**, never in the code repo's `docs/` (which is for operator-facing reference + any OSS-public docs). This rule travels with the handover skill, so it holds while working in **any** registered repo — not only where that repo's `CLAUDE.md` is loaded. The `<type>` set is **operator-controlled and extensible**: add a subfolder (`decision/`, `research/`, `adr/`, …) as needed; the two defaults are `design/` and `plan/`. `specs/` is NOT scanned by `update-status` / roadmap (these are reference artifacts, not tracked items).

## Registry

`~/.claude/handover/registry.json` — single JSON file, atomic writes (tmp+rename on same volume).

```json
{
  "repos": {
    "<name>": {
      "path": "<canonical abs path to repo root>",
      "user": "<user slug>",
      "aliases": ["..."],
      "keywords": ["..."],
      "branch_prefix": "handover/",
      "jira_project": "HIMMEL",
      "bucket_name": "himmel"
    }
  }
}
```

**v2 additions:** each repo entry may also carry `bucket_vocab`, `buckets_custom`, `defaults: {}`, and `stale_thresholds_days: {}`. See `references/init-register.md` for the full schema and key reference. Absence of any v2 field means "use built-in default".

**`source_buckets_extra` (HIMMEL-307):** the state-root **host** repo entry (e.g. `<state-repo>`) may carry `source_buckets_extra` — an optional array of extra source-bucket names (kebab-case) that extends the recognized source-bucket set beyond the four built-ins (see Bucket Resolution). This is a **different axis** from `buckets_custom` (which renames the time-horizon vocab) and from `bucket_name` (a per-source-repo label used by the prefix rule). Absent or empty ⇒ the four built-ins only.

### Reading and writing the registry

The registry is a single JSON file at `~/.claude/handover/registry.json`. The skill is responsible for:

- **Read:** load with the Read tool; parse JSON; coerce missing v2 fields to defaults (`bucket_vocab: "time-horizon"`, `defaults: {}`, `stale_thresholds_days: {30, 60, 90}`).
- **Write:** atomic — Read current content, mutate in memory, Write to a tmp path on the same volume, then `mv` over the original. Never partial-write.
- **Default save:** when an `AskUserQuestion` answer comes back with a "save as default" affirmation, write the corresponding `defaults.<key>` entry. Future commands check defaults first; if present, skip the prompt.
- **Default clear:** the `/handover defaults clear <key>` command removes a single key (re-enabling the prompt).

Managed by `/handover init`, `/handover register`, `/handover repos`. Do not edit by hand.

## ID Derivation

No counter file required. Derive next ID by scanning these locations under `<state-root>` (and, if the bucket layer is active, under every `<state-root>/<bucket>/`):

- `{,<bucket>/}epics/#N-*/` dirs
- `{,<bucket>/}epics/*/tasks/#N-*/` dirs
- `{,<bucket>/}standalones/#N-*/` dirs

Extract all `N` across every bucket plus the (legacy) flat root. `next_id = max(all N) + 1`. If empty: `next_id = 1`. Counter scope is `<state-root>`-wide — never per-bucket — so `#N` IDs never collide across buckets.

If `<state-root>/counter.md` exists with `Next: K` where `K > max(all N) + 1`, prefer K (preserves in-flight increments that haven't reached disk yet).

## Worktree Gate

**All mutation commands** (`new-epic`, `new-task`, `new-standalone`, `end-session`, `update-status`) must run inside a git worktree of the **target repo** — never on `main`.

Before any file write to `<state-root>`:

1. **Identify the target branch** for the item: `<branch_prefix><slug>` where `<branch_prefix>` comes from the registry entry's `branch_prefix` field (default `handover/` if unset). `branch_prefix` is the **handover-mutation** prefix — it scopes branches created by `new-epic`, `new-task`, `new-standalone`, `end-session`, and `update-status`. It is NOT the general feature-branch prefix used by `/worktree.sh` for ticket-driven development; those follow the `<type>/<slug>` convention from CLAUDE.md.
2. **Check if that branch exists and was NOT merged into main:**
   - `git -C <repo-root> branch --list <branch>` — empty → branch gone.
   - `git -C <repo-root> branch --merged main` — branch present here → was merged.
3. **Branch exists and not merged** → enter that existing worktree. Do not create a new one.
4. **Branch missing or already merged** → create a fresh worktree off latest `main`:
   - Naming: `<branch_prefix><slug>-<N>` where N increments on conflict.
5. All file writes happen inside the resolved worktree, never in `<repo-root>`'s main checkout.

`handover-resume` and `/handover repos` are read-only — no worktree gate.

## Commands

### `/handover-setup`

**First-time bootstrap (run this once per machine/operator before anything else).** Asks *where* handover state should live — inline at `<repo-root>/handovers/` (Mode A) or an external state repo (Mode B) — then persists a Mode-B choice to `<repo-root>/.env` as `HANDOVER_DIR` via `scripts/handover/set-handover-dir.sh` (idempotent), and hands off to `init` (new state) or `register` (existing state). Never assumes a specific repo name — the location is always prompted. Full runbook: the plugin's `commands/handover-setup.md`. The downstream resolver (`scripts/lib/handover-path.sh`) + the shell loader (`scripts/lib/load-dotenv.sh`) read that `HANDOVER_DIR`; `init`/`register` below assume setup already chose the location.

### `/handover init`

Bootstrap a **new** target repo (no existing state). Refuses if `<repo-root>/handovers/<user>/` contains any `.md` file (`.gitkeep` ignored).

Full spec: `references/init-register.md`.

Short flow: prompt for name, path (default = `parent(--git-common-dir)` of cwd, canonicalised), user (default = resolved via `scripts/lib/user-slug.sh`: GitHub username via `gh api user`, else slugged `git config user.name`), aliases. Create state dirs (`epics/`, `standalones/`, `_templates/`). Seed default templates from `${CLAUDE_PLUGIN_ROOT}/templates/` into `<state-root>/_templates/`. Write empty `status.md`, `backlog.md`. Register in `~/.claude/handover/registry.json` (atomic write).

- After seeding `_templates/`, generate the first `roadmap.md` and `tech-debt.md` in `<state-root>/` by copying the `_templates/roadmap.md` and `_templates/tech-debt.md` files and filling in the active bucket vocab names + empty sections.

### `/handover register`

Adopt **existing** state in a repo (templates already on disk, items already created). Idempotent — re-run is safe.

Full spec: `references/init-register.md`.

Short flow: scan `<state-root>/epics/`, `tasks/` recursively, `standalones/` for `#N` dirs. Collect all IDs. **Detect duplicates** (report; never auto-fix). Derive `Next = max + 1`. If existing `counter.md` value > derived, preserve higher value (warn). Write `counter.md`. Inject `template_version: 1` frontmatter into existing `_templates/*.md` files that lack it (one-shot). Register in registry. If templates missing entirely, seed from plugin defaults.

### `/handover repos <subcommand>`

- `list` — print registered repos as a table
- `add <name> <path>` — register an already-bootstrapped path; **refuses** if `<path>/handovers/<user>/` is unbootstrapped (tells user to run `init` or `register`)
- `remove <name>` — remove from registry; does not touch repo files
- `where <name>` — print resolved `<state-root>` and `<user>` for the named repo

### `new-epic <name>`

Creates a new epic in the target repo.

0. **Resolve target repo** (see Target Repo Resolution).
1. **Slug ambiguity check** — if `<name>` produces more than one reasonable slug (contains acronyms, mixed case, or multiple split-point candidates), apply `defaults.slug_style`:
   - `prompt-on-ambiguous` (default) → `AskUserQuestion` with 2-3 slug candidates
   - `strict-hyphen-only` → use the deterministic strict transformation; no prompt
2. **Bucket selection** — two orthogonal axes:
   - **Time-horizon bucket** (frontmatter `bucket:`) — if `defaults["new_*.bucket"]` is set, use it; else `AskUserQuestion` ("which time-horizon bucket for this new epic?") with the 4 active vocab options. Offer save-default opt-in.
   - **Source-repo bucket** (which `<state-root>/<bucket>/` dir the item lands in, HIMMEL-307; `new-epic`/`new-standalone` only — a `new-task` inherits its parent epic's source bucket) — resolve per Bucket Resolution. When the state-root host repo defines a non-empty `source_buckets_extra`, additionally offer the recognized extra buckets via `AskUserQuestion` ("which source bucket?"), defaulting to the prefix-derived bucket (dismiss ⇒ prefix default = today's behaviour). When `source_buckets_extra` is absent/empty, skip this sub-prompt entirely — the prefix rule resolves the source bucket exactly as before.
3. **Worktree gate** — create worktree off latest main:
   - If item will be Jira-keyed: branch = `<branch_prefix><JIRA-KEY>-<slug>` (key known only after step 5; rename branch after Jira create resolves)
   - If item will be `#N`: branch = `<branch_prefix><slug>`
4. **Derive `next_id`** (only used for the offline-fallback `#N` path) by scanning `<state-root>` (see ID Derivation).
5. **Jira auto-create gate** — apply `defaults["new_epic.jira_autocreate"]`:
   - `true` → run `jira create --type Epic --project <jira_project> --title "<name>" --desc "handover epic"`. Capture key on success.
   - `false` → skip Jira; use `#N`.
   - absent → `AskUserQuestion` "Create Jira Epic for this?" with save-default opt-in.
6. **Resolve dir name:**
   - Jira create SUCCESS → `epics/<JIRA-KEY>-<slug>/`
   - Jira create FAILED → `epics/#N-<slug>/` with `pending_jira_link: true`
   - Jira skipped (user opted out / no jira_project) → `epics/#N-<slug>/` with `pending_jira_link: false`
7. Create dir + `tasks/.gitkeep`.
8. Copy templates from `<state-root>/_templates/` and fill placeholders (see Template Placeholders + `references/v2-schema.md`). Frontmatter must include the v2 fields; `created` and `updated` set to `date -u +"%Y-%m-%dT%H:%M:%SZ"`.
9. Run `update-status` (regenerates `status.md` + `roadmap.md` + `tech-debt.md`).
10. Append to `sync.log` (trigger=new-epic).
11. Confirm: "Created epic <JIRA-KEY> — `<name>` in repo `<name>`" (or `#N` if offline path).

**Slug rule:** lowercase, hyphens only, max 30 chars.

### `new-task <epic-id> <name>`

Creates a task inside an existing epic. `<epic-id>` is `<JIRA-KEY>`, `#N`, or bare numeric.

**If `<epic-id>` omitted:** run the No-ID picker scoped to epics only.

0. **Resolve target repo.**
1. **Worktree gate** — enter epic's worktree (or create if missing).
2. **Slug ambiguity check** — same rule as `new-epic` step 1.
3. **Bucket selection (time-horizon axis only)** — same rule as `new-epic` step 2's *time-horizon* bucket. The **source bucket is inherited from the parent epic** (a task never lives in a different source bucket than its epic), so the source-bucket sub-prompt does NOT apply to `new-task`.
4. **Jira auto-create gate** — apply `defaults["new_task.jira_autocreate"]`:
   - `true` → run `jira create --type Task --parent <epic-jira-key> --title "<name>" --desc "handover task"`. This creates a Jira Task linked to the parent Epic via Epic Link (NOT a Sub-task).
   - `false` → skip Jira; use `#N`.
   - absent → `AskUserQuestion` "Create Jira Task for this?" with save-default opt-in.
5. **Derive `next_id`** for the `#N` fallback path.
6. Resolve epic dir: `<state-root>/epics/<epic-form>-*/` matching `<epic-id>`.
7. **Resolve dir name** (same rules as `new-epic` step 6):
   - SUCCESS → `tasks/<JIRA-KEY>-<slug>/`
   - FAILED → `tasks/#N-<slug>/` with `pending_jira_link: true`
   - SKIPPED → `tasks/#N-<slug>/` with `pending_jira_link: false`
8. Copy templates filling placeholders (v2 frontmatter):
   - `brief.md` from `task-brief.md`
   - `bugs.md` from `task-bugs.md`
   - `reviewer-notes.md` from `task-reviewer-notes.md`
9. Update epic's `master-plan.md` Task Index: add row `| <ID> | <name> | pending |`.
10. Update epic's `context.md` Current State → move task to Pending.
11. Run `update-status`.
12. Append to `sync.log` (trigger=new-task).
13. Confirm: "Created task <ID> — `<name>` in epic <epic-id> (repo `<name>`)"

### `new-standalone <name>`

0. **Resolve target repo.**
1. **Slug ambiguity check** — same rule as `new-epic` step 1.
2. **Bucket selection** — same rule as `new-epic` step 2.
3. **Worktree gate** — create worktree off latest main (branch naming same rules as `new-epic` step 3).
4. **Jira auto-create gate** — apply `defaults["new_standalone.jira_autocreate"]`:
   - `true` → run `jira create --type Story --project <jira_project> --title "<name>" --desc "handover standalone"`. No `--parent`.
   - `false` → skip Jira; use `#N`.
   - absent → `AskUserQuestion` with save-default opt-in.
5. **Derive `next_id`** for the `#N` fallback path.
6. **Resolve dir name** (same rules as `new-epic` step 6):
   - SUCCESS → `standalones/<JIRA-KEY>-<slug>/`
   - FAILED → `standalones/#N-<slug>/` with `pending_jira_link: true`
   - SKIPPED → `standalones/#N-<slug>/` with `pending_jira_link: false`
7. Copy templates filling placeholders (v2 frontmatter):
   - `brief.md` from `standalone-brief.md`
   - `bugs.md` from `standalone-bugs.md`
   - `reviewer-notes.md` from `standalone-reviewer-notes.md`
8. Run `update-status`.
9. Append to `sync.log` (trigger=new-standalone).
10. Confirm: "Created standalone <ID> — `<name>` in repo `<name>`"

### `update-status`

Regenerates `<state-root>/status.md` + `roadmap.md` + `tech-debt.md` from filesystem state. Run after any mutation. Never ask.

0. **Resolve target repo.**
1. **Worktree gate** — must not be on `main`.
2. List `<state-root>/{,<bucket>/}epics/<form>-*/` → read each `master-plan.md` for Status, Task Index, frontmatter (bucket, priority, severity, jira, pending_jira_link).
3. List `<state-root>/{,<bucket>/}epics/*/tasks/<form>-*/` → read each `brief.md`.
4. List `<state-root>/{,<bucket>/}standalones/<form>-*/` → read each `brief.md`.
5. Count open bugs across all `bugs.md` files (an open bug = a `### BUG-<n>` heading whose inline `<!-- status: ... -->` is `open` or `fixing`; legacy table-format files have no such headings → count 0); count blocked items.
6. **Regenerate three auto-files in one pass:**

   a. `<state-root>/status.md` — summary table with new columns Bucket and Priority:

   ```markdown
   | ID | Name | Status | Bucket | Priority | Jira | Tasks | Open Bugs |
   |----|------|--------|--------|----------|------|-------|-----------|
   | <JIRA-KEY> | slug | status | bucket | priority | KEY | X done, Y pending | Z |
   | #N | <legacy> | <status> | <bucket> | — | — | … | Z |
   ```

   (`Priority` is `—` for items without a Jira key.)

   b. `<state-root>/roadmap.md` — bucket-grouped, priority-sorted (see Roadmap generation below and `references/v2-schema.md`).

   c. `<state-root>/tech-debt.md` — stale-tier + lingering report (see Tech-debt generation below and `references/hygiene.md` once it exists).

7. **Per-item Jira sync** — for every tracked item with a real Jira key (frontmatter `jira` set and not `—`), run bidirectional sync per `references/sync.md`. Skip pending-link items.
8. Append a single `update-status` line to `sync.log`: `<UTC-ts>\tupdate-status\tsynced=<N>\tfailed=<M>`.

### Roadmap generation

The skill produces `<state-root>/roadmap.md` on every `update-status` call. Algorithm:

1. Determine active bucket vocab from registry (`bucket_vocab`).
2. Collect all items from `epics/`, `epics/*/tasks/`, `standalones/`. For each, read frontmatter (`bucket`, `priority`, `jira`, `pending_jira_link`).
3. Group items by bucket index (0..3). Items missing the `bucket` field (pre-v2 leftovers) default to bucket index 2 = `later`/`backlog`.
4. Sort each group by Jira priority desc (Highest > High > Medium > Low > Lowest > —), then by Jira `updated` desc.
5. Render Markdown:

```markdown
# Roadmap — <user> @ <repo-name>

> Auto-regenerated by Claude. Do not edit manually.
> Last updated: <UTC-ISO-8601>
> Bucket vocab: <vocab>

## <bucket-0-name> (<count>)

- **<ID>** <slug> · <priority> · <status> · <task-summary>

...

## <bucket-3-name> (<count>)

- ...
```

Where `<task-summary>` for epics is `X/Y tasks` (closed / total), for tasks/standalones is the short status note (e.g. "blocked", "filed 2026-05-19").

Items with `pending_jira_link: true` render as `**#N** <slug> · — · pending-link` (priority is `—`).

When no items are in a bucket, render `(none)` instead of an empty list.

### tech-debt.md generation

The skill produces `<state-root>/tech-debt.md` on every `update-status` call. Algorithm:

1. Read `<state-root>/_templates/tech-debt.md` as the structural template.
2. Apply stale-tier rules from `references/hygiene.md`. Compute UTC days-since-mtime for each item's most recent `next-session-*.md` (or dir mtime if none).
3. Apply lingering detection: scan each epic's `plan.md` for the keyword list and count post-expansion done-transitions in its tasks.
4. Render every section. Use `(none)` for empty sections.
5. Set the date in the header via `date -u +"%Y-%m-%dT%H:%M:%SZ"`.

Items with `pending_jira_link: true` are listed under their dedicated section, not the stale tiers, regardless of age.

### `/handover bug <add|fix|status>`

Quick-add / update a bug in the **active item's** `bugs.md` (resolved from the
current branch's ticket via `scripts/handover/resolve-active-item.sh` — C1; if it
exits non-zero, tell the user there's no active handover item and stop). Backed by
`scripts/handover/bug.sh`. Run by absolute path from the repo root.

- `add "<symptom>"` → `bug.sh add --bugs <item>/bugs.md --symptom "<symptom>"`. Echoes the new `BUG-<n>` id.
- `fix <BUG-n> <FAILED|WORKED> "<note>"` → `bug.sh fix --bugs <item>/bugs.md --id <BUG-n> --outcome <FAILED|WORKED> --note "<note>"`. Records a fix attempt under `Fixes tried:`.
- `status <BUG-n> <open|fixing|resolved|wontfix>` → `bug.sh status --bugs <item>/bugs.md --id <BUG-n> --to <status>`.

Resolve `<item>` once: `item="$(bash scripts/handover/resolve-active-item.sh)"` (exit 3 → no active item → skip with a one-line note). The bug id is per-item sequential and stable.

### `/handover bugs [--open]`

Cross-item **dashboard** of every tracked bug (read-only). Renders a markdown
table (Item / Bug / Status / Symptom / #Fixes) across all `bugs.md` under the
handover root, with totals. `--open` restricts to `open`/`fixing`. Backed by
`scripts/handover/bugs-dashboard.sh`; run by absolute path from the repo root:

```
bash scripts/handover/bugs-dashboard.sh [--open]
```

No active-item resolve needed — it aggregates the whole root. Prints
`_No bugs tracked._` when clean (`_No open bugs tracked._` under `--open`).

### `/handover lessons`

Proposal-only **lessons sweep** (read-only, writes nothing). Surfaces symptoms
of `resolved`/`wontfix` bugs and CR-finding titles that recur across ≥2 items
as lesson **candidates**, followed by a full digest. The operator promotes
what's worth keeping — there is no auto-write to the vault or `CLAUDE.md`.
Backed by `scripts/handover/lessons-sweep.sh`:

```
bash scripts/handover/lessons-sweep.sh
```

### `handover-resume #N`

Resolves any ID and outputs the cold-start prompt to resume work in a new session. Read-only.

0. **Resolve target repo.** Read-only — if ambiguous from conversation context, ask which repo.
1. **If `#N` omitted:** run No-ID picker.
2. **Normalize input:**
   - `<PROJECT>-K` (e.g. `HIMMEL-15`) → key form; scan only `<jira_project>-K-*/` namespace.
   - bare numeric `N` → scan BOTH `<jira_project>-N-*/` and `#N-*/` (per `references/routing.md` v2 rule).
   - strip leading `#` if present.
3. Scan in order, where `<form>` is each pattern from step 2. If the bucket layer is active and the ID has a Jira-prefix mapping, scan that bucket first; otherwise scan all buckets (and the legacy flat root):
   - `<state-root>/{,<bucket>/}epics/<form>-*/` → type: **epic**
   - `<state-root>/{,<bucket>/}epics/*/tasks/<form>-*/` → type: **task**
   - `<state-root>/{,<bucket>/}standalones/<form>-*/` → type: **standalone**
4. No match → output `No item with ID #N found in <repo-name>.` and stop.
5. List `next-session-*.md` in target dir. Find highest-numbered file.
6. **If session file exists:** read in full, locate the `## Cold-Start Prompt` heading, print every line **after** the heading up to the next `## ` heading or EOF (exclude the heading line itself, trim leading/trailing blank lines). Print under header `Cold-start prompt for #N (repo: <name>):`.
7. **No session file:** fallback — print `context.md` (epic) or `brief.md` (task/standalone), prefixed `No session file yet for #N in <repo-name>. Showing context:`.
7.5. **Surface open bugs + latest CR findings (C5).** Run `bash scripts/handover/resume-context.sh --item <resolved-item-dir>` (the dir found in step 3). If it prints anything, append it to the output under a blank line — so the resuming session sees open bugs (with FAILED/WORKED fixes-tried, to avoid re-trying a failed fix) and the most recent CR-findings block before continuing. Prints nothing for an item with no open bugs and no CR findings — leave the output clean.
8. **Stale nudge** — if `<state-root>/tech-debt.md` has any entries under `## Lingering` or `## Zombie`, append the top 3 to the printed output:

   ```
   Stale items worth a glance before continuing:
   - <ID> (lingering — decompose)
   - <ID> (zombie — close or unblock)

   Full triage: /handover hygiene
   ```

   Top 3 ordered by tier severity (zombie > lingering > stale > warming).

#### No-ID picker flow

Used by `handover-resume` (no ID) and `new-task` (no epic-id, scoped to epics).

1. **Scan** `<state-root>` (every active bucket + legacy flat root):
   - `{,<bucket>/}epics/#N-*/master-plan.md` → read Status
   - `{,<bucket>/}epics/*/tasks/#N-*/brief.md` → read Status (skip for new-task picker)
   - `{,<bucket>/}standalones/#N-*/brief.md` → read Status (skip for new-task picker)
2. **Filter:** keep active only (`in-progress`, `pending`, `not-started`, `planned`, `blocked`). Skip inactive (`done`, `dropped`, `deferred`).
3. **Sort** by status priority desc, then ID desc.
4. **Edge cases:**
   - Zero active items (`handover-resume`): skip picker, free-text prompt for ID.
   - Zero active epics (`new-task`): print `No active epics in <repo-name> — file 'new-epic <name>' first` and stop.
   - 1–3 active items: render `AskUserQuestion` with N+1 options (last = "Other (enter ID)").
5. **Render** up to 4 options. Label: `#N <slug> — <status>` (truncate slug to 30 chars).
6. **Resolve:** option 1–3 → extract `#N`. "Other" → second prompt for free-text ID.
7. Fall through with resolved N.

Read-only — no worktree gate.

### `end-session [epic-id|task-id|standalone-id]`

Creates a numbered session file. Append-only — never overwrites.

0. **Resolve target repo.**
1. **Worktree gate** — enter worktree for the target item.
2. Determine target directory.
3. Count existing `next-session-*.md` files → `N = count + 1`.
4. Create `next-session-N.md` with:
   - Bullet summary of session work
   - Current active task, blockers
   - "First Action Next Session" — one sentence
   - Cold-start prompt (see below); use `date -u +%F` for the file header date and `date -u +"%Y-%m-%dT%H:%M:%SZ"` for the cold-start prompt timestamp if present.
   - `## Overnight Mode Trigger` section — copy the static block from the matching template at `<state-root>/_templates/<variant>-next-session.md` (seeded from `${CLAUDE_PLUGIN_ROOT}/templates/` on `init`/`register`). The template stores the relative link to `docs/handover/overnight-mode.md` at the **rendered-destination depth** already (4 `../` for epic/standalone, 5 `../` for task), so copy verbatim without rewriting. Do NOT inline the pipeline content — point at the canonical doc only. If the seeded `_templates/` copy is missing the section (template_version drift), re-seed from `${CLAUDE_PLUGIN_ROOT}/templates/` before emitting the new session file — same one-shot mechanism used for the frontmatter injection.
5. Update `context.md` Current State; also bump the item's frontmatter `updated:` to UTC ISO-8601 now.
6. **Auto-transition Jira:** read `**Jira:**` field. If `—`, skip. If marking epic complete: `jira transition <KEY> "Done"`. Otherwise: `jira transition <KEY> "In Progress"`. On failure: warn, continue. After the transition, run per-item Jira sync per `references/sync.md` for priority/severity (bidirectional path).
7. Append a single `end-session` row to `sync.log` (trigger=end-session).

**Cold-start prompt format** (lives under `## Cold-Start Prompt` heading inside `next-session-N.md`; `handover-resume` extracts the block between that heading and the next `## ` heading or EOF):

```
Continue <type> #N <name> in repo <repo-name>.

Load context:
- <state-root>/{<bucket>/}<type-path>/#N-<slug>/context.md
- <state-root>/{<bucket>/}<type-path>/#N-<slug>/tasks/#M-<slug>/brief.md  [if active task]

Load latest session: <state-root>/{<bucket>/}<type-path>/#N-<slug>/next-session-<latest>.md

[Critical context that won't be obvious from files]
```

`{<bucket>/}` segment is present only when the bucket layer is active (HIMMEL-129); omit it entirely for flat layouts.

**Rules:**
- Always run `end-session` at session end — even if short.
- Session files are append-only — never delete or rename `next-session-*.md`.
- To resume: load the highest-numbered `next-session-*.md` in the target dir.

### Overnight mode

The handover system's `next-session-N.md` files include a `## Overnight Mode Trigger` section that points at `docs/handover/overnight-mode.md`. If a user prompt includes the literal phrase **"overnight mode"** alongside a `next-session-*.md` path, the assistant is expected to read the canonical pipeline doc and execute the 11-phase autonomous workflow without pausing for confirmation between phases.

The trigger phrase is treated as a workflow signal, not a magic command — it is documented here so the assistant recognizes it from any session. Block-only criteria, budget estimates, and lessons-learned live in the canonical doc.

### `/handover bucket <id> <bucket>`

Move an item between buckets. `<id>` is `#N`, bare numeric, or Jira key. `<bucket>` selects the **axis by name** — the two name-sets are disjoint, so the target axis is unambiguous:

- **`<bucket>` ∈ the active time-horizon vocab** (`now/next/later/someday`, or the kanban/`buckets_custom` names) → **time-horizon move** (frontmatter `bucket:` write). Unchanged behaviour.
- **`<bucket>` ∈ the recognized source-bucket set** (the four built-ins ∪ `source_buckets_extra`, HIMMEL-307) → **source-repo move** (relocate the item's directory + rewrite inbound refs).
- **`<bucket>` matches neither** → error: print the valid names for both axes and do nothing.

The two name-sets are kept disjoint at registry-write time — `source_buckets_extra` validation (see `references/init-register.md`) rejects any extra-bucket name that collides with a reserved time-horizon name. If a name ever appears in **both** sets anyway (e.g. a hand-edited registry), do not guess: treat it as the **source-repo** axis and warn (`<bucket>` is ambiguous; resolving as source-repo — rename the extra bucket to disambiguate).

**Time-horizon move:**

0. **Resolve target repo.**
1. **Worktree gate** — enter item's worktree.
2. Resolve item path (see lookup rules in routing.md + v2-schema.md).
3. Apply the WIP context-detection rule from `references/buckets.md`.
4. Write the new bucket value to the item's frontmatter (`bucket: <name>` and bump `updated:` to UTC now).
5. Run `update-status`.
6. Append to `sync.log`.
7. Confirm: "Moved <id> → <bucket> (time-horizon) in repo `<name>`"

**Source-repo move (HIMMEL-307):**

0. **Resolve target repo.**
1. **Worktree gate** — enter item's worktree.
2. Resolve item path under its current source bucket. **Only epics and standalones may be source-moved** — a task's source bucket follows its parent epic, so moving a task alone is refused (move the epic instead, which carries its `tasks/` subtree). Refuse (warn-only, no-op) if `<bucket>` equals the item's current source bucket.
3. **Relocate the dir:** `git mv <state-root>/<current-bucket>/<type-path>/<dir>/ <state-root>/<bucket>/<type-path>/<dir>/` (create the destination `<type-path>` parent if absent). `<type-path>` is `epics` or `standalones`.
4. **Rewrite inbound refs** — the *regen subset* of `/handover jira-link` step 6 (NOT its task-row bullets: only epics/standalones source-move, so there is no parent-epic Task Index / `context.md` row to rewrite). Regenerate `status.md`, `roadmap.md`, `tech-debt.md` via `update-status`. The source bucket is positional — the directory path — not a frontmatter field, so there is no per-item `bucket:` edit.
5. Bump the item's frontmatter `updated:` to UTC now.
6. Run `update-status`.
7. Append to `sync.log` (trigger=bucket-move-source).
8. Confirm: "Moved <id> → <bucket> (source-repo) in repo `<name>`"

### `/handover priority <id> <priority>`

Set an item's Jira-mirrored priority. `<priority>` is `Highest|High|Medium|Low|Lowest`.

0. **Resolve target repo.**
1. **Worktree gate** — enter item's worktree.
2. Resolve item path.
3. Write the new priority to the item's frontmatter (`priority: <P>` and bump `updated:`).
4. Push to Jira: `jira edit <key> --priority <P>`. On failure (network/token): warn, log to `sync.log` with status=failed. Do not mark `pending_jira_link: true` (we still have the key).
5. Run `update-status`.
6. Confirm: "Set <id> priority → <P>"

### `/handover jira-link <id> [<key>]`

Upgrade a `#N-slug/` item to `<JIRA-KEY>-slug/`. Required for offline-fallback items (`pending_jira_link: true`) and for lazy-adoption of legacy items.

0. **Resolve target repo.**
1. **Worktree gate.**
2. Resolve item path. Refuse (warn-only, not error) if the item already has a real Jira key in frontmatter (`jira` is not `—` and not blank). Caller can pass `--force` to re-link.
3. **If `<key>` provided** → use it directly (user supplied a manually-created Jira ticket).
   **Else** → run `jira create --type <T> [--parent <P>] --title "<slug>" --desc "..."`. Type is inferred from dir position (Epic for `epics/`, Task for `epics/*/tasks/`, Story for `standalones/`). Parent for tasks is the parent epic's Jira key.
4. **Rename dir:** `git mv <path>/#N-slug/ <path>/<JIRA-KEY>-slug/`.
5. **Rename worktree branch** (if exists): `git branch -m <branch_prefix><slug> <branch_prefix><JIRA-KEY>-<slug>`. Also rename the worktree directory under `.claude/worktrees/` to match.
6. **Rewrite inbound refs** in:
   - parent epic's `master-plan.md` Task Index row (if this is a task)
   - parent epic's `context.md` Current State list (if this is a task)
   - `status.md`, `roadmap.md`, `tech-debt.md` (full regen)
7. **Update frontmatter:** set `jira: <KEY>`, `pending_jira_link: false`, bump `updated`.
8. Append to `sync.log` (trigger=jira-link).
9. Confirm: "Linked <id> → <KEY>. Renamed dir + branch + refs."

### `/handover defaults <subcommand>`

Manage per-repo save-defaults. Resolves target repo.

- `get` — print all defaults for the target repo as a table
- `get <key>` — print one default value (e.g. `new_epic.jira_autocreate`)
- `set <key> <value>` — write a default. Validates against the defaults key reference in `init-register.md`.
- `clear <key>` — remove a default (the next command that needs it will ask again)
- `clear-all` — remove every default for the target repo

All writes go to `~/.claude/handover/registry.json` via the atomic-write protocol.

### `/handover hygiene [mode]`

Maintenance command. `<mode>` is `triage`, `consolidate`, `analyse`, or omitted (= all three).

0. **Resolve target repo.**
1. **Read** `<state-root>/tech-debt.md` (already up-to-date from latest `update-status`).
2. Execute the requested mode(s) per `references/hygiene.md`:
   - **triage** — iterate over every entry in tech-debt.md; `AskUserQuestion` per item with per-tier action options.
   - **consolidate** — run path-overlap, DoD-overlap, slug-similarity, and ghost-follow-up scans; print numbered suggestions.
   - **analyse** — compute corpus metrics; print summary.
3. **Apply** triage verdicts as soon as the user answers (skill executes the chosen action: close, move bucket, re-activate, etc.).
4. **Apply** consolidate suggestions only on `/handover consolidate apply <N>` follow-up (this command does NOT auto-act on consolidate).
5. **Print** analyse output to stdout (no side effects).
6. **Append** a single hygiene entry to `sync.log`.

Save-defaults supported: triage verdicts can opt-in to "always close zombie as deferred", "always re-activate stale", etc. via `defaults["hygiene.zombie_default"]`, `defaults["hygiene.stale_default"]`, etc. — keys documented in `references/hygiene.md`.

### `/handover consolidate apply <N>`

Act on a consolidation suggestion from the last `/handover hygiene` (or `/handover hygiene consolidate`) run. `<N>` is the suggestion number.

The skill must remember the most-recent consolidate output. Store it transiently in `<state-root>/.last-consolidate.json` (gitignored) with the list of suggestions. On `apply <N>`:

1. Read `.last-consolidate.json`; locate suggestion N.
2. Execute its proposed action:
   - "fold X under Y" → move dir X under Y/tasks/; rewrite refs; transition X's Jira to a Task under Y's Epic.
   - "promote A+B+C to new epic" → `AskUserQuestion` for new epic name; create epic; move A/B/C as tasks under it.
   - "ghost follow-up X referenced but never filed" → `AskUserQuestion`: "file as standalone now?"
3. Run `update-status`.
4. Append to `sync.log` (trigger=consolidate-apply).

## Template Placeholders

When copying a template, fill these placeholders (text substitution):

| Placeholder | Resolved value |
|---|---|
| `<repo-name>` | registry name of target repo (e.g. `himmel`) |
| `<repo-root>` | canonical abs path of target repo |
| `<state-root>` | `<repo-root>/handovers/<user>/` |
| `<user>` | registry user field |
| `<N>` | new item ID (no `#` prefix) |
| `<slug>` | item slug |
| `<task-slug>` | child task slug (used in epic `context.md` Current State list to reference tasks) |
| `<name>` | item display name (free text from `new-*` invocation) |
| `<type>` | `epic` \| `task` \| `standalone` |
| `<type-path>` | `epics` \| `epics/#M-<epic-slug>/tasks` \| `standalones` |
| `<M>` | parent epic ID (tasks only; no `#` prefix) |
| `<epic-slug>` | parent epic slug (tasks only) |
| `<epic-name>` | parent epic display name (tasks only) |
| `<latest>` | highest existing `next-session-N.md` index when writing cold-start prompt that points at "load latest session" |
| `<branch_prefix>` | registry `branch_prefix` field (default `handover/`) |
| `YYYY-MM-DD` | today's date |

Templates carry `template_version: <integer>` frontmatter. Parsers read the version. On mismatch with the plugin's current version, warn but proceed.

## Critical Rules

- **Resolve target repo before any read or write.** Never assume a single repo.
- **Resolve target bucket** (HIMMEL-129) before any read or write when the bucket layer is active under `<state-root>`. Bucket layer = any **recognized source bucket** exists directly under `<state-root>` — the four built-ins `himmel/`, `luna/`, `luna_brain/`, `cross/` plus any names in the host repo's `source_buckets_extra` (HIMMEL-307). See Bucket Resolution.
- **Scan for ID:** Never trust `counter.md` alone — always reconcile against filesystem max.
- **Worktree always:** All file writes happen in a worktree of the target repo.
- **context.md ≤1 page.**
- **Templates are canonical:** Never modify `<state-root>/_templates/` files via mutation commands. Copy and fill.
- **status.md auto-generated.** Always regenerate via `update-status`.
- **Slugs:** lowercase, hyphens, ≤30 chars. `#` prefix is part of dir name.
- **Session files append-only.**

## Supplementary Files

Two freeform files. They live at the **state-root host**'s `handovers/` root — the external repo chosen at `/handover-setup` (Mode B) when one is configured, else the inline `<repo-root>/handovers/` (Mode A):

- **`<state-root-host>/handovers/manual_notes.md`** — running TODO list. Human-maintained.
- **`<state-root-host>/handovers/random_dreams.md`** — product ideas / roadmap seeds. Human-maintained.

Resolution: read from the `HANDOVER_DIR` host repo's `handovers/` root if Mode B is configured; otherwise fall back to looking for these files at any registered repo's `<repo-root>/handovers/` root.

Rules:
- Never auto-generate or overwrite.
- When user mentions an idea matching an entry, surface it.
- When formalizing into an epic/standalone, move from freeform to `backlog.md` or new item.

## File Paths

```
<repo-root>/
  handovers/
    manual_notes.md                      ← freeform, human-maintained (at the state-root host; Mode B if configured)
    random_dreams.md                     ← freeform, human-maintained (at the state-root host; Mode B if configured)
    <user>/                              ← <state-root>
      status.md                          ← auto-generated
      roadmap.md                         ← auto-generated (NEW in v2)
      tech-debt.md                       ← auto-generated (NEW in v2)
      sync.log                           ← auto-appended on each Jira sync (NEW in v2)
      backlog.md                         ← unprioritized future work
      counter.md                         ← optional; preferred over filesystem max if higher
      next-session-resume.md             ← cold-start marker (root; bucket layer skips this file)
      luna-wave-resume.md                ← LUNA-wave aggregator (root)
      overnight-summary-*.md             ← daily/overnight session logs (root)
      _templates/                        ← per-repo template copies (seeded from plugin)
        roadmap.md                       ← NEW in v2
        tech-debt.md                     ← NEW in v2

      # FLAT LAYOUT (pre-HIMMEL-129; still supported as fallback)
      epics/
        #N-<slug>/
          master-plan.md
          context.md
          plan.md
          bugs.md
          reviewer-notes.md
          extra-rules.md
          next-session-1.md              ← append-only
          next-session-2.md
          tasks/
            #N-<slug>/
              brief.md
              bugs.md
              reviewer-notes.md
              next-session-1.md
      standalones/
        #N-<slug>/
          brief.md
          bugs.md
          reviewer-notes.md
          next-session-1.md

      # BUCKET LAYOUT (HIMMEL-129; active when any recognized source-bucket dir exists)
      himmel/                            ← Jira-prefix HIMMEL-* lands here
        epics/<KEY-or-#N>-<slug>/...
        standalones/<KEY-or-#N>-<slug>/...
      luna/                              ← Jira-prefix LUNA-* lands here
        epics/...
        standalones/...
      luna_brain/                        ← Jira-prefix LUNA-BRAIN-* lands here
        epics/...
        standalones/...
      cross/                             ← cross-repo work; no Jira prefix
        epics/...
        standalones/...
      <extra>/                           ← e.g. luna-medic/ — source_buckets_extra (HIMMEL-307); explicit-only, no Jira-prefix route
        epics/...
        standalones/...
```

Registry (machine-global, not per-repo):

```
~/.claude/handover/
  registry.json                          ← repo registry, atomic writes
```

## Status Values

**Active** (picker shows): `not-started` | `in-progress` | `pending` | `planned` | `blocked`
**Inactive** (picker skips): `done` | `dropped` | `deferred`

## Capturing Human Feedback

When user gives feedback on work during chat, capture it to the relevant `reviewer-notes.md` under `## Human Feedback`. Proactively — don't wait to be asked. Resolves under the **target repo** of the work being reviewed.

## Capturing Bug Fixes

When a fix is attempted during debugging and **fails**, append it to the active item's bug before moving on — proactively, don't wait to be asked: `/handover bug fix <BUG-n> FAILED "<what you tried + why it failed>"` (or `bug add "<symptom>"` first if the bug isn't tracked yet). When a fix works, record `WORKED` and set status `resolved`. This `Fixes tried` FAILED/WORKED ledger is the circular-debugging breaker — it stops a later session (or a post-compaction you) from re-trying a fix that already failed. Resolves under the **target repo** of the work being debugged (same resolver as Human Feedback).

## References (load on demand)

- `references/routing.md` — full resolution algorithm, canonicalisation, edge cases
- `references/init-register.md` — full specs for `init`, `register`, `repos` subcommands
