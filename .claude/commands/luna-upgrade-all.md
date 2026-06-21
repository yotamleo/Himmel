---
allowed-tools: Bash, Read, Skill
description: Multi-vault upgrade sweep — discover all luna-second-brain vaults, dry-run-first, per-vault operator-confirmed apply, backup/restore safety net, and conflict-brainstorm on _CLAUDE.md conflicts. Thin wrapper that delegates to the obsidian-triage:luna-upgrade-all skill (HIMMEL-462 — see marketplace/plugins/obsidian-triage/skills/luna-upgrade-all/SKILL.md for the runbook).
argument-hint: [--roots <dir[,dir]>] [--registry <path>] [--template-dir <path>] [--porcelain]
---

# /luna-upgrade-all — slash-command wrapper (HIMMEL-462)

Invoke the `obsidian-triage:luna-upgrade-all` skill via the `Skill` tool with `$ARGUMENTS` as the literal `args` parameter — do NOT inline or paraphrase the runbook body here, the skill is the single source of truth.

Execute exactly this tool call (substituting `$ARGUMENTS` literally — Claude Code's slash-command preprocessor replaces it with whatever the operator typed after `/luna-upgrade-all`):

```
Skill { skill: "obsidian-triage:luna-upgrade-all", args: "$ARGUMENTS" }
```

This wrapper exists so the operator can keep typing `/luna-upgrade-all` at the user prompt without learning the `/<plugin>:<skill>` form, mirroring `/luna-upgrade`. Keep it a thin wrapper — never duplicate the runbook body.

If the `obsidian-triage` plugin is not installed (the `Skill` tool refuses with "skill not found" or similar): fail loudly with `ERR luna-upgrade-all: obsidian-triage plugin not installed; /plugin install obsidian-triage from the himmel marketplace, or run bash scripts/luna-upgrade-all.sh directly.` Do NOT attempt to inline the runbook as a fallback.
