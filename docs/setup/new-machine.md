# New Machine Setup

Complete checklist for getting a new machine to full working state.

**Adopting himmel on your own repo** (not developing himmel itself)? See [docs/setup/use-on-your-project.md](./use-on-your-project.md) instead — it covers the portable-core flow and tells you which sections here apply to you.

---

## 1. Required environment (HIMMEL-123)

`scripts/setup.sh` and `scripts/setup.ps1` verify these at step 0 and fail fast with install hints. Run `bash scripts/setup.sh` (or `scripts/setup.ps1`) and the script tells you exactly what's missing.

### Foundational (every platform — verified at setup)

| Tool | Min version | Why |
|---|---|---|
| `bash` | 3.2 (most scripts) · 4.0 (8 scripts use `mapfile`) | macOS ships bash 3.2 — `brew install bash` if you hit `mapfile: command not found` from the 8 bash-4 scripts listed below |
| `git` | 2.30+ | Worktrees + `--show-toplevel` |
| `node` | 18+ | Jira plugin build + plugin-install workflow |
| `npm` | bundled with node 18+ | Lockfile audit hooks + plugin install |
| `bun` | 1.0+ | Runs the handover armed-resume resolver, the qmd search index, the Telegram bridge, and the obsidian-triage tools. Install: `curl -fsSL https://bun.sh/install \| bash` (Linux/macOS) or `irm bun.sh/install.ps1 \| iex` (Windows) |
| `python3` | 3.10+ | `realpath -m` fallback (macOS) + JSON helpers in 28 scripts. PEP 668 (Ubuntu 24.04+) blocks system pip — use `uv` or `pipx` for pre-commit. |
| `jq` | 1.6+ | Hook input parsing (13 scripts incl. all Claude PreToolUse hooks) |
| `gh` | 2.x | Issue + PR + CR workflows (12 scripts) |
| `mktemp` | BSD or GNU (both fine) | 19 scripts |
| `pre-commit` | 3.5+ | Pre-commit framework |
| `claude` (CLI) | latest | Native installer: `curl -fsSL https://claude.ai/install.sh \| bash` (Linux/macOS) or `irm https://claude.ai/install.ps1 \| iex` (Windows) |

### Per-platform additions

**Linux (Ubuntu / Debian / Arch / Fedora):**

| Tool | How |
|---|---|
| `at` + `atd` running | `sudo apt install at && sudo systemctl enable --now atd` (or distro equivalent). Required by `scripts/handover/arm-resume.sh` for cron-armed Claude relaunches. |
| `realpath -m` (coreutils) | Default on most distros. |
| `shellcheck`, `gitleaks` | `sudo apt install shellcheck` + `gitleaks` via official tarball or `brew`. Used by pre-commit. |
| `uv` OR `pipx` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` (recommended). PEP 668 blocks system pip. |

**macOS:**

| Tool | How |
|---|---|
| `bash` 4+ | `brew install bash` — system bash is 3.2 and 8 scripts need 4+. Add `/usr/local/bin/bash` (Intel) or `/opt/homebrew/bin/bash` (Apple Silicon) to PATH or use `#!/usr/bin/env bash` (already the convention). |
| `at` daemon | Preinstalled but disabled. Enable: `sudo launchctl load -F /System/Library/LaunchDaemons/com.apple.atrun.plist`. |
| `realpath -m` (optional) | Macos has no `realpath -m`; the 5 scripts that use it (`arm-resume.sh`, `auto-commit.sh`, `block-edit-on-main.sh`, `check-hookspath.sh`) already include a `python3 -c "from pathlib import Path; print(Path(p).resolve(strict=False))"` fallback. Pure-GNU operators: `brew install coreutils && export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"` exposes `grealpath` as plain `realpath`. |
| `uv` OR `pipx` | `brew install uv` (or pipx). |

**Windows (Git Bash via Git for Windows):**

