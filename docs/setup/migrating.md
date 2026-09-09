# Migrating an existing himmel install

You already have himmel wired somewhere — by an old `adopt.sh` run, by hand
from a setup guide, or by a `himmelctl` version older than this one — and you
want to land on the current installer without losing the wiring you have.

- Installing for the first time → [install.md](install.md).
- Already on `himmelctl` and just want the newer code → [updating.md](updating.md).
- Somewhere in between, or not sure → you are on the right page.

The whole migration posture is one sentence: **converge in place with
`himmelctl`, do not tear down and reinstall.** Every path below is additive.

## Step 0 — which state are you in

One command tells you, and it never writes anything you have to undo:

```bash
node scripts/himmelctl/bin.js status
```

Two outcomes matter:

- **Exit code 2**, printing `himmelctl: no himmelctl install profile found —
  run himmelctl install first`. There is no install record on this machine, so
  `himmelctl` has nothing to reconcile *against* yet. You are in state 1 or 2.
- **A severity-grouped item list** (`red` / `degraded` / `green` / `n/a`). The
  record exists; the reds are your drift. You are in state 4 — and possibly
  state 3 as well, which is about your remote, not your wiring.

The install record is two files in `${HIMMELCTL_CACHE_DIR:-~/.claude/himmel}/`:
`install-profile.json` (the answers that drove the install) and `state.json`
(what the installer believes each target looks like now). Their absence is the
detection signal above, not a fault.

| From-state | Detect | Converge | Rollback |
|---|---|---|---|
| **1.** Wired by the old `adopt.sh`, or copied by hand | Hook commands present in the target's `.claude/settings.json`, but `status` exits 2 | `install` (adopts in place), then `ensure` | Restore the backed-up `.claude/settings.json` |
| **2.** A station set up by hand from the setup guide | Environment and tools are there, no repo wiring, `status` exits 2 | `install --scope user`, then `ensure` | Restore `~/.claude/settings.json` |
| **3.** `origin` still points at the pre-cutover remote | `git remote -v` names the old host | **Pending the HIMMEL-2705 cutover** — see below | Re-point `origin` back |
| **4.** Older hook wiring under a current install record | `status` lists `red` items naming hooks | `ensure` | Restore the backed-up `.claude/settings.json` |

## State 1 — wired by the old `adopt.sh`, or copied by hand

Your repo's `.claude/settings.json` already runs himmel hooks, but nothing on
this machine recorded *which* items were meant to be there. `ensure` cannot
help yet: with no `install-profile.json` it exits 2 by design, because
reconciling against an install profile it had to guess would be reconciling
against fiction.

```bash
node scripts/himmelctl/bin.js install --scope project
node scripts/himmelctl/bin.js ensure
```

`install` is not a re-install here — it writes the record and adopts the wiring
that is already present rather than replacing it. `--scope project` takes the
shipped `adopter-project` preset without asking anything, which is what you
want when the goal is simply to record a state that already exists; drop the
flag for the wizard, or pass `--from-profile <file>` to replay a saved
install-profile file, if your hand-wiring diverged from that preset. The
follow-up `ensure` is what closes the gap between "recorded" and "actually on
disk", per item, with a severity for each.

Preview first if you want the plan without the writes: add `--dry-run` to
either verb.

## State 2 — a station set up by hand from the setup guide

Same missing record, different scope: the machine has the environment
variables and the tools, but no repo carries the wiring, so you want the
harness for every project on this machine.

```bash
node scripts/himmelctl/bin.js install --scope user
node scripts/himmelctl/bin.js ensure
```

`--scope user` loads the shipped, placeholder-free adopter answers from
[`docs/setup/profiles/`](profiles/README.md) instead of prompting, so this path
is non-interactive. It writes `~/.claude/settings.json`; a per-project
`.claude/settings.json` still wins where one exists, so a repo you later adopt
at project scope is not fighting this.

## State 3 — `origin` still points at the pre-cutover remote

**This state is documented but not yet actionable.** It is gated on the
HIMMEL-2705 cutover; until that lands there is no new remote to point at, and
re-pointing early would leave you pulling from a URL that has no releases.

