# Slash Commands Catalog

Project-local slash commands in `.claude/commands/` (auto-discovered by
Claude Code). Each row's description is the **verbatim** `description:`
frontmatter of that command file.

Operator-invokable commands shipped by **vendored plugins** under
`marketplace/plugins/` are also listed (see the
[Clipper pipeline](#clipper-pipeline-obsidian-triage-plugin) section) —
their source is the plugin's `commands/<name>.md`, not `.claude/commands/`,
and their rows are paraphrased one-liners rather than verbatim frontmatter
(the plugin descriptions are multi-sentence).

> **Not listed: `marketplace/plugins/claude-hud/commands/`** (HIMMEL-718).
> claude-hud is vendored as the statusline **renderer only** — wired as
> `node …/claude-hud/dist/index.js`, never installed as a plugin (not
> registered in himmel's top-level registry
> `marketplace/.claude-plugin/marketplace.json`; the vendored tree's own
> `.claude-plugin/*` files are inert upstream artifacts), so its upstream
> `/claude-hud:setup` / `/claude-hud:configure` commands are not invokable here. See
> [marketplace/plugins/claude-hud/VENDORED.md](../marketplace/plugins/claude-hud/VENDORED.md).

> **Keep this current.** When a ticket adds, renames, or removes a command
> under `.claude/commands/`, update the matching row here in the same PR.
> The snippet below emits one verbatim row per command (alphabetical) —
> paste its output and re-group into the sections below:
> ```bash
> cd .claude/commands
> for f in *.md; do
>   d=$(awk -F': ' '/^description:/{sub(/^description: */,"");print;exit}' "$f")
>   printf '| /%s | %s |\n' "${f%.md}" "$d"
> done
> ```

## Worktree lifecycle

| Command | What it does |
|---|---|
| /worktree | Create a new worktree under .claude/worktrees/ (no prune). Thin alias for /clean_garden --no-prune. |
| /clean | Prune merged-PR worktrees (no create). Thin alias for /clean_garden --prune-only. |
| /clean_garden | Prune merged-PR worktrees and (optionally) create a new one in the same shot |

## PR / code review

| Command | What it does |
|---|---|
| /pr-triage | Lightweight 4-step PR triage gate (steipete) — decide if a PR is even worth a deep multi-agent CR before running /pr-check |
| /pr-check | Run the multi-agent CR review on the current branch and clear the pre-push marker on clean output |
| /check-ci | Token-free PR merge-gate watcher — one process loops inside gh pr checks --watch --fail-fast, then verifies zero unresolved review threads and no changes-requested review, and returns a single exit code (0=green+resolved, 1=red, 2=cannot evaluate/no PR/usage error, 3=unresolved threads or changes requested), so merge-on-green costs ~zero tokens (HIMMEL-949). |
| /cr-scores | Print the per-critic agreed/availability scorecard and surface drop advice |
| /cr-tune | Mine the CR ledger for disproved classes per critic and draft citation-backed tuning proposals (.coderabbit.yaml / critics.json) — proposals only, never auto-applied |
| /claude-md-audit | Audit changed CLAUDE.md files against the claude-md-improver rubric before PR — audit-only, applies no edits on its own |
| /shell-lint | Pre-emptive advisory shell lint — run shellcheck + UTF-8 BOM + errexit-leak checks on staged shell (or named files) BEFORE the commit attempt, so the loop fixes issues instead of bouncing off the pre-commit gate (HIMMEL-478). |
| /guardrail-sim | Pre-flight guardrail simulator — feed planned Bash commands on stdin and it flags/rewrites the predictable himmel guardrail collisions (compound→single, WSL-bash→Git Bash, destructive-git, on-main-write) + a curated learnings file, before they stall a run (HIMMEL-475). |

## Handover

| Command | What it does |
|---|---|
| /handover-arm-resume | Arm the OS scheduler to relaunch claude at the given time with the given handover. Dedup-guarded. Direct schtasks/at invoke. HIMMEL-122. |
| /handover-commit | Auto-commit *.md changes in the handover root (Mode B / external HANDOVER_DIR only). HIMMEL-59 MVP. |
| /handover-flush | Session-end consolidation sweep across handover/* branches (HIMMEL-143). |
| /handover-link | Report or check where Claude is reading/writing handover state (inline ./handovers or external $HANDOVER_DIR) |
| /handover-pr-open | Open or update the PR for the current handover/<TICKET>-<slug> branch (HIMMEL-141). |
| /handover-pr-merge | Squash-merge the PR for the current handover/<TICKET>-<slug> branch (HIMMEL-141). |
| /handover-resume | Chain-resume a tracked handover item to continue work — surfaces its cold-start (brief/context, latest session, open bugs, CR findings); no arg picks from active items; append `overnight` for overnight mode. Thin wrapper on the `handover:handover` skill's `handover-resume` op (the token-lean equivalent of "load <ID>"). Bare himmel-local command (mirrors /handover-resume-armed); adopters with only the plugin invoke the op via `/handover:handover-resume` or "load <ID>". Distinct from /handover-resume-armed (armed-session recovery). HIMMEL-1034. |
| /handover-resume-armed | Fast-resume from the last armed session — surface its transcript + stop-point (the answered AskUserQuestion = the agreed continuation) with no manual JSONL archaeology. HIMMEL-208. |
| /handover-setup (handover plugin) | First-time handover bootstrap — asks where handover state should live, persists it to .env as HANDOVER_DIR, then runs init (new) or register (existing). Use on a fresh machine/repo before /handover new-epic etc. Plugin-sourced (`marketplace/plugins/handover/commands/handover-setup.md`), not `.claude/commands/` — grouped here with its sibling handover commands for discoverability. |
| /morning-report | Generate the dated 🌅 Morning Report from live git/gh/jira/worktree state at ~zero Claude tokens (no-token default; opt-in --llm enriches TL;DR + Suggested order + theme-clustered Backlog). HIMMEL-574. |

## Session / context

| Command | What it does |
|---|---|
| /context-hop | Mid-session jump to a fresh claude session when context window is approaching the soft budget. Sibling of /handover-arm-resume. HIMMEL-130. |
| /retitle | Infer a himmel-canonical session name (TICKET-ID + meaningful name) from the current branch and print a ready-to-paste built-in /rename line. |
| /overnight-shift | Auto-dispatch N tickets from Jira as parallel subagents — emits plan + confirms before fanout (HIMMEL-134). |
| /pipeline-cadence | Arm/inspect/remove the recurring clip-pipeline cadence (daily /harvest-clips + /triage-clips, daily /synthesize-clips + /archive-clips, weekly /obsidian-health) via schtasks (Windows) or cron (POSIX), interactive-claude shaped with per-leg --model pins. Dedup-guarded. HIMMEL-255/265/357/506. |
| /end-session-wiki-setup | Configure which Obsidian vault the end-session-wiki hook captures sessions into — writes LUNA_VAULT_PATH (global) or .claude/end-session-wiki.json vault_path (this repo only). |
| /stop | Graceful-halt marker for in-progress /overnight-shift sessions (HIMMEL-137). |

## Prompt / discovery

| Command | What it does |
|---|---|
| /improve | Refine a draft prompt via hybrid clarifying-Q workflow. Writes an audit artifact to .improve/ + returns the refined prompt for resubmission. HIMMEL-127. |
| /skill-find | Embedding-indexed lookup over installed skills/commands/agents — eliminates wrong-namespace mistakes (HIMMEL-33). |
| /luna-backfill | Backfill old Claude session transcripts into the luna vault as structured session notes. TOKEN-INTENSIVE — warns before running and recommends --dry-run first. |
| /luna-ingest | Chain-following triage for a github repo URL. Thin wrapper that delegates to the obsidian-triage:luna-ingest skill (LUNA-9 skill conversion — see marketplace/plugins/obsidian-triage/skills/luna-ingest/SKILL.md for the runbook). |
| /telegram-clip | File a Telegram message (text / bare URL / forward) as a harvest-ready LUNA-2 clip note in the luna vault's Clippings/. Thin wrapper that delegates to the obsidian-triage:telegram-clip skill (LUNA-58 — see marketplace/plugins/obsidian-triage/skills/telegram-clip/SKILL.md for the runbook). |
| /roadmap-clips | Aggregate actionable items across the luna vault (daily action items, _deferred.md backlog, synthesis proposals, promotion candidates, component inventory), cluster into a sequenced roadmap mapped to tools, dedup candidate tickets against open Jira, and write a 60-Maps/ roadmap note. Proposals only. Thin wrapper that delegates to the obsidian-triage:roadmap-clips skill (LUNA-59 — see marketplace/plugins/obsidian-triage/skills/roadmap-clips/SKILL.md for the runbook). |
| /luna-upgrade | Content-preserving upgrade of an existing luna-second-brain vault to the current himmel template (dry-run → confirm → apply, or --check to just report whether an upgrade is available). Thin wrapper that delegates to the obsidian-triage:luna-upgrade skill (HIMMEL-389 — see marketplace/plugins/obsidian-triage/skills/luna-upgrade/SKILL.md for the runbook). |
| /luna-upgrade-all | Multi-vault upgrade sweep — discover all luna-second-brain vaults, dry-run-first, per-vault operator-confirmed apply, backup/restore safety net, and conflict-brainstorm on _CLAUDE.md conflicts. Thin wrapper that delegates to the obsidian-triage:luna-upgrade-all skill (HIMMEL-462 — see marketplace/plugins/obsidian-triage/skills/luna-upgrade-all/SKILL.md for the runbook). |

## Clipper pipeline (obsidian-triage plugin)

Four-stage pipeline over the luna vault's `Clippings/` inbox
(HARVEST → TRIAGE → SYNTHESIZE → ARCHIVE). Plugin-provided
(`marketplace/plugins/obsidian-triage/commands/`); full spec in that
plugin's `README.md`. `/luna-ingest` (under Prompt / discovery above) is
the github-repo ingest skill these dispatch to.

| Command | What it does |
|---|---|
| /harvest-clips | Stage 1 — autonomous HARVEST pass: mark unharvested clips (`harvested_at:`), dispatch github URLs to `luna-ingest`, clip-body for the rest. Idempotent. |
| /ig-media-enrich | IG media rung (after ig-embed): download reel/carousel media via gallery-dl (burner cookies), local faster-whisper transcript for reels, copy carousel slides into Clippings/_media/ + agent-read slide digest via the mechanical --apply-digest applier. Lean-invoke. HIMMEL-770. |
| /triage-clips | Stage 2 — autonomous triage: summarize, infer tags, suggest Related Notes, extract action items → daily note, annotate promotion candidate, mark `processed: true`. Idempotent. |
| /synthesize-clips | Stage 3 — cross-clip synthesis: find recurring patterns across processed clips, write proposal pages to `Clippings/_synthesis/` (proposals only, never restructures). |
| /archive-clips | Stage 4 (LUNA-55) — graduate fully-chained clips (harvested ∧ processed ∧ in-synthesis) to `Clippings/_done/<YYYY-MM>/`, rewrite inbound links (literal, boundary-safe), dedup by canonical URL, (re)generate `Clippings/_deferred.md`. |
| /synthesize-stubs | SYNTHESIZE stub mode (LUNA-87) — the generative path that compounds the evidence pool into early `status: stub` subject pages. |
| /deepen-subject | github source fan-out on promotion (LUNA-89) — fills the `## References` scaffold of a `deepen_pending: true` Tech subject page from its linked github sources. |
| /contra | CONTRA passes (LUNA-96/97): ghost-self — past-you (notes older than the `--min-age` duration, default 6m; age from frontmatter `date:`, daily notes falling back to the `YYYY-MM-DD.md` filename) reacting to current-you with verbatim-quote guard; --bridge — one forced cross-domain analogy (max one bridge/day). Appends to today's daily note `## Thinking`. Lean-invoke only. |

**One-time backfill (not a stage):** `/migrate-clip-lifecycle <vault> [--dry-run | --apply [--month YYYY-MM] | --rollback <manifest>]` (obsidian-triage, LUNA-86) — deterministic, reversible, resumable engine (`tools/migrate-clip-lifecycle.mjs`) that migrates the historical top-level `processed: true` clips into `Clippings/_evidence/`, stamping `evidence_kind:` and rewriting every inbound wikilink across SIX literal boundary forms (3 plain + 3 `.md`-suffixed, the silent-dangle guard). Folder-keyed idempotent; byte-identical rollback via the manifest. Run ONCE behind a mandatory staging gate — not a recurring pipeline stage.

**Companion (not a stage):** `/read-link <url>` (obsidian-triage, LUNA-78) — vault-first link reader: read an already-harvested clip for a URL before any live fetch; enrich a thin clip, else live-fetch (fxtwitter / WebFetch / luna-ingest) as the last resort. Never Grok. UX inspired by eugeniughelbur/obsidian-second-brain's `/x-read` (clean-room, no vendored fork).

## Plugin skills & ops (himmel-ops, obsidian-triage)

Skills shipped by vendored plugins. Most trigger on a symptom or a slash
alias rather than a bare command; rows are paraphrased one-liners. Source
is the plugin's `skills/<name>/SKILL.md` (or `commands/<name>.md` where a
slash alias exists).

| Skill / command | What it does |
|---|---|
| /minerva (himmel-ops) | Run the brainstorm→critic→spec→critic→plan pipeline as ONE pass with an adversarial critic loop between stages — one idea to a critic-hardened implementation plan. Slash alias + dispatchable skill. |
| stuck-playbook (himmel-ops) | Load-on-trigger guardrail-recovery escape-hatches — fires on a denial/friction symptom (auto-mode Bash/Jira write denied, hung permission prompt, missing attestation trailer). Surfaces escape-hatches kept out of the always-on root CLAUDE.md (HIMMEL-211). |
| vm (himmel-ops) | Lean-invoke VM lifecycle + e2e runbook — front door to the central VM-control SDK (`scripts/lib/vmsdk.py`); covers up/down/snapshot/restore/baseline/clone/provision/e2e verbs, the engine pass + skill pass probes, and the `sync_repo`/`install_plugin`/`drive_claude` SDK primitives (HIMMEL-491/493). |
| /memory-compound (himmel-ops) | Lean-invoke: losslessly compound the per-project auto-memory (`MEMORY.md` index + topic files) into qmd-searchable luna `30-Resources/Tech/` (or himmel `docs/internals/`) reference notes — read-many → write-once → qmd gate → slim index → delete sources. Run when `MEMORY.md` nears its ~24.4KB load budget. Slash alias + dispatchable skill (HIMMEL-569). |
| vault-lint (obsidian-triage) | Filesystem-only, report-only vault health lint — a single deterministic Python pass that converges on large PARA vaults (orphans, broken wikilinks, audit). Vault-agnostic. |
| luna-vitals-extract (obsidian-triage) | Backfill salus health series for one vault time-bucket (HIMMEL-355) — extracts (date, metric, value) tuples via the luna-vitals CLI + an LLM prose pass, writing one per-bucket review artifact. Single-writer; never writes 50-Vitals/ directly. |

## Utility

| Command | What it does |
|---|---|
| /quiet-run | Run a noisy command quietly — one OK/ERR line + log path |
| /lanes | Print the delegation/critic/bulk lanes actually available on THIS machine (HIMMEL-689 — availability-aware, derived from scripts/lanes/lanes.json + machine state; the invariant delegation policy stays in CLAUDE.md). |
| /himmel-doctor (himmel-ops) | Diagnose common harness health problems (node/caveman SessionStart wiring, shadowed claude-obsidian, dirty single-writer luna vault, bitbucket-vs-gh, handover-registry gaps, PATH-fragile bare-interpreter MCP servers); severity-grouped report; `--fix` heals the node wiring; `--file-issue` files ONE consolidated public GitHub issue. |
| /himmel-update | Update this himmel checkout (harness) — six-item dependency chain (pull, marketplace, jira CLI dist, qmd fork, hermes, luna template) with per-item status + abort-on-first-failure, plus five best-effort advisory steps (codex re-sanitize, statusLine re-wire, plugin gap report, plugin-set reconcile, cadence/guardrail drift checks). `himmelctl update` runs the same engine. autoUpdate does NOT deliver the checkout (git pull) or the core hooks/slash-commands — it only re-syncs installed plugins from the on-disk dir. A configured LUNA_VAULT_PATH is already refreshed by step 6 of this chain; use /luna-upgrade only for an explicit Luna-only run, and /himmel-update-all for multi-vault workflows. |
| /himmel-update-all | Update BOTH the himmel harness (/himmel-update) and the luna vault (/luna-upgrade) in one shot; `--check` dry-runs both. |
