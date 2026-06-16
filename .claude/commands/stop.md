---
description: Graceful-halt marker for in-progress /overnight-shift sessions (HIMMEL-137).
argument-hint: [--hard | --reset]
---

Sets the `~/.claude/.overnight-stop` marker that the overnight-mode
dispatcher polls between Phase 3 subagent dispatches. When set, the
dispatcher finishes the in-flight subagent + halts gracefully before
starting the next one — no partial state.

## Modes

| Flag       | Behavior                                                                            |
|------------|-------------------------------------------------------------------------------------|
| _(no flag)_| Soft stop. `bash scripts/overnight/stop-marker.sh set` — touches the marker.        |
| `--hard`   | Soft stop + invoke `TaskStop` on every running Task subagent in this session.       |
| `--reset`  | `bash scripts/overnight/stop-marker.sh clear` — removes the marker.                 |

## Workflow

1. Parse `$ARGUMENTS` for `--hard`, `--reset`, or none.
2. Run the literal form for the parsed mode — no command substitution
   (HIMMEL-203 bash-shape rule: `$(…)` makes the permission matcher bail):

   - No args (soft stop) or `--hard`: `bash scripts/overnight/stop-marker.sh set`
   - `--reset`: `bash scripts/overnight/stop-marker.sh clear`

3. **Only when `--hard` is passed:** after setting the marker, walk
   the current session's active Task tool agents (via `TaskList`) and
   invoke `TaskStop` on each one whose status is `in_progress`. This
   kills the in-flight subagent rather than waiting for it to return.

4. Report status to the operator:
   - Soft stop: `Soft stop armed. Current subagent will finish; no new dispatches.`
   - Hard stop: `Hard stop armed. N in-flight subagents stopped.`
   - Reset: `Stop marker cleared. Next /overnight-shift will run normally.`

## Dispatcher contract (consumers)

Any long-running dispatch loop (overnight-mode Phase 3, future
`/overnight-shift` fanout, autonomous loops) MUST poll the marker
between dispatches:

```bash
if bash scripts/overnight/stop-marker.sh check; then
    echo "stop marker set — halting before next dispatch"
    exit 0
fi
```

`check` is silent (no stdout/stderr) and exits 0 when the marker
exists, 1 when it doesn't. Cheap to call.

## Status inspection

`bash scripts/overnight/stop-marker.sh status` prints human-readable
state (SET with timestamp, or CLEAR) regardless of marker presence.
Always exits 0.

## Smoke test

`bash scripts/overnight/test-stop-marker.sh` — 9-scenario test (set,
check, clear, aliases, idempotence, status, unknown-subcommand,
filesystem-error). All pass.
