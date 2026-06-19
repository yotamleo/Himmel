---
allowed-tools: Bash, Read, Skill
description: Content-preserving upgrade of an existing luna-second-brain vault to the current himmel template (dry-run → confirm → apply, or --check to just report whether an upgrade is available). Thin wrapper that delegates to the obsidian-triage:luna-upgrade skill (HIMMEL-389 — see marketplace/plugins/obsidian-triage/skills/luna-upgrade/SKILL.md for the runbook).
argument-hint: [--check] [--vault <path>] [--template-dir <path>]
---

# /luna-upgrade — slash-command wrapper (HIMMEL-389)

Invoke the `obsidian-triage:luna-upgrade` skill via the `Skill` tool with `$ARGUMENTS` as the literal `args` parameter — do NOT inline or paraphrase the runbook body here, the skill is the single source of truth.

Execute exactly this tool call (substituting `$ARGUMENTS` literally — Claude Code's slash-command preprocessor replaces it with whatever the operator typed after `/luna-upgrade`):

```
Skill { skill: "obsidian-triage:luna-upgrade", args: "$ARGUMENTS" }
```

This wrapper exists so the operator can keep typing `/luna-upgrade` at the user prompt without learning the `/<plugin>:<skill>` form, mirroring `/luna-ingest`. Keep it a thin wrapper — never duplicate the runbook body.

If the `obsidian-triage` plugin is not installed (the `Skill` tool refuses with "skill not found" or similar): fail loudly with `ERR luna-upgrade: obsidian-triage plugin not installed; /plugin install obsidian-triage from the himmel marketplace, or run bash templates/luna-second-brain/scripts/upgrade.sh directly.` Do NOT attempt to inline the runbook as a fallback.
