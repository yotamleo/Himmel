# Running a console

A supervisor session is how a single operator keeps several tickets moving at once across
sessions that each forget everything at the end. What a supervisor session, worker session, judge,
relay, ticket sequence, batch, arming and side session *are* is defined once, in
[`../glossary.md`](../glossary.md) — read that first if any of those words is
new. This page is how to run one.

`/console new` starts one. `/console next` hands it over to its successor.

## Who does what

- **You (the operator)** talk to the supervisor session. It dispatches **worker sessions**,
  one ticket per worker session, and acts on their questions and on **judge** verdicts;
  it merges only on a GO file (merge approval) that it writes.
- Judges and relays serve the supervisor session; neither holds GO or the nonce mint —
  only the supervisor session does (the authority table is in the glossary).
- **Side session.** If you work in a side session of your own, hand the
  supervisor session a ticket and a brief; never pass it a ruling by way of a relay. A
  ruling reaches the supervisor session from you directly, or not at all.

## Console vs. `/overnight-shift`

They look adjacent and are not interchangeable.

| | `/overnight-shift` | supervisor session |
|---|---|---|
| Shape | one session fans out N subagents inside itself | one session dispatches N *separate* sessions |
| Lifetime | one run, then done | a succession — each supervisor session arms its successor |
| State | in-session | a handover document + a queue lock, survives the session |
| Children | subagents, no window of their own | headed sessions with their own worktrees and PRs |
| Rulings | none — the plan is fixed at fanout | RETASK channel, mid-flight, authenticated |
| Handover | none | `/console next` writes the successor + a HANDOFF |

Reach for `/overnight-shift` when you have a fixed list of well-scoped tickets
and want them done unattended. Reach for a supervisor session when the work will need
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

**Keep the `-console` suffix in a scoped name:** `--name roadmap-console`, not
`--name roadmap`. The suffix is load-bearing. `console-compact-reinject.sh`
re-injects the live state after a compaction only for a session whose
launch-time `-n` name ends in `-console`, and `/rename` does not change that
name. `next` derives the successor's name from its `--doc`, so a doc without
the suffix hands the mistake down the chain. To fix a mis-named supervisor session, copy
its doc to a `…-console.md` path, take the lock on the new path, release the
old one, and leave a pointer stub behind.

It then acquires the queue lock on that document and prints the
`release-token:` line. **That token belongs to the supervisor session you are about to
launch** — record it in the supervisor session's first Results bullet, because releasing
the lock at wrap requires it. The supervisor session *adopts* this lock; it does not
acquire a second one. (`new` takes the lock and then exits, so a supervisor session that
tried to acquire again would be refused by its own startup lock.)

Paste the printed `launch:` line **verbatim, including its `env -u …` prefix**.
That prefix is load-bearing, not decoration: you are almost always pasting into
a terminal that was itself spawned from a claude session, and it clears the
`CLAUDE_CODE_CHILD_SESSION` / `CLAUDE_PID` / `CLAUDE_CODE_SESSION_ID` variables
that shell inherited. A supervisor session that keeps them writes no transcript and gets
`UNKNOWN` from `scripts/context-fill.sh --percent` — which is the signal its
own handover contract runs on. Trimming the line to just
`claude …` silently recreates that failure.

Finally it prints the launch line. Run it in a terminal of its own:

```text
env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
    CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 \
    claude --model '<model>' --autocompact auto -n <session-name> "load <doc> and continue"
```

`[1m]` is appended to the model only for the 4.6 family (`claude-opus-4-6`,
`claude-sonnet-4-6`); Opus 4.7+, Sonnet 5+, Haiku 5.5 and Fable run 1M natively
and non-Anthropic ids (`gpt-*`, `glm-*`, anything with a `/`) never take it
(HIMMEL-5501). `--autocompact` and the Opus 5.5 id need Claude Code 2.1.280 or
newer: an armed launch on an older CLI refuses and names `claude update`
(`/himmel-update` brings it current).

Supervisor sessions default to 1m context with `--autocompact auto`
(a supervisor session exemption). Both `console new` and `next`
accept `--context 1m|standard`, which overrides the environment and default.
Use `--context standard` or `CONSOLE_CONTEXT=standard` in the launching shell
to opt down to `--autocompact 200000`. The printed launch line and armed
launch use the same resolved choice. Fable-family models retain their existing
handling: the CLI strips `[1m]`, so the suffix is not applied; autocompact still
is. Worker sessions and non-supervisor session arms keep their standard default.

A supervisor session wants a real TTY. A session launched without one exits at the first
idle cross-session message.

## ACTION ZERO

