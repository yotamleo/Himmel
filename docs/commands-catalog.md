# Slash Commands Catalog

Project-local slash commands in `.claude/commands/` (auto-discovered by
Claude Code). Each row's **Description** column is machine-generated from the
**verbatim** `description:` frontmatter of that command file; the **Notes**
column is hand-written why/when context and is never checked against the
frontmatter.

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

> **Keep this current.** When a ticket adds, renames, removes, or re-describes
> a command under `.claude/commands/`, the Description column is regenerated
> for you — run `node scripts/lib/gen-commands-catalog.mjs write` and commit
> the result in the same PR (add a new row + Notes cell by hand for a brand
> new command). CI's `doc-invariants` job runs
> `node scripts/lib/gen-commands-catalog.mjs check` and fails on any row whose
> Description has drifted from its frontmatter.

## Worktree lifecycle

| Command | Description | Notes |
|---|---|---|
| /worktree | Create a new worktree under .claude/worktrees/ (no prune). Thin alias for /clean_garden --no-prune. |  |
| /clean | Prune merged-PR worktrees (no create). Thin alias for /clean_garden --prune-only. |  |
| /clean_garden | Prune merged-PR worktrees and (optionally) create a new one in the same shot |  |

## PR / code review

| Command | Description | Notes |
|---|---|---|
| /pr-check | Run the multi-agent CR review on the current branch and clear the pre-push marker on clean output | Run the multi-agent CR review on the current branch and clear the pre-push marker on clean output. Its fenced awk/shell use `$(N)`/`${N}`, never a bare `$<digit>` (HIMMEL-2051) — the Skill tool substitutes `$1`/`$2`/…/`$ARGUMENTS` throughout a command's whole body, args or not, and clobbers a bare positional/field ref; `command-positional-args` (pre-commit + CI) refuses a regression. |
| /check-ci | Token-free PR merge-gate watcher — loops gh pr checks --watch, verifies threads resolved, returns one exit code. | Token-free PR merge-gate watcher — one process loops inside gh pr checks --watch --fail-fast, then verifies zero unresolved review threads and no changes-requested review, and returns a single exit code (0=green+resolved, 1=red, 2=cannot evaluate/no PR/usage error, 3=unresolved threads or changes requested), so merge-on-green costs ~zero tokens (HIMMEL-949). |
| /cr-public | Babysit a PUBLIC propagation PR to CR-clean + CI-green, then STOP — the squash-merge stays an operator action. | Babysit a PUBLIC propagation PR (default repo yotamleo/Himmel) to CR-clean + CI-green before the operator merges — creates the PR if the branch is pushed but has none, watches the CodeRabbit App review + CI via check-ci.sh, loops fixes, and STOPS at PR-ready. The public squash-merge stays an operator action (HIMMEL-1196). |
| /cr-scores | Print the per-critic agreed/availability scorecard and surface drop advice |  |
| /cr-tune | Mine the CR ledger for disproved classes per critic and draft citation-backed tuning proposals. Never auto-applied. | Mine the CR ledger for disproved classes per critic and draft citation-backed tuning proposals (.coderabbit.yaml / critics.json) — proposals only, never auto-applied |
| /cr-learnings-refresh | Refresh known-findings.json evidence from the CR ledger + a CodeRabbit learnings export; lists new-class candidates |  |
| /claude-md-audit | Audit changed CLAUDE.md files against the claude-md-improver rubric before PR — audit-only, applies no edits on its own |  |
| /shell-lint | Advisory shell lint (shellcheck + BOM + errexit-leak) on staged shell BEFORE the commit attempt, not after it. | Pre-emptive advisory shell lint — run shellcheck + UTF-8 BOM + errexit-leak checks on staged shell (or named files) BEFORE the commit attempt, so the loop fixes issues instead of bouncing off the pre-commit gate (HIMMEL-478). |
| /guardrail-sim | Pre-flight guardrail simulator — feed planned Bash commands on stdin; flags/rewrites predictable guardrail hits. | Pre-flight guardrail simulator — feed planned Bash commands on stdin and it flags/rewrites the predictable himmel guardrail collisions (compound→single, WSL-bash→Git Bash, destructive-git, on-main-write) + a curated learnings file, before they stall a run (HIMMEL-475). |

