# Handover — `new-epic` / `new-task` / `new-standalone`

Load `references/resolution.md` first (shared Target Repo Resolution, Bucket Resolution, ID Derivation, Worktree Gate, Idempotent Remote Create, Template Placeholders — referenced by section name below).

## `new-epic <name>`

Creates a new epic in the target repo.

0. **Resolve target repo** (see Target Repo Resolution).
1. **Slug ambiguity check** — if `<name>` produces more than one reasonable slug (contains acronyms, mixed case, or multiple split-point candidates), apply `defaults.slug_style`:
   - `prompt-on-ambiguous` (default) → `AskUserQuestion` with 2-3 slug candidates
   - `strict-hyphen-only` → use the deterministic strict transformation; no prompt
2. **Bucket selection** — two orthogonal axes:
   - **Time-horizon bucket** (frontmatter `bucket:`) — if `defaults["new_*.bucket"]` is set, use it; else `AskUserQuestion` ("which time-horizon bucket for this new epic?") with the 4 active vocab options. Offer save-default opt-in.
   - **Source-repo bucket** (which `<state-root>/<bucket>/` dir the item lands in, HIMMEL-307; `new-epic`/`new-standalone` only — a `new-task` inherits its parent epic's source bucket) — resolve per Bucket Resolution. **Resume check BEFORE any bucket prompt:** the step-5 recovery record is keyed on `(source-bucket, type, slug)`, so search for a `(type, slug)` record across **every candidate bucket** — the prefix-derived one *and* each recognized non-empty `source_buckets_extra` value — not just the prefix default. Exactly one match → **adopt its recorded bucket and skip the prompt entirely**, then resolve the branch per the resume rule in step 5 (the recorded `<prov-branch>` may already have been renamed). More than one match → **fail closed and report**; never pick one, as that silently binds the item to the wrong bucket. No match → the prompt/prefix-default behaviour above is unchanged. Searching only the prefix bucket would miss a record written under an extra bucket, and prompting first would let a different answer compute a different key — either way the lookup misses and a duplicate ticket is filed. On re-entry the record must win over a fresh choice. When the state-root host repo defines a non-empty `source_buckets_extra`, additionally offer the recognized extra buckets via `AskUserQuestion` ("which source bucket?"), defaulting to the prefix-derived bucket (dismiss ⇒ prefix default = today's behaviour). When `source_buckets_extra` is absent/empty, skip this sub-prompt entirely — the prefix rule resolves the source bucket exactly as before.
