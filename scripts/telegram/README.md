# Telegram bun bridge — usage guide

The **bun bridge** is a standalone poller that watches the Telegram bot for
inbound messages and spawns a bounded `claude "<prompt>" </dev/null` run per
message (see `run-prompt.md` for the prompt contract). It does **not** need a
live `claude --channels` session — it owns the `getUpdates` poller itself.

Two processes make it up:

- `supervisor.ts` — restart loop + circuit breaker. Spawns `poller.ts`,
  respawns on crash with exponential backoff, trips after 5 immediate crashes.
  Writes `supervisor.pid` (its own pid + the live poller pid) so `--kill` works.
- `poller.ts` — the single `getUpdates` owner. Ingests messages, gates by
  allowlist, spawns the bounded claude run, delivers replies back to Telegram.

**Single-owner constraint:** Telegram allows exactly ONE `getUpdates` consumer
per bot token. A second poller (stale proc, or a `claude --channels
telegram-himmel` plugin session) causes `409 Conflict` storms and the bridge
goes deaf. Run exactly one. `restart-bridge.ps1` (Windows) enforces this;
`restart-bridge.sh` (POSIX — Linux/macOS, Stage-1) is its sibling launcher,
see below.

---

## Human — quick commands (Windows / PowerShell)

```powershell
# Start (or restart) the bridge — kills any stale bridge procs, starts ONE
# supervisor, settles 35s, verifies no 409 AND real progress (offset advanced
# or a poll heartbeat logged — HIMMEL-1510). This is the canonical Windows
# launcher.
pwsh -File scripts/telegram/restart-bridge.ps1

# Status only — report procs + 409 count, touch nothing.
pwsh -File scripts/telegram/restart-bridge.ps1 -StatusOnly

# Point at a non-default repo root.
pwsh -File scripts/telegram/restart-bridge.ps1 -Repo C:/path/to/himmel
```

Exit codes: `0` = up + clean · `1` = usage/env error · `2` = started but still
seeing 409 (investigate).

## Human — quick commands (POSIX / Linux, macOS)

`restart-bridge.sh` is the Stage-1 POSIX sibling of `restart-bridge.ps1`. It
covers happy-path start/run/stop/status, the stale-lock recovery `flock` gives
for free, and — since HIMMEL-2551 — a pidfile ledger used as an identity source
with a **staleness refusal** (a recorded pid whose process started after the
ledger was written is refused, the same class of guard as the PS1's
`Test-LedgerPidValid`). Unlike the PS1 it still does **not** ship the
`-FromLedger` verb itself, orphan `bun server.ts` detection, or the
offset/heartbeat progress-proof verify — so it does not prove no-409/real
progress after launch. Those remaining gaps are tracked as HIMMEL-2268, not
silently dropped; see the script's own header comment for the full honesty
note.

One platform caveat inside that: the stale-lock recovery is what `flock` gives
for free, and **stock macOS ships no `flock`** (nor does this repo's Windows
Git Bash). The script does not fail there — it prints a named WARNING and
proceeds without the lock, so start/stop/status still work and only the
serialization of two CONCURRENT starts is lost. Install `flock` (Homebrew's
`util-linux`) if you want that back.

```bash
# Start (or restart) the bridge — kills any stale bridge procs belonging to
# THIS instance (see below), starts ONE supervisor detached (nohup), returns.
bash scripts/telegram/restart-bridge.sh start

# Status only — report bridge process(es) found, touch nothing.
bash scripts/telegram/restart-bridge.sh status

# Foreground: same lock + same sweep, but exec the supervisor in the
# foreground instead of detaching. This is what the systemd unit runs.
bash scripts/telegram/restart-bridge.sh run

# Point at a non-default repo root.
bash scripts/telegram/restart-bridge.sh start --repo /path/to/himmel
```

**Kills are instance-scoped (HIMMEL-2551).** Matching `supervisor.ts` /
`poller.ts` on the command line only narrows the *candidates* — every himmel
checkout runs those same entrypoint names, so name-matching alone once let a
sandboxed test fixture SIGKILL the operator's live bridge. A candidate is
killed only if it is also this instance's: recorded in this bridge root's
`supervisor.pid`, or running with a working directory equal to this
instance's `scripts/telegram` (the cwd source is what still catches stale
orphans). A candidate whose cwd cannot be read and which is not in the
pidfile is left alone, with one WARNING on stderr.

