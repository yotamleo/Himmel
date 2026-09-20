# Glossary

The one place himmel's fleet vocabulary is defined (HIMMEL-3136, from the
HIMMEL-2975 operator rulings). Everything else — templates, prefaces, command
files, guard messages, internals docs — links here instead of restating a
definition, because a term defined in two places drifts.

## The lexicon

| Term | Meaning |
|---|---|
| **Console** | The operator's chief of staff: a persistent, operator-facing session that owns the shift. It holds the queue lock on its own document, the GO authority and the nonce mint. It dispatches legs, watches the fleet, acts on rulings and merges on GO, and does no implementation itself. `/console new` starts one. |
| **Judge** | A clean session, headed or headless, spawned for one question, sometimes on a deliberately thin brief. **Advisory: it rules, the console acts.** Several may run in parallel on one question with different scopes. Two shapes — see [Judge: call and session](#judge-call-and-session). |
| **Consolidator** | Combines several judges' outputs into one reconciled answer, so the console does not absorb N judgments. A lexicon term only: nothing in the repo implements it yet. |
| **Relay** | Transport. Receives and moves messages and owns the machine wakes. Also called the *communicator* in the design spec; the code name is `relay`. It is launched as a leg of the console (`headed-arm-leg.sh --relay`), never as a console. |
| **Leg** | A working item: one ticket, one worktree, one brief, one PR. A leg has *kinds*: a work leg (implements and ships), a relay leg, and a judge leg. `HIMMEL_CONSOLE_LEG` marks every console-spawned session of any kind. |
| **Chain** | A set of work: an ordered sequence of legs that belong together. |
| **Wave** | A bulk of legs dispatched together — the unit that collision-checking, single-writer and `HIMMEL_FLEET_CAP` apply to. |
| **Arming** | Launching a headed or headless session on a schedule (`arm-resume.sh`, `headed-arm.sh`, `/console new --arm`). |
| **Manual override** | An ad-hoc operator-side session — a whiteboard. It passes work to the console as a ticket and a brief, never as a relayed ruling. |
| **Succession** | One console handing over to the next: the outgoing console arms its successor and writes a HANDOFF (`/console next`). Not a chain — a chain is legs. |

**Not roles.** *Orchestrator* is a rule (`orchestrator-inline-guard`: a
top-tier parent must not implement inline), not a session role; the word also
names a script (`scripts/clean-garden.sh`) and CI components. *Conductor* is
the cross-project layer (HIMMEL-3129), not a role in this fleet.

## Who holds what

| Authority | Console | Judge session | Judge call | Relay | Work leg |
|---|---|---|---|---|---|
| Queue lock on the **console** document | yes | no | no | no | no |
| Queue lock on its **own** document | yes | yes | no (in-process child: no document, no lock) | yes | yes |
| Run `go.sh` (write a GO) | yes | no | no | no | no |
| Mint a nonce, send a token-quoting message (`inbox-send.sh --token`) | yes | no | no | no | no |
| Send tokenless messages (narrowing, halt, RUN notes) | yes | no | no | yes | to its console |
| Rule on a question | acts on the ruling | rules, advisory | rules, advisory | never | escalates |

A judge leg is a leg kind, so a judge session inherits the leg guards; a judge
call runs inside the caller's process and holds nothing of its own.

`go.sh` refuses under `HIMMEL_CONSOLE_LEG` (every console-spawned session) and
under `HIMMEL_CONSOLE_RELAY`; `inbox-send.sh` refuses `--token` under
`HIMMEL_CONSOLE_RELAY`. The RETASK channel that these nonces belong to is in
[`internals/retask-channel.md`](internals/retask-channel.md).

## Judge: call and session

A judge is a **leg kind**: a *judge leg*. A judge session is launched by the
leg launcher (`console-kit/headed-arm-leg.sh --judge`), runs under the leg
guards, and carries the same `HIMMEL_CONSOLE_LEG` marker as any leg — there is
no separate judge marker, and it cannot write its own GO. What differs from a
work leg is the job: it reads, verifies, writes one verdict file and stops. It
does not implement, push or merge.

| Shape | What it is | Brief |
|---|---|---|
| judge **session** | a judge leg with its own worktree, queue lock and lifecycle; survives past one turn | [`handover/judge-brief-template.md`](handover/judge-brief-template.md), verdict per [`handover/verdict-template.md`](handover/verdict-template.md) |
| judge **call** | an in-process child (`.claude/agents/console-judge.md`) for one question that fits in one dispatch | the dispatch prompt |

The console template records which shape asked each question as
`grade: call|session`.

## Session-name suffix contract

Session names carry the role, and tooling reads it back:

| Name contains | Meaning |
|---|---|
| `-console` | a console (`<PREFIX>-nextleg-<date><letter>-console`) |
| `-relay` | a relay leg |
| `-N<k>-` | a leg (session `<TICKET>-N<k>-<slug>`, doc `<TICKET>-N<k>-<slug>-<date>-RESUME.md`, label `N<k>`, a successor `N<k>b` is a distinct session; the legacy `…-leg[N]<k>-…` doc spelling is still read — `scripts/lib/leg-identity.sh`) |
| `-judge-<qid>` | a judge session (`HIMMEL-<ticket>-judge-<qid>`) |

The scorecard classifiers (`scripts/lanes/bench/scorecard/`) key on the
`-console`, `-relay` and `legN` substrings, and `verdict-template.md` on
`-judge-<qid>`; renaming a suffix silently misclassifies burn data.

## Lane

A **lane** is a dispatch backend a leg or subagent runs on (`--lane
native|claudex`, the Codex lane, the critic and bulk lanes); `/lanes` prints
the set available on this machine. It is not a role, and not a wave.

## Same word, different thing

- **relay** the transport verb/noun in "Telegram relay", `JIRA_NUDGE_RELAY_CMD`
  and "relay every permission denial" is the notification path, not the relay leg.
- **judge** also names the CR/critic-panel reviewer ("a judge review"), the
  independent validation judge in [`token-economy.md`](token-economy.md) and
  [`orchestration-patterns.md`](orchestration-patterns.md), and the
  `follow-judge` clip-triage verdict in `marketplace/plugins/obsidian-triage`.
  None of these is a judge leg.
- **chain** also means a serial hook chain (`architecture.md`,
  `harness-compat.md`) — a different object from a chain of legs.
- **wave** has no code identifier in the lexicon sense. `MID-AGENT-WAVE`
  (`auto-arm-on-subagent-cap.sh`) is a wave of *subagents*; "wave-1" in
  `internals/environment-gotchas.md` is a project-phase label.
- **armed** in "armed merge" (`ARMAUTOMERGE`, auto-merge) and "arm the tick
  Monitor" (`console-template.md`) are different senses from arming a session.
- **orchestrator** / **coordinator** in
  [`orchestration-patterns.md`](orchestration-patterns.md) are the external
  pattern catalog's vocabulary for the parent session.
