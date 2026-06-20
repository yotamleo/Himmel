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

**Step 1 — harness.** If `$ARGUMENTS` contains `--check`, run the dry-run form; otherwise the real update:

```bash
bash scripts/himmel-update.sh --check   # when --check was passed
# otherwise:
bash scripts/himmel-update.sh
```

Only `--check` is forwarded to the harness step — the vault-specific flags (`--vault`, `--template-dir`) are not understood by `himmel-update.sh` and must NOT be passed to it.

The harness step's plugin install-state report flags any himmel-marketplace plugin still served from another marketplace whose `autoUpdate` shadows the `@himmel` pin (e.g. `claude-obsidian` left over from `claude-obsidian-marketplace` or the luna vault's `luna-brain`). If it reports a shadow, run the `migrate-plugin-to-himmel.sh --apply <name@market> …` command it prints (operator-present) to converge onto `@himmel`.

**Step 2 — luna vault.** Delegate to the skill, forwarding the full `$ARGUMENTS` (the skill handles `--check` / `--vault` / `--template-dir` itself, and runs its own dry-run → confirm → apply gate):

```
Skill { skill: "obsidian-triage:luna-upgrade", args: "$ARGUMENTS" }
```

If the `obsidian-triage` plugin is not installed (the `Skill` tool refuses with "skill not found" or similar): report the harness result, then fail the vault step loudly with `ERR himmel-update-all: obsidian-triage plugin not installed; /plugin install obsidian-triage from the himmel marketplace, or run bash templates/luna-second-brain/scripts/upgrade.sh directly.` Do NOT inline the runbook as a fallback.

After both steps: harness hooks are live immediately; **restart any running Claude session** to pick up plugin / slash-command / skill changes.
