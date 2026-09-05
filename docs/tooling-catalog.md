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
> MCP-output vs cache vs routing) is governed by
> [`docs/token-economy.md`](token-economy.md) (HIMMEL-654 WS6) — one
> optimizer per boundary; adoption changes gate on a measured real-session
> delta.

### qmd (`tobi/qmd`)

**What:** Local search engine over markdown documents. BM25 keyword search (lex), semantic vector search (vec), and hypothetical document search (hyde).
**MCP server:** `plugin:qmd:qmd` — exposes `query`, `get`, `multi_get`, `status` tools.
**Usage:** Searching local knowledge base, notes, docs.

**CLI install (HIMMEL-877, pinned HIMMEL-911):** the standalone `qmd` CLI
installs from the **himmel qmd fork** (`yotamleo/qmd`), pinned to an
immutable commit SHA (the literal lives in `_qmd_fork_ref`; read it there
rather than copying it here) rather than a mutable branch, via `scripts/lib/qmd-bin.sh`'s `qmd_install` (clone → fetch/checkout
the pinned SHA → `bun install && bun run build` → junction/symlink onto the
bun-global `@tobilu/qmd` path) — never upstream `bun add -g @tobilu/qmd`,
which EPERM-wedges on this project's machines and bun blocks its postinstall
script. `adopt.sh`/`setup.sh` (bash) and `adopt.ps1`/`setup.ps1` (pwsh, which
delegates via `bash scripts/lib/qmd-bin.sh install` rather than duplicating
the recipe) both call this. Idempotent; overridable via `QMD_FORK_REPO` /
`QMD_FORK_REF` / `QMD_FORK_DIR`.

