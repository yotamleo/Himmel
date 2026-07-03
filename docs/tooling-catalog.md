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

> **Boundary ownership:** which optimizer owns which token boundary (rtk vs
> caveman vs MCP-output vs cache vs routing) is governed by
> [`docs/token-economy.md`](token-economy.md) (HIMMEL-654 WS6) — one
> optimizer per boundary; adoption changes gate on a measured real-session
> delta.

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
**Skills:** `obsidian-triage:luna-ingest`, `obsidian-triage:telegram-clip`, `obsidian-triage:roadmap-clips`, `obsidian-triage:luna-upgrade`, `obsidian-triage:luna-upgrade-all`, `obsidian-triage:luna-vitals-extract`, `obsidian-triage:vault-lint` (the clipper-pipeline stages — harvest/triage/synthesize/archive — are slash **commands**, listed in [`commands-catalog.md`](commands-catalog.md), not SKILL.md-backed skills)

| Tool | What it does |
|------|-------------|
| `component-scan.mjs` | LUNA-57. gh-API deep repo component scanner for `luna-ingest --deep`. Inventories skills/commands/agents/tools/plugin manifests; upserts a cross-repo-deduped `30-Resources/Components/` library. No clone — gh tree + raw reads only. |
| `telegram-clip.mjs` | LUNA-58. Telegram → `Clippings/` ingestion entry point. Maps one message (text / bare URL / forward) to a LUNA-2 Web-Clipper-shaped clip note so `harvest-clips` ingests it; classifies by URL host, preserves sender/ts/msg-id provenance, idempotent per message-id. Pure Node, no runtime deps (the test uses the vendored `js-yaml`). |
| `roadmap-aggregate.mjs` | LUNA-59. Read-only cross-source roadmap-item aggregator for `roadmap-clips`. Scans daily-note action items, `_deferred.md` backlog, synthesis proposals, promotion candidates, and the component inventory; emits a JSON item inventory the skill clusters into a sequenced 60-Maps roadmap. Pure Node, no runtime deps. |
| `clip-lookup.mjs` (+ `clip-lookup-cli.mjs`, `is-thin-cli.mjs`) | LUNA-78. Single source of truth for *"is this URL already harvested (and enriched) in the vault?"* — filesystem-only canonical-URL/status-id match plus a per-type `isThinClipBody` thinness predicate. `telegram-clip.mjs` (`alreadyFiledByUrl`) and `dedup-sweep.mjs` (`indexVault`) derive their URL key from it; `/read-link` and `harvest-clips` shell out to the CLIs. No vault → returns `null` (never throws), so callers degrade to live fetch. Pure Node, no runtime deps. |

#### luna-correlate (`luna-correlate@himmel`)

**What:** Offline health-factor correlation MCP. Correlates personal health series (sleep, HRV, resting HR) against public environmental factors (geomagnetic Kp, lunar phase, daylight hours) and a gated country-level grid fetcher for location factors (barometric pressure, pollen, PM2.5 air quality). Boundary B+C: only `factors.cache` touches the network; all joins and computations are offline. Outputs are candidate signals only — never a diagnosis, never causation.

