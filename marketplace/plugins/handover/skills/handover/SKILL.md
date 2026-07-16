---
name: handover
description: Use when the user says "new epic", "new task", "new standalone", "end session", "update status", "handover", "handover-resume #N", "handover bug", "log a bug", "track a bug", "fix didn't work", "handover bugs", "bug dashboard", "handover lessons", "lessons sweep", "handover init", "handover register", "handover repos", or asks to create/track work items in the handover system. Also use when wrapping up a session or resuming tracked work. Triggers on phrases like "wrap up", "session done", "start epic", "add task to #N", "handover-resume", "resume session", "register handover for <repo>".
---

# Handover System

Tracks epics, tasks, and standalones across sessions. Multi-repo capable: state lives per registered repo under `<repo-root>/handovers/<user>/`, optionally bucketed by source repo under `<repo-root>/handovers/<user>/<bucket>/` (HIMMEL-129 layout — see `references/resolution.md`).

**This SKILL.md is a thin router (HIMMEL-1041).** It carries only the op index + invariant rules. Each op's mechanics live in `references/<op>.md`, loaded on demand — so invoking one op never loads the other ~19. The read path (`handover-resume`) is fully script-driven and skips the skill entirely (HIMMEL-1038).

## Before any mutation op — load the shared substrate

**All mutation ops** resolve the **target repo** the same way and share the registry protocol, template placeholders, the No-ID picker, status values, and the file-path map — that shared substrate lives in **`references/resolution.md`**; load it first, then the op's own slice below. Most (`new-epic`, `new-task`, `new-standalone`, `end-session`, `update-status`, `bucket`, `priority`, `jira-link`, `hygiene`, `consolidate`) also resolve **bucket** and run inside the **worktree gate** before writing; **next-ID derivation** applies only to the `new-*` creation ops. `defaults` is the exception — it resolves only the target repo and writes `~/.claude/handover/registry.json` (no bucket, ID, or worktree). Read-only ops (`handover-resume`, `repos list`) skip the worktree gate.

## Commands (load the slice on demand)

### Create / update items
- **`new-epic <name>`** · **`new-task <epic-id> <name>`** · **`new-standalone <name>`** — create a tracked item (Jira auto-create gate + worktree + templates). → `references/new-item.md`
- **`update-status`** — regenerate `status.md` + `roadmap.md` + `tech-debt.md` from filesystem state; run after any mutation, never ask. → `references/update-status.md`
- **`end-session [id]`** — write the next append-only `next-session-N.md` (session summary + cold-start prompt + Jira transition); carries the overnight-mode trigger. → `references/end-session.md`

### Move / link / configure items
- **`/handover bucket <id> <bucket>`** (time-horizon OR source-repo move) · **`/handover priority <id> <priority>`** · **`/handover jira-link <id> [<key>]`** · **`/handover defaults <sub>`** → `references/item-ops.md`

### Bugs & lessons (script-backed)
- **`/handover bug <add|fix|status>`** · **`/handover bugs [--open]`** · **`/handover lessons`** → `references/bug-ops.md`

### Maintenance
- **`/handover hygiene [triage|consolidate|analyse]`** · **`/handover consolidate apply <N>`** → `references/hygiene.md`

### Resume (read-only, script-driven — no skill load)
- **`handover-resume #N`** — the `/handover-resume` command calls `scripts/handover/resume.sh` directly and does NOT load this skill (HIMMEL-1038). If reached via skill trigger: → `references/resume.md`

### Setup & registry
- **`/handover-setup`** — first-time bootstrap (Mode A inline / Mode B external state repo). Full runbook: the plugin's `commands/handover-setup.md`.
- **`/handover init`** — bootstrap a NEW target repo (no existing state). → `references/init-register.md`
- **`/handover register`** — adopt EXISTING state, idempotent. → `references/init-register.md`
- **`/handover repos <list|add|remove|where>`** — manage the repo registry (read-only reads; `list` skips the worktree gate). → `references/init-register.md`

## Critical Rules

- **Resolve target repo before any read or write.** Never assume a single repo.
- **Resolve target bucket** (HIMMEL-129) before any read or write when the bucket layer is active under `<state-root>`. Bucket layer = any **recognized source bucket** exists directly under `<state-root>` — the four built-ins `himmel/`, `luna/`, `luna_brain/`, `cross/` plus any names in the host repo's `source_buckets_extra` (HIMMEL-307). See `references/resolution.md`.
- **Scan for ID:** Never trust `counter.md` alone — always reconcile against filesystem max.
- **Worktree always:** All file writes **to the target repo's `<state-root>`** happen in a worktree of the target repo — never on `main`. The machine-global registry (`~/.claude/handover/registry.json`, written only by `defaults`/`repos`) is not a target-repo write, so it needs no worktree (see the op index above).
- **context.md ≤1 page.**
- **Templates are canonical:** Never modify `<state-root>/_templates/` files via mutation commands. Copy and fill.
- **status.md auto-generated.** Always regenerate via `update-status`.
- **Slugs:** lowercase, hyphens, ≤30 chars. `#` prefix is part of dir name.
- **Session files append-only.**

## Capturing Human Feedback

When user gives feedback on work during chat, capture it to the relevant `reviewer-notes.md` under `## Human Feedback`. Proactively — don't wait to be asked. Resolves under the **target repo** of the work being reviewed.

## Capturing Bug Fixes

When a fix is attempted during debugging and **fails**, append it to the active item's bug before moving on — proactively, don't wait to be asked: `/handover bug fix <BUG-n> FAILED "<what you tried + why it failed>"` (or `bug add "<symptom>"` first if the bug isn't tracked yet). When a fix works, record `WORKED` and set status `resolved`. This `Fixes tried` FAILED/WORKED ledger is the circular-debugging breaker — it stops a later session (or a post-compaction you) from re-trying a fix that already failed. Resolves under the **target repo** of the work being debugged (same resolver as Human Feedback).

## References (load on demand)

- `references/resolution.md` — shared substrate: repo/bucket/registry resolution, ID derivation, worktree gate, template placeholders, No-ID picker, status values, supplementary files, file-path map
- `references/new-item.md` — `new-epic` / `new-task` / `new-standalone`
- `references/update-status.md` — `update-status` + roadmap.md / tech-debt.md generation
- `references/end-session.md` — `end-session` + cold-start format + overnight mode
- `references/item-ops.md` — `bucket` / `priority` / `jira-link` / `defaults`
- `references/bug-ops.md` — `bug` / `bugs` / `lessons`
- `references/resume.md` — `handover-resume` (script-driven via `scripts/handover/resume.sh`)
- `references/routing.md` — full resolution algorithm, canonicalisation, edge cases
- `references/init-register.md` — full specs for `init`, `register`, `repos`; registry schema + defaults keys
- `references/buckets.md` — WIP context-detection rule + bucket vocab
- `references/hygiene.md` — stale tiers, lingering detection, triage/consolidate/analyse + `hygiene`/`consolidate` op flow
- `references/sync.md` — bidirectional Jira sync
- `references/v2-schema.md` — v2 frontmatter schema
