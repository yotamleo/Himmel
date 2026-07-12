# Windows clean-machine runbook — full himmel dev + lane fleet, remote-driven (HIMMEL-852)

End-to-end walkthrough for taking a **factory-clean Windows 11 machine** to a
full himmel dev machine — base toolchain, himmel + luna, ported credentials,
the delegation-lane fleet (hermes, codex, copilot, antigravity, ollama, GLM),
and always-on hardening (no sleep, auto-logon) — **driven entirely over SSH
from an existing himmel machine**. First executed 2026-07-10 against a clean
ASUS laptop (`win2`); every gotcha below was hit for real on that run.

Relationship to [`new-machine.md`](new-machine.md): that doc is the canonical
per-tool reference (what each tool is for, .env variable walkthrough, hook
scopes). This one is the **ordered Windows path** through it, plus the
remote-drive pattern and the lane fleet, which `new-machine.md` doesn't cover.

Conventions: the machine being set up is the **target**; the machine you drive
from is the **source**. Commands run on the source unless marked "on target".

---

## Phase 0 — remote access (SSH)

Prereq on target (one-time, physical/RDP): Settings → Apps → Optional features
→ add **OpenSSH Server**, start it, and note the machine's LAN IP and username.

1. **Generate a dedicated keypair on the source** and add the pubkey on the
   target. ⚠️ **Copy the pubkey via a file transfer, not by re-typing or
   chat-pasting** — on the first win2 run a *single base64 character* got
   corrupted in transit and auth failed. Diagnose exactly this with
   fingerprints:

   ```bash
   ssh-keygen -lf ~/.ssh/<key>.pub          # on source
   # vs the line that actually landed on the target — mismatch = corrupted key
   ```

2. **Admin users read a different authorized_keys.** If the target user is in
   Administrators (default for the first account), Windows sshd ignores
   `~/.ssh/authorized_keys` and only reads
   `C:\ProgramData\ssh\administrators_authorized_keys` — with strict ACLs
   (on target, elevated):

   ```powershell
   $key = Get-Content "$env:USERPROFILE\.ssh\authorized_keys"
   Set-Content C:\ProgramData\ssh\administrators_authorized_keys $key
   icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
   ```

3. **Source-side `~/.ssh/config`:**

   ```
   Host win2
       HostName <target-ip>
       User <target-user>
       Port 22
       IdentityFile ~/.ssh/<key>
   ```

4. **The default remote shell is cmd.exe** — `;`-chaining and everything
   POSIX-ish silently degrades. Invoke PowerShell explicitly on every call:

   ```bash
   ssh win2 "powershell -NoProfile -Command \"...\""
   ```

5. **Make sshd survive reboots** (on target): `Set-Service sshd -StartupType Automatic`.

6. SSH sessions for admin users carry the **full elevated token** (High
   integrity) — no UAC dance; winget machine-scope installs just work.

## Phase 1 — base toolchain (winget)

A clean machine has only `winget`, `claude` (if pre-installed/logged-in), and
the **Microsoft Store python stub** — which is not Python. Install:

```powershell
foreach ($id in 'Git.Git','OpenJS.NodeJS.LTS','jqlang.jq','GitHub.cli',
                'Microsoft.PowerShell','astral-sh.uv','Python.Python.3.12') {
  winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements --disable-interactivity
}
irm bun.sh/install.ps1 | iex
uv tool install pre-commit
```

Gotchas hit on the first run:

- **Store python stub**: `python` resolving to `...WindowsApps\python.exe`
  means NO Python. Install `Python.Python.3.12` explicitly; verify
  `python --version` prints a real version.
- **Fresh-session rule**: PATH edits from installers are invisible to the
  session that ran them. Each new `ssh win2 ...` call is a fresh session —
  structure multi-step installs as separate ssh calls, not one mega-session.