A ledger entry counts only while it is **not stale** — i.e. the process did not
start *after* the pidfile was written. That single check is what lets both
identity sources coexist: without it, honouring the ledger across checkouts
would license killing another checkout's supervisor that merely inherited a
recycled pid (the same guard `restart-bridge.ps1`'s `Test-LedgerPidValid` has
always applied). When a timestamp cannot be read at all the check reports
*undeterminable* rather than guessing, and that licenses ownership only where
the cwd is unreadable too (the macOS/no-`lsof` host, which must still be able
to stop its own bridge) — a readable but mismatching cwd is evidence and is not
overridden. So on a host that reads cwds but not timestamps, a shared-root
instance stops being swept: a possible `409` accepted rather than possibly
killing a stranger's bridge.

*One poller per token* is preserved whenever two configurations share **either**
the bridge root (one shared `supervisor.pid`, e.g. a git worktree and the
primary checkout under one `$HOME`) **or** the checkout (one shared bridge dir)
— either way they still sweep each other. Only when the roots **and** the
checkouts both differ are they isolated; on the same bot token those can now run
concurrently and Telegram will answer one with `409 Conflict`. That is
deliberate — the old "protection" was an indiscriminate machine-wide kill.
`start`/`run`/`stop` instead print one WARNING naming how many foreign bridge
processes they left alone; running exactly one bridge per token is an operator
responsibility.

Two roots sharing a checkout are deliberately not separated: from the outside,
"my own orphan from a previous run" and "another root's live bridge" are
indistinguishable when both run from the same directory — and reclaiming that
orphan is what the cwd source is for.

A test fixture should export `HIMMEL_TEST_FIXTURE=1`: under that marker,
`start`/`stop`/`run` refuse with **rc=3** if `BRIDGE_ROOT` is unset, or if
`--repo` points at a real checkout — i.e. the target bridge dir is inside any
git work tree, not merely the launcher's own (that case gets its own, more
pointed message). So a fixture can never operate on a real bridge by accident.
The work-tree test is unconditional: it walks up looking for a `.git` entry in
pure shell, with no `git` binary to be missing, so there is no host on which
the guard quietly stops guarding.
(`scripts/ci/run-shell-tests.sh` exports it for every suite it launches.)

`start`/`run` also refuse with **rc=4** (HIMMEL-2556) when another launcher's
handoff is still in flight — a short window after `nohup`/`exec` where the
future supervisor is already a live process but not yet visible to the
`ps`-based candidate scan, so a concurrent launcher would otherwise find
nothing to sweep and start a duplicate (two pollers on one token, `409
Conflict`). Both verbs write a launch marker file,
`<bridgeRoot>/supervisor.launching`, while still holding the lock, naming the
pid about to become the supervisor; a launcher that finds it still alive, not
yet visible, and younger than 30s refuses rather than sweep or launch. The
marker self-clears once the supervisor becomes visible or its launcher dies,
so it never wedges a later `start` — see
`docs/internals/telegram-bridge.md`'s "Launch handoff" section for the full
three-part rule.

### Stop the bridge

```powershell
# Graceful: reads supervisor.pid, kills supervisor first (so it can't respawn
# the poller in the gap), then the poller.
bun --cwd scripts/telegram supervisor.ts --kill
```

`--kill` return codes: `0` = killed/already gone · `1` = pidfile absent (not
running) · `2` = pidfile unreadable/corrupt, or a kill signal failed (e.g.
EPERM) → bridge MAY still be running, check manually (the pidfile is kept on
signal failure so a retry can still find the bridge).

POSIX equivalent: `bash scripts/telegram/restart-bridge.sh stop` — kills only
the bridge's own supervisor/poller processes, serialized under the same
token-scoped lock `start` uses.

### Logs

```powershell
Get-Content "$env:USERPROFILE\.claude\channels\telegram\supervisor.log" -Tail 20
```

A **clean, idle** poller logs nothing (the 30s long-poll is silent on success).
Repeated `getUpdates not ok: Bad Gateway` = Telegram-side 502 (transient,
usually clears on its own or after a restart). Repeated `409 Conflict` = a
second poller is alive — restart to reclaim single ownership.

---

## Human — survive a reboot (manual, one-time)

The bridge is a detached process; nothing relaunches it after a Windows reboot.
To auto-start it at logon, register the `HimmelTelegramBridge` scheduled task
**yourself** (Claude's auto-mode blocks creating persistence on your behalf —
by design):

```powershell
# Register (idempotent — re-run safely; -Status to report, -Remove to unregister)
pwsh -File scripts/telegram/install-logon-task.ps1
```

