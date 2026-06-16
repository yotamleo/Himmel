# himmel marketplace

A Claude Code plugin marketplace. You do **not** need the himmel harness to
use it — most plugins here install and run on their own. Take one item, or
take none and just read the source.

> **New to himmel itself?** The harness (worktrees, guardrails, handover,
> PR-gated loop) is a separate thing — start at
> [`docs/getting-started.md`](../docs/getting-started.md). This page is only
> about the plugins.

## Install just one plugin

`<name>` is the plugin name from the table below (e.g. `obsidian-triage`).
Each plugin is independent — you install only what you name; nothing else
comes along. Pick a **scope** — both use the same marketplace, they just
differ in *where* the choice is recorded:

### User scope — available in every project (the simple default)

From inside any Claude Code session:

```text
/plugin marketplace add yotamleo/himmel      # register this marketplace (once)
/plugin install <name>@himmel                 # grab a single plugin
```

The plugin is enabled for **you**, across all your projects, recorded in
`~/.claude/settings.json`. Best when it's your own setup and you want it
everywhere.

### Project scope — pinned to one repo, shared with collaborators

Commit the marketplace + the plugins you want into the repo's
`.claude/settings.json`, so anyone who clones it gets them auto-known and
enabled (Claude Code still prompts each person to trust the marketplace on
first use):

```jsonc
{
  "extraKnownMarketplaces": {
    "himmel": { "source": { "source": "github", "repo": "yotamleo/himmel" } }
  },
  "enabledPlugins": {
    "obsidian-triage@himmel": true
  }
}
```

Or let the CLI write that block for you — run from the target repo:
`claude plugin install <name>@himmel --scope project` (also accepts `--scope
local` for the gitignored `.claude/settings.local.json`). The himmel setup
scripts expose the same choice: `scripts/machine-setup/install-plugins.{sh,ps1}
--scope project`, and the top-level setup prompts for it.

Best when the plugin is part of *this project's* workflow and you want
contributors to pick it up on clone. (Heads-up: committing
`extraKnownMarketplaces` ships a "trust this third-party registry" into the
repo — fine for your own repos, a supply-chain call to make if it has
outside contributors.)

### Remove, or move between scopes

- **Remove (user scope):** `/plugin uninstall <name>@himmel`.
- **Remove (project scope):** delete that plugin's `enabledPlugins` line from
  the repo's `.claude/settings.json` (drop the `extraKnownMarketplaces.himmel`
  block too once no himmel plugin is left).
- **Move user → project:** `/plugin uninstall <name>@himmel`, then add it to
  the repo's `.claude/settings.json` as shown above.
- **Move project → user:** remove its `enabledPlugins` line from the repo
  settings, then `/plugin install <name>@himmel` in a session.

Prefer a local checkout over GitHub? Point the marketplace at the cloned path
instead: `/plugin marketplace add /path/to/himmel` (user scope), or use
`{ "source": "/path/to/himmel" }` as the project-scope source.

## What's in here

The **Travels** column tells you how portable a plugin is on its own:

- **✅ standalone** — works in any repo/vault, no himmel assumptions.
- **🔶 fork** — a vendored fork of an upstream plugin; portable, but read the
  plugin's README for the fork delta and upstream-watch note.
- **🔗 harness-coupled** — assumes the himmel harness or the operator's personal
  setup. Installable anywhere, but only useful in context.

| Plugin | What you get | Travels | License |
|---|---|---|---|
| **obsidian-triage** | Autonomous triage + cross-clip synthesis for Obsidian Web Clipper output. Commands: `/triage-clips`, `/synthesize-clips`, `/harvest-clips`, `/archive-clips`; skills: `telegram-clip`, `roadmap-clips`, `luna-ingest`. | ✅ standalone | — |
| **claude-obsidian** | Claude + Obsidian knowledge companion — wiki query, save, ingest, lint, autoresearch. Companion to obsidian-triage. Pinned GitHub fork of [AgriciDaniel/claude-obsidian](https://github.com/AgriciDaniel/claude-obsidian). | ✅ standalone | MIT |
| **obsidian** | Steph Ango's Obsidian skills: `obsidian-markdown` (OFM), `obsidian-bases`, `json-canvas`, `obsidian-cli`, `defuddle`. Pinned fork of [kepano/obsidian-skills](https://github.com/kepano/obsidian-skills). | ✅ standalone | MIT |
| **pr-review-toolkit-himmel** | Vendored `code-reviewer` agent + a verify-before-critical sub-rule patch (HIMMEL-178). The other 5 agents stay on upstream `pr-review-toolkit:*`. | 🔶 fork | Apache-2.0 |
| **telegram-himmel** | Telegram channel MCP plugin with the `getUpdates` poller gated behind `TELEGRAM_OWN_POLLER=1`, so only the owner session polls the single bot-token slot. Fork of `telegram@claude-plugins-official` v0.0.6. | 🔶 fork | Apache-2.0 |
| **himmel-ops** | Harness-meta operational skill: `stuck-playbook` surfaces guardrail-recovery escape-hatches when an auto-mode write is denied, a Bash command falls through to the classifier, a permission prompt hangs, or a pre-push gate fails (HIMMEL-211). | 🔗 harness-coupled | — |
| **handover** | Session handover tracking — manages epics, tasks, standalones, and session handovers via `~/.claude/handover/registry.json`. Built around the operator's multi-session workflow. | 🔗 harness-coupled | — |

Per-plugin detail (and fork rationale / upstream-watch protocol where it
applies) lives in each plugin's own README under
[`plugins/<name>/README.md`](plugins/). For where each plugin sits in the
wider toolset, see [`docs/tooling-catalog.md`](../docs/tooling-catalog.md).
