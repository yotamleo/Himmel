# Telegram bridge (HIMMEL-207/208; delivery: HIMMEL-226)

An always-on remote Telegram bridge for Claude Code. An immortal bun
poller owns the single Telegram poll slot (`getUpdates`) and delivers each
inbound message by spawning a **bounded one-turn cold `claude` run** per logical
session — interactive `claude "<prompt>"` with stdin closed (EOF), so the child
does one turn, replies, and exits (Max quota, no `-p`). A file bus carries
per-session inbox / outbox / context so work survives across runs, caps, and
crashes.

> [!important] Armed/overnight relaunches do NOT use `--channels` (HIMMEL-225).
> Telegram reachability comes from the always-on bun bridge, **not** from a
> `claude` session holding `--channels`. A `--channels` Telegram relaunch
> alongside the live bridge is a 2nd `getUpdates` consumer (→ 409 Conflict)
> AND its `--dangerously-load-development-channels` prompt hangs an unattended
> launch ([§ WS-C](#ws-c--why-no---channels-dev-channels-spike-result)). So the
> anti-lockout default is a **PLAIN relaunch** — keep the bun bridge up, drop
> `--channels`. `scripts/handover/arm-resume.sh` enforces this: it **refuses**
> `--channels` (rc=5) while the bridge is live (`ARM_CHANNELS_OK=1` overrides,
> after `bun supervisor.ts --kill`).

## Cold-spawn-per-message delivery (HIMMEL-226)

Each inbound message is handled by a **bounded one-turn cold `claude` run**, not
a long-lived warm child. `makeRunFn` (in `poller.ts`) `peekPending`s the durable
inbox slice, spawns `runSession(buildPrompt(...))` — interactive `claude` with
stdin closed → EOF → one turn → reply appended to `outbox.jsonl` → exit — and
commits the consumed cursor **only on a clean (non-capped) run**; `buildPrompt`
passes `context.md` so a cold reply still carries prior-turn continuity. After a
clean run it drains by re-running until `peekPending` returns 0.

> [!note] Why cold, not warm (HIMMEL-226 revert of HIMMEL-222).
> HIMMEL-222 tried a **persistent warm child** with a piped stdin, writing one
> line per turn. That never drove a turn: interactive `claude "<prompt>"`
> processes + replies only at **EOF**, never on a newline written to a
> still-open stdin pipe — so the warm child consumed the inbox line, stayed
> alive, and replied to nobody (the "bot is deaf" bug). Cold-spawn closes stdin,
> which is what makes the one turn fire. `inbox.jsonl` stays the durable queue;
> a cap/rate-limit on a run's output marks the session `capped` + `retry_at`
> (now + `TELEGRAM_RETRY_MS`, default 15m) and leaves the message uncommitted so
> it redelivers at retry.

### Reply flush timer (T4)
A cold run is a separate process that appends its reply to `outbox.jsonl` as it
works, so the poller flushes outboxes on its **own ~1s timer**
(`TELEGRAM_FLUSH_MS`) running **concurrently** with the 30s `getUpdates`
long-poll, behind a re-entrancy guard (`guarded`) that drops a tick while a
prior flush is still in flight. A reply reaches the operator within ~1s instead
of up to 30s. The flush path touches only the outbox files; the run path touches
only inbox/meta/pending — disjoint, so the concurrent timer adds no shared-file
race.

### Inter-session IPC (T6 / HIMMEL-219 messaging)
`bun bus.ts send <target> <text>` calls `sendToSession`, which `ensureSession`s
the target and appends the message to its durable `inbox.jsonl`. The poller's
per-tick `deliverAllPending` scan runs pending lines for **every** session
(spawning a bounded run), skipping a `capped` session until `retry_at`
passes. **Boundary (followup):** a target that has *never* been created via
Telegram has no `meta.json`, so `deliverAllPending` defers it — an IPC message
to a brand-new target queues durably but is not delivered until that session is
first created (and reply routing needs a `chat_id`, which only a
Telegram-created session has). A→B between two already-live sessions works.

### Atomic cursor writes
Every committed cursor (inbound, per-session outbox, inbox `.consumed`, and the
`inbox.pending.jsonl` scratch) is written via `atomicWrite` (tmp+rename) so a
crash mid-write can't leave a torn byte-offset. (`meta.json` / `offset` /
`context.md` were already atomic.)

## Hardening (HIMMEL-221)

Non-blocking minor items from the HIMMEL-207 PR #222 heavy CR:

- **Malformed `getUpdates` tolerance.** `getUpdates` returns `j.result ?? []`,
  so an `ok:true` response that omits `result` yields an empty batch instead of
  throwing into the poll loop's catch.
- **Append-log truncation (`truncateFullyConsumed`).** `flushOutboxes` and the
  run loop read each session's whole outbox/inbox into memory every tick;
  on a very long-lived session those logs would grow without bound. When a
  log's byte-cursor reaches EOF (every line sent/consumed) the file and its
  cursor are reset to 0. Truncation fires **only at the fully-consumed point**
  and re-reads the file length immediately before the reset, so it never drops
  unsent/unconsumed bytes. A residual sub-millisecond race remains for the
  outbox (a bounded run is a separate process and could append between the final
  length read and the rename) — bounded to one flush interval of output and
  consistent with the bridge's existing at-least-once / operator-resends model.
- **Capped session is not a stall.** A `capped` session with new inbound stays
  **queued** (uncommitted) until its `retry_at` passes — `deliverAllPending`
  skips it by design. A queued-but-not-delivering capped session is expected
  back-pressure, not a hang; it resumes automatically at retry.
- **I2 — at-least-once mid-batch dup window.** Inbound is durably appended
  *before* the Telegram offset advances (append-then-confirm), so a crash
  between the append and the offset write can re-append the same update on
  restart. `ingestUpdates` dedups by `update_id` (skips any `update_id <
  offset`), so the dup window is collapsed at ingest and never reaches a session.
- **`supervisor --kill` is a real lever.** The supervisor writes a
  `supervisor.pid` file (its own pid + the current poller child pid) under the
  bridge root. `bun supervisor.ts --kill` reads it and stops the supervisor
  first (so it can't respawn the poller) then the poller, and removes the file.
  (On Windows the scoped `restart-bridge.ps1` remains the preferred lever — it
  also clears 409-conflicting duplicate pollers left by older launches.)

## WS-C — why no `--channels` (dev-channels spike result)

Loading a local-marketplace channel (`plugin:telegram-himmel@himmel`)
requires `--dangerously-load-development-channels`, whose "I am using this
for local development" prompt **does NOT persist**. Verified empirically:
it re-prompts on every launch, and nothing is written to `~/.claude.json`,
settings, or any other file to record the acknowledgement. This is
confirmed by the claude-code guide — there is no settings key, env var, or
flag to suppress it, because forked plugins never reach Anthropic's
approved-channels allowlist. An unattended relaunch would therefore hang
forever waiting on that prompt.

The bridge avoids `--channels` entirely: a standalone bun poller receives
inbound via the Telegram Bot API, and the bridge sessions are plain
interactive runs (no dev-channel load, no prompt to hang on).

## Components

- **poller** (`scripts/telegram/poller.ts`) — the only daemon and driver.
  Owns the single `getUpdates` slot, gates inbound against `access.json`,
  writes durable inbound (append-then-confirm: append to `inbound.jsonl` +
  fsync, then advance the offset), routes each message with pure code, spawns
  bounded runs, and flushes outboxes back to Telegram.
- **supervisor** (`scripts/telegram/supervisor.ts`) — keeps the poller alive
  (restart-on-exit + backoff + a circuit-breaker on repeated immediate
  crashes). No claude session to manage.
- **bus** (`scripts/telegram/bus.ts`) — the file substrate under
  `~/.claude/handover/bridge/`: `inbound.jsonl`, `offset`, and
  `sessions/<S>/{inbox,outbox,context,meta}`. Single-writer-per-file
  (meta = poller only; outbox = run only; inbox = poller only;
  context = run only); readers use a sibling byte-cursor (`atomicWrite`) and
  parse only complete `\n`-terminated lines. Also `sendToSession` + the
  `bun bus.ts send` IPC CLI.
- **bounded run** (`scripts/telegram/run.ts`) — the delivery primitive:
  `runSession` spawns interactive `claude "<prompt>" </dev/null` (Max quota,
  stdin closed → one turn → reply → exit) + `detectCap`. `poller.ts`'s
  `makeRunFn` wires it per session (peek → run → commit-on-clean).

HIMMEL-208 fast-resume is an independent capability for recovering a closed
session's stop-point: `scripts/telegram/armed-session-track.ts` +
`/handover-resume-armed`.

## Ops runbook

**Start:**

```bash
cd scripts/telegram && bun supervisor.ts
```

The supervisor keeps `bun poller.ts` alive.

**Restart (Windows):** `pwsh -File scripts/telegram/restart-bridge.ps1` kills
ONLY the bridge's bun processes (matched on `supervisor.ts`/`poller.ts` command
line — never a blanket `/IM bun.exe`), starts exactly one supervisor detached,
and verifies it settled with no 409. `-StatusOnly` reports without touching
anything. **Stop (cross-platform):** `bun supervisor.ts --kill` (reads the
`supervisor.pid` file written under the bridge root).

**Required config:**

- `~/.claude/channels/telegram/.env` with `TELEGRAM_BOT_TOKEN=...`
- `~/.claude/channels/telegram/access.json` with `{"allowFrom":["<your-id>"]}`

**Inspect:** session state lives under
`~/.claude/handover/bridge/sessions/`.

**Single-owner rule:** exactly one `getUpdates` consumer per token. Do NOT
run a `claude --channels` / `TELEGRAM_OWN_POLLER=1` owner-fork session while
the poller is running — it would 409-conflict the poller (Telegram allows
only one long-poll consumer per token).

**Message verbs:**

- `work on <KEY>` — dispatch: ensure session `<KEY>`, run it.
- `<KEY>: <text>` — follow-up to that session.
- `status` / `sessions` / `stop <KEY>` — control.
- anything else → chat.

## WS-D — auto-mode

The poller is a bun process, not an LLM, so it spawns `claude` directly
rather than through a classifier-gated tool — there is no special
allow-rule to add for dispatch. The bounded runs it spawns operate under the
operator's standing auto / accept-edits policy, which is what gives them
unattended autonomy.
