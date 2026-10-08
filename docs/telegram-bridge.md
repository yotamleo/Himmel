# Telegram remote bridge — adopter guide

Control Claude Code from your phone over Telegram: DM the bot, an always-on
bridge spawns a bounded Claude run per message and relays the reply back.

## What it is

An always-on **bun** process (`scripts/telegram/supervisor.ts` +
`scripts/telegram/poller.ts`) owns the single Telegram poll slot for your bot
token. For each inbound message it spawns a short-lived, bounded `claude` run
that does one turn and exits; a file-backed bus (under
`~/.claude/handover/bridge/`) carries per-session state across runs, usage
caps, and crashes. There is no long-lived Claude session to babysit — the
bridge itself is just the bun process.

Mechanism detail (delivery model, file bus layout, IPC, hardening) lives in
[`docs/internals/telegram-bridge.md`](internals/telegram-bridge.md); this page
is the front door.

## Required config

- `~/.claude/channels/telegram/.env` with `TELEGRAM_BOT_TOKEN=<your bot token>`
- `~/.claude/channels/telegram/access.json` with `{"allowFrom":["<your-telegram-user-id>"]}`

## Start / stop

**Start:**

```bash
cd scripts/telegram && bun supervisor.ts
```

The supervisor keeps `bun poller.ts` alive (restart-on-exit with backoff).

**Stop (cross-platform):**

```bash
cd scripts/telegram && bun supervisor.ts --kill
```

**Restart (Windows):** `pwsh -File scripts/telegram/restart-bridge.ps1` (add
`-StatusOnly` to just check). This is also the preferred lever on Windows
since it clears any duplicate pollers left by an older launch.

## What you can do from a phone

DM the bot once it's running:

- `work on <TICKET-KEY>` — dispatch: create/resume a session for that ticket and run it.
- `<TICKET-KEY>: <text>` — send a follow-up to that session.
- `status` / `sessions` / `stop <TICKET-KEY>` — control commands.
- Anything else — ordinary chat with the current session.

Privileged actions (arming a resume, restarting the bridge, and other
operator-only ops) are gated behind an explicit auto-command syntax and an
allowlisted-operator check — see the auto-action docs in
[`internals/telegram-bridge.md`](internals/telegram-bridge.md#ws-d--auto-mode)
for what's enabled and how it's authorized. A forwarded message can never
trigger one of these commands.

## Messaging a running console

`/console <text>` delivers to the **one live console**, without needing its
session name. Live means its waiter heartbeat is `waiting` or `sampling` and
less than five minutes old. With none live, nothing is queued; with several,
the bridge lists them and asks you to choose `/console <session-name> <text>`.
The first word names a console only when that inbox already exists; otherwise
it is part of the bare text. `/consoles` lists live names, heartbeat timestamps,
and bucket/project (older consoles without launch metadata show `unknown`).

Each console's first waiter arm queues a DM: “Console <name> is live — just
send /console <text>”. A successor announces its new identity on its first arm;
restarting the same waiter does not repeat the announcement. Replying to an
announcement, console acknowledgement, or console answer routes to that
console using the bridge's saved chat/message-id receipt, not quoted text.
Explicit slash/control commands keep their own routing when sent as replies.

Neither form starts a session. The bridge appends one line to that
console's inbox file, `<bridge root>/consoles/<session-name>.md` (default
`~/.claude/handover/bridge/consoles/`), and the console watches the file with
the event waiter started in its ACTION ZERO (`console-kit/console-wait.sh`,
which reads it through `inbox-follow.sh --once` and a read cursor beside the
file, so a line is never lost across a re-start).

- **Who:** only the `allowFrom` operator, in an allowed chat, with a typed (not
  forwarded, not captioned) message. Anyone else's `/console …` is ordinary
  chat, exactly as before. `access.json` remains the only sender gate.
- **Ack:** `→ console <name>` means the line was queued — not that the console
  has read it. A no-live-console or ambiguous-console response queues nothing;
  delivery never creates a console inbox.