| Tool | How |
|---|---|
| Git Bash 2.40+ | https://git-scm.com — includes bash 4.4+, `realpath -m`, `mktemp`, `cygpath`. |
| `schtasks` | Built-in. Used by `scripts/handover/arm-resume.sh` for cron-armed Claude relaunches. **Always invoke under `MSYS_NO_PATHCONV=1`** (per HIMMEL-125) to prevent Git Bash from mangling `/flag` args into Windows paths. |
| `MSYS_NO_PATHCONV` awareness | Documented in CLAUDE.md handover section. |
| WSL or PowerShell-only is **NOT sufficient** — most operator-facing tooling needs bash. WSL works but adds an indirection layer; native Git Bash is the tested path. |

### Scripts requiring bash 4+

These will error `mapfile: command not found` on macOS system bash (3.2). Either install `bash` 4+ via `brew install bash`, or convert the `mapfile` use to a `while IFS= read` loop (cheap port if needed):

- `scripts/luna/sweep-himmel.sh`
- `scripts/hooks/check-no-headless-claude.sh`
- `scripts/hooks/check-mcp-plugin-refs.sh`
- `scripts/hooks/check-lockfile-integrity.sh`
- `scripts/hooks/check-npm-audit.sh`
- `scripts/hooks/check-npm-audit-signatures.sh`
- `scripts/hooks/check-npm-licenses.sh`
- `scripts/hooks/check-uv-lock.sh`

Every other script is bash 3.2-compatible.

### Single-source tool dependencies

These tools show up in only one script — easy to drop if not on PATH (the affected feature degrades):

- `cygpath` (Windows-only path translation) → `scripts/handover/arm-resume.sh` only.
- `shellcheck`, `gitleaks` → `scripts/machine-setup/ubuntu.sh` bootstrap only; pre-commit framework re-fetches them per-hook so they don't need to be on PATH for normal use.
- `pipx` → fallback in `setup.sh` + `ubuntu.sh` only (uv is primary).
- `qmd` → `setup.sh` step 4 only (collection register); optional if you don't use qmd search.

### Other tools

- **Obsidian** — https://obsidian.md (for luna vault).
- **Claude Code CLI** — see foundational table above.

---

---

## 2. Global Claude Config

These files live at `~/.claude/` and must be copied on every new machine.

```bash
# Create dir if missing
mkdir -p ~/.claude

# Copy from this repo
cp docs/setup/global-claude-md.md ~/.claude/CLAUDE.md
cp docs/setup/rtk-md.md ~/.claude/RTK.md
```

Source of truth: [`docs/setup/global-claude-md.md`](global-claude-md.md) and [`docs/setup/rtk-md.md`](rtk-md.md).

> `CLAUDE.md` uses `@RTK.md` — both files must be present in `~/.claude/`.

---

## 3. RTK (Rust Token Killer)

RTK is a token-saving CLI proxy that wraps common commands.

```bash
# Install
cargo install rtk   # or download binary from releases

# Verify (must show rtk, NOT reachingforthejack/rtk)
rtk --version
rtk gain
```

⚠️ Name collision risk — see [`docs/setup/rtk-md.md`](rtk-md.md).

---

## 4. himmel Repo

```bash
git clone https://github.com/yotamleo/Himmel.git
cd himmel
bash scripts/setup.sh
```

`scripts/setup.sh` handles: pre-commit install, Jira CLI build, `.env` from `.env.example`.

After setup:
```bash
# Fill in Jira token
vi .env   # set JIRA_API_TOKEN=...

# Verify
jira list
pre-commit run --all-files
```

---

## 5. Luna Vault

> **Skip** if you don't use the Luna vault (the author's personal Obsidian vault). §§5a, 6, 7, 8, 8.6 all depend on it — skip those too.

> Canonical layout (post HIMMEL-96 fix): the vault lives at `~/Documents/luna` — flat, not double-nested. If your machine has `~/Documents/luna/luna` from a pre-HIMMEL-96 clone, `scripts/machine-setup/{ubuntu.sh,win11.ps1}` includes a migration step that flattens it.

