# Running a console

A console is how a single operator keeps several tickets moving at once across
sessions that each forget everything at the end. What a console, leg, judge,
relay, chain, wave, arming and manual override *are* is defined once, in
[`../glossary.md`](../glossary.md) — read that first if any of those words is
new. This page is how to run one.

`/console new` starts one. `/console next` hands it over to its successor.

## Who does what

- **You (the operator)** talk to the console. The console dispatches **legs**,
  one ticket per leg, and acts on their questions and on **judge** verdicts;
  it merges only on a GO that it writes.
- Judges and relays serve the console; neither holds GO or the nonce mint —
  only the console does (the authority table is in the glossary).
- **Manual override.** If you work in a side session of your own, hand the
  console a ticket and a brief; never pass it a ruling by way of a relay. A
  ruling reaches the console from you directly, or not at all.

## Console vs. `/overnight-shift`

They look adjacent and are not interchangeable.

| | `/overnight-shift` | console |
|---|---|---|
| Shape | one session fans out N subagents inside itself | one session dispatches N *separate* sessions |
| Lifetime | one run, then done | a succession — each console arms its successor |
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
/console new --name night         # a differently-named succession in the same bucket
/console new --arm                # also arms it headed, on a signal file + deadline
/console new --dry-run            # print what it would write, touch nothing
```

`new` resolves your handover root through the shared resolver (`HANDOVER_DIR`,
else `<repo>/handovers`) and your bucket the same way the handover skill does,
then writes `<root>/<user>/<bucket>/<PREFIX>-nextleg-<date>A-console.md` from
[`console-template.md`](console-template.md). A second `new` on the same day
writes `…B-console.md` — it never overwrites.

It then acquires the queue lock on that document and prints the
`release-token:` line. **That token belongs to the console you are about to
launch** — record it in the console's first Results bullet, because releasing
the lock at wrap requires it. The console *adopts* this lock; it does not
acquire a second one. (`new` takes the lock and then exits, so a console that
tried to acquire again would be refused by its own startup lock.)

Paste the printed `launch:` line **verbatim, including its `env -u …` prefix**.
That prefix is load-bearing, not decoration: you are almost always pasting into
a terminal that was itself spawned from a claude session, and it clears the
`CLAUDE_CODE_CHILD_SESSION` / `CLAUDE_PID` / `CLAUDE_CODE_SESSION_ID` variables
that shell inherited. A console that keeps them writes no transcript and gets
`UNKNOWN` from `scripts/context-fill.sh --percent` — which is the signal its
own handover contract runs on (HIMMEL-3081). Trimming the line to just
`claude …` silently recreates that failure.

Finally it prints the launch line. Run it in a terminal of its own:

```text
env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
    CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 \
    claude --model <model> --autocompact 200000 -n <session-name> "load <doc> and continue"
