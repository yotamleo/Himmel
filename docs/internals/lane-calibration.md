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
model, raise effort before tier, the env-capped spawn depth + concurrency,
Haiku does not spawn,
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
NOT a hard ceiling: larger inputs remain possible past it at higher cost.

The codex-family figures below are **all 900000 as of HIMMEL-1833** (operator
ruling, 2026-08-17), but the EVIDENCE behind that number is deliberately NOT
uniform per lane — same weekly bank, different real backends, different
verification status. A blended story would misrepresent at least one of them.
`lanes.json`'s `$context-note` carries the full per-lane reasoning (measured
vs. ruled, and the gpt-5.5 conflict on three of the five); this table only
summarizes.

Invoke implementation lanes through `scripts/telegram/dispatch-lane.sh` with
the Bash tool's `run_in_background: true`. Its command and flag mapping comes
from each lane's structured `dispatch` entry; the parent receives one bounded
final report instead of spending a Claude wrapper agent on polling.

**v1 lane scope (operator ruling 34, 2026-09-01, HIMMEL-2352):** the
`himmelctl install` wizard ships Claude tiers as the ONLY implementation
lanes; `codex`/`hermes` are offered ONLY as cross-model review (CR) lanes for
`/pr-check`, never as implementation lanes. `ollama-local` and `copilot-cli`
are dormant in v1 (below, `dormant.optInEnv`) — the wizard no longer offers,
selects, or probes either; an operator who wants them sets the registry's
`optInEnv` directly rather than through himmelctl. This is a wizard/installer
scoping decision, not a registry deletion: both rows stay fully live in
`/lanes` and this table, on the operator's own explicit opt-in, "based on user
requests" (the ruling's own words) — the same dormant shape every other row
below already uses.

