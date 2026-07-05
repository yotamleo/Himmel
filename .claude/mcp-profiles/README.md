# MCP fleet lean profiles (HIMMEL-719)

Every Claude Code session spawns the **full** MCP fleet at startup — per-session,
not shared. Measured baseline: ~6 node procs/session (chrome-devtools + context7 +
playwright, ×2 each) that multiply across the operator's 8–11 concurrent sessions
(~69 node / 5.6 GB at peak). Lazy per-server spawn is **not supported** by Claude
Code today (7+ upstream requests, none shipped). The one **verified** lever:

> `claude --strict-mcp-config --mcp-config <file>` loads **only** the servers named
> in `<file>` — ignoring `~/.claude.json` and every enabled plugin's MCP server.

These profiles are minimal `--mcp-config` files, one per lane. A coding/armed
session launches with `minimal` (just tokensave) instead of the whole fleet;
browser/vault/research work launches with the matching profile. Zero capability
loss — the servers are still one flag away, per session.

## Generate (per machine)

```powershell
node scripts/mcp/build-mcp-profiles.mjs          # writes local.<name>.json
node scripts/mcp/build-mcp-profiles.mjs --list   # show profile → servers
```

The generator reads your live `~/.claude.json` for the real (absolute-path,
secret-bearing) server specs and writes `local.<name>.json` here. **Those are
gitignored** — they carry your `OBSIDIAN_API_KEY` and `C:\Users\…` paths, which
must never hit git. Only the generator + `profiles.json` manifest + this README
are committed.

## Launch a lean session

```powershell
claude --strict-mcp-config --mcp-config .claude/mcp-profiles/local.minimal.json
```

| Profile | Servers | Use for |
|---|---|---|
| `minimal` | tokensave | Default coding / armed / overnight sessions |
| `research` | tokensave, context7 (remote HTTP) | Library-docs / API work |
| `browser` | tokensave, playwright, chrome-devtools | Browser automation / web debug |
| `vault` | tokensave, obsidian-vault | luna / salus vault sessions |
| `secrets` | tokensave, onepassword | Sessions that need 1Password |

Edit `profiles.json` to add/rebalance a profile, then re-run the generator.

### "Auto-invocation" — lane → profile

Claude Code has no mid-session server bring-up (`claude mcp add` only persists for
the *next* session). So "auto-invocation" = the launcher picks the profile from the
task lane: overnight-shift / armed-resume for a browser ticket launches with
`browser`, a luna ticket with `vault`, everything else with `minimal`. Wiring the
lane→profile default into the arm/overnight launchers is the Phase-2 follow-up.

## Optional: lean the DEFAULT session too (operator-review-gated)

Profiles make *opt-in* lean launches. To also shrink the fleet a bare `claude`
(no flags) spawns, trim the always-on config. This changes **every** future
session, so it is left for you to review + apply — not done automatically:

```powershell
# 1. Drop rarely-needed always-on stdio servers from ~/.claude.json mcpServers.
#    Re-add recipe is just the reverse — keep this block to restore:
#      headroom     -> until HIMMEL-622 adopts it
#      onepassword  -> now reachable via the `secrets` profile on demand
# 2. context7: disable the npx plugin, rely on the remote endpoint (research profile):
#      claude plugin disable context7
# 3. gh-CLI-first: github MCP is redundant with the gh CLI (block-backend-tier enforces):
#      claude plugin disable github
# 4. Browser via the `browser` profile on demand:
#      claude plugin disable chrome-devtools-mcp playwright
#    NOTE: disabling chrome-devtools-mcp also disables its skills until a himmel fork.
```

Each step is reversible (`claude plugin enable <name>` / restore the `~/.claude.json`
block). Verify after: open a fresh session, confirm the expected tools still resolve
(directly or via a profile launch) — nothing lost its ability to run, just its
*automatic* per-session spawn.

## Tier model (fleet-map lives in `docs/tooling-catalog.md`)

T0 always-on (tokensave) · T1 shared HTTP singleton (context7 remote, atlassian,
huggingface, vercel — 0 local procs) · T2 profile-scoped (browser, vault, secrets)
· T3 env-gated opt-in (telegram-himmel, luna-correlate — HIMMEL-591, done) · TX
CLI-first (jira over atlassian, gh over github, firecrawl).
