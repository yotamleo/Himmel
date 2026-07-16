# Handover — `new-epic` / `new-task` / `new-standalone`

Load `references/resolution.md` first (shared Target Repo Resolution, Bucket Resolution, ID Derivation, Worktree Gate, Template Placeholders — referenced by section name below).

## `new-epic <name>`

Creates a new epic in the target repo.

0. **Resolve target repo** (see Target Repo Resolution).
1. **Slug ambiguity check** — if `<name>` produces more than one reasonable slug (contains acronyms, mixed case, or multiple split-point candidates), apply `defaults.slug_style`:
   - `prompt-on-ambiguous` (default) → `AskUserQuestion` with 2-3 slug candidates
   - `strict-hyphen-only` → use the deterministic strict transformation; no prompt
2. **Bucket selection** — two orthogonal axes:
   - **Time-horizon bucket** (frontmatter `bucket:`) — if `defaults["new_*.bucket"]` is set, use it; else `AskUserQuestion` ("which time-horizon bucket for this new epic?") with the 4 active vocab options. Offer save-default opt-in.
   - **Source-repo bucket** (which `<state-root>/<bucket>/` dir the item lands in, HIMMEL-307; `new-epic`/`new-standalone` only — a `new-task` inherits its parent epic's source bucket) — resolve per Bucket Resolution. When the state-root host repo defines a non-empty `source_buckets_extra`, additionally offer the recognized extra buckets via `AskUserQuestion` ("which source bucket?"), defaulting to the prefix-derived bucket (dismiss ⇒ prefix default = today's behaviour). When `source_buckets_extra` is absent/empty, skip this sub-prompt entirely — the prefix rule resolves the source bucket exactly as before.
3. **Worktree gate** — create worktree off latest main. The Jira key isn't known yet (Jira create is step 5), so both flows start from a provisional slug-only branch — but **do not assume `<branch_prefix><slug>` is free.** This is a *new-item creation*: it must NEVER enter an existing unmerged worktree of that name (unlike the shared Worktree Gate in `references/resolution.md`, which enters an existing unmerged branch — that branch belongs to another item, or to a concurrent/retried creation of the same slug, and entering it would write this item into the wrong worktree). **Allocate a uniquely-owned provisional branch instead:** if `<branch_prefix><slug>` does not exist, create it; if a branch by that name already exists (merged or not), fall through to `<branch_prefix><slug>-<N>`, incrementing `N` until an unused name is found (same conflict-suffix convention as the Worktree Gate's fresh-worktree branch). Call the allocated name `<prov-branch>`.
   - If item will be Jira-keyed: `<prov-branch>` is **renamed** to `<branch_prefix><JIRA-KEY>-<slug>` at step 6, after Jira create succeeds — and that rename target is itself collision-checked (suffix `-<N>` if a branch by that name already exists).
   - If item will be `#N`: the branch stays `<prov-branch>`.
4. **Derive `next_id`** (only used for the offline-fallback `#N` path) by scanning `<state-root>` (see ID Derivation).
5. **Jira auto-create gate** — apply `defaults["new_epic.jira_autocreate"]`:
   - `true` → run `jira create --type Epic --project <jira_project> --title "<name>" --desc "handover epic"`. Capture key on success.
   - `false` → skip Jira; use `#N`.
   - absent → `AskUserQuestion` "Create Jira Epic for this?" with save-default opt-in.
