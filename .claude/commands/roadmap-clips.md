---
allowed-tools: Bash, Read, Write, Skill
description: Aggregate actionable items across the luna vault (daily action items, _deferred.md backlog, synthesis proposals, promotion candidates, component inventory), cluster into a sequenced roadmap mapped to tools, dedup candidate tickets against open Jira, and write a 60-Maps/ roadmap note. Proposals only. Thin wrapper that delegates to the obsidian-triage:roadmap-clips skill (LUNA-59 — see marketplace/plugins/obsidian-triage/skills/roadmap-clips/SKILL.md for the runbook).
argument-hint: "[--vault <path>] [--dry-run]"
---

# /roadmap-clips — slash-command wrapper (LUNA-59)

Invoke the `obsidian-triage:roadmap-clips` skill via the `Skill` tool with `$ARGUMENTS` as the literal `args` parameter — do NOT inline or paraphrase the runbook body here, the skill is the single source of truth.

Concretely, execute exactly this tool call (substituting `$ARGUMENTS` literally — Claude Code's slash-command preprocessor replaces it with whatever the operator typed after `/roadmap-clips`):

```
Skill { skill: "obsidian-triage:roadmap-clips", args: "$ARGUMENTS" }
```

This wrapper exists so the operator can keep typing `/roadmap-clips` at the user prompt without learning the `/<plugin>:<skill>` form (HIMMEL-128: no `claude -p` / headless invocations).

If the `obsidian-triage` plugin is not installed (the `Skill` tool refuses with "skill not found" or similar): fail loudly with `ERR roadmap-clips: obsidian-triage plugin not installed; /plugin install obsidian-triage from the himmel marketplace, or invoke /roadmap-clips after installing.` Do NOT attempt to inline the runbook as a fallback.
