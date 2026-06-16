# Machine Setup Scripts

Automate a bare OS → full dev environment. Run **before** the himmel repo is available.

---

## Win11

**Requirements:** PowerShell 7+ as Administrator, internet access.

```powershell
# 1. Download
Invoke-WebRequest "https://raw.githubusercontent.com/yotamleo/himmel/main/scripts/machine-setup/win11.ps1" -OutFile "$env:TEMP\win11.ps1"

# 2. Run
pwsh -ExecutionPolicy Bypass -File "$env:TEMP\win11.ps1" -LunaRemote "https://github.com/<you>/<your-vault>.git"
```

**What it installs:** winget packages (git, node LTS, python, jq), uv+uvx, Claude Code CLI, RTK, himmel repo + setup, claude-statusline, CLAUDE.md + RTK.md, obsidian-second-brain plugin, Luna vault + pre-commit, `~/.claude/settings.json` (shallow top-level merge), **end-session-wiki SessionEnd hook (prompted: PowerShell / Bash / Both / Skip)**, Obsidian.

**After run:** Complete the printed manual checklist (Jira token, Atlassian MCP token, qmd embed).

---

## Ubuntu

**Requirements:** Standard user with sudo, internet access.

```bash
# 1. Download
curl -fsSL "https://raw.githubusercontent.com/yotamleo/himmel/main/scripts/machine-setup/ubuntu.sh" -o /tmp/ubuntu.sh

# 2. Run
bash /tmp/ubuntu.sh --luna-remote "https://github.com/<you>/<your-vault>.git"
```

**What it installs:** apt packages (git, python3, jq, curl), node LTS via NodeSource, uv+uvx, Claude Code CLI, RTK (.deb), himmel repo + setup, claude-statusline, CLAUDE.md + RTK.md, obsidian-second-brain plugin, Luna vault + pre-commit, `~/.claude/settings.json` (jq deep-merge), **end-session-wiki SessionEnd hook (prompted: Y/n, bash-only)**, Obsidian (.deb).

**After run:** Complete the printed manual checklist (Jira token, Atlassian MCP token, qmd embed).

---

## Error handling

Steps 1–6 are fatal — any failure aborts immediately (no core tools = unusable). Steps 7–12 are non-fatal — failures are logged and setup continues. Final output lists all failed non-fatal steps.

---

## Re-running

Safe to re-run. `apt install -y` and `winget install` are idempotent. Git clones will error if the target already exists (delete first, or treat the clone failure as non-fatal on retry). On Win11, `settings.json` is merged shallowly: existing top-level keys win on conflict, so nested objects (e.g. `hooks`, `mcpServers`) you've customised are preserved as-is — but new nested entries from the template will be **dropped** rather than merged. On Ubuntu, settings.json is deep-merged with jq (existing wins).

---

## End-session-wiki SessionEnd hook

Both setup scripts prompt you near the end to register `scripts/hooks/end-session-wiki.{ps1,sh}` as a `SessionEnd` hook in `~/.claude/settings.json`. Before any write the script backs up `settings.json` to `~/.claude/settings.json.bak.YYYYMMDD-HHMMSS`. If `hooks.SessionEnd` is already populated the script asks Overwrite / Append / Skip. Skip the prompt entirely with the default (Both on Win11, Yes on Ubuntu) — only press other keys if you know what you want.

See [`docs/luna/end-session-wiki.md`](../../docs/luna/end-session-wiki.md) for opt-out + per-repo override.

---

## Caveman plugin (Win11 only)

After first launch of Claude Code (which triggers plugin pull), the script applies a `shell: true` patch to `caveman-shrink/index.js` automatically on the next run. If you skip the script step, apply manually:

```powershell
$f = "$env:USERPROFILE\.claude\plugins\marketplaces\caveman\src\mcp-servers\caveman-shrink\index.js"
(Get-Content $f -Raw).Replace("stdio: ['pipe', 'pipe', 'inherit'],`r`n  });", "stdio: ['pipe', 'pipe', 'inherit'],`r`n    shell: true,`r`n  });") | Set-Content $f -NoNewline
```

Must re-apply after every `git pull` in the caveman plugin directory.

---

## Manual steps after script completes

1. Fill `JIRA_API_TOKEN` in `<himmel>/.env`
2. Configure Atlassian MCP token in `~/.claude/settings.json`
3. Run `qmd embed` inside Claude Code (himmel project) to enable semantic search
4. Verify: `rtk --version`, `rtk gain`, `jira list`, `claude /obsidian-daily`
