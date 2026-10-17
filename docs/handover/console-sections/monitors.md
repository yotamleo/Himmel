# Console section — monitors in full

Read on demand from `console-template.md` `## Monitors`. `<kit>` is the kit path in step 7. Moved verbatim from the template.

## Monitors

**Compact tick line.** `tick.sh` omits empty and unconsumed healthy/default
fields: `hb=ok|skip`, `procs=0`, `models=none`, `ceiling=ok`, `atq=0`,
`suites=0alive/0dead`, `ext-prs=none`, `tick=UNKNOWN`, `burn=none`,
`orphans=none`, `nonces=ok|skip`, `plan-index=ok|skip`, `or=skip` and
`fails=none|skip`. Absence means that field's healthy/not-applicable default;
unknown/error values remain visible. Missing `tick=` still means UNKNOWN,
never proof that a monitor is armed. `--verbose` keeps the explicit labels.

`inbox=<label>:<bytes>/<cursor>` lists only inboxes with unread complete lines;
no `inbox=` means none. It uses the hook's `.cursor/<session>` delivery cursor
when present, otherwise the native follower's `<inbox>.cursor`. A wake cursor
cannot mask rulings still pending hook delivery; empty, consumed and
partial-line-only inboxes are omitted. Reading the snapshot never advances a
cursor.

All fields read by `console-wait.sh` or `board.mjs` retain their values and
order, even at defaults: `legs`, `livestate`, `prs`, `tails`, `legset`, `board`,
`tracker`, `vault`, `cloud`, `orphans-wip`, `vmrun`, `denials`, `bank`, `fleet`,
`gql`, `capacity` and `unowned-prs`, plus the existing conditional `parked`,
`closable` and `deadwin` alerts. In particular, `capacity=ok`,
`unowned-prs=none` and non-stale `tracker=` must stay present to clear the
waiter's persisted streaks. The compact format needs no reader change.

Five, and no more — every event wakes a full-context turn, so each one filters
to terminal-state changes and emits nothing otherwise. The tick and Telegram
rows are **not** `Monitor` arms: both run inside the one event waiter,
`console-wait.sh`, started in ACTION ZERO step 10 with Bash
`run_in_background`. Never arm them as `Monitor` loops — the
tool caps an arm at 30 min, and every expiry costs a full-context turn only to
re-arm.

