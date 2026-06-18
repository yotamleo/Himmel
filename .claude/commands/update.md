---
description: Update this himmel checkout — git pull + marketplace re-sync. autoUpdate does NOT deliver himmel updates.
---

Updates an existing himmel install. **`git pull` is the only thing that
delivers a himmel update** — the marketplace is registered from a local
`directory` source, so Claude Code's `autoUpdate` only re-syncs plugins from
the on-disk dir; and the core hooks + slash commands aren't plugins at all.
Full model: [`docs/setup/updating.md`](../../docs/setup/updating.md).

Does two steps: fast-forward pull of this checkout, then
`claude plugin marketplace update himmel` to refresh plugins from the
freshly-pulled dir.

Run:

```bash
bash scripts/update.sh
```

After it finishes: hooks are live immediately; **restart any running Claude
session** to pick up plugin / slash-command / skill changes.
