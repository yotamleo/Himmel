# himmel

> **A harness for Claude Code.**

> 🚀 **New here? → [Getting Started](docs/getting-started.md)** — clone to your
> first PR-gated loop in ~15 minutes.

A solo-operator / small-team development engine. Ships CLIs, hooks, plugins,
and Claude Code wiring designed for a worktree-isolated, PR-gated, Jira-tracked
workflow with a strong dose of AI assistance.

himmel is the **engine**: the tools that automate the parts a single operator
would otherwise repeat by hand (commit hooks, Claude session guardrails, handover
state, Jira sync, overnight unattended runs).

> **Companion second-brain (optional).** himmel pairs naturally with an AI-first
> Obsidian vault that Claude reads and writes directly — the Camp-2 memory
> substrate described below. himmel ships a ready-to-use template at
> [`templates/luna-second-brain/`](templates/luna-second-brain/) to bootstrap one.
> Cross-session handover state lives under your own repo (or an external handover
> repo via `$HANDOVER_DIR`) — see the
> [handover system](docs/internals/handover-system.md).

## What you get

The payoff of running Claude Code through himmel rather than bare:

- **Work compounds across sessions.** Durable markdown handover state means you
  never re-explain context — a fresh session resumes exactly where the last one
  stopped, with the decisions intact (not just *what* shipped, but *why*).
- **Unattended overnight execution.** `/overnight-shift` dispatches scoped tickets
  as parallel agents that branch, self-review, and open PRs while you sleep;
  arm-on-cap relaunches the session after a usage cap so a long run survives one.
- **Mistakes are structurally hard, not just discouraged.** Guardrail hooks block
  edits on `main`, secret reads, and opening a PR without a passing review — at the
  tool-call layer. Correctness lives in the structure, not in Claude remembering a
  rule.
- **Multi-agent review before every merge.** `/pr-check` runs a panel of review
  agents plus a cross-model first pass and gates the PR on a clean result —
  with an adversarial verify-before-critical rule to kill hallucinated findings.
- **Token-cheap by construction.** A local Jira CLI instead of an MCP server, an
  output-summarizing CLI proxy, and lean per-subagent context briefs keep the
  context window (and the bill) small.
- **Memory you can read and edit by hand.** A plain-markdown Camp-2 substrate — no
  vector DB to trust, debug, or re-embed.
- **Forge-agnostic.** The worktree→PR→merge loop, PR review threads, and
  luna-ingest work the same on GitHub or Bitbucket Cloud — the backend is chosen
  per-repo from the `origin` remote, so nothing in the day-to-day loop changes.
- **Cross-platform.** Linux, macOS, and Windows Git Bash, with the platform gotchas
  already handled.

## Who is this for — Tier 3-4 on the maturity ladder

Claude Code use spans four maturity tiers: **Tier 1 vanilla** (out-of-the-box —
notably where Boris Cherny, a creator of Claude Code, has described his own
setup as "surprisingly vanilla"), **Tier 2 customized** (skills + slash
commands), **Tier 3 orchestrated** (parallel agents + harnesses), and **Tier 4
24/7 autonomous** (scheduled unattended runs).

himmel targets **Tier 3-4**. It is the harness that turns vanilla Claude Code
into an orchestrated, PR-gated, Jira-tracked, overnight-capable operator:
worktree isolation, multi-agent code review, guardrail hooks, handover state
that survives session boundaries, and `/overnight-shift` unattended dispatch.

If you are happy at Tier 1 — and many excellent engineers are — you do not need
himmel. It earns its complexity only once you run multiple parallel sessions,
want unattended overnight work, or need work to compound across sessions without
re-explaining context each time.

## Memory architecture — Camp 2 (a context substrate, not a backend)