```bash
# Clone (or restore from backup) — flat path, NOT ~/Documents/luna/luna
git clone <luna-remote> ~/Documents/luna

# Install pre-commit hooks
cd ~/Documents/luna
uv tool install pre-commit   # or: pipx install pre-commit
pre-commit install
pre-commit install --hook-type pre-push

# Verify
pre-commit run --all-files
```

Hooks: `gitleaks` (secrets scan) + standard hooks. Luna-specific rules live in `~/Documents/luna/CLAUDE.md` (not linked here — it's in a different repo).

> Vault not at `~/Documents/luna`, or want to route a repo's session notes to a different vault? Point the end-session-wiki capture at it — see [Choosing the target vault](../luna/end-session-wiki.md#choosing-the-target-vault) (and §7 below).

### 5a. Optional — Obsidian Web Clipper templates ([Jira LUNA-2](https://yotamleo.atlassian.net/browse/LUNA-2))

If you'll be clipping web pages into Luna (X posts, articles, Reddit threads, newsletters, YouTube videos), install the Obsidian Web Clipper Chrome extension + drop in the 6 pre-built JSON templates that ship with Luna. **Skip if you only want to use Luna for native notes.**

```bash
# Templates ship in the Luna repo:
ls ~/Documents/luna/_Templates/Web-Clipper/import/
# 01-General-Article.json, 02-Research-Article.json, 03-Tweet.json,
# 04-Reddit-Thread.json, 05-Newsletter.json, 06-YouTube-Video.json,
# README.md
```

Install:

1. Install [Obsidian Web Clipper](https://obsidian.md/clipper) from the Chrome Web Store.
2. Extension icon → **Settings** (gear) → scroll to **Templates**.
3. **Drag and drop** all 6 `.json` files from `~/Documents/luna/_Templates/Web-Clipper/import/` onto the Templates list. Six templates appear — names, triggers, properties, body all wired up.
4. Mark **General Article** as Default template (it has no triggers → fires when no other template matches).
5. Confirm `path: "Clippings"` matches Luna's `Clippings/` folder (or change in extension settings).
6. Smoke-test: clip any `x.com/...` URL → confirm Tweet template fires + note lands in `Clippings/`.

The drag-and-drop is the entire install. Trigger tables + post-install tuning live in luna at `_Templates/Web-Clipper/import/README.md`; the *why* behind each section lives in luna at `30-Resources/Tech/Obsidian Web Clipper Templates.md` (both in the luna repo, not linkable from himmel).

Triage of clipped notes (action items / labels / Related Notes hygiene) is implemented as the **`obsidian-triage`** plugin shipped from himmel's marketplace — see §6 below for install. Ticket: [LUNA-3](https://yotamleo.atlassian.net/browse/LUNA-3); handover tracked in the operator's private handover repo.

---

## 6. Claude Code Plugins

> **Skip** if you skipped §5 (Luna vault). The plugins in this section are either luna-dependent or personal-workflow tools — none are required for core himmel operation. Install only what you need.

Plugins live at `~/.claude/plugins/`. Different install methods per plugin — read the **Source** column carefully:

| Plugin | Source | Install method | Why |
|--------|--------|----------------|-----|
| `obsidian-second-brain` | `eugeniughelbur/obsidian-second-brain` | manual clone (NOT in himmel marketplace) | Daily notes, kanban, ADRs, vault operating manual |
| `caveman` | separate marketplace `claude-code-warp` (NOT in himmel marketplace) | `/plugin marketplace add` then `/plugin install` | Caveman compression mode + cavecrew subagents |
| `handover` | himmel marketplace | `/plugin install` after adding himmel marketplace | Handover doc workflows for cross-session continuity |
| `obsidian-triage` (LUNA-3) | himmel marketplace | `/plugin install` after adding himmel marketplace | Autonomous triage of Web Clipper output: `/triage-clips` + `/synthesize-clips`. Required only if you set up the Web Clipper templates in §5a |
| `obsidian` (Steph Ango's skills) | himmel marketplace (sources `kepano/obsidian-skills`, SHA-pinned) | `/plugin install` after adding himmel marketplace | `obsidian-markdown`, `obsidian-bases`, `json-canvas`, `obsidian-cli`, `defuddle`. `obsidian-triage` can use `obsidian-markdown` for proper OFM when editing clipped notes (recommended, not required — fallback documented in the command body) |
| `claude-obsidian` | himmel marketplace (sources `yotamleo/claude-obsidian` vendor fork of `AgriciDaniel/claude-obsidian`, SHA-pinned) | `/plugin install` after adding himmel marketplace | Wiki query, save, ingest, lint, autoresearch. Companion to `obsidian-triage` — `wiki-query` optionally powers richer Related Notes inference |

### Install sequence

```bash
# 1. obsidian-second-brain — manual clone (no marketplace)
git clone https://github.com/eugeniughelbur/obsidian-second-brain ~/.claude/plugins/obsidian-second-brain

# 2. himmel marketplace (carries handover + obsidian-triage + obsidian + claude-obsidian)
# inside Claude Code:
#   /plugin marketplace add yotamleo/himmel
#   /plugin install handover
#
#   # Optional — Web Clipper triage stack (skip if §5a was skipped)
#   /plugin install obsidian-triage
#   /plugin install obsidian            # kepano/obsidian-skills, SHA-pinned
#   /plugin install claude-obsidian     # yotamleo/claude-obsidian (vendor fork of AgriciDaniel/claude-obsidian), SHA-pinned

# 3. caveman — separate marketplace
#   /plugin marketplace add wfgilreath/caveman      # adjust to your fork/source
#   /plugin install caveman
```

After restoring plugins, verify skills load:
```
/obsidian-daily            # from obsidian-second-brain
/caveman help              # from caveman plugin
/triage-clips --dry-run    # from obsidian-triage; should exit 0 with "no Clippings/" or per-clip preview
```

Note: `obsidian` and `claude-obsidian` are pinned to commit SHAs in himmel's `marketplace/.claude-plugin/marketplace.json` per supply-chain policy. To update either, bump the `ref` field in a deliberate PR (same gate as a dep bump).

### Scope: user vs project

The `/plugin install` flow above records the plugin at **user scope** (`~/.claude/settings.json`) — enabled for you across every project. That's the right default for personal-workflow plugins. The alternative is **project scope**: declare the marketplace + plugins in a *repo's* `.claude/settings.json`, so anyone who clones that repo gets them auto-known and enabled (each person is still prompted to trust the marketplace on first use).

The setup scripts let you pick: `scripts/machine-setup/install-plugins.{sh,ps1}` take `--scope user|project|local` (default `user`), and the top-level `ubuntu.sh` / `win11.ps1` setup prompts you to choose. For project/local the target is the **current directory**, so run from the repo you want the plugins scoped to. The CLI does it directly too — `claude plugin install <name>@himmel --scope project` writes the block below for you. Same keys, different file:

```jsonc
// <repo>/.claude/settings.json
{
  "extraKnownMarketplaces": {
    "himmel": { "source": { "source": "github", "repo": "yotamleo/himmel" } }
  },
  "enabledPlugins": {
    "obsidian-triage@himmel": true
  }
}
```

Pick by intent: *yours, everywhere* → user scope; *part of this project, shared on clone* → project scope. Committing `extraKnownMarketplaces` ships a "trust this third-party registry" into the repo — fine for your own repos, a supply-chain call if it has outside contributors. (The JSON above is the illustrative hand-edit form. himmel's setup scripts instead read [`settings-template.json`](settings-template.json) — which registers the marketplace from a local `directory` source rather than the GitHub repo shown above — and apply the plugin set at whichever `--scope` you pick.)

### Direct install (copy-paste, no setup script)

The [Install sequence](#install-sequence) above runs as part of the machine
setup. To skip setup and just add the marketplace + the plugins you want —
choosing the scope per command — copy-paste instead:

```bash
# Register the marketplace (once; the GitHub slug is case-insensitive)
claude plugin marketplace add yotamleo/himmel

# Install plugins — --scope user (default, every project) or
# --scope project (this repo's .claude/settings.json, shared on clone)
claude plugin install handover@himmel         --scope user
claude plugin install obsidian-triage@himmel  --scope user
claude plugin install claude-obsidian@himmel  --scope user
claude plugin install obsidian@himmel         --scope user
claude plugin install himmel-ops@himmel       --scope user
# optional operator-coupled forks: telegram-himmel@himmel, pr-review-toolkit-himmel@himmel
```

Or install the entire manifest (the himmel plugins plus the official ones it
builds on) in one shot from a clone, at a chosen scope:

```bash
git clone https://github.com/yotamleo/Himmel
bash Himmel/scripts/machine-setup/install-plugins.sh --scope project
```

The plugins carry their own slash commands + skills — that's all you need to use
them.

### Remove / move between scopes

- **Remove (user scope):** `/plugin uninstall <name>@himmel`.
- **Remove (project scope):** delete that plugin's `enabledPlugins` line from the repo's `.claude/settings.json` (and drop the `extraKnownMarketplaces.himmel` block once no himmel plugin is left).
- **Move user → project:** `/plugin uninstall <name>@himmel`, then add it to the repo's `.claude/settings.json` as above.
- **Move project → user:** remove its `enabledPlugins` line from the repo settings, then `/plugin install <name>@himmel`.

---

## 7. End-session wiki hook (auto-capture to Luna vault)

> **Skip** if you don't use the Luna vault — this hook writes session notes there and has no effect without it.

Every Claude Code session is auto-captured to the Luna vault as a structured note under `sessions/YYYY/MM/YYYY-MM-DD-HHMM-<repo>-<branch>.md` via a `SessionEnd` hook. Built by epic #7 — full schema + opt-out in [`docs/luna/end-session-wiki.md`](../luna/end-session-wiki.md).

**Prompted during setup.** `scripts/machine-setup/win11.ps1` and `scripts/machine-setup/ubuntu.sh` both prompt to register the hook into `~/.claude/settings.json`:

- **Win11:** `[P]owerShell only / [B]ash only (Git Bash) / Both / [S]kip [default: Both]` — Windows machines usually have both interpreters; pick what you actually use.
- **Ubuntu:** `[Y]es / [n]o [default: Y]` — bash-only (no pwsh by default).

The setup also handles the existing-config case: if `hooks.SessionEnd` already exists in your `settings.json`, the script asks `[O]verwrite / [A]ppend / [S]kip`. A backup is written to `~/.claude/settings.json.bak.YYYYMMDD-HHMMSS` before any modification.

**Skipped during setup?** Re-run the setup script (it's idempotent on this step) or manually add the block to `~/.claude/settings.json`:

```json
"SessionEnd": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "pwsh -NoProfile -File \"<himmel-path>/scripts/hooks/end-session-wiki.ps1\"",
        "shell": "powershell",
        "timeout": 30
      },
      {
        "type": "command",
        "command": "bash \"<himmel-path>/scripts/hooks/end-session-wiki.sh\"",
        "shell": "bash",
        "timeout": 30
      }
    ]
  }
]
```

For per-repo opt-out, env-var disable, dry-run mode, and full operational reference, see [`docs/luna/end-session-wiki.md`](../luna/end-session-wiki.md).

---

## 8. MCP Servers

> **Skip** if you don't use the Luna vault or Atlassian (Jira/Confluence). Both entries here are optional integrations.

Configure in Claude Code settings (`~/.claude/settings.json`):

- **obsidian-vault**: `uvx mcp-obsidian` pointing to Luna vault path
- **atlassian**: Jira/Confluence MCP (requires token)

---

## 8.5. Optional integrations

- **claude-squad (cs)** — multi-agent tmux orchestrator. Opt-in via
  `bash scripts/setup.sh --with-cs` (macOS/Linux) or
  `.\scripts\setup.ps1 -WithCs` (Windows). Full Windows + psmux fork-mirror
  details in [`claude-squad.md`](claude-squad.md).

---

## 8.6. Telegram bridge + Warp onboarding (HIMMEL-227)

> **Skip** if you don't use the Telegram bridge for sending messages to Claude. This is operator-specific infrastructure; it is not required for any core himmel workflow.

`scripts/setup.{sh,ps1}` step `[7/8]` runs
`scripts/setup/onboard-telegram.{sh,ps1}` — **scaffold-only**, also safe to
run standalone. It:

- creates `~/.claude/channels/telegram/` + a `TELEGRAM_BOT_TOKEN=` `.env`
  template (never overwrites an existing `.env`);
- reports `access.json` (pairing) status. Setup **never writes
  `access.json`** — the allowlist is a prompt-injection surface and the live
  bridge must be restarted by the operator after edits. Create it yourself:
  `{"allowFrom":["<your-telegram-user-id>"]}`;
- **never starts the bridge** (one `getUpdates` owner per token — a blind
  start could 409-conflict a live poller). Bring-up after token + pairing:
  `pwsh -File scripts/telegram/restart-bridge.ps1` (Windows) or
  `cd scripts/telegram && bun supervisor.ts` (Linux/macOS). Reboot
  persistence + full ops:
  [`scripts/telegram/README.md`](../../scripts/telegram/README.md) /
  [`docs/internals/telegram-bridge.md`](../internals/telegram-bridge.md);
- verifies the Warp surface: `/open-warp` + `/oz-offload` skills are
  repo-local (`.claude/commands/`, ship with the clone), the
  `warp@claude-code-warp` plugin installs via
  `scripts/machine-setup/install-plugins.{sh,ps1}`, and the Warp app binary
  gets a presence check + install hint.

## 8.7. Uninstall / offboard (HIMMEL-227)

`scripts/uninstall.{sh,ps1}` is the symmetric teardown of setup +
install-plugins. **Destructive and fail-closed**: interactive runs prompt;
non-interactive runs abort without `--yes`/`-Yes`. Preview first:

```bash
bash scripts/uninstall.sh --dry-run
```

Steps: (1) stop the telegram bun bridge (`bun supervisor.ts --kill`),
(2) remove telegram pairing + bridge state (`~/.claude/channels/telegram/`
incl. token + `access.json`, `~/.claude/handover/bridge/`) — local delete
does NOT revoke the bot token; revoke via @BotFather when decommissioning,
(3) remove `HIMMEL-Resume-*` scheduled jobs + the `HimmelTelegramBridge`
logon task, (4) uninstall the settings-template plugins + marketplaces via
`scripts/machine-setup/uninstall-plugins.{sh,ps1}` (**user-scope — affects
every repo on the machine**), (5) `pre-commit uninstall` ×3 hook types.
Partial offboard via `--keep-telegram-state` / `--skip-plugins` /
`--skip-tasks` / `--skip-hooks` (PS: `-KeepTelegramState` etc.). Not
touched: `~/.claude/settings.json`, the himmel clone + `.env`, handover
state outside the bridge root.

---

## 9. Verification Checklist

### CORE — required for any adopter

- [ ] `rtk --version` works
- [ ] `pre-commit run --all-files` passes in himmel
- [ ] Claude Code loads and hooks fire (run any command; check no hook errors appear)
- [ ] Worktree round-trip: `/worktree test/smoke` creates a worktree; `/clean` removes it after merging

### OPTIONAL — per integration

**Jira / HIMMEL project:**
- [ ] `jira list` returns HIMMEL issues

**Luna vault:**
- [ ] `pre-commit run --all-files` passes in Luna vault
- [ ] `/obsidian-daily` creates today's note in Luna

**Caveman plugin:**
- [ ] Claude Code loads with caveman mode active

**Telegram bridge:**
- [ ] Bridge responds to a test message sent from Telegram

---

## `core.hooksPath` gate (HIMMEL-105)

Both machine-setup scripts (`ubuntu.sh`, `win11.ps1`) gate the post-clone
flow on `git config --get core.hooksPath` being either unset OR set to
an existing path inside the himmel working tree. If neither holds, setup
aborts before `pre-commit install` runs.

Why: in HIMMEL-45 the repo on disk was renamed `yotam_internal` → `himmel`,
but the `.git/config` was copied with the old hard-coded `core.hooksPath`
absolute string. Git silently skipped every pre-commit and pre-push hook
for an unknown duration (`no-push-to-main`, `npm-audit`, `npm-licenses`,
`code-review-before-push`, `platforms-tested`). PR #100 (HIMMEL-98) caught
it manually mid-overnight. This gate prevents recurrence.

The same script (`scripts/hooks/check-hookspath.sh` / `.ps1`) is wired in
three other places:

1. `.pre-commit-config.yaml` pre-commit stage — every commit fails if
   misconfigured.
2. Claude Code `~/.claude/settings.json` SessionStart array — prints a
   one-line warning when a session starts on a misconfigured repo.
   Non-blocking. The shared `docs/setup/settings-template.json` does
   NOT carry this entry; instead each platform setup script appends
   the right interpreter sibling so a Windows machine without Git Bash
   (or a Linux machine without pwsh) doesn't get a "command not found"
   line every session start. `scripts/machine-setup/win11.ps1` appends
   the `pwsh` entry; `scripts/machine-setup/ubuntu.sh` appends the
   `bash` entry.
3. The smoke test at `scripts/hooks/test-check-hookspath.sh` covers
   eleven cases: unset, set-inside-repo (absolute + relative), set-but-
   missing, set-outside-repo, bypass-via-env, outside-any-git-repo,
   linked worktree pointing at primary git-common-dir, outside-both-
   worktree-and-git-common-dir, Windows-drive-relative, and Windows
   mixed-case absolute prefix (case-insensitive NTFS).

### Existing machines (not freshly cloned)

The machine-setup scripts patch `~/.claude/settings.json` on every run, so
the SessionStart entries land automatically. If you have an EXISTING
`~/.claude/settings.json` you don't want re-patched, copy ONE of the
following fragments manually into the `SessionStart[0].hooks` array
(replacing `<himmel-path>` with the absolute path to your himmel clone) —
pick the interpreter that's actually on PATH on this machine:

Linux / macOS / Windows-with-Git-Bash:

```json
{
  "type": "command",
  "command": "bash \"<himmel-path>/scripts/hooks/check-hookspath.sh\"",
  "shell": "bash",
  "timeout": 10
}
```

Windows-with-pwsh:

```json
{
  "type": "command",
  "command": "pwsh -NoProfile -File \"<himmel-path>/scripts/hooks/check-hookspath.ps1\"",
  "shell": "powershell",
  "timeout": 10
}
```

### Intentional bypass

If you have a legitimate reason to point `core.hooksPath` outside the repo
(running a custom hook manager, e.g. lefthook, husky-in-parent-dir), set:

```
HOOKSPATH_OK=1 git commit ...
HOOKSPATH_OK=1 bash scripts/machine-setup/ubuntu.sh ...
```

Session-sticky: the env var must be set in the shell that launches the
operation; it cannot be injected per-call by Claude. To restore the gate,
unset the variable and re-launch.

The SessionStart hook has NO bypass — it is non-blocking, the printed
warning IS the affordance.

### Manual repro (verify the gate works)

```bash
# Inside a himmel clone:
git config core.hooksPath /tmp/nope
git commit --allow-empty -m "should be blocked"
# Expect: exit nonzero, "⛔ check-hookspath: core.hooksPath points
# at a path that does not exist" in stderr, no new commit created.
# (The pre-commit framework invokes the bash sibling, which uses ⛔.
# The pwsh sibling — triggered from Claude SessionStart on Windows —
# uses the [BLOCK] prefix instead, same semantics.)
git config --unset core.hooksPath
```
