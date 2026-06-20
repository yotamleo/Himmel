---
description: Update this himmel checkout (harness) — git pull + marketplace re-sync. autoUpdate does NOT deliver himmel updates. For the luna vault, use /luna-upgrade; for both at once, /himmel-update-all.
---

Updates an existing himmel install. **`git pull` is the only thing that
delivers a himmel update** — the marketplace is registered from a local
`directory` source, so Claude Code's `autoUpdate` only re-syncs plugins from
the on-disk dir; and the core hooks + slash commands aren't plugins at all.
Full model: [`docs/setup/updating.md`](../../docs/setup/updating.md).

Does three steps: fast-forward pull of this checkout,
`claude plugin marketplace update himmel` to refresh plugins from the
freshly-pulled dir, then a **plugin install-state report** — `marketplace
update` only re-syncs plugins that are *already installed*, so it can't tell
you a himmel-marketplace plugin is missing, or is being served from a
non-`@himmel` marketplace whose `autoUpdate` shadows the himmel SHA pin
(HIMMEL-434). The report prints the `claude plugin install …@himmel` / migrate
commands for any gap.

Run:

```bash
bash scripts/himmel-update.sh                # pull + re-sync + gap report
bash scripts/himmel-update.sh --check        # report only (behind/ahead + gaps), no pull
bash scripts/himmel-update.sh --plugins-check # just the plugin gap report, no git
```

After it finishes: hooks are live immediately; **restart any running Claude
session** to pick up plugin / slash-command / skill changes. To act on a
*shadowed* plugin (e.g. `claude-obsidian`, `obsidian` served from their
external marketplaces), run the migration **operator-present, in a fresh
session**: `scripts/machine-setup/migrate-plugin-to-himmel.sh`.
