---
name: luna-upgrade
description: Use when an existing luna-second-brain vault needs to pull newer himmel template updates — refreshed bundled-plugin assets, .obsidian config, _CLAUDE.md operating-manual changes, scripts/hooks, scaffold docs, and the PLUGINS-SETUP manual-install list — WITHOUT touching user content (journal, notes, clips). Previews the change plan (dry-run), surfaces any _CLAUDE.md merge conflict or changed manual-install table, asks the operator to confirm, then applies. Triggers on /luna-upgrade at the user prompt OR programmatic Skill-tool dispatch. Distinct from himmel harness self-update and Claude Code marketplace autoUpdate — this is VAULT content/config (HIMMEL-389).
---

# luna-upgrade — content-preserving vault/template upgrade (HIMMEL-389)

You bring an EXISTING luna-second-brain vault up to the current himmel template
without clobbering the user's own content. Vaults are scaffolded once and never
re-read the template; this is the upgrade path. The engine that does all the
work is `templates/luna-second-brain/scripts/upgrade.sh` — this skill is the
ergonomic **dry-run → confirm → apply** surface around it. ALL classification,
3-way merge, conflict handling, and fail-closed recovery logic lives in
`upgrade.sh`; this runbook only orchestrates the preview/confirm/apply sequence
and surfaces the engine's output. Do NOT reimplement any merge logic here.

## Invocation surfaces

- **User prompt:** `/luna-upgrade [--vault <path>] [--template-dir <path>]` —
  handled by the thin wrapper at `.claude/commands/luna-upgrade.md` which
  delegates here.
- **Programmatic Skill-tool dispatch (HIMMEL-128 compliant — no headless
  claude):** `Skill { skill: "obsidian-triage:luna-upgrade", args: "<flags...>" }`.

Wherever this document references `$ARGUMENTS`, treat it as the literal arg
string supplied via either path.

## Inputs

`$ARGUMENTS` is `[--check] [--vault <path>] [--template-dir <path>]` (all optional).

- `--check` — report whether an upgrade is available and stop (no plan, no
  confirm, no changes). See "Check-only mode" below.
- `--vault <path>` — the vault to upgrade. Default: resolve from the current
  session (see Step 1).
- `--template-dir <path>` — explicit himmel template root override. Default:
  resolve the himmel checkout (see Step 0). The engine's own resolver order is
  `--template-dir` > `$HIMMEL_DIR` > generic `$HOME`-relative candidate paths >
  sibling scan, so on a normal layout you pass neither flag.

## Check-only mode (`--check`)

When `--check` is in `$ARGUMENTS`, do Steps 0 and 1 (locate himmel + the vault),
then run the engine in check mode and surface its single-line result verbatim —
do NOT run the dry-run/confirm/apply sequence:

```bash
bash "$UPGRADE" --template-dir "$TEMPLATE" --vault-dir "$VAULT" --check
```

It prints either `luna-second-brain: template vX.Y.Z available …` (an upgrade
exists — tell the operator they can run `/luna-upgrade` to apply it) or
`luna-second-brain: vault is current …`. It changes nothing and exits 0. STOP
after surfacing the line.

## Step 0 — Locate himmel's upgrade.sh

A vault scaffolded BEFORE this feature has no `scripts/upgrade.sh` of its own
yet, so always invoke **himmel's** copy (the first upgrade then installs
`upgrade.sh` into the vault — it is overwrite-class). Resolve the himmel
checkout the same way the engine resolves the template (explicit config wins,
then generic home-relative candidates):

```bash
HIMMEL=""
for d in "${HIMMEL_DIR:-}" "$HOME/github/himmel" "$HOME/github/Himmel" \
         "$HOME/Documents/github/himmel" "$HOME/Documents/github/Himmel"; do
  [ -n "$d" ] && [ -f "$d/templates/luna-second-brain/scripts/upgrade.sh" ] \
    && { HIMMEL="$d"; break; }
done
```

If `--template-dir <path>` was passed, set `HIMMEL` so that
`$HIMMEL/templates/luna-second-brain` equals that path (or pass the flag
straight through). If `HIMMEL` stays empty, stop and tell the operator to set
`HIMMEL_DIR` or pass `--template-dir` — do NOT guess a path. Define:

```bash
TEMPLATE="$HIMMEL/templates/luna-second-brain"
UPGRADE="$TEMPLATE/scripts/upgrade.sh"
```