3. **Worktree gate** — create worktree off latest main. The Jira key isn't known yet (Jira create is step 5), so both flows start from a provisional slug-only branch — but **do not assume `<branch_prefix><slug>` is free.** This is a *new-item creation*: it must NEVER enter an existing unmerged worktree of that name (unlike the shared Worktree Gate in `references/resolution.md`, which enters an existing unmerged branch — that branch belongs to another item, or to a concurrent/retried creation of the same slug, and entering it would write this item into the wrong worktree). **Allocate a uniquely-owned provisional branch instead** — and allocate it by *attempting creation*, never by pre-checking availability. Checking "does this branch exist?" and then creating it is a check-then-create race: two concurrent `new-epic` / `new-standalone` runs on the same slug both observe the name as free and the second silently adopts the first's branch. `git branch <name>` is atomic and fails when the ref already exists, so let it be the arbiter: try to create `<branch_prefix><slug>`; if creation fails because the ref exists (merged or not), retry with `<branch_prefix><slug>-<N>`, incrementing `N` and re-attempting creation until one succeeds (same conflict-suffix convention as the Worktree Gate's fresh-worktree branch). The name you successfully created is `<prov-branch>` — only a create that *you* won grants ownership.
   - If item will be Jira-keyed: `<prov-branch>` is **renamed** to `<branch_prefix><JIRA-KEY>-<slug>` at step 6, after Jira create succeeds — and that rename resolves collisions the same way this step does: by retrying when the atomic `git branch -m` reports the target ref already exists (suffix `-<N>`, incrementing), never by pre-checking the target's availability.
   - If item will be `#N`: the branch stays `<prov-branch>`.
4. **Derive `next_id`** (only used for the offline-fallback `#N` path) by scanning `<state-root>` (see ID Derivation).
5. **Jira auto-create gate** — apply `defaults["new_epic.jira_autocreate"]`:
   - `true` → follow **Idempotent Remote Create** in `references/resolution.md`: mint the nonce, write the intent record, look up the marker, then create the epic WITH the marker — `jira create --type Epic --project <jira_project> --title "<name>" --desc "handover epic" --labels handover-idem-<nonce>`. Capture the key on success (or, if the marker lookup already found one, adopt that key and skip the create).

     **Key the intent record on the item's stable creation identity — `(source-bucket, type, slug)` — NEVER on `<prov-branch>`.** The provisional branch name is not an identity: step 6 *renames* it, and the `-<N>` collision suffix means a retry may not even land on the same name. Keyed on the branch, the record becomes undiscoverable the moment the rename succeeds — so a failure in steps 7-10 would find nothing and file a duplicate anyway, defeating the record's whole purpose. `(source-bucket, type, slug)` is fixed at step 1-2 and survives every rename. Store `<prov-branch>` as a *field* of the record (it is what step 6 must finalize), not as its key. The record is `<state-root>/.pending-new-item/<canonical-identity>.json`.

     **What this contract covers, and what it does not.** The shared protocol closes the common case — a crash anywhere in the create-or-resume window resumes and reuses (or adopts) the key instead of filing a duplicate. It is deliberately NOT a full transactional protocol: it does not serialize two concurrent runs racing the same `(source-bucket, type, slug)` create (cross-process locking is out of scope by decision), and it does not journal per-step progress — that was considered and rejected (see below), because every post-create step is filesystem-observable or idempotent. Do not extend this contract piecemeal here; it lives once, in `references/resolution.md`.

     **Resolve the branch by discovery, never by trusting the recorded `<prov-branch>` verbatim.** The record is written before step 6 and is not re-persisted after the rename, so on resume `<prov-branch>` may already be gone — adopting it blindly would target a branch that no longer exists. Decide from what is actually present:
     - `<prov-branch>` exists → the rename has not happened yet: resume at step 6.
     - `<prov-branch>` is absent but `<branch_prefix><JIRA-KEY>-<slug>` (or its `-<N>` variant, matched via the worktree's own metadata) exists → **the rename already completed**: adopt that branch and resume at step 7.
     - Neither exists → stop and report; do **not** create a second epic — the key is recorded, so this is a state to inspect, not to re-create through. **Clear the record only after EVERY post-create step has succeeded** (through step 10's `sync.log` append) — not at step 6: clearing it there would leave a failure in steps 7-10 (dir/templates/`update-status`/`sync.log`) with no key to resume from. Because the clear necessarily follows the `sync.log` append, a crash between the two is possible — so make step 10 **idempotent** (a `sync.log` entry already bearing this `<JIRA-KEY>` + trigger is not appended twice) and treat a resume that finds every post-create step already done as a **clear-only** finalization. Losing the key is the expensive failure (a duplicate Jira item); a redundant clear costs nothing.

     **A resume RE-RUNS the post-create steps (7-10) from the top, each converging if already done** — this is why no per-step progress journal is needed. Step 8 (copy templates) is **OVERWRITE-FROM-TEMPLATE, not skip-if-exists**: a crash mid-write of `brief.md` leaves a truncated file, and skip-if-exists would see it present, skip, and leave the item permanently carrying a half-written brief; overwriting is safe because nothing user-authored can exist during creation. Step 10's idempotence is the existing rule above (a `sync.log` entry already bearing this `<JIRA-KEY>` + trigger is not appended twice).

     **Per-step progress journal — considered and rejected.** Every post-create step is filesystem-observable or idempotent, so a journal recovers nothing discovery cannot; and it would be a second copy of the filesystem's state that can drift — a surface asserting a state it cannot observe. (The full argument lives in the design doc, not here.)
   - `false` → skip Jira; use `#N`.
   - absent → `AskUserQuestion` "Create Jira Epic for this?" with save-default opt-in.
6. **Resolve dir name:**
   - Jira create SUCCESS → `epics/<JIRA-KEY>-<slug>/`. **Now rename the provisional branch** `<prov-branch>` created in step 3 to `<branch_prefix><JIRA-KEY>-<slug>`. Do **not** pre-check the target for collisions — that is the same check-then-use race step 3 avoids. Instead let `git branch -m` be the arbiter (it is atomic and fails when the target ref exists) and retry, keeping the worktree dir synchronized with whichever name wins. Per candidate — starting at `<branch_prefix><JIRA-KEY>-<slug>`, then `-<N>`, incrementing:
     1. `git worktree move` the worktree dir to match the candidate. **This is the failure-prone half** (a locked dir or an open file handle can fail it, especially on Windows), so it goes first: a failure here aborts with **nothing** renamed — the branch is still `<prov-branch>` and the persisted Jira key from step 5 lets a re-run resume without creating a second epic. **Distinguish the two failure kinds:** if the move fails because the destination **path already exists**, that is a *collision*, not a terminal error — advance to the next `-<N>` candidate and retry the move (the dir and branch must land on the same candidate). Lock / open-handle / permission failures stay **terminal**: abort with nothing renamed, as above.
     2. `git branch -m <prov-branch> <candidate>`. If it fails because the target ref already exists, advance to the next `-<N>` candidate and repeat from 1 (re-moving the dir to stay in sync). Any other failure: **stop and report the exact half-state** — dir moved, branch still `<prov-branch>` — do not proceed.

     (Step 3 named the branch with the key-free provisional slug because the key wasn't known yet — this is the rename step 3 defers to.)
   - Jira create OUTCOME-UNKNOWN (failed / timed out / no key returned — the create WAS issued) → **do NOT auto-file `#N`**: per **Idempotent Remote Create** step 4, keep the intent record, re-query the marker, adopt a hit, else **stop and report**. Only the operator may then choose to proceed offline → `epics/#N-<slug>/` with `pending_jira_link: true` (keep `<prov-branch>`; retain the intent record so a later `/handover jira-link` re-queries the marker and adopts a late-appearing issue rather than creating a second one, then performs the rename).
   - Jira SKIPPED — no create was ever issued (user opted out / no jira_project) → `epics/#N-<slug>/` with `pending_jira_link: false`. Safe to automate: nothing can exist remotely.
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
   - `true` → **first check the parent epic has a real Jira key.** If the parent is offline (`#N` dir / `jira` is `—` / `pending_jira_link: true`), there is no `<epic-jira-key>` to `--parent`, so do NOT emit an unparented or malformed `jira create`: fall back to the offline `#N` task path (`pending_jira_link: true`) and tell the user to `/handover jira-link <epic-id>` first if they want the task Jira-linked. When the parent HAS a key → follow **Idempotent Remote Create** in `references/resolution.md` and run `jira create --type Task --parent <epic-jira-key> --title "<name>" --desc "handover task" --labels handover-idem-<nonce>`. This creates a Jira Task linked to the parent Epic via Epic Link (NOT a Sub-task). The intent record is `<state-root>/.pending-new-item/<canonical-identity>.json`, keyed on `(<canonical-epic-identity>, type, slug)` — the parent epic pins the identity, and a task inherits its epic's source bucket so the bucket is not an independent axis here. **Canonicalize the parent BEFORE keying** (per the shared section's store contract): `<epic-id>` may arrive as `<JIRA-KEY>`, `#N`, or bare numeric for the SAME parent, so keying on the raw argument would make `123`, `#123`, and `HIMMEL-123` three identities with three nonces — and a retry invoked in a different form would miss its own marker and file a duplicate. **This step already resolves the parent** — the offline check above cannot read the parent's `jira` frontmatter without locating its dir — so key on THAT resolved identity, here, before the intent record is written. Do not defer to step 7's dir resolution: it runs *after* this gate, so the canonical identity would not yet exist at the moment the record must be committed.
   - `false` → skip Jira; use `#N`.
   - absent → `AskUserQuestion` "Create Jira Task for this?" with save-default opt-in.
5. **Derive `next_id`** for the `#N` fallback path.
6. Resolve epic dir: `<state-root>/{,<bucket>/}epics/<epic-form>-*/` matching `<epic-id>` — in an active bucket layer the epic lives under its resolved source bucket (`<state-root>/<bucket>/epics/...`, per `references/resolution.md` Bucket Resolution); fall back to the flat `<state-root>/epics/...` only when the bucket layer is inactive.
7. **Resolve dir name** (same rules as `new-epic` step 6):
   - SUCCESS → `tasks/<JIRA-KEY>-<slug>/`
   - OUTCOME-UNKNOWN (create issued, failed / timed out / no key) → **not automatic**: per **Idempotent Remote Create** step 4 — adopt a marker hit, else stop and report; only an operator choice yields `tasks/#N-<slug>/` with `pending_jira_link: true` (intent record retained for `/handover jira-link`).
   - SKIPPED (no create issued) → `tasks/#N-<slug>/` with `pending_jira_link: false`
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
   - `true` → follow **Idempotent Remote Create** in `references/resolution.md` and run `jira create --type Story --project <jira_project> --title "<name>" --desc "handover standalone" --labels handover-idem-<nonce>`. No `--parent`. The intent record is `<state-root>/.pending-new-item/<canonical-identity>.json`, keyed on `(source-bucket, type, slug)` — the same identity and contract as `new-epic` step 5, so a failure after the create resumes instead of filing a second Story.
   - `false` → skip Jira; use `#N`.
   - absent → `AskUserQuestion` with save-default opt-in.
5. **Derive `next_id`** for the `#N` fallback path.
6. **Resolve dir name** (same rules as `new-epic` step 6, including the branch rename):
   - SUCCESS → `standalones/<JIRA-KEY>-<slug>/`. Rename the provisional branch `<prov-branch>` from step 3 to `<branch_prefix><JIRA-KEY>-<slug>` using the **exact per-candidate move-then-`git branch -m` retry loop of `new-epic` step 6** — no collision pre-check (`git branch -m` is the atomic arbiter; on target-exists advance to the next `-<N>` candidate and re-move the dir to stay in sync), worktree move first so a move failure aborts with nothing renamed, and any other rename failure stops and reports the exact half-state.
   - OUTCOME-UNKNOWN (create issued, failed / timed out / no key) → **not automatic**: per **Idempotent Remote Create** step 4 — adopt a marker hit, else stop and report; only an operator choice yields `standalones/#N-<slug>/` with `pending_jira_link: true` (keep `<prov-branch>`; intent record retained for `/handover jira-link`).
   - SKIPPED (no create issued) → `standalones/#N-<slug>/` with `pending_jira_link: false`
7. Copy templates filling placeholders (v2 frontmatter):
   - `brief.md` from `standalone-brief.md`
   - `bugs.md` from `standalone-bugs.md`
   - `reviewer-notes.md` from `standalone-reviewer-notes.md`
8. Run `update-status`.
9. Append to `sync.log` (trigger=new-standalone).
10. Confirm: "Created standalone <ID> — `<name>` in repo `<name>`"