## Handover

| Command | Description | Notes |
|---|---|---|
| /handover-arm-resume | Arm the OS scheduler to relaunch claude at a given time with a given handover. Dedup-guarded. | Arm the OS scheduler to relaunch claude at the given time with the given handover. Dedup-guarded. Direct schtasks/at invoke. HIMMEL-122. |
| /handover-commit | Auto-commit *.md changes in the handover root (Mode B / external HANDOVER_DIR only). MVP. |  |
| /handover-flush | Session-end consolidation sweep across handover/* branches. |  |
| /handover-link | Report or check where Claude is reading/writing handover state (inline ./handovers or external $HANDOVER_DIR) |  |
| /handover-pr-open | Open or update the PR for the current handover/<TICKET>-<slug> branch. |  |
| /handover-pr-merge | Squash-merge the PR for the current handover/<TICKET>-<slug> branch. |  |
| /handover-resume | Resume a tracked handover item — cold-start brief, latest session, open bugs, CR findings. No arg picks from active. | Chain-resume a tracked handover item to continue work — surfaces its cold-start (brief/context, latest session, open bugs, CR findings); no arg picks from active items; append `overnight` for overnight mode. Thin wrapper on the `handover:handover` skill's `handover-resume` op (the token-lean equivalent of "load <ID>"). Bare himmel-local command (mirrors /handover-resume-armed); adopters with only the plugin invoke the op via `/handover:handover-resume` or "load <ID>". Distinct from /handover-resume-armed (armed-session recovery). HIMMEL-1034. |
| /handover-resume-armed | Fast-resume from the last armed session — surface its transcript and stop-point, no manual JSONL archaeology. | Fast-resume from the last armed session — surface its transcript + stop-point (the answered AskUserQuestion = the agreed continuation) with no manual JSONL archaeology. HIMMEL-208. |
| /handover-setup (handover plugin) | First-time handover bootstrap — asks where handover state should live, persists it to .env as HANDOVER_DIR, then runs init (new) or register (existing). Use on a fresh machine/repo before /handover new-epic etc. Plugin-sourced (`marketplace/plugins/handover/commands/handover-setup.md`), not `.claude/commands/` — grouped here with its sibling handover commands for discoverability. |  |
| /morning-report | Generate the dated Morning Report from live git/gh/jira/worktree state at ~zero tokens; --llm enriches it. | Generate the dated 🌅 Morning Report from live git/gh/jira/worktree state at ~zero Claude tokens (no-token default; opt-in --llm enriches TL;DR + Suggested order + theme-clustered Backlog). HIMMEL-574. |

## Session / context

| Command | Description | Notes |
|---|---|---|
| /context-hop | Mid-session jump to a fresh claude session when the context window nears the soft budget. | Mid-session jump to a fresh claude session when context window is approaching the soft budget. Sibling of /handover-arm-resume. HIMMEL-130. |
| /retitle | Infer a himmel-canonical session name from the current branch and print a ready-to-paste /rename line. | Infer a himmel-canonical session name (TICKET-ID + meaningful name) from the current branch and print a ready-to-paste built-in /rename line. |
| /overnight-shift | Auto-dispatch N tickets from Jira as parallel subagents — emits plan + confirms before fanout. |  |
| /pipeline-cadence | Arm/inspect/remove the recurring luna clip-pipeline cadence via schtasks or cron, per-leg --model pins. | Arm/inspect/remove the recurring clip-pipeline cadence (daily /harvest-clips + /triage-clips, daily /synthesize-clips + /archive-clips, daily vault-lint) via schtasks (Windows) or cron (POSIX), interactive-claude shaped with per-leg --model pins. Dedup-guarded. HIMMEL-255/265/357/506/1383/1386. |
| /drift-fix | Resolve upstream fork-drift end-to-end — bump auto-bumpable pins, land on private main, open a PUBLIC PR, STOP. | Resolve upstream fork-drift end-to-end — run the drift guard, mechanically bump every auto-bumpable pin, land it on PRIVATE main, then open a PUBLIC PR and STOP for the operator to merge. The payload of the nightly drift-fix cadence (HIMMEL-1323). Step 1A first runs `scripts/himmel-update.sh` to catch THIS MACHINE up to what already landed on main — the staleness kind no `BEHIND` row can show — and step 2B confirms (a read, not a re-sync) that step 1A's advisory sweep already repaired the `mkt:*` marketplace rows the runbook used to ignore (HIMMEL-2134). Both are machine-local, produce no repo diff, and never open a PR. |
| /fork-resync | Re-sync a carried FORK onto a newer upstream base — rebase + audit the additive delta; pushing is operator-only. | Re-sync a carried FORK onto a newer upstream base — rebase the fork's additive delta and audit that it is still additive. An operator-run invocation may continue on to push the fork and move the pin; the nightly fork-resync cadence (HIMMEL-1323) runs unattended and STOPS after the audit — it never pushes and never moves the pin. |
| /upstream-file | File verified findings upstream (issue / PR / advisory / documented skip) — dupe-gate first, leak-clean, repo-own gates. | The report-upstream half of the fork-maintenance loop (HIMMEL-2150; the converge-to-vendor half is HIMMEL-2135, /fork-resync's sibling). The dupe gate (search issues AND PRs, open AND closed, plus security advisories) runs FIRST — before any drafting, cloning, or building — since a competing PR burns tokens and maintainer goodwill. Every finding resolves to one of four filing forms — **issue** (fix needs maintainer judgment), **PR** (unambiguous fix + test), a drafted **private security advisory** (channel choice and submission stay operator decisions, never auto-picked), **documented skip** (already covered by the repo's own automation) — plus two no-file outcomes (**dupe**, **already fixed at HEAD**) — plus a roster row on the tracking ticket. A mechanical leak grep runs on every commit message, title, body, and advisory draft before any push/create call. |
| /end-session-wiki-setup | Configure which Obsidian vault the end-session-wiki hook captures sessions into — by name, path, or LUNA_VAULT_PATH. | Configure which Obsidian vault the end-session-wiki hook captures sessions into — writes env.LUNA_VAULT_PATH into ~/.claude/settings.json (global) or the .claude/end-session-wiki.json vault or vault_path key (this repo only). |
| /speak | BETA — speak text aloud through the local voice daemon; the last reply by default, or whatever you pass. Detached. | **BETA** — speak text aloud through the local voice daemon; the last reply by default, or whatever you pass. Detached and on demand, needs no hook and no always-on state, and is NOT a `himmelctl` install item. Needs a local runtime that is not in the repo — see [`docs/voice.md`](voice.md) (HIMMEL-1522). |
| /stop | Graceful-halt marker for in-progress /overnight-shift sessions. |  |

## Prompt / discovery

| Command | Description | Notes |
|---|---|---|
| /improve | Refine a draft prompt via a hybrid clarifying-Q workflow; writes an audit artifact and returns the refined prompt. | Refine a draft prompt via hybrid clarifying-Q workflow. Writes an audit artifact to .improve/ + returns the refined prompt for resubmission. HIMMEL-127. |
| /skill-find | Embedding-indexed lookup over installed skills/commands/agents — eliminates wrong-namespace mistakes. |  |
| /luna-backfill | Backfill old Claude session transcripts into the luna vault as session notes. TOKEN-INTENSIVE — --dry-run first. | Backfill old Claude session transcripts into the luna vault as structured session notes. TOKEN-INTENSIVE — warns before running and recommends --dry-run first. |
| /luna-ingest | Chain-following triage for a github repo URL. Thin wrapper over the obsidian-triage:luna-ingest skill. | Chain-following triage for a github repo URL. Thin wrapper that delegates to the obsidian-triage:luna-ingest skill (LUNA-9 skill conversion — see marketplace/plugins/obsidian-triage/skills/luna-ingest/SKILL.md for the runbook). |
| /telegram-clip | File a Telegram message (text, bare URL, or forward) as a harvest-ready LUNA-2 clip note in luna's Clippings/. | File a Telegram message (text / bare URL / forward) as a harvest-ready LUNA-2 clip note in the luna vault's Clippings/. Thin wrapper that delegates to the obsidian-triage:telegram-clip skill (LUNA-58 — see marketplace/plugins/obsidian-triage/skills/telegram-clip/SKILL.md for the runbook). |
| /roadmap-clips | Aggregate actionable items across the luna vault into a sequenced 60-Maps/ roadmap note. Proposals only. | Aggregate actionable items across the luna vault (daily action items, _deferred.md backlog, synthesis proposals, promotion candidates, component inventory), cluster into a sequenced roadmap mapped to tools, dedup candidate tickets against open Jira, and write a 60-Maps/ roadmap note. Proposals only. Thin wrapper that delegates to the obsidian-triage:roadmap-clips skill (LUNA-59 — see marketplace/plugins/obsidian-triage/skills/roadmap-clips/SKILL.md for the runbook). |
| /luna-upgrade | Content-preserving upgrade of a luna-second-brain vault to the current himmel template. --check just reports. | Content-preserving upgrade of an existing luna-second-brain vault to the current himmel template (dry-run → confirm → apply, or --check to just report whether an upgrade is available). Thin wrapper that delegates to the obsidian-triage:luna-upgrade skill (HIMMEL-389 — see marketplace/plugins/obsidian-triage/skills/luna-upgrade/SKILL.md for the runbook). |
| /luna-upgrade-all | Multi-vault luna upgrade sweep — dry-run first, per-vault confirmed apply, backup/restore, conflict-brainstorm. | Multi-vault upgrade sweep — discover all luna-second-brain vaults, dry-run-first, per-vault operator-confirmed apply, backup/restore safety net, and conflict-brainstorm on _CLAUDE.md conflicts. Thin wrapper that delegates to the obsidian-triage:luna-upgrade-all skill (HIMMEL-462 — see marketplace/plugins/obsidian-triage/skills/luna-upgrade-all/SKILL.md for the runbook). |

## Clipper pipeline (obsidian-triage plugin)

Four-stage pipeline over the luna vault's `Clippings/` inbox
(HARVEST → TRIAGE → SYNTHESIZE → ARCHIVE). Plugin-provided
(`marketplace/plugins/obsidian-triage/commands/`); full spec in that
plugin's `README.md`. `/luna-ingest` (under Prompt / discovery above) is
the github-repo ingest skill these dispatch to.

| Command | Description | Notes |
|---|---|---|
| /harvest-clips | Stage 1 — autonomous HARVEST pass: mark unharvested clips (`harvested_at:`), dispatch github URLs to `luna-ingest`, clip-body for the rest. Idempotent. |  |
| /ig-media-enrich | IG media rung (after ig-embed): download reel/carousel media via gallery-dl (burner cookies), local faster-whisper transcript for reels, copy carousel slides into Clippings/_media/ + agent-read slide digest via the mechanical --apply-digest applier. Lean-invoke. HIMMEL-770. |  |
| /x-media-enrich | X/Twitter media rung (parity with ig-media-enrich): for X clips referencing video.twimg.com / pbs.twimg.com media with no media_enriched_at, download the tweet's video/GIF/images via gallery-dl (burner cookies at ~/.luna/cookies/twitter.txt), local faster-whisper transcript, first-frame screenshot for soundless GIF-like videos, copy images into Clippings/_media/ + agent-read slide digest via --apply-digest. --include-done drives the historical backfill. Lean-invoke. HIMMEL-1226. |  |
| /triage-clips | Stage 2 — autonomous triage: summarize, infer tags, suggest Related Notes, extract action items → daily note, annotate promotion candidate, mark `processed: true`. Idempotent. |  |
| /synthesize-clips | Stage 3 — cross-clip synthesis: find recurring patterns across processed clips, write proposal pages to `Clippings/_synthesis/` (proposals only, never restructures). |  |
| /archive-clips | Stage 4 (LUNA-55) — graduate fully-chained clips (harvested ∧ processed ∧ in-synthesis) to `Clippings/_done/<YYYY-MM>/`, rewrite inbound links (literal, boundary-safe), dedup by canonical URL, (re)generate `Clippings/_deferred.md`. |  |
| /synthesize-stubs | SYNTHESIZE stub mode (LUNA-87) — the generative path that compounds the evidence pool into early `status: stub` subject pages. |  |
| /deepen-subject | github source fan-out on promotion (LUNA-89) — fills the `## References` scaffold of a `deepen_pending: true` Tech subject page from its linked github sources. |  |
| /contra | CONTRA passes (LUNA-96/97): ghost-self — past-you (notes older than the `--min-age` duration, default 6m; age from frontmatter `date:`, daily notes falling back to the `YYYY-MM-DD.md` filename) reacting to current-you with verbatim-quote guard; --bridge — one forced cross-domain analogy (max one bridge/day). Appends to today's daily note `## Thinking`. Lean-invoke only. |  |

**One-time backfill (not a stage):** `/migrate-clip-lifecycle <vault> [--dry-run | --apply [--month YYYY-MM] | --rollback <manifest>]` (obsidian-triage, LUNA-86) — deterministic, reversible, resumable engine (`tools/migrate-clip-lifecycle.mjs`) that migrates the historical top-level `processed: true` clips into `Clippings/_evidence/`, stamping `evidence_kind:` and rewriting every inbound wikilink across SIX literal boundary forms (3 plain + 3 `.md`-suffixed, the silent-dangle guard). Folder-keyed idempotent; byte-identical rollback via the manifest. Run ONCE behind a mandatory staging gate — not a recurring pipeline stage.

**Companion (not a stage):** `/read-link <url>` (obsidian-triage, LUNA-78) — vault-first link reader: read an already-harvested clip for a URL before any live fetch; enrich a thin clip, else live-fetch (fxtwitter / WebFetch / luna-ingest) as the last resort. Never Grok. UX inspired by eugeniughelbur/obsidian-second-brain's `/x-read` (clean-room, no vendored fork).

## Plugin skills & ops (himmel-ops, obsidian-triage)

Skills shipped by vendored plugins. Most trigger on a symptom or a slash
alias rather than a bare command; rows are paraphrased one-liners. Source
is the plugin's `skills/<name>/SKILL.md` (or `commands/<name>.md` where a
slash alias exists).

| Skill / command | What it does |
|---|---|
| /minerva (himmel-ops) | Run the grill→brainstorm→critic→spec→critic→plan pipeline as ONE pass with an adversarial critic loop between stages — one idea to a critic-hardened implementation plan. The single front door for grill / stress-test / brainstorm (HIMMEL-2039). Slash alias + dispatchable skill. |
| /fanout (himmel-ops) | Fan out N work items to the lane the invariant routing policy calls for (judgement/destructive → Fable; multi-step reasoning → Opus; well-specified implementation → Sonnet by default, never a dormant lane; scoped research → Sonnet; bulk mechanical → Haiku, never spawns further). `scripts/lanes/fanout-plan.mjs` validates every item against the LIVE roster (`scripts/lanes/resolve.mjs --json`) and refuses — no plan emitted — an unknown type, an unavailable or dormant lane, a bulk item requesting further spawn, or a destructive/irreversible item routed below judgement. Shows the plan, confirms before dispatching, enforces the context/why/done-looks-like + RETASK-block + attestation-trailer brief shape (HIMMEL-1829). |
| stuck-playbook (himmel-ops) | Load-on-trigger guardrail-recovery escape-hatches — fires on a denial/friction symptom (auto-mode Bash/Jira write denied, hung permission prompt, missing attestation trailer). Surfaces escape-hatches kept out of the always-on root CLAUDE.md (HIMMEL-211). |
| vm (himmel-ops) | Lean-invoke VM lifecycle + e2e runbook — front door to the central VM-control SDK (`scripts/lib/vmsdk.py`); covers up/down/snapshot/restore/baseline/clone/provision/e2e verbs, the engine pass + skill pass probes, and the `sync_repo`/`install_plugin`/`drive_claude` SDK primitives (HIMMEL-491/493). |
| /memory-compound (himmel-ops) | Lean-invoke: losslessly compound the per-project auto-memory (`MEMORY.md` index + topic files) into qmd-searchable luna `30-Resources/Tech/` (or himmel `docs/internals/`) reference notes — read-many → write-once → qmd gate → slim index → delete sources. Run when `MEMORY.md` nears its ~24.4KB load budget. Slash alias + dispatchable skill (HIMMEL-569). |
| vault-lint (obsidian-triage) | Filesystem-only, report-only vault health lint — a single deterministic Python pass that converges on large PARA vaults (orphans, broken wikilinks, audit). Vault-agnostic. |
| luna-vitals-extract (obsidian-triage) | Backfill salus health series for one vault time-bucket (HIMMEL-355) — extracts (date, metric, value) tuples via the luna-vitals CLI + an LLM prose pass, writing one per-bucket review artifact. Single-writer; never writes 50-Vitals/ directly. |
| /grow-feed-log (obsidian-triage) | Extract a grow-tent feed/watering (free-form text, e.g. "added 5L + 2 caps to the mint") or a bare nutrient-label photo from a Telegram-shaped message and append it to the vault's `20-Areas/Grow/Grow-Feeding-Log.md` — a feed row to `## Log`, a new product to `## Products`. LLM-first (no rigid command grammar); idempotent per message-id; append-only. Telegram routing is LUNA-127 (separate, out of scope). Slash alias + dispatchable skill (LUNA-130). |

## Utility

| Command | Description | Notes |
|---|---|---|
| /quiet-run | Run a noisy command quietly — one OK/ERR line + log path |  |
| /lanes | Print the delegation/critic/bulk lanes actually available on THIS machine (availability-aware). | Print the delegation/critic/bulk lanes actually available on THIS machine (HIMMEL-689 — availability-aware, derived from scripts/lanes/lanes.json + machine state; the invariant delegation policy stays in CLAUDE.md). |
| /himmel-doctor (himmel-ops) | Diagnose common harness health problems (stale guardrail-hook node path, shadowed claude-obsidian, dirty single-writer luna vault, bitbucket-vs-gh, handover-registry gaps, PATH-fragile bare-interpreter MCP servers); severity-grouped report; `--fix` re-bakes the guardrail node wiring; `--file-issue` files ONE consolidated public GitHub issue. |  |
| /himmel-update | Update this himmel checkout (harness) — pull, marketplace, jira CLI, qmd, hermes, luna template, plus advisories. | Update this himmel checkout (harness) — six-item dependency chain (pull, marketplace, jira CLI dist, qmd fork, hermes, luna template) with per-item status + abort-on-first-failure, plus best-effort advisory steps (codex re-sanitize, statusLine re-wire, plugin gap report, plugin-set reconcile, cadence/guardrail drift checks) and the machine-local catch-up steps (graphify pin sync, cli-proxy-api host roll, installed-marketplaces re-sync, qmd daemon-restart notice — HIMMEL-2134). Those catch-up steps exist because a merged pin bump reaches the REPO but not the MACHINE, and that staleness is invisible to `check-plugin-drift.sh` (for a `mode: base` entry the guard reads `synced_base`, which `apply-drift-bump.sh` moved with the pin, never the installed artifact). `--only <item>` re-runs a single step without the full chain. `himmelctl update` runs the same engine. autoUpdate does NOT deliver the checkout (git pull) or the core hooks/slash-commands — it only re-syncs installed plugins from the on-disk dir. A configured LUNA_VAULT_PATH is already refreshed by step 6 of this chain; use /luna-upgrade only for an explicit Luna-only run, and /himmel-update-all for multi-vault workflows. |
| /himmel-update-all | Update BOTH surfaces in one shot — the himmel harness then the luna vault. Pass --check to dry-run both. | Update BOTH the himmel harness (/himmel-update) and the luna vault (/luna-upgrade) in one shot; `--check` dry-runs both. |
| /graph-publish | Publish a freshly-refreshed graphify graph — commit and open/refresh a PR against tracked graphify-out/ artifacts. | Publish a freshly-refreshed graphify graph — commits + opens/refreshes a PR against the tracked graphify-out/ artifacts (HIMMEL-1129). |
| /graph-refresh | One-shot operator refresh of the luna and/or himmel graphify graphs — one refresh-graph-map.sh run per corpus. | One-shot operator refresh of the luna and/or himmel graphify graphs — fires refresh-graph-map.sh per corpus serially with the cadence's argument sets (HIMMEL-1644). |
| /prose-audit | Find mechanical prose in commands and skills that should be a script call, ranked by candidate size. | Find mechanical prose in commands and skills that should be a script call, ranked by candidate size for inspection — flags files over a size threshold with a high fenced-code ratio; the session judges only the flagged set (HIMMEL-1939). |