The template's first section. The supervisor session runs it before anything else and
writes the result as its first Results bullet: who is alive (`ListAgents`),
what locks are held **at the handover root** (not just its own bucket — a
bucket sweep reports a false "no held locks"), the primary's head and remote,
`bank-preflight.sh`, the live worker session processes, host load, and the kit path. Then
it records the lock token `new` printed — confirming with `queue-lock.sh
status` that the lock is held, and acquiring one only if it reports `free` —
and tells its predecessor it is live.

It also opens a **Telegram inbox**: it creates
`<bridge root>/consoles/<session>.md` and watches it with its one event waiter,
`console-kit/console-wait.sh`, run with Bash `run_in_background` (no `Monitor` re-arm loop, so an idle supervisor session takes no turns; a persisted read
cursor means a line appended while no waiter ran is delivered on the next
start; at-least-once, so a waiter killed mid-emit can repeat one line), so
the operator's `/console <session> <text>` from
Telegram reaches the running supervisor session with the operator's authority — rulings,
halts, new work — but never a permission or settings change and never a
skipped GO verification. The supervisor session replies with
`bun scripts/telegram/console-route.ts reply <chat_id> <text>`. Operator-side
usage: [`../telegram-bridge.md`](../telegram-bridge.md#messaging-a-running-console).

The same waiter **pages the operator** when a worker session's classifier
denials reach `SHIP-STEP` or `PAUSE-RISK`: one Telegram message with the worker session
label, count and class, and nothing else. A paged worker session is then **refused** on
re-dispatch (`headed-arm-leg.sh` exits 14) until someone has looked and run
`bash scripts/handover/console-kit/ack-denial.sh <leg-label-or-doc>`;
`--ignore-denials` overrides. Detail:
[`../internals/enforcement.md`](../internals/enforcement.md#log-classifier-denialsh--classifier-denial-tap-himmel-3724).

## Dispatching legs

**Pre-dispatch trust-path check:** trace the planned scope and
list the trust paths it will plausibly need (shared libraries, hooks, launchers,
settings, or guardrail inventories). Put the exact paths, permitted operations,
and exclusions in the initial brief, with the operator's up-front scope grant.
If that grant is missing, narrow the task or obtain it before dispatch; a
supervisor session cannot manufacture operator permission. The brief grants task scope,
not a bypass of the worker session's tool-permission envelope. In particular, an auto-mode
worker session's mid-flight inbox EXPANSION may be refused by the classifier and needs
operator confirmation in-window, even with a valid RETASK token. Do not use
repeated inbox revisions as a workaround; see
[`../internals/retask-channel.md`](../internals/retask-channel.md).

When drafting the brief's **Ship:** item, spell the attestation trailers'
grammar rather than paraphrasing it: the token is the FIRST word after the
colon — `Platforms tested: <os>`, `Security reviewed: manual — <what you
checked>` (or `claude-code-security-review` / `pr-review-toolkit` / `ad-hoc`
in place of `manual`) — a paraphrase the worker session copies faithfully is how a
non-conforming trailer reaches the pre-push gate.

The supervisor session writes a brief from
[`leg-brief-template.md`](leg-brief-template.md) and launches it headed:

```bash
setsid nohup bash scripts/handover/console-kit/headed-arm-leg.sh --profile leg-impl \
  <session-name> <brief> <signal-file> <deadline-epoch> <log> <model> \
  >/dev/null 2>&1 &
```

Two rules govern the fan-out. **Collision-check first** — list the files each
queued worker session will touch and confirm they are disjoint; **single-writer** means
many readers but exactly one writer per artifact. And **every dispatch names an
explicit model**: an unnamed one draws on the scarcer parent quota. Tier and
effort guidance, including the supervisor session's own wake-up budget, is in
[`../internals/lane-calibration.md`](../internals/lane-calibration.md).

Three pre-launch checks that each cost a supervisor session a dead worker session when skipped:

- **An old backlog bug may already be fixed.** Before dispatching a worker session on a
  bug filed weeks ago, check that it still reproduces on current main: read
  the code the ticket names and look for a regression test that covers it.
  Many have been fixed in passing. Batch the check in one read-only agent pass
  (still open, fixed, or partial, each with file:line evidence), and verify any
  "fixed" claim yourself before you close the ticket.
- **The Tier line needs a literal em-dash.** An Opus or Fable worker session launches only
  if its brief carries `> **Tier:** opus — <category>: <reason>`. With an ASCII
  hyphen in place of the em-dash, `headed-arm-leg.sh` refuses: no launch log,
  nothing in `pgrep`. `--dry-run` an Opus or Fable launch first and look for
  `refusing` in its output.
- **Design-profile worker sessions need a one-time interactive OAuth login.** The `design`
  profile enables `builder-visual@himmel`, whose `.mcp.json` registers the hosted
  `agent-native-dispatch` MCP server (`https://dispatch.agent-native.com/mcp`,
  OAuth). Until the operator has logged in once (`/mcp`, pick
  `agent-native-dispatch`), the server needs auth and a worker session cannot answer the
  prompt, which looks like a hung worker session. Tool arguments go to Builder.io servers:
  never use it on salus/PHI work. `block-agent-native-egress.sh`
  refuses the call from a salus session or when the payload names salus. `context7` needs no login. Do not arm a
  design-profile worker session unattended (`--arm`, at-jobs, overnight) until a fresh
  session has been checked to keep the token.

Pass **`--profile leg-impl`** on a native-lane worker session: it narrows
the worker session's plugin set, appends the standing rules from
[`leg-preface.md`](leg-preface.md) to its system prompt — which is why the v3
brief template no longer repeats them — and exports `HIMMEL_LEAN_LEG=1` to
quiet the warn-only SessionStart hooks. It also now passes
`--mcp-config`/`--strict-mcp-config`, so a worker session only ever sees the `qmd` MCP
server, not the USER-level MCP roster (a supervisor session gets the same treatment:
`qmd` and `himmel-bus` only). A worker session dispatched WITHOUT the flag is
unchanged in every respect, including its argv, so the worker system prompt rules must then be
pasted into the brief. Detail:
[`../internals/lane-calibration.md`](../internals/lane-calibration.md).

`headed-arm-leg.sh` exports `HIMMEL_CONSOLE_LEG=1`, which
`block-leg-askuserquestion.sh` uses to structurally deny
`AskUserQuestion` on the worker session, rather than relying on the brief's prose NEVER.

`headed-arm-leg.sh` also exports `HIMMEL_CONSOLE_NAME` into the
worker session, resolved from the first of: a `--console <name>` flag, this launching
shell's own `HIMMEL_CONSOLE_NAME`, or the supervisor session's own session name if it can
be read reliably — never guessed from the process tree, and exported not at
all if no source yields a name. A running supervisor session usually needs no flag: its
own session name resolves automatically. This is what lets a worker session's
merge-block alert (`scripts/lib/merge-block-alert.sh`) route to
the supervisor session's own inbox instead of DMing the operator.

**Idle capacity is the supervisor session's duty.** `tick.sh` appends `fleet=<live>/<cap>`
(bank-preflight's own census: native + claudex + reserved, `HIMMEL_FLEET_CAP`)
and `capacity=`. On `capacity=UNDERFILLED:<slack>` — live below cap and no worker session
launched for `TICK_UNDERFILL_MIN` minutes (default 10) — pull dispatchable work
from the Jira backlog, not only the held queue, and launch up to `<slack>` worker sessions.
`console-wait.sh` wakes on it once per streak (`WAKE underfilled`) and prints
`console-kit/next-dispatchable.sh --priority-pool-only`'s ranked, collision-checked
list (free slots fill only from the priority pool; `POOL-EMPTY` means unblock
collisions, draft specs for the next priority items, else idle);
`console-kit/gen-briefs.py` writes the briefs and launchers (nothing launches
itself). A bare `--bucket himmel` resolves to `<handover-root>/<user>/himmel`;
`--no-worktree` refuses a leg whose worktree does not exist and prints the
`clean-garden.sh` line to run.
`capacity=unknown` (`fleet=?`) means the census could not be read, not that
capacity is fine.

**Reading worker session locks and the tick.** `tick.sh --legs` takes **absolute**
handover-doc paths on ONE `legs:` line; a relative path drops the bucket
prefix out of the lock key and the worker session reads `free` while it is live. The
queue-lock owner pid is the launcher **wrapper**, so every owner reads dead
while its worker session is alive, and the release token a worker session pasted into its LIVE
bullet can be wrong — recover the real one from
`${XDG_RUNTIME_DIR}/himmel-queue-lock/` before calling a lock stale.
`IDLE-HELD?` is heartbeat age, not death: a worker session inside a long foreground suite
makes no tool calls. Verify with `pgrep` against the worker session's session name;
never force-release on the flag alone.
**`NOLIVE` and `FORKED`.** A worker session that never took its lock or wrote
a marker bullet reads `FREE` forever, so the waiter's key never moved and the
supervisor session was never woken. `legs=` now shows `<N>:NOLIVE` once a worker session with no held
lock and no marker bullet at all is older than `TICK_NOLIVE_MIN` minutes
(default 10), counted from the fleet manifest's `added` time, else the launch
log's `armed:` line, else the doc's mtime; the change from `FREE` wakes the
waiter. `<N>:FORKED` means the worker session's session transcript (found only by its
`custom-title`, never guessed) ends in a `continued-in` record: the session was
forked or backgrounded into another one, usually without its worker system prompt. A
`WRAPPED`, `READY`, `LIVE`, `BLOCKED` or held-lock worker session is never either. Act on
both the same way: `ListAgents`, then `SendMessage` the worker session its lock command
(`queue-lock.sh acquire <its doc>`), your supervisor session name and its RETASK
token; if it is gone, relaunch it.
`tick.sh --legs-from <manifest>` reads the same absolute docs
from a fleet manifest that `console-kit/fleet-manifest.sh add|remove` keeps,
re-read every sample, so a dispatch or wrap needs no waiter re-start.
Pass `--fleet <manifest>` before the positional arguments to
`console-kit/headed-arm-leg.sh` and `console-kit/close-wrapped-leg.sh` to keep
that manifest updated automatically: launch adds its doc only after a successful
handoff; close removes its doc only on a successful close (including benign
prune skips). Failed/refused launches and closes leave the manifest unchanged.
Without the flag, both verbs keep their existing behavior. Dry-run launches
never update the manifest. An update failure returns nonzero and reports that
the launch/close already happened; it does not undo it. Nonces remain supervisor-session-only
inputs to `live-state.sh --nonce`, never sourced from the manifest.

A leg's `MERGED` or `WRAPPED` message is one call, not a turn sequence:
`console-kit/leg-event.sh --doc <console doc> --fleet <manifest> <message-file>`
routes it to `console-kit/wrap-merged.sh` and prints `HANDLED` or `ESCALATE
<reason>`; a judge verdict is one `console-kit/verdict-go.sh` call. Consoles that
ran the hand sequences spent most of their input tokens on them
(HIMMEL-5592 inventory: `scripts/eval/console-load-inventory.py`).

**Lane canary**: `scripts/lanes/lane-canary.sh [--lanes a,b]
[--timeout <sec>] [--out <report.json>] [--dry-run]` launches one no-op worker session per
lane through the real launcher and reports PASS, FAIL or SKIP with the time to
the first Results bullet. Run it after a station update or a lane change; the
unit suites check the generated command, this checks that a worker session on the lane
actually starts, registers, receives its brief and writes a bullet. Lanes run
one at a time, and a lane whose backend is not configured is SKIP. The report
lands at `<handover root>/.canary/latest.json`, the file the board reads. A lane
whose launcher refuses on its bank (exit 11, for example OpenRouter credit under
`OPENROUTER_MIN_CREDIT_USD`) reports FAIL, not SKIP: read the detail column
before treating it as a lane defect.

## Claudex legs: the inbox is the only channel

A `--lane claudex` worker session (`headed-arm-leg.sh`) runs under
`~/.claude-codex`, which keeps it out of the session registry `ListAgents`
reads on both ends — `SendMessage` reaches it in neither direction, even
though its socket is alive. The only channel either way is the file inbox
(`inbox-send.sh`): supervisor session → worker session is `inbox-send.sh <leg-session>
--file <path>`, delivered as `PostToolUse`/`SessionStart` additionalContext on
the worker session's next tool call; worker session → supervisor session is the same script addressed to the
supervisor session's own session name. `AskUserQuestion` reaches nobody on a claudex worker session
while the operator is away — every claudex brief must say so and give the worker session
the supervisor session's exact session name.

Inbox delivery is **tool-call-gated**. Before ending a turn at BLOCKED,
READY, PR-READY, or a blocking question/PROBE ask, the worker session arms ONE bounded
Monitor on `bash scripts/handover/console-kit/inbox-follow.sh --wake
<handover-root>/inbox/<session>.md`, with `timeout_ms: 1800000`. Resolve the
root through `handover_root()` and use only the worker session's own exact session name.
The supported API has no persistent flag. The worker session re-arms on expiry for at
most eight windows/four hours per unresolved hold; unrelated wakes do not
reset the wall-clock cap. Full lifecycle, failure recovery and wrap rules:
[`leg-preface-claudex.md`](leg-preface-claudex.md).

The fixed wake envelope is data only: the worker session makes a benign tool call to
receive the authoritative inbox hook delivery before acting. The follower's
`.md.cursor` never steals the hook's `.cursor/<session>` delivery cursor;
restart drains lines appended during a re-arm gap without normal replay.
Suppression can lose a wake, so expiry must trigger hook delivery too. The
short claudex idle-wake probe (n=1) is not a four-hour soak or a
cross-lane persistence claim. No registry or hook authority changes here.

## Rulings

A worker session that hits something it cannot decide reports to the supervisor session, not to the
operator. The supervisor session verifies the finding itself, then answers.

Re-tasking a running worker session goes through the **RETASK channel**: each dispatch
carries a fresh nonce, and a genuine revision is a direct message quoting it.
Expanding or redirecting a worker session needs the token; narrowing it or halting it does
not — that asymmetry is deliberate, so a halt can never be argued away. Full
threat model and the verbatim block:
[`../internals/retask-channel.md`](../internals/retask-channel.md).

**A ruling that widens what a worker session may do is refused by the worker session's own auto-mode
classifier**, for example an extra push, or SKIP verdicts in place of a suite
that a guard blocked. The refusal is correct: a supervisor session ruling is not user
consent. Narrow the ask instead (run each suite on its own, with no runner
flags), or do the step from the supervisor session, for example push the worker session's verified
head yourself and then tell it to continue.

**Address `inbox-send.sh` by the worker session's real session name**, the `-n` it was
launched with (see its launch log). That name may lack the doc's date suffix.
A ruling sent to the wrong name is never delivered and raises no error, so run
`inbox-send.sh --pending` after sending.

**A PR parked at the round-3 review cap gets one more review round from the supervisor session,
never from the worker session**. Run
`scripts/handover/console-kit/grant-round.sh <pr> <new-head> <qid>`. It grants
only on a signed judge record for that exact head, a PR that has reached the
cap, a head that is still the PR's live head, and a qid no earlier grant
consumed; one record buys one round. A worker session or a relay is refused (exit 3). A
judge's NO-GO on a head that follows the reviewed one by a test-only or
comment-only commit is written with
`write-verdict.sh ... --bind-reviewed <reviewed-sha>`: the verdict
keeps naming the judged head and carries a signed `reviewed-head:` line, and any
other delta is refused with nothing written.

## Merges

`READY <pr> <head> GREEN` → the supervisor session verifies independently (all check-runs
green at that exact head, zero unresolved review threads, attestation trailers
in the first commit) → `GO` → the worker session merges and reports `MERGED #<n> → <sha>`.

The Jira close is the worker session's call from the brief, not a default:
`merge-on-green.sh` transitions the ticket only on `--jira-transition`,
and the brief's Ship contract carries `completes-ticket: yes|no`
— `yes` → the worker session passes the flag, `no` (the ticket spans further
PRs) → it omits it. After `MERGED`, re-read the ticket: the flag closes only the
first `[KEY]` of the PR title, so a multi-key PR needs its other ticket checked
by hand.

`scripts/handover/console-kit/ready-check.sh <pr> <full-40-hex-head-sha>`
mechanizes that independent verification: it re-runs checks
1-6 (head match + clean merge state, statusCheckRollup all green, zero
unresolved review threads, an automated review ledger row for that head, attestation
trailers in the first commit, a ticket ID on every commit subject) and
prints `READY-CHECK PASS|FAIL`. It is read-only — no ledger rows, GO files,
or PR comments — and it does **not** read the three-dot diff; that judgement
call stays the supervisor session's own, which the script says on its last line. On a
PR that is already `MERGED`, GitHub reports `mergeStateStatus: UNKNOWN`
permanently, so check 1 always fails there — that is expected, not a bug;
the script's domain is a PR that has not yet merged.

`scripts/handover/console-kit/ready-go.sh [--to <leg> --token <nonce>] [--ledger <console doc>] <pr> <sha>`
is the whole mechanical READY turn in one call: the `ready-check.sh` output, the coverage line, the trust-path result, the ticket state and the exact GO line to send. It is read-only (no GO file, no message): `go.sh` and the SendMessage stay yours.

The automated review ledger is keyed by head sha, so **every push needs its own review
round**, even a one-line fix after a judge's NO-GO. A ruling of "no new
`/pr-check` panel" leaves check 4 with no row to find, and the marker-clear
script refuses when no critic answered at that head. Word the ruling as "one
`/pr-check` round at the new head; only Critical or Important findings block".

A PR on HIMMEL-2973/2976/2928/2974/2975 is READY only if its body cites
`HIMMEL-2977 "GATE <previous lever> PASS <date>"` (for 2973:
`P0 EXIT <date>` — this line carries no separate status word; its mere
presence, verbatim, is the pass signal for 2973). Open HIMMEL-2977's comments
and find that citation's line verbatim: a missing citation or a line not
found is not READY; for the general `GATE ... <status> <date>` shape (every
ticket except 2973), a found line whose status is not PASS is also not READY.
The supervisor session pulls the primary and the worker session wraps (closing its ticket only if the
brief's `completes-ticket: yes` says the PR completes it).
The supervisor session sends the GO file (merge approval) by first running `bash scripts/handover/console-kit/go.sh
<pr> <full head sha>` — the file IS the GO, the SendMessage is the
notification: a leg launched by `headed-arm-leg.sh` carries
`HIMMEL_CONSOLE_LEG=1`, and `merge-on-green.sh` refuses it (exit 17) without a
GO for the exact head it certifies, so a push after GO needs a fresh one.
`go.sh` runs `ready-check.sh` itself and writes nothing unless
it passes (exit 4). A `--trust-reviewed <qid>` GO also needs the
judge's ``**GO** for head `<sha>`.`` verdict under `verdicts/<qid>/` (exit 5).

An opt-in auto-merge stops at "awaiting approval" wherever branch protection requires
a review the automation identity cannot give — on a single-maintainer repo the
only path through is the admin bypass, which the merge script refuses by
design — so the supervisor session hands the merge to the operator and sends `MERGED`
back when it lands.

### Fork PRs (himmel adapters)

A PR on a fork we own merges only when the repo is listed with `merge_allowed`
true in `scripts/guardrails/himmel-adapters.json` (read from the default branch,
so a worktree edit cannot widen it) and the PR targets that entry's
`himmel_branch`. Run the judge, then, from the primary checkout:

1. `bash <anchor>/scripts/handover/console-kit/go.sh --repo <owner/repo> --trust-reviewed <judge-qid> <pr> <head>`
   (exit 6 not allowlisted or the harness repo itself, 7 PR not OPEN, CLEAN and on the adapter branch at that head
   or a review thread still open, 5 no signed judge GO).
2. `bash <anchor>/scripts/handover/merge-fork-pr.sh <owner/repo> <pr> <head>`
   (console only; a bare `gh pr merge --repo <fork>` stays refused).

Both scripts require GitHub's `mergeStateStatus` CLEAN (every check at the head
passed, no conflict, up to date) and zero unresolved review threads, so a PR
with pending or red checks gets no GO and no merge. A push after the GO needs a
fresh GO.

## Handing over

Supervisor sessions hand over at **45 % context fill, or 90 k input tokens in one turn**.

```bash
/console next --arm --doc <this console's own doc> --bucket <its bucket> --prefix <its prefix> --model <its model>
```

**Name your own document, bucket, prefix and model explicitly.** Without
`--doc`, `next` hands over from the highest-lettered doc it can find — the
wrong one as soon as another `new` has run or a successor already exists;
without `--bucket` and `--prefix` it re-resolves those from the environment
and writes the successor into the wrong bucket, or under the wrong key;
without `--model` it re-resolves the model from `CONSOLE_MODEL` or the
built-in default instead of continuing on the model this supervisor session itself runs
on. The rendered supervisor session doc carries the exact command with all four already
filled in.

`next` writes the successor stub (letter bumped, pointed at this supervisor session and
its HANDOFF) and the predecessor's `-HANDOFF.md` skeleton, and arms the
successor on a signal file. The letter rolls past Z in bijective base-26 (Z →
AA → AB → … → ZZ, then refuses) instead of ever refusing at Z; pass `--date
<YYYY-MM-DD>` to pre-mint tomorrow's first console (`A`) immediately, near
midnight, instead of waiting for the date to roll over. Fill in the HANDOFF —
head, what is in flight worker session by worker session with nonces and lock tokens, rulings made,
the held queue in launch order, what wrapped — then `touch` the signal path
that `next --arm` printed and hand your live worker sessions over by name.

**Re-brief your live worker sessions before you release**. Each
worker session's brief names *you* as its supervisor session, and a successor is a different session
on a different socket: the successor names itself to you during its ACTION ZERO,
you send each worker session — from your own session — a message naming the successor and
quoting the worker session's current token. The worker session's quote-back is the `SUCCESSION
accepted` Results bullet in its own doc (the successor's waiter tallies it); it sends a
`SendMessage` only on a timeout or a decline. A fresh
token is optional: a successor MAY issue one per worker session (then quote it too, and the
worker session quotes it back); a relay with none is complete and the worker session keeps its own.
A successor that arrives after you have left can prove itself only with the
two-token chain form; a worker session that cannot verify that is stranded (it keeps
working and can still be merged, but cannot be re-scoped). The successor's
tick reads `nonces=UNCONFIRMED:<leg>` until each worker session's own `SUCCESSION
accepted` bullet names the successor (`RELAYED:<leg>`, a relay that kept the
worker session's token, is valid) or the worker session has rotated.

**Release your lock only after the successor reports `LIVE`.** It sends that
only after the quote-backs — or with the worker sessions that did not quote back named,
and why (ACTION ZERO step 9) — and it is the only evidence the arm actually fired
and the successor completed ACTION ZERO; releasing on the `touch` alone leaves
an unattended fleet if the launch failed.

**Wrap only with no subagent still running**. An in-process
subagent, a judge subagent above all, dies with its parent session and its verdict
with it. Wrap with `console.sh wrap <your doc> <release-token> '<line>'`: it
writes `WRAPPED` and releases the lock, and refuses (exit 4, nothing written)
while `console-kit/live-subagents.sh` finds a running child of this session or
cannot tell. The successor's `close-wrapped-leg.sh --console` holds the same
line from the outside: exit 7 means the predecessor still has a live subagent;
retry once it finishes. Every judge subagent persists its verdict with
`write-verdict.sh` under `verdicts/<qid>/`, trust path or not, and the HANDOFF
lists the open judge subagents (`next` fills in the children still running), so a
successor reads a verdict instead of re-running the judge.

How a live subagent is detected from outside its session: Claude Code writes
`<projects>/<proj>/<session>/subagents/agent-<id>.meta.json` when it launches a
child, and appends a `queue-operation` enqueue of the child's
`<task-notification>` (carrying `<task-id><id></task-id>`) to the parent
transcript the moment the child stops, whether or not the parent ever reads it.
A child with a registry entry and no later completion record is running. A
foreground child completes with its `tool_result` instead. The process tree
cannot see a subagent (it is not a process), and the `tasks/<id>.output` links
outlive the child.

The HANDOFF is the successor's only required read. Written properly, the succession
does not need the predecessor's transcript at all.

## Switching the Claude account

An account switch is a machine-level login: one active Claude account per
machine, so it changes the subscription usage budget every worker session and supervisor session draws on,
not any routing. Do it at a boundary, in this order.

**1. Before the switch — bring the worker sessions to a boundary.** Let each worker session reach a
milestone (`READY`, `FINDING`, `RESOLVED`) or `WRAPPED`; do not switch mid-turn on
a deep-context worker session. The cost is not yet measured: the prompt-cache audit
([`../internals/prompt-cache.md`](../internals/prompt-cache.md), row 11) marks
"an account switch rewrites the full prefix of running sessions" **UNVERIFIED**.
Its live run L5 was a weekly usage budget reset on the *same* account, not a switch: 2
sessions kept their prefix, 0 invalidated, 0 compacted (a supervisor session reading about
318k tokens from cache stayed warm). So a real switch is still untested — if it
does invalidate, expect each live session to re-pay its whole prefix, which is
why a worker session parked at a boundary is cheaper than one switched mid-turn. Record what
you see (re-run `invalidation --event <switch ISO>` from that doc's "Re-run").

**2. Decide every armed resume.** List the jobs, find the `HIMMEL-Resume-*` ones
(`at -c <job-id>` shows the marker), and keep or cancel each — one armed for the
old account's reset fires against the wrong subscription usage budget:

```bash
atq
atrm <job-id>
```

`auto-arm-on-cap.sh` re-arms a resume on the next tool call once any window is at
or above `AUTO_ARM_THRESHOLD` (default 90 %) and none exists, so an `atrm` made
early can be undone before you finish. **Cancel last** — after the worker sessions are
parked and as the final action of the session, or from a plain terminal.

**3. After the switch — refresh the usage cache.** The cache is stamped with the
account that wrote it; `bank-preflight.sh` reports `BANK-UNKNOWN` while the
stamp does not match the logged-in account. Force
one re-derive, then confirm the new numbers:

```bash
USAGE_FORCE_REFRESH=1 bash scripts/statusline/usage-cache-producer.sh <<< '{}'
bash scripts/lib/bank-preflight.sh
```

Pass: `bank-preflight` prints the new account's `five_hour` / `seven_day` and
`PROCEED` (or `SKIPPED-BANK` if that account is genuinely high). `BANK-UNKNOWN`
means the cache is still the old account's — refresh again, or check the login.

**4. Confirm the weekly budget override voided itself.** An override is bound to the
account that set it, so it is no override under the new login; only the operator can
set one (`bank-lift.sh set`). Verify:

```bash
bash scripts/lib/bank-lift.sh show
```

Expect `bank-lift: INVALID: account` after an account switch. Other invalid
reasons are `expired`, `window`, `trust`, `parse` (or `missing` when unset).
The doctor reports `lift set but INVALID: <reason>`. A stale file is harmless
and can be removed with `bash scripts/lib/bank-lift.sh clear`.

A one-window weekly budget override skips only the weekly ceiling; `five_hour` still binds.
Whole-second reset values tolerate up to one second of fractional API jitter,
not a different weekly window. Only the operator can enable the standing
"spend to 100 %" policy:

```bash
bash scripts/lib/bank-lift.sh set --standing
```

It records `standing:true` in the same operator-only, account-bound override file
(no new state path or hook bypass). The policy applies to every fresh window
for that account and defaults `CADENCE_BANK_MAX_PCT` to 100 for launch checks.
An explicit ceiling still controls `five_hour`; either usage budget at 100 refuses,
so extra usage is never spent. Plain `set` replaces it with a one-window weekly budget override;
`clear` disables it. Agents must never run either form of `set`.

The Done-when for this change needs the operator to walk this once at a real
switch and record the result (and the cache-probe verdict from step 1) in the PR.

## Controlling the VM CI runner

Two VirtualBox VMs (`himmel-ci-1`, `himmel-ci-2`, cloned from the
`ci-runner-v3` snapshot, 4096 MB and 4 CPU each) can run the 8 ubuntu
shell-unit shards. The console drives them with one script, each form a bare
relative literal pre-approved in `.claude/settings.json`:

```
bash scripts/handover/console-kit/vm-runner.sh on            # both VMs
bash scripts/handover/console-kit/vm-runner.sh on --vms 1    # or --vms 2
bash scripts/handover/console-kit/vm-runner.sh off           # kill switch
bash scripts/handover/console-kit/vm-runner.sh status
```

- `on` refuses (rc 3) unless the repo's fork-PR approval policy is
  `all_external_contributors`, clones VM 2 when missing, sets the
  `HIMMEL_VM_RUNNER` repo variable to `on`, removes `~/.himmel/ci-runner.stop`
  and starts one `himmel-ci-runner@<n>.service` user unit per VM. A unit that
  will not start switches the runner `off` again.
- `off` sets the variable `off` first (so GitHub stops routing to the VMs),
  writes the stop file and stops the units; a job already running is not
  re-queued but no new runner is minted.
- `status` prints the variable, per-VM up/idle/busy state and the last error.
- `tick.sh` carries `vmrun=<off | ok:<up>/<want>,busy=<n> | DEAD | STUCK | FAILING | DISAGREE:<up>/<want>,online=0>`.
  `DEAD` is variable on with no unit up; `STUCK` is a job running past its
  budget plus ten minutes; `FAILING` is a loop whose newest log line is an
  error, or a GitHub runner count that could not be read; `DISAGREE` is a unit
  with a registered, unfinished runner while GitHub shows no himmel-vm runner
  online (zero online between jobs is normal and reads `ok`). `console-wait.sh` wakes only on a move to `DEAD` or
  `STUCK`; answer with `status`, then `off` and a note to the operator.
- With the variable `on`, `ci.yml` runs the `shell-unit-shard` matrix on the VM
  runner for a same-repo `pull_request` whose author and actor are the operator
  accounts; everything else (fork PRs, other authors, push, schedule, dispatch)
  and the variable `off` or unset run on `ubuntu-latest`, with the required
  check names unchanged. `scripts/ci/test-ci-vm-routing.sh` pins that
  expression. The routed shard's apt, sudo and pip steps run on GitHub-hosted
  runners only (`runner.environment == 'github-hosted'`); the guest must carry
  the tools instead (`guest-provision.sh`). **Keep the variable `off`** until the
  guest image has been rebaked with those packages (`ci-runner-v4`) and a
  `vm-runner-probe.yml` dispatch has passed with no operator PR CI running:
  until then every routed shard would fail and fail-fast blocks the PRs.
- A classifier denial of one of these commands means the allow rule is missing
  or mismatched; see the stuck playbook, never reshape the command.

## See also

- [`console-template.md`](console-template.md) — the supervisor session's operating contract
- [`console-handoff-template.md`](console-handoff-template.md) — the handover skeleton
- [`leg-brief-template.md`](leg-brief-template.md) — what a dispatched worker session gets
- [`overnight-mode.md`](overnight-mode.md) — the unattended-pipeline alternative
- [`../internals/retask-channel.md`](../internals/retask-channel.md) — authenticated re-tasking
- [`../internals/lane-calibration.md`](../internals/lane-calibration.md) — tiers, effort, wake-up budget
