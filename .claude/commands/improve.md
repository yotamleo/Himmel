---
description: Refine a draft prompt via a hybrid clarifying-Q workflow; writes an audit artifact and returns the refined prompt.
argument-hint: <draft-prompt>
---

`/improve <draft>` refines a draft prompt before you submit it for real. Runs a
hybrid clarifying-question workflow (always anchor on success criterion,
optionally probe content-specific ambiguity), writes the result to disk for
audit, and returns the refined prompt so you can copy + resubmit (or pass it
through directly when the operator wants the refined prompt to fire).

## Workflow

1. **Read $ARGUMENTS as the draft prompt.** If empty, print usage + exit.
2. **Analyze the draft.** Identify ambiguity along these axes:
   - Audience / target: who is reading the response? (operator self, user, peer)
   - Scope: bounded (single-file edit) vs unbounded (open-ended exploration)?
   - Success criterion: implicit ("make it work") vs explicit (test passes, file shipped)?
   - Constraints: time-budget, token-budget, tool restrictions, do-not-touch?
3. **Ask clarifying questions** via the `AskUserQuestion` tool. Pattern:
   - **Always ask the anchor question:** "What does done look like for this prompt?"
     (multi-choice options drawn from the draft, plus 'Other' fallback)
   - **If ambiguity detected on audience/scope/constraints, ask 1-2 content-specific Qs.**
     Skip if the draft already pins them.
   - Cap at 3 questions total — don't drown the operator in clarifications.
4. **Synthesize the refined prompt.** Apply prompting best practices:
   - Lead with goal (one sentence).
   - Inline the success criterion verbatim.
   - State constraints + non-goals explicitly.
   - Reference relevant files / tickets / docs by path (cold-readable).
   - Drop hedging ("maybe", "I think we could").
5. **Write the audit artifact.** Call:
   ```bash
   bash scripts/improve/save-artifact.sh \
     --original "<original draft>" \
     --refined "<refined prompt>" \
     --notes "<clarifying-Q answers summary>"
   ```
   The helper resolves `<HANDOVER_DIR>/.improve/` (Mode B) or
   `<repo>/.improve/` (Mode A), writes a timestamped markdown file with
   frontmatter (`name`, `created`, `original_chars`, `refined_chars`), and
   prints the artifact path on stdout.
6. **Return the refined prompt** as the chat response. Wrap in a fenced code
   block so the operator can copy-paste. Append the artifact path so the
   operator can audit later.

## Common invocations

```bash
# Refine an exploratory draft.
/improve I want to add some better logging to the api

# Refine a long handover-style prompt (paste inline).
/improve $(cat draft-prompt.md)
```

## Failure modes

- `$ARGUMENTS` empty → print usage, exit. Do not invoke artifact helper.
- `save-artifact.sh` non-zero → still return the refined prompt to the
  operator; warn that the audit file was not written + include the helper's
  stderr in the response.
- `HANDOVER_DIR` set but missing → helper fails-closed (rc=2). Surface the
  error verbatim so the operator can fix the env.

## Disk artifact format

```markdown
---
name: improve-{{timestamp}}
created: {{ISO-8601 UTC}}
original_chars: 142
refined_chars: 318
mode: A|B
---

# Original draft

> {{original verbatim, blockquoted}}

# Clarifying-Q answers

- Success criterion: {{anchor answer}}
- {{content-specific Q 1}}: {{answer}}
- {{content-specific Q 2}}: {{answer}}

# Refined prompt

{{refined prompt verbatim}}

# Rationale

{{1-2 sentences on the key ambiguities resolved + how the refinement addressed them}}
```

Artifacts accumulate under `.improve/` and are not auto-pruned. They're useful
for evaluating prompt-improvement quality over time and for re-running
refinements when the operator wants to tweak.

**Sensitivity note:** artifacts contain the original draft + refined prompt
verbatim. If the operator pasted credentials, API keys, or sensitive context
into the draft, those values land on disk inside the artifact. Mode A
artifacts are gitignored; Mode B writes to private `<state-repo>`. Treat the
`.improve/` directory as sensitive regardless — do not commit + do not copy
off-disk without redacting first.
