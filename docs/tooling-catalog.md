# Tooling Catalog

All tools, scripts, plugins, skills, hooks, and integrations in active use. Includes Windows-specific notes.

---

## Claude Code

**What:** Anthropic's CLI for Claude. Core development environment.
**Config:** `~/.claude/settings.json`
**Key settings:**
- `statusLine.command` — shell command that renders the status bar
- `hooks` — PreToolUse, UserPromptSubmit, SessionStart hooks
- `enabledPlugins` — map of plugin IDs → enabled
- `extraKnownMarketplaces` — additional plugin registries beyond the official one

**Project-level override:** `.claude/settings.json` in any repo root overrides global settings for that project. Used for testing statusline changes without touching global config.

**Permission system:** `.claude/settings.json` carries `permissions.allow` and `permissions.deny` arrays for the project. `deny` takes precedence over `allow` — always blocks even if user requests it.

Key allow entries (project-level, `himmel`):
- `Bash(git fetch/pull/merge/rebase/stash/branch/push/worktree/cherry-pick/tag/remote *)` — common git ops
- `Bash(gh issue/run/workflow/release/auth *)` — gh subcommands beyond what's in settings.local.json
- `Bash(cp *)`, `Bash(mkdir -p *)` — common file ops

Key deny entries (always blocked):
- Force push: `git push --force*`, `git push -f *`, `git push --mirror*`, `git push --delete *`
- History rewrite: `git filter-branch *`, `git rebase -i *`
- Data loss: `git reset --hard *`, `git clean -f*`, `rm -rf /*`, `rm -rf ~*`
- Remote delete: `git push origin --delete *`, `gh repo delete *`, `gh release delete *`

---

## Plugins (claude-plugins-official marketplace)

All installed from the official Claude plugins marketplace.

| Plugin | What it does |
|--------|-------------|
| `superpowers` | Workflow skills: planning, TDD, subagent-driven development, git worktrees |
| `context7` | Fetches current library/framework docs on demand (MCP server) |
| `code-review` | Code review agent with severity-tagged findings |
| `code-simplifier` | Simplifies recently written code for clarity/maintainability |
| `skill-creator` | Creates new custom skills |
| `github` | GitHub integration (issues, PRs, repos) |
| `feature-dev` | Feature development workflow (explorer, architect, reviewer agents) |
| `claude-md-management` | Manages CLAUDE.md files across projects |
| `security-guidance` | Security analysis and guidance |
| `commit-commands` | Git commit helpers and conventions |
| `claude-code-setup` | Setup assistant for new Claude Code environments |
| `pr-review-toolkit` | PR review tools (code, tests, types, silent failures, comments) |
| `playwright` | Browser automation via Playwright MCP |
| `ralph-loop` | Autonomous loop execution |
| `typescript-lsp` | TypeScript language server integration |
| `pyright-lsp` | Python type checking via Pyright |

---

## Plugins (third-party marketplaces)

Installed via `extraKnownMarketplaces` in `settings.json`.

> **Staying current:** `bash scripts/check-plugin-drift.sh` (HIMMEL-322) reports
> upstream drift for every externally-sourced plugin himmel ships — the
> SHA-pinned remotes in `marketplace.json` (pin vs upstream HEAD) and the
> vendored forks (`UPSTREAM_PIN` sha vs the upstream file fetched via `gh api`).
> Fail-open when gh is absent; exit 2 on drift (cadence-armable). Run it on
> demand or arm it like `pipeline-cadence`.

### caveman (`JuliusBrussee/caveman`)

**What:** Terse response mode. Strips filler language (articles, pleasantries, hedging) from Claude's output. Three levels: lite / full / ultra.
**Toggle:** `/caveman lite|full|ultra` to switch, `stop caveman` to disable.
**Hooks:**
- `SessionStart` → `~/.claude/hooks/caveman-activate.js` — injects caveman ruleset into session context, writes active-flag file
- `UserPromptSubmit` → `~/.claude/hooks/caveman-mode-tracker.js` — tracks current mode level across turns
**Config:** `~/.claude/hooks/caveman-config.js`
**Statusline integration:** `~/.claude/hooks/caveman-statusline.sh` (separate from main statusline)