- **`winget upgrade --all` can break winget itself mid-process**: on the win2
  run, a full upgrade pass invalidated the `winget.exe` WindowsApps alias for
  the *running* process (`Access is denied` on the next invocation). A fresh
  session was fine. Don't chain `winget upgrade --all` and more winget calls
  in one process.

## Phase 2 — identity + credential porting

```bash
# gh: pipe the oauth token source→target (never lands on disk in transit)
gh auth token | ssh win2 "gh auth login --with-token"
ssh win2 "git config --global user.name <name> && git config --global user.email <email> && gh auth setup-git"
```

`gh auth setup-git` matters: unattended git over HTTPS fails later on a stale
credential helper without it.

## Phase 3 — himmel + machine setup

> **Just installing himmel for adopter use, not the full dev + lane-fleet
> setup below?** Clone first, then use the wizard instead:
> `git clone https://github.com/yotamleo/himmel && cd himmel`, then
> `powershell -ExecutionPolicy Bypass -File scripts\himmelctl\bootstrap.ps1`
> (winget-installs node if missing, then hands off to `himmelctl install`).
> The rest of this phase runs `win11.ps1`, the machine-provisioner script this
> remote clean-machine walkthrough uses for the full toolchain + lane-fleet +
> luna setup — it remains in place, not superseded by the wizard.

1. **Clone the DEV repo, not the public mirror.** If your himmel development
   happens in a private repo with a public propagation mirror, `git clone` of
   the public name gives you a stale, differently-numbered history. Check the
   source machine's `git remote -v` and clone **that** URL.