Detect it with `git remote -v`. If `origin` names the pre-cutover host, do
nothing yet — your updates keep working exactly as they do today. When the
cutover lands, the migration is a single `git remote set-url origin <new-url>`
followed by `git fetch --tags`, and only then does a release channel have tags
to follow. Nothing about your hook wiring, your install record or your scope
changes; this state is about where the code comes from, not what is installed.

Check this page again after the cutover rather than acting on it now.

## State 4 — older hook wiring under a current install record

`status` prints reds naming hook scripts that no longer exist, or it prints
reds for items that do exist but were never wired into your settings. Both are
the same class of drift, and both converge the same way:

```bash
node scripts/himmelctl/bin.js ensure
```

Do **not** hand-edit `.claude/settings.json` to chase the reds. `ensure`
reconciles the wiring against `scripts/install/manifest.json` item by item; a
hand-edit fixes the symptom you can see and silently diverges from the record,
which is exactly the state you are trying to leave.

If `ensure` cannot converge something on its own it says so, naming the items:

```text
himmelctl: N item(s) need manual convergence (no automated install path yet): <ids>
```

That line — and only that line — is your cue to consider the heavier path.

## Why `ensure`, not `uninstall` → `install`

`ensure` is additive: it turns items on toward the recorded install profile,
never off, and it never overwrites an item carrying a deliberate recorded
choice. That is what makes it safe to run against a machine whose history you
do not fully know.

`uninstall` is the opposite by design — it offboards plugins, scheduled jobs,
git hooks and settings wiring in one pass. Reaching for it as a migration step
throws away the very wiring you are trying to preserve, and it takes your
per-item decisions with it.

So: reserve `uninstall` → `install` for the case where `ensure` has printed the
manual-convergence line above and the named items are ones you actually need.
Even then, run `node scripts/himmelctl/bin.js uninstall --dry-run` first and
read the plan.

## Rollback

Back up one file before you start: **`.claude/settings.json`** — the project's,
at project scope, or `~/.claude/settings.json` at user scope. It is what the
tool-call hook wiring lives in, so restoring it undoes that wiring at that
scope in one step. It is not the whole rollback story, and the paragraph after
the snippet is precise about where it stops.

```bash
cp .claude/settings.json .claude/settings.json.bak
```

Be honest about what that does and does not cover. Restoring the file removes
the wiring for the hooks that file declares, so the **tool-call** hooks at that
scope stop firing, immediately. Everything else survives it. The **git** gates
do not live in that file: they are `.git/hooks/` scripts, and a commit or a push
will still be gated after the restore. Neither do the settings at the *other*
scope — a user-scope install keeps wiring every repo on the machine after you
restore a project's file. Nor does it touch installed marketplace plugins,
scheduled jobs, or the install record in
`${HIMMELCTL_CACHE_DIR:-~/.claude/himmel}/`. All of that is what
`node scripts/himmelctl/bin.js uninstall` exists for, and it is the supported
way to leave entirely. So treat the backup as a fast way to undo one scope's
tool-call wiring, not as a rollback: for a clean slate, run `uninstall` rather
than deleting things by hand.

## Release channels

A migration is a good moment to pick one, but this page does not define them:
the channel model, the resolution order, and the exact behaviour when you are
ahead of or diverged from a tag all live in
[updating.md](updating.md#release-channels-himmel-2705). Two things worth
knowing while migrating:

- `install` defaults a **new** station's saved install-profile file to
  `channel: stable`, and never overwrites a `channel` you already set.
- `HIMMEL_UPDATE_CHANNEL` in the environment outranks that recorded value.

State 3 is the caveat: until the cutover, a channel has no release tags to
follow on the old remote.

## Windows

**Windows is EXPERIMENTAL in v1** and migrating is no exception. Run every
command above under **Git Bash**; the PowerShell twins exist but are not part
of the v1 support claim. The scheduler-backed items converge through `schtasks`
and are the least exercised part of any of these paths — if `ensure` leaves one
red on Windows, that is the expected rough edge, not a signal to reinstall.

## Where to go next

- [install.md](install.md) — the full install guide and the adaptation
  checklist for a repo that is not himmel.
- [updating.md](updating.md) — routine updates, release channels, offboarding.
- [configuration.md](../configuration.md) — every knob and every gate's off
  switch, once you are converged.
