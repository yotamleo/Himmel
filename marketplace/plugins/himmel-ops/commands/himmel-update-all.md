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

If the `Skill` tool refuses the invocation ("skill not found" or similar): report the harness result from Step 1, then fall back to the plugin-independent engine instead of failing (HIMMEL-1153 — the lean plugin floor, HIMMEL-1032, disables `obsidian-triage@himmel` by policy on some machines, which trips this same path even though the plugin is vendored+installed).

**Diagnose first.** `$REPO/marketplace/plugins/obsidian-triage/` is tracked in git, so it existing on disk is true in every himmel checkout and proves nothing about whether the plugin is installed/enabled — only the `enabledPlugins` config does. Check `.claude/settings.local.json` first, then `~/.claude/settings.json`, for an `"obsidian-triage@himmel"` entry (local overrides global). Effective value `false` → **disabled by policy** (remedy: flip it to `true` in whichever file carries the `false`, prefer `.claude/settings.local.json`). No entry in either file → **enabled state unknown/defaulted** — say so honestly, do NOT confidently claim "not installed"; give both remedies (add `"obsidian-triage@himmel": true` to `.claude/settings.local.json`, or `/plugin install obsidian-triage` if it was never registered).

**Then run the fallback regardless.** Translate `$ARGUMENTS`' `--vault <path>` to `--vault-dir <path>`. Resolve `--template-dir` too: if `$ARGUMENTS` supplies one, use it verbatim; otherwise default to `$REPO/templates/luna-second-brain` — do NOT hardcode the default into the commands below and silently drop an operator-supplied override.

- **`--check` in `$ARGUMENTS`:** single pass — run `--check` and surface the one-line result verbatim; nothing to gate.
- **Otherwise (apply path):** mirror the skill's own dry-run → confirm → apply contract — do NOT run straight to `--yes`. A non-interactive `Bash` call hits EOF on the engine's confirm prompt, silently answers "no", and it exits **0** having changed nothing (prints `aborted — no changes made.`); trusting the exit code alone would misreport that as success.
  1. Run `bash "$REPO/templates/luna-second-brain/scripts/upgrade.sh" --template-dir "<resolved template-dir>" --vault-dir "<vault>" --dry-run` and show the operator the printed plan.
  2. Ask the operator to confirm via AskUserQuestion. If they decline, STOP — make no changes.
  3. On confirmation, re-run the identical command with `--yes` instead of `--dry-run`.
  4. Read the engine's own stdout, not just its exit code — if it printed `aborted — no changes made.`, that is **not an apply** regardless of the (0) exit; report that nothing changed, don't claim success.

Prefix whichever report you give with the diagnosis (disabled-by-policy vs unknown/unconfigured) so the operator gets the honest remedy either way. Do NOT inline the skill's runbook logic beyond this mechanical fallback.

After both steps: harness hooks are live immediately; **restart any running Claude session** to pick up plugin / slash-command / skill changes.
