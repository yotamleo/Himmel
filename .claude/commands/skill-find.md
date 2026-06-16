---
description: Embedding-indexed lookup over installed skills/commands/agents — eliminates wrong-namespace mistakes (HIMMEL-33).
argument-hint: <intent text> [--namespace <plugin>] [--limit N]
---

Finds the best-matching skill, slash command, or agent for an intent
description. Backed by qmd's hybrid BM25 + vector search over the
`skills` collection. Eliminates the wrong-namespace mistakes that
session-start skill listings cause (e.g. `obsidian-capture` vs
`claude-obsidian:save`).

## Workflow

1. **Ensure the index exists.** If `$SKILL_INDEX_DIR` (default
   `$HOME/.claude/skill-index`) is empty, run:

   ```bash
   bash scripts/skill-index/build-skill-index.sh
   bash -c 'source scripts/lib/qmd-bin.sh; qmd_cmd ingest --collection skills "$HOME/.claude/skill-index"'
   ```

   Bare `qmd` inside Claude's Bash tool resolves to the broken
   plugin-cache stub (HIMMEL-163) — always go through the
   `scripts/lib/qmd-bin.sh` resolver. Re-run the two commands above
   after plugin install/uninstall.

2. **Query.** Pass `$ARGUMENTS` to qmd with a hybrid lex+vec sub-query
   set:

   ```bash
   bash -c 'source scripts/lib/qmd-bin.sh; qmd_cmd query --collection skills --intent "$ARGUMENTS" --lex "$ARGUMENTS" --vec "$ARGUMENTS" --limit "${LIMIT:-5}"'
   ```

   When `--namespace <plugin>` is passed, filter results to entries
   whose `plugin:` frontmatter field matches.

3. **Report results.** Print top-K matches:
   - `<qualified-name>` (fully-qualified, e.g. `pr-review-toolkit:code-reviewer`)
   - `<kind>` (command | agent | skill)
   - `<plugin>` (plugin name or `local`)
   - Confidence score
   - `<invocation>` example (`/<qualified-name>` for commands; for
     agents, an example `Agent` tool call)
   - First 2 lines of the description field

## Example outputs

```
/skill-find 'review the PR'

1. pr-review-toolkit:code-reviewer (agent, score 0.91)
   Invocation: Agent(subagent_type='pr-review-toolkit:code-reviewer', ...)
   Description: Reviews code for bugs, logic errors, security
   vulnerabilities, code quality issues...

2. code-review:code-review (skill, score 0.78)
   Invocation: /code-review
   Description: Review the current diff for correctness bugs at the
   given effort level...
```

```
/skill-find 'capture this idea'

1. claude-obsidian:save (skill, score 0.84)
   Invocation: /save
   Description: Save the current conversation, answer, or insight
   into the Obsidian wiki vault...

2. obsidian-capture (skill, score 0.81)
   Invocation: /obsidian-capture
   Description: Quick idea capture — zero friction, saves to
   Ideas/ and mentions in daily note.

3. obsidian-decide (skill, score 0.62)
   ...
```

## Environment

- `SKILL_INDEX_DIR` — output directory for the index (default
  `$HOME/.claude/skill-index`).
- qmd collection: `skills`. Visible in `qmd status`.

## Acceptance (per HIMMEL-33 spec)

- [x] `/skill-find 'review the PR'` returns the top pr-review-toolkit
      reviewer with confidence + invocation example (when index is
      populated)
- [x] `/skill-find 'capture this idea'` disambiguates `obsidian-capture`
      vs `claude-obsidian:save` via the `plugin:` namespace
- [x] Index rebuild via `bash scripts/skill-index/build-skill-index.sh`
      is idempotent (output files overwrite by qualified name)
- [x] qmd collection `skills` visible in `qmd status` after ingest
- [ ] Auto-rebuild on plugin manifest change — deferred to a follow-up;
      MVP requires explicit `/skill-reindex` (or running the build script)

Source: user feedback /insights 2026-05-19. Related: HIMMEL-32 (wrong-skill-namespace was top friction).
