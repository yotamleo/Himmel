---
description: Embedding-indexed lookup over installed skills/commands/agents — eliminates wrong-namespace mistakes.
argument-hint: <intent text> [--namespace <plugin>] [--limit N]
---

Finds the best-matching skill, slash command, or agent for an intent
description. Backed by qmd's hybrid BM25 + vector search over the
`skills` collection. Eliminates the wrong-namespace mistakes that
session-start skill listings cause (e.g. `obsidian-capture` vs
`claude-obsidian:save`).

## Workflow

1. **Check + query in one step.** Run:

   ```bash
   bash scripts/skill-index/skill-find.sh "$ARGUMENTS" "${LIMIT:-5}"
   ```

   This checks the `skills` qmd collection is registered and non-empty
   before ever querying (bare `qmd` inside Claude's Bash tool resolves
   to the broken plugin-cache stub, HIMMEL-163 — the script goes
   through the `scripts/lib/qmd-bin.sh` resolver, never bare `qmd`).

   - **Exit 3** (collection missing or empty): the script prints the
     exact two rebuild commands on stderr. Run them verbatim, then
     retry the query. Never fall back to guessing skill/command names
     from `ls`/`grep` — that silent reversion to pre-HIMMEL-33
     behavior is the failure mode this check exists to prevent
     (HIMMEL-2222). Re-run the two rebuild commands after any plugin
     install/uninstall too, since nothing auto-rebuilds yet.
   - **Exit 127**: qmd is not resolvable on this machine at all — report
     that, don't guess either.
   - **Exit 0**: the query ran; its stdout is the raw qmd hits to
     report per step 2 below.

   When `--namespace <plugin>` is passed, filter the results to entries
   whose `plugin:` frontmatter field matches.

2. **Report results.** Print top-K matches:
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
