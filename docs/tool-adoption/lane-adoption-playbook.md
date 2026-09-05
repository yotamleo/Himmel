# Lane-adoption playbook (HIMMEL-1246)

> Sibling of [`rubric.md`](rubric.md), not a replacement for it. The rubric
> decides whether to adopt a **community TOOL** (a skill, hook, MCP server).
> This playbook is for a different object: a **model LANE** — an entry in
> `scripts/lanes/lanes.json` an operator or the dispatch guard can route
> implementation work to (GLM, claudex, a future frontier model). A lane is
> not evaluated once and filed away like a tool ADR; it is **profiled and
> tailored per axis**, then measured into readiness. Reference the rubric for
> the general trust-posture/measurement vocabulary (§2, §4) — it isn't
> repeated here.

## Why

Every lane this project has onboarded arrived with the same failure shape:
the harness inherited some OTHER lane's tuning — a timeout sized for Codex's
latency, a context-compaction default sized for a 200k-token model, an
identity file that hardcodes a different provider's name — and the new lane
either timed out spuriously, compacted early, or ran under an
under-specified persona, before anyone measured what the new lane actually
needed. The GLM onboarding (HIMMEL-1241 epic) is the worked example this
playbook generalizes: each axis below is a knob GLM's rollout tripped over,
with the fix now checked into the repo as evidence of what "profile it, then
tailor it" looks like in practice.

**The rule, once per axis: PROFILE the new lane's real behavior before you
TAILOR any config to it.** Never inherit another lane's number.

## How to use this

Run the seven axes below against the new lane, in order, before it earns any
default routing. Each axis names what to *measure* on the new lane and what
*config/code knob* the measurement feeds. Where the axis has GLM evidence
already in the repo, it's cited by path/line so you can see the pattern
before repeating it. Where the brief for this ticket named a ticket number
this worktree could not find checked into the repo, that's flagged as a
discrepancy rather than guessed at — treat those as open follow-up tickets,
not yet-landed evidence.

---

## 1. Latency budget

**Profile:** the new lane's real wall-clock response time and payload size
under a representative task — not a number carried over from another lane.

**Tailor:** `CRITIC_TIMEOUT_SECS` in `scripts/cr/critic-panel.sh` (default
`240`, set at line ~214: `CRITIC_TIMEOUT_SECS="${CRITIC_TIMEOUT_SECS:-240}"`)
is the per-critic-member wall-clock timeout applied to every model in the CR
panel, regardless of which backend answers. It also supports a **per-row
override** (`_resolve_member_timeout`, line ~316) — use that to give one lane
its own number instead of bumping the shared default for everyone.

**GLM evidence:** `glm-5.2[1m]` measured **~205s / 23KB** response on a real
panel run — close enough to the 240s ceiling that real-world variance tips it
into a **spurious timeout** (HIMMEL-1245). The 240s constant itself predates
GLM (`CHANGELOG.md`: "[HIMMEL-558] raise CRITIC_TIMEOUT_SECS default 150
to 240s") — it was sized around the panel's existing (Codex-class) members,
then a new lane inherited it without being measured against it.

**Action:** before wiring a new lane into any dispatcher with a hardcoded
wall-clock bound, measure its typical response latency and size, then set a
per-lane override rather than trusting the shared default to fit.

**Discrepancy flagged:** HIMMEL-1245 is not cited anywhere in-repo (no
comment, no CHANGELOG line) — the 240s constant and its HIMMEL-558 origin are
real and grounded (`scripts/cr/critic-panel.sh`), but the GLM
timeout-measurement finding itself is evidence carried in this ticket's brief,
not yet landed as a code comment or test. Treat it as the motivating
observation, not as something you can `grep` and confirm today.

---

## 2. Context window

**Profile:** the lane's real backend context ceiling AND its **cost-optimal**
operating window — these are not the same number. `scripts/lanes/lanes.json`'s
`$context-note` states the distinction explicitly: `context.windowTokens` is "the
lane's cost-optimal default operating window... don't route work that won't
fit" — codex lanes default to 272k even though the real backend window is
~372k, because 272k is the 2x-pricing cliff, not a hard ceiling.

**Tailor:** two separate config points, not one — there's no automatic
projection from one to the other:
- `lanes.json`'s per-lane `context.windowTokens` field (`glm`: 1000000, `claudex`:
  900000 — HIMMEL-1833 operator ruling, 2026-08-17, launcher default
  unchanged — see the registry, `haiku`: 200000) feeds the lane **resolver**
  (`scripts/lanes/resolve.mjs`), which uses it for the `/lanes` `[ctx: N]`
  **display annotation only** — no dispatch guard reads it; the dispatch-side
  window preflight is configured separately (`spawn-claudex.ts` hardcodes its
  own 272000 constant) — and it does not set any env var itself.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (the Claude Code env var that actually
  controls when the harness starts compacting) is set by the **launcher**
  from its own env knob: the GLM launcher's `GLM_CONTEXT_WINDOW` and
  `spawn-glm --context big|small` preset (`docs/glm-offload.md`): `big` =
  `glm-5.2[1m]` + `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000`; `small` =
  `glm-5.2` + 200000; the codex lane's twin, `CODEX_CONTEXT_WINDOW`
  (`docs/tooling-catalog.md` `claude-codex` section); and the routed lane's
  `ROUTED_CONTEXT_WINDOW`.

