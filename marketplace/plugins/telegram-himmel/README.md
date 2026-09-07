# telegram-himmel

`[yotamleo fork]` of `telegram@claude-plugins-official` **v0.0.7**.

## Why this fork

Upstream starts the Telegram `getUpdates` poller in an unconditional
top-level IIFE (`server.ts`) and stale-kills whatever PID holds
`~/.claude/channels/telegram/bot.pid`. Telegram allows exactly one poller per
bot token, so **every** new claude session (even an unrelated one) steals the
slot from the running bridge and goes deaf to inbound — locking the operator
out of remote Telegram.

## The change

The first of three live deltas, all described below: two behavioural (carried as
**four** `[telegram-himmel fork]` hunks in `server.ts` — grep that marker, it is
the source of truth) and one packaging in `package.json`, which carries no
marker. The stale-kill, the `bot.pid` write, and
the poller IIFE are gated behind `TELEGRAM_OWN_POLLER=1`. Only the designated
owner session polls; all other sessions still load the MCP and keep every
outbound tool (`reply`, `react`, `download_attachment` via `bot.api`), but
never compete for the poll slot.

Launch the owner:

```bash
TELEGRAM_OWN_POLLER=1 claude "<prompt>" --channels plugin:telegram-himmel@himmel
```

(Prompt BEFORE `--channels` — it is variadic.)

Disable upstream `telegram@claude-plugins-official` while this fork is
enabled, or upstream's ungated poller re-introduces the steal.

A second behavioural delta, added at the 0.0.7 re-sync (HIMMEL-1858): upstream
gates the stale-poller `SIGTERM` on `execFileSync('ps', …, '-o', 'args=')` inside
one broad try/catch. Git Bash's MSYS `ps` does not support `-o args=` and cannot
see native PIDs, so on Windows it *throws*, the catch swallows it, the kill is
skipped — and `bot.pid` is overwritten regardless, leaving two live getUpdates
consumers. The fork defaults the kill to ON and gives the `ps` probe its own
try/catch, so only a `ps` that actually ran may suppress it. Where `ps` works,
upstream's PID-recycling protection is unchanged.

One packaging delta: `package.json`'s `start` skips `bun install` when
`node_modules` already exists (upstream reinstalls every launch). Upstream's
`1>&2` redirect is kept — `bun install` on stdout would corrupt the MCP stream.

The fork also carried a photo-handling delta until the 0.0.7 re-sync: photos
recorded `file_id` for lazy download (HIMMEL-266, filed because an eager
download inside the grammy handler stalled the poll loop for N×60s on a batch
of N photos). Upstream 0.0.7 downloads eagerly but only *after* the gate
approves, and surfaces `meta.image_path`; that behaviour was adopted by
operator decision (HIMMEL-1858) and the himmel delta dropped. A photo batch
from an allowlisted sender can still serialize downloads in the poll loop.

## Opt-in MCP launch (HIMMEL-591)

Claude Code eagerly spawns every enabled plugin's MCP server at session start
(no native lazy spawn), so this bun server used to load in **every** session —
even the majority that never send a Telegram message. `.mcp.json` now routes
through `mcp-gate.sh`, which is **default-OFF**: a session that opts out holds
no bun process for this server.

A session opts **in** when either env var is set in the launching shell:
- `TELEGRAM_OWN_POLLER=1` — the owner launch above already sets this, so it is
  unchanged (owner sessions still get the server + the poller).
- `HIMMEL_MCP_TELEGRAM=1` — for a **send-only** session that wants the outbound
  tools (`reply`, `react`, …) without owning the poll slot.

Set the opt-in var **per launch**, not exported globally — a shell that exports
it process-wide re-enables the server in every child session and undoes the
memory saving.

This gates only the plugin's per-session MCP server. The always-on standalone
bun bridge (`scripts/telegram/`) and its per-chat vault-cwd routing are a
separate process and are unaffected. A gated-off server shows as not-connected
in `/mcp` — expected.

## Upstream-watch protocol

Pinned to upstream **v0.0.7**. On an upstream bump:
1. Diff new upstream `server.ts` against this vendored copy.
2. Re-apply **all four** `[telegram-himmel fork]` edits — search that marker, do
   not count from memory: the three `TELEGRAM_OWN_POLLER` hunks (the const, the
   owner-only stale-kill + `bot.pid` write, the poller IIFE) **and** the
   `looksLikeServer` ps-fallback. Re-check the count against the marker after
   every bump; the fourth was added at 0.0.7 and a re-sync that reapplies only
   the "three" silently reintroduces the Windows two-poller bug.
3. Bump the pinned version here + re-run BOTH `tests/test-telegram-poller-gate.sh`
   (behavioural, includes the live reap case) and `bash scripts/plugin-test.sh
   telegram-himmel` (code-shape guards for all four edits).

The `check-telegram-fork-drift` pre-commit hook (scripts/hooks/) flags when
the installed upstream cache no longer matches `UPSTREAM_PIN`.

Ideal end-state: land the gate upstream as an opt-in env so this fork can
retire.

## License

Apache-2.0, carried forward from upstream `telegram@claude-plugins-official`.
See `LICENSE` for the full text.
