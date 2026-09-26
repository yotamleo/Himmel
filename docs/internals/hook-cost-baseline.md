# PreToolUse:Bash cold-start cost — the true 4-matcher shape (HIMMEL-1843)

`docs/internals/enforcement.md`'s dispatcher section (HIMMEL-2002) is stale on
this point and is owned by a parked PR (#1322) rather than fixed here — this
doc is the corrected, standalone baseline until that lands.

## What actually fires on a Bash tool call

A Bash tool call matches every `PreToolUse` group whose matcher pattern
includes `Bash` — not only the group literally named `Bash`. Read
`.claude/settings.json`'s `PreToolUse` array matcher-by-matcher at
`cb43cfbfaa0c41532bcb5bc740be25bfe42dfc1c` (head at time of writing;
ancestor of `92ee89588`), **four** groups match:

| # | Matcher | What runs | Process shape |
|---|---|---|---|
| 1 | `Bash` | `run-hook-with-bash.js --chain` over 15 guard scripts (`auto-approve-safe-bash.sh` … `guard-pr-check-literal.sh`) | one node process, 15 scripts run serially in-process |
| 2 | `*` | `auto-arm-on-cap.sh` (fires on every tool, not only Bash) | one node process (`run-hook-with-bash.js`, single script) |
| 3 | `Bash\|Edit\|Write\|MultiEdit\|NotebookEdit` | `node scripts/trust/shadow-ledger.mjs pre` | one node process, invoked directly — **not** routed through the `--chain` dispatcher |
| 4 | `Bash\|Monitor` | `block-subagent-park.sh` (fires on Monitor too) | one node process (`run-hook-with-bash.js`, single script) |

That is **4 cold node process starts per Bash call**, not the 1 a reader who
only reads the `Bash`-matcher chain would assume, and not the ticket's
original estimate of 7. Groups 2–4 exist because they cover tool sets the
`Bash` chain does not (`*` fires on every tool; `Bash|Monitor` also fires on
`Monitor`); folding them into the `Bash` chain would silently drop that
coverage and is out of scope here — see "Not in scope" below.

`docs/internals/enforcement.md` (dispatcher section, HIMMEL-2002) currently
reads "Bash tool call: 13 matching entries / 11 launcher processes → 4
entries / 2 launchers" — the entry count (4) is still right but the launcher
count (2) is stale: it undercounts groups 2–4 as sharing processes when each
is its own `node` invocation. That file is owned by parked PR #1322; the
correction lives here rather than editing it directly.

## The `--chain` mechanism itself is already hardened

The one matcher that chains (`Bash`, group 1 above) already has its
fail-closed guarantees shipped — whole-chain validation before any member
runs, first-deny-wins, a crashing must-run member denies instead of failing
open, and budget-aware per-member timeouts within the entry's bound:

- HIMMEL-3669 (#1310) — every deny-capable member is must-run
- HIMMEL-3620 (#1295) — sub-floor member timeouts, entry-deadline bounding for advisory members
- HIMMEL-3080 (#1259) — budget-starved must-run guards get their own evaluation window
- HIMMEL-3601 (#1251) — a crashing must-run member denies rather than failing open
- HIMMEL-2557 (#667) — an EPIPE on stdin write propagates the child's real status

Groups 2–4 do not chain (each is a single script), so none of this hardening
applies to them or needs to — there is nothing to chain.

## Measured cost

`scripts/hooks/bench-hook-stack.mjs --runs 7` against the settings above (see
that script's header for the benign-payload / scratch-dir measurement
methodology):

| Matcher | p50 | p95 | max |
|---|---|---|---|
| `Bash` (chain, 15 members) | 181ms | 187ms | 187ms |
| `*` (`auto-arm-on-cap.sh`) | 53ms | 58ms | 58ms |
| `Bash\|Edit\|Write\|MultiEdit\|NotebookEdit` (`shadow-ledger.mjs`) | 25ms | 37ms | 37ms |
| `Bash\|Monitor` (`block-subagent-park.sh`) | 31ms | 37ms | 37ms |

Claude Code fires matching `PreToolUse` groups concurrently (the chain's 15
members are the one serial part, inside group 1), so the wall-clock latency a
Bash call actually waits on is the **slowest** of the four — ~187ms, driven
by the `Bash` chain — not their sum (~319ms). The count that does not
collapse under concurrency is the **process count**: 4 separate node cold
starts happen regardless, since each is a distinct OS process the kernel has
to schedule and tear down.

Regression guard: `scripts/hooks/bench-hook-stack.test.mjs` — "exactly 4
PreToolUse matcher groups in .claude/settings.json match the Bash tool" pins
the matcher list itself (`Bash`, `*`,
`Bash|Edit|Write|MultiEdit|NotebookEdit`, `Bash|Monitor`, in that order), so a
future edit that silently drops or adds Bash-tool coverage is caught here.

## Not in scope

Merging the `*`, `Bash|Edit|Write|MultiEdit|NotebookEdit`, and `Bash|Monitor`
matchers into the `Bash` chain to cut the process count further is real
design work, not a bounded re-measure: each of those three fires on a tool
set the `Bash` chain does not (`*` on every tool; `Bash|Monitor` also on
`Monitor`), so merging them would need to either widen the chain's own
matcher (changing what else it fires on) or split the difference some other
way — a decision this doc does not make. That consolidation needs its own
design ticket.
