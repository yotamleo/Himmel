# Updating himmel

**TL;DR — `git pull` your himmel checkout. Marketplace `autoUpdate` does NOT
deliver himmel updates on its own.** Run `/update` (or `bash scripts/update.sh`)
to do the pull + marketplace re-sync in one step.

## Why a pull is required

himmel ships as two delivery layers, and only one of them is a "plugin":

| Surface | Where it lives | Updated by |
|---------|----------------|------------|
| Core hooks (`scripts/hooks/*`) | your checkout, run from `$CLAUDE_PROJECT_DIR` | **`git pull`** |
| Slash commands (`.claude/commands/*`) | your checkout | **`git pull`** |
| `settings.json` wiring, `scripts/*`, `CLAUDE.md`, docs | your checkout | **`git pull`** |
| himmel plugins (`marketplace/plugins/*`) | your checkout, sourced `./plugins/*` | see below |
| Vendored plugins (`claude-obsidian`, `obsidian`) | GitHub, **SHA-pinned** | only when the pin is bumped (= a `git pull`) |

The hooks and commands are **not plugins** — they execute out of your repo
checkout, so nothing but a pull changes them.

The himmel *plugins* depend on **how the marketplace was registered**:

- **Default setup** ([`settings-template.json`](settings-template.json)) registers
  the marketplace from a local **`directory`** source
  (`path: <himmel-path>/marketplace`) with `autoUpdate: true`. A directory source
  has nothing to fetch over the network — `autoUpdate` only **re-syncs plugins
  from the on-disk dir**, which changes only when you `git pull`. So with the
  default setup, **everything is pull-gated**, plugins included.
- **Direct-install path** (`claude plugin marketplace add yotamleo/himmel`) uses a
  **github** source. There `autoUpdate` pulls a separate Claude-managed clone from
  GitHub, so *plugin* updates arrive without pulling your working checkout — but
  the core hooks and commands still run from your checkout and **still need a
  pull**.

Either way: **a `git pull` is required for the full update; `autoUpdate` never
covers the core hooks.**

## How to update

```bash
/update                 # inside Claude Code
# or
bash scripts/update.sh  # from a shell, in the himmel checkout
```

`scripts/update.sh`:
1. `git pull --ff-only` (fails loudly if your branch has diverged from upstream
   or local edits block the update — reconcile manually, updates land on the
   default branch).
2. `claude plugin marketplace update himmel` — refresh plugins from the
   freshly-pulled local dir.

Plain `git pull` works too if you don't need the marketplace re-sync.

## When changes take effect

- **Hooks**: immediately on the next tool call — PreToolUse/etc. re-read the
  script from disk each invocation. (This is why the [HIMMEL-392] hook fix needs
  only a pull, no restart.)
- **Plugins / slash commands / skills**: loaded at session start — **restart**
  any running Claude session to pick them up.

## Notes

- **On a feature branch?** A pull lands updates on the default branch; merge or
  rebase it into your branch as you would any upstream change. The hook files
  resolve from `$CLAUDE_PROJECT_DIR`, so the updated file is on disk as long as
  the default branch is checked out at pull time.
- **Forked `yotamleo/Himmel`** instead of cloning it directly? Add an `upstream`
  remote and `git pull upstream main` — a plain `git pull origin` only pulls your
  fork.
- Whether the *default* registration should switch to a github (floating) source
  so plugins auto-deliver without a pull is tracked as a deliberate trade-off in
  HIMMEL-398 (it would leave the core hooks pull-only regardless).