The task runs as you, only while you're logged on (the bounded claude runs need
your user session: bun, claude auth, and the bot token in
`~/.claude/channels/telegram/.env`). It invokes `restart-bridge.ps1`, which is
idempotent, so the logon task safely no-ops / reclaims if a bridge is already
up. Remove it with `pwsh -File scripts/telegram/install-logon-task.ps1 -Remove`.

### Linux (systemd user unit + linger)

The POSIX twin installs a systemd **user** unit
(`scripts/telegram/systemd/telegram-bridge.service`) instead of a scheduled
task. Preferred: let the install wizard's bridge-persistence step render and
enable it for you (`scripts/himmelctl/lib/bridge-persistence.js`'s
`installSystemdUnit` + `enableLinger`) — it substitutes the unit's
`@HIMMEL_REPO@` placeholder with your checkout path and runs the commands
below on your behalf. Once installed, don't hand-edit the unit file; re-run
the installer instead (it owns the substitution/escaping).

The unit is `Type=simple` and its `ExecStart` is
`restart-bridge.sh run` — the bun supervisor is the unit's own MAINPID, so
`Restart=on-failure` genuinely brings the bridge back when the supervisor
dies (including on a signal). `StartLimitIntervalSec=600` +
`StartLimitBurst=5` bound that: `supervisor.ts`'s circuit breaker halts with
`exit 1` when the poller keeps crashing immediately, and without a start limit
`Restart=` would relaunch it every 10s forever and silently override the
breaker. Five restarts in ten minutes leaves the unit `failed`, for a human
(`systemctl --user reset-failed telegram-bridge.service` to clear it once
you've fixed the cause). It was `Type=oneshot` + `RemainAfterExit=yes`
around a detached `start` until HIMMEL-2551, which made systemd blind to the
supervisor: the unit reported `active (exited)` right through a dead bridge.
**If you installed the unit before that change, the copy in
`~/.config/systemd/user/` is stale — re-run the installer to pick up the new
shape.**

Whichever way it lands, the unit alone is not enough — without linger it
stops the moment you log out:

```bash
systemctl --user daemon-reload
systemctl --user enable --now telegram-bridge.service

# Linger keeps YOUR systemd user instance (and this unit) running after you
# log out — e.g. over SSH after the session closes, or across a headless
# reboot before any login. Skip it and the bridge dies at logout.
loginctl enable-linger "$USER"
```

Check status: `systemctl --user status telegram-bridge.service` /
`journalctl --user -u telegram-bridge.service`; check linger:
`loginctl show-user "$USER" --property=Linger`.

---

## LLM (Claude session) — how to spawn / check the bridge

When asked to "start the telegram bridge":

1. **Check first** — never blind-start (a second poller = 409 storm):
   ```
   pwsh -File scripts/telegram/restart-bridge.ps1 -StatusOnly
   ```
2. **Start / restart** — the launcher is idempotent (kills stale, starts one):
   ```
   pwsh -File scripts/telegram/restart-bridge.ps1
   ```
   Treat exit `0` as success, `2` as "still 409 — investigate", `1` as env error.
3. **Verify health** — tail `~/.claude/channels/telegram/supervisor.log`. An
   empty / silent log after start = healthy (long-poll is silent on success).
   `Bad Gateway` = Telegram 502, transient. `409` = second poller still alive.
4. **Do NOT** `taskkill /IM bun.exe` (nukes unrelated bun work — the auto-mode
   classifier refuses it anyway). The launcher already scopes its kills to the
   bridge procs only.
5. **Do NOT** open a `claude --channels telegram-himmel` session while the bun
   bridge is up — that is a competing `getUpdates` owner. The two bridges are
   mutually exclusive per token.

The bun bridge and the `telegram-himmel@himmel` **plugin** bridge
(`claude --channels`, MCP-managed) are two different paths to the same bot
token. Pick one. This guide covers the **bun** bridge.

---

## Groups & channels (HIMMEL-238)

The bridge accepts a message if EITHER the sender is in `allowFrom` (DMs
only — an `allowFrom` sender posting in a non-allowed group is still
dropped) OR the chat is allowlisted: its chat_id is a key in `groups` in
`~/.claude/channels/telegram/access.json`:

```json
"groups": { "-1009999999": {} }
```

A non-empty per-group `allowFrom` (the fork's GroupPolicy shape) restricts
which senders are accepted in that group; a bare key admits every member.
Text-less service messages and stickers are dropped at ingest (photos are
ingested as `[photo]`, caption or not).

Plain group/channel messages get their own session (`group_<chat_id>`), so
replies route back to that chat — the operator DM is untouched. Ticket verbs
(`work on <KEY>` / `<KEY>: …`) route to the shared per-ticket session, whose
replies go to whichever chat FIRST created that session. Non-allowed groups
fail closed.

### require_mention (per-group) (LUNA-158)

Set `"requireMention": true` on a group entry to put it in @mention-only
mode — used for groups shared with a sibling bot (e.g. the grow-tent groups,
which also host `luna_grow_bot` and its own `/grow` command):

```json
"groups": { "-5245475441": { "requireMention": true } }
```

A group message in a `requireMention` group is dropped — before triage and
before the operator floor — unless its text `@mentions` this bridge's own bot
username (resolved at startup via `getMe`, retried every 60 s until it
succeeds; no message-entities parsing — a plain case-insensitive regex over
the text, which also accepts Telegram's `/cmd@botusername` command
addressing). The drop is logged as
`[poller] require-mention drop for <session>` in `supervisor.log`. While the
bot's username is unresolved, the gate fails OPEN (every group behaves as if
`requireMention` were unset) and logs a warning — it never silently goes
quiet; gating activates on the retry that resolves it, no restart needed.

### Posting with "Remain anonymous" on (HIMMEL-1358)

When a group ADMIN posts with Telegram's **Remain anonymous** switch on, Telegram
strips the real sender and substitutes the fixed `GroupAnonymousBot` id
`1087968824`. Your own id never reaches the bridge, so the triage **operator
floor** (which keeps an operator message out of the cheap-triage drop path) can
never match it — your messages get classified `ignore`/`ack` and are dropped
permanently, with only a `[poller] triage ignore: dropped (never enqueued)` line
in `supervisor.log` to show for it. That is not a bridge outage; the bridge is
healthy and discarding the messages.

Opt the group in per-group — allow-listing alone deliberately does **not** do
this:

```json
"groups": { "-1009999999": { "trustAnonymousAdmins": true } }
```

**What you are trusting.** The anonymous id is shared by EVERY admin of that
chat, so this says "any admin here may speak as me". Set it only where you
control the admin list.

Be precise about what the flag does and does not change, because the honest
answer is not "triage only":

- It does **not** grant any new capability. Allow-listing the group already lets
  every member submit work to the bridge (see the trust warning below), and
  `run-prompt.md` frames pending messages as the operator's requests regardless
  of who sent them (tracked as HIMMEL-1359). What the flag changes is narrower
  than "gets answered": an opted-in group's anonymous posts are guaranteed to be
  **enqueued** rather than subject to the classifier's ignore/ack verdict.
  Ordinary group messages stay fully triaged, and an enqueued message still waits
  if that session is already running — enqueue is the guarantee, not an immediate
  run. The verdict it bypasses was never a security boundary either: the triage
  gate is a cost filter and is fail-open (a classifier error returns spawn-high).
- It is **not** wired into the `/arm` auto-command surface. An anonymous `/arm`
  is refused by `autoGate.authorize` and falls through to ordinary chat, because
  an anonymous post cannot distinguish you from a co-admin.

**If the group also has a per-group `allowFrom`, the flag alone is not enough.**
A non-empty per-group `allowFrom` restricts senders at INGEST — before any
triage runs — and the substituted `1087968824` is not your real id, so an
anonymous post is rejected there and the floor never sees it. That rejection is
correct (the restriction is deliberate and this flag must not quietly undo it),
but it means a restrictively-configured group still loses anonymous posts
silently. To admit them, add `1087968824` to that group's `allowFrom` as well:

```json
"groups": { "-1009999999": { "allowFrom": ["<your-id>", "1087968824"], "trustAnonymousAdmins": true } }
```

Understand what that costs: the id is shared, so listing it admits the anonymous
posts of **every** admin of that chat — the same trust statement
`trustAnonymousAdmins` makes, now also at the ingest gate. If you are not willing
to make it, the alternative is to turn "Remain anonymous" off for that group.

**Deploying it:** `access.json` is read at poller startup, so the flag takes
effect only after a bridge restart —
`pwsh -File scripts/telegram/restart-bridge.ps1`. Verify with a real post from
that group: `supervisor.log` should show
`[poller] triage <verdict> → spawn-low (operator floor) for group_<chat_id>`, or
no triage line at all if the classifier already said spawn. A fresh
`dropped (never enqueued)` line means the flag did not take — check that the
chat_id key matches exactly (including the leading `-`) and that the restart
actually reloaded.

**Trust warning:** allowing a group trusts EVERY member of it — any member
can drive the bridge: chat text spawns bounded claude runs (prompt-injection
risk), and `work on <TICKET>` / `stop <TICKET>` verbs dispatch/halt ticket
sessions. Only allowlist groups whose full membership you control.

Operator-side requirements:

- **Groups**: BotFather privacy mode must be OFF (`/setprivacy` → Disable) or
  the bot must be a group admin — otherwise the bot never sees plain text.
- **Channels**: the bot must be a channel admin (posts arrive as
  `channel_post`, anonymous — gating is by chat_id only).

  > **Warning — channels must use an empty entry `{}`** (no `allowFrom`).
  > Channel posts have no `from` user: the poller falls back to
  > `sender_chat.id` — the channel's own `-100…` id — so a non-empty
  > `allowFrom` of user ids will never match and every post is silently
  > dropped (fails closed). Use `"-100xxxx": {}` with no `allowFrom` key, or
  > omit `allowFrom` entirely.
- A basic group's chat_id changes if Telegram migrates it to a supergroup
  (`-100…`) — re-add the new id to `groups` if that happens.

To discover a chat_id: post in the chat once. If the chat isn't allowed yet,
the poller logs `gated out chat <id>` to `supervisor.log`; once allowed, the
message lands in `~/.claude/handover/bridge/inbound.jsonl` with its `chat_id`.
The poller reads access.json ONCE at startup — restart the bridge after every
allowlist edit.

**Verified live (2026-06-10, HIMMEL-238 acceptance):** an allowlisted group
— plain message ingested, bounded run replied INTO the group, DM untouched;
an allowlisted channel — first post surfaced its id via the gated-out log,
allowlisted + restarted, posts then processed with replies into the channel.

## Privileged auto-commands — `/arm`, `/mergepub`, `/restart` (default OFF)

These commands are executed by the TRUSTED bridge itself rather than by a spawned
Claude session — the agent is never in the trust path:

| Command | Op name | What it does |
|---|---|---|
| `/arm <ticket-or-path> [at HH:MM\|auto\|smart]` | `arm-resume` | schedules a resume session via `arm-resume.sh` (time defaults to `smart`) |
| `/mergepub <pr> <sha12>` | `merge-public` | SHA-bound squash-merge of a PUBLIC propagation PR |
| `/restart` | `restart` | bounces the POLLER — supervisor respawns it (rung 1) |
| `/restart full` | `restart` | relaunches the WHOLE bridge with a fresh environment (rung 2) |

**All ship disabled.** Enable per-op with `TELEGRAM_AUTO_ACTIONS`, read from the
bridge's own `~/.claude/channels/telegram/.env` (the file that already holds
`TELEGRAM_BOT_TOKEN`) **or** the poller's process env — a process env var wins.
Restart the bridge to apply.

