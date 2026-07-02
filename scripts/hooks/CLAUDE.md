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

## Bypass model (don't redesign)
PreToolUse bypass is a session env var set in the **launching shell**
(e.g. `EDIT_ON_MAIN_OK=1 claude`); a per-call prefix does NOT reach the
hook process.

## Reference
- Hook + guardrail detail:
  [`docs/internals/enforcement.md`](../../docs/internals/enforcement.md).
