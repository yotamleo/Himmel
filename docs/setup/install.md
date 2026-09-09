# Installing himmel on your project

himmel is a harness *for* [Claude Code](https://claude.com/claude-code): hooks,
git gates and guardrails that enforce a PR-gated workflow at the tool-call layer
instead of asking the model to remember prose, plus handover files that carry
context across sessions. This page is the whole adopter path — install it,
choose what lands, and adapt the parts that assume himmel's own conventions.

Developing himmel *itself* is a different path:
[new-machine.md](new-machine.md#4-himmel-repo).

## Install

```bash
git clone https://github.com/yotamleo/himmel
node himmel/scripts/himmelctl/bin.js install --scope project   # or --scope user
```

`--scope` is the non-interactive path: it loads a shipped, runnable preset
([`docs/setup/profiles/adopter-project.install-profile.json`](profiles/adopter-project.install-profile.json)
or the `adopter-user` twin) and installs without asking anything. Drop the flag
to get the wizard instead — it asks a handful of questions and lets you confirm
each default. `--dry-run` prints the plan and writes nothing.

No `node` on the machine yet? Run `bash himmel/scripts/himmelctl/bootstrap.sh`
first; it installs Node, then re-run the install.

**Prerequisites**, checked by the installer, which fails fast with install
hints: `git`, `bash` 3.2+, `node`, `jq`, `python3`, and the Claude Code CLI on
your `PATH`. `gh` is optional for the install but used by the PR and
worktree-prune steps; `bun` is needed only for the optional extras (companion
vault tooling, qmd search, the Telegram bridge, armed resume).

> **Windows is EXPERIMENTAL in v1.** The installer, the git gates and the
> worktree commands are exercised on Linux and macOS. On Windows they run under
> **Git Bash** (`bash` 3.2+), and the PowerShell twins exist but are not part of
> the v1 support claim. Treat a Windows install as opt-in and self-supported:
> the Git Bash path is the one to prefer. Expect quoting and `PATH` differences
> from a Linux shell, and open an issue for whatever breaks — that is how the
> v1 support claim grows.

## What `profile` means: three unrelated things

This is the single biggest comprehension trap in himmel's surface, so it gets
named once, up front, and every later mention in this guide is qualified.

| Sense | Values | Where it lives | What it decides |
|---|---|---|---|
| **Install profile** | `starter`, `luna`, `operator`, `custom` — resolving to the manifest categories `core`, `luna`, `all` | [`scripts/install/manifest.json`](../../scripts/install/manifest.json) membership | *Which items* the installer wants present |
| **Saved install-profile file** | any `*.install-profile.json` | [`docs/setup/profiles/`](profiles/README.md), or the wizard's own cache | *Your recorded answers* — scope, install profile, plugin set, release channel — replayable with `--from-profile <file>` |
| **Plugin profile** | `lean`, `full` | [`scripts/lanes/plugin-profiles.json`](../../scripts/lanes/plugin-profiles.json), toggled with `/profile` | *Which marketplace plugins* are enabled in your Claude Code sessions |

They are independent. A `starter` install profile with the `lean` plugin
profile, recorded in a saved install-profile file, is the ordinary adopter
setup — and is exactly what `--scope project` gives you.

## What you are opting into

Four independent axes; pick one value from each. Nothing here is a package
deal, and every guard has an off switch (see
[configuration.md](../configuration.md) for the full map).

| Axis | Choice | What lands | What it requires | What it costs |
|---|---|---|---|---|
| **Scope** | `project` | The harness is wired in **this repo's** `.claude/settings.json` | Nothing extra | Everyone who clones the repo inherits it — commit the file deliberately |
| | `user` | The harness is wired in **`~/.claude/settings.json`** | Nothing extra | Applies to *every* project you open on this machine, including ones you did not mean to gate |
| **Install profile** | `starter` → `core` | 37 items: hooks, git gates, worktree commands, statusline, marketplace plugins, the Jira CLI build | `git`, `bash`, `node`, `jq`, `python3` | The PR-gated workflow becomes the only way to commit — that is the point, and it is the thing to try on one repo first |
| | `luna` | `core` plus the second-brain surface: vault scaffold, qmd index, graphify MCP, the clip cadences | `bun`, plus disk for the qmd index | A vault you now have to maintain; the cadences run on a schedule |
| | `operator` / `custom` | `all` (46 items) / whatever you answer | Everything above | The maintainer's full machine — not an adopter starting point |
| **Release channel** | unset (no recorded channel) | `git pull --ff-only` on your branch | Nothing | You track the tip, including work in progress — this is the *fallback*, not what a fresh install records |
| | `stable` | The highest `vX.Y.Z` tag | Nothing | You update only when a release is cut |
| | `pre` | The highest tag including `-pre.N` | Nothing | Prereleases, so earlier fixes and earlier breakage |
| **Plugin profile** | `lean` | The everyday plugin set | Nothing | Fewer skills loaded, less context spent per session |
| | `full` | Every marketplace plugin | Nothing | More context per session for surfaces you may never invoke |

Item membership is **data, not prose** — read
[`scripts/install/manifest.json`](../../scripts/install/manifest.json) rather
than trusting the counts above if they ever disagree. Channels are defined once,
in [updating.md](updating.md#release-channels-himmel-2705); this table cites
them rather than restating the resolution rules. Two senses of "default" that
are easy to conflate: the unset row is what the resolver falls back to when
*nothing* is recorded, while `install` on a new station records `stable` — so a
fresh install tracks releases, and only a station whose channel was never
written tracks the tip.

> **The Windows row-note.** Every axis above is available on Windows and none of
> them is covered by the v1 support claim. The scheduler-backed items in
> particular (`cadence-armed`, the arming legs) use `schtasks` there and are the
> least exercised.

## Minimal config

- **`USER_SLUG`** — your kebab-case handle. Skip it and himmel derives one from
  `git config user.name`. That is the whole required configuration.
- **Everything else is opt-in.** The companion vault, Telegram, hermes and Jira
  are all absent until you configure them; the harness runs fully without any of
  them. Add Jira later by filling the `JIRA_*` values in `.env` — the local CLI
  needs four values and no cloud ID.
- **Handover state** — run `/handover-setup` once to say where cross-session
  notes live: an inline folder in the repo, or a separate git repo via
  `HANDOVER_DIR`.

## Adapting himmel to a repo that is not himmel

himmel's gates encode himmel's own conventions. Six of them will not fit your
repo unchanged. Each is *what it assumes → how to change it → how to turn it
off*.

**1. Ticket IDs in commit messages.** `check-commit-msg.sh` requires every
commit subject to reference a ticket. It assumes a Jira-style key: with
`JIRA_PROJECT_KEY` set, the pattern is `<KEY>-<number>`; with no key set it
falls back to `#<number>`, which is a GitHub issue reference and probably
already right for you. To use your own convention, set `TICKET_ID_PATTERN` to an
extended-regex. To switch it off entirely, set `TICKET_ID_REQUIRED=0` — the
conventional-commit shape is still enforced, only the ticket reference is
dropped.

**2. Attestation trailers.** Two pre-push gates ask you to *attest*, in the
commit message, that you did something a machine cannot verify:
`Platforms tested: <os>` on shell and script diffs
([`scripts/hooks/check-platforms-tested.sh`](../../scripts/hooks/check-platforms-tested.sh))
and `Security reviewed: <token>` on non-docs code
([`scripts/hooks/check-security-reviewed.sh`](../../scripts/hooks/check-security-reviewed.sh)).
Both belong in the **first** commit of a branch, written after actually testing
and reviewing — the gate fires at push, far too late to teach the habit. They
are opt-in for adopters: they run only if you list the `platforms-tested` and
`security-reviewed` hook ids in your own `.pre-commit-config.yaml`. Omit the ids
and neither ever fires.

**3. `.single-writer` — the one you will want on day one.** `block-edit-on-main`
refuses edits when `HEAD` is your default branch, which is correct for a
review-gated team repo and wrong for a personal repo you commit straight to.
Drop a `.single-writer` file at that repo's root (`touch .single-writer`) and
on-main edits are allowed there. It is local and gitignored, so clones of the
same repo stay protected — this is a per-checkout opt-out, not a repo policy.

**4. The worktree workflow, and where the bypass goes.** `/worktree` creates an
isolated branch and worktree next to your `.claude/` directory; `block-edit-on-main` and
`check-worktree-isolation` keep work inside one. For a deliberate one-off, the
bypass is `EDIT_ON_MAIN_OK=1` — and it must be set in the shell that **launches**
Claude Code (`EDIT_ON_MAIN_OK=1 claude`). A per-call prefix inside a session does
nothing, because the hook runs in a process that never sees it. This is the most
common adopter confusion; it is worth reading twice.

**5. Which guards you may disable, and which you should not.** Disabling is
per-hook: remove the stanza from the `.claude/settings.json` the installer
wired, or the hook id from `.pre-commit-config.yaml`.
- **Reasonable to disable:** the ticket-ID requirement, the attestation
  trailers, the doc-freshness advisory, and the backend-routing guard
  (`block-backend-tier.sh`) if you have no Jira.
- **Keep:** `block-read-secrets.sh` (stops `.env`, `*.pem`, `id_rsa` and
  friends from reaching the model as tool results) and
  `block-destructive-commands.sh`. These are the two that fail *closed* around
  irreversible harm, and they cost nothing when nothing dangerous is happening.

**6. Operator-personal subsystems — skip all of these.** None of them is part of
the portable core, and skipping them changes nothing about the hooks or the
worktree workflow.

| Subsystem | What it is | Skip signal |
|---|---|---|
| Jira (`scripts/jira/`) | Local Jira CLI plus the backend-routing guard | Absent without `JIRA_*` credentials; the guard never fires |
| luna / Obsidian (`scripts/luna/`) | Vault management and the clip pipeline | Not in the `core` install profile at all |
| Telegram (`scripts/telegram/`) | Remote dispatch and chat bridge | Absent without a bot token |
| hermes (`scripts/hermes/`) | Free-inference junior and review lanes | Absent without API keys |
| graphify (`scripts/graphify/`) | Knowledge-graph retrieval over a corpus | Optional; its data egress is fenced by [`scripts/guardrails/egress-matrix.json`](../../scripts/guardrails/egress-matrix.json) |
| overnight mode (`scripts/overnight/`) | Unattended multi-ticket dispatch | Depends on handover plus Jira |

## Verify

Open a Claude Code session at the repo root (`claude`) — hooks only fire inside
a session — then:

1. Try to edit a file while on the default branch. `block-edit-on-main` should
   refuse and point you at `/worktree`. That refusal *is* the success signal.
2. Run `/worktree feat/try-himmel`. Edits on the worktree branch proceed
   normally.
3. Try `cat .env` (if you have one). `block-read-secrets` should refuse.
4. Run `node scripts/himmelctl/bin.js status` for a severity-grouped diff of
   what is installed versus what the manifest wants.

Then walk one real loop: [getting-started.md](../getting-started.md#3-your-first-loop-5-minutes).

## Lifecycle

| You want to… | Run |
|---|---|
| See what drifted | `node scripts/himmelctl/bin.js status` |
| Fix what drifted | `node scripts/himmelctl/bin.js ensure` |
| Change scope after the fact | `node scripts/himmelctl/bin.js scope set <project\|user>` |
| Update the harness | `/himmel-update` (Claude Code's own `autoUpdate` does **not** deliver himmel) |
| Diagnose a sick install | `/himmel-doctor` (`--fix` repairs the node wiring) |
| Offboard | `node scripts/himmelctl/bin.js uninstall` |

Detail for all of these: [updating.md](updating.md). Coming from an older
himmel install rather than a fresh one: [migrating.md](migrating.md).

## Appendix — manual install (recovery only)

**Use `himmelctl install`.** This sequence exists for one situation: the
installer cannot run and you need the portable core anyway. If you end up here,
that is a bug worth reporting, not a supported second path — and
`/himmel-doctor` is the first thing to try instead.

The portable core needs `bash` 3.2+, `git`, `jq`, `python3`. Copy these files
from the himmel clone into your repo, **keeping the relative paths** (the hooks
source their libraries relative to their own location):

```text
scripts/hooks/auto-approve-safe-bash.sh
scripts/hooks/block-edit-on-main.sh
scripts/hooks/block-read-secrets.sh
scripts/guardrails/lib.sh
scripts/lib/py-armor.sh
scripts/clean-garden.sh
scripts/worktree.sh
scripts/clean.sh
scripts/_new-worktree.sh
```

Make them executable, then wire the three hooks into your repo's
`.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "bash $CLAUDE_PROJECT_DIR/scripts/hooks/auto-approve-safe-bash.sh" }] },
      { "matcher": "Edit|Write|MultiEdit|NotebookEdit",
        "hooks": [{ "type": "command", "command": "bash $CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh" }] },
      { "matcher": "Bash|PowerShell|Read|Grep",
        "hooks": [{ "type": "command", "command": "bash $CLAUDE_PROJECT_DIR/scripts/hooks/block-read-secrets.sh" }] }
    ]
  }
}
```

`CLAUDE_PROJECT_DIR` is set by Claude Code to the directory holding
`.claude/settings.json`, so that directory must be your repo root. Verify with
the four steps under [Verify](#verify) above, then run
`node scripts/himmelctl/bin.js status` as soon as the installer works again — it
will tell you what the manual copy missed.

## Where to go next

- [getting-started.md](../getting-started.md) — your first PR-gated loop.
- [daily-loop.md](../daily-loop.md) — one full loop with every gate explained
  where it fires.
- [configuration.md](../configuration.md) — every knob, every gate's
  classification, every off switch.
- [migrating.md](migrating.md) — converging an older himmel install.
