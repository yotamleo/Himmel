# Tool-adoption registry — every evaluated tool, recorded (HIMMEL-201)

> A dynamic index with two jobs: it records every tool that ran through
> the [tool-adoption rubric](rubric.md) (HIMMEL-200), **including rejected
> ones**, AND holds our own in-house borrow-candidates — items we like,
> parked, that won't necessarily ship. The rubric decides; this file
> records the decision so it isn't re-litigated, and keeps our own ideas
> searchable so we borrow rather than rebuild. Part of the HIMMEL-199
> framework.
>
> Rejected rows are the most valuable entries here — they stop a settled
> tool being re-evaluated from scratch next quarter (rubric §3).

## How to read this

- **Layer (A/B/C/D)** and **trust-tier** reuse the rubric's definitions
  verbatim — see [rubric §2](rubric.md#2-trust-posture-tiers) for tiers and
  the layer taxonomy below. Do not redefine them here.
- **Status** is one of the rubric's decision states ([rubric §3](rubric.md#3-decision-states)),
  mapped to a registry-friendly label:
  `in-use` = ADOPT, `pilot-pending` = PILOT-MEASURE (not yet run/closed),
  `rejected` = REJECT.
  - `parked-idea` is a fourth label, used only in the own-items index
    below: an in-house item we like and want searchable to borrow from —
    NOT a community ADOPT/REJECT decision, and NOT committed to ship.
- **KPI** is the desired outcome-per-session, never %-tokens
  ([rubric §1](rubric.md#1-goal-articulation) — the vanity-metric trap).
- **Measuring `in-use` rows** — the before/after protocol only applies to
  net-new installs. For items already in the default path the accepted
  protocol is **measure-during**: 0-cost live telemetry captured while
  real work runs ([rubric §4](rubric.md#4-measurement-protocol);
  format + emit lib: [`telemetry.md`](telemetry.md), HIMMEL-236).
- **ADR link** — ADRs may not exist yet. `—` means no recorded ADR; the
  ticket in the source column is the decision trail until one lands. Do
  not fabricate ADR paths.

## How to use this index

- **Search-first** — before building or evaluating anything, search this
  index. A settled REJECT or an existing borrow-candidate may already
  answer the question, no new eval needed.
- **Port-in** — found a community item whose use-case fits a real
  session? Don't adopt on the pitch — open a PILOT (rubric §3) and record
  it here.
- **Borrow** — the own-items `parked-idea` rows are a borrow-library:
  lift the idea, don't re-derive it.

### Layer taxonomy (from the luna synthesis)

Layers are from the 8-tool luna synthesis
(`30-Resources/Tech/token-optimizer-tools.md`): composing across layers is
additive, competing within a layer is substitutive.

- **Layer A** — prompt / response shape (output Claude generates per turn).
- **Layer B** — tool-output filtering (noise tool calls inject into context).
- **Layer C** — setup / scaffolding (how Claude reads the project once).
- **Layer D** — MCP / runtime (protocol-layer; needs MCP-compatible client).

## Registry

| Tool | Layer | Source | Status | Desired outcome (KPI) | Trust-tier | ADR |
|------|-------|--------|--------|-----------------------|------------|-----|
| rtk | B (tool-output filtering) | `luna 30-Resources/Tech/token-optimizer-tools.md`; `docs/tooling-catalog.md` | in-use | Less tool-output noise in context per session → longer useful context window, fewer re-launches on long sessions | `community-active → validate-before-adopt` (battle-tested, Rust binary, zero deps) | — |
| token-savior | D (MCP / runtime) | HIMMEL-170; `luna 30-Resources/Tech/mibayy-token-savior.md` | rejected | (structural code-nav + persistent memory) — rejected 2026-06-13: its pitch is token-% (-77% active / -76% wall benchmark), but our KPI is outcome-per-session, NOT token-% (rubric §1 vanity-metric trap; @ashwingop's "Token Burn Is the New Vanity Metric", cited in HIMMEL-170 itself). rtk already serves Layer-B tool-output noise reduction; a substitutive token-% optimizer buys no new outcome-per-session, only added MCP-runtime surface + an unreproducible benchmark. HIMMEL-170 → REJECT | `source-read-mandatory` (claims a benchmark — 100% / -77% active / -76% wall on Opus 4.7 — we can't independently reproduce, so read the impl) | HIMMEL-170 comment |
| engram | memory layer (D-adjacent) | LUNA-44 | pilot-pending | Persistent memory survives across sessions → fewer "re-explain the same context" turns, work resumes faster | `source-read-mandatory` (persistent-memory store; touches what the agent remembers — read before it runs) | — |
| skill-factory / autoresearch | skill-quality | HIMMEL-167 | pilot-pending | Higher-quality generated skills → fewer manual skill fix-ups, a research loop that actually files usable output | `community-active → validate-before-adopt` (sandbox-test generated skills in a throwaway worktree before any real use) | — |
| nizos/tdd-guard | PreToolUse hook | HIMMEL-182; `luna 30-Resources/Tech/nizos-tdd-guard.md` | pilot-pending | TDD enforced structurally → fewer untested-code regressions slipping through | `source-read-mandatory` (touches the PreToolUse hook stack — sees/alters every tool call; rubric §2 makes impl-read non-negotiable) | — |
| hermes-agent (Nous) junior tier | agent runtime (D-adjacent — separate agent under himmel orchestration) | HIMMEL-272 (rubric pass + ADR comment, 2026-06-11); HIMMEL-277 (gemini-cli route spike; OAuth routes later VOIDED by operator); HIMMEL-278 (free routes WIRED 2026-06-12: NIM nemotron-3-ultra default → OpenRouter :free → gemini-flash; route table + rebuild steps `docs/hermes-runbook.md`); `luna 30-Resources/Tech/nousresearch-hermes-agent.md`; install `%LOCALAPPDATA%/hermes` | pilot-pending | Junior-shaped chores (vault inbox capture, note-taking, summaries) ship on free inference without burning Max quota or operator babysitting; zero write-fence violations | `source-read-mandatory` (free Nous endpoint — prompts leave the machine; mitigations: curated read tier hot.md/index/CLAUDE.md/synthesis/60-Maps, write fence `Clippings/hermes-*.md` only, in-house fail-closed `lunavaultguard.py` guard hook — self-protecting, authored + read locally) | HIMMEL-272 ADR comment |
| mksglu/context-mode | B (tool-output filtering) | HIMMEL-183 (primary eval, completed 2026-06-12); HIMMEL-170 AC (superseded passing rejection); `luna 30-Resources/Tech/mksglu-context-mode.md`, `…/token-optimizer-tools.md` | rejected | (tool-output sandboxing) — rejected ON-MERITS after full source read + sandbox test: 0% structural reduction on 4/5 noisiest himmel patterns (native Glob/Grep/Read/Bash pass through unchanged, advisory nudges only), net-negative always-on session overhead, 3 hook-stack interference vectors (deny short-circuits PreToolUse chain; unlocked settings.json read-modify-write; ~500-word Agent-prompt mutation per dispatch) | `source-read-mandatory` (98% claim measured: their own BENCHMARK.md says 96%, conditional on voluntary ctx_* routing — not interception) | HIMMEL-183 context-mode eval (operator's private handover repo) |
| lightpanda-io/browser | headless-browser backend (infra, D-adjacent) | HIMMEL-284 (Docker-on-Windows eval, completed 2026-06-12, 14 days inside timebox); hermes `AGENT_BROWSER_ENGINE=lightpanda` (wired-adjacent, auto-fallback to Chrome); `docs/hermes-runbook.md` | rejected | (lightweight headless browser) — rejected NO-WORKLOAD after live Docker probe: viability CONFIRMED (image 68.5 MB vs Chrome 281 MB; 40.5 vs 88.8 MiB RSS; 0.68 s startup; CDP + puppeteer-core worked first try on Windows Docker; GitHub/blog pages render full text) but every candidate slot fails today — IG `/embed/captioned/` returns a 114-char shell (the shipped HIMMEL-280 plain-fetch rung gets full captions), clipper harvest needs no browser (LUNA-2 bodies), hermes junior-tier browsing is not yet a real workload. Re-open trigger: hermes browsing chores materialize → set `AGENT_BROWSER_ENGINE=lightpanda` (one env var, auto-fallback to Chrome) + PILOT-MEASURE. Beta caveats: CORS unimplemented, no screenshots, x.com loads shell-only pre-hydration, glibc-only binaries | `community-active → validate-before-adopt` (validated in throwaway Docker sandbox; no hook/secret surface, container-isolated; benchmark claims independently reproduced on memory, NOT on nav speed) | HIMMEL-284 lightpanda eval (operator's private handover repo) |
| caveman | A (prompt / response shape) | `luna 30-Resources/Tech/token-optimizer-tools.md`; `docs/tooling-catalog.md` | rejected | (terser responses) — rejected: clashes with the docs-quality bar (caveman compression degrades the readable-docs output this repo requires) | `community-active → validate-before-adopt` | — |
| ooples/token-optimizer-mcp | D (MCP / runtime) | `luna 30-Resources/Tech/token-optimizer-tools.md` | rejected | (MCP caching/compression) — rejected: no reproducible benchmark; relies on caching-style claims with no measured number we can verify | `source-read-mandatory` (claims -95%+, unverifiable) | — |
| drona23/claude-token-efficient | A (prompt / response shape) | `luna 30-Resources/Tech/token-optimizer-tools.md` | rejected | (terse-response CLAUDE.md policy) — rejected: lower-leverage layer; overlaps existing CLAUDE.md hygiene, marginal outcome-per-session gain | `docs-claim-trusted` (drop-in CLAUDE.md, trivially reversible) | — |
| alexgreensh/token-optimizer | C (setup / scaffolding) | `luna 30-Resources/Tech/token-optimizer-tools.md` | rejected | (ghost-token / compaction-drift audit) — rejected: lower-leverage layer; no benchmark, periodic-audit value unproven for this workload | `community-active → validate-before-adopt` | — |
| nadimtuhin/claude-token-optimizer | C (setup / scaffolding) | `luna 30-Resources/Tech/token-optimizer-tools.md` | rejected | (one-time project-doc rewrite) — rejected: lower-leverage layer; one-shot setup pass, marginal recurring outcome | `community-active → validate-before-adopt` | — |
| `/code-review ultra` (built-in) | CR toolkit (review subagents) | HIMMEL-299 (eval 2026-06-13, items 2–4) | in-use | Lower missed-critical on big/risky PRs — multi-agent **cloud** escalation tier for exactly the PRs where solo/holistic passes are weakest (the class where cavecrew-solo fabricated 2 Criticals). **MOST EXPENSIVE tier — costs MORE than the 6-reviewer heavy CR, so it sits ABOVE heavy CR on the cost ladder: reach it AFTER heavy CR for the biggest/riskiest PRs, never as a cheaper first escalation** (operator-conventions.md CR-sizing ladder). User-triggered + **billed**; the agent cannot launch it. Open follow-up (operator, billed, one action): a live calibration run on a recent real PR to confirm it adds catches over the solo pass without flooding noise | `docs-claim-trusted` (built-in Anthropic tool, zero install, trivially reversible — rubric §3 ADOPT-without-pre-measurement case) | HIMMEL-299 ADR comment |
| wshobson/agents code-reviewer | CR toolkit (review subagent) | HIMMEL-299 (eval 2026-06-13); `luna 30-Resources/Tech/wshobson-agents.md` | rejected | (CR subagent swap) — rejected: substitutive with the `pr-review-toolkit-himmel` fork AND lacks its confidence-gate + verify-before-critical (HIMMEL-178) discipline (verbatim source-read of `plugins/comprehensive-review/agents/code-reviewer.md` — "elite/comprehensive" maximalist posture, no threshold). Replayed-PR benchmark (#463 + #453): ties the fork on the KPI (0 false Criticals both) but +9 minor-noise findings across 2 PRs vs the fork's 0; only a marginal recall edge. Wrong direction for a fabricated-Critical failure mode. Scope: reviewer-as-toolkit-swap only — broader 192-agent marketplace not re-litigated | `community-active → validate-before-adopt` (validated: verbatim source-read + 2-PR replay) | HIMMEL-299 ADR comment |
| tirth8205/code-review-graph | CR toolkit / code-intelligence graph (MCP + CLI) | HIMMEL-299 (eval 2026-06-13); `luna 30-Resources/Tech/tirth8205-code-review-graph.md` | rejected | (repo-context graph for reviews) — rejected: its only benchmark is %-token-reduction (~82× median / 528× max), the vanity metric rubric §1 says to read-the-impl-not-adopt; its review-quality 0.71 F1 is **circular** by the author's own admission ("ground truth comes from the same graph edges the predictor walks … upper bound by construction"). Targets "reviewer lacks context" but the anchor's context-failure already self-corrects via grep + is cured by verify-before-critical (shipped, zero-cost), and the tool REDUCES files-read (wrong direction). No measured KPI benefit + MCP-runtime blast radius = REJECT. Parked-idea below | `source-read-mandatory` (claims benchmark numbers + MCP runtime — impl/claims read) | HIMMEL-299 ADR comment |
| firecrawl/firecrawl (`/v2/scrape` API) | D (runtime / external data-fetch) | HIMMEL-320 (thin-body escalation, 2026-06-16); clip `firecrawl-firecrawl.md` → `30-Resources/Tech/firecrawl-firecrawl.md` | in-use (opt-in escalation) | Thin-body **article/web** clips the Web Clipper captured poorly get clean markdown instead of being lost → the deferred LUNA-27 gap closes for non-X/non-github URLs, without a browser. **Escalation lane, not a default path** — gated behind `--firecrawl-thin`, budget-capped (`--firecrawl-budget`, default 20/run) to protect the 1000-credit/mo free tier; X/github/youtube excluded (owned by twitter-cli / luna-ingest / playwright-youtube). Self-host via `FIRECRAWL_BASE_URL` for operators with more budget. The hosted API SDKs are AGPL but we call the REST endpoint over stdlib urllib (no dep, no code lifted) | `docs-claim-trusted` (well-known hosted API; only public URLs + the page content transit firecrawl's servers — no secrets egress beyond the API key; trivially reversible — drop the flag). **Open: 1-credit live smoke** to confirm the documented `/v2/scrape` response shape against the live API | HIMMEL-320 |
| public-clis/twitter-cli (agent-reach X backend) | D (runtime / external data-fetch) | `feat/x-thread-reply-capture` bake-off 2026-06-14 | in-use (integration pending) | Capture X reply-thread + first-comment repo URL per flagged clip → clips whose payload lives in a reply/self-thread ("↓ repo in comment") get enriched, not lost. **Won the bake-off vs Playwright** (Playwright blocked at login by X/Google anti-automation; couldn't even capture a session). `twitter tweet <id> --json` returns focal + same-author self-thread + other-author replies + `quotedTweet`, each with pre-parsed `urls[]` (proven: extracted `github.com/Panniantong/Agent-Reach` from the example's first self-reply). Auth = explicit `TWITTER_AUTH_TOKEN`/`TWITTER_CT0` in gitignored `.env` (Chrome App-Bound-Encryption v127+ kills cookie auto-extraction). **BURNER account only, never the main.** Adoption decided; pipeline integration is the open implementation | `source-read-mandatory` (scrapes X with burner session cookies — ToS-gray, account-ban risk, reads the cookie DB; impl + auth read mandatory) | — |

## Dynamic index — our own items

In-house items we like but won't necessarily ship, kept here so they're
searchable and borrowable instead of rebuilt. Status is always
`parked-idea` — these aren't community ADOPT/REJECT decisions.

| Item | What we like | Status | Source |
|------|--------------|--------|--------|
| caveman | Response-mode compression — installed but default mode set `off` 2026-06-12 (operator: the main-loop model already outputs ~40% fewer tokens; clashed with Anthropic brevity guidance); `rejected` for the default token stack (row above); kept to borrow the compression ideas. Fable→Opus 4.8 revert executed early 2026-06-13 (HIMMEL-282 closed, HIMMEL-300 archives the Fable tuning) — whether to re-enable is an open question | parked-idea | `docs/tooling-catalog.md`; HIMMEL-199 |
| worktree-isolation plugin | Generic marketplace extraction of our worktree-isolation pattern (`/worktree` `/clean` `/clean_garden`) so it works for any repo — extraction filed, not built | parked-idea | HIMMEL-234 |
| emergence→self-improvement crystallization | Triggered pass that crystallizes emerging vault clusters into derived self-improvement candidates — design parked-documented, won't necessarily build | parked-idea | `docs/luna/emergence-crystallization.md`; HIMMEL-217 |
| >100KB auto-externalize + BM25 retrieval | The one genuinely good context-mode pattern (its Part-3 design): oversized tool output auto-indexes into local FTS5 instead of truncating, model retrieves sections on demand — nothing lost, nothing flooding context. If himmel ever needs this shape, extend qmd (already local BM25+vec over markdown) rather than adopt context-mode | parked-idea | HIMMEL-183 ADR (operator's private handover repo) |
| CR context-graph for large-repo reviews | The borrowable idea behind the rejected code-review-graph: a persistent codebase graph so a reviewer reads only the files that matter, for reviews whose context exceeds a single window. himmel is not large-repo today, so it was REJECTed on the KPI. If himmel ever hits large-repo review-context limits, extend qmd (already a local BM25+vec index over the repo) rather than adopt an MCP graph runtime — same reasoning as the >100KB row above | parked-idea | HIMMEL-299 ADR comment |

## Reconciliation notes

### context-mode — CLOSED `rejected` on-merits (HIMMEL-183 eval, 2026-06-12)

The reopened eval ran 2026-06-12 (overnight), same-day as the reopen and
14 days before the 2026-06-26 timebox expiry: full source read of
v1.0.162 + sandbox test feeding
the 5 noisiest himmel tool patterns through the real `pretooluse.mjs` +
live-repo size measurement. Verdict **REJECT** — full evidence in the
HIMMEL-183 context-mode eval ADR (operator's private handover repo).
Headline findings: the structural/interception layer reduces NOTHING on
Glob/Grep/Read/Bash (Glob unmatched; the rest get one-shot advisory
nudges while output passes through unchanged — the "98%" is their
fixture benchmark for data *voluntarily routed* through ctx_* MCP
tools, and their own BENCHMARK.md says 96%); always-on layers add ~1KB
of routing-block/nudge overhead per session; and three interference
vectors threaten the himmel guardrail stack (PreToolUse deny
short-circuits subsequent hooks; unlocked read-modify-write of
`~/.claude/settings.json` with a changelog-documented config-deletion
regression, #415; ~500-word prompt mutation on every Agent dispatch +
silent `subagent_type` rewrite, which fights HIMMEL-166/177 dispatch
discipline). The reopen itself was sound — rtk's corruption did
invalidate the substitutive shortcut — but the direct eval lands at the
same status for independent reasons. The rtk Layer-B reliability gap
REMAINS OPEN and is not solved by this rejection; if in-script
discipline keeps burning sessions, file a dedicated Layer-B eval.

### [SUPERSEDED by on-merits eval above] context-mode — REOPENED to `pilot-pending` (operator override, 2026-06-12)

*Decision-trail record only — the live status is `rejected` per the
closing note above; the `pilot-pending` this note argues for lasted from
the morning reopen to the same-day eval.*

**Operator decision 2026-06-12 (HIMMEL-283 audit follow-up): HIMMEL-183 wins.**
The `rejected` resolution below is superseded. Basis for reconsideration: the
rejection rested on rtk being the battle-tested incumbent at Layer B, but rtk
has since shown measured output corruption inside Claude Bash sessions
(top-level `git diff` rewritten to a stat summary feeding garbage to a CR
pipeline, HIMMEL-270; `grep`/`cat` file-redirects garbled even under
`rtk proxy` — see auto-memory `reference_rtk_rewrites_git_diff_in_bash`).
The substitutive-with-rtk argument assumed rtk reliably serves the Layer-B
KPI; that assumption no longer holds unqualified. HIMMEL-183 is reopened as
the primary eval, new timebox 2026-06-26 (ADR or Won't-Do). The original
reconciliation is preserved below for the decision trail.

### [SUPERSEDED 2026-06-12] context-mode — status RESOLVED to `rejected`

The spec flagged a contradiction over status. The two tickets are NOT
duplicates: **HIMMEL-183** is the *primary* context-mode eval (timeboxed to
2026-06-10, Won't-Do if no ADR by then). **HIMMEL-170** is the *token-savior*
eval — its acceptance criteria record context-mode only in passing, as one of
six "other tools rejected" ("context-mode — substitutive with rtk, less
battle-tested"). So the substitutive-with-rtk judgment already exists (in
HIMMEL-170's AC); HIMMEL-183 is the open eval that re-opens it. The registry
must resolve to one status — resolved to **`rejected`**.

Rationale, grounded in the luna synthesis
(`30-Resources/Tech/token-optimizer-tools.md`): context-mode sits at **Layer B
(tool-output filtering), substitutive with rtk** — they compete head-to-head at
the same layer. rtk is already **in-use** at Layer B and the synthesis
explicitly prefers it ("more battle-tested than context-mode; Rust binary, zero
deps"). Adopting a second, substitutive Layer-B tool buys no new outcome — the
KPI rtk already serves — while adding tool-output-path surface and an
unreproducible 98% benchmark claim. So context-mode is **rejected** on the
substitutive-with-rtk basis already captured in HIMMEL-170's AC, and
**HIMMEL-183 should close Won't-Do on that basis** — it is re-litigating a
settled question, which is exactly what this registry exists to prevent.

Discrepancy noted (not blocking): the HIMMEL-201 spec text describes
context-mode as a "Layer D hook," but its grounding luna doc classifies it as
**Layer B (tool-output, substitutive with rtk)**. The registry uses Layer B per
the grounding doc, since the substitutive-with-rtk relationship — the whole
basis of the REJECT — only holds at Layer B.

### Rejected-tool rationale source

`caveman`, `ooples`, and the `drona23 / alexgreensh / nadimtuhin` lower-leverage
trio are recorded as `rejected` per the HIMMEL-201 spec. Their layer
classifications and substitutive/leverage relationships are grounded in the
luna 8-tool synthesis (`30-Resources/Tech/token-optimizer-tools.md`). Note:
`caveman` is currently installed as a response-mode plugin
(`docs/tooling-catalog.md`); its `rejected` status here is scoped to the
HIMMEL-199 default-path question — it is not adopted into the default token
stack because compression conflicts with this repo's docs-quality bar.

### Luna sources read

All four cited luna docs were readable at
`~/Documents/luna/30-Resources/Tech/`:
`token-optimizer-tools.md`, `mibayy-token-savior.md`, `nizos-tdd-guard.md`,
`mksglu-context-mode.md`. The 8-tool comparison
(`token-optimizer-tools.md`) is the primary grounding for every Layer
assignment and the context-mode reconciliation.
