# scripts/hooks — Claude Code hook scripts

Loads only when working in this subtree. The hook *inventory* (which hooks
fire when) and guardrail matrix live in the reference doc below; this file
is how to safely edit a hook.

## Editing conventions
- Most hooks have a paired smoke test `test-<name>.sh` (the suite is the
  spec). **Update it when you change such a hook; add one for new hooks.**
- **bash 3.2-compatible by default** (macOS ships 3.2). Avoid bash 4 features
  (`mapfile` — use a `while IFS= read -r` loop; associative arrays). All hooks
  here are 3.2-safe.
- Hooks fail-closed (non-zero exit blocks the action). Preserve that.
  Exception: `auto-arm-on-cap.sh` is a WATCHDOG, deliberately fail-open
  (it must never block tool calls on its own bugs) — do not "fix" it
  back to fail-closed; see its header for the exit-semantics contract.
- Some hooks have `.ps1` Windows twins (`check-commit-msg`,
  `check-hookspath`) — change both in lockstep.

## Adding a NEW hook (the non-obvious part)
`.claude/settings.json` is **not** the source of truth. Hand-wiring it produces
a hook that either never dispatches or breaks `wire-hook-bash.test.mjs`. Three
places must agree:

1. `scripts/hooks/<name>.sh` — the script.
2. `EXPECTED_SCRIPT_ORDER` in `wire-hook-bash.mjs` — the **frozen ordered
   inventory**, flattened over `--chain` entries, so a guardrail wired for
   several disjoint matchers is listed **once per chain it appears in**
   (HIMMEL-2002). A `scripts/hooks/*.sh` invocation under an owned event
   (`PreToolUse`/`PostToolUse`/`SessionStart`) that is *not* listed is an
   **impostor** and refused (HIMMEL-1552) — deliberately: it is a command the
   wirer would otherwise route and execute.
3. `.claude/settings.json` — in the **same relative order** as the inventory.

Edit all three **in your own worktree** — the copy there is yours to change and
rides your PR. The LIVE copies (the primary checkout's `.claude/settings.json`
and the user-scope `~/.claude/settings.json`) stay guarded by
`block-edit-live-settings.sh`, since a change there takes effect unreviewed
(HIMMEL-2360).

**A committed hook script is not the artifact; a registered, dispatching hook
is.** Confirm with `node scripts/hooks/wire-hook-bash.mjs --check`.

**Never assert a hardcoded hook COUNT in a test** — derive it from
`EXPECTED_SCRIPT_ORDER.length` (exported). Per-event counts are deliberately not
frozen because a second sanctioned writer (the trust ledger) adds entries. A
hardcoded count is a wall the next capability that adds a hook has to climb
(HIMMEL-1952).

## Merging a hook addition — the silent-duplicate trap
A frozen ordered list is a **merge hazard**. Two branches that each add an entry
merge *textually clean, with no conflict markers*, and leave the entry
**duplicated**. This happened in both `wire-hook-bash.mjs` and
`.claude/settings.json` when HIMMEL-1952 and HIMMEL-1802 landed in parallel.

**A clean auto-merge is not evidence of correctness here — check for duplicates
explicitly** after any merge that touches the inventory or settings.

Related: from inside a branch cut before a sibling hook PR merged, that PR's
hook looks exactly like un-inventoried drift. **Before concluding the repo is
broken, check whether your branch is behind main.** The wire suite only runs
when `scripts/hooks/**` changes, so a genuine inventory problem also surfaces on
whichever branch next touches this subtree — not necessarily the one that caused
it. Read the assertion before assuming it is yours.

## Making a hook actually change behaviour
- **Deny + name the exact replacement.** A hook that only emits
  `additionalContext` is prose wearing a hook costume — `additionalContext` does
  **not** produce compliance. What works is refusing the call and printing the
  copy-pasteable command to run instead (`block-graphify-egress.sh`,
  `block-jira-compound-write.sh`, `block-destructive-commands.sh`).
- **Never silently rewrite the command.** Deny + name keeps an audit trail of
  what actually ran; a rewrite hides it.
- **Give every deny a documented single-run bypass** and name it in the message.

## Fail-open vs fail-closed — decide by failure DIRECTION
Default is fail-closed, but the right answer follows from what a false positive
costs:
- **Security fences** (secrets, destructive commands, egress) fail **closed**.
- **Watchdogs** fail **open** — must never block a tool call on their own bug.
- **Workflow nudges** fail **open** on their own infrastructure errors (missing
  `jq`, unparseable JSON). Failing closed there denies every call the hook could
  not parse, and an over-matching nudge becomes the next thing everyone
  bypasses. `require-quiet-run.sh` is this shape.

Scope tightly; for anything that is not a security fence, prefer a false
negative to a false positive.

## Bypass model (don't redesign)
PreToolUse bypass is a session env var set in the **launching shell**
(e.g. `EDIT_ON_MAIN_OK=1 claude`); a per-call prefix does NOT reach the
hook process.

## End-side hooks: enqueue, don't fan out (HIMMEL-2004)
A `Stop`/`SessionEnd` hook must not spawn its own detached tree — that is the
unbounded fan-out HIMMEL-1993 traced the kernel-pool leak to. Route it through
the bounded queue instead: wrap the wired command in
`stop-queue.mjs enqueue --key <name> -- <command>`, or, if the hook already
full-body-detaches itself, swap that one `detach_run` for `detach_queued <key>`.
Never enqueue a command whose ARGUMENTS carry a credential — an entry is a file.
Inspect with `node scripts/hooks/stop-queue.mjs status`, drain by hand with
`… work`. Layout + secrets model:
[`docs/internals/enforcement.md`](../../docs/internals/enforcement.md).

## Reference
- Hook + guardrail detail:
  [`docs/internals/enforcement.md`](../../docs/internals/enforcement.md).