### qmd (`tobi/qmd`)

**What:** Local search engine over markdown documents. BM25 keyword search (lex), semantic vector search (vec), and hypothetical document search (hyde).
**MCP server:** `plugin:qmd:qmd` — exposes `query`, `get`, `multi_get`, `status` tools.
**Usage:** Searching local knowledge base, notes, docs.

### claude-obsidian (plugin)

**What:** Obsidian vault companion skills — setup, scaffolding, wiki management, ingestion, search.
**Skills:**

| Skill | Trigger | Purpose |
|-------|---------|---------|
| `claude-obsidian:wiki` | `/wiki`, "set up wiki", "obsidian vault", "second brain" | Bootstrap vault, scaffold structure, check state |
| `claude-obsidian:wiki-ingest` | "ingest", "batch ingest", multiple files | Parallel ingestion of sources into vault |
| `claude-obsidian:wiki-lint` | "lint the wiki", "health check", "find orphans" | Vault health audit |
| `claude-obsidian:save` | "save to vault", "add this to obsidian" | Save conversation content to vault |
| `claude-obsidian:canvas` | "create canvas", "visualize as canvas" | Build Obsidian canvas files |
| `claude-obsidian:autoresearch` | "research and save", "research into vault" | Research + auto-save to vault |
| `claude-obsidian:wiki-query` | "query the wiki", "search vault" | Search across vault |

**MCP server:** `obsidian-vault` (uvx mcp-obsidian) — tools: `list_files_in_vault`, `get_file_contents`, `append_content`, `patch_content`, `simple_search`, `complex_search`, `delete_file`, `get_periodic_note`, `get_recent_changes`

---

### obsidian-second-brain (external, manual install)

**Repo:** `eugeniughelbur/obsidian-second-brain`
**Install path:** `~/.claude/plugins/obsidian-second-brain/` (cloned)
**Skill link:** `~/.claude/skills/obsidian-second-brain`
**Commands:** 33 slash commands installed to `~/.claude/commands/`
**Version:** v0.8 (May 2026) | **Installed:** 2026-05-16
**Update:** `git pull` in `~/.claude/plugins/obsidian-second-brain/`
**Research toolkit:** disabled (needs XAI + Perplexity API keys — re-run install.sh to enable)

**Commands:**

| Command | Purpose | Category |
|---------|---------|---------|
| `/obsidian-init` | Generate vault `_CLAUDE.md`, `index.md`, `log.md` | Setup |
| `/obsidian-save` | Extract vault-worthy items from conversation | Core |
| `/obsidian-daily` | Create/update today's daily note | Core |
| `/obsidian-log` | Log a work or dev session | Core |
| `/obsidian-task` | Add tasks to kanban boards | Core |
| `/obsidian-person` | Create/update person notes | Core |
| `/obsidian-project` | Create/update project notes | Core |
| `/obsidian-find` | Search vault for notes | Core |
| `/obsidian-capture` | Quick capture to inbox | Core |
| `/obsidian-recap` | Summarize recent vault activity | Review |
| `/obsidian-review` | Review a note or area | Review |
| `/obsidian-board` | Update kanban boards | Review |
| `/obsidian-decide` | Log a decision | Review |
| `/obsidian-adr` | Architecture Decision Record | Review |
| `/obsidian-learn` | Log learning (book, course, concept) | Review |
| `/obsidian-export` | Export vault content | Utility |
| `/obsidian-world` | World/external context notes | Utility |
| `/obsidian-health` | Vault audit — orphans, dead links | Maintenance |
| `/obsidian-synthesize` | Auto-detect cross-vault patterns | Maintenance |
| `/obsidian-reconcile` | Find and resolve contradictions | Maintenance |
| `/obsidian-ingest` | Ingest a source into vault | Maintenance |
| `/obsidian-visualize` | Visualize vault relationships | Thinking |
| `/obsidian-challenge` | Red-team ideas against vault history | Thinking |
| `/obsidian-emerge` | Surface unnamed patterns from recent notes | Thinking |
| `/obsidian-connect` | Bridge unrelated domains | Thinking |
| `/obsidian-graduate` | Promote idea fragments into full projects | Thinking |
| `/research` | Web research with citations → vault | Research |
| `/research-deep` | Deep multi-source research → vault | Research |
| `/x-read` | Analyze X posts | Research |
| `/x-pulse` | X trend analysis | Research |
| `/notebooklm` | Source-grounded vault research (Gemini) | Research |
| `/youtube` | Extract and summarize YouTube videos | Research |
| `/create-command` | Interview flow to create new vault command | Meta |

