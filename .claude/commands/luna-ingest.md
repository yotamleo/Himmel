---
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, WebSearch, WebFetch
description: Chain-following triage for a github repo URL. Thin wrapper that delegates to the obsidian-triage:luna-ingest skill (LUNA-9 skill conversion — see marketplace/plugins/obsidian-triage/skills/luna-ingest/SKILL.md for the runbook).
argument-hint: <github-url> [--vault <path>] [--dest <category>] [--limit <N>] [--deep] [--research] [--dry-run]
---

# /luna-ingest — slash-command wrapper (LUNA-9)

Invoke the `obsidian-triage:luna-ingest` skill via the `Skill` tool with `$ARGUMENTS` as the literal `args` parameter — do NOT inline or paraphrase the runbook body here, the skill is the single source of truth.

Concretely, execute exactly this tool call (substituting `$ARGUMENTS` literally — Claude Code's slash-command preprocessor replaces it with whatever the operator typed after `/luna-ingest`):

```
Skill { skill: "obsidian-triage:luna-ingest", args: "$ARGUMENTS" }
```

This wrapper exists so the operator can keep typing `/luna-ingest <url>` at the user prompt without learning the `/<plugin>:<skill>` form, AND so any future `/harvest-clips` (LUNA-10) dispatching the skill programmatically uses the same Skill-tool call shape (HIMMEL-128: no `claude -p` / headless invocations). Per LUNA-3 plan §13.1 + LUNA-9 DoD, this file MUST stay a thin wrapper — never duplicate the runbook body.

If the `obsidian-triage` plugin is not installed (the `Skill` tool refuses with "skill not found" or similar): fail loudly with `ERR luna-ingest: obsidian-triage plugin not installed; /plugin install obsidian-triage from the himmel marketplace, or invoke /luna-ingest after installing.` Do NOT attempt to inline the runbook as a fallback.
