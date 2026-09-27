---
name: skill-find
description: Embedding-indexed lookup over installed skills/commands/agents. Use for which-skill-fits or /skill-find.
---

# skill-find

When the user asks which skill/command/agent fits an intent, find the
best match via qmd's hybrid BM25 + vector search over the `skills` collection.

1. **Check + query** with the intent text (substitute it for `<intent>`):

       bash scripts/skill-index/skill-find.sh "<intent>" 5

   Checks the `skills` qmd collection is registered and non-empty before
   querying, and goes through the `scripts/lib/qmd-bin.sh` resolver — bare
   `qmd` resolves to the broken plugin-cache stub. On exit 3 the collection
   is missing/empty: the script prints the two rebuild commands on stderr —
   run them verbatim, then retry. Never fall back to guessing skill/command
   names (HIMMEL-2222). Re-run the rebuild commands after plugin
   install/uninstall too.

2. **Report** the top matches: `<qualified-name>` (e.g. `pr-review-toolkit:code-reviewer`),
   `<kind>` (command|agent|skill), `<plugin>` (or `local`). See `.claude/commands/skill-find.md`.