**Shared HTTP singleton (HIMMEL-592):** himmel vendors `qmd@himmel`
(`marketplace/plugins/qmd/`, a thin fork of upstream `qmd@qmd`) whose only
delta is that the `qmd` MCP server is declared as an HTTP endpoint
(`{"type":"http","url":"http://localhost:8181/mcp"}`) instead of a per-session
stdio process. All Claude sessions address **one** `qmd mcp --http --daemon` on
`localhost:8181`, so the read-only index runtime is loaded once, not N times.
The skill (`qmd:qmd`) and tool prefix (`mcp__plugin_qmd_qmd__*`) keep the same
name/prefix as upstream (one `allowed-tools` line added — see the plugin
README's fork-delta section).
- **Daemon lifecycle:** the plugin ships its own SessionStart hook
  (`marketplace/plugins/qmd/hooks/hooks.json` invoking
  `${CLAUDE_PLUGIN_ROOT}/scripts/ensure-qmd-daemon.sh`), so it runs from ANY
  session in ANY repo where the plugin is enabled — not just himmel checkouts.
  It probes the endpoint and starts the daemon if it is dead (idempotent; the
  start is bounded by `timeout(1)` so a hung start cannot stall SessionStart;
  a non-qmd listener on 8181 fails loudly as a port collision instead of
  counting as alive). A manual operator twin for PowerShell lives at
  `scripts/qmd/ensure-qmd-daemon.ps1`. Stop the daemon with `qmd mcp stop`.
  Both resolve qmd as `bun <bun-global dist/cli/qmd.js>` first (HIMMEL-928):
  the bun bin shim honors the CLI's node shebang and hands the daemon to
  node, where qmd needs the better-sqlite3 native binding (bun-side qmd uses
  `bun:sqlite`) — a binding bun's install blocks by default and that breaks
  again on every node ABI bump.
- **Boot survival (Windows, lean-invoke):**
  `scripts/qmd/register-qmd-daemon-logon.ps1` registers a per-user ONLOGON
  scheduled task (`qmd-mcp-daemon`) running the ensure twin, so the daemon is
  back up after a reboot without waiting for the first Claude session
  (HIMMEL-928). One-shot per machine; remove with
  `Unregister-ScheduledTask -TaskName 'qmd-mcp-daemon' -Confirm:$false`.
- **Freshness:** the index is sqlite+WAL, read per query, so docs added by the
  existing `qmd update` cadence are served by the running daemon immediately —
  no daemon restart or watch mechanism, cadence unchanged.
- **Blast radius:** a shared-daemon crash affects every session's qmd. Accepted
  for a read-only index — a connect failure surfaces loudly in `/mcp`, never as
  a silent empty index.

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

**MCP server:** `obsidian-vault` (uvx mcp-obsidian) — tools: `list_files_in_vault`, `get_file_contents`, `append_content`, `patch_content`, `simple_search`, `complex_search`, `delete_file`, `get_recent_changes`

---

### obsidian-second-brain (external, manual install)

**Repo:** `eugeniughelbur/obsidian-second-brain`
**Install path:** `~/.claude/plugins/obsidian-second-brain/` (cloned)
**Skill link:** `~/.claude/skills/obsidian-second-brain`
**Commands:** 33 slash commands installed to `~/.claude/commands/` (5 research-toolkit
commands are NOT adopted — see Research toolkit line below)
**Version:** v0.8 (May 2026) | **Installed:** 2026-05-16
**Update:** `git pull` in `~/.claude/plugins/obsidian-second-brain/`
**Research toolkit:** NOT ADOPTED (proposed 2026-07-29, pending ADR sign-off) —
operator confirmed no active XAI/Grok or Perplexity subscription. A
`~/.config/obsidian-second-brain/.env`
credentials file exists (since 2026-06-12) but is presence-without-validity —
having the file is not evidence of a working subscription. `/x-read`, `/x-pulse`,
`/research`, `/research-deep`, `/youtube` should be removed from
`~/.claude/commands/` (operator action — these are user-scope files, not
tracked by this repo). `/notebooklm` (Gemini File Search) uses a different key
and is unaffected by this decision. Decision record:
`docs/tool-adoption/registry.md` (research-toolkit row) and
`docs/tool-adoption/adr-obsidian-second-brain-research-toolkit.md`. Revisit if
a subscription lands.

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

### openai-codex (codex plugin)

**What:** The OpenAI codex companion plugin — the codex CLI runtime, the `codex:codex-rescue` / `codex:setup` skills, and the `codex-companion.mjs` script under `$HOME/.claude/plugins/cache/openai-codex/codex/<version>/` (the version segment drifts on plugin update — glob-resolve it, never hardcode).

**Tiered vendor posture (operator ruling 2026-08-28):** large established
vendors — the codex plugin, the claude CLI, hermes (see the hermes pin revert
precedent, #1929) — deliberately track upstream LATEST, with our last
reviewed version as an informal floor, never locked to a himmel fork/pin;
upstream is already ≥ v1.0.6 here, so no pin or drift mechanism is needed.
Smaller community forks (claude-obsidian, qmd) keep the opposite posture —
pin-or-better plus a drift advisory (`scripts/check-plugin-drift.sh` /
`scripts/plugin-upstreams.json`) — claude-obsidian is the exemplar. The
SessionEnd `Hook cancelled` 5s-timeout noise (HIMMEL-2148) is tracked upstream
at openai/codex-plugin-cc#474. The `yotamleo/codex-plugin-cc` fork and tag
`v1.0.6-himmel.1` remain parked, unreferenced by any marketplace entry.

**ADOPTED (HIMMEL-694):** the companion's `adversarial-review` mode is integrated into `/pr-check` step 3.1 as an ADDITIONAL pre-merge cross-model pass of the paid/pair tier — **availability-gated** (it consumes the operator's OpenAI usage bank, so absence of codex ⇒ silently skipped with a one-line note, never an error; also skipped under `CR_PROFILE=none`). Its `[codex-adv-N]` findings are blocking candidates merged into the same adjudication flow as the free critic panel (VERDICT lines + step-4.5 ledger `--model codex-adv`). Runbook: `.claude/commands/pr-check.md` step 3.1.
**Windows ACL hardening (HIMMEL-733):** aged Codex worktrees can lose inherited
sandbox ACEs on child directories. Before an unattended Codex dispatch into an
existing worktree, run `pwsh -NoProfile -File scripts\codex\normalize-worktree-acl.ps1 <worktree>`
(or the `scripts/codex/normalize-worktree-acl.sh` wrapper from Git Bash). The
helper refuses paths outside `.claude/worktrees/<name>` and resets only each
top-level child directory, never the worktree root.
**GPT-5.6 reasoning-effort knob (HIMMEL-905):** `scripts/codex/dispatch-codex-exec.sh`
accepts an optional `--reasoning-effort <none|low|medium|high|xhigh|max>` passthrough
(translated internally to `-c model_reasoning_effort=<value>`); the wrapper's own
model pin stays `gpt-5.5` pending in-repo verification of GPT-5.6 availability.

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
| `follow-list-score.mjs` (+ `lib/follow-{roster,dossier,verify,screen,score}.mjs`) | HIMMEL-660. Evidence-first X/Twitter follow-list scorer: pure-code `gather` (per-handle evidence dossier — corpus, account fetch via the spike-A fxtwitter endpoint, claim extraction/verification, HIMMEL-256 injection screen), a manual `judge-prep` → Claude judge pass scored against `follow-judge-charter.md`, and pure-code `assemble` (deterministic composite/tier math + `follow-overrides.json` whitelist/exclude, writes `ai-x-follow-list.md` + `ai-x-follow-scores.md`). Judge pass is interactive/subagent only — never headless `claude -p`. See `marketplace/plugins/obsidian-triage/tools/README.md`. |

#### luna-correlate (`luna-correlate@himmel`)

**What:** Offline health-factor correlation MCP. Correlates personal health series (sleep, HRV, resting HR) against public environmental factors (geomagnetic Kp, lunar phase, daylight hours) and a gated country-level grid fetcher for location factors (barometric pressure, pollen, PM2.5 air quality). Boundary B+C: only `factors.cache` touches the network; all joins and computations are offline. Outputs are candidate signals only — never a diagnosis, never causation.

**M3 operator-facing tool:** `signals.dashboard` — lag-swept (±3 days default), best-lag-per-pair, Benjamini-Hochberg FDR-controlled (q=0.1) analysis over device series × factors. Writes `dashboard.md` + `dashboard.json` to `LUNA_SIGNALS_DIR` (must be set; a salus vault's `60-Signals/` by convention).

**MCP tools:** `factors.cache` (network, gated), `series.load`, `correlate`, `signals.report`, `signals.dashboard` (all offline).
**Offline factors:** `kp` (GFZ Potsdam, CC BY 4.0), `lunar_phase` (astronomical formula, zero network), `daylight` (bbox-centroid latitude, zero network). Location factors (`pressure`, `pollen`, `aq`) via Open-Meteo, opt-in via `LUNA_REGION_BBOX`.
**Plugin path:** `marketplace/plugins/luna-correlate/`

#### himmel-ops (`himmel-ops@himmel`)

**What:** Harness-meta operational skills for himmel.
**Skills:** `himmel-ops:stuck-playbook` (load-on-trigger guardrail-recovery playbook, HIMMEL-211), `himmel-ops:minerva` (grill→brainstorm→critic→spec→critic→plan pipeline with adversarial critic loops, HIMMEL-428; the one front door for grill / stress-test / brainstorm, HIMMEL-2039), `himmel-ops:vm` (lean-invoke VM lifecycle + e2e runbook, HIMMEL-491/493), `himmel-ops:memory-compound` (lean-invoke auto-memory→vault compaction with a qmd findability gate, HIMMEL-569).
**Commands:** `/minerva` — runs the minerva pipeline; `/memory-compound` — runs the auto-memory compaction pass; `/fanout` — validates + confirms + dispatches N work items to the invariant-policy lane by type, refusing destructive/irreversible items below the judgement tier and any dormant lane (HIMMEL-1829).
**Hook:** `hooks/hooks.json` wires a PreToolUse(`matcher: "Skill"`) hook `inject-minerva-critic.sh` (HIMMEL-429) — injects the minerva critic loop when `superpowers:brainstorming`/`writing-plans` fires without `/minerva`, and routes `mattpocock-skills:grilling` into minerva Stage 1a (HIMMEL-2039). Advisory, fail-open; kill switch `MINERVA_HOOK_DISABLE=1`.
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

---

## himmel-doctor (`scripts/himmel-doctor.sh`)

The `/himmel-doctor` diagnostic. Read-only except `--fix`. Checks (a subset —
`scripts/himmel-doctor.sh` is the source of truth for the full C1–C28 set): C1-guardrail
user-level guardrail-hook node path (+ `--fix` re-bake; the old C1-node check was
retired in HIMMEL-2033 and the ids were NOT renumbered), C2 shadowed claude-obsidian, C3 dirty
single-writer luna vault, C4 Bitbucket-remote-where-`gh`-fails, C5 repo not in the
handover registry, C6 PATH-fragile bare-interpreter MCP servers (uvx/bun — same
GUI-launch failure class as the node hook), C7 lingering merged-PR worktrees, C8
stale pipeline-cadence runners, C9 auto-arm scheduler backend (HIMMEL-594 — reads
`scripts/lib/scheduler-backend.sh`; never sudos), C10 private→public propagation
drift (HIMMEL-640 — read-only advisory; surfaces MISSING/DRIFT/REVERSE-LEAK
between the private mirror and the public clone; skips cleanly on adopter clones),
C28 guardrail-block-global armed-but-inert consent gap (HIMMEL-2176 — read-only,
never auto-wires; C1-guardrail already covers wired-and-healthy vs
wired-but-degraded, so this adds the third distinction among the never-wired
case: consent recorded 'no' is a legitimate decline (OK), consent 'yes' but
still unwired means a prior `himmelctl ensure` likely failed partway (WARN),
and no recorded consent at all is the never-asked gap this check exists to
report (WARN) — read from himmelctl's own `state.json`, never from a guess;
an early revision short-circuited OK whenever the user-level settings file was
merely absent, conflating "nothing to check" with "never asked" — the shipped
check no longer does).
Prints a severity-grouped report (FAIL/WARN/INFO); `--file-issue
[--repo owner/name]` files ONE deduped consolidated public GitHub issue (resolves
the repo from `--repo` → `$HIMMEL_DOCTOR_ISSUE_REPO` → github origin). Exit 1 on any
FAIL. Tests: `scripts/test-himmel-doctor.sh`, `scripts/lib/test-{resolve,run}-node.sh`.

---

## Memory-capture audit (`scripts/memory/audit-memory-capture.sh`, HIMMEL-1090)

Decoupled, standalone detector for the auto-memory capture discipline (HIMMEL-570/1076 Task 5) — it deliberately does NOT ride the memory-compound cadence (compound now runs weeks-to-months apart, so a detector riding it would grow its own latency in proportion to the design working). Reads the deny/write log appended by `scripts/hooks/guard-memory-capture.sh` (`MEMORY_CAPTURE_LOG`, default `$MEMDIR/.capture-log.jsonl`). Checks: **orphaned denies** — a fact the hook denied and the model never re-landed in the substrate (windowed to a trailing epoch window via `MEMORY_AUDIT_WINDOW_DAYS` so a reworded/re-landed fact stops ringing once its deny ages out; WARNs rather than silently reporting clean when denies exist but the substrate is unresolvable — LUNA_VAULT_PATH → `<home>/Documents/luna` fallback, P2-13/P2-14); **orphan topic files** — a topic file whose basename is not referenced by any `MEMORY.md` routing line (Rev2: topic files ARE the design, so the old ">2 topic files = drift" check is inverted); **line-count tripwire** (net pointer-line growth in-window); **index budget + over-length-line discipline**; and a best-effort **qmd `luna-curated` collection-freshness** check (skips cleanly when qmd is absent or `MEMORY_AUDIT_SKIP_QMD=1`). Exit 0 clean / 1 findings; bash 3.2-safe, no `date -d`. Tests: `scripts/memory/test-audit-memory-capture.sh`.

---

## Tool-call census (`scripts/observability/tool-call-census.sh`, HIMMEL-1462)

Answers the operator's named observability blind spot — per-session tool-call and error volume — without any live instrumentation, because session transcripts already record every `tool_use` and every `tool_result`. Reads `~/.claude/projects/<slug>/**/*.jsonl` (`--projects-dir` / `CLAUDE_PROJECTS_DIR` override) — including the nested `<session-id>/subagents/agent-*.jsonl` transcripts newer Claude Code writes, whose tool calls are attributed to the spawning project, not to a phantom `subagents` one — windowed by transcript mtime (`--since`, default `24h`) and optionally scoped to one project (`--project <slug>`), and merges one JSON line per session into `~/.himmel/tool-call-census.jsonl` (`--out` / `HIMMEL_TOOL_CENSUS`): `{session_id, project, started_at, ended_at, tool_calls:{<tool>:{calls,errors}}, total_calls, total_errors, denials:{<class>:n}}`. MCP tools keep their namespaced names (`mcp__qmd__query`), so per-server health falls out of the same map. Rows are keyed by `session_id` and **replaced** on re-run, so a session that was still growing when last scanned is refreshed rather than duplicated. The merge is single-writer — it claims `<out>.lock` by atomic `mkdir` and refuses (rc 2) rather than racing a concurrent run — and prunes rows past a 14-day retention window (`HIMMEL_TOOL_CENSUS_RETAIN_DAYS`) so the file the exporter re-parses every scrape stays bounded. Denial classes are a first-line prefix/keyword classifier over the error text — the hook name for a `PreToolUse:… hook error:` result, plus `auto-mode-classifier`, `user-rejected`, and `hook-unclassified`; a plain tool failure counts as an error, never as a denial. Pure reader: no transcript writes, no network, no process control. Lean-invoke (no cadence wired yet). The flow exporter reads the census file passively and exposes `himmel_tool_calls_total{tool,project}`, `himmel_tool_errors_total{tool,project}`, and `himmel_tool_denials_total{class,project}` folded over the last 24h — window-folded counters with the same reset caveat as `flow_run_outcome_total`. Tests: `scripts/observability/test-tool-call-census.sh` (synthetic transcripts only) plus the census cases in `scripts/observability/flow-exporter.test.ts`.

---

## Agent-runtime census (`scripts/observability/agent-runtime-census.ps1` + `.sh`, HIMMEL-1988)

REPORT-ONLY Windows evidence collector for the agent-runtime RAM + MCP lifecycle program (P0-1) — it never kills, restarts, throttles or reconfigures a process, and there is no `--kill` mode to grow into one. One snapshot per invocation (`-Loop -IntervalSec 300 -MaxSnapshots N` for the 5-minute cadence; `-MaxSnapshots` always bounds the run, there is no unbounded loop), appended as one compact JSON line to `-OutFile` (default `~/.himmel/agent-runtime-census.jsonl`) plus a human table on stdout. Each snapshot records: UTC timestamp + boot time; the supervisors (`codex.exe`, `claude.exe`) with pid/creation time/working set; their direct MCP fleet roots (node/node_repl/bun/deno/python/uv/uvx/npx/tokensave/qmd) with pid, creation time, working set, descendant count and summed descendant working set; the duplicate groups per supervisor (same exe + first argument, more than one live instance — the live-supervisor duplication HIMMEL-1328 reports and the Codex lifecycle defect this program is chasing); process-family counts (bash, sh, node, bun, python, pwsh, powershell, cmd, wsl, conhost, git); the runtime tuple (node/npm/bun versions, which `bash` resolves first, flagged when that is the WSL launcher); the `\Memory\*` pool/commit/available counters via `Get-Counter`; and the poolmon rows for `File`/`Toke`/`FMfn`/`SeAt`/`SeTd`/`SeTl` summed across a tag's Nonp AND Paged rows (same locator + summing rule as station-ops `pool/pool-rate.ps1`; `HIMMEL_POOLMON` overrides it, and an absent poolmon degrades to empty tag rows, never a failure) with the raw dump kept next to the JSONL as `poolmon_artifact`. **Redaction:** exactly the executable name plus ONE argument reaches the row — never the rest of the line, never env, never anything after a bare `--`, never the value of any flag (a flag is treated as value-taking by default, because the token after an unlisted flag is where a prompt or credential sits; the only exception is a short known-boolean list — `-y`/`--yes`, `-q`/`--quiet`, `--no-install`, `--offline` — so `npx -y <pkg>` identifies as the package instead of collapsing every npx server into one `-y` duplicate group), path arguments reduced to their leaf, and credential shapes scrubbed with ledger-append.sh's `--detail` regexes. The limit of that guarantee, stated plainly: the recorded argument is a *positional* token by design — it is what tells two servers apart for the duplicate census — so a bare positional secret with no recognizable credential shape would be recorded. Pass secrets to MCP servers as flag values or environment, never positionally. `-Label` is required (`codex` | `claude-swarm` | `hermes-wsl`) — an unlabelled row is evidence nobody can attribute to a harness later, so the run is refused rather than defaulted. Two consecutive rows are the unit of analysis: they let a reader correlate a fleet/process-generation change with the `File`/`Toke`/`FMfn` deltas. Lean-invoke (no cadence wired). Windows-only — the `.sh` wrapper forwards every argument to `powershell`/`pwsh -NoProfile -ExecutionPolicy Bypass -File` and exits 2 elsewhere rather than pretending to have collected evidence. Tests: `scripts/observability/test-agent-runtime-census.sh` (canned process table + canned poolmon dump through the documented test-only `-FixtureProcesses`/`-FixturePoolmon` seams).

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

## Shared home/vault resolution (`scripts/lib/resolve-user-home.sh`, HIMMEL-645/642/458, HIMMEL-2176)

Sourced-only, bash-3.2-safe lib exporting `resolve_user_home` (cross-platform
user-home: on Windows Git-Bash prefers `USERPROFILE` via `cygpath -u`
**before** `$HOME`, since `$HOME` can be the MSYS home while Claude Code's
config and the luna vault live under the Windows profile; POSIX hosts have
`USERPROFILE` unset and fall through to `$HOME`, then `/tmp` as the last
resort) and `default_vault` (honors `LUNA_VAULT_PATH` first — the path
`adopt.sh` persists and `himmel-doctor` probes — else `<home>/Documents/luna`
via the resolver above; an explicit `--vault` always overrides at the caller).
Extracted **verbatim** from `scripts/luna/pipeline-cadence.sh` (HIMMEL-2176
Stage 1 PR-A, spec A16), which now sources it instead of carrying its own
copy. Stage 1 converted **only** `pipeline-cadence.sh`; the remaining
byte-identical copies scattered across other cadence scripts (e.g.
`cadence-format.sh`'s `cadence_user_home()`) are tracked as **HIMMEL-2253**,
which also found 3 call sites resolving `$HOME` **before** `USERPROFILE` —
the inverse, and wrong, order — so that follow-up is an audit-then-convert
pass, never a blind find-and-replace.

---

## claude-statusline (vendored, HIMMEL-331)

**Vendored in himmel:** `scripts/statusline/` (`bin/statusline.sh`, `test/`, `LICENSE`, `README.md`, provenance in `VENDORED.md`).
**Config:** `~/.claude/settings.json` → `statusLine.command` now points at the hud node renderer (`node "<himmel-path>/marketplace/plugins/claude-hud/dist/index.js"`, wired by `scripts/lib/wire-statusline.sh`; env gate `CLAUDE_HUD_ALLOW_EXTRA_CMD=1`; hud config dropped at `~/.claude/plugins/claude-hud/config.json`). The bash wrapper `<himmel-path>/scripts/where-are-we/statusline.sh` is retained as the rollback fallback that `scripts/lib/unwire-statusline.sh` can repoint to; it composes this vendored `bin/statusline.sh` + a where-are-we line — active handover + epic progression, HIMMEL-538; the segment is default-ON since HIMMEL-556 — opt out with an explicit falsy `HIMMEL_WHERE_ARE_WE` (`0|false|off|no`); no external clone.
**What:** Bash script receiving Claude Code session JSON via stdin, outputs formatted status bar.

Displays: model, context %, git branch, rate-limit bars (current/weekly/extra), cache TTL countdown, per-session and all-sessions cache read/write/hit/savings.

**Source fork:** `yotamleo/claude-statusline` — **ARCHIVED (HIMMEL-1233)**; superseded as the renderer by the vendored claude-hud fork (see the claude-hud entry). The bar (`bin/statusline.sh`) is retained in-tree as the rollback fallback but is no longer wired or re-vendored, so the fork-sync path is closed.
**Patch applied:** `docs/patches/2026-05-16-cache-statusline.md`
**Upstream:** `nilbuild/claude-statusline` (fork now archived; no PR path)

---

<a id="claude-glm"></a>

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
| `ANTHROPIC_MODEL` | `glm-5.2[1m]` |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `glm-4.7` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `glm-5.2[1m]` |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `glm-5.2[1m]` |
| `CLAUDE_CONFIG_DIR` | `$HOME/.claude-glm` |

**Key resolution:** shell env `ZAI_API_KEY` first, else the himmel repo `.env`
(bash via `load-dotenv.sh --root <himmel>`, PS via an inline reader) — pinned to
the *launcher's* repo, not the cwd, so a session running in the luna vault still
finds the key. Missing key → **exit 2**. The launcher cannot distinguish shell
env from `settings.json`-injected env — don't put the key in `settings.json`
(that hands it to every session); use per-launch shell env or the repo `.env`.

**Isolated config dir (`$HOME/.claude-glm`):** seeded from `~/.claude` on first
launch (or `--reseed`/`-Reseed`), and **auto-refreshed** (HIMMEL-819) on any
plain launch when `~/.claude/settings.json`, `plugins/installed_plugins.json`,
or `plugins/known_marketplaces.json` is newer than the `.seeded` sentinel — or
deleted while a lane copy remains (true mirror for those three files) — so
plugin-profile changes (e.g. disabling plugins to slim worker context) reach
lane workers without a manual `--reseed`. `commands`/`skills`/`hooks`/`agents`
drift still needs an explicit `--reseed`. **Optional:** set
`CLAUDE_LANE_AUTO_RESEED=0` in the launching shell to restore the once-only
seed if auto-reseed ever blocks a launch in your setup (e.g. a settings change
re-running the seed against a broken `node`). The seed is an allowlist copy — `settings.json`
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

**`--settings` env-injection screen (HIMMEL-1040):** a `--settings <file|json>`
arg passes through to `claude` (this is the plugin-profile injection channel —
see [Lane plugin profiles](#lane-plugin-profiles-scriptslanesplugin-profilesjsonmjs-himmel-1040)), but the launcher first
screens the payload and **refuses (exit 3)** any `--settings` that sets
`env.ANTHROPIC_*` / `env.CLAUDE_CODE_USE_*` (or is unparseable) — such a payload
would redirect the lane away from the z.ai endpoint. Twin of claude-codex's
`screen_settings_arg`; a plugin-only `{"enabledPlugins":{…}}` payload passes.

**Off-peak annotation:** an advisory stderr line notes whether you're inside the
GLM peak window (14:00–18:00 UTC+8); advisory only, changes no behavior.

**Setup:** `ZAI_API_KEY` sourcing + the `.salus` PHI marker are covered in
[`docs/setup/new-machine.md`](setup/new-machine.md) §1 and §4d.

**Acceptance:** the hermetic launcher tests in
`scripts/test-claude-glm.{sh,ps1}` cover the key gate, the seeder, the
PHI/egress guards, and the `--settings` env-injection screen against a mock
`claude`; only the live-backend acceptance leg is manual — the **HIMMEL-665
Task 8 checklist**.

---

<a id="lane-plugin-profiles"></a>

## Lane plugin profiles (`scripts/lanes/plugin-profiles.{json,mjs}`, HIMMEL-1040)

**What:** Named plugin profiles injected per-dispatch so a lane worker runs a
**lean** plugin set while the operator's own `~/.claude` stays full. A lane worker
resolves its plugin surface from the operator's config either way — `spawn-glm`
shares `~/.claude` directly (no `CLAUDE_CONFIG_DIR`, so himmel hooks load), while
the interactive `claude-glm` launcher runs against a seeded `$HOME/.claude-glm`
**mirror** of `~/.claude` ([claude-glm](#claude-glm-scriptsclaude-glm-ps1-twin-himmel-665) above) — so both would otherwise
inherit the operator's entire (full) plugin catalog: duplicated plugin context +
duplicate MCP invocations on every worker, and neither live-mutates the
operator's primary config. The fix is **lever-b**: resolve a profile to an
`enabledPlugins` map and inject it as `claude --settings '{"enabledPlugins":{…}}'`
(highest non-managed precedence, overrides the inherited/mirrored profile without
changing which config dir loads, so hooks are unaffected).

**Registry (`plugin-profiles.json`):**
- `floor` — the inviolable operational set present in every INJECTED profile:
  `handover@himmel`, `himmel-ops@himmel`, `qmd@himmel`
  (a lane that can't dispatch/search/handover is broken). `operator` is the
  exception — it's a `null` sentinel that injects nothing at all, so the floor
  doesn't apply to it. `codex@openai-codex` is deliberately NOT in the floor
  (HIMMEL-1677) — it stays catalogued and enabled for the `user` profile, but
  every `lane-*` worker disables it: lane workers reach codex through provider
  env overrides, so the plugin only added a redundant, unreaped app-server
  process stack.
- `catalog` — the known plugin universe; the resolver sets `false` for anything a
  profile doesn't enable, so the injected map is **complete** (correct whether
  Claude Code merges or replaces `enabledPlugins`). Beyond the catalog the
  resolver also sets `false` for every id in `opts.installed` — the caller's LIVE
  plugin universe — so a newly-installed plugin absent from `catalog` is still
  disabled on a lane whose caller passes that set (the spawn scripts do, via
  `readEnabledPluginIds`). Two exceptions:
  - **The claudex lane does not fully close this** (KNOWN GAP, HIMMEL-1066):
    `readEnabledPluginIds` reads the dispatcher's ambient config dir, but a
    claudex worker's effective user scope is `~/.claude-codex` (the launcher owns
    and seeds it AFTER the resolve). A plugin enabled only there, and absent from
    `catalog`, is missing from `opts.installed` and can stay enabled in an
    unattended worker. See the seam note at `spawn-glm.ts:36-41`.
  - A CATALOG-ONLY caller (one passing no `opts.installed`) retains the gap:
    there, an id absent from `catalog` goes unmentioned and inherits its enabled
    state until added (the HIMMEL-819 staleness class).
- `profiles` — `operator` (`null` sentinel: full `~/.claude`, never injected),
  `user` (adopter set, HIMMEL-1044), `lane-impl` (impl workers: floor +
  `pr-review-toolkit-himmel`), `lane-review` (CR-only, same lean set),
  `lane-content` (impl + `claude-obsidian` + `obsidian-triage`).

**Resolver (`plugin-profiles.mjs`):** `resolveProfile(registry, name, {addPlugins,
installed})` → `null` for `operator`, else `{enabledPlugins:{…}}`; the floor is
forced `true` last (nothing can drop it); unknown name / malformed overlay id /
overlay id absent from the catalog / `operator`+overlay all throw.
`resolveProfileByName(name, opts)` is the file-reading convenience the spawn
scripts + CLI use — it loads the registry, **validates it and fails closed**, then
delegates. `opts.installed` widens the deny-by-default baseline beyond the static
catalog with the caller's LIVE plugin universe (`readEnabledPluginIds(home, cwd,
configDir)` — the child's effective config dir plus every ancestor
`.claude/settings{,.local}.json` from `cwd` to the filesystem root; absent layer =
no opinion, unparseable layer = fail closed). CLI:
`node scripts/lanes/plugin-profiles.mjs <profile> [--add-plugins a@m,b@m]` prints
the `--settings` JSON; `--validate` checks the floor/catalog invariants;
`--list` lists profiles.

**Dispatch flags (`spawn-glm` / `spawn-claudex`):** both inject the resolved
profile by default (`lane-impl`); override with `--profile <name>` and layer a
per-dispatch overlay with `--add-plugins a@m,b@m` (repeatable; e.g. an obsidian
task on the impl lane adds `claude-obsidian@himmel` for that one dispatch). An
unknown profile / bad overlay id is a clean usage refusal (exit 2) before any
worktree side-effect. spawn-glm carries a non-default profile into its
cap-respawn handover; spawn-claudex dispatches through `claude-codex`, which
already screens + forwards `--settings`.

**Measured delta (`claude plugin details`, 2026-07-16 operator machine):**
`lane-impl` drops **~5,058 always-on tok/session** vs the operator's full
profile — dominated by `obsidian-triage` (~3,671), `superpowers` (~715),
`hookify` (~292), `coderabbit` (~205), `claude-md-management` (~175) — paid per
worker, per session, so it multiplies across a fan-out.

**Acceptance:** `node --test scripts/lanes/tests/plugin-profiles.test.mjs`
(resolver invariants: floor always on, complete map, overlay, operator→null,
registry validation) + the `--settings` cases in the spawn/launcher suites.

---

<a id="claude-codex"></a>

## claude-codex (`scripts/claude-codex`, `.ps1` twin, HIMMEL-979)

**What:** Thin launcher that runs Claude Code as the harness over the codex
subscription through a self-hosted CLIProxyAPI Anthropic-compatible proxy: the
claudex pattern from the theo/t3.gg recipe. It keeps himmel's full Claude Code
harness (skills, hooks, guardrails, worktrees) while spending the codex weekly
bank, and opens mixed subagent lanes that the plain codex CLI harness does not.

**Env table:**

| Var | Value |
|---|---|
| `CODEX_PROXY_BASE_URL` | `http://127.0.0.1:8317` by default |
| `CODEX_MODEL` | `gpt-5.6-sol` by default |
| `CODEX_HAIKU` | `$CODEX_MODEL` by default |
| `CODEX_SUBAGENT_MODEL` | `$CODEX_MODEL` by default |
| `CODEX_CONTEXT_WINDOW` | `272000` by default → `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (twin of `GLM_CONTEXT_WINDOW`). Without it Claude Code assumes its ~200k default for the unrecognized `gpt-5.6-sol` slug and compacts early. gpt-5.6's real window is **~372k** (95% effective ~353k, [openai/codex#32486](https://github.com/openai/codex/issues/32486)); **272k is the 2× pricing cliff, NOT a hard ceiling** — input past 272k bills 2× input / 1.5× output. `272000` is the cost-optimal default (compact at the cliff); raise to `353000` to use the full window at 2× cost past 272k. |
| `CLIPROXY_API_KEY` | Must match an `api-keys` entry in `~/.cli-proxy-api/config.yaml` |
| `CLAUDE_CONFIG_DIR` | `$HOME/.claude-codex` |

**Guard files:** the lane uses `~/.config/claude-codex/phi-roots` and
`~/.config/claude-codex/egress-denylist`, plus the launch-cwd `.salus` marker.
A PHI-marked workspace is refused with no override; denylisted workspaces require
`--force`/`-Force` and warn that content will be sent to OpenAI via the local
proxy.

**Seeding:** same lane-seed mechanism as `claude-glm`: an isolated
`$HOME/.claude-codex` config dir is seeded from `~/.claude`, sanitized to strip
model and `env.ANTHROPIC_*`, refreshed by the shared `CLAUDE_LANE_*` reseed and
lock knobs, and never copies credentials or history.

**Prerequisite:** the CLIProxyAPI binary is **not on PATH** — it's installed to
`~/.cli-proxy-api/cli-proxy-api.exe` and driven through the per-host bring-up
script, never invoked bare. Run `.\scripts\setup\cli-proxy-lane.ps1 -Install`
(downloads the pinned release, writes `~/.cli-proxy-api/config.yaml` with
`host: "127.0.0.1"` — the default empty host binds ALL interfaces, which would
LAN-expose the OAuth-wrapped endpoint — and `port: 8317`), then `-Login` (device-code
OAuth, no local browser needed) and `-Register` (windowless logon task, starts it
now). An `api-keys` entry in `config.yaml` must match `CLIPROXY_API_KEY`. Full
per-host checksheet + re-login recovery (device-flow re-auth when the codex token
invalidates): [`docs/setup/cli-proxy-lane.md`](setup/cli-proxy-lane.md). This is
subscription OAuth re-exposure; the ToS-risk posture is operator-accepted for
HIMMEL-979.

**Coexistence:** plain `claude` (Anthropic subscription, `~/.claude`, native
OAuth) and `claude-codex` run side by side, even concurrently, because the lane's
env applies only to its own invocation and its config dir (`~/.claude-codex`),
guard dir, and seed lock are fully per-lane. Nothing in the codex lane touches
the stock Claude Code install; it has the same isolation contract as
`claude-glm`.

**Effort mapping (HIMMEL-1002, verified 2026-07-14).** The launcher pins
`CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1`; Claude Code emits the effort as top-level
`output_config.effort` in the `/v1/messages` body, and CLIProxyAPI forwards it
**verbatim** as the codex thinking level — no clamping, no proxy-side default
override, so a per-dispatch effort **downgrade does reach `gpt-5.6-sol`** (proxy
`apply.go` debug lines: `original config from request` == `processed config to
apply`, `mode=level level=<X>`).

| `CLAUDE_CODE_EFFORT_LEVEL` | Level sent to `gpt-5.6-sol` |
|---|---|
| _(unset — the lane default)_ | **`xhigh`** |
| `low` / `medium` / `high` / `xhigh` | `low` / `medium` / `high` / `xhigh` |
| `max` | `max` (accepted upstream — see caveat) |
| `ultra`, or any unrecognized value | **`xhigh`** — silently falls back to the default |

- **`ultra` is unreachable from the Claude Code side.** The effort enum tops out
  at `max`; the literal `ultra` is never forwarded — Claude Code ignores any
  unrecognized value and falls back to the lane default (`xhigh`). No
  `CLAUDE_CODE_EFFORT_LEVEL` value produces `level=ultra` to codex, so **no
  launcher guard against `ultra` is needed** (Claude Code itself refuses it).
- **`max` is the real ultra-risk vector.** It IS reachable and forwarded
  verbatim; codex returns `200`, but what juice codex resolves `max` to is *not*
  observable in the proxy log (which shows only what is sent, not codex's
  internal resolution). Because OpenAI's documented `reasoning_effort` ceiling is
  `xhigh` and theo's post-mortem warns the top juice ("ultra") is buggy, treat
  `max` as unverified/avoid — the HIMMEL-1001 operating ladder caps explicit
  effort at `xhigh`.
- **The implicit default is `xhigh`** (theo's "rare" tier) — higher than his
  recommended medium/high default; HIMMEL-1001 pins it down.

_Method: one bounded `claude -p` turn per tier through the live proxy with
`debug: true` + `logging-to-file: true` added to `~/.cli-proxy-api/config.yaml`
(hot-reloaded via the proxy's config watcher, reverted immediately after);
levels read from the proxy `main.log` `apply.go` lines. Feeds HIMMEL-774
(per-lane effort/tier calibration)._

**Operating rules (HIMMEL-1001, from theo's gpt-5.6-sol post-mortem).** The lane
spends the codex weekly bank, so GPT-5.6's token-burn mechanics apply. These are
encoded where the lane runs (the launcher default + `lanes.json`), not just as
vault prose (HIMMEL-195); the full mechanics live in luna
`30-Resources/Tech/CLIProxyAPI.md`.

- **Effort ladder — default `high`, `xhigh` rare, never `ultra`/`max`.** The
  launcher now pins `CLAUDE_CODE_EFFORT_LEVEL=high` when unset (it was an implicit
  `xhigh` — theo's "rare" over-spend tier); override per dispatch for a
  harder/cheaper task. `ultra` is unreachable (see Effort mapping above); `max` is
  reachable but its codex juice is undocumented — avoid it.
- **Lane's declared window raised to 900k (HIMMEL-1833, 2026-08-17 operator
  ruling) — the launcher's own `CODEX_CONTEXT_WINDOW` default stays 272000,
  unchanged.** The operator ruled to declare 900k for this lane (matching
  hermes-oneshot's fresh measurement, see below), accepting that it doubles
  billing past the old ~272k cliff on any dispatch that opts up to it via
  `CODEX_CONTEXT_WINDOW=900000` — but the launcher's own code still WARNS past
  its ~372k backend-window ceiling for THIS path (CLIProxyAPI), so the
  272000 default was left as-is rather than moved to a figure the launcher's
  own evidence says this backend may reject (Codex briefly exposed 372k →
  silent 2× before reverting).
- **Subagent fan-out multiplies codex spend — linearly, not by parent-context
  copy.** Claude Code gives each subagent a FRESH context (see the codex-CLI
  contrast below), so the claudex lane avoids theo's worst multiplier (the v2
  full-history copy); still, every subagent turn is a separate gpt-5.6-sol
  consumer on the codex bank, so fan out deliberately and chunk big plans.

Two of theo's rules are **codex-CLI-specific, not claudex levers** — they belong
to the raw `codex-exec` / hermes gpt lanes (HIMMEL-1001 item 3, deferred), not
this Claude Code harness: the **v2 subagent layer that copies the entire parent
history** (a Codex-harness mechanism; the claudex lane uses Claude Code's own
subagent context management) and **fast mode** (~2.5× per message; a Codex CLI
toggle with no Claude Code equivalent).

### claudex raised to 900k by operator ruling — CLIProxyAPI path itself unmeasured (HIMMEL-1833)

The 272k `CODEX_CONTEXT_WINDOW` default was a deliberate 2× billing-cliff
choice, not a hard ceiling — the real backend window for gpt-5.6-sol was
~350-372k, corroborated from TWO independent sources: this doc's own citation
([openai/codex#32486](https://github.com/openai/codex/issues/32486), ~372k,
~353k effective) and hermes' independently live-verified 350000 (hermes-agent
commit 522997543, 2026-08-16 — ~371k input completes OK, ~382k+ rejected with
`context_length_exceeded`). Two unrelated sources landing on the same number
is why 272000 was trusted rather than folklore.

The operator has since upgraded hermes and measured ~900K as what was
actually attainable there (hermes v0.20.2, 2026.8.16, upstream commit
`bab7be3c`, 2026-08-17 — see `lanes.json`'s `$context-note`). Shown that
raising claudex to match doubles billing past the old 272k cliff, the
operator ruled to raise the LANE's declared window anyway (HIMMEL-1833,
2026-08-17): `lanes.json`'s `context.windowTokens` for `claudex` now reads
900000. This is a RULING, not a fresh measurement — the 900K figure is
hermes' own, measured inside hermes itself; the CLIProxyAPI path this lane
actually dispatches through remains UNMEASURED at 900K, an open, named gap.
The launcher's own `CODEX_CONTEXT_WINDOW` default is deliberately left at
272000 rather than moved to match — its own code already WARNS above the
~372k backend-window ceiling it has evidence for on this path, so 900000
would trigger that warning on every default invocation, not confirm the
lane is safe there. `CODEX_CONTEXT_WINDOW` stays a genuine
per-invocation-overridable lever (see the env table above) for a caller who
wants to opt UP toward the ruled 900k figure and accept the risk, or stay at
the evidence-backed 272000/353000 range.

Two OTHER levers existed for verifying the CLIProxyAPI path on its own
evidence (as distinct from the operator-ruling override above) — one is now
APPLIED, one remains UNTESTED, not refuted:

1. **`CLAUDE_CODE_MAX_CONTEXT_TOKENS`** — an official, documented,
   name-independent Claude Code env var for declaring an unrecognized model's
   context window. Distinct from `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (which only
   sets the compaction *threshold*, not the declared window). **APPLIED
   (HIMMEL-1887):** the launcher now exports it, tied to
   `CODEX_CONTEXT_WINDOW`. Evidence: Claude Code resolves the effective
   compact window as `min(modelWindow, configured)`, and for a model absent
   from its catalog (gpt-5.6-sol) the modelWindow falls back to a hardcoded
   `200000` — so `CODEX_CONTEXT_WINDOW` was inert, silently clamped to 200k,
   until this export declared the window. Both env vars get the SAME value so
   the clamp is structurally unreachable; guarded by
   `scripts/parity/test-launcher-context-env-parity.sh`.
2. **The `gpt-5.6-sol[1m]` model-name suffix** — the same convention that
   makes `glm-5.2[1m]` a real 1M lane. Status: **untested through the real
   path, not refuted.** A direct probe of CLIProxyAPI with the suffix already
   attached returned `HTTP 400 unknown provider for model gpt-5.6-sol[1m]`
   (2026-08-17) — but Claude Code's own documented behavior is to STRIP the
   `[1m]` suffix before the provider ever sees it, so that probe tested a
   request shape Claude Code never actually sends and settles nothing about
   the real path. Recorded here specifically so nobody re-probes the wrong
   layer and mistakes a proxy-level rejection for an answer about Claude
   Code's actual behavior.

### spawn-claudex dispatch path (`scripts/telegram/spawn-claudex.ts`, HIMMEL-1003)

**What:** the codex-lane twin of `spawn-glm` (HIMMEL-654/726) —
lets a parent Claude session hand a scoped implementation chunk to an inline
gpt-5.6-sol worker running the FULL himmel harness (skills/hooks/guardrails/
worktree) on the **codex weekly bank**, with the same review/merge contract as
the GLM lane. `spawn-claudex.ts` dispatches THROUGH `claude-codex` itself
(`bash <primary-repo>/scripts/claude-codex --permission-mode <mode>
<pointer-prompt>`, cwd = the minted worker worktree) rather than
re-implementing any of its trust-boundary guarding — it sets NO `ANTHROPIC_*`
var and builds no GLM-style env block; the launcher owns the entire PHI/
egress/env-sweep/proxy chain (the invocation is by the PRIMARY checkout's
absolute path, since a worktree lacks the gitignored `.env` the launcher
resolves its key from). Own-branch mode mints `claudex/<slug>`
(`.claude/worktrees/claudex+<slug>`); `--branch <existing>` selects
shared-branch mode (reuses `scripts/lib/shared-branch-lock.sh` under the
`"codex"` lane name, serializing writers onto an existing PR branch — the
same iterative CR-fix-round pattern as GLM's shared mode). Sessions live
under `<BRIDGE_ROOT>/claudex-sessions/` (a sibling of `glm-sessions/`);
`meta.json` records `lane: "codex"`.

```
bun scripts/telegram/spawn-claudex.ts "<prompt>" [--cwd <dir>] [--name <slug>] [--branch <existing>] [--timeout-mins <n>] [--permission-mode <mode>] [--effort low|medium|high|xhigh] [--model gpt-5.6-sol|gpt-5.6-terra|gpt-5.6-luna] [--force]
```

**Codex weekly bank preflight (HIMMEL-1003 D4):** reads the LAST
`"secondary":{"used_percent":<N>` occurrence from a bounded tail read of
`~/.codex/logs_2.sqlite` (the rollout log; `secondary` = weekly, `primary` =
5h) — fail-**OPEN** on any read error (a cold/absent log never bricks a
dispatch). WARNs to stderr at `CLAUDEX_BANK_WARN_PCT` (default `80`);
**REFUSES (exit 2) BEFORE any worktree side-effect** at `CLAUDEX_BANK_REFUSE_PCT`
(default `90`) unless overridden (`CLAUDEX_BANK_OK=1` or `--force`) — a
capped worker dies mid-run, so the tree survives but the work is lost.

**Effort (HIMMEL-1001):** `--effort` is optional; unset lets the launcher's
own `${CLAUDE_CODE_EFFORT_LEVEL:-high}` default apply. `spawn-claudex.ts`
REFUSES `--effort max` (undocumented codex juice) and `--effort ultra`
(unreachable — Claude Code silently falls back to `xhigh`) at parse time,
pointing back at this section.

**Model tier (HIMMEL-1464):** `--model` is optional and selects the GPT-5.6
tier for one dispatch by setting `CODEX_MODEL` in the worker's child env —
exactly how `--effort` sets `CLAUDE_CODE_EFFORT_LEVEL`. Unset lets the
launcher's own `${CODEX_MODEL:-gpt-5.6-sol}` default apply. Accepted values are
`gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`; anything else is a parse-time
refusal (exit 2) pointing back at this section.

The allowlist is deliberately scoped to **this flag**, not to the launcher.
`scripts/claude-codex`'s own `CODEX_MODEL` knob stays unvalidated because its
documented contract is "all overridable per task" against whatever the local
CLIProxyAPI `/v1/models` serves — which today includes `gpt-5.4`,
`gpt-5.4-mini`, `gpt-5.5`, `gpt-5.3-codex-spark` and the image models beyond
the three tiers above. Hardcoding the triple at the launcher would break every
one of those direct `CODEX_MODEL=… cc-codex` uses; a NEW interface can be
strict without breaking an existing contract. Launcher-side validation against
the proxy's *live* model list stays open on HIMMEL-1464.

Verifying a tier actually took effect: the worker transcript's `model` field is
**not** sufficient — `claude-codex` exports `ANTHROPIC_MODEL="$CODEX_MODEL"`
and Claude Code records the model it *sent*, so that field only proves the env
var propagated. Corroborate against CLIProxyAPI's own request log, or probe with
`CODEX_MODEL=<tier> scripts/claude-codex --preflight-only`, which issues a real
`/v1/messages` call carrying the model. (A `/v1/models` listing proves even
less — the registry GET stays 200 during an OAuth refresh gap.)

Dispatch this lane through `scripts/telegram/dispatch-lane.sh`, invoked with
the Bash tool's `run_in_background: true`. The registry maps the generic brief,
cwd, name, branch and model options onto `spawn-claudex.ts`; it maps no log or
timeout flag for this lane — the dispatcher enforces the timeout around the
worker process itself, independently of the lane command.
The dispatcher waits once and returns final `meta.json` status, worker branch,
diffstat, outbox tail, and failure log; the parent owns review + merge. Claudex
is registry-marked dormant pending the lane rethink (HIMMEL-1954 worker git
permission surface + HIMMEL-1966 subagent-control probe) and requires the
explicit `CLAUDEX_LANE_OK=1` opt-in.

**HIMMEL-1003 v1 scope — deferred to a followup ticket:** cap-guard /
arm-on-cap resume scheduling (GLM cap-window classification +
`arm-resume.sh` scheduling — a generic sentinel only marks a capped run
`capped` in `meta.json`; no resume is armed), a quota-gauge ledger row for
this lane, the grants/escalation channel (`--grant`/`--autonomous`/
`--carry-from`), and an `await-claudex-worker.sh` twin of
`await-glm-worker.sh` (until then, poll `meta.json` directly — see the agent
def).

**Acceptance:** `scripts/telegram/spawn-claudex.test.ts` (plan-function
refusal branches for both modes, bank-preflight parsing incl. warn/refuse/
override/fail-open, `--effort` refusal branches, dispatch-command
construction against `claude-codex` with no `ANTHROPIC_*` var, shared-branch
lock lifecycle against a real temp repo + the real lock script).

**Bash convenience shims (HIMMEL-1012):** `scripts/shell/himmel-offload-shims.sh` installs idempotent `cc-codex` / `cc-glm` functions into `~/.bashrc` for Git Bash and WSL.

---

## claude-routed + omniroute-config-lint (`scripts/claude-routed`, `scripts/omniroute-config-lint.sh`, `.ps1` twins, HIMMEL-666)

**What:** the WS2 OmniRoute-pilot wiring pair. `claude-routed` is a
copy-and-edit variant of `claude-glm` (the WS1 extensibility seam): identical
PHI/egress guard, config-dir seeding, flag handling and exit codes — only the
backend block differs. It points Claude Code at the LOCAL loopback OmniRoute
router (`ANTHROPIC_BASE_URL=http://127.0.0.1:$OMNIROUTE_PORT`, default port
`20128`; host fixed — the router is loopback-only by charter), authenticates
with a router-issued client key `OMNIROUTE_API_KEY` (shell env first, else the
himmel repo `.env`; the Z.ai key never appears in this launcher), keeps the
GLM tier-alias mapping (`glm-5.2[1m]`/`glm-4.7`), and seeds its own isolated
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
findings / 2 usage / unreadable / unparseable input (mirrors the script
header; covers wrong arg count, an unreadable file, invalid JSON, and a
non-object JSON root).

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
`--model opus` (→ `glm-5.2[1m]`) and ignore `TELEGRAM_CLAUDE_MODEL`. Sessions live
under `<BRIDGE_ROOT>/glm-sessions/` (default `~/.claude/handover/bridge/`) —
**outside** the poller's `sessions/` tree, so nothing here is double-spawned or
Telegram-flushed. A blocked worker can record a capability request and degrade
gracefully via the **escalation channel** — `spawn-glm --grant`/`--autonomous`
pre-seed, an `adjudicate list|grant|refuse` CLI, and a per-session append-only
`grants.jsonl` the deny-hook honors on one arm (TTL/use-bounded, fail-closed).
Full loop, permission guidance, escalation channel, and honest enforcement
inventory in [`docs/glm-offload.md`](glm-offload.md).

```
bun scripts/telegram/spawn-glm.ts "<prompt>" [--cwd <dir>] [--name <slug>] [--timeout-mins <n>] [--permission-mode <mode>] [--arm-on-cap | --no-arm-on-cap]
```

Prints exactly three inspect-contract lines on exit: `session-dir:`,
`transcript-dir:` (`~/.claude/projects/<escaped-worktree-cwd>/`), `exit:`.
**Cap guard (HIMMEL-654):** detects the z.ai 5-hour usage cap (429), labels the
run `capped` in `meta.json` (`cap_window`/`resume_at`/`cap_source`), and by
default (`--arm-on-cap`) arms a resume at the cycle reset; `--no-arm-on-cap`
writes `resume_at` without arming. Preflight warns at `GLM_USAGE_WARN_PCT`
(default `80`). Detail: [`docs/glm-offload.md`](glm-offload.md#cap-guard-himmel-654).
Exit codes: **2** usage error / plan refusal (non-himmel cwd, settings
conflict, missing ZAI key); **3** guard refusal (PHI marker, phi-root, denylist,
unreadable guard config); **1** operational failure; else the worker's exit code.

**Status:** offload-spike artifact. There is **no mechanical push block** — the
default-path pushurl tripwire was removed in HIMMEL-1961 (it fenced nothing and
could lose operator push configuration), so push protection is **contract-only**
and every dispatch report says so. A worker inherits operator git credentials
via the shared `~/.claude`; the in-session accident guard is
`block-glm-external-writes.sh` and the load-bearing control is the CR gate (no
GLM branch merges except by the validating session). D2 guards are
dormant-by-construction in v1 (himmel-worktree cwd scope). Uses GLM flat-rate
Coding-Plan quota, sanctioned by the operator directive — the per-token block
gates the WS2 router only, not this direct-CLI lane.

**Acceptance:** bun unit suite in the telegram bridge (guard red paths, env
builder block + missing-key throw + quote-strip, `runSession` lane env merge
with argv shape unchanged, GLM model pin ignoring `TELEGRAM_CLAUDE_MODEL`,
settings-conflict preflight, prompt composition
embedding the minted session paths); the live GLM-lane acceptance + offload-loop
legs are recorded in [`docs/glm-offload.md`](glm-offload.md).

---

## Registry-driven implementation dispatch (`scripts/telegram/dispatch-lane.sh`, HIMMEL-1942)

**What:** One Bash dispatcher for every available `class: "impl"` registry lane.
The parent invokes it directly with the Bash tool's `run_in_background: true`;
no Claude wrapper agent supervises or polls the worker. Session-shaped lanes
retain their chokepoint's isolated worktree/session behavior. One-shot lanes get
a dispatcher-owned worktree, session directory, metadata, and process-tree
deadline. Every outcome returns a compact status, diffstat, outbox, and failure
log report; the parent still owns review + merge.

```bash
Bash(run_in_background=true) -> bash scripts/telegram/dispatch-lane.sh --brief-file <path> --name <slug> [--lane <id>] [--timeout <seconds>]
```

Lane selection is registry-driven: `--lane` > `HIMMEL_IMPL_LANE` > the
`lanes.local.json` `defaultImplLane` overlay > the tracked registry default.
The tracked registry declares no `defaultImplLane` (impl routes to native
Claude subagents only — operator ruling 2026-08-19, HIMMEL-1967): an
unqualified dispatch refuses and names the Agent-tool path instead of
silently spending a GPT-backed bank. Unavailable choices fail with exit 2 and
list available impl lanes; they never silently spend a different bank.
`--context blank` is the default, while
`--context fork --context-file <path>` prepends explicitly delimited inherited
background. Test: `bash scripts/telegram/test-dispatch-lane.sh`.

---

## Other delegation-lane dispatch chokepoints (`scripts/lanes/lanes.json` registry, HIMMEL-689)

The lanes below are registered in `scripts/lanes/lanes.json` (the `/lanes`
source of truth) but don't otherwise get a full write-up in this file — their
`bestFor` field in the registry IS the authoritative description (effort,
traps, roster caveats); restating that prose here would just create a second
copy that drifts (HIMMEL-1021 class; see also
[`lane-calibration.md`](internals/lane-calibration.md#non-claude-lane-calibration)).
What's pinned here is the **exact dispatch shape** — several of these lanes
enforce a wrapper chokepoint, and calling the underlying binary bare is either
wrong (not on PATH) or bypasses the wrapper's guards (hook-blocked).

| Lane (`lanes.json` id) | Dispatch — never call the bare binary/underlying CLI directly where a chokepoint is named |
|---|---|
| GitHub Copilot CLI (`copilot-cli`, HIMMEL-772) | `bash scripts/copilot/dispatch-copilot.sh --worktree <wt> <args>` — enforces allow-list passthrough, worktree containment, granular grants |
| hermes one-shot (`hermes-oneshot`) | `bash scripts/hermes/dispatch-trusted.sh <args>` (trusted-engine writes) or `scripts/hermes/invoke.sh` (untrusted default `todo` toolset) — the `/pr-check`-internal `hermes-critics`/`codex(paid)` critic lanes route through this same chokepoint; see the CR Scripts section below |
| codex CLI sandbox (`codex-exec`, HIMMEL-741) | `bash scripts/codex/dispatch-codex-exec.sh --worktree <wt> <args>` — ACL preflight fail-closed, `gpt-5.5` pin |
| codex WSL lane (`codex-wsl`, HIMMEL-999) | `bash scripts/codex/dispatch-codex-wsl.sh --distro <name> --clone <in-distro-abs-path> [--brief-file <path>] [args...]` — raw `wsl ... codex exec` is hook-blocked |
| Antigravity CLI (`antigravity-cli`) | `agy -p <prompt>` (headless; PATH-installed CLI, no repo wrapper — permission flags only, no hook surface today) |
| ollama, local (`ollama-local`) | `ollama run <model>` — bare model name only; zero-egress guarantee is structural (cloud requires the explicit `-cloud` suffix) |
| Ollama Cloud (`ollama-cloud`) | `ollama run <model>-cloud` — same CLI, opt-in cloud suffix; content egresses to ollama.com |
| OpenRouter free models (`openrouter-free`) | `OPENROUTER_API_KEY`-gated API calls, not a CLI dispatch; `scripts/openrouter/free-watch.sh` (below) watches catalog churn, it does not dispatch work |

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
**Auto-rewriting:** himmel's full machine-setup scripts run `rtk init -g` once (then reconcile the entry into the `rtk-hook-guard.sh` wrapper — see [`docs/setup/new-machine.md`](setup/new-machine.md#3a-expected-post-setup-state-no-hook-installed-banner) §3a). **Do NOT run `rtk init -g` manually outside setup** — it appends a duplicate bare hook entry; use `bash scripts/lib/reconcile-rtk-hook.sh ~/.claude/settings.json <himmel-path>` to collapse duplicates instead (see "Reconcile" below). Without any hook installed, prefix commands manually with `rtk`.
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

## tokensave (MCP server)

**What:** Code-graph MCP server (single Rust binary) — indexes a repo into a symbol-level knowledge graph (per-project `.tokensave/` sqlite DB) and serves exploration + analysis tools over it. The harness's designated organ for symbol-level code ops in the retrieval routing (qmd finds content, graphify explains structure, **tokensave serves code** — CLAUDE.md, HIMMEL-621).
**MCP tools:** `tokensave_context` (natural-language exploration — first call for any code question), `tokensave_search`, `tokensave_callers` / `tokensave_callees`, `tokensave_impact`, plus a wide discovery/analysis/edit surface.
**Install + register:** binary via scoop (Windows) / brew (macOS) / `cargo install tokensave`, then `tokensave install --agent claude`; per-repo `tokensave init` once, `tokensave sync` to refresh. Full steps: [`docs/setup/new-machine.md` §8](setup/new-machine.md#8-mcp-servers).
**Tier:** T0 always-on — the one server included in *every* lean profile (`.claude/mcp-profiles/profiles.json`).

---

## MCP fleet — tiered lean profiles (`scripts/mcp/build-mcp-profiles.mjs`, HIMMEL-719)

**What:** Every session spawns the full MCP fleet at startup (per-session, not
shared) — ~6 node procs/session that multiply across concurrent sessions. Lazy
per-server spawn is unsupported upstream. The verified lever: `claude
--strict-mcp-config --mcp-config <file>` loads **only** the servers named in
`<file>`, ignoring `~/.claude.json` and enabled plugins.

**Generator:** `node scripts/mcp/build-mcp-profiles.mjs` reads the machine's live
`~/.claude.json` and emits `.claude/mcp-profiles/local.<name>.json` (gitignored —
they carry absolute paths + secrets). Committed = the generator, the
`profiles.json` manifest, and `.claude/mcp-profiles/README.md`. `--list` prints the
profile→server map.

**Fleet-map / tier admission** — every MCP admission names its tier:

| Tier | Meaning | Members |
|---|---|---|
| T0 always-on | single pinned binary, used most sessions | tokensave |
| T1 shared HTTP | remote/daemon singleton, 0–1 local procs total | context7 (remote), atlassian, huggingface, vercel |
| T2 profile-scoped | in a `--mcp-config` profile, launched per lane | playwright, chrome-devtools, obsidian-vault, onepassword |
| T3 env-gated | default-OFF `mcp-gate.sh`, activated by launch env var (HIMMEL-591) | telegram-himmel, luna-correlate |
| TX CLI-first | no server; a CLI + skill (enforced by `block-backend-tier`) | jira (over atlassian), gh (over github), firecrawl |

Launch recipes, lane→profile mapping, and the operator-review-gated default-fleet
trim: `.claude/mcp-profiles/README.md`.

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

## Install manifest lint + secrets manifest (`scripts/install/manifest-lint.mjs`, `scripts/himmelctl/lib/secrets-manifest.json`)

`scripts/install/manifest-lint.mjs` (HIMMEL-756 T1.2, zero-dep ESM) validates
`scripts/install/manifest.json` against the closed schema `himmelctl`'s
install engine consumes: exactly the required item keys plus the optional
schema-v2 `install`/`unwire`/`removable`/`offboard` quartet; `kind` and
`probe.type` drawn from fixed vocabularies (`kind: hardening` is explicitly
refused); unique ids; `deps[]` resolving to real ids and forming a DAG (DFS
cycle detector); a closed per-probe-type descriptor shape (an unknown or
extra field is a lint error, same as a missing one — one shape per
`probe.type`, including the externalization-era `cmd:telegram_getme`,
`cmd:whisper_ready`, `cmd:python_interpreter`, `distinct-tokens` and
`luna-sources` types PR-B added); an install/unwire `wire` pair must target
the SAME thing; and a `config`-type install descriptor's `key`/`keys` must
cover exactly what its own probe checks. Run by hand after editing the
manifest: `node scripts/install/manifest-lint.mjs` — currently `OK (46
items)`, not wired into CI or a pre-commit hook.

`scripts/himmelctl/lib/secrets-manifest.json` (HIMMEL-2176 Task 5, design
A14/A15) is the single source for both `himmelctl install`'s secrets walk and
`.env.example`'s generated secrets block (12 entries as of PR-B/PR-C) —
descriptive metadata only, per A8.2 — never a value, never a real credential.
Per entry: `name`/`storage`/`obtain`/`probe`/`required`/`feature`, plus two
optional fields PR-C added so a verdict lands on the right credential —
`sources` (the `fetch-health` source ids this credential feeds, so a
*configured* source is genuinely probed rather than assumed) and `pairedWith`
(so a half-configured pair reports `unconfigured` naming its sibling instead
of blaming the wrong one). 9 of the 12 entries carry `sources`, 4 carry
`pairedWith`. `feature` (HIMMEL-2305) is a closed enum —
`core|vault|cadence|bridge|whisper|lane:codex|lane:hermes`
(`scripts/himmelctl/lib/adopter-profile.js`'s `FEATURE_IDS`, mirrored in
`scripts/lib/gen-secrets-doc.mjs`) — naming which recorded wizard selection
the secret belongs to: 10 entries are `vault`, `TELEGRAM_BOT_TOKEN` is
`bridge`, `WHISPER_MODEL` is `whisper`. The wizard's secrets walk scopes
itself to the recorded profile's active features (an unselected feature's
secrets are skipped, with one honest line naming how many and why); the
TRACKED `.env.example` block stays the full union for every adopter, only
reorganized into labeled per-feature sections. `scripts/lib/gen-secrets-doc.mjs write` re-renders the block
between its BEGIN/END markers from the manifest; `check` / `check --staged`
diff the rendered block against what's committed and exit 1 on drift. The
pre-commit hook `secrets-doc-drift` (`.pre-commit-config.yaml`) runs `check
--staged` on any commit touching `secrets-manifest.json` or `.env.example`,
so the wizard's secrets walk and the example file can never drift apart once
committed.

---

## Release Scripts (`scripts/`)

- `scripts/gen-changelog.sh` — **CHANGELOG generator** (HIMMEL-454; version-tag grouping + `--check` + morning-report wiring HIMMEL-2250). Writes `CHANGELOG.md` from conventional-commit history: `feat` → Added, `fix` → Fixed, `chore|refactor|docs|test` → Changed, everything else → Other. Groups commits by version tag (`v[0-9]*`, newest-first): each tag gets its own `## [<tag>] - <date>` section, with `## [Unreleased]` covering everything after the newest tag; a tagless repo gets a single `## [Unreleased]` over all history. `--check` writes nothing and exits 1 with an entry count when `CHANGELOG.md` is stale — the primitive the daily `scripts/overnight/morning-report.sh` "Changelog freshness" section reads, since the file is regenerate-on-demand (never per-commit/per-worktree, which would guarantee merge conflicts) so staleness needs a visible surface. Idempotent on immediate re-run; do not hand-edit the generated file. `.ps1` twin: `scripts/gen-changelog.ps1`.

---

## Network Scripts (`scripts/net/`)

- `scripts/net/router.sh` — **home router CLI** (HIMMEL-2055). curl-only client for the ASUS TUF-AX6000's stock ASUSWRT admin API (`login.cgi`/`appGet.cgi`/`applyapp.cgi`), so DHCP reservations and router facts stop being "operator at the LAN-only JS UI". Verbs: `status`, `clients`, `nvram <key>...`, `reservations`, `reserve <mac> <ip> [name]`, `unreserve <mac>`, `set --rc <service> key=val...`. Creds from `.env` (`ROUTER_WEB`/`ROUTER_USER`/`ROUTER_PASS`), never printed. Test: `scripts/net/test-router.sh` (offline, sources the script for the staticlist encode/decode + validator helpers).

---

## Luna Scripts (`scripts/luna/`)

Scripts for luna vault maintenance and session import. Operator-invoked
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
- `scripts/luna/fold-chat-history.py` — Fold an exported provider chat history (ChatGPT now; Gemini rides HIMMEL-391) into the luna vault as `chats/gpt/` notes (provider id maps to a vault subdir, e.g. `chatgpt` → `gpt`) + gitignored assets; create-only idempotent, `--dry-run` first (HIMMEL-832).
- `scripts/luna/enrich-chat-notes.py` — **Chat-note enrichment pass** (HIMMEL-833; provider-pluggable HIMMEL-1167).
  `--provider deepseek|codex|glm|claude` (default `deepseek`) summary + vocab-constrained tags + locally-computed Related Notes for
  `enriched: false` chat-import notes under `<vault>/chats/`; flips each note to
  `enriched: true` (incremental, interruptible; rewrites existing notes in
  place — sibling of the create-only `fold-chat-history.py`). Each provider is egress-matrix-gated under purpose `enrichment`
  (permitted: `claude` only, via the `anthropic → allow` rule — `deepseek` was de-listed by HIMMEL-1257 and `glm`/`zai-glm` by HIMMEL-2224, and `codex` stays default-deny until an adopter ratifies a cell; the entries remain so the gate refuses them legibly), ledgered per run
  (`GRAPHIFY_LEDGER`); `deepseek`/`codex` use OpenAI chat/completions, `glm` (via z.ai anthropic-compat)/`claude` use the Anthropic Messages API. DeepSeek off-peak advisory. `--dry-run` first.
- `scripts/luna/fetch-health.py` — Daily no-LLM health probes for luna
  clip-source fetch integrations. The registry (`build_probe_registry`) carries
  **ten** source ids, several per platform: `reddit`, `x-fxtwitter`, `x-media`,
  `x-twitter-cli`, `instagram-embed`, `instagram-media`, `youtube-playwright`,
  `github`, `bitbucket`, `firecrawl`. The full run (armed by `pipeline-cadence.sh`'s
  fetch-health leg) probes every source, writes `~/.himmel/fetch-health.json`
  (`last_success_timestamp` preserved per source across runs), and exits 0 iff
  every source is `ok`. `--probe <source>` (HIMMEL-2176 Task 2) runs exactly
  one probe through the SAME shared registry the full run uses — no separate
  code path to drift — prints `{"status", "reason"}` JSON, and exits 0 iff
  that probe's own status is `ok`; it deliberately never writes the state
  file, so a manual or wizard-driven single-source check can't perturb the
  scheduled run's bookkeeping. An unrecognized `--probe` source is an argparse
  usage error (nonzero exit, message on stderr), not a JSON payload. This is
  the seam `himmelctl install`'s secrets walk and the `luna-sources` manifest
  probe (above) call to verify one configured source without waiting for the
  next scheduled run. Note the two source sets are **not** identical: the
  manifest's `luna-sources` list carries nine of this registry's ten ids —
  `github` is absent, so `himmelctl status` never probes it even though
  `--probe github` works (HIMMEL-2291).

---

## Graphify map cadence (`scripts/graphify/`, HIMMEL-825/826)

Keeps the graphify knowledge-graph maps fresh and publishes a compact, tracked
view into the vault — the bridge between the derived graph and the KB.

- `scripts/graphify/publish-graph-map.mjs` — curator. Parses a
  `graphify-out/GRAPH_REPORT.md` and emits a small `type: moc` note (Summary,
  God Nodes, Surprising Connections, top-N largest communities + provenance
  frontmatter). The raw report is 3k+ lines / 150KB+ (one heading per community,
  1500+ of them) — too big to track; this extracts just the navigational value
  (~100 lines / ~10KB) so the MOC is git-diffable and qmd-useful. Pure core
  (`parseReport`/`renderMoc`) unit-tested by `test-publish-graph-map.mjs`.
- `scripts/graphify/refresh-graph-map.sh` — schedulable orchestrator. Per corpus:
  copies the vault's markdown to a scratchpad carrying a `.graphify-corpus`
  marker (fence-safe — extraction NEVER touches a live vault), runs
  `graphify --update` (incremental — only changed files re-extract) + `cluster-only`,
  promotes the refreshed `graph.json` + `GRAPH_REPORT.md` into the corpus's
  repo-local `graphify-out/` (the "latest in repo" substrate), then publishes the
  curated MOC to the vault's `60-Maps/`. `--no-update` republishes from an
  existing report without re-extracting. DeepSeek peak-window advisory (never
  hard-refuses). Hermetic test: `test-refresh-graph-map.sh` (stubs graphify).
- **Cost + cadence:** a full ecosystem sync is ~$2 (measured 2026-07-09);
  `--update` is a fraction of that, so a **daily** off-peak run is affordable.
  Schedule per corpus (example, Git Bash on Windows via schtasks or cron):
  `bash scripts/graphify/refresh-graph-map.sh --name luna --corpus-root <vault> --backend kimi --maps-dir <vault>/60-Maps --title "Graphify Luna Vault Map" --slug graphify-luna-map --corpus-tag luna`
  (`--backend kimi` is the ratified luna extraction provider — moonshot, allow+log on
  luna-personal, HIMMEL-1748; a native graphify backend, it only needs `MOONSHOT_API_KEY`
  from `.env`. `--backend glm` was the prior lane but zai-glm is de-listed as of
  HIMMEL-2224, so on luna corpora it now fails closed at the egress preflight).
  **Throttle knob (`GRAPHIFY_MAX_CONCURRENCY`, default 6):** concurrency 6
  overshoots Z.ai's request limit — `--backend glm` 429s (`rate_limit_error`
  1302) on most chunks and the regen fails. `GRAPHIFY_MAX_CONCURRENCY=1`
  serializes the extraction + cluster-only LLM calls, which eases request
  pressure but is NOT true rate-limiting (no pacing/backoff) and cannot beat a
  hard per-key quota — an exhausted quota 429s even serialized (observed
  2026-07-21: chunk 1 failed at concurrency 1). Band-aid for the full-extraction
  cost; the durable fix (seed graphify's semantic cache so a regen is a small
  incremental, not a 255-chunk full run) is HIMMEL-1097.
  Model: the derived graph.json + full report stay repo-local (gitignored,
  regenerable); only the curated MOC is committed to the vault, so each refresh
  shows the map's drift as a small git diff.
- `scripts/luna/graphmap-cadence.sh` — the scheduler that arms this refresh
  (HIMMEL-829, follow-up to HIMMEL-825; cadence inverted by HIMMEL-1948).
  A SEPARATE OS-scheduler sibling of `pipeline-cadence.sh` (deliberately not a
  pipeline-cadence leg — that runner's invariant is "every task = a claude
  session", and a graph refresh is a deterministic script, no claude).
  `arm`/`status`/`disarm` register **four** tasks. The semantic pair
  (`HIMMEL-GraphMap-Luna` / `-Himmel`, default Sunday 13:00/13:20 local,
  staggered) is now **weekly**, on the **`kimi`** backend — off the Anthropic
  interactive bank — each firing `refresh-graph-map.sh` for its corpus. The
  structural/AST pair (`HIMMEL-GraphMapAst-Luna` / `-Himmel`) is **asymmetric**
  since HIMMEL-1960: **himmel hourly** (:15 past), **luna daily** (00:05). Both
  legs are free; the asymmetry is about the artifact, not cost — luna is a live
  vault with an auto-committer, so an hourly in-place update meant ~24 commits a
  day of graph churn, while himmel has no auto-committer (`/graph-publish` owns
  shipping its graph). The same decision gitignores luna's **top-level**
  `graphify-out/`, so that vault's graph is now a per-machine artifact: a fresh
  clone elsewhere has none until it refreshes there. Each leg fires
  `scripts/graphify/ast-update.sh <abs-path>` — a thin
  wrapper that takes the semantic leg's per-out-dir promote lock (skip-not-wait)
  before running `graphify update <abs-path> --force` itself, so the free
  structural AST re-parse can never race the weekly semantic refresh's write to
  the same `graphify-out` (both sides resolve `GRAPHIFY_OUT` identically as of
  HIMMEL-1960 — `refresh-graph-map.sh` honours the relative form and refuses an
  absolute one, which its scratch-then-promote model cannot express): no LLM,
  no bank, no `bank-preflight`, never shells
  `claude` — and is **free**. schtasks (Windows, StartWhenAvailable XML) / crontab
  (POSIX); dedup-guarded; hermetic test `test-graphmap-cadence.sh`. Arming is
  an operator flip (weekly `kimi` spend on the semantic pair only — the AST pair
  costs nothing), not auto-armed. `arm` now REFUSES when the semantic backend's
  credential is missing. It must be readable from the primary checkout's
  `.env` (`kimi` -> `MOONSHOT_API_KEY`) — the source `refresh-graph-map.sh`
  loads at fire time. A value merely exported in the arming shell is NOT
  accepted: both schedulers start with their own environment and the generated
  runners carry no secrets, so it cannot be shown to reach the run. Without
  this check an arm could report ARMED while every weekly run failed
  unattended (HIMMEL-1960):
  `bash scripts/luna/graphmap-cadence.sh arm` (`--luna-time` / `--himmel-time` /
  `--vault` / `--force` / `--dry-run` / `--ast-only`).
  `--ast-only` (HIMMEL-2071) arms/dedup-checks ONLY the two free structural
  (AST) tasks, skipping the weekly semantic pair (and its backend credential
  requirement) entirely — a pre-existing semantic pair, if any, is left
  untouched. Lets the free legs re-arm independently of an operator ruling on
  the semantic pair's backend/egress. To ADD a missing semantic pair later,
  re-arm WITHOUT `--ast-only` and WITH `--force` — a plain re-arm (no
  `--force`) dedup-blocks on the already-armed AST tasks instead of adding
  the missing semantic pair.
  `status` also prints a per-log **run summary** (HIMMEL-1901 ask 3): the
  `tokens:` totals when the run finished, otherwise `NO tokens summary`, plus
  the last chunk reached and the count of hollow responses (each of which graphify bisects), with
  a `HOLLOW-BISECT STORM` marker past one chunk's worth (>15). graphify holds
  its token counters in memory and prints them only on the normal write path,
  so a run killed by the run deadline — or by a reboot, as on 2026-08-17 —
  leaves no totals to emit; the summary is reconstructed from the log after the
  fact so it survives any termination mode. The run itself is bounded by
  `GRAPHIFY_RUN_DEADLINE_SECONDS` (default 7200) in `refresh-graph-map.sh`
  (HIMMEL-1901 ask 4).

---

## qmd reindex cadence (`scripts/luna/qmd-*.sh`, HIMMEL-568)

Keeps the qmd search index from going silently stale. The index once sat 5 days
stale (luna `lastUpdated` 2026-06-22 with `needsEmbedding: 0`) while notes
written that week were simply not searchable — every qmd-backed workflow
(compounding, ingest, synthesis, recall) answered off a stale index and nothing
signalled it. Same runner/scheduler split as the graphify pair above.

- `scripts/luna/qmd-reindex.sh` — the RUNNER. `qmd update` (re-index changed
  files) then `qmd embed` (generate missing vectors), then a COMPLETENESS ASSERT:
  a second `qmd embed` that must report "All content hashes already have
  embeddings". That assert is the point — `qmd embed` has a session cap
  (`--timeout`, default 30 min), and a run that hits it exits 0 having embedded
  only PART of the pending set, leaving vectors lagging lex: the same silently-
  wrong state with a fresher timestamp. Distinct exit codes (3 update failed,
  4 embed failed, 5 embed incomplete) so a scheduler log says which half broke.
  Scope is ALL configured collections — `qmd update`/`qmd embed` default to
  everything and take `-c` only to NARROW, so nothing is hardcoded and a
  collection added later needs no edit. `--qmd-bin` pins the executable (the
  scheduler fires with a minimal PATH that lacks bun's bin dir); `--dry-run`
  previews. Does NOT fence the qmd MCP daemon. What was actually observed
  (2026-07-25): with the daemon running, a full `qmd update` + `qmd embed`
  completed without error and the daemon was still serving on the same PID
  afterwards. That is a process-survival + no-error observation, NOT a
  concurrency proof — nothing exercised reads racing the writes. It is the
  basis for not fencing today; if a fence is ever needed it belongs in the
  runner, not the scheduler. Hermetic test `test-qmd-reindex.sh` (stubs qmd).
- `scripts/luna/qmd-cadence.sh` — the scheduler that arms it. Deterministic-script
  shape (the graphmap sibling, NOT a pipeline-cadence leg): no claude session, no
  NUL stdin, no `--settings` fragment, so HIMMEL-128 does not apply at all.
  `arm`/`status`/`disarm` register ONE daily task, `HIMMEL-Qmd-Reindex`
  (default 05:00 local — AFTER the pipeline legs that WRITE to the vault
  (Harvest 02:00, Synthesize 03:00, Health 04:00) so the reindex picks up what
  they wrote instead of racing them, and clear of the graphmap slots 13:00/13:20).
  A full local refresh measured 16s + 24s, so daily is cheap. schtasks (Windows,
  StartWhenAvailable + IgnoreNew XML) / crontab (POSIX); dedup-guarded; hermetic
  test `test-qmd-cadence.sh`. Arming is an operator flip, never auto-armed:
  `bash scripts/luna/qmd-cadence.sh arm` (`--time` / `--force` / `--dry-run`).

---

## qmd index ship transport (`scripts/luna/ship-index*`, HIMMEL-1275)

Build the search index LOCALLY, ship the artifact to a machine that cannot build
its own. Measured 2026-07-25: the receiver station embeds at ~5 docs/min vs
~256 docs/min locally (50x), so an in-place reindex there was projected at
**~17 hours** and was killed mid-run. It RECEIVES, never builds. Consumes
HIMMEL-568's runner — ship AFTER a successful local reindex, not on a blind
clock.

- `scripts/luna/prepare-ship-index.mjs` — builds the shippable artifact.
  Consistent copy via SQLite's **backup API** (not a file copy, so it is safe
  while the local daemon is live), collection reconcile, **vec0 orphan GC**,
  VACUUM, then a self-check. Node rather than Python because the index carries a
  vec0 virtual table and Python's stdlib `sqlite3` cannot load vec0 on these
  boxes. Two facts it depends on, both verified against the live index:
  `vectors_vec.hash_seq == hash || '_' || seq` (underscore), and a vec0
  `TEXT PRIMARY KEY` **replaces rowid** so deletes must key on `hash_seq`.
  FTS needs no separate step — the `documents_ad` trigger cascades the
  `documents` delete into `documents_fts` (hand-deleting from that contentless
  fts5 table would corrupt it). Content is SHARED across collections
  (`luna-curated` indexes a subset of the luna vault), so orphan cleanup is
  "referenced by NO surviving document", never "belonged to a dropped
  collection". The source index is opened READONLY and never modified.
- `scripts/luna/ship-index-remote.ps1` — the RECEIVER half, copied over and run
  there. Daemon fence (the daemon is **bun**, not node — a node-only filter both
  misses it and matches dozens of unrelated processes), swap via a `.preship`
  copy that is **reaped on success and failure**, **WMI-parented restart**
  (`Invoke-CimMethod Win32_Process Create` — a child of the ssh session dies with
  the connection), then verify. It is a FILE rather than an inline command
  because a nested `\"` inside `ssh host 'powershell -Command "…"'` breaks cmd
  parsing.
- `scripts/luna/ship-index.sh` — the orchestrator: reindex → resolve the
  receiver's collection set → prepare → upload → run the receiver script →
  ship the graph. Distinct exit codes per stage (3 reindex / 4 prepare /
  5 upload / 6 receiver / 7 graph) so a failure says which half broke and
  whether anything reached the receiver.

**Reconcile policy: ship-only-what-the-RECEIVER-configures.** Its own
`qmd collection list` is the authority, so the ship can never create an orphan
collection there; and it REFUSES outright if the receiver expects a collection
the source lacks, rather than silently shipping an index missing it.
**Verify fails LOUD** if vectors lag lex after the swap — that is the exact
state a receiver station was found in (lex-current at 14,803 docs while
thousands of vectors were missing, answering semantic queries off the gap in
silence).

The graphify graph rides the same transport; **HIMMEL-1129 owns publishing** —
this moves the machine-to-machine leg only and never generates a graph.

Hermetic tests: `test-prepare-ship-index.sh` (33 assertions against REAL fixture
databases with real vec0 tables — reconcile, shared-content retention, orphan
GC including pre-existing ghost rows, FTS trigger cascade; skips cleanly when
better-sqlite3/vec0 are absent) and `test-ship-index.sh` (37 assertions —
argument handling, preflight, dry-run, per-stage failure attribution, and the
"a failed local build ships NOTHING" ordering guarantee, all against stubbed
ssh/scp/node). Neither needs a second machine; the actual swap is deliberately
never a CI test.

---

## Codex Cleanup Cadence (`scripts/cleanup/`, HIMMEL-892)

Windows-only scheduled cleanup for orphaned codex processes and stale MCP fleet.

- `scripts/cleanup/codex-sweep-cadence.sh` — Scheduler that arms a Windows scheduled task (`HIMMEL-CodexOrphanSweep`, default 09:00 local, repeating every 4h across the day) firing a persistent `.bat` runner with exit-code stamping. The runner fires `scripts/cleanup/sweep-codex-orphans.ps1 -Kill` (codex orphan-process reaper), then `scripts/codex/reap-mcp-fleet.ps1 -Kill` (MCP fleet killer), then `scripts/codex/reap-superseded-fleets.ps1 -Kill` (duplicate fleets under a LIVE app-server, HIMMEL-1309 — fires last, once the two orphan sweeps have removed everything whose supervisor is gone). `arm`/`status`/`disarm` subcommands with `--time HH:MM` (arm-only, 24h HH:MM), `--repeat-hours N` (arm-only, 0-23; 0 = daily only), `--force` (replace existing), `--dry-run` (preview). Dedup-guarded; hermetic test `test-codex-sweep-cadence.sh`. Arming is operator-invoked (Windows task maintenance); lean-invoke: `bash scripts/cleanup/codex-sweep-cadence.sh arm`. An already-armed pre-HIMMEL-1309 task keeps firing only the two old legs — `status` warns and nudges `arm --force`.
- `scripts/codex/reap-superseded-fleets.ps1` — Reports (default) / reaps (`-Kill`) MCP fleets that a still-LIVE codex app-server has superseded: it spawns a fresh fleet per client connection and never reaps the previous one, a leak both other reapers skip by design because the tree is legitimately live. Groups fleet roots by `(app-server, --cwd plugin | command tail)` and keeps the newest, gated by `-KeepNewest` (default 1), `-MinAgeMinutes` (default 30 — the parallel-tool-call protection) and a CPU-idle veto. Safety comes from lineage (a target must descend from a live app-server, which the telegram bridge / qmd MCP / claude session never do); app-server accumulation and unkeyable roots are reported, never reaped. Test: `scripts/codex/test-reap-superseded-fleets.ps1`.

---

## Upstream drift-fix cadence (`scripts/upstreams/`, HIMMEL-1323)

The REPAIR half of the nightly `fork-drift` drift-detection Action (HIMMEL-1046,
`check-plugin-drift.sh`), which only detects and files a tracking issue. Runs
LOCALLY on purpose (operator decision, 2026-07-28) rather than in CI — the
private repo has Actions off by design.

- `scripts/upstreams/apply-drift-bump.sh <name> <new-version> [--dry-run]` —
  deterministic pin bumper for one `tag_release`/`mode: base` entry in
  `scripts/upstreams.json`. Moves the in-repo pin literal (the entry's new
  optional `version_pin: {file, template}` field) and `synced_base` together,
  then re-parses and verifies; restores both files byte-identical on any
  failure. No network — the caller passes the target version in. Exit codes:
  `0` bumped, `1` already current, `2` usage/registry error (including a
  refused downgrade), `3` SKIP — no `version_pin` declared, not auto-bumpable
  (qmd is the standing case: its pin is a fork SHA, not a version), `4` bump
  failed (both files restored). Hermetic test: `test-apply-drift-bump.sh`.
- `scripts/upstreams/apply-tool-upgrade.sh <name> [target-version] [--dry-run] [--unattended]` —
  the `mode: probe` counterpart: upgrades an INSTALLED vendor CLI (rtk,
  twitter-cli) whose version lives on the machine, not in the repo, so there is
  no pin to move and no PR to open. Runs the entry's `upgrade.command` (an argv
  ARRAY, executed as argv — never through a shell), then RE-PROBES and requires
  the version to have strictly advanced: a command that exits 0 without moving
  the version is rc `4`, not success. Pass `target-version` (from the drift
  guard's BEHIND line) whenever you have it — the cadence always does. Without
  it, "already the newest release" and "the upgrade silently did nothing" are
  indistinguishable from inside the script, so an unchanged version reports rc
  `1` with the claim marked unverified instead of guessing; with it, not
  reaching the target is a hard rc `4`. `--unattended` — which the cadence always
  passes — refuses any entry not marked `upgrade.unattended: true`. That is the
  structural gate for the per-entry policy; read the registry for who is gated
  rather than trusting this line. As of 2026-07-28 BOTH probe entries are
  `unattended: true`: twitter-cli (Tier A) and rtk, which the operator approved
  that day, overriding its Tier B default (the entry's note records the
  reservation and the revert path). Exit codes: `0` upgraded,
  `1` already current, `2` usage/registry/**tool not installed** (it upgrades,
  it never bootstraps), `3` SKIP (no `upgrade` block, or operator-triggered
  only), `4` ran but the version did not advance. Hermetic test:
  `test-apply-tool-upgrade.sh`.
- `scripts/upstreams/resync-fork.sh <name> [--target <ref>] [--dry-run] [--push]`
  — the FORK counterpart, and the only honest repair for that class. When
  upstream tags past a fork's `synced_base`, bumping `synced_base` would claim a
  base the fork never rebased onto, so instead this rebases the fork's own delta
  onto the new upstream base **in a scratch clone**, audits that the delta is
  still strictly additive, and reports the resulting SHA. It never edits the pin
  and never writes to a remote without `--push` (which itself refuses a
  conflicted or non-additive rebase). Driven by a `fork` block on the registry
  entry (`fork_repo`, `upstream_repo`, `pin_file`, `pin_template`, `work_dir`).
  Exit codes: `0` clean + additive, `1` already on target, `2`
  usage/registry/tooling, `3` SKIP (no `fork` block), `4` CONFLICTED,
  non-additive, or a pin-literal failure (`PIN_FILE_MISSING`/`PIN_NOT_FOUND`/
  `PIN_AMBIGUOUS`, a stale registry pin — not a rebase judgment call) — a human
  decides. Hermetic test: `test-resync-fork.sh`.
- `scripts/upstreams/update-marketplaces.sh [--check]` (HIMMEL-2134) — re-syncs
  the installed Claude Code marketplaces that nothing else refreshes: the
  `mkt-manual` rows in `~/.claude/plugins/known_marketplaces.json` (`autoUpdate`
  off), which `check-plugin-drift.sh` reports BEHIND as `mkt:<name>` and which
  `/drift-fix` used to ignore because a marketplace re-sync is not a version bump
  and carries no repo diff. `autoUpdate:true` rows are skipped (Claude Code
  refreshes them at session start) and `himmel` is skipped twice over — it is
  chain item 2 of `himmel-update.sh`, where a failure must ABORT the update
  rather than be isolated. **Failure-isolated by design:** every row is attempted
  regardless of what the previous row did, and failures are reported together at
  the end. Exit codes: `0` all selected rows updated or none selected, `1` at
  least one row failed (the rest were still attempted), `2` cannot run (no
  `claude`, no `python3`, unreadable/malformed registry) — distinct from `1`
  because "could not look" is not "looked and found something broken". Both front
  doors call this one implementation: `himmel-update.sh`'s advisory block and
  `/drift-fix` step 2B. Test seams `DRIFT_KNOWN_MARKETPLACES` /
  `HIMMEL_UPDATE_CLAUDE_BIN`; hermetic test: `test-update-marketplaces.sh`.
- `scripts/upstreams/drift-fix-cadence.sh arm|status|disarm` — arms TWO daily
  local scheduled tasks (schtasks on Windows, crontab on Linux/macOS; sibling of
  `codex-sweep-cadence.sh` / `pipeline-cadence.sh`), each firing an INTERACTIVE
  `claude --model <M>` session (never `-p`/`--print`, HIMMEL-128):
  `HIMMEL-DriftFix` at 05:00 on the `/drift-fix` runbook, and
  `HIMMEL-ForkResync` at 05:30 on `/fork-resync`. Two legs rather than one
  because a fork re-sync can legitimately end "conflicted, a human must decide",
  and a stuck re-sync must not block routine pin bumps; ONE script rather than
  two because the arm/status/disarm machinery (locale-independent query
  classification, `StartWhenAvailable` XML, fail-closed crontab reads) is the
  part that is hard to get right and must not be copy-pasted. Flags (arm only):
  `--time HH:MM` (drift leg, default 05:00), `--resync-time HH:MM` (default
  05:30), `--model` (default sonnet), `--force`, `--dry-run`. Dedup-guarded;
  hermetic test `test-drift-fix-cadence.sh`. Arming is operator-invoked:
  `bash scripts/upstreams/drift-fix-cadence.sh arm`.

## Upstream-watch cadence (`scripts/upstreams/`, HIMMEL-2367)

Replaces the resident interactive-claude poller that used to check himmel's
open upstream PRs/issues every 20 minutes (operator ruling 2026-09-01: "we
should monitor it daily not as a puller and with tokens"). Pure bash + `gh` +
`jq`, delta-gated, zero tokens on a no-delta day — it never invokes `claude`.

- `scripts/upstreams/upstream-watch.sh` (no args) — inventories open
  PRs/issues authored by the operator (`gh search prs`/`gh search issues
  --author <me> --state open`), excluding the operator's own repos. Per item:
  comment count + most recent non-self comment, review count, CI conclusion
  read at the item's CURRENT head SHA (never a possibly-stale rollup field,
  the same method the HIMMEL-2367 Leg F upstream-sweep report used),
  mergeable/mergeStateStatus, and closed/merged disposition once an item
  vanishes from the open search. Diffs against
  `~/.himmel/upstream-watch/last_seen.json` and — only on an actual delta —
  writes a dated report under `handover_root` (`specs/reports/upstream-watch-
  <date>.md`) and sends one Telegram line via the existing sanctioned relay
  (no new poller). Positive control: 0 items now against a nonzero last-seen
  count is treated as an instrument failure, never as "everything closed" —
  refuses before any per-item enrichment call and leaves the state file
  untouched. Exit codes: `0` no delta, `10` delta found (report + Telegram
  sent, best-effort), `2` instrument failure (gh auth/rate-limit/parse, the
  positive-control refusal, or a broken `handover_root`/report write on a run
  that DID find a delta — state is left UNTOUCHED in that last case too, so
  the same delta is retried next run instead of being permanently marked
  "seen" with no report ever written for it).
  Test seams `UPSTREAM_WATCH_GH` / `UPSTREAM_WATCH_ME` /
  `UPSTREAM_WATCH_STATE_DIR` / `UPSTREAM_WATCH_HIMMEL_ROOT`; hermetic test
  (7 cases): `test-upstream-watch.sh`.
- `scripts/upstreams/upstream-watch-cadence.sh arm|status|disarm` — arms ONE
  daily local scheduled task (schtasks on Windows, crontab on Linux/macOS;
  structural sibling of `drift-fix-cadence.sh`, one leg instead of two because
  `upstream-watch.sh` has no "conflicted, a human must decide" branch to
  isolate) that runs `bash scripts/upstreams/upstream-watch.sh` directly —
  never `claude`, no `--model` flag, so HIMMEL-128 does not apply even
  indirectly. Default fire time 06:00 local, after drift-fix's 05:00/05:30.
  Self-registers with the observability registry
  (`scripts/lib/observability-registry.sh`) on arm/disarm so `himmel-doctor`'s
  C24 check reports the cadence (unlike `drift-fix-cadence.sh`, which
  registers nowhere). **Test/smoke-test trap (caught live, HIMMEL-2367):** the
  observability-registry path is NOT scoped by any `UPSTREAMWATCH_*` seam —
  only by the registry's own `HIMMEL_OBSERVABILITY_CONFIG`. A hand smoke-test
  of `arm` that omits it registers a REAL expected task in
  `~/.himmel/observability.json`; an unmatched `disarm` (or none at all)
  leaves it there and pages on the resulting scheduled-task-missing alert.
  Every test/smoke invocation must set `HIMMEL_OBSERVABILITY_CONFIG` to a
  scratch path. `disarm` unregisters unconditionally, including its "nothing
  armed" no-op path, so a stale registry entry with no matching live task
  (e.g. the task was deleted outside this script) still gets cleaned up.
  Flags: `--time HH:MM` (06:00 default), `--force`, `--dry-run`. Dedup-guarded;
  hermetic test: `test-upstream-watch-cadence.sh`. `--arm-on-delta` (an
  interactive claude leg launched from the delta report) was deliberately
  **not** implemented — deferred to a follow-up ticket rather than shipped as
  a dormant flag, since the launch surface (mission-doc generation, model pin,
  workspace pre-trust) is real scope for an already-sized leg. Arming is
  operator-invoked: `bash scripts/upstreams/upstream-watch-cadence.sh arm`.

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
- `scripts/ci/run-shell-tests.sh` — discovers and runs all hermetic `test-*.sh` suites under a scan-root. Maintains a `SKIP_LIST` ledger of suites that need a live VM, hermes runtime, or network — none of which exist on a bare runner. Flags: `--list` (plan without running), `--skip-extra <relpath>` (ad-hoc skip). Exit 1 on any failure, **exit 2 = refused** (see the lock below). Harness guards added by HIMMEL-1338:
  - **Machine-wide lock.** Concurrent runs test the same tree and starve each other, so the second one refuses with exit 2 and names the holder (or, with `SUITE_LOCK_WAIT` set, queues for it visibly — see below). Re-entrant for nested invocations, and **keyed by scan root** — a scoped subtree run does not queue behind a full-tree one. The key is the scan root *as given*, not its absolute path, so runs launched from different worktrees still serialise against each other. Abandoned locks are reclaimed under an exclusive `.claim`; a lock path that is a symlink, or a directory holding anything but the lock's own `owner` file, is refused rather than touched.
  - **Per-suite cap** (`SUITE_TIMEOUT`, default 600s since HIMMEL-2233, with a per-suite table for measured slow suites) — escalates TERM → grace → KILL across the suite's whole process group via `scripts/lib/proc-tree.sh`, so descendants die with it rather than being orphaned.
  - **Whole-run budget** (`SUITE_RUN_BUDGET`, default 7200s) — stops between suites and names what did not run; a truncated run exits non-zero rather than reporting green. It was described here as a runaway backstop, but HIMMEL-2243 measured otherwise: 397 suites are discovered, 381 run, and the 2026-08-29 reference run spent its whole 7200s on real work while reaching 174 of them, so on this hardware the budget bounds an *ordinary* run.
  - **Resume rotation** (`SUITE_ROTATE`, default 1 — HIMMEL-2243) — discovery is sorted, so a truncated run used to drop the *same* 207-suite tail forever (all of `scripts/lib`, `scripts/luna`, `scripts/machine-setup`, `scripts/parity`, `scripts/statusline`, `scripts/upstreams`). A truncated run now records the first suite it did not reach; the next run over the same scan root starts there and wraps to the top, covering the whole ring across ~3 budget windows. It **reorders, never filters** — a single run's suite set is unchanged — and truncation still exits 1, so the blind spot becomes temporary without a partial run reading as a pass. Inert with no cursor on disk (so a fresh CI container is byte-identical to before); `SUITE_ROTATE=0` disables it, `SUITE_ROTATE_STATE` overrides the cursor path (default `$HOME/.himmel/himmel-shell-suite-<scan-slug>.cursor`, deliberately not `TMPDIR`, which `tmp-sweep.sh` clears).
  - **Stdin isolation** — suites run with stdin on `/dev/null` and the runner reads its list on fd 3, so no suite can block an unattended run on a prompt or consume the remaining suite list.
  - **Visible wait** (`SUITE_LOCK_WAIT`, default `0` — HIMMEL-2215). The runner never used to wait at all: a held lock refused on sight, so legs hand-rolled their own retry loops and a *queued* leg became indistinguishable from a *parked* one (opposite remedies — patience vs a nudge — and getting it backwards is how a coordinator creates a second-writer race). Set it to a number of seconds and the run queues instead, printing a repeating `WAITING:` line every `SUITE_LOCK_WAIT_INTERVAL` seconds (default 60) that names the **current** holder's pid/host/elapsed hold plus how long this run has waited; `ACQUIRED:` on success, and the full `REFUSED` verdict plus exit 2 when the budget runs out. Every attempt is the unmodified acquire, so staleness/CAS/takeover behaviour is unchanged — this adds a cadence and a heartbeat, not a second way to get the lock. Default `0` keeps the historical refuse-on-sight *behaviour* — same decision, same exit 2, no waiting. The refusal TEXT is not byte-identical: it gains three lines naming `SUITE_LOCK_WAIT` as the way to queue instead, so anything asserting on the exact refusal output sees them.
  - Other env: `SUITE_LOCK=0` (opt out of the lock), `SUITE_LOCK_DIR` (override the lock path), `SUITE_LOCK_TTL` (default 4h). Those durations must be positive integers; `0` is rejected, since for each of them it would disable the guard it configures. `SUITE_LOCK_WAIT` is the deliberate exception — a budget rather than a guard, where `0` legitimately means "do not queue" (a malformed value falls back to `0`, never to an unbounded wait).
  - **Per-suite temp root** (HIMMEL-1978) — each suite runs with `TMPDIR`/`TMP`/`TEMP` pointed at its own `himmel-suite.XXXXXX` dir, which the runner deletes after the suite (or after the watchdog kills it). A terminated suite never runs its own cleanup traps, so without this it left every `mktemp` behind: /tmp on the dev box reached ~149,600 entries that way.
- `scripts/ci/tmp-sweep.sh` — lean-invoke sweep of himmel's own leftover fixture trees out of `%TEMP%`/`$TMPDIR`. **Dry-run by default**; `--apply` deletes, `--older-than <hours>` (default 6) is the age floor, `--root <dir>` overrides the temp root, `--bytes` adds a (slow) reclaimable-size figure, `--include-bare-mktemp` opts into `tmp.XXXXXX` (coreutils mktemp's default template — not exclusively ours, so it is off by default). Matches only top-level entries whose name starts with one of a derived allow-list of our own `mktemp`/`mkdtempSync` prefixes; never follows or removes symlinks; resolves the root with `pwd -P` and refuses anything that is not at or under `$TMPDIR`/`$TEMP`/`$TMP`/`/tmp`/`/var/tmp`. Every allow-list entry is a complete `mktemp`/`mkdtempSync` template prefix, or the shared fixed part of a family of them (`bench-run-batch-`, `lane-bank-`) — never a bare family stem (HIMMEL-1995). Exit 2 on usage error or a refused root; exit 3 when `--apply` left matched entries behind (the survivor count is on stderr — dry-run never returns it). Suite: `scripts/ci/test-tmp-sweep.sh`.
- `scripts/ci/orphan-census.sh` — **read-only** census of orphaned himmel suite/probe processes (dead parent + a command line naming a script inside *this* checkout + older than `--min-age`, default 10 min). The checkout anchor (HIMMEL-1995) is the primary root, derived from the script's own location with any `.claude/worktrees/<name>` suffix stripped, so it covers the primary and every worktree. The script must be root-prefixed, or named relative to a `cd` into the root on the same line (`cd <root> && bash scripts/…`, the live shape), and in both cases actually run by an interpreter — an editor or scanner holding a suite file open is not a suite process; a same-layout foreign repo, a foreign absolute script that merely shares the line, and a bare relative invocation with the root nowhere on the line are all left unclassified. Windows via `Get-CimInstance Win32_Process`, POSIX via `ps`; `check-ci` / `merge-on-green` watchers are listed as `WATCHER` and never reaped. `--reap` exists but is **operator-run** — the destructive-command hook denies process termination from a Claude session. `--reap` re-reads each PID's creation time immediately before signalling and skips with a WARN if it changed, which narrows the PID-reuse window from minutes to the microseconds between that read and the signal — it does not close it (bash signals by PID, not by handle). `ORPHAN_CENSUS_INPUT=<file>` feeds the classifier a canned `pid|ppid|age|start|cmdline` table (test seam; refuses to combine with `--reap`). Suite: `scripts/ci/test-orphan-census.sh`.
- `scripts/lib/proc-tree.sh` — terminates a background job **and its descendants** on POSIX and Git Bash: process-group TERM → grace → KILL, then verifies the group is actually empty and falls back to Windows `taskkill` for anything that survived. Callers must spawn under `set -m` so the job owns a process group. Used by the suite runner's per-suite cap; covered by `scripts/ci/test-suite-concurrency.sh`.

**Five jobs:** `secret-scan` (check-no-secrets), `lint` (shellcheck --severity=warning over `scripts/**/*.sh`), `node-suites` (npm matrix: jira/bitbucket/himmel-run), `bun-suites` (luna-vitals bun test), `shell-unit` (run-shell-tests.sh).

Full reference: [`scripts/ci/README.md`](../scripts/ci/README.md).

---

## CR Scripts (`scripts/cr/`)

Shell scripts that implement `/pr-check` sub-steps. Called by the `/pr-check` command; not invoked standalone in normal workflows.

- `scripts/cr/file-deferred-issues.sh` — reads `/pr-review-toolkit:review-pr` output, dedupes low-severity findings by content hash, and files them as GitHub issues tagged `cr-deferred`. Called by `/pr-check` step 7. Idempotent; `--dry-run` mode for inspection.
- `scripts/cr/critic-first-pass.sh` — generic model-parametrized CR reviewer (HIMMEL-415, supersedes retired `gemini-first-pass.sh`): diff on stdin → findings with stable `[<slug>-N]` IDs; routes through `scripts/hermes/invoke.sh`; `--model`/`--slug` flags select the model. **Senior-reviewer routing (HIMMEL-558):** the gpt/codex-family critic runs under the `himmel_agent` hermes profile (main-tier SOUL) instead of the user-default junior SOUL — the junior framing produced shallow/discarded codex output. Only the gpt family by default because `himmel_agent` is Codex-provider-bound (a non-OpenAI model like the free qwen3coder anchor 400s under it); open/claude critics stay on the hermes default profile and take their senior framing from the role-prompt. Override with `CR_CRITIC_PROFILE` (applies to every family when set; `none`/empty → hermes default). `invoke.sh --profile` is fail-open (missing profile warns + falls back). Tests: `scripts/cr/test-critic-first-pass.sh` (deterministic, PATH-stubbed fake hermes).
- `scripts/cr/critic-panel.sh` + `scripts/cr/critics.json` — NIM critic panel (roster defined in `critics.json`). **`critics.json` currently holds ONE row — `codex`/`gpt-5.6-sol`, tier `paid` — and NO free critics (HIMMEL-1101).** The free lane was **removed deliberately** — it made more trouble than it was worth: gptoss + kimi dropped 2026-07-03 (HIMMEL-667 operator decision, 12%/13% ledger agreed-rate — noise), and the surviving qwen3coder anchor kept erroring rc=1 (HIMMEL-953). Paid-by-default is the intended posture, not drift. So `/pr-check` **auto-runs the PAID codex anchor by default** (~2min, bounded by the 240 s per-member timeout): an unset `CR_PROFILE` **AND** unset `CRITIC_PANEL_TIERS` resolve to tier filter `free` (`CRITIC_PANEL_TIERS` is the low-level override, honored ONLY when `CR_PROFILE` is unset), which matches zero rows, so the panel falls back to the paid anchor — **spending the OpenAI bank on any default run that actually runs the panel** — skipped, and therefore free, on an empty diff or `CR_PROFILE=none` (operator decision recorded on HIMMEL-1101: accepted). Note this fallback also bypasses HIMMEL-737's triviality gate, which only fires when `paid` is already IN the tier filter. `CR_PROFILE=none` = instant claude-only (skip panel). `CR_PROFILE=thorough` = adds the `thorough` tier (currently EMPTY — kept for future heavier critics). `CR_PROFILE=paid` / `free,paid` = the paid codex critic. Any other value is the tier filter verbatim. **`CR_PROFILE` is authoritative (HIMMEL-558):** `/pr-check` loads it from `.env` and the panel derives its tiers from it directly — it wins over the low-level `CRITIC_PANEL_TIERS` override (honored only when `CR_PROFILE` is unset). This closed a drift where a run hand-scoped the panel to free-only and silently dropped the paid critic. Retired the gemini-only CR lane (HIMMEL-412/415). Per-member hang protection via `CRITIC_TIMEOUT_SECS` — default **240 s**, which is ALSO the fallback when the supplied value is non-numeric or ≤0 (the panel warns and uses 240 rather than failing). HIMMEL-558 raised it from 150 s after codex + qwen3coder were seen clipping at 150 s. It needs the `timeout` binary, but does not *require* it: when `timeout` is absent the panel prints "per-member hang protection disabled" and runs each member **unbounded**.
- `scripts/cr/ledger-append.sh` — appends `finding` / `avail` / `usage` records to the CR ledger (`cr-critic-scores.jsonl`); called by `/pr-check` adjudication step. The `usage` kind (HIMMEL-485) records a chars/4 **estimated** token count for a critic (hermes does not expose real usage through the one-shot chokepoint); written best-effort by `critic-first-pass.sh` when `CR_USAGE_LOG=1`.
- `scripts/cr/cr-scores.sh` — generates a per-critic correctness scorecard from the ledger; surfaced via `/cr-scores`. Adds an estimated-token Usage section (per-model + cumulative) when the ledger holds `usage` records.
- `scripts/cr/pr-check-external.sh` — **Claude-free CR runner** (HIMMEL-750): reviews a branch with NO Claude session so review still runs when the Claude quota bank is maxed. `--branch <b> [--session-dir <dir>] [--base <ref>]`; fetches, diffs `origin/<base>...<branch>`, pipes to `critic-panel.sh` with `CR_PROFILE=free,paid` forced (so the paid codex critic reviews; `CR_PROFILE=none` refused). Fail-CLOSED gate: panel non-zero exit, unparseable Critical/Important counts, an ABSENT codex critic, or any Critical/Important finding all FAIL. On clean it writes `external_cr_verdict: pass (sha=…; critics=…)` into the spawn-glm session `meta.json` (distinct from `d1_verdict`) and prints a PR-body snippet; does NOT touch the CR marker. Test: `scripts/cr/test-pr-check-external.sh` (hermetic; fake git repo + stubbed panel via `CRITIC_PANEL_CMD`). See [`docs/glm-offload.md`](glm-offload.md) "Claude-down ship flow".
- `scripts/cr/coderabbit-review.sh` — **CodeRabbit CLI finding pass** (HIMMEL-926, `/pr-check` step 3.2; adopted on a 14-day trial 2026-07-11): reviews the branch's COMMITTED diff vs the base via the CodeRabbit CLI (`review --agent` — the invocation the coderabbitai/skills `code-review` skill prescribes; findings grouped Critical/Warning/Info map to Critical/Important/Suggestion) and prints findings the session classifies into `[coderabbit-N]` blocking candidates. Availability-gated + fail-open (missing CLI → exit 3 skip note; error/timeout → exit 1, gate degrades to the remaining critics). Resolves the CLI natively on PATH first, else inside WSL (`wsl.exe` probe — the supported install on Windows; login shell so `~/.local/bin` resolves). Both lanes review a **temp clone of the primary checkout** (single-branch + base fetch): WSL git cannot resolve a Windows-created worktree (its `.git` pointer holds a `C:/` path), and the clone also pins the review to committed state. `CODERABBIT_TIMEOUT_SECS` (default 900 s) caps the review; `CODERABBIT_BIN`/`CODERABBIT_WSL` are test seams. With the trial active, the `pr-review-toolkit:*` Claude reviewer agents are opt-in via `CR_CLAUDE_AGENTS=1` (default = inline session adjudication, no agent fan-out). Post-PR, the user-scope `autofix` skill (coderabbitai/skills) applies CodeRabbit GitHub review-thread feedback — separate surface, not wired into `/pr-check`. Test: `scripts/cr/test-coderabbit-review.sh` (hermetic; stub binary + fake wsl launcher).

## OpenRouter free-tier watcher (`scripts/openrouter/free-watch.sh`, HIMMEL-846)

Lean-invoke (no hook/daemon) watcher for free-model CHURN on OpenRouter —
the risk under the free-only policy (the $20 top-up is NEVER spent; it only
unlocks the 1000 free-req/day tier; panels pin `:free` ids exclusively).
Fetches the public catalog (no auth), keeps the `:free` subset, snapshots to
`~/.himmel/openrouter-free-catalog.json`, diffs vs the last run
(new/delisted free models), checks every OpenRouter model pinned in the CR
registry (overlay `critics.local.json` > shipped `critics.json`) for
delisting / deranked endpoints (any `status < 0`; all-deranked and
partial-derank are distinct flags) / uptime drops
(`uptime_last_30m < OPENROUTER_UPTIME_MIN`, default 90, validated numeric
at startup), and prints
`SUGGEST` lines for better code-capable `:free` candidates (bigger context
than the pinned max). Suggestions only — never edits any registry file.
Flags for hermetic testing: `--catalog-file`, `--endpoints-dir`,
`--state-dir`, `--registry`, `--no-probe`. Test:
`scripts/openrouter/test-free-watch.sh`. Pattern-parity with
`alibaba-probe-once` (HIMMEL-729); relates HIMMEL-737 rotation.

## GLM ship lane (`scripts/glm/`, HIMMEL-750)

- `scripts/glm/ship-branch.sh` — pushes a reviewed `glm/*` branch FROM the trusted main checkout (the GLM worker still never pushes for itself — the no-push prompt + the deny hook are unchanged; the pushurl poison that used to sit alongside them is gone, HIMMEL-1961). `ship-branch.sh <branch> [--session-dir <dir>] [--allow-any-branch]`; refuses to run from a `.claude/worktrees/` path, requires an `origin` remote, and is authorized only by `external_cr_verdict:pass` (written by `pr-check-external.sh`) whose reviewed SHA must equal the current branch tip (closes the post-panel-commit TOCTOU). Runs `git push -u origin <branch>` with the real pre-push gates (NO `--no-verify`), then clears the CR marker only when its SHA matches the pushed SHA. Never opens a PR, never merges — prints the exact `gh pr create` for the operator. Test: `scripts/glm/test-ship-branch.sh` (hermetic; temp bare-repo origin). See [`docs/glm-offload.md`](glm-offload.md) "Claude-down ship flow".

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
