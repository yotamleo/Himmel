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
goes deaf. Run exactly one. `restart-bridge.ps1` enforces this.

---

## Human — quick commands (Windows / PowerShell)

```powershell
# Start (or restart) the bridge — kills any stale bridge procs, starts ONE
# supervisor, settles 12s, verifies no 409. This is the canonical launcher.
pwsh -File scripts/telegram/restart-bridge.ps1

# Status only — report procs + 409 count, touch nothing.
pwsh -File scripts/telegram/restart-bridge.ps1 -StatusOnly

# Point at a non-default repo root.
pwsh -File scripts/telegram/restart-bridge.ps1 -Repo C:/path/to/himmel
```

Exit codes: `0` = up + clean · `1` = usage/env error · `2` = started but still
seeing 409 (investigate).

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
which senders are accepted in that group; the fork's `requireMention` is
**ignored** by the bun bridge (it doesn't parse message entities) — a bare
key admits every member. Text-less updates (service messages, stickers,
photos) are dropped at ingest.

Plain group/channel messages get their own session (`group_<chat_id>`), so
replies route back to that chat — the operator DM is untouched. Ticket verbs
(`work on <KEY>` / `<KEY>: …`) route to the shared per-ticket session, whose
replies go to whichever chat FIRST created that session. Non-allowed groups
fail closed.

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
- `TELEGRAM_TRIAGE_MODEL` selects the Hermes model. Default: `deepseek-chat`.
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
| `install-logon-task.ps1` | register/remove/report the `HimmelTelegramBridge` reboot-persistence task |
| `run-prompt.md` | the prompt contract handed to each bounded run |

Bot: `@<your-bot-username>`. Token: `~/.claude/channels/telegram/.env`
(`TELEGRAM_BOT_TOKEN=`). Logs + pidfile: `~/.claude/channels/telegram/`.
Bus (sessions, inbound.jsonl, offset): `~/.claude/handover/bridge/`
(`BRIDGE_ROOT` to override).
