# Handover — Shared Resolution Substrate

Load this **first** for any mutation op (`new-epic`, `new-task`, `new-standalone`, `end-session`, `update-status`, `bucket`, `priority`, `jira-link`, `defaults`, `hygiene`, `consolidate`). It holds the repo → bucket → ID → worktree resolution every write depends on, plus the registry protocol, template placeholders, the No-ID picker, status values, and the file-path map. The op's own slice (`references/<op>.md`) references sections here by name.

## Target Repo Resolution

Every command resolves a **target repo** before reading or writing state. Order:

1. **CWD match (primary).** Run `git -C <cwd> rev-parse --path-format=absolute --git-common-dir`. Take its parent directory (handles worktrees AND regular checkouts — `--path-format=absolute` returns an absolute path either way, so the parent is always the main repo root). Canonicalise (lowercase drive on Windows, forward slashes, `$HOME` expansion). Compare against canonical `path` of each entry in `~/.claude/handover/registry.json`. Exact match wins.
2. **Conversation alias (fallback).** Only if step 1 produces no match. Scan recent user turns for any registered alias or keyword (case-insensitive substring). Unambiguous hit → use it.
3. **Ambiguous or none → prompt** via `AskUserQuestion`. No session cache — always prompt when ambiguous, every invocation. (If `AskUserQuestion` is unavailable — non-Claude harness, e.g. Codex — ask the same question as plain text and route on the typed answer; never silently pick a repo.)

Once resolved, `<repo-root>` = registry path, `<state-root>` = `<repo-root>/handovers/<user>/` (user from registry).

Read-only commands (`handover-resume`, `repos list`) skip step 3 if the user clearly intends a specific repo from context. `update-status` may **likewise skip the step-3 disambiguation prompt** when the target repo is unambiguous — but it is a **mutation** (it writes `status.md` / `roadmap.md` / `tech-debt.md`), so it still runs inside the **Worktree Gate** section below. Skipping the *repo prompt* ≠ skipping the *worktree gate*; keep these distinct.

Full algorithm + canonicalisation rules: `references/routing.md` (load only on ambiguity or first invocation in a new session).

## Bucket Resolution (HIMMEL-129)

Some registered repos — the **state-root host** an operator chose at `/handover-setup` (e.g. a repo named `<state-repo>`) — split `<state-root>` into per-source-repo buckets to keep work from multiple code repos disambiguated:

```text
<state-root>/
  himmel/{epics,standalones}/
  luna/{epics,standalones}/
  luna_brain/{epics,standalones}/
  cross/{epics,standalones}/      # cross-repo work; no Jira prefix
  <extra>/{epics,standalones}/    # e.g. salus/ — extra source bucket (HIMMEL-307); explicit-only, no Jira-prefix route
```

A bucket layer is active when **any recognized source bucket** dir exists directly under `<state-root>`. The **recognized source-bucket set** is the four built-ins `himmel/`, `luna/`, `luna_brain/`, `cross/` **plus** any names listed in the state-root host repo's `source_buckets_extra` registry field (HIMMEL-307). When `source_buckets_extra` is absent or empty, the recognized set is exactly the four built-ins, so behaviour is byte-identical to the pre-HIMMEL-307 4-set. Wherever this skill says "active bucket" / "every `<state-root>/<bucket>/`" (ID derivation, `update-status`, roadmap, `handover-resume`, the No-ID picker), `<bucket>` ranges over the **recognized** set — extra buckets are walked automatically. In an active layer, every read/write resolves `<bucket>` first:

1. **Ticket-prefix rule (primary).** If the item carries a Jira key, map prefix → bucket via the registry's `bucket_name` field (HIMMEL-147). Default mappings carry over from HIMMEL-129: `HIMMEL-*` → `himmel/`, `LUNA-*` → `luna/`, `LUNA-BRAIN-*` → `luna_brain/`. **Match the most-specific (longest) prefix first** — `LUNA-BRAIN-123` must route to `luna_brain/`, never to `luna/` on the shorter `LUNA-` match; regardless of listing order, the longest matching registered prefix wins. No-prefix or unmapped prefix → `cross/`. Operators with forked repos override per-entry by setting `bucket_name` in registry.json. The prefix rule only ever resolves to one of the **four built-in** buckets — it never auto-routes to an extra bucket (see rule 3).
2. **No Jira key (offline-fallback `#N`).** Use the source-repo registry `bucket_name` (HIMMEL-147; defaults to slugified `basename(path)`) where the slash command was invoked. If the source repo is the state-root host itself (no obvious bucket), prompt via `AskUserQuestion` listing the active buckets — which includes any recognized extra buckets.
3. **Extra source buckets are explicit-only (HIMMEL-307).** Names in `source_buckets_extra` get **no** Jira-prefix auto-route — an item lands in one only by an explicit operator choice: the source-bucket step in `new-epic`/`new-standalone` (offered only when extra buckets exist), or an explicit `/handover bucket <id> <extra>` move. Rationale: an extra bucket like `salus` carries `LUNA-*` tickets that would otherwise collide with `luna/` under the prefix rule, so it must never silently capture prefix-routed work. Once an item lives in an extra bucket, all scans/regens walk it like any built-in bucket (see the recognized-set note above).
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

