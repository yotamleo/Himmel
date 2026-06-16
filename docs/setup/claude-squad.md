# Claude Squad (`cs`) — optional

[Claude Squad](https://github.com/smtg-ai/claude-squad) (`cs`) is a terminal app that manages multiple Claude Code / Codex / Gemini / Aider sessions in isolated tmux panes + git worktrees. License: AGPL-3.0.

> Status: optional. Not required by any himmel script or hook. Install via `scripts/setup.sh --with-cs` or `scripts/setup.ps1 -WithCs`, or follow the manual flow below.

---

## Why fork

himmel keeps an in-org mirror of the upstream repo at
[`yotamleo/claude-squad`](https://github.com/yotamleo/claude-squad). A daily
GitHub Action (`.github/workflows/sync-upstream.yml` in the fork) calls
`gh repo sync` to fast-forward the fork's `main` to `smtg-ai/claude-squad@main`.

Purpose:

- **Source audit trail** — every upstream change lands in the fork's commit
  log on a 24-hour cadence, so we can diff-review what changed before
  picking up new binaries.
- **Escape hatch** — if upstream goes dark, gets compromised, or relicenses
  to something non-AGPL-compatible, we can pin the fork at a known-good
  commit and rebuild releases ourselves.

v1 scope: source mirror only. Binary releases still come from
`smtg-ai/claude-squad/releases` (maintainer-signed). A future ticket can
add release-build CI in the fork if upstream ever goes dark.

A fork of himmel run by a different operator can point at their own
claude-squad fork (or upstream `smtg-ai`) by setting `CS_FORK_OWNER`
before running setup:

```bash
CS_FORK_OWNER=smtg-ai bash scripts/setup.sh --with-cs    # skip the mirror, hit upstream
CS_FORK_OWNER=acme    bash scripts/setup.sh --with-cs    # use acme/claude-squad
```

Default: `yotamleo`.

### Enabling the scheduled sync in the fork

GitHub disables scheduled workflows on forks by default. One-time setup:

1. Open https://github.com/yotamleo/claude-squad/actions
2. Click "I understand my workflows, go ahead and enable them"
3. Verify the "Sync upstream" workflow shows up

Manual trigger any time via the **Run workflow** button or:

```bash
gh workflow run sync-upstream.yml --repo yotamleo/claude-squad
```

---

## Prerequisites

| Tool | Why |
|---|---|
| `tmux` (or psmux on Windows) | cs spawns each agent in a tmux pane |
| `gh` | cs uses `gh` to push branches to GitHub |
| `git` | worktree isolation per session |
| `bash` | install scripts + cs internals |

`scripts/setup.sh` step 0 already verifies `bash`, `git`, `gh`. The cs
install step adds platform-specific tmux handling:

- `scripts/setup/install-cs.sh` (Linux + macOS) checks for `tmux` and installs
  via `brew install tmux` (macOS) or `apt-get` / `dnf` / `yum` / `pacman`
  (Linux) if missing.
- `scripts/setup.ps1` (Windows) installs `psmux` via
  `winget install --id marlocarlo.psmux`. psmux ships a `tmux.exe` shim so
  cs's `tmux` calls work unmodified.

---

## Install — Windows

psmux is a native-Windows tmux replacement (Rust + ConPTY). It ships a `tmux.exe`
shim so cs's `tmux` invocations work unmodified.

```powershell
# 1. psmux (provides tmux.exe shim)
winget install --id marlocarlo.psmux

# 2. cs binary — opt-in via setup.ps1
.\scripts\setup.ps1 -WithCs

# Or manually:
$ver = (gh api repos/smtg-ai/claude-squad/releases/latest --jq .tag_name).TrimStart('v')
$url = "https://github.com/smtg-ai/claude-squad/releases/download/v$ver/claude-squad_${ver}_windows_amd64.zip"
$tmp = "$env:TEMP\cs-install"; New-Item -ItemType Directory -Force $tmp | Out-Null
Invoke-WebRequest -Uri $url -OutFile "$tmp\cs.zip"
Expand-Archive -Force -Path "$tmp\cs.zip" -DestinationPath $tmp
New-Item -ItemType Directory -Force "$HOME\.local\bin" | Out-Null
Move-Item -Force "$tmp\claude-squad.exe" "$HOME\.local\bin\cs.exe"
```

Add `~/.local/bin` to User PATH if not already there. Git Bash inherits
User PATH on Windows, so no `.bashrc` edit is needed for cs to resolve in
both shells.

Verify:

```powershell
cs version    # cs.exe version 1.0.x
tmux -V       # tmux 3.3.x  (psmux shim reports tmux's version)
```

### Known Windows quirks

- **Config paths use backslashes.** `~/.claude-squad/config.json` is
  Windows-format. If you copy a config from Linux/macOS, normalize paths
  before launching cs.
- **`default_program` must be absolute.** Relative paths fail silently.
  Set it to `C:\Users\<you>\.local\bin\claude.exe` (or wherever `claude`
  lives).
- **psmux is not 100% tmux-compatible.** It implements a subset of tmux
  commands sufficient for cs's session management. If you hit a tmux feature cs needs
  that psmux doesn't support, file an issue against
  [psmux](https://github.com/psmux/psmux) and fall back to WSL2 + real tmux.

> _Windows quirks verified against cs 1.0.18 + psmux 3.3.4 on 2026-06-01. Behavior may drift on newer versions — re-check with `cs debug` and `psmux list-commands`._

---

## Install — macOS

```bash
# Recommended: Homebrew
brew install claude-squad
ln -sf "$(brew --prefix)/bin/claude-squad" "$(brew --prefix)/bin/cs"

# Or opt-in via setup
bash scripts/setup.sh --with-cs
```

`tmux` is auto-installed by the setup script if missing
(`brew install tmux`).

---

## Install — Linux

The cs upstream `install.sh` handles tmux/gh installation per distro
(apt/dnf/yum/pacman) and drops the binary at `~/.local/bin/cs`.

```bash
bash scripts/setup.sh --with-cs
```

The setup step downloads the install script from the fork
(`https://raw.githubusercontent.com/yotamleo/claude-squad/main/install.sh`)
and executes it. The fork mirrors upstream daily, so this is functionally
equivalent to running upstream's script — with the audit-trail benefit
that any change is visible in the fork's commit log.

Manual one-liner (matches what setup runs):

```bash
curl -fsSL https://raw.githubusercontent.com/yotamleo/claude-squad/main/install.sh | bash
```

---

## First-run checklist

```bash
cs debug          # prints config path + version, no TUI
cs version        # version only
```

Edit `~/.claude-squad/config.json` (or `%USERPROFILE%\.claude-squad\config.json`):

```json
{
  "default_program": "/absolute/path/to/claude",
  "auto_yes": false,
  "daemon_poll_interval": 1000,
  "branch_prefix": "cs/"
}
```

> _This example lists the keys himmel relies on, not the full schema. Run `cs debug` (prints the active config path + values) or check the upstream [claude-squad config](https://github.com/smtg-ai/claude-squad) for the authoritative key set — upstream may add or rename keys._

Then launch in a real terminal (Windows Terminal / Warp / iTerm — NOT
inside an existing tmux session unless you know what you're doing):

```bash
cs
```

Keybinds:

- `n` — new session
- `D` — kill session
- `enter` / `o` — attach
- `ctrl-q` — detach
- `s` — commit + push branch to GitHub
- `?` — full help
- `q` — quit

---

## Opt-in flags

The setup scripts only install cs when explicitly requested:

| Trigger | setup.sh | setup.ps1 |
|---|---|---|
| Explicit flag | `--with-cs` | `-WithCs` |
| Interactive TTY prompt | `Install claude-squad? [y/N]` (default N) | same |
| Non-interactive, no flag | skipped silently | skipped silently |

No env var gate (unlike `EDIT_ON_MAIN_OK` etc.) — cs install is a
network-fetching action, so per-invocation consent is the right shape.

---

## Troubleshooting

- **`failed to start new session: timed out waiting for tmux session`** —
  upstream FAQ says update `claude` to latest. On Windows, also check
  that `psmux --version` works and `tmux.exe` resolves to the psmux shim
  via `where tmux` (PowerShell) or `which tmux` (bash).
- **`cs: command not found` in fresh shell** — `~/.local/bin` not on PATH.
  PowerShell: the User PATH edit takes effect in new shells only.
  Git Bash inherits User PATH, so the same edit covers both.
- **psmux missing on Windows** — `winget install --id marlocarlo.psmux`.

---

## References

- Upstream: https://github.com/smtg-ai/claude-squad (AGPL-3.0)
- Fork mirror: https://github.com/yotamleo/claude-squad
- psmux: https://github.com/psmux/psmux (MIT, Windows-only)
- Jira: HIMMEL-151
