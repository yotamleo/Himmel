# handover

Cross-session, multi-repo work tracking for Claude Code. Epics, tasks, and
standalones survive session boundaries as plain markdown under each repo, so
work compounds instead of being re-explained every session.

## What it does

The handover system gives Claude a durable, file-based record of in-flight
work. State lives **per registered repo** under `<repo-root>/handovers/<user>/`,
optionally split into per-source-repo buckets. Every command resolves a
**target repo** (from the current working directory, a conversation alias, or a
prompt) before reading or writing, so one registry can drive many repos.

Three item types:

- **Epic** — a multi-task body of work (`epics/<id>-<slug>/` with `master-plan.md`,
  `context.md`, a `tasks/` tree).
- **Task** — a unit inside an epic (`tasks/<id>-<slug>/` with `brief.md`,
  `bugs.md`, `reviewer-notes.md`).
- **Standalone** — a one-off not under any epic (`standalones/<id>-<slug>/`).

IDs are **Jira-keyed by default** (`HIMMEL-42-<slug>`) when a Jira project is
registered, falling back to a repo-wide running `#N` when offline. Cross-bucket
counters never collide — the counter scope is `<state-root>`-wide, never
per-bucket (HIMMEL-129).

## Install

Ships as part of himmel's marketplace. With the marketplace registered:

```
/plugin install handover
```

The skill triggers on natural phrases ("new epic", "new task", "end session",
"handover-resume", "register handover for <repo>") — no slash command required,
though the himmel repo also wires explicit `/handover *` commands.

## Commands

| Command | Purpose |
|---|---|
| `/handover-setup` | **First-time bootstrap.** Asks where handover state should live (inline vs an external state repo), persists a Mode-B choice to `.env` as `HANDOVER_DIR`, then runs `init`/`register`. No hardcoded repo. |
| `/handover init` | Bootstrap a **new** repo (no existing state). Seeds `_templates/`, `status.md`, `roadmap.md`, registers in the registry. |
| `/handover register` | Adopt **existing** state in a repo (idempotent — scans for `#N` dirs, derives the next ID, detects duplicates). |
| `/handover repos <list\|add\|remove\|where>` | Manage the repo registry (read-only `list`/`where`; `add`/`remove` touch the registry only, never repo files). |
| `new-epic <name>` | Create an epic. Resolves source + time-horizon bucket, opens a worktree, optionally auto-creates the Jira Epic. |
| `new-task <epic-id> <name>` | Create a task inside an epic (inherits the epic's source bucket; optional Jira Task linked via Epic Link). |
| `new-standalone <name>` | Create a standalone (optional Jira Story). |
| `update-status` | Regenerate `status.md` + `roadmap.md` + `tech-debt.md` from filesystem state. Run after any mutation. |
| `handover-resume #N` (or `/handover-resume [ID] [overnight]`) | Resume a tracked item — surface its brief, decisions, and stop-point. Read-only (no worktree gate). Forms: **no ID** → picker over active items; **`#N`/`HIMMEL-N`/bare number** → that item; append **`overnight`** → overnight-mode trigger. The `/handover-resume` slash command is a token-lean wrapper for this op (≡ "load #N"); distinct from `/handover-resume-armed`, which recovers an interrupted/armed session. |
| `/handover bug <add\|fix\|status>` | Quick-add / update a bug in the active item's `bugs.md` (status + FAILED/WORKED fixes-tried). The circular-debugging breaker. |
| `/handover bugs [--open]` | Cross-item dashboard of every tracked bug (item / id / status / symptom / #fixes + totals). Read-only. |
| `/handover lessons` | Proposal-only sweep: recurring resolved-bug symptoms + CR findings as lesson candidates. Writes nothing. |
| `end-session [id]` | Consolidate session work into a `next-session-N.md` snapshot for the named item. |
| `/handover bucket <id> <bucket>` | Move an item between source buckets (HIMMEL-307). |
| `/handover priority <id> <priority>` | Set an item's priority. |
| `/handover jira-link <id> [<key>]` | Link (or relink) an item to a Jira key. |
| `/handover defaults <subcommand>` | Inspect / set / clear per-repo prompt defaults (Jira auto-create, slug style, bucket). |
| `/handover hygiene [mode]` | Surface stale / orphaned / duplicate items for cleanup. |
| `/handover consolidate apply <N>` | Apply a consolidation across `handover/*` branches. |

## State layout

```
<repo-root>/handovers/<user>/        # <state-root>
  status.md  roadmap.md  backlog.md  tech-debt.md  counter.md  sync.log
  _templates/                        # seeded from the plugin on init
  epics/<id>-<slug>/
    master-plan.md  context.md
    tasks/<id>-<slug>/{brief,bugs,reviewer-notes}.md
  standalones/<id>-<slug>/{brief,bugs,reviewer-notes}.md
```

When a **bucket layer** is active (any recognized source-bucket dir exists
directly under `<state-root>`), `epics/` and `standalones/` live one level
deeper under `<bucket>/` (e.g. `himmel/`, `luna/`, `cross/`). Top-level index
files (`status.md`, `roadmap.md`, …) stay at the state-root root. Backwards
compatible — with no bucket dirs, the resolver walks the flat layout.

## Registry

A single JSON file at `~/.claude/handover/registry.json`, written atomically
(tmp + rename on the same volume):

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

Managed by `init` / `register` / `repos` — **do not edit by hand**. v2 fields
(`bucket_vocab`, `buckets_custom`, `defaults`, `stale_thresholds_days`,
`source_buckets_extra`) are optional; absence means "use the built-in default".

## Worktree gate

All **mutation** commands (`new-epic`, `new-task`, `new-standalone`,
`end-session`, `update-status`) must run inside a git worktree of the target
repo — never on `main`. The skill enters an existing unmerged
`handover/<slug>` branch or creates a fresh one off latest `main`. Read-only
commands (`handover-resume`, `repos list`) skip the gate.

## Reference

- Full algorithm + canonicalisation rules: `skills/handover/references/routing.md`
- v2 schema + key reference: `skills/handover/references/v2-schema.md`,
  `skills/handover/references/init-register.md`
- Templates: `templates/` (epic / task / standalone / roadmap / tech-debt)
- v1→v2 migration: `scripts/migrate-v1-to-v2.sh`
