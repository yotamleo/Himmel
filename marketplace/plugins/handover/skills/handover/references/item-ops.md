# Handover — item mutation ops (`bucket` / `priority` / `jira-link` / `defaults`)

Load `references/resolution.md` first (Target Repo Resolution, Bucket Resolution, Worktree Gate).

## `/handover bucket <id> <bucket>`

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

## `/handover priority <id> <priority>`

Set an item's Jira-mirrored priority. `<priority>` is `Highest|High|Medium|Low|Lowest`.

0. **Resolve target repo.**
1. **Worktree gate** — enter item's worktree.
2. Resolve item path.
3. Write the new priority to the item's frontmatter (`priority: <P>` and bump `updated:`).
4. **Push to Jira only if the item has a real Jira key.** For an offline item (`#N` dir / `jira` is `—` or blank / `pending_jira_link: true`), there is no key to `jira edit` — write the local frontmatter priority only, log `sync.log` status=local-only, and stop (the next `/handover jira-link` carries the stored priority up on create). Otherwise run `jira edit <key> --priority <P>`; on failure (network/token) warn and log to `sync.log` with status=failed, and do not mark `pending_jira_link: true` (we still have the key).
5. Run `update-status`.
6. Confirm: "Set <id> priority → <P>"

## `/handover jira-link <id> [<key>]`

Upgrade a `#N-slug/` item to `<JIRA-KEY>-slug/`. Required for offline-fallback items (`pending_jira_link: true`) and for lazy-adoption of legacy items.

0. **Resolve target repo.**
1. **Worktree gate.**
2. Resolve item path. Refuse (warn-only, not error) if the item already has a real Jira key in frontmatter (`jira` is not `—` and not blank). Caller can pass `--force` to re-link.
3. **If `<key>` provided** → use it directly (user supplied a manually-created Jira ticket).
   **Else** → run `jira create --type <T> [--parent <P>] --title "<slug>" --desc "..."`. Type is inferred from dir position (Epic for `epics/`, Task for `epics/*/tasks/`, Story for `standalones/`). Parent for tasks is the parent epic's Jira key.
4. **Rename dir:** `git mv <path>/#N-slug/ <path>/<JIRA-KEY>-slug/`.
5. **Rename worktree branch** (if exists): `git branch -m <branch_prefix><slug> <branch_prefix><JIRA-KEY>-<slug>`. To rename the worktree directory under `.claude/worktrees/`, use **`git worktree move <old-path> <new-path>`** — never rename the directory by hand (a manual `mv` orphans Git's worktree metadata, which still points at the old path). Move through Git, then the branch rename above.
6. **Rewrite inbound refs** in:
   - parent epic's `master-plan.md` Task Index row (if this is a task)
   - parent epic's `context.md` Current State list (if this is a task)
   - `status.md`, `roadmap.md`, `tech-debt.md` (full regen)
7. **Update frontmatter:** set `jira: <KEY>`, `pending_jira_link: false`, bump `updated`.
8. Append to `sync.log` (trigger=jira-link).
9. Confirm: "Linked <id> → <KEY>. Renamed dir + branch + refs."

## `/handover defaults <subcommand>`

Manage per-repo save-defaults. Resolves target repo.

- `get` — print all defaults for the target repo as a table
- `get <key>` — print one default value (e.g. `new_epic.jira_autocreate`)
- `set <key> <value>` — write a default. Validates against the defaults key reference in `init-register.md`.
- `clear <key>` — remove a default (the next command that needs it will ask again)
- `clear-all` — remove every default for the target repo

All writes go to `~/.claude/handover/registry.json` via the atomic-write protocol.
