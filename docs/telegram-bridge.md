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

`/console <session-name> <text>` delivers `<text>` to a console that is already
running — it does not start a session. The bridge appends one line to that
console's inbox file, `<bridge root>/consoles/<session-name>.md` (default
`~/.claude/handover/bridge/consoles/`), and the console watches the file with
a `Monitor` armed in its ACTION ZERO (`console-kit/inbox-follow.sh`, which keeps
a read cursor beside the file so a line is never lost across a re-arm). Use the console's exact session name
(`ListAgents`, or the name it printed at launch).

- **Who:** only the `allowFrom` operator, in an allowed chat, with a typed (not
  forwarded, not captioned) message. Anyone else's `/console …` is ordinary
  chat, exactly as before. `access.json` remains the only sender gate.
- **Ack:** `→ console <name>` means the line was queued — not that the console
  has read it. `⚠️ no console "<name>" is listening` means that console never
  armed its inbox and nothing was sent; the bridge never creates the file, so
  a typo cannot open a mailbox nobody reads.
- **Reply:** the console answers through the same outbox as every other bridge
  reply (`bun scripts/telegram/console-route.ts reply <chat_id> <text>`); the
  running poller sends it.
- **Authority:** the line carries your authority — a ruling, a halt or new
  work, as if typed in the console's terminal. It never changes the console's
  permissions or settings and never bypasses `merge-on-green.sh`'s own GO
  verification.
- **A wrapped console leaves its file behind**, so a line to one is acked but
  read by no one; check the console is live before relying on it.

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