2. `git config --global core.longpaths true` **before** cloning big vaults —
   the luna clone on win2 finished but **checkout failed** ("unable to
   checkout working tree") until longpaths was on; recover an already-cloned
   vault with `git checkout -f HEAD`.
3. Run the full machine setup **detached** so an ssh drop doesn't kill it,
   with **stdin redirected from a file of blank lines** so every `Read-Host`
   prompt takes its default:

   ```powershell
   # on target
   Set-Content "$env:USERPROFILE\setup-stdin.txt" ("`n" * 30)
   Start-Process pwsh -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',
       '-File',"$env:USERPROFILE\Documents\github\himmel\scripts\machine-setup\win11.ps1",
       '-LunaRemote','<luna-remote-url>' `
     -RedirectStandardInput "$env:USERPROFILE\setup-stdin.txt" `
     -RedirectStandardOutput "$env:USERPROFILE\win11-setup.log" `
     -RedirectStandardError "$env:USERPROFILE\win11-setup.err" -WindowStyle Hidden
   ```

   Poll `win11-setup.log` for `[N/19]` markers; the process disappearing
   before `SETUP COMPLETE` means a fatal step — read `win11-setup.err`.
4. **nvm-windows PATH trap**: step 3 of `win11.ps1` fails on the very first
   run with "nvm.exe still not on PATH" — the installer's env vars don't
   reach the running process. The fix is exactly what the error says: re-run
   in a fresh session (the script is idempotent; already-installed steps skip
   or no-op-fail through).
5. Single-writer vaults: drop `.single-writer` at the vault root + add it to
   the global excludes file (see `new-machine.md` §4a).

## Phase 4 — .env + config porting

`scp` from source, same paths on target:

| File | Note |
|---|---|
| `<himmel>/.env` | jira CLI + bridged process-env values |
| `~/.config/watch/.env` | watch tooling |
| `~/.claude/channels/telegram/.env` | ⚠️ **port the token but DO NOT start the bridge** — one `getUpdates` poller per token; a second live poller 409-conflicts the first |

`~/.claude/CLAUDE.md` + `RTK.md` are written by `win11.ps1` from the repo —
no porting needed.

## Phase 5 — lane fleet

Registry: `scripts/lanes/lanes.json` (query the live set with `/lanes`).
What each lane needs on a new machine:

| Lane | Install | Auth/config port |
|---|---|---|
| codex | `winget install OpenAI.Codex` | copy `~/.codex/{auth.json,config.toml,AGENTS.md}` (skip caches/sessions). Re-check `config.toml` absolute paths (e.g. `uvx.exe`) if the username differs. Then run `scripts/codex/install-himmel-codex.ps1` |
| hermes | `git clone https://github.com/NousResearch/hermes-agent` → `%LOCALAPPDATA%\hermes\hermes-agent`, then `uv venv --python 3.11 venv` + `python -m ensurepip` + `pip install -e .` (uv venvs ship without pip), add `venv\Scripts` to user PATH. (Upstream one-liner installer exists — see `docs/hermes-runbook.md` — but the git method matches what `/himmel-update` maintains.) | copy from source `%LOCALAPPDATA%\hermes\`: `.env`, `config.yaml`, `SOUL.md`, `auth.json`, `active_profile`, `shell-hooks-allowlist.json`, `agent-hooks/`, `hooks/`, `profiles/`, `skills/`. **Never** `state.db`/caches/sessions/logs. ⚠️ **Do not auto-start the gateway** — same-token platform pollers conflict across machines, same rule as the telegram bridge. Then `scripts/hermes/install-himmel-profile.ps1` |
| copilot-cli | `winget install GitHub.Copilot` | interactive `copilot` GitHub device-flow login on target (not portable) |
| antigravity (agy) | no public installer metadata — copy the standalone `agy.exe` from source `%LOCALAPPDATA%\agy\bin\` + add to user PATH (it self-updates) | interactive Google login on target |
| ollama | `winget install Ollama.Ollama` + `setx OLLAMA_NO_CLOUD 1` | `ollama pull qwen2.5-coder:7b` (multi-GB; run detached) |
| GLM / openrouter | nothing — launchers ship in himmel | keys ride `<himmel>/.env` (Phase 4) |

Smoke tests: `codex --version` · `hermes doctor` ·
`bash scripts/hermes/invoke.sh "Reply with exactly: OK"` (spends free-tier
credits) · `ollama list`.

## Phase 6 — always-on hardening

```powershell
# never sleep (AC + DC), no hibernate, disk stays up, lid does nothing
powercfg /change standby-timeout-ac 0;  powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-ac 0; powercfg /change hibernate-timeout-dc 0
powercfg /change disk-timeout-ac 0
powercfg /hibernate off
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
# no lock screen on wake
powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
powercfg /S SCHEME_CURRENT
```

Apps that should ride the auto-logon session (e.g. Obsidian for the vault)
go in the per-user Run key:

```powershell
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Obsidian `
  -Value "`"$env:LOCALAPPDATA\Programs\Obsidian\Obsidian.exe`""
```

Auto-logon (so scheduled `claude` relaunches get a desktop session):

1. Windows 11 hides the classic auto-logon path while Hello/passwordless is
   preferred — clear it first:
   `Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device' -Name DevicePasswordLessBuildVersion -Value 0`
2. Use **Sysinternals Autologon** (`https://live.sysinternals.com/Autologon64.exe`)
   — it stores the password LSA-encrypted, unlike the plaintext
   `DefaultPassword` registry value. The password entry is the one step the
   operator does by hand on the target.

## Verification checklist

- [ ] `ssh win2 "powershell -NoProfile -Command hostname"` answers
- [ ] `node scripts/jira/dist/index.js list` returns issues (proves node build + .env)
- [ ] `pre-commit --version` + hooks installed in himmel clone
- [ ] `rtk --version`
- [ ] luna clone clean: `git -C ~/Documents/luna status -s` empty
- [ ] `codex --version` + `~/.codex/auth.json` present
- [ ] `hermes doctor` clean; `invoke.sh` smoke returns `OK`
- [ ] `powercfg /a` + `Get-ItemProperty ...Winlogon | Select AutoAdminLogon` = 1
- [ ] reboot target → machine comes back logged-in, sshd up, no lock screen
