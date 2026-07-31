# Lane calibration — tiers, effort, and cost

> **If you are not a Claude session, read this as an inventory, not an identity.**
> The model names below (Haiku, Sonnet, Opus, Fable) name LANES this operator can
> dispatch work to — they do not describe you, and a Claude-family fact stated
> here (effort equivalences, quota posture) is not a fact about your own model.
> Route only to what `/lanes` lists on this machine. `AGENTS.md` is debranded for
> non-Claude harnesses (`scripts/agents-md/debrand.json`); this file is reference
> detail linked from it and is deliberately NOT rewritten, so the orientation is
> stated here instead (HIMMEL-559 / HIMMEL-480).

Reference detail for the delegation policy. The **directives** (name an explicit
model, raise effort before tier, spawn-depth 2, Haiku does not spawn,
single-writer, the salus provider restriction) stay resident in
[`CLAUDE.md`](../../CLAUDE.md) — a directive behind a lookup is a dead directive
(see [`context-architecture.md`](context-architecture.md#memory-as-a-map-not-a-backend)).
What lives here is the fact-shaped part: which lane suits which work, and how to
set effort.

The live per-machine inventory is **`/lanes`** (derived from
`scripts/lanes/lanes.json` + machine state, HIMMEL-689). Never route to a lane
`/lanes` does not list. The tier semantics below are invariant; the inventory
is data.

## Tier semantics

| Lane | Best for | Effort / notes |
|---|---|---|
| Haiku | bulk mechanical (never delegates further) | low |
| Sonnet 5 | scoped research; default implementor for well-specified impl briefs | medium default; high for multi-file/long briefs — raise effort before reaching for Opus |
| Opus 4.8 | multi-step reasoning; default parent/orchestrator | xhigh for orchestration; scale DOWN (high/medium) for lighter parenting or scoped impl |
| Fable 5 | judgment, taste — hardest calls; escalation target | scale to the item (operator 2026-07-08, un-capped): medium default; high for substantial judgment work — not just the hardest; xhigh for the hardest |

Beyond the Claude tiers the fleet includes machine-specific impl/critic/bulk
lanes (paid/optional — they exist only where the operator configured them). See
[Non-Claude lane calibration](#non-claude-lane-calibration) below.

Labels above mirror `scripts/lanes/lanes.json`, which is authoritative. When a
tier's underlying model ships a new generation, update `lanes.json` first and
this table follows — never the reverse.

## Non-Claude lane calibration

Every lane `scripts/lanes/lanes.json` registers gets a row here. The columns
are the **invariant** calibration facts (class, effort convention, context
ceiling, cost/quota posture, calibration status) — not the full description,
chokepoint invocation, or roster detail, which stay in `lanes.json` (data) and
[`tooling-catalog.md`](../tooling-catalog.md#other-delegation-lane-dispatch-chokepoints-scriptslaneslanesjson-registry-himmel-689)
(dispatch shape). Restating that prose here would create a second copy that
silently drifts (the HIMMEL-1021 class) — this table is deliberately thin.

`quota bank` reflects the `quota.bank` field in `lanes.json`; a lane without
one is **dashboard-omitted** from the quota exporter (HIMMEL-1000) — that's a
registry fact, not a doc gap. `cost-optimal context window` is exactly that —
NOT a hard ceiling: larger inputs remain possible past it at higher cost (e.g.
2× billing past 272k on the codex-quota lanes), per the registry's own wording.

| Lane (`lanes.json` id) | Class | Default effort convention | Cost-optimal context window | Quota bank | Calibration status |
|---|---|---|---|---|---|
| `glm` — GLM lane (spawn-glm.ts) | impl | small-context discipline — chunk big plans | 1M | glm (flat-rate overflow, not per-token) | calibrated |
| `glm-subagent` — GLM inline subagent | impl | same as `glm`, inline in-session dispatch | 1M | glm | calibrated |
| `claudex` — claudex lane (claude-codex over CLIProxyAPI) | impl | launcher default `high`; `xhigh` rare; never `ultra`/`max` | 272k (2× bill past) | codex | calibrated (HIMMEL-1001/1002) |
| `hermes-critics` — hermes free critics (qwen3coder) | critic | — (critic pass, not effort-tiered) | unverified/varies | none (dashboard-omitted) | calibrated — CR panel only (`/pr-check`) |
| `codex` (paid, via hermes) | critic | — (critic pass) | 272k | none (dashboard-omitted); opt-in `CR_PROFILE=paid` | calibrated — CR escalation / second opinions only |
| `copilot-cli` — GitHub Copilot CLI (free tier) | bulk | small tasks; model tier is mini-class unless the caller overrides the auto pin | unverified/varies | none (dashboard-omitted); 2,000 completions/mo bank | **not calibrated yet** — worker-spawn-matrix row UNVERIFIED (live smoke pending eval); route only for free chores / second opinions, and only through the `dispatch-copilot.sh` chokepoint |
| `hermes-oneshot` — hermes one-shot dispatch | impl | no internal timeout — caller wraps | unverified/varies | none (dashboard-omitted) | calibrated — live-proven spawn path |
| `codex-exec` — codex CLI sandbox | impl | well-scoped chunks; job registry is per-workspace | 272k | codex | calibrated (HIMMEL-741) |
| `codex-wsl` — codex WSL lane | impl | well-scoped chunks; brief via `--brief-file` | 272k | codex | calibrated (HIMMEL-999) |
| `antigravity-cli` — Antigravity CLI (Google AI Plus) | bulk | simple tasks; `--output-format` drift seen on Windows builds | unverified/varies | none (dashboard-omitted); free AI-Plus bank | **not calibrated yet** — roster + quota shape TO VERIFY at eval (HIMMEL-772); parity/guards UNVERIFIED (permission flags only, no hook surface); egress-DENIED for vault corpora, himmel-code only; route only for free-bank chores / second opinions |
| `ollama-local` — ollama (local models) | bulk | slow, small tasks | unverified/varies | none (dashboard-omitted); free, local wall-clock | calibrated — zero-egress guarantee is structural; the only salus-eligible backend |
| `openrouter-free` — OpenRouter free models | bulk | simple tasks only; rate-limited | unverified/varies | none (dashboard-omitted) | **not calibrated yet** — parity/guards UNVERIFIED pending eval; probe live availability before routing, route only for simple free-tier chores |
| `ollama-cloud` — Ollama Cloud (free tier) | bulk | simple tasks; free-bank caps | unverified/varies | none (dashboard-omitted) | **not calibrated yet** — parity/guards UNVERIFIED pending eval; egresses to ollama.com, an undeclared egress-matrix provider — vault corpora default-DENY (himmel-code only) until the operator declares a cell; route only for free-bank chores on non-vault corpora |

## Effort calibration

Effort is a **per-dispatch** lever — use the full scale per item, do not flatten
to one default. Raise effort before raising model tier: Fable-5 `low` ≈
prior-gen `xhigh`, and the same shift applies down-tier.

Anthropic's published **Claude Opus 5** prompting guidance — cited here as the
newest available guidance for the Opus family, not as a claim that the Opus lane
above already runs Opus 5 — is to use `low` and `medium` liberally as the
primary control for token cost and latency wherever quality holds, and to step
up to `xhigh` only for demanding coding and agentic work. Effort defaults
carried over from a prior model should be re-swept against real evals rather
than assumed — that sweep is HIMMEL-774, which is also where the lane's own
model generation gets revisited.

Temperature is Claude-API-only — deferred; rides HIMMEL-774.

## Cost posture

Fable stays **conserved** (limited release) — the spread optimizes
Sonnet/Opus/impl lanes. Sonnet 5 carried introductory pricing ($2 per
million input tokens / $10 per million output tokens) through 2026-08-31;
recalibrate in September against Anthropic's published pricing (HIMMEL-774).

Pricing and per-lane benchmark analysis are volatile: treat any figure here as
needing revalidation before it drives a routing decision.

## Escalation shape

The parent does not have to be the top model — an Opus parent spawns a Fable
child for the one hard call; the child answers and returns. The top-tier
parent-selection restriction and its downward-delegation rule are **directives
and stay resident in [`CLAUDE.md`](../../CLAUDE.md)** — a directive behind a
lookup is a dead directive. What belongs here is the rationale: Fable is
limited-release and conserved; when it is the parent, its role is planning,
judgment, and final synthesis while every implementation chunk goes to a lower
lane. The delegation floor in [`CLAUDE.md`](../../CLAUDE.md) still applies: work
finishable in a handful of tool calls stays with the parent, and verification
is never delegated.

The inline-implementation anti-pattern, its single per-PR exception, and the
second-round batching rule are **directives and stay resident in
[`CLAUDE.md`](../../CLAUDE.md)** — a directive behind a lookup is a dead
directive. What belongs here is the rationale: batching exists because CR rounds
are where a top-tier parent quietly burns its scarce weekly quota on mechanical
edits, and because a worker lane on a shared branch can absorb several findings
per dispatch instead of one round-trip each.