**Allocate `#N` by attempting creation, not by trusting the scan.** For a setup with no external ticket system, `#N` *is* the ticket ID — so it gets the same treatment as provisional branch allocation (`references/new-item.md` step 3): the scan above is a *proposal*, not a reservation. Two runs scanning concurrently both compute the same `max + 1` and would both claim it. Instead create the item dir with an operation that **fails when the path already exists** (`mkdir` without `-p`, which is atomic) and let that be the arbiter. Never pre-check with a "does `#N-*` exist?" test and then create — that is the same check-then-use race, and here it silently produces two different items sharing one ID.

**On a collision, identity-check before re-deriving** (same rule as `references/hygiene.md`'s move-skip): a collision does not by itself mean the ID is taken by someone else. `mkdir` can succeed and the run then die before templates / `update-status` / `sync.log`, leaving this run's **own partial item** behind.
- Existing `#N-<slug>` holds **this** item (identity match on `<slug>` + type) → it is a resumable partial from an earlier attempt: **adopt it and resume the remaining post-create steps.** Do NOT re-derive — that strands the partial and creates a duplicate under a fresh ID.
- Existing `#N-*` holds an **unrelated** item → the ID really is taken: re-derive `next_id` and retry.

A stronger form (reserving IDs in their own atomic namespace, independent of the item dir) is tracked in **HIMMEL-1068**; the identity-check above is what keeps the common crash-and-retry case correct without it.

If `<state-root>/counter.md` exists with `Next: K` where `K > max(all N) + 1`, prefer K (preserves in-flight increments that haven't reached disk yet).

## Worktree Gate

**Every target-repo mutation** must run inside a git worktree of the **target repo** — never on `main`. This covers **all** ops that write under `<state-root>`: `new-epic`, `new-task`, `new-standalone`, `end-session`, `update-status`, `bucket`, `priority`, `jira-link`, `hygiene` (when triage applies a verdict), and `consolidate apply`. The only exceptions are the **registry-only** ops `defaults` and `repos add/remove`, which write `~/.claude/handover/registry.json` (not a target-repo write) and so need no worktree.

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

## Idempotent Remote Create

**The trigger is the CALL, not this list: any flow that runs `jira create` follows this section — no exceptions.** The known call sites today are `new-epic`, `new-standalone`, `new-task` (`references/new-item.md`), "promote A+B+C to new epic" (`references/hygiene.md`), and `jira-link` (`references/item-ops.md`) — but a list of call sites cannot know what it omits, so treat the rule as the authority and this enumeration as a convenience. Adding a `jira create` anywhere without this protocol is the defect; if you find a call site missing from this list, the list is wrong, not the call site. It applies ONLY to the external-ticket path. The `#N` path needs no marker and gets none — there is no remote create, so there is no window; its ID is derived locally and re-derived on retry, and its own allocation hazard is already handled by ID Derivation's atomic-`mkdir`-with-retry rule. Do NOT modify the ID Derivation rules.

`jira create` is a **non-idempotent call to a remote system**. Every flow that runs it records the created key AFTER the create returns — "the instant it is created" / "immediately". A crash BETWEEN the create landing and the record being written leaves an issue in Jira that nothing local knows about, and the retry files a **duplicate**. Recording the key *sooner* does not close the window: a local write and a remote create can never be made atomic, so the instant of recording is always after the instant of creation. **Recording the marker BEFORE the create does close it.** That distinction — sooner vs before — is the entire mechanism, and the thing a future reader must not lose.

The six-step ordering:

1. **Mint a nonce**, once, per creation attempt-set. Pin the command verbatim — this protocol is executed by an LLM following prose, so "a short random value" is not a specification: two sessions that improvise differently (sha256 vs md5, different truncation) produce different labels, the lookup misses, and the protocol files the very duplicate it exists to prevent.
   ```sh
   nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')   # 16 lowercase hex chars
   ```
   Lowercase hex moots JQL label case-sensitivity and fits Jira's label constraints (no spaces, <=255 chars). A resume **reads** the nonce from the record; it NEVER re-mints one.
2. **Write the intent record BEFORE the create** — `<state-root>/.pending-new-item/<canonical-identity>.json` (`<state-root>/.pending-consolidate/<canonical-identity>.json` for promote), carrying `idem_nonce: <nonce>` as a field. A record that exists but carries no key means "an attempt was made, outcome unknown" — the signal that distinguishes "never created" from "created but not yet indexed".

   **The store contract — the ordering only works if the record survives, so specify the store, not just the write:**
   - **ONE FILE PER IDENTITY in a directory — never one shared file, and never a map inside one file.** The identity is the FILENAME. This is the whole reason the store is a directory: a shared file (whether it holds one record or a map of them) has to be read-modify-written, and a RMW of a shared file loses updates — two unrelated flows read the same map, each adds its own entry, each renames its version over the other, and the last writer silently deletes the first flow's nonce. Its retry then discovers nothing and files a duplicate. **Atomic replacement prevents torn JSON; it does not prevent lost updates** — those are different problems, and only removing the shared mutable state solves the second. With one file per identity there is no shared state to lose: a write touches exactly its own path, and a clear removes exactly its own path. (This also needs no lock, which is why the concurrency boundary below still holds.)
   - **Write it atomically and durably: serialize the record, write a temp file in the same dir, flush it, `rename` it into place, then `fsync` the PARENT DIRECTORY.** Ordering alone is not durability — a buffered write that has not reached disk when the process dies is a record that never existed, and a rename whose directory entry hasn't itself been fsynced can vanish on crash even though the file's contents landed, and *either* failure is what would break the invariant below and duplicate the ticket. The write must be **committed** — file contents AND the directory entry — before `jira create` is issued, not merely issued before it. (Same atomic temp-then-rename convention the rest of the harness uses for state files; it also makes a torn/partial JSON record unrepresentable.)
   - **Canonicalize the identity before keying on it.** An identity is only stable if two invocations of the same intent produce the same key. Resolve every reference to its canonical form FIRST — `new-task` accepts `<JIRA-KEY>`, `#N`, *or* bare numeric for the same parent, so keying on the raw argument makes `123`, `#123`, and `HIMMEL-123` three different identities, three different nonces, and a retry that misses its own marker. Key on the resolved epic's canonical identity (its dir / Jira key), not on what the operator typed.
   - **The promote intent record does NOT share `.last-consolidate.json`.** That file is the suggestion cache — step 1 reads it back to resolve `<N>` — so multiplexing the intent record through it lets either write destroy the other's state (lose the suggestion and `apply <N>` cannot resolve; lose the nonce and the retry duplicates the epic). Keep the cache and the intent store as separate files with separate lifetimes.
3. **Look up the marker** — `jira list --jql 'project = <key> AND labels = "handover-idem-<nonce>"'` — and apply the verdict table below. **Whether "empty" may be read as "absent" depends entirely on whether an attempt could already have been issued, and the intent record is what tells you:**
   - **FIRST entry (no pre-existing record)** — no attempt has been made, so nothing can exist to find. Empty means absent, immediately. **This is the common path and it never waits.**
   - **RESUME (the record already existed on entry)** — an attempt *may* have been issued and its outcome is unknown. Re-query with a short backoff (a handful of attempts over ~10s) to give the index a chance to reveal a hit. **If it is still empty when the budget expires, STOP AND REPORT — do NOT create.** The lookup reads Jira's SEARCH INDEX (`GET /search/jql`), not the issue store, and that index is eventually consistent with **no documented upper bound**. A bounded wait can therefore reveal a hit, but it can never *prove* absence — so treating budget-expiry as "absent" and creating would be inferring a fact from a timer. That is the one place this protocol could let uncertainty read as green, and it is closed: an unresolved outcome is a state to inspect, not to create through. Creating there risks a second issue carrying the SAME marker, after which every later lookup returns `> 1` and fail-closes — turning a one-time duplicate into a stuck identity needing manual reconciliation.

   Note the asymmetry is deliberate: the cost of stopping is a rare manual check (the ambiguous state needs a crash inside the millisecond window between the record committing and the create being issued, *or* index lag beyond the budget — both rare); the cost of guessing is a duplicate remote ticket. Rare × safe beats rare × unrecoverable.
4. **Create with the marker** — `jira create --labels handover-idem-<nonce> …`. The label is part of the create PAYLOAD, so the issue is created WITH its marker or not at all — there is no window in which the issue exists but is unfindable.

   **A failed create is OUTCOME-UNKNOWN, not "did not happen" — it must NEVER fall through to the offline `#N` path on its own.** A timeout, a dropped connection, or any non-zero exit can be returned *after* Jira already accepted the request, so a create that reports failure may well have landed. Auto-filing a local `#N` item there strands a real, marked remote issue against local state committed under a *different* identity — split state a later retry can then "adopt" into. This is also the **worst** place to trust an empty lookup: the attempt was seconds ago, so index lag is at its most likely.

   So on ANY failed / timed-out / key-less create response: **keep the intent record and re-query the marker**, then let the verdict table decide — a hit is **adopted**; an unresolved outcome **stops and reports**.

   **The two `#N` paths are not the same thing, and only one is automatic:**
   - **SKIPPED — no create was ever issued** (the gate is `false`, the operator opted out, or there is no `jira_project`): `#N` with `pending_jira_link: false`. Automatic and safe — nothing can exist remotely.
   - **OUTCOME-UNKNOWN — a create was issued and its result is unknown:** never automatic. Stop and report. From there the *operator* may choose to proceed offline (`#N` with `pending_jira_link: true`), and when they do, **retain the intent record** so a later `/handover jira-link` re-queries the marker and **adopts** a late-appearing issue instead of creating a second one.

   The distinction is the point: the machine will not infer "no ticket exists" from a failure it cannot interpret, but a human who has checked Jira may decide, and the record keeps that decision recoverable.
5. **Run the flow's post-create steps — a resume RE-RUNS them from the top and each must CONVERGE.** This is what makes the per-step progress journal unnecessary: every post-create step is filesystem-observable, so a resume re-derives its state instead of trusting a record. The convergence rules are the same for EVERY flow this section covers (`new-epic`, `new-standalone`, `new-task`, `promote`) — a flow does not get to be the exception, and where a flow names its own steps it inherits these:
   - **Item dir** — adopt an existing dir only on an **identity match** (it holds the expected `<ID>-<slug>`); an unrelated item at that path is a collision → stop and report.
   - **Templates** — **OVERWRITE from template, never skip-if-exists.** A crash mid-write leaves a truncated `brief.md`; skip-if-exists would see it present, skip, and leave the item permanently carrying a half-written file. Overwriting is safe because nothing user-authored can exist during creation.
   - **Index / context / log edits** (a parent epic's Task Index row, `context.md` state, `sync.log`) — **deduplicate on re-run**: an entry already bearing this `<ID>` / `<JIRA-KEY>` + trigger is not appended twice. Re-running must not double-write a row.
   - **Finalization** — a resume that finds every post-create step already done is a **clear-only** finalization: clear the intent record and stop. Losing the key is the expensive failure; a redundant clear costs nothing.
6. **Clear the intent record** only after EVERY post-create step has succeeded.

**The load-bearing invariant, stated precisely — it is about what is OUTSTANDING, never about what exists remotely:**

> For any nonce, **if a create was issued carrying it, a record for it was durably committed first** (step 2's atomic temp-then-rename, flushed, before step 4). So a record for an **unfinished** attempt is never missing: the only thing that removes one is step 6's deliberate clear, which runs only after that create is fully accounted for. Therefore **no live record ⇒ nothing is outstanding**, and a freshly minted nonce — which no record and no issue has ever carried — may be created under safely.

**Scope it to a LIVE, non-retired record, and never read it as a claim about the remote.** "No record ⇒ no issue exists" is **false for every completed flow**: step 6 clears the record precisely on success, while the issue carrying that nonce remains forever. What step 6 retires is a nonce whose work is *done*, not one whose issue vanished. Recovery never needs the wider claim, because it only ever looks up a nonce it read **from a live record** — with no record there is no nonce to look up, so the flow mints a fresh one and starts clean.

Keep the two apart, because conflating them is how a duplicate gets filed:
- **"no pending record"** → nothing is outstanding → safe to mint and create.
- **"no remote issue"** → a claim this protocol makes **only** from a lookup verdict, and never from a record's absence.

Note also what it rests on: the invariant is a consequence of step 2's *durability*, not of its *ordering*. Write the record non-durably and the guarantee inverts — the create lands, the buffered record dies with the process, and the retry files exactly the duplicate this protocol exists to prevent.

The verdict table:

**A zero-result lookup means different things depending on whether a create could already have been issued for this nonce, so the table keys on that — and ONLY that.**

The state is **not** "how the invocation started"; it is **"has a create been issued for this nonce?"** — and it **transitions the moment you issue one**:
- **PRE-CREATE** — no record existed on entry *and* you have not yet issued a create in this invocation. Nothing can exist remotely under this nonce.
- **POST-ATTEMPT** — a record already existed on entry, **OR** you have issued a create in this invocation (however it returned). Once you issue, you are POST-ATTEMPT for the rest of the invocation. There is no path back to PRE-CREATE.

| CLI rc | state | results | verdict |
|---|---|---|---|
| != 0 | any | — | **MISSING signal — stop and report.** Never "absent". |
| 0 | **PRE-CREATE** | 0 | absent — no create was issued → **create now** |
| 0 | **POST-ATTEMPT** | 0, still empty after the step-3 backoff | **AMBIGUOUS — stop and report. NEVER create.** |
| 0 | any | 1 | **adopt that key; skip the create** |
| 0 | any | > 1 | ambiguous → **stop and report**; never pick |

**The PRE-CREATE row applies to the pre-create lookup ONLY.** Keying it on how the *invocation* began is a trap that has already been caught once: a first run whose create timed out would re-query, still call itself "first", match the zero-result row, and **issue a second create** — the exact duplicate this protocol exists to prevent, produced by the protocol's own table. Issuing the create is what moves you to POST-ATTEMPT, so **every post-attempt zero result stops, regardless of how the invocation began.**

There is deliberately **no unconditional zero-result → create row**. That row is what made an earlier draft contradict itself: prose said a resume must stop, the table said create, and prose this specific drives an LLM — which would follow the table, create a second issue carrying the same marker during index lag, and wedge every later lookup at `> 1`.

**Stop-and-report is recoverable, and must not wedge the flow.** Report the nonce and the exact JQL so the operator can check Jira directly. If they confirm no such issue exists, **clearing the intent record returns the flow to a FIRST entry** and the next run creates cleanly. That clear is the deliberate human judgement this protocol refuses to infer from a timer — the machine will not guess, but it must never trap the operator either.

The `rc != 0` row is the point of the table. A broken or 5xx query prints an error and returns no issues — indistinguishable, to a careless reader, from "no issue exists" — and concluding "absent" there files the duplicate. **When a check returns "nothing", prove the check ran.** (Verified: a malformed JQL exits 1.)

**Why the nonce is NOT a hash of the item's identity.** A label is permanent; the local record is cleared on success. An identity-keyed marker would therefore make the create idempotent FOREVER, not just for one in-flight creation. The operator legitimately files a second standalone with the same name in the same bucket months later; its lookup would find the FIRST issue's label, adopt its Jira key, and refuse to file the legitimate new ticket — silently binding the new item to the old, closed item's ticket. A per-attempt nonce has no afterlife: once the record is cleared the old marker is inert. The IDENTITY keys the RECORD (so a retry finds it across renames); the NONCE keys the MARKER (so it cannot go sticky). They are not the same thing.

**Bounded scope — concurrency is neither prevented nor detected, and this protocol does not improve it.** Two concurrent runs on the same identity each mint their own nonce, each looks up a marker no issue carries, each creates, and the two issues carry DIFFERENT markers — no later lookup ever returns >1. Both finish green with two tickets. Preventing the race needs cross-process locking, which is out of scope by decision, not omission — tracked as **HIMMEL-1132**. The `> 1` row survives only as a defensive canary for genuine marker reuse (a nonce collision, a hand-copied record), NOT as a concurrency story.

**Residuals:**
- `jira edit --labels` is FULL-REPLACE (it sets, not appends). Any label edit on an issue between its create and its record-clear silently strips the marker and strands the intent record.
- **Promote set-drift:** if the operator re-runs `/handover hygiene consolidate` (regenerating suggestions) instead of `apply <N>` after a failed apply, and the source set has changed (e.g. C closed), the identity genuinely changed → a different record → the nonce is never consulted → duplicate epic. Not solvable by this protocol. Mitigation is procedural: re-run `apply <N>`, not `consolidate`, to resume a failed apply.

## No-ID picker flow

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

## Status Values

**Active** (picker shows): `not-started` | `in-progress` | `pending` | `planned` | `blocked`
**Inactive** (picker skips): `done` | `dropped` | `deferred`

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

```text
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
      <extra>/                           ← e.g. salus/ — source_buckets_extra (HIMMEL-307); explicit-only, no Jira-prefix route
        epics/...
        standalones/...
```

Registry (machine-global, not per-repo):

```text
~/.claude/handover/
  registry.json                          ← repo registry, atomic writes
```
