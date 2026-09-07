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
| `-Register` | register a windowless **logon task** (hidden `wscript` launcher — see below), **and start it now** — so the proxy is up immediately and restarts at each sign-in |
| `-Verify` | curl the running proxy |

## What to run — per host

This assumes `-Install` already ran (binary + `config.yaml` staged).

**A host that already has codex OAuth present:**

```powershell
.\scripts\setup\cli-proxy-lane.ps1 -Register   # starts it now + persists across sign-in
```

**A host that needs the one-time login:**

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

## Re-login when the codex token is invalidated

When the gateway's codex token goes stale, the lane fails with the proxy
error log showing `authentication_error: Your authentication token has been
invalidated. Please try signing in again`. This is a self-service re-login,
not a blocking outage — re-auth with the DEVICE flow (`-codex-login` plain
OAuth needs a localhost callback; the device flow does not):

```shell
cd ~/.cli-proxy-api && ./cli-proxy-api.exe -config ./config.yaml -codex-device-login
```

After ~2–4 seconds it prints
`Codex device URL: https://auth.openai.com/codex/device` plus a 9-character
device code, then polls until authorized — leave it running in the
FOREGROUND of a dedicated terminal until authorization completes, and do
NOT kill it early (the URL + code only print after that short delay).
Authorize from a logged-in browser or a second terminal. Treat the device
URL + code as sensitive authorization material: surface them to the
operator directly and nowhere else — never into shared logs, chat
channels, screenshots, or CI output (anyone holding the active code can
authorize the login). On authorize the process writes
`~/.cli-proxy-api/codex-<email>.json` ("Codex authentication
successful") and exits 0; re-verify the lane end-to-end (section above).

Detection caveat: the gateway's `/v1/models` endpoint is registry-backed and
keeps returning 200 during an OAuth gap — probe a real completion
(`/v1/messages`) to detect an auth gap, never `/v1/models`.

## The logon-task launcher, and the Defender detection it trips (HIMMEL-1822)

`-Register` registers the at-logon task with the action
`wscript.exe //B //Nologo "<home>\.cli-proxy-api\start-hidden.vbs"`. The proxy
exe is a console-subsystem (`WINDOWS_CUI`) binary, so the earlier registration
form — `powershell -NoProfile -WindowStyle Hidden -Command "& exe"` — created a
console that was only hidden *after* a visible flash at every sign-in.
`wscript.exe` is a GUI-subsystem process (it allocates no console) and the
generated `start-hidden.vbs` starts the exe with `SW_HIDE` from creation. Both
`-Install` and `-Register` (re)write `start-hidden.vbs` next to the exe with
paths derived from the resolved install root; re-running either is idempotent,
and re-running `-Register` upgrades a machine still carrying the old
PowerShell-wrapper action to the launcher form.

**Windows Defender removes this registration — expected, and the fix is an
exclusion, not stealth.** The registration command line (`schtasks /create`
with an at-logon trigger, limited run level, force-overwrite, and a WSH script
as the action) trips the `Trojan:Win32/Commando.A!ml` ML heuristic — "a
scheduled task launching a WSH script at logon" is a textbook persistence
pattern, so the heuristic firing on it is expected, not a sign of compromise.
Three removals observed on this fleet (2026-08-14, 2026-08-16 ×2). The
sanctioned fix is an operator-added exclusion — deliberately NOT an obfuscated
registration command. Scope it to `start-hidden.vbs` specifically, not the
whole install directory: that script is what the heuristic keys on, and a
narrower exclusion keeps `config.yaml` and the codex OAuth token under
real-time scanning:

```powershell
# elevated, once per host:
Add-MpPreference -ExclusionPath "$env:USERPROFILE\.cli-proxy-api\start-hidden.vbs"
# then re-register:
.\scripts\setup\cli-proxy-lane.ps1 -Register
```

**Residual risk, accepted (CR round):** `start-hidden.vbs` is a user-writable
file that runs automatically at every sign-in, so excluding it — narrowly
scoped or not — creates an antivirus blind spot for whatever content sits at
that exact path: a process already running as the signed-in user (the
realistic compromise scenario on a single-user workstation) can overwrite it
and gain both the blind spot and logon persistence. This is inherent to
persisting *any* auto-run script through a Defender exclusion — narrowing the
exclusion's scope (above) shrinks it to this one file, but does not remove it,
and there is no ACL-based mitigation that helps here (restricting writes to
the operator account does nothing against code already running as that
operator). It is the same tradeoff `-Register` already accepts by design
(*"expected, and the fix is an exclusion, not stealth"*, above) — named here
explicitly rather than left implicit.

Until the exclusion is in place the proxy will **not** auto-start at logon
(start it manually with `-Start`; `-Register` throws before it gets that far
while the task keeps vanishing). `-Register` detects a failed `/create` or a
task that vanished right after creation and prints this guidance itself.

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
