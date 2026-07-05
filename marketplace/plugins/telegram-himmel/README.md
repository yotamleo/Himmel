# telegram-himmel

`[yotamleo fork]` of `telegram@claude-plugins-official` **v0.0.6**.

## Why this fork

Upstream starts the Telegram `getUpdates` poller in an unconditional
top-level IIFE (`server.ts`) and stale-kills whatever PID holds
`~/.claude/channels/telegram/bot.pid`. Telegram allows exactly one poller per
bot token, so **every** new claude session (even an unrelated one) steals the
slot from the running bridge and goes deaf to inbound — locking the operator
out of remote Telegram.

## The change

One behavioural delta vs upstream: the stale-kill, the `bot.pid` write, and
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

Pinned to upstream **v0.0.6**. On an upstream bump:
1. Diff new upstream `server.ts` against this vendored copy.
2. Re-apply the three `TELEGRAM_OWN_POLLER` edits (search `[telegram-himmel fork]`).
3. Bump the pinned version here + re-run `tests/test-telegram-poller-gate.sh`.

The `check-telegram-fork-drift` pre-commit hook (scripts/hooks/) flags when
the installed upstream cache no longer matches `UPSTREAM_PIN`.

Ideal end-state: land the gate upstream as an opt-in env so this fork can
retire.

## License

Apache-2.0, carried forward from upstream `telegram@claude-plugins-official`.
See `LICENSE` for the full text.
