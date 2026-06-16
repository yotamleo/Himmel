# himmel marketplace

A Claude Code plugin marketplace. You do **not** need the himmel harness to
use it — most plugins here install and run on their own. Take one item, or
take none and just read the source.

> **New to himmel itself?** The harness (worktrees, guardrails, handover,
> PR-gated loop) is a separate thing — start at
> [`docs/getting-started.md`](../docs/getting-started.md). This page is only
> about the plugins.

## Install just one plugin

From inside any Claude Code session:

```text
/plugin marketplace add yotamleo/himmel      # register this marketplace (once)
/plugin install <name>@himmel                 # grab a single plugin
```

`<name>` is the plugin name from the table below (e.g.
`/plugin install obsidian-triage@himmel`). Each plugin is independent — you
install only what you name; nothing else comes along.

Prefer a local checkout? Point the marketplace at the cloned path instead:
`/plugin marketplace add /path/to/himmel`.

## What's in here

The **Travels** column tells you how portable a plugin is on its own:

- **✅ standalone** — works in any repo/vault, no himmel assumptions.
- **🔶 fork** — a vendored fork of an upstream plugin; portable, but read the
  plugin's README for the fork delta and upstream-watch note.
- **🔗 harness-coupled** — assumes the himmel harness or yotam's personal
  setup. Installable anywhere, but only useful in context.

| Plugin | What you get | Travels | License |
|---|---|---|---|
| **obsidian-triage** | Autonomous triage + cross-clip synthesis for Obsidian Web Clipper output. Commands: `/triage-clips`, `/synthesize-clips`, `/harvest-clips`, `/archive-clips`; skills: `telegram-clip`, `roadmap-clips`, `luna-ingest`. | ✅ standalone | — |
| **claude-obsidian** | Claude + Obsidian knowledge companion — wiki query, save, ingest, lint, autoresearch. Companion to obsidian-triage. Pinned GitHub fork of [AgriciDaniel/claude-obsidian](https://github.com/AgriciDaniel/claude-obsidian). | ✅ standalone | MIT |
| **obsidian** | Steph Ango's Obsidian skills: `obsidian-markdown` (OFM), `obsidian-bases`, `json-canvas`, `obsidian-cli`, `defuddle`. Pinned fork of [kepano/obsidian-skills](https://github.com/kepano/obsidian-skills). | ✅ standalone | MIT |
| **pr-review-toolkit-himmel** | Vendored `code-reviewer` agent + a verify-before-critical sub-rule patch (HIMMEL-178). The other 5 agents stay on upstream `pr-review-toolkit:*`. | 🔶 fork | Apache-2.0 |
| **telegram-himmel** | Telegram channel MCP plugin with the `getUpdates` poller gated behind `TELEGRAM_OWN_POLLER=1`, so only the owner session polls the single bot-token slot. Fork of `telegram@claude-plugins-official` v0.0.6. | 🔶 fork | Apache-2.0 |
| **himmel-ops** | Harness-meta operational skill: `stuck-playbook` surfaces guardrail-recovery escape-hatches when an auto-mode write is denied, a Bash command falls through to the classifier, a permission prompt hangs, or a pre-push gate fails (HIMMEL-211). | 🔗 harness-coupled | — |
| **handover** | Session handover tracking — manages epics, tasks, standalones, and session handovers via `~/.claude/handover/registry.json`. Built around yotam's multi-session workflow. | 🔗 harness-coupled | — |

Per-plugin detail (and fork rationale / upstream-watch protocol where it
applies) lives in each plugin's own README under
[`plugins/<name>/README.md`](plugins/). For where each plugin sits in the
wider toolset, see [`docs/tooling-catalog.md`](../docs/tooling-catalog.md).
