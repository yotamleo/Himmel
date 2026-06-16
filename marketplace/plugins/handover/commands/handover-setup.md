---
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion, Skill
description: First-time handover bootstrap — asks where handover state should live, persists it to .env as HANDOVER_DIR, then runs init (new) or register (existing). Use on a fresh machine/repo before /handover new-epic etc.
argument-hint: "[handover-dir]"
---

## Your task

Bootstrap the handover system for this operator/repo. The job of this command
is the one-time **setup** the rest of the handover skill assumes is already
done: pick *where* handover state lives, persist that choice so every later
session resolves it the same way, and hand off to the skill's `init`/`register`
flow. Do **not** hardcode any specific repo (e.g. `yotam_docs`) — always ask.

### 1. Resolve the target repo root

Run `git rev-parse --git-common-dir` and take its parent — that is the primary
checkout root (`<repo-root>`), where the gitignored `.env` lives even when you
are inside a worktree. If git fails, stop and tell the user to run from inside a
git repo.

### 2. Detect whether setup already ran

Check both signals:

- **Config:** is `HANDOVER_DIR` already set in the environment, or present as an
  active (uncommented) line in `<repo-root>/.env`?
- **Registry:** does `~/.claude/handover/registry.json` already contain an entry
  whose `path` canonicalises to `<repo-root>`?

If **both** are present, report the resolved state root and stop with: "Handover
already set up for this repo (HANDOVER_DIR=<…>, registered as '<name>'). Re-run a
specific step with `/handover register` or edit `.env` manually if you need to
change the location." Do not silently re-prompt.

If only one is present, continue — you will fill the missing half.

### 3. Ask where handover state should live

If `$1` (the `handover-dir` argument) was provided, treat it as the operator's
explicit Mode-B path and skip the prompt. Otherwise ask via `AskUserQuestion`:

> **Where should handover state live?**
> - **Inline (this repo)** — state under `<repo-root>/handovers/`. Simplest; no
>   `.env` change. Best for a single-repo setup. (Mode A)
> - **External state repo** — a separate directory (typically a dedicated repo)
>   so handover commits never land on your feature branches. You'll enter the
>   path. (Mode B)

For the **External** choice, get the absolute path (the user types it via the
"Other" option or a follow-up). Expect a path ending in `/handovers` inside a
git repo, e.g. `/c/Users/<you>/Documents/github/<your-state-repo>/handovers`.

### 4. Persist the choice

- **Inline (Mode A):** nothing to write — `HANDOVER_DIR` stays unset and the
  resolver (`scripts/lib/handover-path.sh`) defaults to `<repo-root>/handovers`.
  Continue to step 5 with `<state-root-host>` = `<repo-root>`.
- **External (Mode B):** if the chosen directory does not exist yet, ask whether
  to create it (`mkdir -p`) — do not write a `HANDOVER_DIR` that points at a
  missing path. Then run the idempotent writer (this never echoes secret values,
  so it passes the secrets guard):

  ```bash
  bash <repo-root>/scripts/handover/set-handover-dir.sh "<chosen-path>"
  ```

  It creates-or-updates the `HANDOVER_DIR=` line in `<repo-root>/.env`. Confirm
  the printed `OK set-handover-dir:` line. `<state-root-host>` = the chosen path.

  Note for the current session: `.env` is read by tools at launch, so the new
  `HANDOVER_DIR` takes effect for shell scripts the next time Claude is launched
  from this repo (the loader `scripts/lib/load-dotenv.sh` picks it up); the
  skill steps below use the path directly.

### 5. Initialise or adopt the state

Resolve `<state-root>` = `<state-root-host>/<USER_SLUG>` (USER_SLUG via
`scripts/lib/user-slug.sh`; ask if it cannot be resolved).

- If `<state-root>` has no `.md` items yet → invoke the **handover** skill's
  `init` flow (`Skill` tool, handover) against `<state-root-host>` to seed
  `_templates/`, `status.md`, `roadmap.md`, and register the repo.
- If `<state-root>` already contains handover items (existing state being
  adopted) → invoke the skill's `register` flow instead (idempotent).

Pass the resolved path so the skill does not re-prompt for it. Follow the full
specs in the skill's `references/init-register.md`.

### 6. Confirm

Print a one-line summary: the mode (inline/external), the resolved `<state-root>`,
and the registered repo name. Suggest the next step: `/handover new-epic <name>`.

### Notes

- This command is the **only** place the state-root location is chosen
  interactively. Everything downstream resolves it from `.env` (Mode B) or the
  inline default (Mode A) — never a hardcoded path.
- Re-running is safe: step 2 short-circuits when setup is already complete, and
  `set-handover-dir.sh` + the skill's `register` flow are both idempotent.