**M3 operator-facing tool:** `signals.dashboard` — lag-swept (±3 days default), best-lag-per-pair, Benjamini-Hochberg FDR-controlled (q=0.1) analysis over device series × factors. Writes `dashboard.md` + `dashboard.json` to `LUNA_SIGNALS_DIR` (must be set; a salus vault's `60-Signals/` by convention).

**MCP tools:** `factors.cache` (network, gated), `series.load`, `correlate`, `signals.report`, `signals.dashboard` (all offline).
**Offline factors:** `kp` (GFZ Potsdam, CC BY 4.0), `lunar_phase` (astronomical formula, zero network), `daylight` (bbox-centroid latitude, zero network). Location factors (`pressure`, `pollen`, `aq`) via Open-Meteo, opt-in via `LUNA_REGION_BBOX`.
**Plugin path:** `marketplace/plugins/luna-correlate/`

#### himmel-ops (`himmel-ops@himmel`)

**What:** Harness-meta operational skills for himmel.
**Skills:** `himmel-ops:stuck-playbook` (load-on-trigger guardrail-recovery playbook, HIMMEL-211), `himmel-ops:minerva` (brainstorm→critic→spec→critic→plan pipeline with adversarial critic loops, HIMMEL-428), `himmel-ops:vm` (lean-invoke VM lifecycle + e2e runbook, HIMMEL-491/493), `himmel-ops:memory-compound` (lean-invoke auto-memory→vault compaction with a qmd findability gate, HIMMEL-569).
**Commands:** `/minerva` — runs the minerva pipeline; `/memory-compound` — runs the auto-memory compaction pass.
**Hook:** `hooks/hooks.json` wires a PreToolUse(`matcher: "Skill"`) hook `inject-minerva-critic.sh` (HIMMEL-429) — injects the minerva critic loop when `superpowers:brainstorming`/`writing-plans` fires without `/minerva`. Advisory, fail-open; kill switch `MINERVA_HOOK_DISABLE=1`.
**Plugin path:** `marketplace/plugins/himmel-ops/`

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

**Node resolution (macOS/Linux):** a GUI-launched session has no `node` on PATH,
so this hook is wired through `scripts/lib/run-node.sh` (a runtime launcher that
resolves node every call via `scripts/lib/resolve-node.sh` — PATH → homebrew →
newest nvm/fnm → Windows install dir, `sort -V` so never a stale EOL node — and
fail-opens silently if none, instead of erroring every session). `ubuntu.sh` and
`scripts/lib/wire-caveman-node.sh` (the idempotent heal helper, also used by
`/himmel-doctor --fix`) install the wrapper form; win11.ps1 keeps the stable
absolute Windows path. See `/himmel-doctor` (C1).

---

## himmel-doctor (`scripts/himmel-doctor.sh`)

The `/himmel-doctor` diagnostic. Read-only except `--fix`. Checks: C1 node/caveman
SessionStart wiring (+ `--fix` heal), C2 shadowed claude-obsidian, C3 dirty
single-writer luna vault, C4 Bitbucket-remote-where-`gh`-fails, C5 repo not in the
handover registry, C6 PATH-fragile bare-interpreter MCP servers (uvx/bun — same
GUI-launch failure class as the node hook), C7 lingering merged-PR worktrees, C8
stale pipeline-cadence runners, C9 auto-arm scheduler backend (HIMMEL-594 — reads
`scripts/lib/scheduler-backend.sh`; never sudos), C10 private→public propagation
drift (HIMMEL-640 — read-only advisory; surfaces MISSING/DRIFT/REVERSE-LEAK
between the private mirror and the public clone; skips cleanly on adopter clones).
Prints a severity-grouped report (FAIL/WARN/INFO); `--file-issue
[--repo owner/name]` files ONE deduped consolidated public GitHub issue (resolves
the repo from `--repo` → `$HIMMEL_DOCTOR_ISSUE_REPO` → github origin). Exit 1 on any
FAIL. Tests: `scripts/test-himmel-doctor.sh`, `scripts/lib/test-{resolve,run,wire-caveman}-node.sh`.

---

## auto-arm scheduler backend (`scripts/lib/scheduler-backend.sh`, HIMMEL-594)

Pure, sourceable, bash-3.2-safe detection/remediation lib whose status mirrors
what `arm-resume.sh` actually selects (windows=schtasks, linux=`at`+atd else
crontab, macos=crontab) so the usage-cap auto-resume can't silently no-op on a
missing/dead backend. `scheduler_backend_os` / `_status` (`ok|ok-cron|disabled|
missing`) / `_remediation`. Consumed by `/himmel-doctor` C9 and the installers.
Enable lives in installers (needs sudo): `ubuntu.sh` installs+enables `at`/atd;
**`scripts/machine-setup/macos.sh`** (ALPHA, unvalidated — adopters validate +
file issues) wires the statusline + auto-arm hook + verifies crontab, reusing the
idempotent `scripts/lib/register-auto-arm-hook.sh`. Tests:
`scripts/lib/test-scheduler-backend.sh`, `scripts/machine-setup/test-macos.sh`,
`scripts/lib/test-register-auto-arm-hook.sh`, macOS cases in `scripts/handover/test-arm-resume.sh`.

---

## claude-statusline (vendored, HIMMEL-331)

**Vendored in himmel:** `scripts/statusline/` (`bin/statusline.sh`, `test/`, `LICENSE`, `README.md`, provenance in `VENDORED.md`).
**Config:** `~/.claude/settings.json` → `statusLine.command` (machine-setup points it at the himmel wrapper `<himmel-path>/scripts/where-are-we/statusline.sh`, which composes this vendored `bin/statusline.sh` + a where-are-we line — active handover + epic progression, HIMMEL-538; the segment is default-ON since HIMMEL-556 — opt out with an explicit falsy `HIMMEL_WHERE_ARE_WE` (`0|false|off|no`); no external clone).
**What:** Bash script receiving Claude Code session JSON via stdin, outputs formatted status bar.

Displays: model, context %, git branch, rate-limit bars (current/weekly/extra), cache TTL countdown, per-session and all-sessions cache read/write/hit/savings.

**Source fork:** `yotamleo/claude-statusline` (fork of `nilbuild/claude-statusline`) — kept as upstream-tracking source; edits to the vendored script are pushed back to the fork so both mirror.
**Patch applied:** `docs/patches/2026-05-16-cache-statusline.md`
**Upstream:** `nilbuild/claude-statusline` (PR not yet opened)

---

## claude-glm (`scripts/claude-glm`, `.ps1` twin, HIMMEL-665)

**What:** Thin launcher that runs Claude Code against the Z.ai GLM
Anthropic-compatible endpoint instead of the Anthropic API — a flat-rate
**overflow lane** for when the Anthropic usage cap is hit. This buys *overflow
capacity on a flat subscription*, **not** per-token savings: the GLM lane is not
metered per token, so the framing is "keep working past the cap", never
"cheaper tokens".

**Env contract (7 vars, set for the child `claude` only):**

| Var | Value |
|---|---|
| `ANTHROPIC_BASE_URL` | `https://api.z.ai/api/anthropic` |
| `ANTHROPIC_AUTH_TOKEN` | `$ZAI_API_KEY` |
| `ANTHROPIC_MODEL` | `glm-5.2` |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `glm-4.7` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `glm-5.2` |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `glm-5.2` |
| `CLAUDE_CONFIG_DIR` | `$HOME/.claude-glm` |

**Key resolution:** shell env `ZAI_API_KEY` first, else the himmel repo `.env`
(bash via `load-dotenv.sh --root <himmel>`, PS via an inline reader) — pinned to
the *launcher's* repo, not the cwd, so a session running in the luna vault still
finds the key. Missing key → **exit 2**. Never read from `settings.json`.

**Isolated config dir (`$HOME/.claude-glm`):** seeded from `~/.claude` on first
launch (or `--reseed`/`-Reseed`) by an allowlist copy — `settings.json`
(sanitized via node: the `model` key + every `env.ANTHROPIC_*` stripped so they
don't fight the launcher's env), `CLAUDE.md`, `RTK.md`,
`commands`/`skills`/`hooks`/`agents`, and the plugin registry
(`installed_plugins.json`, `known_marketplaces.json`, `marketplaces/`). **Never
copied:** `.credentials.json`, history. Plugin caches resolve through the
absolute `installPaths` in the seeded registry — no install step.
**Seeding is transactional:** a `.seeded` sentinel is written *last*, so any
copy/sanitize failure (e.g. `node` missing/broken) aborts with **exit 4** — a
loud refusal that launches nothing and writes no sentinel, and the next launch
re-seeds (self-heal) rather than running against a half-populated, unsanitized
dir. A failed `--reseed`/`-Reseed` first clears the stale sentinel, so it can't
mask the failure and leave the next plain launch on the stale tree.

**Tiered egress guard (gates the LAUNCH cwd only):**
- **PHI tier** — a `.salus` marker file in cwd, or cwd under any `phi-roots`
  line → **REFUSED, exit 3, no override.** PHI never goes to a cloud GLM backend.
- **Denylist tier** — cwd under any `egress-denylist` line → refused (exit 3)
  **unless** `--force`/`-Force`, which proceeds after a stderr warning that
  content WILL be sent to Z.ai.
- Config at `~/.config/claude-glm/{phi-roots,egress-denylist}`, one path per
  line (trailing CR + trailing slash tolerated; blank lines skipped — a
  block-everything lone `/` root is not supported). A guard config that *exists
  but is not a readable regular file* (e.g. a directory) never silently allows
  egress: bash refuses with **exit 3**; the PS twin fails closed via a
  terminating error (exit 1).
- **Limitation — launch-scope only:** the guard checks the cwd *at launch*. A
  session that later `cd`s into a PHI-marked or denylisted directory is **not**
  re-checked. Launch from the right place.

**Flags must LEAD:** launcher flags (`--reseed`/`--force`, `-Reseed`/`-Force`)
must come **before** any `claude` args; the first non-flag argument stops flag
parsing and everything from there passes to `claude` verbatim. (The PS twin is
deliberately a plain script with no `param()` block, so real claude flags like
`-p`/`-d`/`-v` aren't hijacked by PowerShell's automatic parameter binding.)

**Off-peak annotation:** an advisory stderr line notes whether you're inside the
GLM peak window (14:00–18:00 UTC+8); advisory only, changes no behavior.

**Setup:** `ZAI_API_KEY` sourcing + the `.salus` PHI marker are covered in
[`docs/setup/new-machine.md`](setup/new-machine.md) §1 and §4d.

**Acceptance:** the hermetic launcher tests in
`scripts/test-claude-glm.{sh,ps1}` cover the key gate, the seeder, and the
PHI/egress guards against a mock `claude`; only the live-backend acceptance leg
is manual — the **HIMMEL-665 Task 8 checklist**.

---

## claude-routed + omniroute-config-lint (`scripts/claude-routed`, `scripts/omniroute-config-lint`, `.ps1` twins, HIMMEL-666)

**What:** the WS2 OmniRoute-pilot wiring pair. `claude-routed` is a
copy-and-edit variant of `claude-glm` (the WS1 extensibility seam): identical
PHI/egress guard, config-dir seeding, flag handling and exit codes — only the
backend block differs. It points Claude Code at the LOCAL loopback OmniRoute
router (`ANTHROPIC_BASE_URL=http://127.0.0.1:$OMNIROUTE_PORT`, default port
`20128`; host fixed — the router is loopback-only by charter), authenticates
with a router-issued client key `OMNIROUTE_API_KEY` (shell env first, else the
himmel repo `.env`; the Z.ai key never appears in this launcher), keeps the
GLM tier-alias mapping (`glm-5.2`/`glm-4.7`), and seeds its own isolated
`$HOME/.claude-routed`. Guard config is **deliberately shared** with
claude-glm at `~/.config/claude-glm/{phi-roots,egress-denylist}` — one guard
source of truth across launcher lanes. A bare `ANTHROPIC_BASE_URL` export is
not acceptable wiring; the launcher IS the wiring.

`omniroute-config-lint` is WS2 guardrail 1 (WS6 dedup invariant — one
optimizer per boundary): a **positive assertion** over the authoritative
engine-key set from the HIMMEL-666 Task-1 source-read (OmniRoute pin
`b729a8f`, v3.8.43). It reads an exported pilot-config JSON (`compression`
object + top-level `autoRoutingEnabled`) and FAILs loudly, one line per
offending key, when any expected key is missing (default-ON engines must
never pass as "nothing enabled found"), any entry is enabled, any unknown
key appears inside `compression` (a renamed engine can't sneak in;
`optimization` = SQLite tuning, excluded), or the free-lane switch
`autoRoutingEnabled` is not explicitly `false`. Exit codes: 0 PASS / 1
findings / 2 usage-or-unparseable.

**Status:** the router deploy itself (HIMMEL-666 Task 2) is operator-gated
(per-token lane decision) — these artifacts are built-and-tested ahead of it;
the lint has NOT yet approved a real deployed config (plan Task 3 Step 4
pending deploy).

**Acceptance:** hermetic twin suites `scripts/test-claude-routed.{sh,ps1}`
(mock `claude`; guard red paths incl. `.salus` refusal surviving the variant)
and `scripts/test-omniroute-config-lint.{sh,ps1}` (fixture matrix incl. the
omitted-key and unknown-key red paths).

---

## spawn-glm (`scripts/telegram/spawn-glm.ts`, HIMMEL-654)

**What:** Poller-free CLI that spawns an unattended GLM-lane Claude worker for
the offload loop (spawn → inspect → validate → push-by-validator). It creates a
fresh git worktree + `glm/<slug>` branch, resolves the GLM env block
(`glm-env.ts` — `ZAI_API_KEY` from shell env or the himmel repo `.env`, launcher
-parity `ANTHROPIC_*` vars), runs the D2 egress guard (`glm-guard.ts`), composes
the worker prompt with minted `outbox.jsonl` / `context.md` paths, and drives
the run through the `runSession(…, lane:"glm")` seam in `run.ts`. GLM runs pin
`--model opus` (→ `glm-5.2`) and ignore `TELEGRAM_CLAUDE_MODEL`. Sessions live
under `<BRIDGE_ROOT>/glm-sessions/` (default `~/.claude/handover/bridge/`) —
**outside** the poller's `sessions/` tree, so nothing here is double-spawned or
Telegram-flushed. Full loop, permission guidance, and honest enforcement
inventory in [`docs/glm-offload.md`](glm-offload.md).

```
bun scripts/telegram/spawn-glm.ts "<prompt>" [--cwd <dir>] [--name <slug>] [--timeout-mins <n>] [--permission-mode <mode>]
```

Prints exactly three inspect-contract lines on exit: `session-dir:`,
`transcript-dir:` (`~/.claude/projects/<escaped-worktree-cwd>/`), `exit:`.
Exit codes: **2** usage error / plan refusal (non-himmel cwd, settings
conflict, missing ZAI key); **3** guard refusal (PHI marker, phi-root, denylist,
unreadable guard config); **1** operational failure; else the worker's exit code.

**Status:** offload-spike artifact. The default-path push block
(`extensions.worktreeConfig` + `remote.origin.pushurl=DISABLED-glm-quarantine`)
is a **tripwire, not a wall** — a `bypassPermissions` worker inherits operator
git credentials via the shared `~/.claude`; the load-bearing control is the CR
gate (no GLM branch merges except by the validating session). D2 guards are
dormant-by-construction in v1 (himmel-worktree cwd scope). Uses GLM flat-rate
Coding-Plan quota, sanctioned by the operator directive — the per-token block
gates the WS2 router only, not this direct-CLI lane.

**Acceptance:** bun unit suite in the telegram bridge (guard red paths, env
builder block + missing-key throw + quote-strip, `runSession` lane env merge
with argv shape unchanged, GLM model pin ignoring `TELEGRAM_CLAUDE_MODEL`,
settings-conflict preflight, worktree pushurl poison, prompt composition
embedding the minted session paths); the live GLM-lane acceptance + offload-loop
legs are recorded in [`docs/glm-offload.md`](glm-offload.md).

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

## Pre-commit Hook Scripts (`scripts/hooks/`)

Shell scripts that run as pre-commit / pre-push gates (wired in `.pre-commit-config.yaml`). Full detail and rc contracts in `docs/internals/enforcement.md`.

- `scripts/hooks/check-doc-guard.sh` — **doc-guard gate** (himmel-dev only, HIMMEL-454). Blocks committing a new command or skill file (`.claude/commands/**`, `marketplace/plugins/*/{commands,skills}/**`) without also touching `docs/commands-catalog.md`. Added-files-only (`--diff-filter=A`); modifications don't trigger it. Gated behind `.himmel-dev` marker at repo root — absent → exit 0 (adopters unaffected). rc: 0 pass | 1 violation | 2 fail-closed. Bypass: `DOC_GUARD_OK=1`. `.ps1` twin: `scripts/hooks/check-doc-guard.ps1`. Smoke test: `scripts/hooks/test-doc-guard.sh` (+ `.ps1` twin).

---

## Release Scripts (`scripts/`)

- `scripts/gen-changelog.sh` — **CHANGELOG generator** (HIMMEL-454). On-demand (not a gate); writes `CHANGELOG.md` from conventional-commit history. Groups commits into a single `## [Unreleased]` section: `feat` → Added, `fix` → Fixed, `chore|refactor|docs|test` → Changed, everything else → Other. Idempotent on immediate re-run; do not hand-edit the generated file. `.ps1` twin: `scripts/gen-changelog.ps1`.

---

## Luna Scripts (`scripts/luna/`)

Shell scripts for luna vault maintenance and session import. Operator-invoked
on demand; nothing here runs automatically.

- `scripts/luna/backfill-sessions.sh` — Render historical Claude session
  transcripts into the luna vault as structured session notes (same schema as
  the live `end-session-wiki` hook, with `source: claude-backfill`). CREATE-only
  (never overwrites); idempotent via ledger at `~/.claude/luna-backfill-state.json`.
  Scope flags: default = current project, `--all` = every project, `--project
  <path>` (repeatable) = specific repo(s). `--dry-run` prints counts without
  writing. Two recovery modes overwrite existing notes in place via the
  crystallizer: `--reheal` (husk-only — notes that look contentless) and
  `--recrystallize` (any `crystallized: false` note with a content-bearing
  transcript, the common backfilled-prose case; LLM-only; `--limit N` chunks the
  token cost, `--dry-run` reports the full count first). Both emit stderr
  progress on long runs (HIMMEL-627). Primary surface: `/luna-backfill`. Full
  flag reference in `.claude/commands/luna-backfill.md`.
- `scripts/luna/crystallize-note.sh` — Best-effort background LLM "crystallizer"
  (HIMMEL-576): upgrades a just-written mechanical session note into a real
  synthesis via a bounded interactive `claude` run (Max-billed, no API key,
  HIMMEL-128-safe), flipping the note to `crystallized: true`. Spawned detached
  by the `end-session-wiki` hook on every success-write, and reused by
  `backfill-sessions.sh --reheal`/`--recrystallize`. Fail-open (no `claude` / over the concurrency
  cap → leaves the mechanical note untouched). Detail:
  `docs/luna/end-session-wiki.md` → Crystallization.

---

## Multi-vault upgrade engine (`scripts/luna-upgrade-all.sh`)

Multi-vault luna template upgrade sweep (HIMMEL-462). The MULTI-vault layer
above the proven single-vault engine (`templates/luna-second-brain/scripts/upgrade.sh`).
Operator-invoked on demand via `/luna-upgrade-all` or directly.

- `scripts/luna-upgrade-all.sh` — Discover candidate luna-second-brain vaults
  from the registry (`~/.claude/luna-vaults.json`) and a depth-1 scan of
  `--roots` (default `~/Documents`); classify each as `luna-family` / `unstamped`
  / `not-a-vault` (classification: what the vault IS); dry-run sweep per
  luna-family vault using himmel's `upgrade.sh`; and emit a per-vault table
  (sweep state: `already-current` / `clean-upgrade` / `conflict` / `error`,
  from→to versions, dirty flag). Note: classification (`luna-family`/`unstamped`)
  describes vault identity; sweep state describes the upgrade outcome for
  `luna-family` vaults only. `unstamped` appears as a porcelain row with empty
  from/to/dirty columns (no sweep performed for unstamped vaults).
  Apply is always per-vault and operator-confirmed. Creates a timestamped backup
  under `~/.claude/luna-upgrade-backups/<vault-slug>/<UTC-ts>/` before any write.
  Subcommands: `sweep [--roots] [--registry] [--template-dir] [--porcelain]`,
  `apply --vault <path> [--template-dir] [--force-unstamped]`,
  `restore --vault <path> [--from <ts>] [--list]`.
  Output signals: `BACKUP\t<dest>`, `OK\t<vault>`, `SKIPPED-DIRTY\t<vault>`,
  `PARTIAL\t<vault>`, `CONFLICT\t<vault>\t<sidecar>`, `RESTORED\t<vault>\t<ts>`.
  `.ps1` twin: `scripts/luna-upgrade-all.ps1` (thin Git-Bash forwarder).
  Primary surface: `/luna-upgrade-all` (skill: `obsidian-triage:luna-upgrade-all`
  — runbook at `marketplace/plugins/obsidian-triage/skills/luna-upgrade-all/SKILL.md`).
  Bash 3.2-safe; cross-platform (Windows Git Bash + macOS + Linux).

---

## CI Workflow + Runner (`scripts/ci/`)

GitHub Actions workflow (`.github/workflows/ci.yml`, HIMMEL-494) and the
helper scripts it calls. Triggered manually (`workflow_dispatch`-only); runs
on a dedicated public fork using free public runners.

- `scripts/ci/check-no-secrets.sh` — asserts no `${{ secrets.* }}` interpolation in `.github/workflows/`. Enforces the secret-free rail: all CI jobs run with zero credentials.
- `scripts/ci/run-shell-tests.sh` — discovers and runs all hermetic `test-*.sh` suites under a scan-root. Maintains a `SKIP_LIST` ledger of suites that need a live VM, hermes runtime, or network — none of which exist on a bare runner. Flags: `--list` (plan without running), `--skip-extra <relpath>` (ad-hoc skip). Exit 1 on any failure.

**Five jobs:** `secret-scan` (check-no-secrets), `lint` (shellcheck --severity=warning over `scripts/**/*.sh`), `node-suites` (npm matrix: jira/bitbucket/himmel-run), `bun-suites` (luna-vitals bun test), `shell-unit` (run-shell-tests.sh).

Full reference: [`scripts/ci/README.md`](../scripts/ci/README.md).

---

## CR Scripts (`scripts/cr/`)

Shell scripts that implement `/pr-check` sub-steps. Called by the `/pr-check` command; not invoked standalone in normal workflows.

- `scripts/cr/file-deferred-issues.sh` — reads `/pr-review-toolkit:review-pr` output, dedupes low-severity findings by content hash, and files them as GitHub issues tagged `cr-deferred`. Called by `/pr-check` step 7. Idempotent; `--dry-run` mode for inspection.
- `scripts/cr/critic-first-pass.sh` — generic model-parametrized CR reviewer (HIMMEL-415, supersedes retired `gemini-first-pass.sh`): diff on stdin → findings with stable `[<slug>-N]` IDs; routes through `scripts/hermes/invoke.sh`; `--model`/`--slug` flags select the model. Tests: `scripts/cr/test-critic-first-pass.sh` (deterministic, PATH-stubbed fake hermes).
- `scripts/cr/critic-panel.sh` + `scripts/cr/critics.json` — NIM critic panel (qwen3coder=`free` anchor since the 2026-07-03 drop of gptoss+kimi — HIMMEL-667 operator decision, 12%/13% ledger agreed-rate; defined in `critics.json`). `/pr-check` **auto-runs the free panel (qwen3coder, ~2min — bounded by the 150 s per-member timeout) by default**. `CR_PROFILE=none` = instant claude-only (skip panel). `CR_PROFILE=thorough` = adds the `thorough` tier (currently EMPTY — kept for future heavier critics). Any other value passes through as `CRITIC_PANEL_TIERS`. Tier filter passed via `CRITIC_PANEL_TIERS` env var. Retired the gemini-only CR lane (HIMMEL-412/415). Per-member hang protection via `CRITIC_TIMEOUT_SECS` (default 150 s, requires `timeout`).
- `scripts/cr/ledger-append.sh` — appends `finding` / `avail` / `usage` records to the CR ledger (`cr-critic-scores.jsonl`); called by `/pr-check` adjudication step. The `usage` kind (HIMMEL-485) records a chars/4 **estimated** token count for a critic (hermes does not expose real usage through the one-shot chokepoint); written best-effort by `critic-first-pass.sh` when `CR_USAGE_LOG=1`.
- `scripts/cr/cr-scores.sh` — generates a per-critic correctness scorecard from the ledger; surfaced via `/cr-scores`. Adds an estimated-token Usage section (per-model + cumulative) when the ledger holds `usage` records.

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
