# Telegram remote bridge — operator runbook

Run Claude Code as a remote-controllable agent over Telegram: DM the bot from
your phone, the owner session receives it and replies. Built on the
**`telegram-himmel`** fork (a poller-gated fork of
`telegram@claude-plugins-official`).

## Why the fork (1-line)

Telegram allows one `getUpdates` poller per bot token. Upstream polls in
*every* claude session and steals the slot, so any ad-hoc window kills your
bridge. `telegram-himmel` gates the poller behind `TELEGRAM_OWN_POLLER=1` —
only the designated owner polls; everything else leaves the slot alone. Full
rationale: [`marketplace/plugins/telegram-himmel/README.md`](../marketplace/plugins/telegram-himmel/README.md).

## One-time setup (already done on this machine)

```bash
claude plugin marketplace update himmel
claude plugin install telegram-himmel@himmel
```

In `~/.claude/settings.json` → `enabledPlugins`:

```json
"telegram-himmel@himmel": true,
"telegram@claude-plugins-official": false
```

Upstream **must stay disabled** — its ungated poller re-creates the steal.
Token + allowlist live in `~/.claude/channels/telegram/` and carry over from
upstream (no re-pairing).

## Launch the owner (the bridge)

Two things are required and easy to get wrong:

1. **`TELEGRAM_OWN_POLLER=1`** — makes this session the poller.
2. **`--dangerously-load-development-channels plugin:telegram-himmel@himmel`** —
   the fork is a *local* channel, not on Claude's built-in approved-channels
   allowlist, so a plain `--channels` drops inbound. This flag opts in (it's
   your own fork). The flag takes the `plugin:` spec **directly** — do NOT also
   pass `--channels`. On launch it prompts once; choose **"I am using this for
   local development"**.

**PowerShell:**
```powershell
$env:TELEGRAM_OWN_POLLER=1; claude "telegram bridge owner — standby" --dangerously-load-development-channels plugin:telegram-himmel@himmel
```

**Git Bash / Linux / macOS:**
```bash
TELEGRAM_OWN_POLLER=1 claude "telegram bridge owner — standby" --dangerously-load-development-channels plugin:telegram-himmel@himmel
```

Confirm: the session prints `Listening for channel messages from:
plugin:telegram-himmel@himmel`. DM your bot (`@<your-bot-username>`) from the allowlisted
account → the message appears in the session as a `<channel …>` block; reply
flows back to Telegram.

## Non-owner sessions

Just run `claude` normally — **no env var, no flag**. The plugin still loads,
so outbound tools (`reply`, `react`) work, but it won't poll and won't steal
the owner's slot. Open as many as you like; the bridge stays up.

## Alias

Drop one of these in your shell profile so you don't retype the launch.

**PowerShell** (`$PROFILE`):
```powershell
function tgowner {
    $env:TELEGRAM_OWN_POLLER = "1"
    claude "telegram bridge owner — standby" --dangerously-load-development-channels plugin:telegram-himmel@himmel
}
```
Then: `tgowner`. (Sets `$env:TELEGRAM_OWN_POLLER` for that shell — open
non-owner windows in a different shell, or clear with
`$env:TELEGRAM_OWN_POLLER=$null`.)

**Bash / Zsh** (`~/.bashrc` / `~/.zshrc`):
```bash
alias tgowner='TELEGRAM_OWN_POLLER=1 claude "telegram bridge owner — standby" --dangerously-load-development-channels plugin:telegram-himmel@himmel'
```
The inline `VAR=1 cmd` form scopes the env var to that one launch — non-owner
windows are unaffected.

## Verify (quick)

| Check | How | Expect |
|---|---|---|
| Owner polls | launch owner, DM bot | `<channel>` block in session |
| Non-owner doesn't steal | owner up, open plain `claude`, DM bot | owner still receives; `cat ~/.claude/channels/telegram/bot.pid` unchanged |
| Outbound from non-owner | ask plain session to send a Telegram msg | delivered |

## Troubleshooting

- **DM sent, no reply, session shows nothing.** Check the fork's MCP log:
  `~/AppData/Local/claude-cli-nodejs/Cache/<cwd-slug>/mcp-logs-plugin-telegram-himmel-telegram/`.
  - `Channel notifications skipped: … not on the approved channels allowlist` →
    you launched without `--dangerously-load-development-channels`. Relaunch
    with it.
  - `poller disabled (not owner; set TELEGRAM_OWN_POLLER=1)` → you forgot the
    env var. Relaunch with it.
- **`--dangerously-load-development-channels entries must be tagged`** → you
  passed a stray `--channels`. The dev-channels flag takes the `plugin:` spec
  directly; remove the separate `--channels`.
- **`'TELEGRAM_OWN_POLLER=1' is not recognized`** → that's bash syntax in
  PowerShell. Use `$env:TELEGRAM_OWN_POLLER=1; claude …`.
- **409 Conflict in the log** → another poller holds the token (a stray owner
  or upstream still enabled). Ensure upstream is disabled and only one owner
  runs.

## Keeping the fork current

Pinned to upstream v0.0.6 (`marketplace/plugins/telegram-himmel/UPSTREAM_PIN`).
The `check-telegram-fork-drift` pre-commit hook flags when the installed
upstream cache drifts from the pin — re-sync per the fork README.

## Roadmap

Automating the owner lifecycle (keep it alive across context/usage-cap cycles
+ arm work sessions from a Telegram message) is **HIMMEL-207** (bun supervisor
+ `arm-resume` integration), unified with HIMMEL-208 (fast-resume from armed
session).
