# himmel working principles (user-scope template)

`scripts/adopt.sh` / `adopt.ps1` append the fenced block below to your
user-scope `~/.claude/CLAUDE.md` (creating the file if absent). The block is
delimited by the `HIMMEL:working-principles` markers; the installer skips
entirely when the start marker is already present, so re-running adopt adds
nothing and never rewrites a hand-edited file.

These four defaults used to sit in himmel's project `CLAUDE.md`. They are
general engineering defaults, not himmel invariants, so they belong on the
user-scope layer where every project gets them once instead of every himmel
session paying for them (HIMMEL-2038). Operator machines that already carry a
user-scope `CLAUDE.md` with these principles are detected and left alone.

**Why this is not the same file as
[`global-claude-md.md`](global-claude-md.md)**, which states the same four
principles: that one is the *operator's* personal user-scope file, copied
wholesale on a new machine and ending in an `@RTK.md` import an adopter has no
file for. It is the operator's to reword. This one is the adopter payload with
a stable marker fence, and adopt.sh reads it at run time — so an edit to the
operator's personal prose can never silently change what adopters install.

Everything between (and including) the two marker lines is the payload:

<!-- BEGIN HIMMEL:working-principles -->
## Working principles (general defaults)

Use judgement on trivial tasks.

1. **Think before coding** — read the code the change touches before editing
   it; trace the real flow end to end. State your assumptions and proceed.
   Ask only when different readings of the request would lead to materially
   different work, or when the action is destructive or hard to reverse. If a
   simpler approach exists, take it unless told otherwise.
2. **Simplicity first** — the minimum code that solves the problem. Nothing
   speculative: no unrequested features, abstractions, configurability, or
   error handling for impossible scenarios.
3. **Surgical changes** — touch only what the task requires. Match the existing
   style. Don't refactor what isn't broken. Remove only the orphans your own
   change created; mention unrelated dead code rather than deleting it.
4. **Verify before you claim** — turn the task into a check that fails if the
   work is wrong (e.g. a test that reproduces the bug). Make it pass, then
   report the actual result.
<!-- END HIMMEL:working-principles -->
