---
allowed-tools: Bash, Read, Skill
description: Extract a grow-tent feed/watering or nutrient-label photo from a Telegram message into luna's Grow-Feeding-Log.md.
argument-hint: <message text> [--vault <path>] [--dry-run]
---

# /grow-feed-log — slash-command wrapper (LUNA-130)

Invoke the `obsidian-triage:grow-feed-log` skill via the `Skill` tool with
`$ARGUMENTS` as the literal `args` parameter — do NOT inline or paraphrase
the runbook body here, the skill is the single source of truth.

Concretely, execute exactly this tool call (substituting `$ARGUMENTS`
literally — Claude Code's slash-command preprocessor replaces it with
whatever the operator typed after `/grow-feed-log`):

```
Skill { skill: "obsidian-triage:grow-feed-log", args: "$ARGUMENTS" }
```

This wrapper exists so the operator can keep typing `/grow-feed-log
<message text>` at the user prompt without learning the `/<plugin>:<skill>`
form, AND so a future interactive telegram channel session (LUNA-127,
out of scope here) dispatching the skill programmatically uses the same
Skill-tool call shape (HIMMEL-128: no headless invocations).

Per the skill's own `## Inputs` section: `$ARGUMENTS` supplies the message
text only — sender and message-id are NOT parsed out of it. On this manual
path the sender is the operator and the message-id is the current
`<channel>` `message_id` if present, else a stable id the operator supplies.
The skill must never invent a message-id; if this manual invocation carries
no channel context and no operator-supplied id, it stops and asks rather
than fabricating one (a fabricated id would defeat `--msg-id` idempotency).

If the `obsidian-triage` plugin is not installed (the `Skill` tool refuses
with "skill not found" or similar): fail loudly with `ERR grow-feed-log:
obsidian-triage plugin not installed; /plugin install obsidian-triage from
the himmel marketplace, or invoke /grow-feed-log after installing.` Do NOT
attempt to inline the runbook as a fallback.