`TELEGRAM_AUTO_ACTIONS` is the *only* key that takes a process override.
`TELEGRAM_BOT_TOKEN` is read from that file and nowhere else, because the repo
`.env` holds a different bot's token for the jira-nudge relay.

```ini
# ~/.claude/channels/telegram/.env
TELEGRAM_AUTO_ACTIONS=arm-resume,merge-public
```

Rules worth knowing before you edit that line:

- The op names are exactly `arm-resume`, `merge-public` and `restart`. Unknown tokens are
  dropped, so `TELEGRAM_AUTO_ACTIONS=arm` enables **nothing** — the poller now
  logs a startup `WARNING: … enables NOTHING` naming the bad tokens (HIMMEL-1270;
  before that it was silent and indistinguishable from "off").
- `=1`/`all`/`on`/`yes` enable the non-merge ops (`arm-resume` + `restart`)
  but **never** `merge-public`. The
  public merge is `EXPLICIT_ONLY` — it must be named, so an operator running `=1`
  cannot silently inherit the capability.
- `/mergepub` needs a **12+ hex** SHA (`[0-9a-f]{12,40}`). A 7-hex one fails the
  router regex and reads as ordinary chat.
- Launching the bridge with `TELEGRAM_AUTO_ACTIONS=` (defined but empty) is the
  one-run kill switch: an explicitly empty process value beats the file, so it
  turns file-enabled ops off without editing anything.
