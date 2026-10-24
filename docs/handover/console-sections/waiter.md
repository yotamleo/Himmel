# Console section — the event waiter (ACTION ZERO step 10)

Read on demand from `console-template.md` step 10. `<kit>` is the kit path in step 7. Moved verbatim from the template.

10. **Start the event waiter now** (it replaces the `tick` and
    `telegram` Monitor loops). Loops are pure code, never model turns: a
    `Monitor` arm is capped at 30 min, and every expiry woke this full-context
    session only to re-arm it. Instead, run `console-wait.sh` **once** with the
    **Bash tool's `run_in_background: true` AND `timeout: 7200000`** — both
    are required: the default background limit (30 min) killed a waiter once. The harness re-invokes you when the command exits:
    `bash scripts/handover/console-kit/console-wait.sh "<inbox>" --doc "<this file>" --token <your token> --legs "<absolute leg docs>"`
    (everything after the inbox path is passed to `tick.sh` unchanged). It is
    silent while nothing happens and **exits on the first real event**,
    printing one block: `WAKE telegram` plus the operator's line(s), or
    `WAKE tick changed=<fields> bank=<verdict>` plus the tick line, or
    `WAKE underfilled capacity=UNDERFILLED:<slack>` (on the streak's first sample, and again once each time the pool's key set changes: it is re-probed every 30 min, `CHIEF_WAIT_UNDERFILL_REPOOL_SEC`, each probe cut at `CHIEF_WAIT_REPOOL_TIMEOUT` (120 s), and a pool that grows from empty counts, while a pool that empties or a failed probe does not wake; plus the tick line and `next-dispatchable.sh --priority-pool-only`'s
    ranked list (the pool: the `priority:` line in Live state, labels `ps3-blocker` / `must-v1.1.3` / `operator-directed`, High+ bugs, security and data-integrity; per tier its `RESUME` rows, In Progress with no leg and no open PR, lead the To Do rows, only when a leg source (`--owners` / `--legs-from`) is given, and they are kept in `--priority-pool-only` by design (operator decision 29: drain In Progress work with no leg first): the waiter passes its own `--legs-from` file when it was started with one, and no `--owners`; <!-- old-term-ok: pre-existing prose, only the waiter clause changed -->
    a closing `# pool=<rows>/<slack>` line, `,LOW` when the pool fills fewer slots than the slack, and `POOL-EMPTY` when it has nothing, followed by the next tier (tier-4 To Do rows in rank order) as `NEXT-TIER` rows: then unblock collisions, draft specs for the next priority items, or fill from the NEXT-TIER rows when the operator has ruled so); dispatch it with `gen-briefs.py`; both refuse Windows/WSL work per `console-kit/platform-dropped.re` unless the ticket is labelled `windows-removal` / the leg sets `platform_removal` and its title says remove/drop/delete/retire/sweep/clean), or
    `WAKE tick-fail samples=<n>` when 3 samples in a row failed (the tick or
    the bank read is broken: fix it, then restart the waiter; it wakes once per
    failure streak), or, on a successor's first arm only (ACTION ZERO step 9,
    `--succession <your session> [--silent-min T]`), `WAKE succession complete
    <k/n>` plus the printed LIVE command when every inherited leg's `SUCCESSION
    accepted` bullet is in, or `WAKE succession partial <k/n> silent <T> min`
    naming the legs still out. Each fires once; **re-arm without `--succession`**
    (a re-arm that keeps it after a complete wake stays quiet). An outgoing
    chief started with `chief.sh next --relay-on-live` gets `WAKE relay-on-live
    successor=<session>` plus `relay-batch.sh`'s SENDMESSAGE lines once the
    successor's lock is held fresh; send each line. It runs `tick.sh` every
    180 s and wakes only when two consecutive samples differ from the action
    key you last saw: `legs=` (a leg FRESH → STALE / FREE / WRAPPED …),
    `livestate=` (DRIFT / MALFORMED), `prs=` (the repo's open-PR set — any
    PR opening or merging, yours or not), `orphans-wip=` (an In Progress /
    In Review ticket nobody holds — no leg, no open PR: dispatch it as a RESUME
    row of `next-dispatchable.sh`), `tails=` (a leg's marker: FINDING, READY …),
    `legset=`, `board=` (its class — the STALE age alone does not wake, and a
    move TO `ok` never wakes on its own either, since that's just the console's
    own render; the key still saves, so a later move to STALE/MISSING wakes
    again) and the
    `bank-preflight.sh` verdict word. Heartbeat, procs, fill, fleet, gql and
    orphans never wake (`capacity=` wakes only through `WAKE underfilled`). An idle console therefore takes **zero** turns.

    **Re-start it at the end of the turn that handles each wake** — the waiter
    has exited, so a turn that does not re-start it leaves you deaf to Telegram
    and to the tick. Start it in the same turn as your other work, never as a
    turn of its own. A re-start with changed tick args (a dispatch or wrap
    changed `--legs`) takes a silent baseline instead of waking you for your own
    act. Leg messages (`SendMessage`) wake you on their own; only the Telegram
    and tick paths depend on the waiter.

    **Verify it is live** — record in your first bullet the background task id
    the Bash tool returned, and read the heartbeat next to the inbox:
    `cat "<inbox>.wait"` → `hb=<epoch> pid=<pid> key=<hash> tick=ok state=waiting`,
    rewritten every second between samples. `state=sampling` is a tick in
    progress: a sample (tick, then bank) can take about 4 min (twice the 120 s
    timeout, plus a 5 s kill grace each), and a Telegram line waits for it. `state=exited exit=<reason>` is
    a waiter that stopped (`wake-telegram`, `wake-tick`, `signal-TERM` …); a
    `state=waiting` or `state=sampling` heartbeat older than about 5 min is one
    that was SIGKILLed (untrappable). `tick=fail` means `tick.sh` exited
    non-zero or produced no TICK line (it runs under a 120 s timeout, so a hung
    tick cannot hold the Telegram path forever). A second waiter on the same
    inbox is refused (exit 3, naming the live pid). Measured: a
    background task that exits, or that is SIGKILLed from outside, re-invokes
    the idle session. **Not reproduced:** the harness-internal "low memory" kill
    of a background task — a waiter lost that way is visible only
    as a stale heartbeat; a bridge-side stale-heartbeat
    alert is a planned follow-up.

    **Re-start the waiter on every dispatch and every wrap, with absolute leg
    doc paths**: stop the running one with `TaskStop` and start a
    fresh one. The tick judges only the legs `--legs` names; a leg you
    dispatched after starting it is not in it. The tick says so rather than
    guessing: `legset=STALE:unarmed=<leg,…>` (in `## Live state`, not in the
    arm) and `procs=<n>,unwatched=<leg,…>` (a live leg session the arm does not
    name) both mean **your arm is out of date, not that a leg is in trouble** —
    re-start with the current leg docs. `legset=STALE:…;unlisted=<leg,…>` is the
    reverse: an armed leg that is no longer held and not in `## Live state`,
    i.e. a wrapped leg to drop from the arm. `unwatched=` reads the whole
    process census, so with more than one console on the host it can name
    another console's legs. `tick.sh`'s own `tick=` field still reads `UNKNOWN`
    (see its `ponytail:` comment); the heartbeat above is the liveness signal.

    **Or arm from a fleet manifest and skip the re-starts**:
    keep the leg set in `<this file's stem>.fleet.json` next to this doc and
    start the waiter with `--legs-from "<that file>"` in place of `--legs`.
    On each dispatch run `bash "<kit>/fleet-manifest.sh" add "<manifest>"
    "<absolute leg doc>"`; on each wrap, `… remove "<manifest>" <N-label>`.
    The tick re-reads the manifest every sample and the waiter takes a silent
    baseline when its leg set changes, so neither needs a re-start; the
    `legset=`/`unwatched=` checks above then compare against the manifest.
    Then render the `legs:` entries from it instead of editing
    them: `bash "<kit>/live-state.sh" "<this doc>" [--nonce <N-label>=<nonce>]`.
    It reads each leg's lock token from its held lock and keeps the nonce and
    pid already on the line; a leg not yet listed needs `--nonce` (the nonce is
    yours, never read from the leg or the manifest). A manifest leg holding no
    lock is left out. The rest of `## Live state` is still yours to edit.
    **Your manifest:** `<your manifest>` — <note>.

    **The waiter wraps workers; do not run `leg-event` / `close-wrapped-leg` by
    hand; run any other bounded script as `timeout 90` in the foreground.** Armed
    with both `--doc` and `--legs-from`, the waiter is the script relay (R0): a
    worker whose `tails=` turns `WRAPPED` or whose `acts=` turns `MERGED` is
    wrapped by `timeout 90 leg-event.sh --doc --fleet` on a line built from that
    worker's bullet, with no wake. `HANDLED` lands in `<inbox>.wait.digest`; a
    refusal that only means "not yet" (lock still held, tail not yet `WRAPPED`,
    subtree alive) is retried next sample. Anything else wakes you once per
    bullet with `WAKE leg-event <its line> out=<file>` plus the tick line: read
    the out file and finish that wrap by hand (`wrapping.md`). Every WAKE block
    ends with `absorbed since last wake: wraps=<n> (<labels>) merged=<n> (#<pr>,…)`
    when the relay absorbed anything (labels and PR numbers only), and the
    digest starts over. The relay takes no lock and sends nothing to a worker;
    the chief keeps every authority write (GO, judge, dispatch, Jira).

    **A hold wakes you once.** `WAKE tick changed=holds` means a worker entered the
    `holds=` set (`BLOCKED`, or a `FINDING` awaiting a ruling, untouched for
    `TICK_HOLD_MIN` minutes, default 20): read its newest bullet and answer it. It
    does not repeat while the hold stands.

    **Permission.** The tracked `.claude/settings.json` allows exactly the
    step-10 launch shape `bash scripts/handover/console-kit/console-wait.sh …`
    (`Bash(bash scripts/handover/console-kit/console-wait.sh:*)`) and nothing
    wider: no glob before the path, because a glob can span quotes and would let
    `bash "-c" "<cmd>" "…/console-wait.sh"` match. The harness refuses any
    command containing a `$VAR` expansion before it reads the allow list, so the
    command is spelled relative, never with `$HIMMEL_REPO`. The chief runs it with
    its cwd at the primary checkout root (a separate `cd` call first, never a
    `cd … &&` prefix), so it runs the primary's copy of the waiter. The
    operator's local Bash-wrapped absolute rule (`Bash(bash "<abs kit>/console-wait.sh" *)`,
    added through `/permissions`; a bare path with a wildcard is skipped as
    invalid) stays as the fallback for an absolute spelling. The chief never
    re-spells the command to dodge a refusal: it sends the operator the exact
    line and holds.
