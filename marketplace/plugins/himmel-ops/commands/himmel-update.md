---
description: Update this himmel checkout (harness) — six-item dependency chain (pull, marketplace, jira CLI dist, qmd fork, hermes, luna template) with per-item status + abort-on-first-failure, plus seven best-effort advisory steps (codex re-sanitize, statusLine re-wire, graphify pin sync, plugin gap report, plugin-set reconcile, cadence/guardrail drift checks, dependency-readiness check). `himmelctl update` runs the same engine. autoUpdate does NOT deliver the checkout (git pull) or the core hooks/slash-commands — it only re-syncs installed plugins from the on-disk dir. A configured LUNA_VAULT_PATH is already refreshed by step 6 of this chain; use /luna-upgrade only for an explicit Luna-only run, and /himmel-update-all for multi-vault workflows.
---

Updates an existing himmel install. **`git pull` is the only thing that
delivers a himmel update** — the marketplace is registered from a local
`directory` source, so Claude Code's `autoUpdate` only re-syncs plugins from
the on-disk dir; and the core hooks + slash commands aren't plugins at all.
Full model: `docs/setup/updating.md` in the himmel checkout. `node
scripts/himmelctl/bin.js update` (or `himmelctl update` if wired) is a thin
front-end that shells out to the exact same `scripts/himmel-update.sh` engine
described below, so the two entry points never drift.

In **apply mode** (no `--check`), refuses to run against a **dirty checkout**
(uncommitted changes) up front — commit or stash first, then re-run. (The
read-only `--check` mode does not reject a dirty tree.) To update through
deliberately-kept local tracked diffs (e.g. locally-installed skills), set
`HIMMEL_UPDATE_AUTOSTASH=1` per-invocation to autostash them around the pull
(HIMMEL-1197). On a clean tree it runs
a **six-item dependency chain, in order**: (1) `git pull --ff-only` of this checkout, (2)
`claude plugin marketplace update himmel` to refresh plugins from the
freshly-pulled dir, (3) a **jira CLI dist rebuild** (`scripts/jira/dist` is
gitignored, so a pull that touches the jira TypeScript source needs a
rebuild to take effect), (4) a **qmd fork update** (qmd ships from a
himmel-pinned fork outside this checkout), (5) a **hermes junior-tier
update** (HIMMEL-426 — hermes is a separate editable git checkout *outside*
this repo, so `git pull` here never touches it; this pulls + reinstalls it),
and (6) a **luna template upgrade** (`LUNA_VAULT_PATH`, content-preserving).
Each item reports one of `updated` / `up-to-date` / `skipped` / `failed` /
`not-attempted` in a closing status table. The **first genuine failure aborts
the chain** — later items report `not-attempted`, the table still prints, and
the script exits non-zero.

After the chain (win or lose — these never abort and always run, restoring
their pre-existing best-effort behavior even on a chain failure) come seven
advisory steps: a **codex plugin re-sync + hooks.json re-sanitize**
(HIMMEL-742), a **statusLine hud re-wire** (HIMMEL-718), a **graphify pin
sync** (HIMMEL-1048) — rolls an EXISTING `uv`-managed graphify install
forward to the pinned version, so a pin bump in this checkout actually
reaches the machine (`git pull` alone only updates the resolver script, not
the installed tool); it reinstalls graphify via `uv` when the pinned version
differs, skips cleanly when `uv` or the install is absent, and never aborts
the chain on failure — a **plugin install-state report** — `marketplace
update` only re-syncs plugins that are *already installed*, so it can't tell
you a himmel-marketplace plugin is missing, or is being served from a
non-`@himmel` marketplace whose `autoUpdate` shadows the himmel SHA pin
(HIMMEL-434; the report prints the `claude plugin install …@himmel` /
migrate commands for any gap) — a **lean plugin-set reconcile** (HIMMEL-1032,
warn-only unless `HIMMEL_RECONCILE_PLUGINS=1`), stale **cadence-runner** /
**guardrail-mode block** drift checks, and a **dependency-readiness check**
(HIMMEL-1393) — surfaces an enabled skill missing its declared API key, or
an enabled+keyed skill whose docs still mark its toolkit disabled
(presence-only, no key values read).

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
bash "$REPO/scripts/himmel-update.sh"                 # six-item chain + advisory steps
bash "$REPO/scripts/himmel-update.sh" --check         # report only (behind/ahead + gaps), no pull
bash "$REPO/scripts/himmel-update.sh" --plugins-check # just the plugin gap report, no git
# equivalent entry point:
node "$REPO/scripts/himmelctl/bin.js" update          # same engine, thin wrapper
```

After it finishes: hooks are live immediately; **restart any running Claude
session** to pick up plugin / slash-command / skill changes. To act on a
*shadowed* plugin (e.g. `claude-obsidian`, `obsidian` served from their
external marketplaces), run the migration **operator-present, in a fresh
session**: `$REPO/scripts/machine-setup/migrate-plugin-to-himmel.sh`.