- A disabled or unmatched auto-command is not an error: it never enters the
  auto-action path, it routes as normal chat. So the first question for any
  command that "did nothing" is whether it MATCHED at all — and
  `auto-action-audit.log` answers it, because a matched command always leaves a
  line there and an unmatched one never does. The `result=` labels:

  | Label | Meaning |
  |---|---|
  | `armed` / `already-armed` / `ambiguous` / `no-match` | `/arm` outcomes |
  | `merged` / `not-green` / `head-moved` / `no-open-pr` | `/mergepub` outcomes |
  | `restarting` | `/restart` accepted and fired |
  | `restart-unsupported` | `/restart full` on non-Windows (rc 20), or a build with no restart dep wired |
  | `refused-forwarded` | the injection kill-switch — any op, forwarded |
  | `error` | any op, any other non-zero rc |

  No line at all means it never matched: check the three points above (enabled?
  named explicitly? `/mergepub` 12+ hex? `/restart` with no trailing words?).
- Guards are unconditional and fail-closed: operator-only sender, typed (not a
  caption), not forwarded, whole-message match. Every attempt — executed or
  refused — appends a line to `~/.claude/handover/bridge/auto-action-audit.log`.
  One line each, with one exception: an accepted `/restart` logs `restarting`
  when it fires and a SECOND line (`error`, with the rc) if the fire itself
  failed — the acceptance and the outcome are separate events, because the
  process expects not to survive the first one.