This probe is best-effort and only locates `upgrade.sh`; the engine re-resolves
and re-validates the template itself (and warns if multiple checkouts match), so
the engine's resolution is authoritative — do not treat this snippet's result as
final.

## Step 1 — Resolve the vault root

If `--vault <path>` was passed, use it. Otherwise resolve the current session's
vault: walk up from `$PWD` to the nearest ancestor that contains a `.obsidian/`
directory or a `.vault-template.json` stamp; if none is found, use `$PWD`.
Confirm the resolved `$VAULT` looks like a vault (it has `.obsidian/` or
`.vault-template.json`); if it clearly is not one, stop and ask the operator to
pass `--vault`.

## Step 2 — Dry-run (preview)

Run the engine in preview mode — it touches nothing:

```bash
bash "$UPGRADE" --template-dir "$TEMPLATE" --vault-dir "$VAULT" --dry-run
```

## Step 3 — Surface the plan

Show the operator the engine's plan output verbatim (which files WRITE /
WRITE-NEW / MERGE-JSON / MERGE-3WAY / REPORT, and the template-vs-vault
versions). Call out explicitly if the plan includes:
- a `MERGE-3WAY _CLAUDE.md` line (their operating manual may merge or conflict), or
- a changed `.obsidian/PLUGINS-SETUP.md` (the manual-install list reprints on apply).

If the dry-run reports the vault is already current (exit 0, "already current"),
say so and STOP — nothing to do.

## Step 4 — Confirm

Ask the operator to confirm they want to apply this plan to `$VAULT`. Wait for
an explicit yes. If they decline, STOP — make no changes.

## Step 5 — Apply

On confirmation, re-run the engine with `--yes` (same resolution, no prompt):

```bash
bash "$UPGRADE" --template-dir "$TEMPLATE" --vault-dir "$VAULT" --yes
```

## Step 6 — Surface the result

Report the engine's outcome, preserving its loud signals:
- **Success (exit 0):** "Upgrade complete — vault is now vX.Y.Z."
- **`_CLAUDE.md` conflict / write failure (non-zero exit):** the engine did NOT
  write the version stamp (fail-closed) and printed the reason. Surface that
  loud alert verbatim — on a `_CLAUDE.md` conflict the original is kept and the
  conflicted 3-way merge is in `_CLAUDE.md.template-merge`; the operator
  resolves it by hand, deletes the sidecar, and re-runs (writes are idempotent).
- **PLUGINS-SETUP reprint:** if the engine reprinted the manual-install table,
  pass it through so the operator can install/update the AGPL/proprietary
  plugins (Charts, Templater, …) that cannot be bundled.

Do NOT attempt to resolve a conflict or re-run automatically — the
content-preserving contract is the engine's; your job is to surface its result.

## Step 7 — Offer to commit (single-writer vaults only)

`upgrade.sh` writes template files but never commits — and the vault's
`vault-autosync.sh` is opt-in (default OFF) and wired to no trigger, so a fresh
upgrade leaves a dirty working tree that silently never lands (the "N uncommitted
changes after /luna-upgrade" surprise). On a **successful apply (exit 0)**, close
that gap:

```bash
# only if the vault commits straight to main by design AND has pending changes
[ -f "$VAULT/.single-writer" ] && [ -n "$(git -C "$VAULT" status --porcelain)" ] && echo offer
```

If both hold, OFFER to commit (operator confirms — do not auto-commit):

```bash
git -C "$VAULT" add -A && git -C "$VAULT" commit -m "chore: luna vault upgrade → template vX.Y.Z"
```

If the vault is not single-writer (no `.single-writer`), do NOT offer — those
vaults gate vault writes through a PR lane; just tell the operator the upgrade
left uncommitted changes to review. (`/himmel-doctor` C3 is the standing backstop
that flags a dirty single-writer vault later.)

## Exit codes (from the engine)

- `0` — applied (or dry-run completed, or already current).
- `1` — a partial upgrade: write failure or `_CLAUDE.md` conflict — stamp NOT
  written, re-run after resolving.
- `2` — env/usage error (e.g. template not located, vault dir missing, unknown
  flag, unreadable marketplace.json, missing python3/git/sha256sum). On "could
  not locate the himmel template", set `HIMMEL_DIR` or pass `--template-dir`.

## Notes

- The build of this skill was autonomous; its USE is interactive (the confirm
  in Step 4 is the load-bearing safety gate).
- Never edit user content. The engine only ever enumerates template-owned files;
  this skill never writes vault files directly.