Configure both for a new lane — the registry value and the launcher env
knob — since neither derives the other; setting only one leaves the other
silently stale.

**GLM evidence:** without an explicit window, Claude Code assumes its ~200k
default for an unrecognized model slug and compacts/rejects early — the
documented "prompt too long" deaths in `docs/glm-offload.md`. Setting
`CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000` for the `[1m]` GLM variant fixed it.

**Action:** never let a new lane's model slug silently fall through to Claude
Code's built-in default window. Look up (or benchmark) the backend's real
ceiling, decide the cost-optimal operating point, and set the
auto-compact-window knob explicitly — same pattern as `glm`/`claudex` above.

---

## 3. SOUL/persona

**Profile:** does the new lane get its own identity file matched to its
actual capability tier, or does it inherit an identity written for a
different provider, or default to a persona sized for a weaker role?

**Tailor:** two SOUL assets already exist in `scripts/hermes/assets/`, and
neither is a drop-in fit for a new frontier lane:
- `himmel-agent.SOUL.md` — the **senior** identity, installed onto the
  `himmel_agent` hermes profile by `scripts/hermes/install-himmel-profile.sh`.
  Its opening line hardcodes the provider: *"running as the **main tier** on
  Codex (GPT-5.5)"* — and the installer's own profile description literally
  reads *"himmel's main-tier orchestrator (Codex/GPT-5.5)"*
  (`install-himmel-profile.sh` line 97). This SOUL is **Codex-provider-bound**
  by construction, not generic.
- `free-tier.SOUL.md` — the **junior, read-only** identity for free critics
  (`qwen3-coder-plus` anchor): terse, ~32K context budget, JSON-only output
  contract, explicitly "You do not write code to disk, run git, open PRs."

**GLM evidence:** a frontier lane dispatched under `himmel-agent.SOUL.md`
verbatim inherits a false provider claim; dispatched under
`free-tier.SOUL.md` it inherits a read-only ceiling that under-drives a
full-capability model. Neither fits — the fix is a **per-lane senior
profile**: clone the senior SOUL's structure (identity, working principles,
precedence ladder, hard limits) but swap the provider-specific line for the
new lane's actual backend.

**Discrepancy flagged:** the brief cites HIMMEL-559 for this axis, but the
in-repo HIMMEL-559 (`scripts/agents-md/debrand.json`) is a **different,
related** problem: it's the CLAUDE.md → AGENTS.md debranding pass that
neutralizes Fable-specific identity language (*"the Fable main thread"* →
*"the main thread"*) so a non-Claude driver reading the shared `CLAUDE.md`
doesn't misidentify itself. That's about a Codex/GPT session correctly
NOT reading Claude-branded prose as its own identity — the opposite move
from authoring a dedicated senior SOUL for a new provider. Both are
persona-correctness work; they are not the same change.

---

## 4. Prompt family

**Profile:** which scaffolding family the new lane's model name resolves to.

**Tailor:** `family_for_model()` in `scripts/cr/critic-first-pass.sh`
(lines 88–101) — a `case` statement mapping a lowercased model-name substring
to `gpt | open | claude`, each with different prompt scaffolding (GPT/codex:
explicit non-contradiction + spec tags; open: rigid format-obedience because
open models "drift from the contract and over-report"; Claude: XML +
IMPORTANT markers). Order matters — `gpt-oss`/`gptoss` must match before the
real-GPT branch or they'd be misfiled.

**GLM evidence:** `*glm*` falls into the `open` family bucket (alongside
qwen/kimi/deepseek/mistral/llama) — rigid format-obedience scaffolding, the
same bucket the unknown-model fallback (`*) echo open ;;`) defaults to as
"the safest default."

**Action:** before wiring a new lane's model name into `critic-first-pass.sh`
or any prompt-family-aware caller, check which branch its name resolves to.
An unmatched name silently lands in `open` — verify that's actually the right
scaffolding for the new model's failure modes, don't assume the fallback is
correct just because it doesn't error.