### Which `/restart` do you want? (HIMMEL-1272)

The bridge can bounce itself, but the two rungs pick up different things, and the
difference is the **environment freeze**:

| | `/restart` (rung 1) | `/restart full` (rung 2) |
|---|---|---|
| What restarts | the poller only | supervisor + poller |
| Mechanism | poller exits 0, `supervisor.ts` respawns it | fires the registered `HimmelTelegramBridge` scheduled task |
| Picks up | anything re-read from a FILE at startup — incl. `TELEGRAM_AUTO_ACTIONS` | that, **plus** changed User/Machine env vars |
| Cost | ~instant | a few seconds |

Rung 1's respawn inherits the supervisor's environment, frozen when the operator's
shell launched it — so it will **not** see a `[Environment]::SetEnvironmentVariable(…, 'User')`
change. Only a process created by the Task Scheduler service reads the current User
environment at fire time, which is what rung 2 uses. That is also why rung 2 is not
just "run `restart-bridge.ps1`": that script's `Get-BridgeProcs` matches
`scripts[\/]+telegram`, which includes the calling poller, so an in-process call
kills its own caller mid-command. The scheduled task is launched by the scheduler
service and is fully detached.

Caveats for rung 2, both from the task's registration:

- **Logon mode is "Interactive only"** — it can only run while you are logged ON.
  Locked is fine; logged off is not. A failed `schtasks /run` is reported back to
  you with its rc rather than swallowed.
- **Trigger is "At logon time"**, so there is no periodic trigger and no watchdog.
  If a restart fails, nothing retries it for you.
- The ack is written to the outbox **before** the restart fires — the firing is
  what kills the transport. Expect the confirmation to arrive from the *new*
  bridge, a second or two later.
- `schtasks /run` exiting 0 only means the task was **launched**. If
  `restart-bridge.ps1` then fails, the old poller just keeps running — so rung 2
  arms a 90s watchdog: if the bridge is still alive when it fires, you get a
  second message saying the relaunch did not take effect, and an `error` audit
  line. Silence after the ack means it worked.

**Bootstrap, once:** enabling `/restart` for the first time requires a restart, by
hand, because the flag is read at poller startup. `pwsh -File scripts/telegram/restart-bridge.ps1`.
After that the bridge can bounce itself.

Semantics + threat model: [`docs/internals/enforcement.md`](../../docs/internals/enforcement.md).
Where each knob is set: [`docs/configuration.md`](../../docs/configuration.md).

## Group triage (HIMMEL-721)

Plain group/channel chat is fronted by a cheap classifier before the bridge
spawns a bounded Claude run. DMs and explicit operator routes (`status`,
`sessions`, `stop <ticket>`, `work on <ticket>`, ticket follow-ups, and enabled
trusted auto-actions) bypass triage.

The gate runs BEFORE the message is enqueued: the classifier sees the message
text first, and only a spawn verdict writes anything to the session inbox.

Environment:

- `TELEGRAM_TRIAGE=off` disables group triage. Default is on. The match is an
  exact, lowercase `off` — any other value leaves triage enabled.