```

`--autocompact 200000` is the default (HIMMEL-2973 — the largest cache-read
cost driver on the fleet was Fable consoles compacting only near the 1M
window). Set `CONSOLE_CONTEXT=1m` in the launching shell before running
`console new`/`next` to opt into the old `--autocompact auto` behavior; the
printed launch line reflects whichever is resolved.

A console wants a real TTY. A session launched without one exits at the first
idle cross-session message.

## ACTION ZERO

The template's first section. The console runs it before anything else and
writes the result as its first Results bullet: who is alive (`ListAgents`),
what locks are held **at the handover root** (not just its own bucket — a
bucket sweep reports a false "no held locks"), the primary's head and remote,
`bank-preflight.sh`, the live leg processes, host load, and the kit path. Then
it records the lock token `new` printed — confirming with `queue-lock.sh
status` that the lock is held, and acquiring one only if it reports `free` —
and tells its predecessor it is live.

It also opens a **Telegram inbox** (HIMMEL-3355): it creates
`<bridge root>/consoles/<session>.md` and watches it with its one event waiter,
`console-kit/console-wait.sh`, run with Bash `run_in_background` (HIMMEL-3509:
no `Monitor` re-arm loop, so an idle console takes no turns; a persisted read
cursor means a line appended while no waiter ran is delivered on the next
start; at-least-once, so a waiter killed mid-emit can repeat one line), so
the operator's `/console <session> <text>` from
Telegram reaches the running console with the operator's authority — rulings,
halts, new work — but never a permission or settings change and never a
skipped GO verification. The console replies with
`bun scripts/telegram/console-route.ts reply <chat_id> <text>`. Operator-side
usage: [`../telegram-bridge.md`](../telegram-bridge.md#messaging-a-running-console).

## Dispatching legs

When drafting the brief's **Ship:** item, spell the attestation trailers'
grammar rather than paraphrasing it: the token is the FIRST word after the
colon — `Platforms tested: <os>`, `Security reviewed: manual — <what you
checked>` (or `claude-code-security-review` / `pr-review-toolkit` / `ad-hoc`
in place of `manual`) — a paraphrase the leg copies faithfully is how a
non-conforming trailer reaches the pre-push gate (HIMMEL-2982).

The console writes a brief from
[`leg-brief-template.md`](leg-brief-template.md) and launches it headed:

```bash
setsid nohup bash scripts/handover/console-kit/headed-arm-leg.sh --profile leg-impl \
  <session-name> <brief> <signal-file> <deadline-epoch> <log> <model> \
  >/dev/null 2>&1 &