---

## 5. Harness choice

**Profile:** does the task need a fire-and-forget one-shot dispatch, or a
full himmel-harness session (worktree, hooks, guardrails, durable
transcript)? Measure the actual requirement — isolation, durability,
per-dispatch model control — don't default to whichever is easiest to wire.

**Tailor:** two structurally different spawn shapes exist:
- **Hermes one-shot** (`scripts/hermes/invoke.sh` / `dispatch-trusted.sh`) —
  no worktree; `invoke.sh` wall-clock timeboxes + Nth-identical-deny aborts
  it (HIMMEL-2025 — a parity_guard DENY is not terminal to hermes upstream),
  `-z`
  auto-approval with a `todo`-only default toolset. Cheapest to dispatch,
  weakest isolation.
- **Full-session `cc-<lane>`** (`scripts/claude-glm`, `scripts/claude-codex`)
  — runs the complete Claude Code harness (skills, hooks, guardrails,
  worktrees) over the lane's backend. Dedicated worktree + branch, durable
  session artifacts, native Claude Code hook coverage.

**Evidence:** `docs/internals/worker-spawn-matrix.md` (HIMMEL-749) is the
grounded comparison — a full matrix of worktree isolation, guard/hook
coverage, per-dispatch model selection, session artifacts, push/PR authority,
permission handling, and supervision signal across all five spawn paths
(native Hermes subagent, Hermes one-shot, external Claude Code worker,
GLM worker, Codex worker). Its verdict: "the Hermes one-shot lane has the
clearest model/toolset selector... the GLM worker has the clearest worker
artifact contract" — the two shapes trade off differently, and the matrix
names which cells are `UNVERIFIED` per path rather than assuming parity.

**Discrepancy flagged:** the brief cites HIMMEL-1113 for this axis. No
HIMMEL-1113 reference exists anywhere in this repo (clean grep across code
and docs). The comparison this axis needs is fully grounded instead by
HIMMEL-749's `worker-spawn-matrix.md` — cite that as the evidence base;
treat HIMMEL-1113 as a ticket number this worktree could not corroborate.

---

## 6. Trust/egress posture

**Profile:** is the new lane's provider declared in the egress matrix at
all? If not, every corpus defaults to deny for it.

**Tailor:** `scripts/guardrails/egress-matrix.json` is keyed by **provider ×
corpus × purpose — there is no lane axis.** What to do depends on whether the
new lane's backend is already a declared provider:
1. **Provider already declared** (e.g. another lane already runs on
   `zai-glm`): add nothing to `providers`. Reusing it means the new lane
   automatically inherits every existing `rules` row for that provider,
   across every corpus — review those rows before onboarding, since a rule
   scoped to the existing lane's use case now also covers the new one. If
   the new lane needs different clearance, give it a distinct provider
   identity instead of reusing the shared one.
2. **Provider genuinely new:** add a `providers` entry (region + one-line
   note — see the `zai-glm` / `openai-codex` rows for the shape), then
   explicit `rules` rows for each corpus the lane needs (`corpus` x
   `provider` x `purpose` → `allow` / `allow+log` / `conditional` / `deny`).
3. Nothing at all, if the lane should stay denied everywhere for now — the
   file's own `"default": "deny"` already covers that.

**GLM evidence — a full ratify-then-reverse cycle.** `zai-glm` was declared
(`"region": "CN"`) with narrow, dated, ticketed rules — `luna-personal` ×
`zai-glm` × `extraction` was `allow+log`, ratified 2026-07-17 (HIMMEL-1122)
with a measured comparison against the prior incumbent recorded directly in
the `why` field, and `handover-state` × `zai-glm` × `inference` was
`conditional` on "brief-scoped... never bulk corpus runs." When the lane was
dropped (HIMMEL-1749; Coding Plan lapsed 2026-08-17) all four cells were
**reversed to explicit `deny` with the reversal recorded in each `why`**
(HIMMEL-2224), and the `providers` note was annotated `DE-LISTED` — the same
shape HIMMEL-1257 used for DeepSeek/Alibaba. **This is the pattern to copy
when a lane you onboarded goes away: reverse the rows, never delete them.** A
deleted row falls through to `"default": "deny"` and reads identically to a
provider that was never permitted, destroying the audit trail of what was
once open and why. **PHI (`salus` corpus) is hard-denied for every provider with
no override, structurally** — this doesn't change per lane.

