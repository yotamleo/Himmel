---
description: Update this himmel checkout (harness) — git pull + marketplace re-sync + hermes junior-tier update. autoUpdate does NOT deliver himmel updates. For the luna vault, use /luna-upgrade; for both at once, /himmel-update-all.
---

Updates an existing himmel install. **`git pull` is the only thing that
delivers a himmel update** — the marketplace is registered from a local
`directory` source, so Claude Code's `autoUpdate` only re-syncs plugins from
the on-disk dir; and the core hooks + slash commands aren't plugins at all.
Full model: `docs/setup/updating.md` in the himmel checkout.

Does four steps: fast-forward pull of this checkout,
`claude plugin marketplace update himmel` to refresh plugins from the
freshly-pulled dir, a **hermes junior-tier update** (HIMMEL-426 — hermes is a
separate editable git checkout *outside* this repo, so `git pull` here never
touches it; this pulls + reinstalls it, skipping cleanly when hermes isn't
installed), then a **plugin install-state report** — `marketplace update` only
re-syncs plugins that are *already installed*, so it can't tell you a
himmel-marketplace plugin is missing, or is being served from a non-`@himmel`
marketplace whose `autoUpdate` shadows the himmel SHA pin (HIMMEL-434). The
report prints the `claude plugin install …@himmel` / migrate commands for any
gap.

This command can run from **any directory** (HIMMEL-459), so first resolve the
himmel checkout using the same checkout-resolution order as
`marketplace/plugins/himmel-ops/scripts/legs.sh` (here it fails closed with an
error; legs.sh fails open): `$HIMMEL_REPO` → the current git toplevel →
canonical install paths → error. Run the resolver, then ONE of the update forms:

```bash
# Resolve the himmel checkout: $HIMMEL_REPO -> git toplevel -> canonical -> error.
REPO="${HIMMEL_REPO:-}"
[ -n "$REPO" ] && [ -f "$REPO/scripts/himmel-update.sh" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO" ] || [ ! -f "$REPO/scripts/himmel-update.sh" ]; then
  for c in "$HOME/Documents/github/himmel" "$HOME/Documents/github/Himmel" "$HOME/github/himmel" "$HOME/github/Himmel"; do
    [ -f "$c/scripts/himmel-update.sh" ] && { REPO="$c"; break; }
  done
fi
[ -f "$REPO/scripts/himmel-update.sh" ] || { echo "ERR: cannot locate himmel checkout — set HIMMEL_REPO to your himmel clone" >&2; exit 1; }

# Then run ONE of:
bash "$REPO/scripts/himmel-update.sh"                 # pull + re-sync + gap report
bash "$REPO/scripts/himmel-update.sh" --check         # report only (behind/ahead + gaps), no pull
bash "$REPO/scripts/himmel-update.sh" --plugins-check # just the plugin gap report, no git
```

After it finishes: hooks are live immediately; **restart any running Claude
session** to pick up plugin / slash-command / skill changes. To act on a
*shadowed* plugin (e.g. `claude-obsidian`, `obsidian` served from their
external marketplaces), run the migration **operator-present, in a fresh
session**: `$REPO/scripts/machine-setup/migrate-plugin-to-himmel.sh`.