```

Two rules govern the fan-out. **Collision-check first** — list the files each
queued leg will touch and confirm they are disjoint; **single-writer** means
many readers but exactly one writer per artifact. And **every dispatch names an
explicit model**: an unnamed one draws on the scarcer parent quota. Tier and
effort guidance, including the console's own wake-up budget, is in
[`../internals/lane-calibration.md`](../internals/lane-calibration.md).
Pass **`--profile leg-impl`** (HIMMEL-2830) on a native-lane leg: it narrows
the leg's plugin set, appends the standing rules from
[`leg-preface.md`](leg-preface.md) to its system prompt — which is why the v3
brief template no longer repeats them — and exports `HIMMEL_LEAN_LEG=1` to
quiet the advisory SessionStart hooks. It also now (HIMMEL-2935) passes
`--mcp-config`/`--strict-mcp-config`, so a leg only ever sees the `qmd` MCP
server, not the operator console's full USER-level MCP roster. A leg dispatched WITHOUT the flag is
unchanged in every respect, including its argv, so the preface must then be
pasted into the brief. Detail:
[`../internals/lane-calibration.md`](../internals/lane-calibration.md).

`headed-arm-leg.sh` exports `HIMMEL_CONSOLE_LEG=1`, which
`block-leg-askuserquestion.sh` (HIMMEL-2923) uses to structurally deny
`AskUserQuestion` on the leg, rather than relying on the brief's prose NEVER.

`headed-arm-leg.sh` also exports `HIMMEL_CONSOLE_NAME` (HIMMEL-3435) into the
leg, resolved from the first of: a `--console <name>` flag, this launching
shell's own `HIMMEL_CONSOLE_NAME`, or the console's own session name if it can
be read reliably — never guessed from the process tree, and exported not at
all if no source yields a name. A running console usually needs no flag: its
own session name resolves automatically. This is what lets a leg's
HIMMEL-3430 merge-block alert (`scripts/lib/merge-block-alert.sh`) route to
the console's own inbox instead of DMing the operator.

**Idle capacity is the console's duty.** `tick.sh` appends `fleet=<live>/<cap>`
(bank-preflight's own census: native + claudex + reserved, `HIMMEL_FLEET_CAP`)
and `capacity=`. On `capacity=UNDERFILLED:<slack>` — live below cap and no leg
launched for `TICK_UNDERFILL_MIN` minutes (default 10) — pull dispatchable work
from the Jira backlog, not only the held queue, after a file-collision check
against live legs and open PRs, and launch up to `<slack>` legs.
`capacity=unknown` (`fleet=?`) means the census could not be read, not that
capacity is fine.

**Reading leg locks and the tick.** `tick.sh --legs` takes **absolute**
handover-doc paths on ONE `legs:` line; a relative path drops the bucket
prefix out of the lock key and the leg reads `free` while it is live. The
queue-lock owner pid is the launcher **wrapper**, so every owner reads dead
while its leg is alive, and the release token a leg pasted into its LIVE
bullet can be wrong — recover the real one from
`${XDG_RUNTIME_DIR}/himmel-queue-lock/` before calling a lock stale.
`IDLE-HELD?` is heartbeat age, not death: a leg inside a long foreground suite
makes no tool calls. Verify with `pgrep` against the leg's session name;
never force-release on the flag alone.

## Claudex legs: the inbox is the only channel

A `--lane claudex` leg (`headed-arm-leg.sh`, HIMMEL-2782) runs under
`~/.claude-codex`, which keeps it out of the session registry `ListAgents`
reads on both ends — `SendMessage` reaches it in neither direction, even
though its socket is alive. The only channel either way is the file inbox
(`inbox-send.sh`, HIMMEL-2788): console → leg is `inbox-send.sh <leg-session>
--file <path>`, delivered as `PostToolUse`/`SessionStart` additionalContext on
the leg's next tool call; leg → console is the same script addressed to the
console's own session name. `AskUserQuestion` reaches nobody on a claudex leg
while the operator is away — every claudex brief must say so and give the leg
the console's exact session name (HIMMEL-2898 item 1).

Inbox delivery is **tool-call-gated**, so a leg that ends its turn on
`BLOCKED` or a question goes idle and never sees the answer on its own.
Standing rule (console 03H, 2026-09-10 01:18): every claudex leg arms a
persistent `Monitor` on `tail -n 0 -F <handover-root>/inbox/<session>.md` at
LIVE, before anything else — carry that line verbatim in the claudex brief
preface. A structural fix (registry entry, or an idle-wake path) is still
open on HIMMEL-2898 items 1 and 2.

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

The Jira close is the leg's call from the brief, not a default:
`merge-on-green.sh` transitions the ticket only on `--jira-transition`
(HIMMEL-3143), and the brief's Ship contract carries `completes-ticket: yes|no`
(HIMMEL-3271) — `yes` → the leg passes the flag, `no` (the ticket spans further
PRs) → it omits it. After `MERGED`, re-read the ticket: the flag closes only the
first `[KEY]` of the PR title, so a multi-key PR needs its other ticket checked
by hand.

`scripts/handover/console-kit/ready-check.sh <pr> <full-40-hex-head-sha>`
mechanizes that independent verification (HIMMEL-3163): it re-runs checks
1-6 (head match + clean merge state, statusCheckRollup all green, zero
unresolved review threads, a CR-ledger row for that head, attestation
trailers in the first commit, a ticket ID on every commit subject) and
prints `READY-CHECK PASS|FAIL`. It is read-only — no ledger rows, GO files,
or PR comments — and it does **not** read the three-dot diff; that judgement
call stays the console's own, which the script says on its last line. On a
PR that is already `MERGED`, GitHub reports `mergeStateStatus: UNKNOWN`
permanently, so check 1 always fails there — that is expected, not a bug;
the script's domain is a PR that has not yet merged.

A PR on HIMMEL-2973/2976/2928/2974/2975 is READY only if its body cites
`HIMMEL-2977 "GATE <previous lever> PASS <date>"` (for 2973:
`P0 EXIT <date>` — this line carries no separate status word; its mere
presence, verbatim, is the pass signal for 2973). Open HIMMEL-2977's comments
and find that citation's line verbatim: a missing citation or a line not
found is not READY; for the general `GATE ... <status> <date>` shape (every
ticket except 2973), a found line whose status is not PASS is also not READY.
The console pulls the primary and the leg wraps (closing its ticket only if the
brief's `completes-ticket: yes` says the PR completes it).
The console sends GO by first running `bash scripts/handover/console-kit/go.sh
<pr> <full head sha>` — the file IS the GO, the SendMessage is the
notification: a leg launched by `headed-arm-leg.sh` carries
`HIMMEL_CONSOLE_LEG=1`, and `merge-on-green.sh` refuses it (exit 17) without a
GO for the exact head it certifies, so a push after GO needs a fresh one
(HIMMEL-2919).

An armed merge stops at "awaiting approval" wherever branch protection requires
a review the automation identity cannot give — on a single-maintainer repo the
only path through is the admin bypass, which the merge script refuses by
design — so the console hands the merge to the operator and sends `MERGED`
back when it lands.

## Handing over

Consoles hand over at **45 % context fill, or 90 k input tokens in one turn**.

```bash
/console next --arm --doc <this console's own doc> --bucket <its bucket> --prefix <its prefix> --model <its model>
```

**Name your own document, bucket, prefix and model explicitly.** Without
`--doc`, `next` hands over from the highest-lettered doc it can find — the
wrong one as soon as another `new` has run or a successor already exists;
without `--bucket` and `--prefix` it re-resolves those from the environment
and writes the successor into the wrong bucket, or under the wrong key;
without `--model` it re-resolves the model from `CONSOLE_MODEL` or the
built-in default instead of continuing on the model this console itself runs
on. The rendered console doc carries the exact command with all four already
filled in.

`next` writes the successor stub (letter bumped, pointed at this console and
its HANDOFF) and the predecessor's `-HANDOFF.md` skeleton, and arms the
successor on a signal file. The letter rolls past Z in bijective base-26 (Z →
AA → AB → … → ZZ, then refuses) instead of ever refusing at Z; pass `--date
<YYYY-MM-DD>` to pre-mint tomorrow's first console (`A`) immediately, near
midnight, instead of waiting for the date to roll over. Fill in the HANDOFF —
head, what is in flight leg by leg with nonces and lock tokens, rulings made,
the held queue in launch order, what wrapped — then `touch` the signal path
that `next --arm` printed and hand your live legs over by name.

**Re-brief your live legs before you release** (HIMMEL-3082, HIMMEL-3254). Each
leg's brief names *you* as its console, and a successor is a different session
on a different socket: the successor names itself to you during its ACTION ZERO,
you send each leg — from your own session — a message naming the successor and
quoting the leg's current token, and each leg answers with a quote-back. A fresh
token is optional: a successor MAY issue one per leg (then quote it too, and the
leg quotes it back); a relay with none is complete and the leg keeps its own.
A successor that arrives after you have left can prove itself only with the
two-token chain form; a leg that cannot verify that is stranded (it keeps
working and can still be merged, but cannot be re-scoped). The successor's
tick reads `nonces=UNCONFIRMED:<leg>` until each leg's own `SUCCESSION
accepted` bullet names the successor (`RELAYED:<leg>`, a relay that kept the
leg's token, is valid) or the leg has rotated.

**Release your lock only after the successor reports `LIVE`.** It sends that
only after the quote-backs — or with the legs that did not quote back named,
and why (ACTION ZERO step 9) — and it is the only evidence the arm actually fired
and the successor completed ACTION ZERO; releasing on the `touch` alone leaves
an unattended fleet if the launch failed.

The HANDOFF is the successor's only required read. Written properly, the succession
does not need the predecessor's transcript at all.

## See also

- [`console-template.md`](console-template.md) — the console's operating contract
- [`console-handoff-template.md`](console-handoff-template.md) — the handover skeleton
- [`leg-brief-template.md`](leg-brief-template.md) — what a dispatched leg gets
- [`overnight-mode.md`](overnight-mode.md) — the unattended-pipeline alternative
- [`../internals/retask-channel.md`](../internals/retask-channel.md) — authenticated re-tasking
- [`../internals/lane-calibration.md`](../internals/lane-calibration.md) — tiers, effort, wake-up budget