6. **Resolve dir name:**
   - Jira create SUCCESS → `epics/<JIRA-KEY>-<slug>/`. **Now rename the provisional branch** `<prov-branch>` created in step 3 to `<branch_prefix><JIRA-KEY>-<slug>` (collision-check the target first — suffix `-<N>` if a branch by that name already exists): `git branch -m <prov-branch> <branch_prefix><JIRA-KEY>-<slug>`, then `git worktree move` the worktree dir to match (step 3 named the branch with the key-free provisional slug because the key wasn't known yet — this is the rename step 3 defers to).
   - Jira create FAILED → `epics/#N-<slug>/` with `pending_jira_link: true` (keep the provisional `<prov-branch>` branch; a later `/handover jira-link` performs the rename)
   - Jira skipped (user opted out / no jira_project) → `epics/#N-<slug>/` with `pending_jira_link: false`
7. Create dir + `tasks/.gitkeep`.
8. Copy templates from `<state-root>/_templates/` and fill placeholders (see Template Placeholders + `references/v2-schema.md`). Frontmatter must include the v2 fields; `created` and `updated` set to `date -u +"%Y-%m-%dT%H:%M:%SZ"`.
9. Run `update-status` (regenerates `status.md` + `roadmap.md` + `tech-debt.md`).
10. Append to `sync.log` (trigger=new-epic).
11. Confirm: "Created epic <JIRA-KEY> — `<name>` in repo `<name>`" (or `#N` if offline path).

**Slug rule:** lowercase, hyphens only, max 30 chars.

## `new-task <epic-id> <name>`

Creates a task inside an existing epic. `<epic-id>` is `<JIRA-KEY>`, `#N`, or bare numeric.

**If `<epic-id>` omitted:** run the No-ID picker scoped to epics only.

0. **Resolve target repo.**
1. **Worktree gate** — enter epic's worktree (or create if missing).
2. **Slug ambiguity check** — same rule as `new-epic` step 1.
3. **Bucket selection (time-horizon axis only)** — same rule as `new-epic` step 2's *time-horizon* bucket. The **source bucket is inherited from the parent epic** (a task never lives in a different source bucket than its epic), so the source-bucket sub-prompt does NOT apply to `new-task`.
4. **Jira auto-create gate** — apply `defaults["new_task.jira_autocreate"]`:
   - `true` → **first check the parent epic has a real Jira key.** If the parent is offline (`#N` dir / `jira` is `—` / `pending_jira_link: true`), there is no `<epic-jira-key>` to `--parent`, so do NOT emit an unparented or malformed `jira create`: fall back to the offline `#N` task path (`pending_jira_link: true`) and tell the user to `/handover jira-link <epic-id>` first if they want the task Jira-linked. When the parent HAS a key → run `jira create --type Task --parent <epic-jira-key> --title "<name>" --desc "handover task"`. This creates a Jira Task linked to the parent Epic via Epic Link (NOT a Sub-task).
   - `false` → skip Jira; use `#N`.
   - absent → `AskUserQuestion` "Create Jira Task for this?" with save-default opt-in.
5. **Derive `next_id`** for the `#N` fallback path.
6. Resolve epic dir: `<state-root>/{,<bucket>/}epics/<epic-form>-*/` matching `<epic-id>` — in an active bucket layer the epic lives under its resolved source bucket (`<state-root>/<bucket>/epics/...`, per `references/resolution.md` Bucket Resolution); fall back to the flat `<state-root>/epics/...` only when the bucket layer is inactive.
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

## `new-standalone <name>`

0. **Resolve target repo.**
1. **Slug ambiguity check** — same rule as `new-epic` step 1.
2. **Bucket selection** — same rule as `new-epic` step 2.
3. **Worktree gate** — create worktree off latest main (branch naming same rules as `new-epic` step 3).
4. **Jira auto-create gate** — apply `defaults["new_standalone.jira_autocreate"]`:
   - `true` → run `jira create --type Story --project <jira_project> --title "<name>" --desc "handover standalone"`. No `--parent`.
   - `false` → skip Jira; use `#N`.
   - absent → `AskUserQuestion` with save-default opt-in.
5. **Derive `next_id`** for the `#N` fallback path.
6. **Resolve dir name** (same rules as `new-epic` step 6, including the branch rename):
   - SUCCESS → `standalones/<JIRA-KEY>-<slug>/`. Rename the provisional branch `<prov-branch>` from step 3 to `<branch_prefix><JIRA-KEY>-<slug>` (collision-check the target — suffix `-<N>` if taken): `git branch -m <prov-branch> <branch_prefix><JIRA-KEY>-<slug>`, then `git worktree move` the worktree dir to match.
   - FAILED → `standalones/#N-<slug>/` with `pending_jira_link: true` (keep the provisional `<prov-branch>` branch)
   - SKIPPED → `standalones/#N-<slug>/` with `pending_jira_link: false`
7. Copy templates filling placeholders (v2 frontmatter):
   - `brief.md` from `standalone-brief.md`
   - `bugs.md` from `standalone-bugs.md`
   - `reviewer-notes.md` from `standalone-reviewer-notes.md`
8. Run `update-status`.
9. Append to `sync.log` (trigger=new-standalone).
10. Confirm: "Created standalone <ID> — `<name>` in repo `<name>`"
