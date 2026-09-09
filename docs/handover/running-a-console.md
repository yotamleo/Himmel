# Running a console

A **console** is a long-running Claude session that does no implementation. It
holds a queue lock on its own handover document, watches the fleet, dispatches
implementation **legs** as separate sessions, rules on their questions, relays
merges, and arms its own successor before its context fills. It is how a single
operator keeps several tickets moving at once across sessions that each forget
everything at the end.

`/console new` starts one. `/console next` hands it over.

## Console vs. `/overnight-shift`

They look adjacent and are not interchangeable.

| | `/overnight-shift` | console |
|---|---|---|
| Shape | one session fans out N subagents inside itself | one session dispatches N *separate* sessions |
| Lifetime | one run, then done | a chain — each console arms its successor |
| State | in-session | a handover document + a queue lock, survives the session |
| Children | subagents, no window of their own | headed sessions with their own worktrees and PRs |
| Rulings | none — the plan is fixed at fanout | RETASK channel, mid-flight, authenticated |
| Handover | none | `/console next` writes the successor + a HANDOFF |

Reach for `/overnight-shift` when you have a fixed list of well-scoped tickets
and want them done unattended. Reach for a console when the work will need
decisions you cannot pre-write, or will outlive one context window.

## Starting one

```bash
/console new                      # writes the doc, takes the lock, prints the launch line
/console new --name night         # a differently-named chain in the same bucket
/console new --arm                # also arms it headed, on a signal file + deadline
/console new --dry-run            # print what it would write, touch nothing
```

`new` resolves your handover root through the shared resolver (`HANDOVER_DIR`,
else `<repo>/handovers`) and your bucket the same way the handover skill does,
then writes `<root>/<user>/<bucket>/<PREFIX>-nextleg-<date>A-console.md` from
[`console-template.md`](console-template.md). A second `new` on the same day
writes `…B-console.md` — it never overwrites.

It then acquires the queue lock on that document and prints the
`release-token:` line. **Record that token in the console's first Results
bullet** — releasing the lock at wrap requires it.

Finally it prints the launch line. Run it in a terminal of its own:

```
claude --model <model> --autocompact auto -n <session-name> "load <doc> and continue"
```

A console wants a real TTY. A session launched without one exits at the first
idle cross-session message.

## ACTION ZERO

The template's first section. The console runs it before anything else and
writes the result as its first Results bullet: who is alive (`ListAgents`),
what locks are held **at the handover root** (not just its own bucket — a
bucket sweep reports a false "no held locks"), the primary's head and remote,
`bank-preflight.sh`, the live leg processes, host load, and the kit path. Then
it acquires its own lock and tells its predecessor it is live.

## Dispatching legs

The console writes a brief from
[`leg-brief-template.md`](leg-brief-template.md) and launches it headed:

```bash
setsid nohup bash scripts/handover/console-kit/headed-arm-leg.sh \
  <session-name> <brief> <signal-file> <deadline-epoch> <log> <model> \
  >/dev/null 2>&1 &
```

Two rules govern the fan-out. **Collision-check first** — list the files each
queued leg will touch and confirm they are disjoint; **single-writer** means
many readers but exactly one writer per artifact. And **every dispatch names an
explicit model**: an unnamed one draws on the scarcer parent quota. Tier and
effort guidance, including the console's own wake-up budget, is in
[`../internals/lane-calibration.md`](../internals/lane-calibration.md).

## Rulings

A leg that hits something it cannot decide reports to the console, not to the
operator. The console verifies the finding itself, then answers.

Re-tasking a running leg goes through the **RETASK channel**: each dispatch
carries a fresh nonce, and a genuine revision is a direct message quoting it.
Expanding or redirecting a leg needs the token; narrowing it or halting it does
not — that asymmetry is deliberate, so a halt can never be argued away. Full
threat model and the verbatim block:
[`../internals/retask-channel.md`](../internals/retask-channel.md).

## Merges

`READY <pr> <head> GREEN` → the console verifies independently (all check-runs
green at that exact head, zero unresolved review threads, attestation trailers
in the first commit) → `GO` → the leg merges and reports `MERGED #<n> → <sha>`.
The console pulls the primary and the leg closes out its ticket.

## Handing over

Consoles hand over at **45 % context fill, or 90 k input tokens in one turn**.

```bash
/console next --arm
```

`next` writes the successor stub (letter bumped, pointed at this console and
its HANDOFF) and the predecessor's `-HANDOFF.md` skeleton, and arms the
successor on a signal file. Fill in the HANDOFF — head, what is in flight leg
by leg with nonces and lock tokens, rulings made, the held queue in launch
order, what wrapped — then `touch` the signal, release the lock, and stop.

The HANDOFF is the successor's only required read. Written properly, the chain
does not need the predecessor's transcript at all.

## See also

- [`console-template.md`](console-template.md) — the console's operating contract
- [`console-handoff-template.md`](console-handoff-template.md) — the handover skeleton
- [`leg-brief-template.md`](leg-brief-template.md) — what a dispatched leg gets
- [`overnight-mode.md`](overnight-mode.md) — the unattended-pipeline alternative
- [`../internals/retask-channel.md`](../internals/retask-channel.md) — authenticated re-tasking
- [`../internals/lane-calibration.md`](../internals/lane-calibration.md) — tiers, effort, wake-up budget
