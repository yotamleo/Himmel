---
name: luna-upgrade-all
description: Use when multiple luna-second-brain vaults need to be brought up to the current himmel template in one best-effort pass — dry-run-first sweep across all discovered vaults, per-vault operator-confirmed apply, backup/restore safety net, and a conflict-brainstorm layer that proposes a concrete _CLAUDE.md merge resolution instead of just failing. Triggers on /luna-upgrade-all at the user prompt OR programmatic Skill-tool dispatch. NEVER auto-applies; every apply is confirmed by the operator. Distinct from /luna-upgrade (single vault) and /himmel-update (harness self-update) — this is the MULTI-vault sweep layer above the proven single-vault engine (HIMMEL-462).
---

# luna-upgrade-all — multi-vault upgrade sweep (HIMMEL-462)

You bring MULTIPLE existing luna-second-brain vaults up to the current himmel
template in one best-effort pass. The engine that does all the work is
`scripts/luna-upgrade-all.sh` — this skill is the ergonomic
**sweep → confirm → apply → (brainstorm-on-conflict)** surface around it.
ALL discovery, classification, 3-way merge, conflict handling, backup/restore,
and fail-closed logic lives in `luna-upgrade-all.sh` (which in turn delegates
all single-vault logic to `templates/luna-second-brain/scripts/upgrade.sh`).
Do NOT reimplement any merge, backup, or classification logic here.

## Invocation surfaces

- **User prompt:** `/luna-upgrade-all [--roots <dirs>] [--registry <path>]
  [--template-dir <path>] [--porcelain]` — handled by the thin wrapper at
  `.claude/commands/luna-upgrade-all.md` which delegates here.
- **Programmatic Skill-tool dispatch (HIMMEL-128 compliant — no headless
  claude):** `Skill { skill: "obsidian-triage:luna-upgrade-all", args: "<flags...>" }`.

Wherever this document references `$ARGUMENTS`, treat it as the literal arg
string supplied via either path.

## Inputs

`$ARGUMENTS` is `[--roots <dir[,dir]>] [--registry <path>] [--template-dir <path>]
[--porcelain]` (all optional). Flags are passed through to the engine unchanged.

## Step 0 — Locate himmel's engine

The multi-vault engine `scripts/luna-upgrade-all.sh` lives in the himmel
checkout. Resolve the himmel checkout the same way as the single-vault skill:

```bash
HIMMEL=""
for d in "${HIMMEL_DIR:-}" "$HOME/github/himmel" "$HOME/github/Himmel" \
         "$HOME/Documents/github/himmel" "$HOME/Documents/github/Himmel"; do
  [ -n "$d" ] && [ -f "$d/templates/luna-second-brain/scripts/upgrade.sh" ] \
    && { HIMMEL="$d"; break; }
done
ENGINE="$HIMMEL/scripts/luna-upgrade-all.sh"
```

If `--template-dir <path>` was passed, set `HIMMEL` so that
`$HIMMEL/templates/luna-second-brain` equals that path (or pass the flag
straight through to the engine). If `HIMMEL` stays empty, stop and tell the
operator to set `HIMMEL_DIR` or pass `--template-dir`. The engine re-validates
the template internally — this probe only locates the engine file.

## Step 1 — Sweep (`--porcelain` table)

Run the engine's sweep subcommand with `--porcelain` to get a stable, machine-readable per-vault summary:

```bash
bash "$ENGINE" sweep --porcelain $ARGUMENTS
```

The engine emits one TSV row per discovered vault:

```
state\tfrom\tto\tdirty\tvault-path
```

States the engine can return:

| State | Meaning |
|---|---|
| `already-current` | Vault is at template version — nothing to do |
| `clean-upgrade` | Vault is behind and upgrades without conflict |
| `conflict` | Upgrade would conflict on `_CLAUDE.md` — needs brainstorm |
| `unstamped` | No luna stamp (`.vault-template.json` missing) — Phase 2 out of scope. Appears as a porcelain row with empty from/to/dirty columns (no sweep performed). |
| `error` | Engine dry-run failed for this vault |

Present the table to the operator in a readable form — align columns, highlight
`conflict` and `clean-upgrade` rows. Report the `dirty=true` advisory on any
luna-family vault with uncommitted git changes (sweep still ran the dry-run;
`apply` will refuse it until clean).

If the sweep returns no vaults, tell the operator and stop — nothing to do.

## Step 2 — Confirm per vault

For each vault in **`clean-upgrade`** or **`conflict`** state, CONFIRM with the
operator before applying. Apply is ALWAYS per-vault operator-confirmed — this
is the load-bearing safety gate. Never batch-apply silently.

Suggested prompt per vault:

> Apply upgrade from vX.Y.Z → vA.B.C to `<vault-path>`? (y/n)

Best-effort: if the operator declines a vault, skip it and continue to the next
one — do NOT abort the whole sweep. If a vault is `dirty=true`, tell the
operator to commit or stash first and then re-run `/luna-upgrade-all`.

## Step 3 — Apply

On operator confirmation, run the engine's `apply` subcommand for that vault:

```bash
bash "$ENGINE" apply --vault "<vault-path>" [--template-dir <path>]
```

The engine emits output signals on stdout — surface each one verbatim:

### Signal: `BACKUP\t<dest>`

Always printed first (before any writes to the vault itself (the backup directory write has already completed)). The `<dest>` is the timestamped
backup path under `~/.claude/luna-upgrade-backups/<vault-slug>/<UTC-ts>/`.
Report it to the operator so they know where to restore from if needed:

> Backup created at `<dest>`. Run `restore --vault <path>` to undo.

Then wait for the next signal.

### Signal: `OK\t<vault>`

Upgrade succeeded. Report the new template version (from the `vto` shown in
the sweep table) and remind the operator of the backup path:

> Upgrade complete — vault is now at vA.B.C. Backup retained at `<dest>`.

Continue to the next vault.

### Signal: `SKIPPED-DIRTY\t<vault>`

The vault is a git repo with uncommitted changes. The engine refused — no
backup was created, nothing was modified. Tell the operator:

> Skipped (dirty git tree): commit or stash your changes in `<vault>`, then
> re-run `/luna-upgrade-all`.

Continue to the next vault.

### Signal: `PARTIAL\t<vault>`

A write failure or `git merge-file` error — the stamp was NOT written (fail-closed).
Non-`_CLAUDE.md` files may be partially written (idempotent on re-run).
Surface the engine's full output verbatim and tell the operator:

> Partial upgrade: a write or merge error occurred. The version stamp was not
> written. Fix the underlying issue (check engine output above), then re-run.
> Backup retained at `<dest>`. Do NOT use `restore` — that undoes a completed
> upgrade, not a failed one; re-run `apply` after fixing.

Continue to the next vault.

### Signal: `CONFLICT\t<vault>\t<sidecar>`

The `_CLAUDE.md` 3-way merge could not auto-resolve. The engine left
`_CLAUDE.md` untouched, the stamp unwritten, and wrote the conflict merge
result to `<sidecar>` (`_CLAUDE.md.template-merge`). Proceed to Step 4
(conflict-brainstorm layer) for this vault — do NOT continue to the next vault
yet.

## Step 4 — Conflict-brainstorm layer

**Only enters on a `CONFLICT` signal from Step 3. Never on `PARTIAL` or any
other signal.**

Read the three inputs:

1. **Vault's `_CLAUDE.md`** — the operator's current operating manual (untouched by the engine).
2. **`_CLAUDE.md.template-merge` sidecar** — the 3-way merge result with conflict markers.
3. **Template `_CLAUDE.md`** — the incoming template version (at `$HIMMEL/templates/luna-second-brain/_CLAUDE.md`).

Study the conflict: identify the exact lines that diverged between the operator's
vault copy and the template's new version. The base (ancestor) for the 3-way
merge is stored in `<vault>/.vault-template.base/_CLAUDE.md`.

Propose a **concrete merged `_CLAUDE.md`** that:
- Preserves all operator customizations from the vault's copy.
- Incorporates all template changes from the incoming version.
- Is a valid, human-readable operating manual (not conflict-marker soup).

Show the operator a unified diff between the current vault `_CLAUDE.md` and
your proposed merge. Ask for explicit confirmation:

> I propose this merged `_CLAUDE.md` (diff above). Confirm to write, or paste
> corrections.

**NEVER auto-write the merge.** Wait for an explicit yes (or corrections, then
re-confirm).

On confirmation, write the proposed `_CLAUDE.md` to `<vault>/_CLAUDE.md` and
delete the sidecar `_CLAUDE.md.template-merge`. Do NOT write the stamp — the
re-apply below does that.

**If the vault is a git repo:** tell the operator to COMMIT the resolved
`_CLAUDE.md` before re-applying, so the dirty-git precondition passes:

> Conflict resolved. Because this vault is a git repo, commit the resolved
> `_CLAUDE.md` now (`git -C <vault> add _CLAUDE.md && git -C <vault> commit -m
> "resolve _CLAUDE.md upgrade conflict"`), then I'll re-apply.

Wait for the operator to confirm they have committed, then re-invoke `apply`:

```bash
bash "$ENGINE" apply --vault "<vault-path>" [--template-dir <path>]
```

On the re-apply, the `_CLAUDE.md` now merges cleanly → the engine should emit
`OK`. A second backup is created for this second apply run (that is expected —
two logical operations, two backups).

If re-apply returns another `CONFLICT`, surface verbatim and ask the operator
whether to try again or skip this vault.

## Undo path (`restore`)

At any point, the operator can undo a completed apply with:

```bash
bash "$ENGINE" restore --vault "<vault-path>" [--from <UTC-ts>] [--list]
```

- `--list` shows all matching backups for the vault with their from→to versions.
- `--from <ts>` selects a specific backup by timestamp (from the `BACKUP\t<dest>` line or `--list`).
- Without `--from`, selects the most recent backup whose manifest matches the vault's canonical path.

Restore is the **undo-a-completed-upgrade** path. It is NOT the forward path
after a `CONFLICT` or `PARTIAL` — those are still in-progress states; the
operator resolves and re-applies.

Backups live under `~/.claude/luna-upgrade-backups/<vault-slug>/` (outside the
vault — no vault `.gitignore` or autosync interaction). No auto-pruning in
Phase 1; the operator can inspect and remove old backups manually.

## Notes

- **Build was autonomous; USE is interactive.** The confirms in Steps 2 and
  4 are the load-bearing safety gates. The engine never auto-applies and never
  auto-resolves conflicts.
- **Never touch user content.** The engine only enumerates template-owned files;
  this skill never writes vault files directly (except the resolved `_CLAUDE.md`
  in Step 4, after operator confirmation).
- **`unstamped` vaults are out of scope for the sweep.** They are reported so
  the operator is aware. Upgrading a known-luna unstamped vault requires an
  explicit `apply --vault X --force-unstamped` — a deliberate, per-vault
  operator action with the honest risk that the engine runs a full pass that
  can overwrite `.obsidian/` config and other template-owned paths. Phase 2
  foreign-vault conversion is out of scope.
- **`dirty=true` is advisory at sweep time.** Sweep still shows the dry-run
  plan; `apply` enforces the precondition and refuses. Tell the operator to
  commit or stash first.
- **Single-writer, sequential.** Apply runs one vault at a time, in the order
  the operator confirms. Never fan parallel applies at one shared artifact.
