---
name: skill-find
description: Embedding-indexed lookup over installed skills/commands/agents — eliminates wrong-namespace mistakes. Use when the user asks which skill/command/agent fits an intent, or runs /skill-find.
---

# skill-find

When the user asks which skill/command/agent fits an intent, find the
best match via qmd's hybrid BM25 + vector search over the `skills` collection.

1. **Ensure the index exists.** If `$SKILL_INDEX_DIR` (default
   `$HOME/.claude/skill-index`) is empty, build + ingest it:

       bash scripts/skill-index/build-skill-index.sh
       bash -c 'source scripts/lib/qmd-bin.sh; qmd_cmd ingest --collection skills "$HOME/.claude/skill-index"'

   Always go through the `scripts/lib/qmd-bin.sh` resolver — bare `qmd` resolves
   to the broken plugin-cache stub. Re-run both after plugin install/uninstall.

2. **Query** with the intent text (substitute it for `<intent>`):

       bash -c 'source scripts/lib/qmd-bin.sh; qmd_cmd query --collection skills --intent "<intent>" --lex "<intent>" --vec "<intent>" --limit 5'

3. **Report** the top matches: `<qualified-name>` (e.g. `pr-review-toolkit:code-reviewer`),
   `<kind>` (command|agent|skill), `<plugin>` (or `local`). See `.claude/commands/skill-find.md`.