| Monitor | Cadence | What it is |
|---|---|---|
| tick | 180 s, wakes on change | **Runs inside the step-10 waiter, not here** — the only unconditional check of the five, so its absence is the one that goes structurally unnoticed; the waiter's heartbeat (`<inbox>.wait`) is how you see it is live. The waiter passes its args to `tick.sh`: `--doc "<this file>" --token <your token> --legs "<bucket dir>/<leg1>.md <bucket dir>/<leg2>.md"` (or comma-separated — `--legs` accepts space- **and** comma-separated docs, both spellings produce identical output; use absolute paths, because a bare leg doc name resolves against the handover ROOT, not your bucket, and reads `NOTFOUND`) — one batched line: heartbeat, leg locks, leg processes, armed jobs, suite locks, open PRs, bank. Per-leg lock status is one of **`FRESH`** (held, heartbeat current), **`STALE`** (held, heartbeat aged), **`WRAPPED`** (lock released and the leg's last status bullet says `WRAPPED` — the normal end of a leg, nothing to reclaim), **`NOLIVE`** (no lock, no marker bullet, and older than `TICK_NOLIVE_MIN` minutes (default 10) — the leg never went LIVE; `ListAgents`, then `SendMessage` it the `queue-lock.sh acquire <its doc>` command, your console session name and its token), **`FORKED`** (its session transcript ends in a `continued-in` record — forked or backgrounded, likely without its preface; message it the same way, or relaunch), **`FREE`** (the literal token `tick.sh` emits when the lock is gone while the leg has *not* wrapped — a lost lock, reclaim it; its own comments call this state "MISSING" as a concept, but `FREE` is what actually appears in `legs=`), **`UNVERIFIED`** (a lock *named* for the leg doc exists but records a path that does not resolve here, so `queue-lock.sh` can neither attribute it nor rule it out — **not** free: find its owner before anything else, never reclaim on it), or **`NOTFOUND`** (the leg doc did not resolve — a warning about a typo'd/nonexistent path, *not* a dead lock; never mistake it for a released lock). The line also ends `legset=<ok\|STALE:unarmed=…;unlisted=…\|unknown\|skip>` — see ACTION ZERO step 10: `STALE` means re-start the waiter, not leg trouble. It then ends `board=<ok\|STALE:<age>\|MISSING\|skip>` — whether `console-board.html` still matches the state; anything but `ok` means re-run ACTION ZERO step 12. Next comes `tracker=<ok\|STALE:<age>\|MISSING\|skip>` — whether `roadmap-tracker.html` still matches the Jira mirror and the plan files (`skip` with no `tracker:` URL); `STALE`/`MISSING` means refresh, re-render and republish the tracker (step 12). Then `vault=<ok\|STALL:<age>,<n>\|PUSH-LAG:<age>\|skip\|unknown>` — the notes vault's commit health: `STALL` = the vault's auto-commit is stuck (the waiter wakes you; reproduce with `git -C <vault> hook run pre-commit`, usually a gitleaks false positive in a staged file), `PUSH-LAG` = commits unpushed past `TICK_VAULT_PUSHLAG_MIN`. The line also carries `orphans-wip=<0\|n:KEY,KEY\|n\|?\|skip>` — In Progress / In Review tickets with no leg and no open PR (keys named up to 5, a bare count above that, `?` when the open-PR read failed): a non-zero value wakes the waiter; run `next-dispatchable.sh --legs-from <fleet manifest>` (its RESUME rows come first and pass the file-collision check; the bare `--resume-only` read the tick uses knows no manifest and skips collisions) and dispatch each as a RESUME leg, or park it |
| bank | 300 s | poll `bank-preflight.sh`, emit only when the state word changes (headroom → park → weekly-ceiling) |
| CI | 600 s | poll `gh run list -R <owner/repo> --limit 20 --json databaseId,status`, emit only newly-completed runs |
| notes repo | 300 s | the notes vault is already covered by the tick's `vault=` field (no loop to arm); only a *second* repo for handover state needs this: emit only on STALL (dirty files older than the commit cadence) or PUSH-LAG |
| telegram | 1 s poll, event-driven | **Runs inside the step-10 waiter.** Operator messages sent from Telegram as `/console <your session name> <text>`, the inbox being `<inbox>`. The waiter drains it each second with `inbox-follow.sh --once` and wakes you with `WAKE telegram` plus the line(s). The persisted read cursor (`<inbox>.cursor`, a byte offset) means a line appended while no waiter ran is delivered on the next start, and delivered lines are not replayed (at-least-once: a waiter killed mid-emit can repeat one line). The file must exist before the bridge will write to it (step 11). See step 11 for the authority these lines carry and how to reply |

The three polling monitors are plain Bash loops over already-versioned inputs;
write them in the session scratchpad, not in the repo. The context-fill probe
(`scripts/context-fill.sh --percent`) **fails inside a Monitor** — run it in an
ordinary Bash call.

**Stuck PRs.** The tick's `prs=` field does not say why a PR is stuck. When a leg
waits on CI that never starts (a CONFLICTING PR gets no pull_request CI) or a PR
sits for hours, run `<kit>/pr-stall.sh --manifest <fleet manifest>` by hand: one
`STALL <pr> <class> <leg> <detail>` line per stuck PR (conflict, no-ci, ci-slow,
idle). Add `--notify` to send the owning leg the action once per (pr, class,
head). Not yet wired into the tick (HIMMEL-6049 slice 2).

**Label what the operator asks for.** A ticket you file because the operator
asked for it gets the Jira label `operator-directed`, and its Results bullet reads
`OPERATOR: <ask>. Filed HIMMEL-n`. The roadmap tracker builds the
operator-directed bundle from that label and that bullet.