- **Reply:** the console answers through the same outbox as every other bridge
  reply (`bun scripts/telegram/console-route.ts reply <chat_id> <text>`); the
  running poller sends it. On Linux the CLI resolves the calling session name
  automatically when its inbox exists. For an explicit identity (including
  other platforms), use `reply --console <session-name> <chat_id> <text>`.
- **Authority:** the line carries your authority — a ruling, a halt or new
  work, as if typed in the console's terminal. It never changes the console's
  permissions or settings and never bypasses `merge-on-green.sh`'s own GO
  verification.
- **A wrapped console leaves its file behind**, so a line to one is acked but
  read by no one; check the console is live before relying on it.

## Slash console requests and emergency lockdown

These **slash forms only** carry the same authority as free `/console` text:

| Command | Queued console request |
|---|---|
| `/fleet` | fleet status |
| `/legs` | list legs |
| `/go <leg>` | ask whether GO is pending; never write GO or a grant |
| `/push <leg>` | request a push through the console's normal gates |
| `/halt [<leg>]` | request a halt of that leg, or the wave |

Leg labels are 1–64 ASCII letters, digits, underscores, dots or hyphens; `..`,
path separators and controls refuse the command shape. Bare `fleet`, `legs`,
`go`, `push` and `halt` remain chat; existing `status` still reports bridge
session status. Messages must pass the existing operator/allowed-chat gate,
be typed, unforwarded and without a `model:` tag.

A trusted reply receipt selects its original console **only while fresh**;
otherwise exactly one fresh console must be live. Zero or multiple live
consoles queue nothing. Reply to the chosen console's announcement or answer
to disambiguate. Unlike explicitly named `/console`, these requests refuse
stale targets. Their acknowledgement says **queued**, never completed, and
replies thread to the inbound message while retaining the same console receipt
owner. No handler launches a session, runs git, or grants approval.

An inbound command older than `TELEGRAM_VERB_MAX_AGE_S` (default **300 seconds**)
is refused with **“stale, resend”**, preventing outage replay. Missing/invalid
or future message dates also refuse; invalid/nonpositive configuration uses
300 seconds. This window applies to the five console verbs, not existing
free `/console` text. `/lockdown` remains narrowing-only even when replayed.

`/lockdown` sets `<bridge root>/lockdown` and confirms it. While present, the
bridge drops console routes (including trusted reply threads), console verbs,
and all typed auto-actions, including `/mergepub`, `/cr-grant-delta`, `/arm`
and the retired typed launch. It does not cancel already-running actions or
disable ordinary chat. The flag survives bridge restart. **Reset at the station
only**, after securing the Telegram account:

```bash
rm -- "${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/lockdown"
```

No remote unlock exists. End the compromised Telegram sessions from a second
trusted device. `/launch-bypass-leg …` is retired and always refuses, even if
explicitly enabled: **start hook legs at the station**. Telegram never ratifies
a hook-bypass launch.

**Threat ceiling:** a same-uid process can forge an inbox line or remove the
station-local flag. The flag is emergency narrowing, not a protected privilege
boundary. A queued command never carries more authority than free-text
`/console` and never bypasses PR, CR or GO gates. If the Telegram account is
taken over, `/console` free text, `/mergepub` and `/cr-grant-delta` remain
one-factor operator authority until lockdown; this slice adds no approval
capability or second factor.

After deploying an updated bridge, restart it **at the station** on Linux:
`bash scripts/telegram/restart-bridge.sh` (do not start a second poller).

## The one-poller-per-token trap

Telegram allows exactly **one** `getUpdates` consumer per bot token. Do not
launch a `claude --channels` (or `TELEGRAM_OWN_POLLER=1`) session by hand
while the bun bridge is running — it becomes a second consumer and Telegram
returns `409 Conflict`, breaking delivery for both. If you need a manual
`--channels` session, stop the bridge first (`bun supervisor.ts --kill`).

## Troubleshooting

- **`409 Conflict` in the poller log** — another poller holds the token
  (usually a stray hand-launched `--channels` session, or two supervisors).
  Kill the extra poller; on Windows, `restart-bridge.ps1` clears this for you.
- **No reply to a DM** — check that your Telegram user id is in
  `access.json`'s `allowFrom`, and that the bridge process is actually up.