- `TELEGRAM_TRIAGE_MODEL` selects the Hermes model. Default: `deepseek-v4-flash` (thinking mode by default; legacy `deepseek-chat` was non-thinking).
- `TELEGRAM_TRIAGE_PROVIDER` selects the Hermes provider. Default: `deepseek`.
- `TELEGRAM_TRIAGE_TIMEOUT_MS` is the classifier deadline in milliseconds.
  Default: `20000` (20s). A non-numeric or non-positive value falls back to the
  default. On expiry the call fails open (see below).

Verdicts:

- `ignore` drops the message — it is never enqueued, so no bounded run spawns
  and a later delivery sweep has nothing to resurrect. The skip is logged.
- `ack` drops the message like `ignore` (no reusable reply path yet); the skip
  is logged.
- `spawn-low` enqueues the message and, when the session is idle/done at triage
  time, spawns through the normal session path with model override `haiku`.
- `spawn-high` enqueues the message and preserves the existing default
  bounded-run model behavior.

The classifier is fail-open: errors, timeouts, and unparseable output all become
`spawn-high`, so a broken cheap lane does not drop actionable messages. The
triage prompt includes the message text only, not sender/chat metadata or local
paths.

**Known limitation:** the `spawn-low` `haiku` override applies only to the
direct spawn that fires when the session is idle/done at triage time. A message
queued behind a busy (running) session is later delivered by the ordinary
delivery sweep at the default model — the override is not persisted through the
inbox queue. Deferred to a follow-up; not fixed here.

**Consolidation pattern:** Telegram channels don't contain groups — to funnel
many sources through one allowlisted chat, forward/post their content INTO a
single allowed channel. Forwards arrive as ordinary channel posts, so the
source groups need no allowlisting and the bot doesn't need to join them.
Channel posts are anonymous (gating is chat-only) — anyone with post rights
drives the bridge, so keep the channel's post rights tight.

## Voice transcription (HIMMEL-251) — one-time machine setup

Voice notes (and audio files) in allowed chats are downloaded, transcribed
locally via whisper.cpp (free, offline, multi-language), and forwarded to the
session as `[voice transcript] <text>`. Transcription failure replies an
explicit "couldn't transcribe" to the chat — never a silent drop. Without the
setup below every voice note gets that error reply (graceful degrade).

```powershell
# 1. ffmpeg (OGG/Opus → 16kHz WAV conversion; must be on PATH)
winget install Gyan.FFmpeg.Essentials

# 2. whisper.cpp prebuilt binary + multilingual model → ~/.himmel/whisper/
mkdir $HOME\.himmel\whisper
curl.exe -sL -o $HOME\.himmel\whisper\whisper-bin-x64.zip https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.6/whisper-bin-x64.zip
Expand-Archive $HOME\.himmel\whisper\whisper-bin-x64.zip $HOME\.himmel\whisper -Force
# the zip nests everything under Release\ — flatten so whisper-cli.exe (and the
# DLLs it needs beside it) sit directly in ~/.himmel/whisper/ where the code looks
Move-Item $HOME\.himmel\whisper\Release\* $HOME\.himmel\whisper\ -Force
curl.exe -sL -o $HOME\.himmel\whisper\ggml-small.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin   # ~488MB, multilingual

# 3. smoke test
ffmpeg -version
& $HOME\.himmel\whisper\whisper-cli.exe --help
```

Overrides (poller env): `WHISPER_DIR` (install dir), `WHISPER_CLI`,
`WHISPER_MODEL` (full path to the `.bin`), `FFMPEG_BIN`,
`TRANSCRIBE_TIMEOUT_MS` (per step, default 120s).

**Model guidance (HIMMEL-291):** `ggml-small.bin` is the built-in fallback —
`transcribe.ts` defaults to it when `WHISPER_MODEL` is unset (`base` is
noticeably worse on non-English audio and multi-language is a hard requirement,
HIMMEL-251). For **mixed Hebrew/English** voice notes — the common case here —
prefer **`ggml-medium.bin`**: `small` garbled the first live he/en transcript,
so medium is the recommended model for he/en and is the one configured in use
(via `WHISPER_MODEL`, upgrade path below). Per-utterance language detection
(`-l auto`) is already wired in `transcribe.ts`, so no language flag is needed.

Upgrade small → medium (the configuration currently in use):

