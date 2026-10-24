# himmel

> **A harness for Claude Code.**

Audience: newcomer. The page opens with the first task for someone new to
himmel; the path for running or developing himmel itself is
[its own part of the Quickstart](#quickstart).

## Start here: protect one project

The first thing to do with himmel is protect one project you can throw away.
You install it into a spare git repository, ask Claude Code to edit a file on
`main` and see the edit refused, keep the install, make one change in its own
worktree, and then undo everything.
**[Getting Started](docs/getting-started.md) is that trial, step by step.**
Each step names the folder to run it from and what you should see, and the
last step removes the install again.

That one protected project is a complete result. Everything else on this page
is optional and comes later: a second-brain vault, unattended runs, a fleet of
parallel sessions. The [adoption trail](docs/adoption-trail.html) lays these
out as levels, and each level says what it gives you, what it costs and how to
turn it off.

> Deciding whether it is worth it? Read [**Why himmel**](docs/why-himmel.md),
> the failure modes it exists for and what each one costs. Want the design
> in one read? [**System design**](docs/system-design.md) explains the parts,
> one ticket's flow, the trust model and the trade-offs. Want the wiring?
> [**Architecture**](docs/architecture.md) draws the enforcement layers,
> handover, fleet, Jira seam and observability chain.

## What himmel is

himmel is a development engine for a solo operator or a small team who works
with Claude Code every day. It wraps Claude Code in hooks, guardrails, slash
commands, a local Jira CLI and a handover system, so the work follows a
worktree-isolated, PR-gated, Jira-tracked workflow without anyone having to
remember the rules.

The idea is simple: anything you would otherwise repeat by hand (checking a
commit, reviewing a PR, writing down where you stopped, restarting after a
usage cap) becomes a tool or a gate. Safety comes from structure, not from
Claude remembering a paragraph of instructions.

## What you get

The trial above shows the first of these: the edit refused on `main`, the
commit gate and the worktree. The rest arrive as you add them, and the
[adoption trail](docs/adoption-trail.html) says which level brings each one.

- **Work carries over between sessions.** Each session leaves a plain
  markdown handover doc behind. A fresh session reads it and resumes where the
  last one stopped, with the decisions and the reasons for them intact.
- **Work runs while you sleep.** `/afk-shift` hands scoped tickets to
  parallel agents that branch, review themselves and open PRs. When a session
  nears its usage cap, a usage-cap auto-relaunch schedules a relaunch with the operating
  system's scheduler, so a long run survives the cap.
- **Mistakes are blocked, not just discouraged.** Hooks stop edits on `main`,
  reads of secret files, and opening a PR without a passing review, at the
  moment Claude tries the tool call.
- **Every merge is reviewed by several agents.** `/pr-check` runs a panel of
  review agents plus a first pass from a second model, and the PR cannot merge
  until the result is clean. A finding marked critical must survive an
  adversarial check first, which filters out invented findings.
- **It stays cheap.** A local Jira CLI replaces a Jira MCP (Model Context
  Protocol) server, a CLI proxy summarizes noisy command output, and each
  subagent gets a lean brief. All three keep the context window and the bill
  small.
- **Memory you can read and edit.** Everything Claude remembers is a markdown
  file you can open. The search index on top is disposable and always points
  back at the file. [Memory architecture](#memory-architecture) explains how
  the pieces fit.
- **GitHub or Bitbucket.** The worktree, PR and merge loop works the same on
  GitHub and Bitbucket Cloud. himmel picks the backend from each repo's
  `origin` remote.
- **Linux and macOS.** Linux is checked on every PR, macOS on a scheduled
  run. Windows is not supported. Details in the
  [Support matrix](#support-matrix).

## How it flows

<p align="center">
  <img src="docs/assets/flows.svg" alt="Four himmel flows, each a row of six steps: shipping a change, running a fleet of workers from a chief, carrying work across sessions, and finding what you already know" width="960">
</p>

The graph walks four flows that make up most of a day with himmel. Each box
lights up in order. The graph is rendered by
[`scripts/docs/render-flows.py`](scripts/docs/render-flows.py); edit the
script, not the image.

**1. Ship a change.** Every change starts from a Jira ticket, and every commit
names it. `/worktree` gives the change its own branch and directory, because
nobody edits `main` directly. Hooks check each commit and push: message
format, secrets, the attestation lines that say what was tested. `/pr-check`
then runs the review panel. Once CI is green on the suites the change touches,
the PR merges and `/clean` prunes the finished worktree.

**2. Run a fleet: one chief, many workers.** For bigger runs, one Claude
session acts as the *chief*. It plans the work and starts *workers*, other
Claude sessions that each own one ticket, one worktree and one PR. A worker
reports back with short status markers (`LIVE`, `READY`) and never merges on
its own. The chief checks the PR (and can ask an independent judge subagent
for a second opinion), writes a GO file (merge approval) to sign off, and the
worker merges through `merge-on-green.sh`. The [glossary](docs/glossary.md)
defines chief, worker, judge and the rest.

**3. Carry work across sessions.** A session that has made decisions writes
them into a handover doc with `/handover`. The doc lives in your handover
state repo, not in the project, so it survives anything that happens to the
session. If the session hits its usage cap, himmel arms a relaunch. The next
session runs `/handover-resume`, reads the doc, and continues where the last
one stopped.

**4. Find what you already know.** Before improvising, a session looks up
what is already known. Claude Code's per-project `MEMORY.md` is a short index
that routes a keyword to a topic note. `qmd` searches the markdown itself
(notes, handovers, docs) by keyword and meaning. `graphify` answers questions
about how the code fits together. Each hop ends at a real file, and a lesson
learned on the way is written back to memory for the next session.

The commands behind flow 1:

```bash
/worktree feat/my-thing   # isolated branch + worktree (never edit on main)
#   … work with Claude in the worktree …
git commit && git push    # hooks gate the message, secrets and attestation lines
/pr-check                 # review panel; clears the merge gate when clean
gh pr create              # then merge once CI is green and the PR is approved
/clean                    # prune merged worktrees
/handover                 # write down where you stopped
```

Going unattended:

```bash
/afk-shift --limit 5   # five scoped tickets to parallel agents, each ending in a PR
/stop                        # ask an overnight run to halt gracefully
```

[`docs/daily-loop.md`](docs/daily-loop.md) walks flow 1 end to end and
explains every hook at the moment it fires.
[`docs/configuration.md`](docs/configuration.md) lists every gate, knob and
off switch in one place. A language model (or a new session) should start
from [`llms.txt`](llms.txt), the machine-readable map of the repo.

## Quickstart

himmel is a harness *for* [Claude Code](https://claude.com/claude-code), so
install Claude Code first:
`curl -fsSL https://claude.ai/install.sh | bash`.

There are two ways in:

1. **Add himmel to a project** (newcomer; the usual case). This brings over
   the portable core: hooks, guardrails, the worktree workflow and the
   marketplace plugins and skills. Do the trial in
   [`docs/getting-started.md`](docs/getting-started.md) on a spare project
   first. The [adoption trail](docs/adoption-trail.html) (also at
   [yotamleo-org.github.io/Himmel/adoption-trail.html](https://yotamleo-org.github.io/Himmel/adoption-trail.html))
   shows what each later level of adoption changes.
2. **Run or develop himmel itself** (contributor). This path has more
   prerequisites, and the rest of this section covers it.

**Prerequisites.** `bash`, `git`, `node`, `npm`, `bun`, `python3`, `jq`, `gh`
and `mktemp`; `scripts/setup.sh` checks for them first and stops with install
hints if one is missing. You also need one of `uv`, `pipx` or an installed
`pre-commit`: setup uses it to install `pre-commit` and then wires the git
hooks. `bun` runs the handover resume resolver, the qmd search index, the
Telegram bridge and the vault triage tools. Per-platform install steps are in
[`docs/setup/new-machine.md`](docs/setup/new-machine.md).

**Linux, from the release tarball** (checksummed and pre-built: no clone, no
`npm install`):

```bash
V=X.Y.Z   # a release that ships the tarball: https://github.com/yotamleo-org/Himmel/releases
curl -fsSLO "https://github.com/yotamleo-org/Himmel/releases/download/v$V/himmel-$V-linux.tar.gz"
curl -fsSLO "https://github.com/yotamleo-org/Himmel/releases/download/v$V/himmel-$V-linux.tar.gz.sha256"
sha256sum -c "himmel-$V-linux.tar.gz.sha256" \
  && mkdir -p ~/.local/share/himmel/"$V" \
  && tar -xzf "himmel-$V-linux.tar.gz" -C ~/.local/share/himmel/"$V" --strip-components=1 \
  && ln -sfn "$V" ~/.local/share/himmel/current \
  && node ~/.local/share/himmel/current/scripts/himmelctl/bin.js install --scope user
```

The `&&` chain matters: if the tarball does not match its published
`.sha256`, `sha256sum -c` fails and nothing is extracted or installed. With
`gh` you can also check that this repo's CI built it:
`gh attestation verify himmel-$V-linux.tar.gz -R yotamleo/Himmel`. CI builds
the tarball on each `v*` tag ([`release.yml`](.github/workflows/release.yml)).

Each release unpacks into its own `~/.local/share/himmel/<version>/` (no root
needed), and `~/.local/share/himmel/current` points at the live one.
`himmelctl install` wires everything through `current` and puts a `himmelctl`
launcher in `~/.local/bin`.

To upgrade, run `himmelctl update`. It downloads the latest release, verifies
it, unpacks it next to the old one and only then switches `current`, so a
failed download changes nothing. To roll back, point `current` at the previous
version: `ln -sfn <previous-version> ~/.local/share/himmel/current`. After
`himmelctl uninstall`, deleting `~/.local/share/himmel` removes every version.
An older install that unpacked straight into `~/.local/share/himmel` predates
this layout: move it aside and install once with the recipe above.

**Linux or macOS, from a clone:**

```bash
git clone https://github.com/yotamleo-org/Himmel himmel
cd himmel
node scripts/himmelctl/bin.js install
```

No node on the machine yet? Run `bash scripts/himmelctl/bootstrap.sh` first,
then `install`. The wizard runs `scripts/setup.sh` under the hood; call that
directly for a manual or CI install.

**Environment.** Set these in the shell that launches Claude. luna, Telegram,
hermes and Jira are all optional; the harness runs without them.

| Variable             | Required? | Notes                                                              |
|----------------------|-----------|--------------------------------------------------------------------|
| `USER_SLUG`          | recommended | Your kebab-case handle, e.g. `jane-doe`. Names your handover bucket (`handovers/<USER_SLUG>/`) and worktree dirs. If unset, it is derived from `git config user.name`; setup fails only if both are unset. |
| `JIRA_PROJECT_KEY`   | only for Jira | e.g. `HIMMEL`. The project the CLI creates and queries issues in. |
| `JIRA_BASE_URL`      | only for Jira | Your Atlassian site, e.g. `https://your-site.atlassian.net`. |
| `JIRA_API_TOKEN` + `JIRA_EMAIL` | only for Jira | API-token credentials. Never commit them; `.env` is gitignored. |
| `HANDOVER_DIR`       | recommended | Path to your external handover repo. Or leave it unset and run `/handover-setup` once. Until one of the two is done there is no handover root, and handover commands stop with a clear message instead of writing to the wrong place. |

The Jira CLI needs only those four Jira variables, no cloud ID.
`JIRA_CLOUD_ID` is only for the optional Atlassian MCP server. The full list
is in [`.env.example`](.env.example).

Check the install:

```bash
node scripts/jira/dist/index.js list      # talk to Jira
gh auth status                            # talk to GitHub
pre-commit run --all-files                # all hooks green
```

Then run one full loop (worktree, commit, PR, merge, `/clean`, `/handover`)
with [`docs/daily-loop.md`](docs/daily-loop.md) open beside you.

## Support matrix

himmel is developed on Linux and macOS. **Windows (Git Bash, WSL) is not
supported.** The Windows code paths are still in the tree and Windows issues
are welcome, but nothing about Windows is claimed as working.

| Tier | Platforms | What it promises |
|---|---|---|
| **Supported** | Linux | Checked on every PR as a required check ([CI runs on `main`](https://github.com/yotamleo-org/Himmel/actions/workflows/ci.yml?query=branch%3Amain)). The adopter round trip is verified. |
| **Supported** | macOS | Checked on a scheduled run twice a week, not on every PR ([scheduled macOS runs](https://github.com/yotamleo-org/Himmel/actions/workflows/macos-cadence.yml?query=event%3Aschedule)). A macOS-only failure is fixed as its own change ([`docs/internals/testing.md`](docs/internals/testing.md)). |
| **Not supported** | Windows (Git Bash), WSL | Code paths exist but are unverified: no CI gate, no guarantee. |

**Install channels:**

| Channel | Status |
|---|---|
| Release tarball (`himmel-<version>-linux.tar.gz` + `.sha256`) | **Supported** on Linux: the recipe above. A fresh machine installing from it is tested end to end. |
| `git clone` + `himmelctl install` | **Supported** on Linux and macOS. |
| Plugin marketplace (`marketplace/plugins/*`, one directory per plugin) | **Supported.** Installed, updated and removed by Claude Code itself (`claude plugin install/update/uninstall`), not by `himmelctl`. Includes [`himmel-ops`](marketplace/plugins/himmel-ops/README.md) (skills that load when a guardrail stops you and explain the way out), [`himmel-bus`](docs/himmel-bus.md) (a local message bus between sessions, early) and [`luna-correlate`](marketplace/plugins/luna-correlate/README.md) (an opt-in, offline health-factor correlation MCP). |
| AUR (`himmel`, recipe in [`packaging/aur/`](packaging/aur/)) | **Supported after the first AUR push** (Arch). `pacman` installs to `/opt/himmel`; each user then runs `himmelctl install --scope user`, and `himmelctl update` defers to `pacman -Syu`. To remove: `himmelctl uninstall` for each user, then `pacman -R himmel`. |
| brew (Linux tap) | Not supported. Reconsidered if a tap shared with macOS becomes worthwhile. |
| nix, deb, rpm | Not supported. Reconsidered when users ask for a given channel. |

New shell scripts target bash and stay bash 3.2-safe, so they run on macOS's
default bash. See
[`docs/internals/harness-compat.md`](docs/internals/harness-compat.md) for how
himmel behaves under other harnesses.

## Memory architecture

There are two broad ways to give an AI agent memory.

The first is a **memory backend**: software pulls facts out of your
conversations and files, stores them in a separate database (usually as
vector embeddings), and later retrieves the closest-matching facts *instead
of* the files they came from. Writing about agent memory sometimes calls this
"Camp 1".

The second is a **context substrate** ("Camp 2"): the files themselves are
the memory. The agent reads them, reasons over them and writes back to them.
Any index exists only to find the right file faster.

himmel is firmly in the second camp. The reason is that a single operator is
the source of truth and should be able to open, read and fix what the agent
remembers. Pulling one fact out of a file throws away the context that made
it useful: the links, the surrounding decisions, the reason it was written.
A memory backend wins when the corpus is too large to read and nobody needs
to inspect it, as in enterprise document search. That is not himmel's case.

What the memory is made of today, all plain files:

- **Auto-memory.** Claude Code keeps a per-project memory folder. himmel uses
  its `MEMORY.md` as a short index that *routes*: one line per theme, each
  pointing to a topic note that holds the detail. A session reads the index,
  then only the notes it needs.
- **Handover state.** Each piece of work has a markdown handover doc in your
  handover state repo (`$HANDOVER_DIR`): what was done, what was decided, what
  comes next. This is how work survives the end of a session. The state can
  live in your own repo or in a separate handover repo; see the
  [handover system](docs/internals/handover-system.md).
- **The luna vault (optional).** An Obsidian vault built from
  [`templates/luna-second-brain/`](templates/luna-second-brain/) holds notes,
  web clippings and daily entries that Claude reads and writes like any other
  markdown.

Two search tools sit on top. Neither replaces a file:

- **[qmd](https://www.npmjs.com/package/@tobilu/qmd)** is a local search
  engine over the markdown, using keyword ranking (BM25) and vectors. It
  returns a pointer to the source file, never a fact in its place. The index
  can be deleted and rebuilt at any time. That is the line between the two
  camps: not whether embeddings are used, but whether you get the file back.
- **graphify** builds a knowledge graph of the code (which file and function
  relates to which) and answers structure questions with `graphify query` and
  `graphify explain`. The graph is rebuilt from the source on a schedule. A
  data-egress fence ([`docs/internals/egress-matrix.md`](docs/internals/egress-matrix.md))
  decides which files may reach which extraction provider.

### Companion vault tooling (optional)

If you run the vault in Obsidian, himmel ships and pins the tools to operate
it. None of them is needed by the core harness.

- **[obsidian-triage](marketplace/plugins/obsidian-triage/README.md)** (part of
  himmel) turns an Obsidian Web Clipper inbox into a knowledge base that keeps
  itself tidy: `/harvest-clips`, `/triage-clips`, `/synthesize-clips`,
  `/archive-clips`.
- **qmd** reaches Claude as an MCP server (`qmd@qmd`). The standalone CLI
  installs from himmel's qmd fork with `bash scripts/lib/qmd-bin.sh install`,
  which setup runs for you.
- **[claude-obsidian](https://github.com/AgriciDaniel/claude-obsidian)**, pinned
  to an upstream release tag:
  skills to ingest, query and save notes, and to lint vault health
  (`wiki-lint`).
- **[obsidian (kepano)](https://github.com/kepano/obsidian-skills)**, pinned:
  the `obsidian-markdown` skill for Obsidian-flavored markdown.

A weekly vault-health pass (`/obsidian-health`, Sundays at 04:00) is
scheduled by [`pipeline-cadence`](.claude/commands/pipeline-cadence.md).

## Features

Every feature has one doc that owns its detail; the full map is
[`docs/README.md`](docs/README.md).

**Core loop and enforcement**
- Worktree isolation with `/worktree`, `/clean`, `/clean_garden`:
  [`docs/commands-catalog.md`](docs/commands-catalog.md) and
  [`CLAUDE.md`](CLAUDE.md) (`## WORKFLOWS`)
- Pre-commit and Claude tool-call guardrail hooks, and the multi-agent PR
  review (`/pr-check`) that gates every merge:
  [`docs/internals/enforcement.md`](docs/internals/enforcement.md)
- Handover system (multi-repo registry, auto-branch, PR, flush):
  [`docs/internals/handover-system.md`](docs/internals/handover-system.md)
- Collision preflight before starting a session: `bash scripts/handover/queue-lock.sh preflight <handover-doc> [file...]`
  warns (exit 20) when a file you intend to touch is already changed in another
  live session's checkout; read-only, `queue-lock.sh` header lists the contract
- AFK (unattended) mode runs (`/afk-shift`, `/stop` to halt):
  [`docs/handover/afk-mode.md`](docs/handover/afk-mode.md)

**Lifecycle and delegation**
- `himmelctl` install, update and uninstall:
  [`docs/setup/updating.md`](docs/setup/updating.md)
- Delegation across Claude model tiers, plus optional GLM and Codex lanes,
  listed live by `/lanes`: [`docs/tooling-catalog.md`](docs/tooling-catalog.md)
- Cloud lane (`claude --cloud` sessions on your fork):
  [`docs/setup/cloud-environment.md`](docs/setup/cloud-environment.md)
- Watchers that cost almost no tokens: `/morning-report` (git, GitHub and Jira
  state) and the `check-ci` merge-gate watcher:
  [`docs/commands-catalog.md`](docs/commands-catalog.md)
- Test VMs (osboxes, Multipass) driven by `/vm`:
  [`docs/setup/vms.md`](docs/setup/vms.md)

**Jira and forge**
- Jira CLI, a token-cheap local replacement for an MCP server:
  [`scripts/jira/`](scripts/jira/) and
  [`docs/internals/jira-plugin.md`](docs/internals/jira-plugin.md)
- GitHub and Bitbucket Cloud, detected from `origin`:
  [`scripts/bitbucket/`](scripts/bitbucket/) and
  [`plugins/himmel-gh/`](plugins/himmel-gh/)

**Knowledge (optional)**
- Vault capture and the clip pipeline (harvest, triage, synthesize, archive):
  [`marketplace/plugins/obsidian-triage/README.md`](marketplace/plugins/obsidian-triage/README.md)
- graphify and qmd: see [Memory architecture](#memory-architecture)

**Comms**
- Telegram bridge (arm a session, check status, chat from your phone):
  [`docs/telegram-bridge.md`](docs/telegram-bridge.md)

## Who is this for

Claude Code use tends to grow through four stages:

1. **Vanilla**: Claude Code as it ships. Boris Cherny, one of its creators,
   has described his own setup as "surprisingly vanilla".
2. **Customized**: your own skills and slash commands.
3. **Orchestrated**: parallel agents and a harness around them.
4. **Autonomous**: scheduled runs that work unattended, around the clock.

himmel is built for stages 3 and 4. If you are happy at stage 1, and many
excellent engineers are, you do not need it. It earns its complexity once you
run several sessions in parallel, want work done overnight, or want work to
build on itself across sessions without re-explaining the context each time.

## Setup details

- **A new machine, step by step:**
  [`docs/setup/new-machine.md`](docs/setup/new-machine.md) (required
  environment and per-platform notes).
- **Adopting himmel in your own repo:** `git clone
  https://github.com/yotamleo-org/Himmel himmel`, then
  `node himmel/scripts/himmelctl/bin.js install --scope project` (or
  `--scope user`). Leave out `--scope` to walk the wizard. What each scope and
  install profile brings, and the checklist for a repo that is not himmel:
  [`docs/setup/install.md`](docs/setup/install.md). Coming from an older
  install: [`docs/setup/migrating.md`](docs/setup/migrating.md).
- **Updating:** `/himmel-update` updates the harness (a `git pull` plus a
  marketplace re-sync; Claude Code's own `autoUpdate` does not deliver
  himmel). `/luna-upgrade` upgrades a companion vault separately.
- **Uninstalling:** `node scripts/himmelctl/bin.js uninstall`. Preview it first
  with `uninstall --dry-run`, which touches nothing. It removes himmel's wiring and keeps your state unless you
  pass `--purge-state` ([details](docs/setup/install.md#uninstalling)). All of
  this in full: [`docs/setup/updating.md`](docs/setup/updating.md).
- **Global Claude Code config** (`~/.claude/`):
  [`docs/setup/global-claude-md.md`](docs/setup/global-claude-md.md).
- **Test VMs:** [`docs/setup/vms.md`](docs/setup/vms.md).
- **Status line:** a pinned
  [claude-hud](marketplace/plugins/claude-hud/VENDORED.md) shows live session
  and cost data ([`docs/tooling-catalog.md`](docs/tooling-catalog.md)).
- **Security review** before shipping code changes:
  [`docs/security-review.md`](docs/security-review.md).

## Docs site (local preview)

`bash scripts/docs-site/serve.sh` builds `docs/` with Starlight and serves it on
loopback only: open `http://127.0.0.1:4321/Himmel/`. Needs Node 22.22+ and
network on first run (`npm ci` in `site/`).

## Contributing

The workflow is in [`docs/contributing.md`](docs/contributing.md). In short:

1. All work goes through a PR; `main` is protected.
2. Conventional commits with the ticket in the subject:
   `type(scope): [PROJ-123] message`.
3. One worktree per branch (`/worktree <type>/<slug>`); never edit on `main`.
4. Pre-commit and pre-push hooks must pass.
5. A new shell script comes with a smoke test (`scripts/<area>/test-<thing>.sh`).

## Project conventions

Commits follow Conventional Commits with a Jira ticket in the subject, and the
pre-commit hooks enforce the format. Worktrees live under
`.claude/worktrees/` and branches are named `<type>/<slug>` (`feat`, `fix`,
`chore`, `docs`, `refactor`, `test`). Branch protection, force-push gates,
platform attestation and the rules for headless Claude runs are all in
[`CLAUDE.md`](CLAUDE.md).

## License

himmel is licensed under the MIT License; see [`LICENSE`](LICENSE).

The vendored fork `marketplace/plugins/telegram-himmel` keeps its upstream
**Apache-2.0** license; see its `LICENSE` file. `scripts/cr/floor-reviewer.md`
is a modified copy of the Apache-2.0 `code-reviewer` agent from
`anthropics/claude-plugins-official` (see `THIRD-PARTY-NOTICES.md`).

Third-party attribution for vendored bundles and the dependency-license
audit (clean, fully permissive) is in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
