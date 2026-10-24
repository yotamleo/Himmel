# Installing himmel on your project

Audience: newcomer. Owner of the rewrite: HIMMEL-7212.

**The task:** protect one git project with himmel, so that a Claude Code
session refuses to edit your default branch and works in a worktree instead.
Five steps get you there: preview, install, persist, verify, undo. Read the
choices, the adapting notes and the recovery path once the first install
works.

himmel is a harness *for* [Claude Code](https://claude.com/claude-code): hooks,
git gates and guardrails that enforce a PR-gated workflow at the tool-call layer
instead of asking the model to remember prose, plus handover files that carry
context across sessions.

Developing himmel *itself* is a different path:
[new-machine.md](new-machine.md#4-himmel-repo).

## Before you start

You need two folders: the **himmel download**, cloned once outside your project,
and **your project**, a git repository you run every install command from.

```bash
git clone https://github.com/yotamleo-org/Himmel ~/himmel   # outside your project, once
cd <your-project>                                           # the install acts on this folder
```

**Prerequisites**, checked by the installer, which fails fast with install
hints: `git`, `bash` 3.2+, `node`, `jq`, `python3`, and the Claude Code CLI on
your `PATH`. `gh` is optional for the install but used by the PR and
worktree-prune steps; `bun` is needed only for the optional extras (companion
vault tooling, qmd search, the Telegram bridge, armed resume). No `node` on the
machine yet? Run `bash ~/himmel/scripts/himmelctl/bootstrap.sh` first; it
installs Node.

> **Windows is EXPERIMENTAL in v1.** The installer, the git gates and the
> worktree commands are exercised on Linux and macOS. On Windows they run under
> **Git Bash** (`bash` 3.2+), and the PowerShell twins exist but are not part of
> the v1 support claim. Treat a Windows install as opt-in and self-supported:
> the Git Bash path is the one to prefer. Expect quoting and `PATH` differences
> from a Linux shell, and open an issue for whatever breaks. That is how the
> v1 support claim grows.

## Preview

Run from the root of your project. Both commands write nothing:

```bash
node ~/himmel/scripts/himmelctl/bin.js install --scope project --dry-run
bash ~/himmel/scripts/adopt.sh --profile core --scope project --dry-run
```

The first prints a summary of the install; the second prints one `DRY:` line
for each file and setting it would write. A preview leaves nothing to undo.

## Install

```bash
node ~/himmel/scripts/himmelctl/bin.js install --scope project   # or --scope user
```

`--scope` is the non-interactive path: it loads a shipped, runnable preset
([`docs/setup/profiles/adopter-project.install-profile.json`](profiles/adopter-project.install-profile.json)
or the `adopter-user` twin) and installs without asking anything. Drop the flag
to get the wizard instead; it asks a handful of questions and lets you confirm
each default.

Three words name three different choices, and the installer asks for them
separately: the **preset** is the shipped install-profile file that supplies
answers (`--scope` loads one, `--from-profile <file>` loads another); the
**installation scope** is where the harness is wired (`project` or `user`); the
**plugin profile** is which marketplace plugins are on (`lean` or `full`). Detail
and the exact values are in
[What `profile` means](#what-profile-means-three-unrelated-things).

The install itself always runs in a terminal. When it finishes it prints a link
to the local UI's Setup page (see [ui.md](../ui.md)), where you save secrets and
set the commit rules: `Finish setup in the UI: http://127.0.0.1:<port>/#t=<token>&page=setup`.
Open the printed link as is; the `#t=` part is the token. Run the install again
while that UI is running and it prints the same link. On a machine with no
browser (an SSH session, or Linux with no display) it asks for the secrets in
the terminal instead.

## Persist: commit it before you branch

A project-scope install writes `.claude/`, `scripts/` and `.gitignore` into the
working tree and leaves them **untracked**. A worktree is cut from committed
history, so one created before the install is committed has none of those
files: no `.claude/settings.json`, no `scripts/hooks/block-edit-on-main.sh`,
no `scripts/worktree.sh`, and nothing protects an edit there. Commit the
install first. Without the `pre-commit` tool the installer places plain git
hooks, and the commit hook refuses a commit on the default branch (with
`pre-commit` present the hooks run only what your `.pre-commit-config.yaml`
lists, which a starter install does not write). Use a branch and fast-forward
either way:

```bash
git switch -c chore/install-himmel
git add -A
git commit -m "chore: install himmel #1"      # the commit-msg gate wants a ticket reference
git switch main
git merge --ff-only chore/install-himmel
```

Where those plain hooks run, the commit-msg gate rejects a message with no
ticket reference. When
`JIRA_PROJECT_KEY` is unset it accepts `#<number>` (or `LOCAL-<number>`), as
above. On a repository with no ticket convention, switch the requirement off with
`TICKET_ID_REQUIRED=0 git commit …` (or set it in `~/.himmel/himmel.conf`, which applies to every project on this machine). On a repository with a branch-protected
default branch, push the branch and merge it through a PR instead of the
fast-forward. If the project has an `origin`, the worktree helper cuts new
worktrees from `origin/main`, so the install commit must reach it first, and
the installed pre-push hook refuses a direct push to `main` (no bypass): push
`chore/install-himmel` and merge it through a PR before you create a
worktree. A project with no `origin` branches from the local `main`. The commands say `main`; use your default branch's name if it
differs.

`.claude/settings.json` carries the path of your himmel download (the status
line and `HIMMEL_REPO` point at it), so this commit puts this machine's path
into the project. In a repository you share, a teammate whose download sits
elsewhere needs those two values changed to their own path.

A project-scope install also copies and wires the unresolved-review merge gate
and its libraries. The install commit adds `scripts/ci/ci-trust-paths.txt`,
seeded only when absent; your existing trust list is never overwritten. Until
that list is on your default branch, the gate refuses every merge from a
session that loads the new settings, including the adoption PR. The operator
must merge that first adoption PR outside Claude, using the forge web UI or
their own terminal; no agent session merges it.

A **trust path** is a file that decides whether other changes are safe: your
merge gate, your hooks, your CI checks and the list itself. A change to one can
switch a safety check off, so the agent that wrote it may not approve it. The
list lives in `scripts/ci/ci-trust-paths.txt` on your default branch (the copy
on a PR branch is never read); add any file that guards your project, such as
deploy scripts or release config. You may add lines but never remove one that
himmel's core list (`scripts/ci/ci-trust-paths-core.txt` in your himmel download)
holds. A new list is seeded with every core line; an existing list is left as it
is, so check that it holds them, because a PR touching a core path your list lacks
is refused (`list core-missing <pattern>`).

Inside a Claude session, a PR touching a listed path needs a trust-reviewed GO.
Only a himmel chief signs one for your repo, and only once your repo is listed
with `"merge_allowed": true` in `scripts/guardrails/himmel-adopted.json` on the
default branch of the himmel repo your download tracks (it ships empty) and an
independent judge has recorded its verdict on that head with
`write-verdict.sh --repo <owner/name>`; the chief then runs
`go.sh --repo <owner/name> --trust-reviewed <judge-qid> <pr> <head>`. Until then
such a PR does not merge from a session: the operator merges it in the forge web
UI or with a raw `gh pr merge`, which bypass `merge-on-green.sh`.

These checks run only inside Claude sessions (the hooks) and in himmel's merge
script (`merge-on-green.sh`) wherever it is run.
A merge made another way, in the forge web UI or with a raw
`gh pr merge`, bypasses them and is not checked. To enforce the list on the
forge too, turn on the optional branch rules (CODEOWNERS and a required review
for the listed paths; tracked in HIMMEL-3897).

## Verify

Open a Claude Code session at the repo root (`claude`); hooks only fire inside
a session. The install must already be committed on the default branch (see
[Persist](#persist-commit-it-before-you-branch)). Then:

1. Try to edit a file while on the default branch. `block-edit-on-main` should
   refuse and point you at a worktree. That refusal *is* the success signal.
2. Create the worktree: `bash scripts/worktree.sh feat/try-himmel`. It prints
   the worktree path (a `feat+try-himmel` folder under your repo's worktrees
   directory) and does not move a running session; quit and run `claude` again inside that path. Check that
   `.claude/settings.json`, `scripts/hooks/block-edit-on-main.sh` and
   `scripts/worktree.sh` exist there. If they do not, the install was not
   committed first. Edits on the worktree branch then proceed normally.
3. Try `cat .env` (if you have one). `block-read-secrets` should refuse.
4. Run `node ~/himmel/scripts/himmelctl/bin.js status` for a severity-grouped diff of
   what is installed versus what the manifest wants.

Then walk one real loop: [getting-started.md](../getting-started.md#your-first-loop).

## Undo

A preview wrote nothing. An install is undone by the uninstaller, which also
previews first.

### Uninstalling

`himmelctl uninstall` is the inverse of install. Preview first: `--dry-run`
lists every path, plugin, hook and settings key it would touch and changes
nothing:

```bash
node ~/himmel/scripts/himmelctl/bin.js uninstall --dry-run   # preview; touches nothing
node ~/himmel/scripts/himmelctl/bin.js uninstall             # remove himmel's CODE wiring (asks first)
node ~/himmel/scripts/himmelctl/bin.js uninstall --yes       # same, no prompt; needed without a terminal
node ~/himmel/scripts/himmelctl/bin.js uninstall --purge-state   # ...and your operator STATE too
```

Without a terminal, a run without `--yes` aborts (`non-interactive run without
--yes — aborting (fail-closed)`) and removes nothing.

It splits what himmel installed into two classes, and the default is the
conservative one:

- **Code** (removed by default): the Claude plugins and marketplaces himmel
  added, the repo's git hooks, the himmel keys (`statusLine`, hooks and `env`)
  in `~/.claude/settings.json` and in the current project's
  `.claude/settings.json`, the `HIMMEL:working-principles` block install appended to
  `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` (only that block is stripped;
  a file left empty by it is removed), the claude-hud config himmel wrote, the
  `HIMMEL-Resume-*` scheduled jobs, the Telegram bridge process and the
  himmelctl cache.
- **State** (kept unless you pass `--purge-state`): your Telegram pairing
  (`~/.claude/channels/telegram`) and the bridge state directory. A purge is
  refused (non-zero exit) rather than run while the bridge is still running,
  so state can remain after a guarded purge; stop the bridge and re-run.
- **Never touched**: the himmel clone, your `.env`, worktrees, handover state,
  and any `settings.json` key himmel did not add, and files of yours that were
  never part of the install. Files the install recorded in its ledger are
  removed from your repo's `scripts/` (git then shows them as deleted, so
  commit or discard that); a copy the ledger does not recognize is kept and
  named in the footprint, as is Claude Code's workspace-trust entry in
  `~/.claude.json` when the ledger does not say himmel added it. Deleting the
  himmel clone removes none of this; drop what is left with git.

Every change is printed with its exact path and line (`removing hook
PreToolUse: …`). After the settings step it re-reads the file and prints
`verified: no himmel wiring left in <file>`, a check of the file (hooks,
statusLine and the himmel `env` keys), not of a return code; if any of it is
still wired the run stops with a non-zero exit. The full path list lives in
[`scripts/install/uninstall-manifest.tsv`](../../scripts/install/uninstall-manifest.tsv),
which the uninstaller reads; `--dry-run` prints it as a `KEEP`/`REMOVE`
footprint. Flags and exit codes: [updating.md](updating.md#uninstalling--offboarding).

## After the first success

Everything below is for when the five steps above have worked once: what the
choices mean, what to configure, and how to fit himmel to a repo with its own
conventions.

### What `profile` means: three unrelated things

This is the single biggest comprehension trap in himmel's surface, so it gets
named once, and every later mention in this guide is qualified.

| Sense | Values | Where it lives | What it decides |
|---|---|---|---|
| **Install profile** | `starter`, `luna`, `operator`, `custom` — resolving to the manifest categories `core`, `luna`, `all` | [`scripts/install/manifest.json`](../../scripts/install/manifest.json) membership | *Which items* the installer wants present |
| **Saved install-profile file** | any `*.install-profile.json` | [`docs/setup/profiles/`](profiles/README.md), or the wizard's own cache | *Your recorded answers* — scope, install profile, plugin set, release channel — replayable with `--from-profile <file>` |
| **Plugin profile** | `lean`, `full` | [`scripts/lanes/plugin-profiles.json`](../../scripts/lanes/plugin-profiles.json), toggled with `/profile` | *Which marketplace plugins* are enabled in your Claude Code sessions |

They are independent. A `starter` install profile with the `lean` plugin
profile, recorded in a saved install-profile file, is the ordinary adopter
setup, and is exactly what `--scope project` gives you.

The plugin profile toggles with `/profile`; its registry is
`scripts/lanes/plugin-profiles.json`. The always-on `base` carries
`lean-skills@himmel` (vendored workflow skills) and `i-have-adhd@himmel`
(vendored; the installer and updater create its flag file unless
`HIMMEL_NO_ADHD_ALWAYS=1`). `design` adds the HTML/UI design kit and
`domain-modeling@himmel` per dispatch, `user` enables the opt-in `pstack@himmel`,
and `humanizer@himmel` is in no plugin profile.

### What you are opting into

Four independent axes; pick one value from each. Nothing here is a package
deal, and every guard has an off switch (see
[configuration.md](../configuration.md) for the full map).

| Axis | Choice | What lands | What it requires | What it costs |
|---|---|---|---|---|
| **Scope** | `project` | The harness is wired in **this repo's** `.claude/settings.json` | Nothing extra | Everyone who clones the repo inherits it — commit the file deliberately |
| | `user` | The harness is wired in **`~/.claude/settings.json`** | Nothing extra | Applies to *every* project you open on this machine, including ones you did not mean to gate |
| **Install profile** | `starter` → `core` | 38 items: hooks, git gates, worktree commands, statusline (claude-hud, cache-expiry line on; legacy bash bar stays opt-in/rollback — [tooling-catalog.md](../tooling-catalog.md#claude-statusline-vendored)), marketplace plugins, the Jira CLI build | `git`, `bash`, `node`, `jq`, `python3` | The PR-gated workflow becomes the only way to commit — that is the point, and it is the thing to try on one repo first |
| | `luna` | `core` plus the second-brain surface: vault scaffold, qmd index, graphify MCP, the clip cadences | `bun`, plus disk for the qmd index | A vault you now have to maintain; the cadences run on a schedule |
| | `operator` / `custom` | `all` (48 items) / whatever you answer | Everything above | The maintainer's full machine — not an adopter starting point |
| **Release channel** | unset (no recorded channel) | `git pull --ff-only` on your branch | Nothing | You track the tip, including work in progress — this is the *fallback*, not what a fresh install records |
| | `stable` | The highest `vX.Y.Z` tag | Nothing | You update only when a release is cut |
| | `pre` | The highest tag including `-pre.N` | Nothing | Prereleases, so earlier fixes and earlier breakage |
| **Plugin profile** | `lean` | The everyday plugin set | Nothing | Fewer skills loaded, less context spent per session |
| | `full` | Every marketplace plugin | Nothing | More context per session for surfaces you may never invoke |

Item membership is **data, not prose**. Read
[`scripts/install/manifest.json`](../../scripts/install/manifest.json) rather
than trusting the counts above if they ever disagree. Channels are defined once,
in [updating.md](updating.md#release-channels); this table cites
them rather than restating the resolution rules. Two senses of "default" that
are easy to conflate: the unset row is what the resolver falls back to when
*nothing* is recorded, while `install` on a new station records `stable`, so a
fresh install tracks releases, and only a station whose channel was never
written tracks the tip.

> **The Windows row-note.** Every axis above is available on Windows and none of
> them is covered by the v1 support claim. The scheduler-backed items in
> particular (`cadence-armed`, the arming legs) use `schtasks` there and are the
> least exercised.

### Minimal config

- **`USER_SLUG`:** your kebab-case handle. Skip it and himmel derives one from
  `git config user.name`. That is the whole required configuration.
- **Everything else is opt-in.** The companion vault, Telegram, hermes and Jira
  are all absent until you configure them; the harness runs fully without any of
  them. Add Jira later by filling the `JIRA_*` values in `.env`; the local CLI
  needs four values and no cloud ID.
- **Handover state:** run `/handover-setup` once to say where cross-session
  notes live: an inline folder in the repo, or a separate git repo via
  `HANDOVER_DIR`. A fresh clone has no handover root until you do. Until then
  `handover_root` fails closed with a diagnostic (`scripts/lib/handover-path.sh`),
  it does not crash, and nothing silently writes to the wrong place.

### Adapting himmel to a repo that is not himmel

himmel's gates encode himmel's own conventions. Six of them will not fit your
repo unchanged. Each is *what it assumes → how to change it → how to turn it
off*.

**1. Ticket IDs in commit messages.** `check-commit-msg.sh` requires every
commit subject to reference a ticket. It assumes a Jira-style key: with
`JIRA_PROJECT_KEY` set, the pattern is `<KEY>-<number>`; with no key set it
falls back to `#<number>`, which is a GitHub issue reference and probably
already right for you. To use your own convention, set `TICKET_ID_PATTERN` to an
extended-regex. To switch it off entirely, set `TICKET_ID_REQUIRED=0`. The
conventional-commit shape is still enforced, only the ticket reference is
dropped.

**2. Attestation trailers.** Two pre-push gates ask you to *attest*, in the
commit message, that you did something a machine cannot verify:
`Platforms tested: <os>` on shell and script diffs
([`scripts/hooks/check-platforms-tested.sh`](../../scripts/hooks/check-platforms-tested.sh))
and `Security reviewed: <token>` on non-docs code
([`scripts/hooks/check-security-reviewed.sh`](../../scripts/hooks/check-security-reviewed.sh)).
Both belong in the **first** commit of a branch, written after actually testing
and reviewing: the gate fires at push, far too late to teach the habit. They
are opt-in for adopters: they run only if you list the `platforms-tested` and
`security-reviewed` hook ids in your own `.pre-commit-config.yaml`. Omit the ids
and neither ever fires.

**3. `.single-writer`: the one you will want on day one.** `block-edit-on-main`
refuses edits when `HEAD` is your default branch, which is correct for a
review-gated team repo and wrong for a personal repo you commit straight to.
Drop a `.single-writer` file at that repo's root (`touch .single-writer`) and
on-main edits are allowed there. It is local and gitignored, so clones of the
same repo stay protected; this is a per-checkout opt-out, not a repo policy.

**4. The worktree workflow, and where the off switch goes.** `/worktree` creates an
isolated branch and worktree next to your `.claude/` directory; `block-edit-on-main` and
`check-worktree-isolation` keep work inside one. For a deliberate one-off, the
off switch is `EDIT_ON_MAIN_OK=1`, and it must be set in the shell that **launches**
Claude Code (`EDIT_ON_MAIN_OK=1 claude`). A per-call prefix inside a session does
nothing, because the hook runs in a process that never sees it. This is the most
common adopter confusion; it is worth reading twice.

**5. Which guards you may disable, and which you should not.** Disabling is
per-hook: remove the stanza from the `.claude/settings.json` the installer
wired, or the hook id from `.pre-commit-config.yaml`.
- **Reasonable to disable:** the ticket-ID requirement, the attestation
  trailers, the doc-freshness warn-only hook, and the backend-routing guard
  (`block-backend-tier.sh`) if you have no Jira.
- **Keep:** `block-read-secrets.sh` (stops `.env`, `*.pem`, `id_rsa` and
  friends from reaching the model as tool results) and
  `block-destructive-commands.sh`. These are the two that fail *closed* around
  irreversible harm, and they cost nothing when nothing dangerous is happening.
- **The `himmel-guard` plugin is on by default.** The starter install enables
  `himmel-guard@himmel`, which carries the same destructive-command guard as a
  plugin. To opt out run `/profile disable himmel-guard@himmel`; the
  [plugin README](../../marketplace/plugins/himmel-guard/README.md#on-by-default-and-how-to-opt-out)
  covers keeping it off across a reconcile.

**6. Operator-personal subsystems: skip all of these.** None of them is part of
the portable core, and skipping them changes nothing about the hooks or the
worktree workflow.

| Subsystem | What it is | Skip signal |
|---|---|---|
| Jira (`scripts/jira/`) | Local Jira CLI plus the backend-routing guard | Absent without `JIRA_*` credentials; the guard never fires |
| luna / Obsidian (`scripts/luna/`) | Vault management and the clip pipeline | Not in the `core` install profile at all |
| Telegram (`scripts/telegram/`) | Remote dispatch and chat bridge | Absent without a bot token |
| hermes (`scripts/hermes/`) | Free-inference junior and review lanes | Absent without API keys |
| graphify (`scripts/graphify/`) | Knowledge-graph retrieval over a corpus | Optional; its data egress is fenced by [`scripts/guardrails/egress-matrix.json`](../../scripts/guardrails/egress-matrix.json) |
| AFK (unattended) mode (`scripts/overnight/`) | Unattended multi-ticket dispatch | Depends on handover plus Jira |

## Lifecycle

| You want to… | Run |
|---|---|
| See what drifted | `node ~/himmel/scripts/himmelctl/bin.js status` |
| Fix what drifted | `node ~/himmel/scripts/himmelctl/bin.js ensure` |
| Change scope after the fact | `node ~/himmel/scripts/himmelctl/bin.js scope set <project\|user>` |
| Update the harness | `/himmel-update` (Claude Code's own `autoUpdate` does **not** deliver himmel) |
| Diagnose a sick install | `/himmel-doctor` (`--fix` repairs the node wiring) |
| Preview an offboard | `node ~/himmel/scripts/himmelctl/bin.js uninstall --dry-run` (or `-n`) |
| Offboard | `node ~/himmel/scripts/himmelctl/bin.js uninstall` (add `--yes` when there is no terminal to confirm) |

Detail for all of these: [updating.md](updating.md). Coming from an older
himmel install rather than a fresh one: [migrating.md](migrating.md).

## Appendix — manual install (recovery only)

**Use `himmelctl install`.** This sequence exists for one situation: the
installer cannot run and you need the portable core anyway. If you end up here,
that is a bug worth reporting, not a supported second path, and
`/himmel-doctor` is the first thing to try instead.

The portable core needs `bash` 3.2+, `git`, `jq`, `python3`. Copy these files
from the himmel clone into your repo, **keeping the relative paths** (the hooks
source their libraries relative to their own location):

```text
scripts/hooks/auto-approve-safe-bash.sh
scripts/hooks/block-edit-on-main.sh
scripts/hooks/block-read-secrets.sh
scripts/hooks/lib/guard-unwrap.sh
scripts/hooks/lib/shell-tokenize.sh
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
`node ~/himmel/scripts/himmelctl/bin.js status` as soon as the installer works again. It
will tell you what the manual copy missed.

## Where to go next

- [getting-started.md](../getting-started.md) — your first PR-gated loop.
- [daily-loop.md](../daily-loop.md) — one full loop with every gate explained
  where it fires.
- [configuration.md](../configuration.md) — every knob, every gate's
  classification, every off switch.
- [migrating.md](migrating.md) — converging an older himmel install.
- [Credits](../credits.md) — the sources, authors, licences and pins behind the plugins, skills and forks.
