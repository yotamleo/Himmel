# Handover — bug / lessons ops (`bug` / `bugs` / `lessons`)

All three are backed by scripts under `scripts/handover/`; run each by absolute path from the repo root. Read `references/resolution.md` only if you need to resolve the target repo (the scripts resolve it themselves).

## `/handover bug <add|fix|status>`

Quick-add / update a bug in the **active item's** `bugs.md` (resolved from the
current branch's ticket via `<repo-root>/scripts/handover/resolve-active-item.sh`
— C1; if it exits **3**, there's no active handover item — say so and stop. Any
other non-zero exit is a resolver error — report it and stop, don't treat it as
"no item"). Backed by `<repo-root>/scripts/handover/bug.sh`. Run by absolute path
from the repo root.

- `add "<symptom>"` → `bug.sh add --bugs <item>/bugs.md --symptom "<symptom>"`. Echoes the new `BUG-<n>` id.
- `fix <BUG-n> <FAILED|WORKED> "<note>"` → `bug.sh fix --bugs <item>/bugs.md --id <BUG-n> --outcome <FAILED|WORKED> --note "<note>"`. Records a fix attempt under `Fixes tried:`.
- `status <BUG-n> <open|fixing|resolved|wontfix>` → `bug.sh status --bugs <item>/bugs.md --id <BUG-n> --to <status>`.

Resolve `<item>` once: `item="$(bash <repo-root>/scripts/handover/resolve-active-item.sh)"` (exit 3 → no active item → skip with a one-line note; any other non-zero → resolver error → report and stop). The bug id is per-item sequential and stable.

## `/handover bugs [--open]`

Cross-item **dashboard** of every tracked bug (read-only). Renders a markdown
table (Item / Bug / Status / Symptom / #Fixes) across all `bugs.md` under the
handover root, with totals. `--open` restricts to `open`/`fixing`. Backed by
`<repo-root>/scripts/handover/bugs-dashboard.sh`; run by absolute path from the repo root:

```bash
bash <repo-root>/scripts/handover/bugs-dashboard.sh [--open]
```

No active-item resolve needed — it aggregates the whole root. Prints
`_No bugs tracked._` when clean (`_No open bugs tracked._` under `--open`).

## `/handover lessons`

Proposal-only **lessons sweep** (read-only, writes nothing). Surfaces symptoms
of `resolved`/`wontfix` bugs and CR-finding titles that recur across ≥2 items
as lesson **candidates**, followed by a full digest. The operator promotes
what's worth keeping — there is no auto-write to the vault or `CLAUDE.md`.
Backed by `<repo-root>/scripts/handover/lessons-sweep.sh`:

```bash
bash <repo-root>/scripts/handover/lessons-sweep.sh
```
