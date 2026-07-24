# Getting Started

New to himmel? This is the path from clone to your first PR-gated loop — about
**15 minutes**, most of it just watching `setup.sh` run. The core install is
three commands, and you stay in control the whole way. The deeper
[daily-loop walkthrough](daily-loop.md) that narrates every hook is *optional
depth*, not a prerequisite — the steps below stand on their own.

> **What is himmel?** A harness that runs Claude Code as a PR-gated,
> overnight-capable agent: worktree isolation, multi-agent review, guardrail
> hooks, and durable handover state that survives session boundaries. See the
> [README](../README.md) for the full pitch and the
> [advantages](../README.md#what-you-get).

> **Before you start:** himmel is a harness *for* Claude Code, so you need
> [Claude Code](https://claude.com/claude-code) installed —
> `curl -fsSL https://claude.ai/install.sh | bash` (Linux/macOS) or
> `irm https://claude.ai/install.ps1 | iex` (Windows). The install wizard
> checks for it — and for the other prerequisites, failing fast with install
> hints (the node-less bootstrap step below installs Node itself).

## 1. Install (≈3 min hands-on, plus install time)

This guide is for **using himmel on your own project** — the common case. Bring
himmel's hooks, guardrails, worktree workflow, and marketplace plugins/skills
into a repo you already have, in one command. The full adopter guide is
**[use-on-your-project.md](setup/use-on-your-project.md)** — start there.

> **Developing himmel itself** — running the repo standalone with `setup.sh`,
> hacking on the harness — is a different path. It's not covered here; see
> [setup/new-machine.md](setup/new-machine.md#4-himmel-repo).

**Prerequisites** (the wizard checks them and fails fast with hints):
`git`, `bash` 3.2+ (**Git Bash** on Windows), `node` (node-less machine? the
bootstrap step below installs it), `jq`, `python3`, and the
[Claude Code](https://claude.com/claude-code) CLI on your `PATH`. `gh` is
optional for the *install* — but the PR steps of the first loop below use it
on a GitHub repo (on Bitbucket Cloud, himmel's bundled Bitbucket CLI takes
its place), and the worktree-prune step uses it too. The optional extras
mentioned below — the companion vault tooling, qmd search, the Telegram
bridge, armed resume — additionally need [`bun`](https://bun.sh); the core
loop does not. (The README's standalone/contributor path lists `bun` as a
prerequisite because developing himmel itself uses it — that's the other
install path, not this one. Likewise `uv`/`pipx`/pre-commit: the contributor
path hard-requires one of them, but on *this* path the wizard only warns —
the pre-commit gates are an optional add-on for your repo.)

Clone once, then run the install wizard:

```bash
git clone https://github.com/yotamleo/himmel
node himmel/scripts/himmelctl/bin.js install
```

Node-less machine? `bash himmel/scripts/himmelctl/bootstrap.sh` first
(Windows: `powershell -ExecutionPolicy Bypass -File himmel\scripts\himmelctl\bootstrap.ps1`
— built-in `powershell`, since a fresh machine may not have `pwsh`),
then re-run `install`. The wizard asks a few questions (role, target repo,
scope, vault, handover, plugins) and derives the `adopt.sh`/`adopt.ps1`
invocation under the hood — for example, the most common outcome, `--profile core` at project scope:

```bash
bash himmel/scripts/adopt.sh --profile core --scope project --target /path/to/your/repo
# Windows:  pwsh -ExecutionPolicy Bypass -File himmel\scripts\adopt.ps1 -Profile core -Scope project -Target C:\path\to\repo
#   (adopt.ps1 needs PowerShell 7 `pwsh` — its plugin/settings helpers invoke pwsh
#    internally. Only the node-less BOOTSTRAP step above works in built-in powershell.)
```

Invoke `adopt.sh`/`adopt.ps1` directly for the manual or CI path. Full
profile/scope matrix (`luna`, `all`, user scope) and the à-la-carte parts:
[docs/setup/use-on-your-project.md](setup/use-on-your-project.md).

When the Claude Code plugins (handover, triage, obsidian, …) get
installed you choose where they're recorded: **user scope** (`~/.claude`, every
project — the default) or **project scope** (this repo's `.claude/settings.json`,
shared with anyone who clones it). The plugin step prompts you, or pass
`--scope` — see [plugin scope](setup/new-machine.md#scope-user-vs-project).

## 2. Minimal config (≈1 minute)

himmel needs almost nothing to start:

- **`USER_SLUG`** — your kebab-case handle (e.g. `jane-doe`). If you skip it,
  himmel derives it from your `git config user.name`. That's it for the core.
- **Everything else is optional.** luna (the companion vault), Telegram,
  [hermes](hermes-runbook.md) (himmel's hermes lanes — a CR-critic reviewer for
  `/pr-check` and a free-inference junior tier),
  and Jira are all opt-in — the harness runs fully without any of them. Add Jira
  later by filling `JIRA_*` in `.env` (see the
  [env table](../README.md#quickstart)); the local CLI needs only four values
  and **no cloud ID**.
- **Want the companion vault?** himmel ships a ready-to-use AI-first Obsidian
  vault skeleton at
  [`templates/luna-second-brain/`](../templates/luna-second-brain/) — copy it
  out into its own git repo and run its `setup.sh`. Its
  [README](../templates/luna-second-brain/README.md#quickstart) has the
  install steps. With the vault in place, each Claude session is auto-captured
  into it — [point the capture at a specific vault](luna/end-session-wiki.md#choosing-the-target-vault)
  if it doesn't live at the default `~/Documents/luna`. To import existing
  sessions and understand how capture → triage → synthesize compound over time,
  see the [compounding loop guide](luna/compounding.md).

**For your first loop you need none of this** — the install wizard already did
the work. Skip straight to step 3.

## 3. Your first loop (≈5 minutes)

First, **open a Claude Code session in the repo** — run `claude` in your terminal
at the repo root (or use your IDE's Claude extension). The hooks below only fire
inside an active session. Then the day-to-day loop is:

```bash
/worktree feat/my-thing      # isolated branch + worktree. Branch must be type/slug —
                             #   type in feat|fix|chore|docs|refactor|test. Never edit main.
#   … make a small change with Claude …
git add -A && git commit -m "feat: my change" && git push -u origin feat/my-thing
                             # conventional-commit gate fires at commit; the pre-push
                             #   gates run and record that a review is owed
/pr-check                    # multi-agent review; clears the merge gate when clean
#   gh pr create / gh pr merge --squash
/clean                       # prune merged-PR worktrees
/handover                    # save notes on what you did + where you left off, so the
                             #   next session (or a teammate) resumes with full context
```

> **First time using `/handover`?** Run **`/handover-setup`** once to point it at
> your own state store — an inline `handovers/` folder in the repo, or a separate
> git repo (via `HANDOVER_DIR`). It's configurable, not hardcoded, so your
> cross-session notes land wherever you want them.

**How to tell it's working:** if you try to edit a file on `main` you'll get a
`block-edit-on-main` message pointing you back into a worktree (`/clean_garden`
or `/worktree`). That message is the guardrail doing its job — a sign of
success, not an error. (If you also installed the optional pre-commit gates,
`pre-commit run --all-files` should pass too.)

**You're done when:** `/pr-check` reports clean, the PR merges, `/clean` removes
the worktree, and `/handover` confirms a saved snapshot. To verify, run
`git checkout main && git pull && git log --oneline -3` — your change is on `main`.
That's one full PR-gated loop.

Want it explained line-by-line — every hook and gate at the moment it fires, on
a real toy change? The **[daily-loop walkthrough](daily-loop.md)** runs the real
workflow on a real branch (≈15 min). Optional, but the best way to build trust in
what each guard does.

Going unattended later: `/overnight-shift --limit 5` dispatches scoped tickets as
parallel agents that open PRs while you sleep ([overnight mode](handover/overnight-mode.md)).

## Initiative mode + planning pipelines

Two optional accelerators sit on top of the loop. Both are opt-in.

### `HIMMEL_INITIATIVE` — drive-to-ship

When set, each session proactively drives finished work toward shipping at
*natural completion points* (a logical chunk is done **and** verified), instead
of waiting for you to say "ship it" each time. In the default (interactive)
profile, the `all` master switch runs four legs, in order:

1. **`prcheck`** — run `/pr-check` and loop until the review is clean.
2. **`pr`** — open or refresh the PR.
3. **`ticket`** — transition the Jira ticket.
4. **`handover`** — write the handover.

> **Merging is opt-in, never a surprise.** None of the four interactive legs
> merges. The full grammar does include `merge` and `public` legs — used by
> the overnight profile or an explicit subset. Know exactly what `merge`
> means before enabling it: **the leg itself authorizes an autonomous private
> merge** — `ARMAUTOMERGE` only selects *which* merge path it takes (the
> CI-certified chokepoint vs a plain squash-merge), it is not an extra on/off
> gate. The off switch is simply not enabling the leg. The `public` leg stops
> at PR-ready; the public merge always stays a human action. See
> [configuration.md](configuration.md) for the complete grammar and gate
> conditions. The directive also can't relax any safety rail — every gate in
> [configuration.md](configuration.md) still applies: the review-owed marker
> still gates `gh pr create`, the attestation commit-lines
> (`Platforms tested:` / `Security reviewed:`) are still required, and
> reactive history rewrites / settings self-edits stay vetoed.

**Enable it in the launching shell** (it's read at session start):

```bash
HIMMEL_INITIATIVE=all claude        # the four interactive legs
HIMMEL_INITIATIVE=prcheck,pr claude # just CR + open the PR
```

Grammar: a master switch `1`/`true`/`on`/`yes`/`all` (= the four legs above),
or a comma-separated subset of the full vocabulary
`plan,execute,prcheck,pr,ticket,merge,public,handover`. Case-insensitive,
whitespace-tolerant; an unset/falsy/typo value is **OFF** (the default), a
byte-identical no-op. A separate overnight profile (`HIMMEL_OVERNIGHT` +
`HIMMEL_INITIATIVE_OVERNIGHT`) widens `all` to six legs for unattended runs —
grammar, per-leg semantics, and profiles:
[configuration.md](configuration.md).

**Most people should leave the aggressive legs OFF.** Default is OFF for a
reason — auto-opening PRs and transitioning tickets is a lot of initiative. If
you want some of it, start conservative (`prcheck`, or `prcheck,handover`) and
reserve `all` (or the overnight profile) for trusted/overnight contexts.

**Per-project override (user default + per-repo tightening).** Beyond the
launching-shell variable, you can set it via the `env` block in
`settings.json`, which Claude Code makes visible to the session's hooks. Per
Claude Code's settings precedence, a **project** `.claude/settings.json`
deep-merges over your **user** `~/.claude/settings.json`, so you can set a
machine-wide default and override it per repo:

```jsonc
// ~/.claude/settings.json — your default for every repo
{ "env": { "HIMMEL_INITIATIVE": "prcheck,handover" } }

// <repo>/.claude/settings.json — make THIS repo stricter (off) or freer (all)
{ "env": { "HIMMEL_INITIATIVE": "" } }
```

A value exported in the launching shell takes precedence over `settings.json`
(per Claude Code's docs), and any change needs a **session restart** to take
effect.

### `/himmel-ops:minerva` — idea → critic-hardened plan

Runs brainstorm → spec → plan as one pipeline with an adversarial critic between
each stage, so every artifact is red-teamed before it advances. Use it for any
feature/design work before writing code. It stops at the plan (it doesn't
implement) and hands off.

## You're in control

himmel makes the workflow *structurally* safe — but nothing is hidden, and every
guard is yours to lift:

- **Everything is plain files.** Rules live in [`CLAUDE.md`](../CLAUDE.md), hooks
  and permissions in `.claude/settings.json`, gates in `.pre-commit-config.yaml`.
  Read them; change them.
- **What himmel adds to your repo:** PreToolUse hooks (block edits on `main`,
  block secret reads, gate PR creation on a passing review) and
  pre-commit/pre-push gates. (The auto-mode classifier you may hit in
  unattended sessions is Claude Code's own, not himmel's — himmel just routes
  sanctioned commands around it.) The full inventory + exactly what each does:
  [`docs/internals/enforcement.md`](internals/enforcement.md).
- **Nearly every guard has an off switch.** Each session hook is bypassed by an
  env var set in the launching shell, e.g. `EDIT_ON_MAIN_OK=1 claude` to edit
  `main`, or `READ_SECRETS_OK=1 claude` if the (deliberately strict)
  secret-read guard blocks a file you need to inspect. A small set of gates is
  deliberately hard (secret-leak scans, the human-only public merge) — the
  per-gate map, including that list, is in
  [configuration.md](configuration.md); the
  [`stuck-playbook`](internals/stuck-playbook.md) has the recovery flow for
  each guard.
- **No surprise network or spend — with three named exceptions.** Optional
  integrations are opt-in; headless Claude/Gemini calls are gated; the local
  Jira CLI talks only to your own Atlassian site. The exceptions, all
  switchable: a throttled session-start update check (a plain `git fetch` of
  your own himmel clone's remote, no data sent — `UPDATE_CHECK_DISABLE=1`);
  the usage-cap watchdog, which schedules a local session relaunch when a cap
  approaches (`AUTO_ARM_DISABLE=1`); and `/pr-check`'s external review
  critics, which run only where you configured their lane — `CR_PROFILE=none`
  forces a Claude-only review with no external spend. The full map:
  [configuration.md](configuration.md).

## Where to go next

| You want to… | Read |
|---|---|
| See one full loop explained | [daily-loop.md](daily-loop.md) |
| See every knob, gate, and off switch in one place | [configuration.md](configuration.md) |
| Understand every hook + gate | [internals/enforcement.md](internals/enforcement.md) |
| Browse the slash commands | [commands-catalog.md](commands-catalog.md) |
| Browse every tool/script | [tooling-catalog.md](tooling-catalog.md) |
| Run unattended overnight | [handover/overnight-mode.md](handover/overnight-mode.md) |
| Adopt the core in another repo | [setup/use-on-your-project.md](setup/use-on-your-project.md) |
| Full machine setup + gotchas | [setup/new-machine.md](setup/new-machine.md) |
| Update the harness + upgrade the vault | [setup/updating.md](setup/updating.md) |
| Uninstall / offboard himmel | `node scripts/himmelctl/bin.js uninstall` (execs [`scripts/uninstall.sh`](../scripts/uninstall.sh); see [updating.md](setup/updating.md#uninstalling--offboarding)) |

Working as an LLM in this repo? Start from [`llms.txt`](../llms.txt) — the
machine-readable map.
