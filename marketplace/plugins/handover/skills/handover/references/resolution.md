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