```powershell
# ~1.53 GB; ~1.3x realtime on CPU. Download, point WHISPER_MODEL at the FULL
# path (the env var is used verbatim — a bare filename would not resolve), restart.
curl.exe -sL -o $HOME\.himmel\whisper\ggml-medium.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin
[Environment]::SetEnvironmentVariable("WHISPER_MODEL", "$HOME\.himmel\whisper\ggml-medium.bin", "User")
pwsh -File scripts/telegram/restart-bridge.ps1
```

For long notes (>90s of audio), medium on CPU can approach the 120s
`TRANSCRIBE_TIMEOUT_MS` — raise it (user env) or evaluate `large-v3-turbo`
(faster + better multilingual than medium).

**Platform note:** the `WHISPER_CLI` default resolves to `whisper-cli.exe`
(Windows only). On macOS/Linux set `WHISPER_CLI` to the binary path
(e.g. `/usr/local/bin/whisper-cli`).

**Claude model pin (HIMMEL-671):** every bounded run spawns
`claude --model <m> …` with an explicit model — it never inherits the
operator's default model (which may be Fable, whose time-limited quota is
reserved for interactive work). `TELEGRAM_CLAUDE_MODEL` (poller env)
overrides the model; blank/unset falls back to the baked-in default
(`opus`). Channel-mode (`claude --channels`, operator-launched in a
terminal) inherits that terminal's model and is intentionally NOT pinned.

**Restart required:** all env vars above are read at poller start, not
per-message. After changing any of them, restart the bridge:
`pwsh -File scripts/telegram/restart-bridge.ps1`

**Acceptance test (HIMMEL-268):** after install, verify end-to-end with the
sample WAV shipped alongside the binary:

```powershell
# Verify ffmpeg + whisper-cli work together on the JFK sample
$env:WHISPER_INTEGRATION_TEST = "1"; bun test scripts/telegram/transcribe-integration.test.ts
# Expected: "1 pass" — transcript contains "ask" + "country"
# (Git Bash: WHISPER_INTEGRATION_TEST=1 bun test scripts/telegram/transcribe-integration.test.ts)
```

## Tests

Run from the **repo root** (the suites resolve helper scripts relative to the
cwd): `bun test scripts/telegram/<file>.test.ts --dots`.

The REAL-GIT cases build their throwaway repos under the OS temp dir through
`fixture-repo.ts`, and tear them down with its `removeFixture` — which
removes a path only if that helper created it, so a worktree you are working in
is refused and named on stderr rather than reaped (HIMMEL-1888).

When a case fails during a busy dispatch leg, run the same suite on `main`
under the same load before concluding the branch broke it — this family has a
measured history of failing purely with ambient load (HIMMEL-1786).

## Files

| File | Role |
|------|------|
| `supervisor.ts` | restart loop, circuit breaker, pidfile, `--kill` |
| `poller.ts` | single getUpdates owner; ingest → spawn run → deliver |
| `telegram-api.ts` | `getUpdates` / `sendMessage` HTTP wrappers |
| `run.ts` | bounded `claude` run + meta settle |
| `bus.ts` | per-session inbox/outbox/context bus on disk |
| `gate.ts` | DM sender + group/channel chat allowlist checks |
| `router.ts` | session classification (ticket vs chat) |
| `transcribe.ts` | whisper.cpp voice-note transcription (HIMMEL-251) |
| `transcribe-integration.test.ts` | live acceptance test (real binaries; needs `WHISPER_INTEGRATION_TEST=1`) |
| `restart-bridge.ps1` | **the canonical Windows launcher** |
| `restart-bridge.sh` | the Stage-1 POSIX launcher (Linux/macOS); parity gaps vs. the PS1 tracked as HIMMEL-2268 |
| `onboard.ts` | bounded onboarding run (`bun scripts/telegram/onboard.ts`) — reports chat.id/from.id for `access.json`; never writes it |
| `install-logon-task.ps1` | register/remove/report the `HimmelTelegramBridge` reboot-persistence task |
| `systemd/telegram-bridge.service` | systemd **user** unit template (`@HIMMEL_REPO@` placeholder) — Linux reboot-persistence twin of the logon task |
| `run-prompt.md` | the prompt contract handed to each bounded run |
| `fixture-repo.ts` | real-git test fixtures + the registry-gated teardown the spawn suites use (HIMMEL-1888) |

Bot: `@<your-bot-username>`. Token: `~/.claude/channels/telegram/.env`
(`TELEGRAM_BOT_TOKEN=`). Logs + pidfile: `~/.claude/channels/telegram/`.
Bus (sessions, inbound.jsonl, offset): `~/.claude/handover/bridge/`
(`BRIDGE_ROOT` to override).
