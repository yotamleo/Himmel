---
allowed-tools: Bash, Read, Skill
description: Update BOTH surfaces in one shot — the himmel harness (/himmel-update) then the luna vault (/luna-upgrade). Pass --check to dry-run both without changing anything.
argument-hint: [--check] [--vault <path>] [--template-dir <path>]
---

# /himmel-update-all — update the himmel harness AND the luna vault (HIMMEL-426)

himmel has two independent update surfaces:
- **harness** (hooks, slash commands, scripts, plugins) — pulled by `/himmel-update` / `scripts/himmel-update.sh`.
- **luna vault** (bundled-plugin assets, `.obsidian` config, `_CLAUDE.md`, scaffold) — refreshed by the `obsidian-triage:luna-upgrade` skill, content-preserving.

This combo runs both, **harness first** (so the latest template + skill are on disk before the vault upgrade reads them), then the vault. Run the two steps in order:

**Step 1 — harness.** This command can run from **any directory** (HIMMEL-459), so first resolve the himmel checkout using the same checkout-resolution order as `marketplace/plugins/himmel-ops/scripts/legs.sh` (here it fails closed with an error; legs.sh fails open): `$HIMMEL_REPO` → the current git toplevel → canonical install paths → error. If `$ARGUMENTS` contains `--check`, run the dry-run form; otherwise the real update:

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

bash "$REPO/scripts/himmel-update.sh" --check   # when --check was passed
# otherwise:
bash "$REPO/scripts/himmel-update.sh"
```

Only `--check` is forwarded to the harness step — the vault-specific flags (`--vault`, `--template-dir`) are not understood by `himmel-update.sh` and must NOT be passed to it.

The harness step's plugin install-state report flags any himmel-marketplace plugin still served from another marketplace whose `autoUpdate` shadows the `@himmel` pin (e.g. `claude-obsidian` left over from `claude-obsidian-marketplace` or the luna vault's `luna-brain`). If it reports a shadow, run the `migrate-plugin-to-himmel.sh --apply <name@market> …` command it prints (operator-present) to converge onto `@himmel`.

**Step 2 — luna vault.** Delegate to the skill, forwarding the full `$ARGUMENTS` (the skill handles `--check` / `--vault` / `--template-dir` itself, and runs its own dry-run → confirm → apply gate):

```
Skill { skill: "obsidian-triage:luna-upgrade", args: "$ARGUMENTS" }
```

If the `obsidian-triage` plugin is not installed (the `Skill` tool refuses with "skill not found" or similar): report the harness result, then fail the vault step loudly with `ERR himmel-update-all: obsidian-triage plugin not installed; /plugin install obsidian-triage from the himmel marketplace, or run bash "$REPO/templates/luna-second-brain/scripts/upgrade.sh" directly.` Do NOT inline the runbook as a fallback.

After both steps: harness hooks are live immediately; **restart any running Claude session** to pick up plugin / slash-command / skill changes.
