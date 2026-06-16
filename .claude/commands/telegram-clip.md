---
allowed-tools: Bash, Read, Write, Skill
description: File a Telegram message (text / bare URL / forward) as a harvest-ready LUNA-2 clip note in the luna vault's Clippings/. Thin wrapper that delegates to the obsidian-triage:telegram-clip skill (LUNA-58 — see marketplace/plugins/obsidian-triage/skills/telegram-clip/SKILL.md for the runbook).
argument-hint: <message text or URL> [--vault <path>] [--dry-run]
---

# /telegram-clip — slash-command wrapper (LUNA-58)

Invoke the `obsidian-triage:telegram-clip` skill via the `Skill` tool with `$ARGUMENTS` as the literal `args` parameter — do NOT inline or paraphrase the runbook body here, the skill is the single source of truth.

Concretely, execute exactly this tool call (substituting `$ARGUMENTS` literally — Claude Code's slash-command preprocessor replaces it with whatever the operator typed after `/telegram-clip`):

```
Skill { skill: "obsidian-triage:telegram-clip", args: "$ARGUMENTS" }
```

This wrapper exists so the operator can keep typing `/telegram-clip <text-or-url>` at the user prompt without learning the `/<plugin>:<skill>` form, AND so the interactive telegram channel session dispatching the skill programmatically uses the same Skill-tool call shape (HIMMEL-128: no `claude -p` / headless invocations).

If the `obsidian-triage` plugin is not installed (the `Skill` tool refuses with "skill not found" or similar): fail loudly with `ERR telegram-clip: obsidian-triage plugin not installed; /plugin install obsidian-triage from the himmel marketplace, or invoke /telegram-clip after installing.` Do NOT attempt to inline the runbook as a fallback.