himmel takes an explicit stance on agent memory. Following the two-camps
taxonomy (memory *backends* vs context *substrates*), himmel is firmly **Camp
2**: the handover system, AI-first markdown, and a companion AI-first vault
(such as the bundled [`templates/luna-second-brain/`](templates/luna-second-brain/)
template) **are** the memory. Claude reads those files directly, reasons over
them, and writes back; the substrate
compounds across sessions. Crucially, there is no memory **backend** — nothing
extracts your files into a separate store you query *instead of* the source (no
Mem0, no RAG over embeddings of extracted facts). himmel does run a local search
index ([qmd](https://www.npmjs.com/package/@tobilu/qmd) — BM25 + vectors) *over*
the same markdown, but that index is a derived, drop-and-rebuild view that points
you back at the real file; the files remain the single source of truth, never
replaced by the index. The line is *what gets embedded and returned*, not whether
embeddings are used: qmd embeds the files and returns a pointer to the source,
whereas a Camp 1 backend embeds extracted facts and returns the fact in the
file's place.

The reasoning: for a single operator, the operator *is* the source of truth and
can read and edit the substrate by hand. Camp 1 backends (extract → embed →
store → similarity-retrieve) destroy exactly the structural context that makes
compounding work — you get an extracted fact when you needed the whole file, its
links, and the surrounding decisions, and extraction removes your ability to
inspect and correct the memory. Camp 1 wins when the corpus is too large to load
and inspection isn't needed (enterprise document QA); that is not himmel's use
case.

### Companion vault tooling (optional)

If you run the second-brain substrate as an Obsidian vault, himmel ships (and
pins) the tooling to operate it. All of it is optional — the core harness runs
without any of it.

- **[obsidian-triage](marketplace/plugins/obsidian-triage/README.md)** (shipped by
  himmel) — autonomous harvest → triage → synthesis → archive for Obsidian Web
  Clipper output: `/harvest-clips`, `/triage-clips`, `/synthesize-clips`,
  `/archive-clips`. Turns a clip inbox into a self-maintaining knowledge base.
- **[qmd](https://www.npmjs.com/package/@tobilu/qmd)** — a fast local search
  engine (BM25 + vector) over your markdown, exposed to Claude as an MCP server
  (`qmd@qmd`); the standalone CLI installs from himmel's qmd fork via
  `bash scripts/lib/qmd-bin.sh install` (run automatically by setup/adopt).
  This is the retrieval layer over the substrate; it indexes the files, it
  does not replace them (see above).
- **[claude-obsidian](https://github.com/yotamleo/claude-obsidian)** — a SHA-pinned
  fork of [AgriciDaniel/claude-obsidian](https://github.com/AgriciDaniel/claude-obsidian);
  skills for operating an Obsidian wiki vault: ingest, query, save, and **vault
  health / lint** (its `wiki-lint` skill).
- **[obsidian (kepano)](https://github.com/kepano/obsidian-skills)** — SHA-pinned;
  the `obsidian-markdown` skill for Obsidian-flavored-markdown syntax.

Separately, a scheduled vault-health pass (`/obsidian-health`, from the
`obsidian-second-brain` skill set) is armed on a monthly cadence by
[`pipeline-cadence`](.claude/commands/pipeline-cadence.md).

## Quickstart

himmel is a harness *for* [Claude Code](https://claude.com/claude-code), so you
need Claude Code installed (`curl -fsSL https://claude.ai/install.sh | bash`, or
`irm https://claude.ai/install.ps1 | iex` on Windows). The rest:
`bash`, `git`, `node`, `npm`, `bun`, `python3`, `jq`, `gh`, `mktemp`,
`pre-commit` (verified by `scripts/setup.sh` step 0). `bun` runs the handover
armed-resume resolver, the qmd search index, the Telegram bridge, and the
obsidian-triage tools. See
[`docs/setup/new-machine.md`](docs/setup/new-machine.md) for the per-platform
shell-and-package install (Linux / macOS / Windows Git Bash).

```bash
git clone https://github.com/yotamleo/Himmel
cd himmel

# Linux / macOS / Git Bash
bash scripts/setup.sh

# Windows PowerShell
powershell -File scripts\setup.ps1
```

Minimum environment (set in the shell that launches Claude or your daily
work shell):

luna, telegram, hermes, and Jira are all optional — the harness runs without them.

| Variable             | Required? | Notes                                                              |
|----------------------|-----------|--------------------------------------------------------------------|
| `USER_SLUG`          | recommended | Your kebab-case handle — e.g. `jane-doe`. Names your handover bucket (`handovers/<USER_SLUG>/`) and worktree dirs. If unset, auto-derived from your slugified `git config user.name`; setup fails only if both are unset. |
| `JIRA_PROJECT_KEY`   | required only for Jira ops | e.g. `HIMMEL`. The project the CLI creates/queries issues in. |
| `JIRA_BASE_URL`      | required only for Jira ops | Your Atlassian site, e.g. `https://your-site.atlassian.net`. |
| `JIRA_API_TOKEN` + `JIRA_EMAIL` | required only for Jira ops | API-token credentials. Never commit. `.env` is gitignored. |
| `HANDOVER_DIR`       | recommended | Path to your external handover repo (Mode B). See handover docs. |

The local Jira CLI needs only those four (`JIRA_BASE_URL`, `JIRA_EMAIL`,
`JIRA_API_TOKEN`, `JIRA_PROJECT_KEY`) — **no cloud ID**. `JIRA_CLOUD_ID` /
`ORGANIZATION_ID` are only for the optional Atlassian MCP server (Confluence and
a few ops the CLI lacks), not the CLI. Full list: [`.env.example`](.env.example).

After setup, sanity-check the install:

```bash
node scripts/jira/dist/index.js list      # talk to Jira
gh auth status                            # talk to GitHub
pre-commit run --all-files                # all hooks green
```

Then run one full loop end-to-end — worktree → commit → PR → merge →
`/clean` → `/handover`, with every hook and gate explained at the point it
fires: [`docs/daily-loop.md`](docs/daily-loop.md).

## Features

Pointer-heavy by design — every feature has a canonical doc that owns the
detail. This README points at them; the full map is in
[`docs/README.md`](docs/README.md).

| Feature                                    | Pointer                                                              |
|--------------------------------------------|----------------------------------------------------------------------|
| **Pre-commit + Claude PreToolUse hooks**   | [`docs/internals/enforcement.md`](docs/internals/enforcement.md)      |
| **Worktree + clean commands**              | [`docs/commands-catalog.md`](docs/commands-catalog.md) + [`CLAUDE.md`](CLAUDE.md) (`## WORKFLOWS`) |
| **Handover system (multi-repo registry + auto-branch + PR + flush)** | [`docs/internals/handover-system.md`](docs/internals/handover-system.md) |
| **Overnight mode (unattended dispatch)**   | [`docs/handover/overnight-mode.md`](docs/handover/overnight-mode.md)  |
| **Jira plugin (token-cheap local CLI)**    | [`scripts/jira/`](scripts/jira/) + [`docs/internals/jira-plugin.md`](docs/internals/jira-plugin.md) |
| **Forge support (GitHub + Bitbucket Cloud, auto-detected from `origin`)** | [`scripts/bitbucket/`](scripts/bitbucket/) + [`plugins/himmel-gh/`](plugins/himmel-gh/) |
| **Guardrails (shared git-state predicates)** | [`scripts/guardrails/`](scripts/guardrails/) + [`docs/internals/enforcement.md`](docs/internals/enforcement.md) |
| **`/improve` prompt-refinement hook**      | [`.claude/commands/improve.md`](.claude/commands/improve.md) (HIMMEL-127) |
| **`/overnight-shift` ticket fanout**       | [`.claude/commands/overnight-shift.md`](.claude/commands/overnight-shift.md) (HIMMEL-134) |
| **`/stop` graceful-halt marker**           | [`.claude/commands/stop.md`](.claude/commands/stop.md) (HIMMEL-137)   |
| **VM tooling (ralph-loop, etc.)**          | [`docs/setup/`](docs/setup/)               |

## Usage — the core loop

Day-to-day work runs through one PR-gated loop, driven by slash commands inside
a Claude Code session:

```bash
/worktree feat/my-thing   # isolated branch + git worktree (never edit on main)
#   … work with Claude in the worktree …
/pr-check                 # multi-agent review; clears the merge gate when clean
#   gh pr create / gh pr merge --squash   # PR-gated; ≥1 approval to merge
/clean                    # prune merged-PR worktrees
/handover                 # snapshot state so the next session resumes here
```

Going unattended:

```bash
/overnight-shift --limit 5   # dispatch 5 scoped tickets as parallel agents → PRs
/stop                     # graceful halt marker for an in-flight overnight run
```

The narrated walkthrough — every hook and gate explained at the point it fires —
is in [`docs/daily-loop.md`](docs/daily-loop.md). Working LLMs (or a new session)
should start from [`llms.txt`](llms.txt), the machine-readable map of the repo.

## Setup details

The full new-machine walkthrough — required environment, platform-specific
gotchas (macOS bash 4, Windows MSYS_NO_PATHCONV, realpath fallbacks),
per-platform shell setup — lives at
[`docs/setup/new-machine.md`](docs/setup/new-machine.md).

Adopting himmel in your own repo (or user scope) is one command —
`bash scripts/adopt.sh --profile core --scope project --target /path/to/repo`
brings the harness (hooks + guardrails + worktree commands + marketplace
plugins/skills) over in one shot. Profiles, scopes, the Windows `adopt.ps1`
twin, and the à-la-carte parts:
[`docs/setup/use-on-your-project.md`](docs/setup/use-on-your-project.md).

Claude Code global config (`~/.claude/`) setup: see
[`docs/setup/global-claude-md.md`](docs/setup/global-claude-md.md).

VM-based dev machines (osboxes / Multipass) for cross-platform testing:
[`docs/setup/vms.md`](docs/setup/vms.md).

## Contributing

See [`docs/contributing.md`](docs/contributing.md) for the contribution
workflow. TL;DR:

1. All work goes through a PR; main is protected.
2. Conventional commits: `type(scope): [HIMMEL-N ]message`.
3. Worktree-isolated branches (`/worktree <type>/<slug>`); never edit on `main`.
4. Pre-commit + pre-push hooks must pass.
5. New shell scripts include a smoke test (`scripts/<area>/test-<thing>.sh`).

## Project conventions

himmel uses Conventional Commits + Jira-ticket-in-subject for traceability.
The pre-commit framework enforces the format. Worktrees live under
`.claude/worktrees/` and follow `<type>/<slug>` (`feat`, `fix`, `chore`,
`docs`, `refactor`, `test`).

Detailed conventions — branch protection, force-push gates,
cross-platform attestation, headless-Claude billing rules — all live in
[`CLAUDE.md`](CLAUDE.md).

## License

himmel is licensed under the MIT License — see [`LICENSE`](LICENSE).
License selection was tracked under HIMMEL-132 Phase 4.

The vendored forks `marketplace/plugins/pr-review-toolkit-himmel` and
`marketplace/plugins/telegram-himmel` are distributed under their upstream
**Apache-2.0** licenses — see each plugin's `LICENSE` file.

Third-party attribution for vendored bundles and the dependency-license posture
(audited clean, fully permissive) is in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