**Action:** before a new lane touches any vault or handover corpus, check
whether its provider is already declared. An **undeclared provider is
default-DENY** (`"default": "deny"`, `scripts/guardrails/egress-matrix.json`
line 176) — add its provider row and the specific per-corpus rules it needs.
A **declared** provider is different: reusing it is not free, since the
matrix has no lane axis and every existing rule for that provider now also
covers the new lane — review those rows for fit rather than assuming they
were written with this lane's use case in mind, and register a distinct
provider identity if they don't fit.

---

## 7. Measure before trust

**Profile:** run the rubric's measurement protocol against the new lane on
real work, and clear the **structural readiness gate** before it earns
default routing — readiness is measured, never asserted.

**Tailor:**
- The measurement method: `docs/tool-adoption/rubric.md` §4 (baseline vs
  treatment on outcome-per-session signals, not token count) — the same
  protocol this playbook's sibling doc uses for tools, reused here for lanes.
- The structural gate: `scripts/lanes/lane-readiness.mjs` +
  `readiness.passesRequired` in `scripts/lanes/lanes.json` (HIMMEL-1626).
  Readiness is computed from **trailing consecutive PASS rows** in the
  verify-return ledger (HIMMEL-1621, `scripts/lanes/verify-return.mjs`) —
  a single FAILED row resets the streak to zero. A lane below its gate reads
  `down`, and the dispatch guard (`scripts/hooks/guard-implementor-dispatch.sh`)
  treats `down` as **skip-toward-another-lane**, never as a hard refusal.

**GLM evidence:** `lanes.json`'s `$readiness-note` records the live operator
ruling (2026-08-07): **glm gated at 10 consecutive passes** (down since the
HIMMEL-1575 startup-hang class was found), **claudex on probation at 5**
consecutive passes to graduate. A lane can be fully *funded* (quota
available) while still *not ready* (an operator ruling holds it down) —
funding and readiness are deliberately different questions
(`lane-readiness.mjs` header comment).

**Action:** don't route default work to a new lane on the strength of a
pitch or a single successful dispatch. Register it in `lanes.json` with a
`readiness.passesRequired` gate, let the verify-return ledger accumulate real
passes, and only drop the gate (or raise `passesRequired` back up on a
regression) once the trailing-pass evidence supports it. Treat this as the
**dispatch gate**, not the whole of "measure before trust" — clearing it only
shows the lane's dispatches keep passing their own verify-return checks; it
says nothing about outcome-per-session on real work. Run the rubric §4
measurement independently and don't let a clean pass streak substitute for it.

**Discrepancy flagged:** the brief cites HIMMEL-1118 for the benchmark step.
No HIMMEL-1118 reference exists anywhere in this repo. The grounded
artifacts for "measure before trust" are the rubric's own protocol
(HIMMEL-200, `docs/tool-adoption/rubric.md` §4) and the concrete structural
gate that now backs it (HIMMEL-1626, `scripts/lanes/lane-readiness.mjs`) —
cite those; treat HIMMEL-1118 as an open ticket this worktree could not
corroborate against checked-in evidence.

---

## Summary checklist

Run in order; each row's "tailor" artifact is where the fix lands.

| # | Axis | Profile (measure) | Tailor (config/code) |
|---|------|--------------------|-----------------------|
| 1 | Latency budget | Real wall-clock + payload size on representative work | `CRITIC_TIMEOUT_SECS` / per-row override in `scripts/cr/critic-panel.sh` |
| 2 | Context window | Real backend ceiling vs cost-optimal operating point | `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `lanes.json` `context.windowTokens`, lane-specific `*_CONTEXT_WINDOW` env |
| 3 | SOUL/persona | Capability tier the lane actually has | A per-lane senior SOUL cloned from `himmel-agent.SOUL.md`'s structure, provider line swapped |
| 4 | Prompt family | Which family bucket the model name resolves to | `family_for_model()` in `scripts/cr/critic-first-pass.sh` |
| 5 | Harness choice | Isolation/durability the task actually needs | Hermes one-shot vs full-session `cc-<lane>` launcher — see `docs/internals/worker-spawn-matrix.md` |
| 6 | Trust/egress posture | Which corpora the lane is cleared against | `scripts/guardrails/egress-matrix.json` — provider entry + explicit rules |
| 7 | Measure before trust | Outcome-per-session over real work, sustained (rubric §4 — independent of the dispatch gate below) | Structural **dispatch gate**: `readiness.passesRequired` in `scripts/lanes/lanes.json` + `scripts/lanes/lane-readiness.mjs` (a trailing verify-return PASS streak, not outcome evidence) |

Ground every number on the new lane itself. An inherited default is exactly
the failure this playbook exists to catch.
