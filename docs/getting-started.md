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
> `irm https://claude.ai/install.ps1 | iex` (Windows). `setup.sh` checks for it
> and installs everything else.

## 1. Install (≈3 min hands-on, plus install time)

```bash
git clone https://github.com/yotamleo/Himmel
cd himmel

# Linux / macOS / Git Bash
bash scripts/setup.sh
# Windows PowerShell:  powershell -File scripts\setup.ps1
```

`setup.sh` is non-destructive and tells you exactly what it does at each step:
it verifies the [required tools](setup/new-machine.md#foundational-every-platform--verified-at-setup),
installs the pre-commit + git hooks, builds the local Jira CLI, registers the
qmd search index, and creates a ready-to-use `.env` from `.env.example`
(placeholder values — you do **not** need to edit it for the core loop). Re-run
it any time; it is idempotent.

> One PATH note: setup installs `jira`, `pre-commit`, and `uv` into
> `~/.local/bin`. If a fresh shell can't find them, add
> `export PATH="$HOME/.local/bin:$PATH"` to your shell rc (setup reminds you at
> the end).

Prefer to add himmel's portable core (hooks + worktree workflow) to an existing
repo instead? See [use-on-your-project.md](setup/use-on-your-project.md).

Installing the Claude Code plugins (handover, triage, obsidian, …)? You choose
where they're recorded: **user scope** (`~/.claude`, available in every project
— the default) or **project scope** (this repo's `.claude/settings.json`, shared
with anyone who clones it). The plugin-install step prompts you, or pass
`--scope` to `install-plugins` — see
[plugin scope](setup/new-machine.md#scope-user-vs-project).

## 2. Minimal config (≈1 minute)

himmel needs almost nothing to start:

- **`USER_SLUG`** — your kebab-case handle (e.g. `jane-doe`). If you skip it,
  himmel derives it from your `git config user.name`. That's it for the core.
- **Everything else is optional.** luna (the companion vault), Telegram, hermes,
  and Jira are all opt-in — the harness runs fully without any of them. Add Jira
  later by filling `JIRA_*` in `.env` (see the
  [env table](../README.md#quickstart)); the local CLI needs only four values
  and **no cloud ID**.
- **Want the companion vault?** himmel ships a ready-to-use AI-first Obsidian
  vault skeleton at
  [`templates/luna-second-brain/`](../templates/luna-second-brain/) — copy it
  out into its own git repo and run its `setup.sh`. Its
  [README](../templates/luna-second-brain/README.md#quickstart) has the
  install steps.

**For your first loop you need none of this** — `setup.sh` already did the work.
Skip straight to step 3.

## 3. Your first loop (≈5 minutes)

First, **open a Claude Code session in the repo** — run `claude` in your terminal
at the repo root (or use your IDE's Claude extension). The hooks below only fire
inside an active session. Then the day-to-day loop is:

```bash
/worktree feat/my-thing      # isolated branch + worktree. Branch must be type/slug —
                             #   type in feat|fix|chore|docs|refactor|test. Never edit main.
#   … make a small change with Claude …
/pr-check                    # multi-agent review; clears the merge gate when clean
#   gh pr create / gh pr merge --squash
/clean                       # prune merged-PR worktrees
/handover                    # save notes on what you did + where you left off, so the
                             #   next session (or a teammate) resumes with full context
```

**How to tell it's working:** `pre-commit run --all-files` should pass, and if you
try to edit a file on `main` you'll get a `block-edit-on-main` message pointing you
back into a worktree (`/clean_garden` or `/worktree`). That message is the guardrail
doing its job — a sign of success, not an error.

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

## You're in control

himmel makes the workflow *structurally* safe — but nothing is hidden, and every
guard is yours to lift:

- **Everything is plain files.** Rules live in [`CLAUDE.md`](../CLAUDE.md), hooks
  and permissions in `.claude/settings.json`, gates in `.pre-commit-config.yaml`.
  Read them; change them.
- **What himmel adds to your repo:** PreToolUse hooks (block edits on `main`,
  block secret reads, gate PR creation on a passing review), pre-commit/pre-push
  gates, and an auto-mode classifier. The full inventory + exactly what each does:
  [`docs/internals/enforcement.md`](internals/enforcement.md).
- **Every guard has an off switch.** Each hook is bypassed by a session env var
  set in the launching shell, e.g. `EDIT_ON_MAIN_OK=1 claude` to edit `main`, or
  `READ_SECRETS_OK=1 claude` if the (deliberately strict) secret-read guard blocks
  a file you need to inspect. The [`stuck-playbook`](internals/stuck-playbook.md)
  lists the escape hatch for each guard.
- **No surprise network or spend.** Optional integrations are opt-in; headless
  Claude/Gemini calls are gated; the local Jira CLI talks only to your own
  Atlassian site.

## Where to go next

| You want to… | Read |
|---|---|
| See one full loop explained | [daily-loop.md](daily-loop.md) |
| Understand every hook + gate | [internals/enforcement.md](internals/enforcement.md) |
| Browse the slash commands | [commands-catalog.md](commands-catalog.md) |
| Browse every tool/script | [tooling-catalog.md](tooling-catalog.md) |
| Run unattended overnight | [handover/overnight-mode.md](handover/overnight-mode.md) |
| Adopt the core in another repo | [setup/use-on-your-project.md](setup/use-on-your-project.md) |
| Full machine setup + gotchas | [setup/new-machine.md](setup/new-machine.md) |

Working as an LLM in this repo? Start from [`llms.txt`](../llms.txt) — the
machine-readable map.