---

### obsidian-skills (`kepano/obsidian-skills`)

**What:** Skills for working with Obsidian vaults — reading notes, searching, creating entries.

### warp (`warpdotdev/claude-code-warp`)

**What:** Warp terminal integration for Claude Code.

### himmel (local directory marketplace)

**Source:** `<himmel-path>/marketplace/` (typically `C:\Users\<user>\Documents\github\himmel\marketplace\`)
**Registered via:** `extraKnownMarketplaces.himmel` in `~/.claude/settings.json`
**Plugins:**

#### handover (`handover@himmel`)

**What:** Session handover and work tracking system for Claude Code. Operationalizes `handovers/<USER_SLUG>/` via a skill.
**Skill:** `handover:handover` — invoke with phrases like "new epic", "new task", "end session", "update status"
**Skill file:** `marketplace/plugins/handover/skills/handover/SKILL.md`
**Commands:**

| Command | What it does |
|---------|-------------|
| `new-epic <name>` | Creates epic dir with all 7 files from templates, increments counter |
| `new-task <epic-id> <name>` | Creates task dir, updates epic master-plan + context |
| `new-standalone <name>` | Creates standalone dir with brief/bugs/reviewer-notes |
| `update-status` | Regenerates `status.md` by scanning current epic/standalone dirs |
| `end-session [id]` | Creates `next-session-N.md` (sequential, never overwrites) with cold-start prompt |

**Session files:** `next-session-1.md`, `next-session-2.md` ... (append-only, highest = latest).
**Tracking root:** `handovers/<USER_SLUG>/` — all state is versioned markdown.

#### obsidian-triage (`obsidian-triage@himmel`)

**What:** Batch tooling for luna vault maintenance — harvest, triage, dedup, enrich, component-scan, and the telegram ingestion entry point. Skills invoke tools in `marketplace/plugins/obsidian-triage/tools/`.
**Skills:** `obsidian-triage:luna-ingest`, `obsidian-triage:harvest-clips`, `obsidian-triage:triage-clips`, `obsidian-triage:synthesize-clips`, `obsidian-triage:archive-clips`, `obsidian-triage:telegram-clip`, `obsidian-triage:roadmap-clips`

| Tool | What it does |
|------|-------------|
| `component-scan.mjs` | LUNA-57. gh-API deep repo component scanner for `luna-ingest --deep`. Inventories skills/commands/agents/tools/plugin manifests; upserts a cross-repo-deduped `30-Resources/Components/` library. No clone — gh tree + raw reads only. |
| `telegram-clip.mjs` | LUNA-58. Telegram → `Clippings/` ingestion entry point. Maps one message (text / bare URL / forward) to a LUNA-2 Web-Clipper-shaped clip note so `harvest-clips` ingests it; classifies by URL host, preserves sender/ts/msg-id provenance, idempotent per message-id. Pure Node, no runtime deps (the test uses the vendored `js-yaml`). |
| `roadmap-aggregate.mjs` | LUNA-59. Read-only cross-source roadmap-item aggregator for `roadmap-clips`. Scans daily-note action items, `_deferred.md` backlog, synthesis proposals, promotion candidates, and the component inventory; emits a JSON item inventory the skill clusters into a sequenced 60-Maps roadmap. Pure Node, no runtime deps. |

#### luna-correlate (`luna-correlate@himmel`)

**What:** Offline health-factor correlation MCP. Correlates personal health series (sleep, HRV, resting HR) against public environmental factors (geomagnetic Kp, lunar phase, daylight hours) and a gated country-level grid fetcher for location factors (barometric pressure, pollen, PM2.5 air quality). Boundary B+C: only `factors.cache` touches the network; all joins and computations are offline. Outputs are candidate signals only — never a diagnosis, never causation.

**M3 operator-facing tool:** `signals.dashboard` — lag-swept (±3 days default), best-lag-per-pair, Benjamini-Hochberg FDR-controlled (q=0.1) analysis over device series × factors. Writes `dashboard.md` + `dashboard.json` to `LUNA_SIGNALS_DIR` (must be set; luna-medic `60-Signals/` by convention).

**MCP tools:** `factors.cache` (network, gated), `series.load`, `correlate`, `signals.report`, `signals.dashboard` (all offline).
**Offline factors:** `kp` (GFZ Potsdam, CC BY 4.0), `lunar_phase` (astronomical formula, zero network), `daylight` (bbox-centroid latitude, zero network). Location factors (`pressure`, `pollen`, `aq`) via Open-Meteo, opt-in via `LUNA_REGION_BBOX`.
**Plugin path:** `marketplace/plugins/luna-correlate/`

---

## Hooks

Defined in `~/.claude/settings.json`. Run as shell commands at specific Claude Code lifecycle events.

### PreToolUse — RTK hook (via guard wrapper)

```
bash "<himmel>/scripts/hooks/rtk-hook-guard.sh"
```
Runs before every `Bash` tool call. Delegates to `rtk hook claude`, which
rewrites commands transparently for token savings — EXCEPT `find` commands
carrying compound predicates (`-not`/`-exec`/`-o`/`!`/parens): those pass
through unrewritten because `rtk find` rejects them at runtime (HIMMEL-241).

### UserPromptSubmit — Caveman mode tracker

```
node ~/.claude/hooks/caveman-mode-tracker.js
```
Tracks the active caveman mode level across turns. Injects current mode into context so it persists across compaction.

### SessionStart — Caveman activator

```
node ~/.claude/hooks/caveman-activate.js
```
On every new session: writes `~/.claude/.caveman-active` flag, emits the full caveman ruleset as hidden session context. Ensures mode is active from turn 1.

---

## claude-statusline (vendored, HIMMEL-331)

**Vendored in himmel:** `scripts/statusline/` (`bin/statusline.sh`, `test/`, `LICENSE`, `README.md`, provenance in `VENDORED.md`).
**Config:** `~/.claude/settings.json` → `statusLine.command` (machine-setup points it at `<himmel-path>/scripts/statusline/bin/statusline.sh` — no external clone).
**What:** Bash script receiving Claude Code session JSON via stdin, outputs formatted status bar.

Displays: model, context %, git branch, rate-limit bars (current/weekly/extra), cache TTL countdown, per-session and all-sessions cache read/write/hit/savings.

**Source fork:** `yotamleo/claude-statusline` (fork of `nilbuild/claude-statusline`) — kept as upstream-tracking source; edits to the vendored script are pushed back to the fork so both mirror.
**Patch applied:** `docs/patches/2026-05-16-cache-statusline.md`
**Upstream:** `nilbuild/claude-statusline` (PR not yet opened)

---

## Superpowers (plugin: `superpowers@claude-plugins-official`)

**What:** Workflow orchestration skills. Invoked via `/skill` tool.

Key skills used:

| Skill | When to use |
|-------|-------------|
| `superpowers:writing-plans` | Before implementation — creates step-by-step plan with full code |
| `superpowers:subagent-driven-development` | Executes a plan via fresh subagent per task + 2-stage review |
| `superpowers:using-git-worktrees` | Ensures all feature work is in a worktree, never on main |
| `superpowers:executing-plans` | Inline plan execution (alternative to subagent-driven) |
| `superpowers:finishing-a-development-branch` | Wraps up a feature branch after all tasks complete |

Plans saved to: `docs/superpowers/plans/YYYY-MM-DD-feature.md`
Specs saved to: `docs/superpowers/specs/YYYY-MM-DD-feature.md`

---

## RTK (Rust Token Killer)

**What:** Token-efficient CLI proxy. Intercepts common commands and strips irrelevant output before it enters Claude's context.
**Usage:** `rtk git status`, `rtk git add`, etc.
**Savings:** 60–90% token reduction on dev operations.
**Auto-rewriting:** Requires `rtk init -g` to install the shell hook. Without it, prefix commands manually with `rtk`.
**Verify:** `rtk gain` — shows token savings analytics.
**Note:** Name collision risk — `reachingforthejack/rtk` (Rust Type Kit) is a different tool. If `rtk gain` fails, check which binary is installed.
**Reconcile after a standalone `rtk init -g` (HIMMEL-399):** `rtk init -g` appends a bare `rtk hook claude` entry without checking for an existing one, so running it outside full machine-setup can stack duplicates. himmel swaps that bare entry for the `rtk-hook-guard.sh` wrapper (HIMMEL-241). The full machine-setup scripts run `rtk init -g` once and reconcile inline; for an on-demand reconcile run `bash scripts/lib/reconcile-rtk-hook.sh ~/.claude/settings.json <himmel-path>` — idempotent + duplicate-safe (collapses to exactly one guard entry). Reconcile **user scope only** (`~/.claude/settings.json`): `rtk init -g` is global and the guard is an absolute path, so a project-scope copy would just double-fire the hook.
**Expected banner noise:** after the guard swap, `rtk init --show` reports `Hook: not found` and every rewritten command prints `[rtk] /!\ No hook installed — run rtk init -g` to stderr. This is benign: rtk detects its hook by its own `rtk hook claude` signature, which the guard wrapper replaces by design. The guard IS installed and rewriting works; rtk exposes no flag/config to quiet the banner (an upstream limitation). Not a real missing-hook signal — do not "fix" it by re-running `rtk init -g` (that just re-adds the bare entry).

---

## context7 (plugin: `context7@claude-plugins-official`)

**What:** MCP server that fetches current, accurate documentation for libraries and frameworks on demand. Avoids stale training data for fast-moving APIs.
**MCP tools:** `resolve-library-id`, `query-docs`
**When Claude uses it:** Any question about a library, framework, SDK, CLI tool, or cloud service — even well-known ones.

---

## Playwright (plugin: `playwright@claude-plugins-official`)

**What:** MCP server for browser automation. Lets Claude navigate, click, fill forms, take screenshots, execute JS in a real browser.
**MCP tools:** `browser_navigate`, `browser_click`, `browser_fill_form`, `browser_snapshot`, `browser_take_screenshot`, etc.

---

## jq

**What:** JSON processor. Used in `statusline.sh` for parsing session JSON and transcript JSONL files.
**Windows:** Available via Git Bash. Works identically to Linux.

---

## Git Bash (MSYS2)

**What:** Bash environment on Windows. All shell scripts run here.
**Home path:** `/c/Users/<user>` (POSIX style) = `C:\Users\<user>` (Windows style).
**Rule:** Always use POSIX paths in bash scripts. Never mix backslashes.

---

## gh (GitHub CLI)

**What:** GitHub operations from terminal.
**Used for:** Forking repos, creating/merging PRs, branch verification, repo inspection.

---

## CR Scripts (`scripts/cr/`)

Shell scripts that implement `/pr-check` sub-steps. Called by the `/pr-check` command; not invoked standalone in normal workflows.

- `scripts/cr/file-deferred-issues.sh` — reads `/pr-review-toolkit:review-pr` output, dedupes low-severity findings by content hash, and files them as GitHub issues tagged `cr-deferred`. Called by `/pr-check` step 7. Idempotent; `--dry-run` mode for inspection.
- `scripts/cr/gemini-first-pass.sh` — gemini first-pass CR reviewer (HIMMEL-270): diff on stdin → findings in the /pr-check heading contract with stable `[gemini-N]` IDs; called by `/pr-check` step 3.0. Tests: `scripts/cr/test-gemini-first-pass.sh` (deterministic, PATH-stubbed fake gemini).

---

## Windows gotchas

Bugs encountered and fixes applied when running bash scripts on Windows via Git Bash.

### 1. `set -f` disables glob expansion globally

**Script:** `bin/statusline.sh` line 2: `set -f`
**Effect:** All glob patterns treated as literal strings. `cat "$HOME/.claude/projects"/*/*.jsonl` passes the literal `*/*.jsonl` to cat → no files → jq returns 0.
**Fix:** Wrap glob with `set +f` / `set -f`:
```bash
set +f
stats=$(cat "$HOME/.claude/projects"/*/*.jsonl 2>/dev/null | ...)
set -f
```
**File:** `bin/statusline.sh`, `read_all_sessions_cache_stats()`

---

### 2. `((VAR++))` fails under `set -e` when VAR=0

**Context:** Bash arithmetic `((VAR++))` exits with code 1 when the result is 0 (before the increment). `set -e` kills the script.
**Reproduces:** `set -e; PASS=0; ((PASS++))` — exits immediately.
**Fix:** `VAR=$(( VAR + 1 ))` instead of `((VAR++))`.
**File:** `test/test_cache.sh` — all counter increments.

---

### 3. `date -d` / `date -r` cross-platform divergence

**Context:** Converting ISO 8601 timestamps to Unix epoch.
- Linux/Git Bash: `date -d "2026-05-16T15:04:31Z" +%s`
- macOS/BSD: `-d` not supported; different invocation needed
**Fix:** Try Linux form first, fall back with `||`. The original script already had this; replicated in tests.

---

### 4. `stat` mtime flag differs by platform

**Context:** Checking cache file age for the 30s TTL.
- Linux: `stat -c %Y file`
- macOS: `stat -f %m file`
**Fix:**
```bash
cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
```

---

### 5. Home path format

`$HOME` in Git Bash = `/c/Users/<user>`. Windows tools expect `C:\Users\<user>`.
**Rule:** All bash scripts use POSIX paths. Claude Code's `transcript_path` field uses `/c/` prefix.

---

### 6. Testing statusline without touching global config

`statusLine` in `~/.claude/settings.json` is global. To test a new script in isolation, create `.claude/settings.json` in the feature worktree:
```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"C:/path/to/test/bin/statusline.sh\""
  }
}
```
Claude Code picks up project-level settings when opened from that directory.

---

### 7. `eval "$(sed ...)"` for sourcing partial script in tests

`statusline.sh` starts with `input=$(cat)` which blocks stdin if sourced directly.
**Fix:** Extract only the cache functions section with `sed` + `eval`:
```bash
eval "$(sed -n '/^# ── Cache metrics functions/,/^# ── End cache metrics functions/p' "$STATUSLINE")"
if ! declare -f format_tokens >/dev/null 2>&1; then
    echo "ERROR: failed to source cache functions" >&2; exit 1
fi
```
Guard after `eval` catches silent failures if section markers are renamed.