| Lane (`lanes.json` id) | Class | Default effort convention | Cost-optimal context window | Quota bank | Calibration status |
|---|---|---|---|---|---|
| `glm` — GLM lane (spawn-glm.ts) | impl | small-context discipline — chunk big plans | 1M | glm (flat-rate overflow, not per-token) | calibrated |
| `claudex` — claudex lane (claude-codex over CLIProxyAPI) | impl | launcher default `high`; `xhigh` rare; never `ultra`/`max` | 900000 — declared window raised by operator ruling (HIMMEL-1833, 2026-08-17) alongside `hermes-oneshot`; the CLIProxyAPI path itself is UNMEASURED at 900k (see below) — the launcher's `CODEX_CONTEXT_WINDOW` default stays 272000 (its own code warns past the ~372k backend ceiling it has evidence for), so a caller opts UP toward 900k per-dispatch and accepts the risk | codex | calibrated (HIMMEL-1001/1002) |
| `hermes-critics` — hermes free critics (scripts/cr/hermes-critic.sh) | critic | — (critic pass, not effort-tiered) | unverified/varies | none (dashboard-omitted) | calibrated — model is PINNED to gpt-6-astra via `critics.json` (re-pinned HIMMEL-2546, 2026-09-05, operator switched the codex CLI default; the pin-via-critics.json mechanism itself dates to operator ruling 2026-08-23, HIMMEL-2059, which pinned gpt-5.6-sol), not the himmel_agent profile default (ox-alpha stays reserved for `hermes-oneshot`/dispatch-trusted); not yet wired into the `/pr-check` gate (HIMMEL-2031) |
| `codex` (paid, via hermes) | critic | — (critic pass) | 900000 — raised by operator ruling (HIMMEL-1833, 2026-08-17); pins gpt-6-astra via `critics.json` (HIMMEL-2546, 2026-09-05) — the window figure predates and is independent of the model pin; least-verified of the five raised lanes | none (dashboard-omitted); opt-in `CR_PROFILE=paid` | calibrated — CR escalation / second opinions only |
| `copilot-cli` — GitHub Copilot CLI (free tier) | bulk | small tasks; model tier is mini-class unless the caller overrides the auto pin | unverified/varies | none (dashboard-omitted); 2,000 completions/mo bank | **not calibrated yet** — worker-spawn-matrix row UNVERIFIED (live smoke pending eval); route only for free chores / second opinions, and only through the `dispatch-copilot.sh` chokepoint |
| `hermes-oneshot` — hermes one-shot dispatch | impl | invoke.sh wall-clock timebox (default 1800s) + Nth-identical-deny abort (HIMMEL-2025) | 900000 — re-confirmed on ox-alpha (HIMMEL-2024, 2026-08-22: 300K/600K/900K probes all accepted); previously operator-verified inside hermes v0.20.2 (2026.8.16), upstream commit `bab7be3c` (2026-08-17), superseding 350000 (hermes-agent commit 522997543, 2026-08-16) | none (dashboard-omitted) — free while ox-alpha lasts | calibrated — live-proven spawn path; see [ox-alpha](#ox-alpha--the-current-hermes-himmel_agent-default-himmel-2024) |
| `codex-exec` — codex CLI sandbox | impl | well-scoped chunks; job registry is per-workspace | 900000 — raised by operator ruling (HIMMEL-1833, 2026-08-17) despite still pinning gpt-5.5, the same model hermes measured rejecting a 360K probe; least-verified of the five raised lanes | codex | calibrated (HIMMEL-741) |
| `codex-wsl` — codex WSL lane | impl | well-scoped chunks; brief via `--brief-file` | 900000 — raised by operator ruling (HIMMEL-1833, 2026-08-17) despite still pinning gpt-5.5, the same model hermes measured rejecting a 360K probe; least-verified of the five raised lanes | codex | calibrated (HIMMEL-999) |
| `antigravity-cli` — Antigravity CLI (Google AI Plus) | bulk | simple tasks; `--output-format` drift seen on Windows builds | unverified/varies | none (dashboard-omitted); free AI-Plus bank | **not calibrated yet** — roster + quota shape TO VERIFY at eval (HIMMEL-772); parity/guards UNVERIFIED (permission flags only, no hook surface); egress-DENIED for vault corpora, himmel-code only; route only for free-bank chores / second opinions |
| `ollama-local` — ollama (local models) | bulk | slow, small tasks | unverified/varies | none (dashboard-omitted); free, local wall-clock | calibrated — zero-egress guarantee is structural; the only salus-eligible backend |
| `openrouter-free` — OpenRouter free models | bulk | simple tasks only; rate-limited | unverified/varies | none (dashboard-omitted) | **not calibrated yet** — parity/guards UNVERIFIED pending eval; probe live availability before routing, route only for simple free-tier chores |
| `ollama-cloud` — Ollama Cloud (free tier) | bulk | simple tasks; free-bank caps | unverified/varies | none (dashboard-omitted) | **not calibrated yet** — parity/guards UNVERIFIED pending eval; egresses to ollama.com, an undeclared egress-matrix provider — vault corpora default-DENY (himmel-code only) until the operator declares a cell; route only for free-bank chores on non-vault corpora |

## ox-alpha — the current hermes `himmel_agent` default (HIMMEL-2024)

The `hermes-oneshot` lane takes its model from the `himmel_agent` hermes
profile's default rather than from a pin in this repo. Hermes-routed critics do
NOT ask for that profile by name — `hermes-critic.sh` passes no `-p`, so it
gets whichever profile hermes has ACTIVE. The two land on the same model today
only because `%LOCALAPPDATA%/hermes/active_profile` reads `himmel_agent`; that
coupling is a real gap, not a guarantee (last two notes below). The
`himmel_agent` default is **`stealth/ox-alpha`** (provider `nous`,
`https://inference-api.nousresearch.com/v1`) as of 2026-08-22 — **free,
front-tier, and TEMPORARY**. It was `gpt-5.6-sol`. Per the lane-adoption rule
(profile + tailor per lane; a codex-tuned 240s budget once starved the GLM
lane), it is measured here rather than assumed.

Measured 2026-08-22 on this machine, `scripts/hermes/invoke.sh --profile
himmel_agent`:

| Axis | Result |
|---|---|
| Small prompt (~1.0 KB) — 3 runs | 12.4 / 12.7 / 14.7 s — **p50 12.7s, p95 14.7s** |
| CR-sized prompt (~45 KB real diff) — 2 runs | 58.8 / 64.9 s |
| Context accept probes (synthetic, ~4 chars/token) | 300K OK (43.0s), 600K OK (49.1s), **900K accepted (35.5s)** — no rejection, no `context_length_exceeded` at any size; acceptance only, see the caveat below |
| JSON-verdict reliability (`scripts/cr/hermes-critic.sh --model ""`) — 3 runs | **3/3** valid fail-closed verdicts, rc=0, full key set; 108.2 / 57.3 / 82.8 s — **p95 108.2s** |
| Tool-call behaviour under the profile SOUL | correct — `--toolsets coding`, listed `scripts/cr` and answered `COUNT=50`, exactly matching `ls -1 \| wc -l`; 29.3s; no refusal or format quirk |

Notes a future reader needs:

- **A 900K acceptance does not prove the model attended to every token.** The 900K probe returned
  *faster* than the 600K one, which is what compaction upstream of the model
  looks like. `context.overflow` for this lane is already `compact-continue`;
  900000 stays the declared operating window on that basis, unchanged — it was already an operator ruling/measurement (HIMMEL-1833) before ox-alpha, and these probes establish ACCEPTANCE at that size, not a verified usable window.
- **`--toolsets fs` is not a hermes toolset** — it exits 2 in ~1s with
  `ignoring unknown --toolsets entries: fs`. Use `coding`.
- **Recommended `CRITIC_TIMEOUT_SECS` for a hermes critic row: 180s**
  (p95 108.2s x 1.5 = 162, rounded up). That is well under the shared
  codex-tuned 240s default, so a hermes row must set its own `timeout_secs`
  (HIMMEL-1245) to get the benefit — inheriting 240s is not wrong, only
  loose. The 108.2s p95 run overlapped a concurrent 900K context probe; the
  two clean runs were 57.3s and 82.8s, so 180s carries real margin.
- **No hermes row exists in `scripts/cr/critics.json` today** (the panel is
  `codex` only), so there is no timeout value to correct here, and — contrary
  to what an earlier draft of this note said — adding one is NOT a config-only
  follow-up. `critic-panel.sh`'s per-member reviewer, `critic-first-pass.sh`,
  hard-requires `--model` (`exit 2` on empty), so a row deferring to the
  profile default (`model: ""`, the whole point of HIMMEL-2017/#1811) needs a
  real code change there first. Separately, a live free-tier panel row would
  silently reverse the HIMMEL-1101 operator decision recorded in
  `pr-check.md` ("paid-by-default — free lane removed deliberately" after
  qwen3coder/gptoss/kimi were dropped for noise/errors) — that reversal wants
  its own explicit sign-off, not a side effect of a lanes.json/docs pass.
  Tracked as **HIMMEL-2031** (agreed-rate data for the eventual promotion
  call needs this wired in first; until then `/cr-scores` has nothing to
  report for hermes/ox-alpha — `hermes-critic.sh` is not invoked by any live
  `/pr-check` path today).
- **The profile is what routes.** `hermes-critic.sh` does not pass `-p`; the
  no-`-p` path lands on ox-alpha only because
  `%LOCALAPPDATA%/hermes/active_profile` reads `himmel_agent`. The hermes root
  config still defaults to `gpt-5.5`/`openai-codex`, so if the operator switches
  the active profile, hermes-routed critics silently change model. **Doctor
  advisory: `himmel-doctor.sh` check C21** (HIMMEL-2024) WARNs when the active
  hermes profile's `config.yaml` `model.default` no longer matches the
  `profileDefaultModel` this file's `lanes.json` records for the
  `hermes-oneshot`/`hermes-critics` rows — advisory only, it never edits the
  profile or lanes.json, and never runs the hermes CLI (a plain offline file
  read).
- **Temporary.** ox-alpha's availability is time-limited; when it goes, the
  profile default moves and these numbers expire with it. Nothing in this repo
  pins ox-alpha by name, which is deliberate.

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
