# CLIProxyAPI codex lane (`cc-codex`) — per-host bring-up checksheet

The `cc-codex` lane runs Claude Code against the codex subscription through a
local **CLIProxyAPI** Anthropic-compatible proxy (`scripts/claude-codex`,
[tooling-catalog](../tooling-catalog.md)). This sheet stands the proxy up on a
host.

## Where it runs (read this first)

The proxy is a **HOST** process on `127.0.0.1:8317`. **One instance per host**
serves *all three* clients on that machine:

- the host bash launcher (`scripts/claude-codex`),
- the host PowerShell launcher (`scripts/claude-codex.ps1`),
- that host's **WSL** (`cc-codex`) — which reaches it over `127.0.0.1` via
  mirrored networking.

So: install/run it **on each host, never inside WSL, never per-launcher**. On an
N-host fleet you run N proxies, not N×(hosts+WSLs).

> `cc-codex` needs the proxy. `cc-glm` does **not** — it goes direct to z.ai and
> only needs `ZAI_API_KEY` in `.env`.

## The script

`scripts/setup/cli-proxy-lane.ps1` (PowerShell, run on the host). Run it with no
switch for a status report that names the next command:

```powershell
.\scripts\setup\cli-proxy-lane.ps1
```

| Switch | Does |
|---|---|
| `-Install` | download the pinned CLIProxyAPI binary + write `~/.cli-proxy-api/config.yaml` (loopback-bound) if missing |
| `-Login` | one-time codex OAuth via **device-code** flow (no local browser needed — works over SSH) |
| `-Start` | start the proxy in the **foreground** (Ctrl-C to stop) — for debugging |
| `-Register` | register a windowless **logon task**, **and start it now** — so the proxy is up immediately and restarts at each sign-in |
| `-Verify` | curl the running proxy |

## What to run — per host

Both hosts already have the binary + `config.yaml` staged.

**win1** (codex OAuth already present):

```powershell
.\scripts\setup\cli-proxy-lane.ps1 -Register   # starts it now + persists across sign-in
```

**win2** (needs the one-time login):

```powershell
.\scripts\setup\cli-proxy-lane.ps1 -Login
.\scripts\setup\cli-proxy-lane.ps1 -Register
```

A **fresh host** starts one step earlier with `-Install`. Use `-Start` instead
of `-Register` only to run the proxy in the foreground for debugging.

## Verify the lane end-to-end

```shell
# host:
bash scripts/claude-codex -p "reply OK"
# WSL (reaches the host proxy via mirrored 127.0.0.1):
cc-codex -p "reply OK"
```

## Notes

- `config.yaml` pins `host: "127.0.0.1"` on purpose — the CLIProxyAPI default
  (empty host) binds **all interfaces**, LAN-exposing the OAuth-wrapped
  subscription endpoint. Always start via the script / `-config`.
- `CLIPROXY_API_KEY` in `.env` must match the `api-keys` entry
  (`himmel-local-claudex`).
- This re-exposes a subscription via OAuth; the ToS posture is operator-accepted
  (HIMMEL-979).
- POSIX hosts (mac/Linux) need the equivalent binary + a `.sh` twin — not yet
  shipped (Windows-host fleet only today).
