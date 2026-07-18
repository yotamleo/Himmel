# Updating himmel

**TL;DR — `git pull` your himmel checkout. Marketplace `autoUpdate` does NOT
deliver himmel updates on its own.** Run `/himmel-update` (or `bash
scripts/himmel-update.sh`) to do the pull + marketplace re-sync in one step.

> This updates the himmel **harness**. A configured `LUNA_VAULT_PATH` is
> already refreshed by `/himmel-update`'s own dependency chain (step 6,
> below) — reserve
> [`/luna-upgrade`](../../marketplace/plugins/obsidian-triage/skills/luna-upgrade/SKILL.md)
> for an **explicit**, Luna-only run, and `/himmel-update-all` for running
> both the harness and the vault update together deliberately. To bring
> **multiple** luna-family vaults up to the current template in one pass, use
> [`/luna-upgrade-all`](../../marketplace/plugins/obsidian-triage/skills/luna-upgrade-all/SKILL.md)
> (see [Updating multiple vaults](#updating-multiple-luna-vaults) below).

## Updating multiple luna vaults

If you keep more than one luna-family vault (e.g. a personal vault plus a
work vault), [`/luna-upgrade-all`](../../marketplace/plugins/obsidian-triage/skills/luna-upgrade-all/SKILL.md)
sweeps them all in **one best-effort, dry-run-first pass** instead of running
`/luna-upgrade` once per vault:

1. **Sweep** — discovers your vaults (from `~/.claude/luna-vaults.json` and a
   scan of `~/Documents`), classifies each (luna-family vs not-yet-stamped), and
   prints a per-vault table: already-current / clean-upgrade / conflict.
2. **Per-vault confirm** — it never auto-applies. You approve each vault before
   it is upgraded.
3. **Backup before every apply** — a timestamped snapshot is written to
   `~/.claude/luna-upgrade-backups/<vault-slug>/<timestamp>/` *before* any change
   (`<vault-slug>` is the vault's directory name with non-alphanumeric characters
   replaced by `_`). If a backup can't be written, the upgrade is aborted and the
   vault is left untouched. To undo a vault, run
   `luna-upgrade-all.sh restore --vault <path>` (add `--list` to see available
   backups).
4. **Conflict help** — if your customized `_CLAUDE.md` conflicts with the new
   template, the command proposes a merged version for you to approve rather than
   failing or silently overwriting your edits. On a heavily-customized vault this
   conflict is a **permanent shape**, not a transient (`git merge-file` exits 2 and
   the upgrade reports "NOT writing the version stamp" every time). If the new
   template's semantic content already reached your `_CLAUDE.md` another way,
   resolve ours-wins (change nothing) and hand-stamp `.vault-template.json` to the
   new version so the next sweep reports current. Note the upgrade refreshing
   template-owned `.obsidian` files on a live vault is designed behavior — with
   one consequence to check before committing the result: bundled plugin files
   (`.obsidian/plugins/*/{main.js,manifest.json,styles.css}`) are
   overwrite-class, so the upgrade can clobber a plugin you've since updated
   with the template's OLDER bundled copy. If your installed plugin versions
   are newer, restore the affected plugin paths from the timestamped pre-apply
   backup (`~/.claude/luna-upgrade-backups/<vault-slug>/<timestamp>/`) before
   committing — or abandon the whole upgrade with
   `luna-upgrade-all.sh restore --vault <path>`.

It is **best-effort**: a vault with uncommitted git changes still appears in the
sweep table (flagged `dirty=true`, plan shown), but `apply` refuses it until the
working tree is clean — commit or stash first. A vault that errors during its
dry-run is reported with `error` state and the sweep continues to the rest. Your
notes, journal, and data are never touched — only template-owned files are
refreshed. Obsidian vaults without a luna stamp show as `unstamped` and are left
alone (upgrade them deliberately, per vault, with `apply --force-unstamped`);
directories that aren't Obsidian vaults are skipped entirely.

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
/himmel-update                              # inside Claude Code
# or
bash scripts/himmel-update.sh               # from a shell, in the himmel checkout
# or, an equivalent entry point:
node scripts/himmelctl/bin.js update        # thin wrapper, same engine
```

`scripts/himmel-update.sh` (HIMMEL-893), in **apply mode** (no `--check`),
refuses to run against a **dirty checkout** (uncommitted changes) — commit or
stash first, then re-run. (The read-only `--check` mode does not reject a dirty
tree; it reports the chain without pulling.) On a clean tree it runs a
**six-item dependency chain, in order**, each item
reporting `updated` / `up-to-date` / `skipped` / `failed` / `not-attempted`
in a closing status table:

1. `git pull --ff-only` (fails loudly if your branch has diverged from upstream
   or local edits block the update — reconcile manually, updates land on the
   currently checked-out branch's configured upstream).
2. `claude plugin marketplace update himmel` — refresh plugins from the
   freshly-pulled local dir.
3. **jira CLI dist rebuild** — `scripts/jira/dist` is a gitignored build
   artifact; a pull that changes the jira TypeScript source needs a rebuild
   to take effect.
4. **qmd fork update** — qmd ships from a himmel-pinned fork outside this
   checkout, so `git pull` here never touches it.
5. **hermes junior-tier update** (HIMMEL-426) — hermes is a separate editable
   git checkout outside this repo; pulls + reinstalls it, skipping cleanly
   when hermes isn't installed.
6. **luna template upgrade** (`LUNA_VAULT_PATH`) — content-preserving refresh
   of template-owned vault files only.

The **first genuine failure aborts the chain** — later items report
`not-attempted`, the status table still prints, and the script exits
non-zero. There is no rollback or atomicity: items that already succeeded
before the failure are **not** undone — only the not-yet-attempted items are
skipped.

After the chain — win or lose, these five never abort and always run,
including on a chain failure — five pre-existing **best-effort advisory
steps** run: a codex plugin re-sync + hooks.json re-sanitize (HIMMEL-742), a
statusLine hud re-wire (HIMMEL-718), a **plugin install-state report**
(HIMMEL-434 — `marketplace update` only re-syncs *already-installed*
plugins, so it can't surface a himmel plugin that is missing or being served
from a non-`@himmel` marketplace; the report prints the
`claude plugin install …@himmel` / migrate commands for any gap; run it
standalone with `bash scripts/himmel-update.sh --plugins-check`), a lean
plugin-set reconcile (HIMMEL-1032), and stale cadence-runner / guardrail-mode
block drift checks.

Plain `git pull` works too if you don't need the rest of the chain.

## When changes take effect

- **Hooks**: immediately on the next tool call — PreToolUse/etc. re-read the
  script from disk each invocation. (This is why the [HIMMEL-392] hook fix needs
  only a pull, no restart.)
- **Plugins / slash commands / skills**: loaded at session start — **restart**
  any running Claude session to pick them up.

## Lean plugin set — keeping session-start context low (HIMMEL-1032)

Every **enabled** plugin injects its agents + skills + commands into the
context at session start, whether or not you use it. Ad-hoc `/plugin` installs
(and older maximal templates) drift the enabled set upward over time, and the
plugin install step is *additive* — it enables the lean template's plugins but
never disables the extras — so a manual prune used to drift back after the next
update.

The **lean floor** is the set of plugins flagged `true` in
[`docs/setup/settings-template.json`](settings-template.json). To reconcile your
`~/.claude/settings.json` back down to it:

```bash
# preview what would be disabled (writes nothing)
bash scripts/machine-setup/reconcile-enabled-plugins.sh --dry-run
# apply
bash scripts/machine-setup/reconcile-enabled-plugins.sh
```

It uses a **whitelist**: only floor plugins survive; every other enabled plugin
(including a future one that ships enabled) is set `false`. **`/himmel-doctor`**
(check **C15**) reports drift read-only, so you can see the cost before acting.

**Keep a plugin you actually want** — add it to `~/.claude/settings.local.json`.
The reconciler reads this sibling file and **bakes its entries into
`settings.json`** on every run, in both directions (a `true` keeps an off-floor
plugin like `codex@openai-codex` enabled; a `false` disables a floor plugin like
`playwright`), so your choice survives each reconcile — the override is enforced
by the reconciler itself, not by Claude Code's runtime settings precedence:

```json
{
  "enabledPlugins": {
    "codex@openai-codex": true,
    "playwright@claude-plugins-official": false,
    "luna-correlate@himmel": false
  }
}
```

(All vendored `@himmel` plugins stay `true` in the shared template so adopters
get them; disable the ones you personally don't run — like `luna-correlate` —
here, without editing the shared floor.)

**`/himmel-update` is adopter-safe**: by default it only *warns* about drift.
To have it *enforce* the floor on every update — the operator's "prune stays
pruned" switch — export the opt-in and persist it in your shell profile (once
per machine) so it reaches `/himmel-update` and every new shell:

```bash
echo 'export HIMMEL_RECONCILE_PLUGINS=1' >> ~/.bashrc   # or ~/.zshrc / your profile
export HIMMEL_RECONCILE_PLUGINS=1                        # this shell, now
```

Other lanes inherit this for free: GLM workers read the same
`~/.claude/settings.json`. (The codex lane uses a different plugin model — its
leanness is governed by what `install-himmel-codex.sh` provisions, not an
`enabledPlugins` map — and himmelctl's full-set enable stays a deliberate opt-in
that `settings.local.json` protects.)

## Uninstalling / offboarding

The inverse of install is the wizard's `uninstall` subcommand:

```bash
node scripts/himmelctl/bin.js uninstall --dry-run    # preview; nothing is executed
node scripts/himmelctl/bin.js uninstall              # actually offboard
```

Under the hood it derives + confirms, then execs
[`scripts/uninstall.sh`](../../scripts/uninstall.sh) (`scripts\uninstall.ps1`
on Windows) — a symmetric six-step teardown of what `setup.sh`/`adopt` onboard:
stops the Telegram bridge, removes its pairing + bridge state, deletes the
`HIMMEL-Resume-*` scheduled jobs, uninstalls the Claude plugins + marketplaces,
uninstalls the repo's git hooks, and unwires the user-scope
`~/.claude/settings.json` keys himmel added. It is destructive and fail-closed
(a non-interactive run aborts without `--yes`). Invoke `uninstall.sh` directly
for the manual or CI path — preview any run with `--dry-run`, and skip
individual steps with `--skip-plugins` / `--skip-hooks` / `--skip-tasks` /
`--skip-settings`:

```bash
bash scripts/uninstall.sh --dry-run    # preview; nothing is executed
bash scripts/uninstall.sh --yes        # actually offboard
```

It deliberately leaves the himmel clone, your `.env`, worktrees, handover state
outside the bridge root, and non-himmel `settings.json` keys untouched. **hermes
is not torn down** — it installs outside the repo (`%LOCALAPPDATA%\hermes` /
`$HERMES_HOME`); stop its gateway and remove that directory by hand if you are
decommissioning it (see the [hermes runbook](../hermes-runbook.md)).

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
- **Vendored plugin served from its external marketplace?** If `--plugins-check`
  flags `claude-obsidian` / `obsidian` as "served from another marketplace", an
  external auto-updating copy is shadowing the himmel SHA pin. Migrate it to the
  pinned `@himmel` source **operator-present, in a fresh session**:
  `bash scripts/machine-setup/migrate-plugin-to-himmel.sh --apply <name@market> …`
  (it mutates `settings.json` via `claude plugin`, so it is an operator step).
  Run it from a shell where the `claude` CLI is on `PATH` — on Windows that is
  PowerShell, **not** a bare Git Bash (which exits `ERROR: claude CLI required
  on PATH`). The external marketplace can silently re-appear later (its
  `autoUpdate` re-adds it), so re-run the migrate whenever `--plugins-check`
  flags the shadow again.
